import Foundation
import XCTest
@testable import OpenAva

final class FileSystemServiceTests: XCTestCase {
    private var workspaceURL: URL!
    private var service: FileSystemService!

    override func setUpWithError() throws {
        workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileSystemServiceTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        service = FileSystemService(baseDirectoryURL: workspaceURL)
        try createFixtureTree()
    }

    override func tearDownWithError() throws {
        if let workspaceURL {
            try? FileManager.default.removeItem(at: workspaceURL)
        }
        workspaceURL = nil
        service = nil
    }

    func testFindFilesMatchesBasenameRecursively() async throws {
        let result = try await service.findFiles(glob: "*.swift")

        XCTAssertEqual(relativePaths(from: result.items), [
            "root.swift",
            "Sources/App/main.swift",
            "Sources/Feature/View.swift",
            "Sources/root.swift",
            "Tests/AppTests.swift",
        ])
    }

    func testFindFilesSupportsPathAwareDoubleStar() async throws {
        let result = try await service.findFiles(glob: "Sources/**/*.swift")

        XCTAssertEqual(relativePaths(from: result.items), [
            "Sources/App/main.swift",
            "Sources/Feature/View.swift",
            "Sources/root.swift",
        ])
    }

    func testFindFilesSupportsBraceExpansion() async throws {
        let result = try await service.findFiles(glob: "*.{swift,md}")

        XCTAssertEqual(relativePaths(from: result.items), [
            "README.md",
            "root.swift",
            "Sources/App/main.swift",
            "Sources/Feature/View.swift",
            "Sources/root.swift",
            "Tests/AppTests.swift",
        ])
    }

    func testFindFilesHonorsNonRecursiveSearch() async throws {
        let result = try await service.findFiles(glob: "*.swift", recursive: false)

        XCTAssertEqual(relativePaths(from: result.items), ["root.swift"])
    }

    private func createFixtureTree() throws {
        try writeFile("root.swift")
        try writeFile("README.md")
        try writeFile("Sources/root.swift")
        try writeFile("Sources/App/main.swift")
        try writeFile("Sources/App/helper.ts")
        try writeFile("Sources/Feature/View.swift")
        try writeFile("Tests/AppTests.swift")
    }

    private func writeFile(_ relativePath: String, content: String = "fixture") throws {
        let fileURL = workspaceURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func relativePaths(from items: [DirectoryItem]) -> [String] {
        items.map { item in
            let itemURL = URL(fileURLWithPath: item.path).standardizedFileURL
            let basePath = workspaceURL.standardizedFileURL.path + "/"
            return String(itemURL.path.dropFirst(basePath.count))
        }
    }
}
