import CryptoKit
import Foundation
import Synchronization
import os

/// The speech models, downloaded when the user picks one (in the walkthrough or Settings › Models)
/// rather than shipped in the app, so each can be removed. Both are FluidAudio's Core ML conversions of
/// NVIDIA Parakeet, pinned to a Hugging Face revision and checked file by file against SHA-256 sums
/// taken from it (`scripts/speech-model-manifest.py` prints them for a new revision).
@MainActor @Observable
final class SpeechModels {
    enum Kind: String, CaseIterable, Codable, Identifiable {
        case english, multilingual

        var id: String { rawValue }

        var name: String {
            switch self {
            case .english: "English"
            case .multilingual: "Multilingual"
            }
        }

        var modelName: String {
            switch self {
            case .english: "Parakeet Unified 0.6B"
            case .multilingual: "Parakeet v3 0.6B"
            }
        }

        /// Parakeet v3's languages (NVIDIA's model card).
        static let multilingualLanguages = [
            "Bulgarian", "Croatian", "Czech", "Danish", "Dutch", "English", "Estonian", "Finnish", "French", "German",
            "Greek", "Hungarian", "Italian", "Latvian", "Lithuanian", "Maltese", "Polish", "Portuguese", "Romanian",
            "Russian", "Slovak", "Slovenian", "Spanish", "Swedish", "Ukrainian",
        ]
        /// The same, as language codes, to suggest the model to people whose Mac uses one of them.
        static let multilingualCodes: Set<String> = [
            "bg", "hr", "cs", "da", "nl", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro",
            "ru", "sk", "sl", "es", "sv", "uk",
        ]

        /// Multilingual when the Mac's languages include one of v3's besides English.
        static var suggested: Kind {
            let codes = Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
            return codes.contains(where: multilingualCodes.contains) ? .multilingual : .english
        }

        /// Cleanup's model (S1-mini) was trained on English only.
        var supportsCleanup: Bool { self == .english }

        nonisolated var directory: URL { AppFolder.models.appending(path: folder, directoryHint: .isDirectory) }

        /// FluidAudio's folder names for the same models.
        fileprivate nonisolated var folder: String {
            switch self {
            case .english: "parakeet-unified-en-0.6b"
            case .multilingual: "parakeet-tdt-0.6b-v3"
            }
        }

        fileprivate nonisolated var source: URL {
            switch self {
            case .english:
                URL(string: "https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml/resolve/d32e972dd4315f1dc3f6be28fb2aab0ab3e80358/")!
            case .multilingual:
                URL(string: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/7dd20fe6b1797d35f5e3307e8b1732d9a178edfe/")!
            }
        }

        var size: Int64 { files.reduce(0) { $0 + $1.size } }

        fileprivate nonisolated var files: [File] {
            switch self {
            case .english: Self.englishFiles
            case .multilingual: Self.multilingualFiles
            }
        }

        private nonisolated static let englishFiles = [
            File("config.json", 1355, "6cbe6c76445410c5c6debf3d44c8c3b75e9966bf09bba5cd138c2378c62120f6"),
            File("metadata.json", 1046, "2b26a96b76fe1f7a04d3e867f50c75d6ce5dd1650d0dbcd4c35b591b22305f0e"),
            File("parakeet_unified_decoder.mlmodelc/analytics/coremldata.bin", 243, "9ae70f6559989f88b856b326e59315798f9f0d08207a19fcc2dd3287a30088a5"),
            File("parakeet_unified_decoder.mlmodelc/coremldata.bin", 560, "ce99c4488840fc463d59f8d4d6d2a9e8ceae8138ead51e3c265dde4d2ba4a0e9"),
            File("parakeet_unified_decoder.mlmodelc/model.mil", 13102, "6e60965b89c93943aa2be2d991c2461108145851fde05e1d048223a32d4cb20d"),
            File("parakeet_unified_decoder.mlmodelc/weights/weight.bin", 14429952, "96f990461a5986d5e7309ad1a0f36084fbf0f4b28aec35948f8b8d0dcbf8599e"),
            File("parakeet_unified_encoder_int8.mlmodelc/analytics/coremldata.bin", 243, "57e116a9d5765e39c0cdf754137ab744ddae34d9c6d68a5fdcad6600ae3a7b6b"),
            File("parakeet_unified_encoder_int8.mlmodelc/coremldata.bin", 492, "54f533d30343d5e62b324a0691e4c262a6768b07b6e88e7aa14c617a2baba8a3"),
            File("parakeet_unified_encoder_int8.mlmodelc/model.mil", 1110902, "c1c5d71c6cbf4d35bba08458746bde3640da7b1b444e1229a269393a58222c10"),
            File("parakeet_unified_encoder_int8.mlmodelc/weights/weight.bin", 595051904, "f984b81590a4deae041ae20fbab8981c2d2a5b528b2ac81fae81c432633535c6"),
            File("parakeet_unified_joint_decision_single_step.mlmodelc/analytics/coremldata.bin", 243, "163877ad14af97ec4107cd854fd1c6d336ee5d40ad25a657cc764fb763f452f5"),
            File("parakeet_unified_joint_decision_single_step.mlmodelc/coremldata.bin", 556, "68a081570a48b52ec9379e153bd56748a5408a50be16767601563f231eaeff03"),
            File("parakeet_unified_joint_decision_single_step.mlmodelc/model.mil", 9611, "03c21096090bcd0b71c896c5ae0eb815db31a91c6676f572a7868eee4299abe3"),
            File("parakeet_unified_joint_decision_single_step.mlmodelc/weights/weight.bin", 3446978, "06831afa6d1beb0c0b10350ebf7886bc37638e951d14e738d7e06fbd2a05012f"),
            File("vocab.json", 15088, "e1a7bff4f5df133c0f4ad47b8e43c96f6bf1865d99126a4c4725ef51d0108bec"),
        ]
        private nonisolated static let multilingualFiles = [
            File("Decoder.mlmodelc/analytics/coremldata.bin", 243, "4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350"),
            File("Decoder.mlmodelc/coremldata.bin", 554, "18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99"),
            File("Decoder.mlmodelc/metadata.json", 3427, "a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9"),
            File("Decoder.mlmodelc/model.mil", 13110, "ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35"),
            File("Decoder.mlmodelc/weights/weight.bin", 23604992, "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41"),
            File("Encoder.mlmodelc/analytics/coremldata.bin", 243, "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
            File("Encoder.mlmodelc/coremldata.bin", 485, "d48034a167a82e88fc3df64f60af963ab3983538271175b8319e7d5720a0fb86"),
            File("Encoder.mlmodelc/metadata.json", 2921, "da24da9cca943fb29d7fa8e376d57fca7cb3aa08ca51b956b0b0e56813f087e9"),
            File("Encoder.mlmodelc/model.mil", 959769, "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
            File("Encoder.mlmodelc/weights/weight.bin", 445187200, "e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421"),
            File("JointDecisionv3.mlmodelc/analytics/coremldata.bin", 243, "26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c"),
            File("JointDecisionv3.mlmodelc/coremldata.bin", 521, "f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342"),
            File("JointDecisionv3.mlmodelc/metadata.json", 3453, "d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f"),
            File("JointDecisionv3.mlmodelc/model.mil", 11775, "be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d"),
            File("JointDecisionv3.mlmodelc/weights/weight.bin", 12642764, "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e"),
            File("Preprocessor.mlmodelc/analytics/coremldata.bin", 243, "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
            File("Preprocessor.mlmodelc/coremldata.bin", 486, "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
            File("Preprocessor.mlmodelc/metadata.json", 2841, "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
            File("Preprocessor.mlmodelc/model.mil", 28181, "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
            File("Preprocessor.mlmodelc/weights/weight.bin", 491072, "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
            File("config.json", 475, "97f19ecccd0fdc730d76fb918090fa8bc64bce8ea4ad43715d5e9c2c7350db66"),
            File("parakeet_v3_vocab.json", 151122, "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
            File("parakeet_vocab.json", 151122, "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
        ]
    }

    fileprivate struct File: Sendable {
        let path: String
        let size: Int64
        let sha256: String

        init(_ path: String, _ size: Int64, _ sha256: String) {
            (self.path, self.size, self.sha256) = (path, size, sha256)
        }
    }

    enum State: Equatable {
        case absent
        case downloading(Double)
        case installed
        case failed(String)
    }

    private(set) var states: [Kind: State] = [:]
    /// Called when a download finishes, to switch to the model the user just fetched.
    @ObservationIgnored var onInstalled: ((Kind) -> Void)?
    @ObservationIgnored private var downloads: [Kind: Task<Void, Never>] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "io.github.snaeppi.localflow", category: "speech-model")

    init() {
        refresh()
    }

    func state(_ kind: Kind) -> State { states[kind] ?? .absent }

    func isInstalled(_ kind: Kind) -> Bool { state(kind) == .installed }

    var installed: [Kind] { Kind.allCases.filter(isInstalled) }

    /// Re-reads what's on disk (after the app folder moved, or files were deleted by hand). A model counts
    /// as installed when all its files are there at their sizes; their contents were checked at download.
    func refresh() {
        for kind in Kind.allCases where downloads[kind] == nil {
            if Self.isComplete(kind) {
                states[kind] = .installed
            } else if case .failed = state(kind) {
                continue  // Keeps its message until the user tries again.
            } else {
                states[kind] = .absent
            }
        }
    }

    func install(_ kind: Kind) {
        guard downloads[kind] == nil, !isInstalled(kind) else { return }
        states[kind] = .downloading(0)
        downloads[kind] = Task {
            defer { downloads[kind] = nil }
            do {
                let t0 = ContinuousClock.now
                try await Self.download(kind) { [weak self] fraction in
                    guard let self, case .downloading = self.state(kind) else { return }
                    self.states[kind] = .downloading(fraction)
                }
                states[kind] = .installed
                log.info("Speech model \(kind.rawValue, privacy: .public) installed in \((ContinuousClock.now - t0).milliseconds, privacy: .public) ms")
                onInstalled?(kind)
            } catch is CancellationError {
                cancelled(kind)
            } catch let error as URLError where error.code == .cancelled {
                cancelled(kind)
            } catch {
                // What was fetched stays in the partial folder, so trying again resumes.
                log.error("Speech model download failed: \(error.localizedDescription, privacy: .public)")
                states[kind] = .failed(error.localizedDescription)
            }
        }
    }

    private func cancelled(_ kind: Kind) {
        states[kind] = .absent
        try? FileManager.default.removeItem(at: Self.partial(kind))
    }

    func cancel(_ kind: Kind) {
        downloads[kind]?.cancel()
    }

    /// Deletes a model. The last one stays: Localflow can't dictate without one.
    func remove(_ kind: Kind) {
        guard installed.count > 1 || !isInstalled(kind) else { return }
        cancel(kind)
        try? FileManager.default.removeItem(at: kind.directory)
        states[kind] = .absent
    }

    // MARK: Download

    private enum Failure: LocalizedError {
        case noSpace(Int64), checksum
        var errorDescription: String? {
            switch self {
            case .noSpace(let size):
                "Not enough disk space (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) needed)"
            case .checksum: "Download was corrupted; try again"
            }
        }
    }

    private nonisolated static func partial(_ kind: Kind) -> URL {
        AppFolder.models.appending(path: kind.folder + ".partial", directoryHint: .isDirectory)
    }

    private nonisolated static func isComplete(_ kind: Kind) -> Bool {
        kind.files.allSatisfy { file in
            let path = kind.directory.appending(path: file.path).path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return (attributes?[.size] as? NSNumber)?.int64Value == file.size
        }
    }

    /// Fetches every file into a partial folder, checks it, and moves the folder into place when all are
    /// there. Files an earlier, failed attempt fetched are kept if they check out.
    private static func download(_ kind: Kind, progress: @escaping @MainActor (Double) -> Void) async throws {
        let partial = partial(kind)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        let free = try partial.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? .max
        guard free >= kind.size else { throw Failure.noSpace(kind.size) }
        var done: Int64 = 0
        for file in kind.files {
            try Task.checkCancellation()
            let target = partial.appending(path: file.path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if try await Self.verified(target, file) == false {
                let completed = done
                _ = try await ModelDownload.file(
                    from: kind.source.appending(path: file.path), to: target, expectedSize: file.size
                ) { fraction in
                    let overall = Double(completed) + fraction * Double(file.size)
                    Task { @MainActor in progress(overall / Double(kind.size)) }
                }
                guard try await Self.verified(target, file) else { throw Failure.checksum }
            }
            done += file.size
            progress(Double(done) / Double(kind.size))
        }
        try? FileManager.default.removeItem(at: kind.directory)
        try FileManager.default.moveItem(at: partial, to: kind.directory)
    }

    /// Hashing the 0.6 GB encoder takes about a second: off the main thread.
    private nonisolated static func verified(_ url: URL, _ file: File) async throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return try await Task.detached(priority: .userInitiated) {
            try ModelDownload.sha256(of: url) == file.sha256
        }.value
    }
}

/// Downloads for the models: one file at a time over an ephemeral session (no cookies, credentials or
/// cache on disk), and the SHA-256 they're checked against.
enum ModelDownload {
    static func file(
        from url: URL, to destination: URL, expectedSize: Int64, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        let delegate = DownloadDelegate(destination: destination, expectedSize: expectedSize, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.attach(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Reports download progress and moves the finished file into place (URLSession deletes its
/// temporary file as soon as the delegate call returns).
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let destination: URL
    let expectedSize: Int64
    let progress: @Sendable (Double) -> Void
    /// The waiting caller and the outcome, whichever arrives first waits for the other: a task
    /// cancelled before it started can complete before the continuation is attached.
    private let completion = Mutex<(continuation: CheckedContinuation<URL, Error>?, result: Result<URL, Error>?)>((nil, nil))
    private let moved = Mutex<Result<URL, Error>?>(nil)
    private let reported = Mutex<Double>(0)

    init(destination: URL, expectedSize: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
        totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64
    ) {
        let fraction = Double(written) / Double(expected > 0 ? expected : expectedSize)
        // Called every few kilobytes; Settings only needs every half percent.
        guard reported.withLock({ last in
            guard fraction - last >= 0.005 else { return false }
            last = fraction
            return true
        }) else { return }
        progress(fraction)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let result: Result<URL, Error>
        if status == 200 {
            result = Result {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                return destination
            }
        } else {
            result = .failure(DownloadError.http(status))
        }
        moved.withLock { $0 = result }
    }

    func attach(_ continuation: CheckedContinuation<URL, Error>) {
        completion.withLock { state in
            if let result = state.result {
                continuation.resume(with: result)
            } else {
                state.continuation = continuation
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = error.map { Result<URL, Error>.failure($0) } ?? moved.withLock { $0 } ?? .failure(URLError(.unknown))
        completion.withLock { state in
            if let continuation = state.continuation {
                continuation.resume(with: result)
                state.continuation = nil
            } else {
                state.result = result
            }
        }
    }

    private enum DownloadError: LocalizedError {
        case http(Int)
        var errorDescription: String? {
            if case .http(let status) = self { return "Download failed (HTTP \(status))" }
            return nil
        }
    }
}
