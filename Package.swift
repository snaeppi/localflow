// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Localflow",
    platforms: [.macOS(.v26)],
    products: [
        // The app's executable; scripts/build-app.sh wraps it into Localflow.app.
        .executable(name: "Localflow", targets: ["LocalflowApp"]),
        // Offline ASR benchmark harness (see bench/README.md); not part of the app.
        .executable(name: "localflow-bench", targets: ["LocalflowBench"]),
    ],
    dependencies: [
        // ASR/VAD only: opt out of FluidAudio's TTS, diarization and NeMo text-normalization traits.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
    ],
    targets: [
        .executableTarget(
            name: "LocalflowApp",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio"), "LocalflowEngine"],
            path: "Sources/LocalflowApp"
        ),
        .executableTarget(
            name: "LocalflowBench",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio"), "LocalflowEngine"],
            path: "Sources/LocalflowBench"
        ),
        // The optional transcript cleanup's model engine (Rewriter.swift) and the speech models' decoders
        // (ParakeetUnified.swift, ParakeetV3.swift): C, NEON and SME. Its sources build without clang modules: with them,
        // including <arm_sme.h> pulls in the SVE module, which Apple's cores (SVE only in streaming
        // mode) don't have. Swift still imports its header.
        .target(
            name: "LocalflowEngine",
            path: "Sources/LocalflowEngine",
            cSettings: [.unsafeFlags(["-fno-modules"]), .define("ACCELERATE_NEW_LAPACK")],
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
    ]
)
