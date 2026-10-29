import Foundation
import LocalflowEngine
import os

/// The cleanup model on disk. It is not bundled: it is downloaded only when the user turns cleanup
/// on — besides the speech model, Localflow's only download — from a pinned Hugging Face revision, checked against
/// its SHA-256, and converted once into the engine's format (int8, Hadamard-rotated; see
/// Sources/LocalflowEngine/convert.c), which Rewriter uses straight from the memory-mapped file. The
/// F16 download is deleted afterwards.
@MainActor @Observable
final class RewriteModel {
    enum State: Equatable {
        case absent
        case downloading(Double)
        case preparing
        case installed
        case failed(String)
    }

    nonisolated static let name = "S1-mini by Superwhisper"
    nonisolated static let licenseURL = URL(string: "https://huggingface.co/superwhisper/s1-mini/blob/main/LICENSE")!
    private nonisolated static let source = URL(string: "https://huggingface.co/superwhisper/s1-mini-GGUF/resolve/34add00a48a2e5d24e5a4ee5405a99620a3a240c/s1-mini-f16.gguf")!
    private nonisolated static let sourceSHA256 = "0370da4f1bae19e3150bcafa33c5d396c15f97bf25519540a3e013db5cc00af4"
    private static let sourceSize: Int64 = 1_509_347_232
    /// The F16 download plus the converted file (0.92 GB), which exist side by side for a moment.
    private static let requiredSpace: Int64 = 2_500_000_000

    /// In the app folder, so it moves with it (Advanced settings › App folder location).
    nonisolated static var directory: URL { AppFolder.models }
    /// The number is the engine's file format (LF_FORMAT in Sources/LocalflowEngine/internal.h): a
    /// new format is a new file, downloaded and converted again.
    nonisolated static var file: URL { directory.appendingPathComponent("s1-mini-2.gguf") }
    private nonisolated static var partialDownload: URL { directory.appendingPathComponent("s1-mini-f16.gguf.download") }

    private(set) var state: State
    @ObservationIgnored private var installation: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "io.github.snaeppi.localflow", category: "rewrite")

    init() {
        state = FileManager.default.fileExists(atPath: Self.file.path) ? .installed : .absent
        // Leftovers of an install that was interrupted by quitting (up to 2.4 GB).
        for leftover in [Self.partialDownload, Self.file.appendingPathExtension("partial")] {
            try? FileManager.default.removeItem(at: leftover)
        }
    }

    var isInstalled: Bool { state == .installed }

    /// After the app folder moved: the model may be there or not.
    func refresh() {
        guard installation == nil else { return }
        state = FileManager.default.fileExists(atPath: Self.file.path) ? .installed : .absent
    }

    /// Size of the installed model, for Settings.
    var installedSize: Int64? {
        (try? FileManager.default.attributesOfItem(atPath: Self.file.path)[.size] as? NSNumber)?.int64Value
    }

    func install() {
        guard installation == nil, state != .installed else { return }
        state = .downloading(0)
        installation = Task {
            defer { installation = nil }
            do {
                try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                let free = try Self.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage ?? .max
                guard free >= Self.requiredSpace else { throw Failure.noSpace }
                let t0 = ContinuousClock.now
                let download = try await Self.download { [weak self] fraction in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(fraction)
                }
                state = .preparing
                log.info("Cleanup model downloaded in \((ContinuousClock.now - t0).milliseconds, privacy: .public) ms")
                try await Self.prepare(download)
                state = .installed
                log.info("Cleanup model installed")
            } catch is CancellationError {
                state = .absent
            } catch let error as URLError where error.code == .cancelled {
                state = .absent
            } catch {
                log.error("Cleanup model install failed: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        installation?.cancel()
    }

    func remove() {
        cancel()
        try? FileManager.default.removeItem(at: Self.file)
        state = .absent
    }

    /// The installed file didn't load (damaged); offer to download it again.
    func reportUnusable() {
        guard state == .installed else { return }
        state = .failed("Cleanup model is damaged")
    }

    // MARK: Steps

    private enum Failure: LocalizedError {
        case noSpace, checksum, conversion
        var errorDescription: String? {
            switch self {
            case .noSpace: "Not enough disk space (2.5 GB needed)"
            case .checksum: "Download was corrupted; try again"
            case .conversion: "Could not prepare the model"
            }
        }
    }

    private static func download(progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        try await ModelDownload.file(from: source, to: partialDownload, expectedSize: sourceSize) { fraction in
            Task { @MainActor in progress(fraction) }
        }
    }

    /// Verifies the download and converts it, off the main thread (~2 s).
    private static func prepare(_ download: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: download) }
            guard try ModelDownload.sha256(of: download) == sourceSHA256 else { throw Failure.checksum }
            let partial = file.appendingPathExtension("partial")
            if let error = lf_convert(download.path, partial.path) {
                Logger(subsystem: "io.github.snaeppi.localflow", category: "rewrite")
                    .error("Cleanup model conversion failed: \(String(cString: error), privacy: .public)")
                throw Failure.conversion
            }
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: partial, to: file)
        }.value
    }
}
