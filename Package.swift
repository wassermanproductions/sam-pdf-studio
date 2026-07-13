// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SamPDFStudio",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SamPDFStudio", targets: ["SamPDFStudio"])
    ],
    targets: [
        .executableTarget(
            name: "SamPDFStudio",
            path: "Sources/SamPDFStudio"
        )
    ]
)
