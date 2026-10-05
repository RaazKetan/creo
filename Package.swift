// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Creo",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "creo", targets: ["Creo"])],
    targets: [
        .executableTarget(name: "Creo", path: "Sources/ClaudeSessions",
                          resources: [.process("Resources")])
    ]
)
