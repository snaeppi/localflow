@preconcurrency import CoreML
import CryptoKit
import FluidAudio
import Foundation
import Synchronization
import os

/// Copies of a Parakeet encoder (or v3's preprocessor) bundle for fewer mel frames than the 1501
/// (15 s) it's compiled for. The graphs mask the frames past `mel_length`, so a window that holds the
/// recording gives the same valid frames in a fraction of the time (bench/README.md; which window
/// holds a recording is the pipeline's rule). Each window is derived from the bundle: its model.mil
/// with the window's sizes, its description with the new shapes, its weights by a relative link
/// (which survives moving the app folder).
struct ShorterWindows {
    enum Graph {
        /// Parakeet Unified's encoder: masks at each subsampling stage, positional terms (one per
        /// layer, for 375 relative positions) quantized per position.
        case unifiedEncoder
        /// Parakeet TDT v3's encoder: one mask, from the encoder frames, and palettized positional terms.
        case v3Encoder
        /// v3's preprocessor (audio to mel on the CPU): 160 samples per mel frame.
        case v3Preprocessor
    }

    let graph: Graph
    /// The 15 s bundle.
    let source: String
    /// Mel frames, and the SHA-256 of the derived model.mil followed by coremldata.bin. CoreML
    /// crashes on a graph it can't parse rather than throwing, so nothing else is loaded.
    let all: [(frames: Int, sha256: String)]

    /// Audio samples that a window of `frames` mel frames takes (v3's preprocessor).
    static func samples(_ frames: Int) -> Int { 160 * (frames - 1) }

    private static let melBins = 128
    private static let log = Logger(subsystem: "io.github.snaeppi.localflow", category: "asr")

    func name(_ frames: Int) -> String { "\(source.dropLast(".mlmodelc".count))_\(frames).mlmodelc" }
    private var weights: String { "../../\(source)/weights/weight.bin" }

    /// One derivation at a time: a model unloaded while deriving can be loaded again meanwhile.
    private static let deriving = Mutex(())

    /// Frames after each of the subsampling's three stride-2 convolutions (1501: 751, 376, 188).
    static func stages(_ frames: Int) -> (Int, Int, Int) {
        let l1 = (frames - 1) / 2 + 1, l2 = (l1 - 1) / 2 + 1
        return (l1, l2, (l2 - 1) / 2 + 1)
    }

    /// The window, derived first if it's missing or not the expected one, and warmed up; nil if
    /// that fails.
    func load(_ window: (frames: Int, sha256: String), in directory: URL) async -> MLModel? {
        let url = directory.appending(path: name(window.frames))
        // CoreML crashes on a bundle it can't load rather than throwing, so a load that didn't
        // finish (the app crashed, or quit while it compiled) is tried once more, not at every launch.
        let attempts = directory.appending(path: name(window.frames) + ".attempts")
        let tried = (try? String(contentsOf: attempts, encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        guard tried < 2 else {
            Self.log.error("\(url.lastPathComponent, privacy: .public) skipped: its last loads didn't finish")
            return nil
        }
        do {
            try Self.deriving.withLock { _ in
                if !isDerived(url, window.sha256) { try derive(window, in: directory) }
            }
            try String(tried + 1).write(to: attempts, atomically: true, encoding: .utf8)
            // As the 15 s bundles: preprocessors on the CPU, encoders on the Neural Engine.
            let model = try await MLModel.load(
                contentsOf: url,
                configuration: MLModelConfigurationUtils.defaultConfiguration(
                    computeUnits: graph == .v3Preprocessor ? .cpuOnly : .cpuAndNeuralEngine))
            // The first inference places an encoder on the Neural Engine and warms either up.
            let (input, shape) = graph == .v3Preprocessor
                ? (("audio_signal", "audio_length"), [1, NSNumber(value: Self.samples(window.frames))])
                : (("mel", "mel_length"), [1, NSNumber(value: Self.melBins), NSNumber(value: window.frames)])
            let values = try MLMultiArray(shape: shape, dataType: .float32)
            values.withUnsafeMutableBufferPointer(ofType: Float.self) { p, _ in p.initialize(repeating: 0) }
            let length = try MLMultiArray(shape: [1], dataType: .int32)
            length[0] = 1
            _ = try await model.prediction(
                from: MLDictionaryFeatureProvider(dictionary: [input.0: values, input.1: length]))
            try? FileManager.default.removeItem(at: attempts)
            return model
        } catch {
            try? FileManager.default.removeItem(at: attempts)
            Self.log.error("\(url.lastPathComponent, privacy: .public) unavailable: \(error, privacy: .public)")
            return nil
        }
    }

    /// Whether `bundle` is the derivation: its graph and description by digest, its weights by the
    /// link (copying a folder can drop links, and CoreML crashes without the weights).
    private func isDerived(_ bundle: URL, _ sha256: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: bundle.appending(path: "weights/weight.bin").path))
            == weights && (try? Self.digest(of: bundle)) == sha256
    }

    private static func digest(of bundle: URL) throws -> String {
        try digest(Data(contentsOf: bundle.appending(path: "model.mil"))
            + Data(contentsOf: bundle.appending(path: "coremldata.bin")))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func derive(_ window: (frames: Int, sha256: String), in directory: URL) throws {
        let source = directory.appending(path: self.source)
        let mil = Data(try graph(String(contentsOf: source.appending(path: "model.mil"), encoding: .utf8),
            frames: window.frames).utf8)
        let description = try self.description(
            Data(contentsOf: source.appending(path: "coremldata.bin")), frames: window.frames)
        let digest = Self.digest(mil + description)
        let target = directory.appending(path: name(window.frames))
        guard digest == window.sha256 else {
            // Another revision of the model: compare its windows' transcripts with the 15 s
            // window's before taking this digest.
            Self.log.error("\(target.lastPathComponent, privacy: .public) derived as \(digest, privacy: .public)")
            throw CocoaError(.fileReadCorruptFile)
        }
        let files = FileManager.default
        // Not inside intermediate directories, which would bring back a model removed meanwhile.
        let partial = directory.appending(path: name(window.frames) + ".partial")
        try? files.removeItem(at: partial)
        defer { try? files.removeItem(at: partial) }
        try files.createDirectory(at: partial, withIntermediateDirectories: false)
        try files.createDirectory(at: partial.appending(path: "weights"), withIntermediateDirectories: false)
        try files.createDirectory(at: partial.appending(path: "analytics"), withIntermediateDirectories: false)
        try mil.write(to: partial.appending(path: "model.mil"))
        try description.write(to: partial.appending(path: "coremldata.bin"))
        try files.copyItem(
            at: source.appending(path: "analytics/coremldata.bin"), to: partial.appending(path: "analytics/coremldata.bin"))
        try files.createSymbolicLink(
            atPath: partial.appending(path: "weights/weight.bin").path, withDestinationPath: weights)
        try? files.removeItem(at: target)
        try files.moveItem(at: partial, to: target)
    }

    /// The 15 s graph with the window's sizes: mel frames 1501 → 751 → 376 → 188 encoder frames
    /// through the subsampling, attention's 375 relative positions (376 padded for the shift), the
    /// convolution modules' 196 (188 padded). The constants made for 1501 frames are made again,
    /// and the positional terms (one per layer, for 375 positions) are sliced to the window's.
    func graph(_ mil: String, frames: Int) throws -> String {
        if graph == .v3Preprocessor { return try preprocessorGraph(mil, frames: frames) }
        let (l1, l2, n) = Self.stages(frames)
        func sizes(_ list: Substring) -> String {
            let values = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let attention = values.count > 1 && values[1] == "8"   // [1, 8 heads, …]
            return values.map { value in
                switch value {
                case "1501": "\(frames)"
                case "751": "\(l1)"
                case "376": attention ? "\(2 * n)" : "\(l2)"
                case "375": "\(2 * n - 1)"
                case "196": "\(n + 8)"
                case "188": "\(n)"
                default: value
                }
            }.joined(separator: ", ")
        }
        let (context, positional) = graph == .unifiedEncoder
            ? ("const_63", "constexpr_affine_dequantize") : ("const_7", "constexpr_lut_to_dense")
        var lines: [String] = []
        var made = 0, sliced = 0
        for line in mil.split(separator: "\n", omittingEmptySubsequences: false) {
            if let m = line.prefixMatch(of: /(\s*)tensor<int32, \[1, \d+\]> (expand_dims_([0-3])) = const\(\)/) {
                // The positions the masks compare lengths with: Unified's for each stage, v3's for the output.
                let count = graph == .unifiedEncoder ? [frames, l1, l2, n][Int(m.3)!] : n
                let range = (0..<count).map(String.init).joined(separator: ", ")
                lines.append("\(m.1)tensor<int32, [1, \(count)]> \(m.2) = const()[name = tensor<string, []>(\"\(m.2)\"), "
                    + "val = tensor<int32, [1, \(count)]>([[\(range)]])];")
                made += 1
            } else if let m = line.prefixMatch(of: /(\s*)tensor<bool, \[1, 188, 188\]> (const_\d+) = const\(\)/),
                m.2 == context
            {
                // Attention's context: all of it, offline.
                let row = "[" + [String](repeating: "true", count: n).joined(separator: ", ") + "]"
                lines.append("\(m.1)tensor<bool, [1, \(n), \(n)]> \(context) = const()[name = tensor<string, []>(\"\(context)\"), "
                    + "val = tensor<bool, [1, \(n), \(n)]>([[\([String](repeating: row, count: n).joined(separator: ", "))]])];")
                made += 1
            } else if let m = line.wholeMatch(of: /(\s*)tensor<fp16, \[1, 8, 128, 375\]> (\w+) = (constexpr_\w+)\(\)(.*)/),
                m.3 == positional
            {
                // Relative positions 187 … −187; the window's are the middle 2n − 1.
                let (indent, name) = (m.1, m.2)
                let rest = m.4.replacing("(\"\(name)\")", with: "(\"\(name)_full\")")
                lines += [
                    "\(indent)tensor<fp16, [1, 8, 128, 375]> \(name)_full = \(positional)()\(rest)",
                    "\(indent)tensor<int32, [4]> \(name)_begin = const()[name = tensor<string, []>(\"\(name)_begin\"), "
                        + "val = tensor<int32, [4]>([0, 0, 0, \(188 - n)])];",
                    "\(indent)tensor<int32, [4]> \(name)_end = const()[name = tensor<string, []>(\"\(name)_end\"), "
                        + "val = tensor<int32, [4]>([1, 8, 128, \(187 + n)])];",
                    "\(indent)tensor<fp16, [1, 8, 128, \(2 * n - 1)]> \(name) = slice_by_index(begin = \(name)_begin, "
                        + "end = \(name)_end, x = \(name)_full)[name = tensor<string, []>(\"\(name)\")];",
                ]
                sliced += 1
            } else {
                lines.append(String(line)
                    .replacing(/tensor<(\w+), \[([0-9, ]*)\]>/) { "tensor<\($0.1), [\(sizes($0.2))]>" }
                    .replacing(/val = tensor<int32, \[(\d+)\]>\(\[([-0-9, ]+)\]\)/) {
                        "val = tensor<int32, [\($0.1)]>([\(sizes($0.2))])"
                    })
            }
        }
        guard made == (graph == .unifiedEncoder ? 5 : 2), sliced == 24 else { throw CocoaError(.fileReadCorruptFile) }
        return lines.joined(separator: "\n")
    }

    /// v3's preprocessor graph with the window's sizes: 240000 samples (239999 after pre-emphasis,
    /// 240512 padded for the STFT) and 1501 mel frames; the frame positions the mask compares with are
    /// made again, and the constant the masked frames take is sliced to the window's.
    private func preprocessorGraph(_ mil: String, frames: Int) throws -> String {
        let samples = Self.samples(frames)
        let sizes = ["240000": samples, "239999": samples - 1, "240512": samples + 512, "1501": frames]
        func resize(_ list: Substring) -> String {
            list.split(separator: ",").map { value in
                let value = value.trimmingCharacters(in: .whitespaces)
                return sizes[value].map(String.init) ?? value
            }.joined(separator: ", ")
        }
        var lines: [String] = []
        var made = 0
        for line in mil.split(separator: "\n", omittingEmptySubsequences: false) {
            if let m = line.prefixMatch(of: /(\s*)tensor<int32, \[1, 1501\]> var_82 = const\(\)/) {
                let range = (0..<frames).map(String.init).joined(separator: ", ")
                lines.append("\(m.1)tensor<int32, [1, \(frames)]> var_82 = const()[name = tensor<string, []>(\"op_82\"), "
                    + "val = tensor<int32, [1, \(frames)]>([[\(range)]])];")
                made += 1
            } else if let m = line.wholeMatch(
                of: /(\s*)tensor<fp16, \[1, 128, 1501\]> (op_24_after_broadcast_to_fp16_quantized) = constexpr_affine_dequantize\(\)(.*)/)
            {
                let (indent, name) = (m.1, m.2)
                let rest = m.3.replacing("(\"\(name)\")", with: "(\"\(name)_full\")")
                lines += [
                    "\(indent)tensor<fp16, [1, 128, 1501]> \(name)_full = constexpr_affine_dequantize()\(rest)",
                    "\(indent)tensor<int32, [3]> \(name)_begin = const()[name = tensor<string, []>(\"\(name)_begin\"), "
                        + "val = tensor<int32, [3]>([0, 0, 0])];",
                    "\(indent)tensor<int32, [3]> \(name)_end = const()[name = tensor<string, []>(\"\(name)_end\"), "
                        + "val = tensor<int32, [3]>([1, 128, \(frames)])];",
                    "\(indent)tensor<fp16, [1, 128, \(frames)]> \(name) = slice_by_index(begin = \(name)_begin, "
                        + "end = \(name)_end, x = \(name)_full)[name = tensor<string, []>(\"\(name)\")];",
                ]
                made += 1
            } else {
                lines.append(String(line)
                    .replacing(/tensor<(\w+), \[([0-9, ]*)\]>/) { "tensor<\($0.1), [\(resize($0.2))]>" }
                    .replacing(/val = tensor<int32, \[(\d+)\]>\(\[([-0-9, ]+)\]\)/) {
                        "val = tensor<int32, [\($0.1)]>([\(resize($0.2))])"
                    })
            }
        }
        guard made == 2 else { throw CocoaError(.fileReadCorruptFile) }
        return lines.joined(separator: "\n")
    }

    /// coremldata.bin: a header holding the length of the model description (a protobuf) at
    /// 0x4b, the description, a trailer. The input's and output's shapes change.
    func description(_ data: Data, frames: Int) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 0x53 else { throw CocoaError(.fileReadCorruptFile) }
        let length = bytes[0x4b..<0x53].reversed().reduce(0) { $0 << 8 | Int($1) }
        guard length >= 0, length <= bytes.count - 0x53 else { throw CocoaError(.fileReadCorruptFile) }
        var description = Array(bytes[0x53..<0x53 + length])
        if graph == .v3Preprocessor {
            description = try Protobuf.shape(of: "audio_signal", in: description, to: [1, Self.samples(frames)])
            description = try Protobuf.shape(of: "mel", in: description, to: [1, Self.melBins, frames])
        } else {
            description = try Protobuf.shape(of: "mel", in: description, to: [1, Self.melBins, frames])
            description = try Protobuf.shape(of: "encoder", in: description, to: [1, 1024, Self.stages(frames).2])
        }
        let size = (0..<8).map { UInt8(truncatingIfNeeded: description.count >> (8 * $0)) }
        return Data(bytes[..<0x4b] + size + description + bytes[(0x53 + length)...])
    }
}

/// Just enough protobuf to change a feature's shape in a CoreML model description.
private enum Protobuf {
    typealias Field = (number: Int, wire: Int, payload: [UInt8])

    static func varint(_ value: Int) -> [UInt8] {
        var value = UInt64(value), bytes: [UInt8] = []
        repeat {
            bytes.append(UInt8(value & 0x7f) | (value > 0x7f ? 0x80 : 0))
            value >>= 7
        } while value > 0
        return bytes
    }

    static func fields(_ bytes: [UInt8]) throws -> [Field] {
        var fields: [Field] = [], i = 0
        func read() throws -> Int {
            var value = 0, shift = 0
            while true {
                guard i < bytes.count, shift < 63 else { throw CocoaError(.fileReadCorruptFile) }
                let byte = bytes[i]
                i += 1
                value |= Int(byte & 0x7f) << shift
                shift += 7
                if byte < 0x80 { return value }
            }
        }
        while i < bytes.count {
            let key = try read(), start = i
            let count: Int
            switch key & 7 {
            case 0: _ = try read(); count = i - start; i = start
            case 1: count = 8
            case 2: count = try read()
            case 5: count = 4
            default: throw CocoaError(.fileReadCorruptFile)
            }
            guard count >= 0, count <= bytes.count - i else { throw CocoaError(.fileReadCorruptFile) }
            fields.append((key >> 3, key & 7, Array(bytes[i..<i + count])))
            i += count
        }
        return fields
    }

    static func encode(_ field: Field) -> [UInt8] {
        varint(field.number << 3 | field.wire) + (field.wire == 2 ? varint(field.payload.count) : []) + field.payload
    }

    /// The description with input or output `name`'s array shape (FeatureDescription.type
    /// .multiArrayType.shape) set to `shape`.
    static func shape(of name: String, in description: [UInt8], to shape: [Int]) throws -> [UInt8] {
        func replace(_ bytes: [UInt8], path: ArraySlice<Int>) throws -> [UInt8] {
            try fields(bytes).flatMap { field -> [UInt8] in
                guard field.number == path.first, field.wire == 2 else { return encode(field) }
                let payload = path.count == 1 ? shape.flatMap(varint) : try replace(field.payload, path: path.dropFirst())
                return encode((field.number, 2, payload))
            }
        }
        return try fields(description).flatMap { field -> [UInt8] in
            // ModelDescription.input = 1, .output = 10; FeatureDescription.name = 1.
            guard [1, 10].contains(field.number), field.wire == 2,
                try fields(field.payload).first(where: { $0.number == 1 })?.payload == Array(name.utf8)
            else { return encode(field) }
            return encode((field.number, 2, try replace(field.payload, path: [3, 5, 1])))
        }
    }
}
