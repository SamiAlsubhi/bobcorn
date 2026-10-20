// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Bobcorn",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Bobcorn", targets: ["Bobcorn"]),
        .executable(name: "bobcorn-torrent", targets: ["TorrentCLI"]),
        .library(name: "TorrentKit", targets: ["TorrentKit"]),
    ],
    targets: [
        .target(name: "TorrentKit"),
        .target(name: "Remux"),
        .target(name: "CastKit"),
        .executableTarget(name: "Bobcorn", dependencies: ["TorrentKit", "Remux", "CastKit"]),
        .executableTarget(name: "TorrentCLI", dependencies: ["TorrentKit"]),
        .testTarget(name: "TorrentKitTests", dependencies: ["TorrentKit"]),
        .testTarget(name: "BobcornTests", dependencies: ["Bobcorn", "TorrentKit"]),
        .testTarget(name: "RemuxTests", dependencies: ["Remux"]),
        .testTarget(name: "CastKitTests", dependencies: ["CastKit"]),
    ]
)
