import Darwin
import Foundation
import XCTest
@testable import AgentBridgeCore

final class BoundedDescriptorFileReaderTests: XCTestCase {
    func testReadsAndDecodesValidDescriptorJSON() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("descriptor.json")
        let source = Data(#"{"id":"example.skill","kind":"skill","name":"Example","version":"1.0","summary":"Inert metadata","requestedPermissions":[]}"#.utf8)
        try source.write(to: file)

        let loaded = try BoundedDescriptorFileReader.read(at: file)
        let descriptor = try JSONDecoder().decode(ExtensionDescriptor.self, from: loaded)
        XCTAssertEqual(loaded, source)
        XCTAssertEqual(descriptor.id, "example.skill")
        XCTAssertEqual(descriptor.kind, .skill)
    }

    func testAcceptsDescriptorExactlyAtMaximumSize() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("maximum.json")
        var source = Data(#"{"id":"max.skill","kind":"skill","name":"Maximum","version":"1","summary":"","requestedPermissions":[]}"#.utf8)
        source.append(Data(repeating: 0x20, count: BoundedDescriptorFileReader.maximumDescriptorSize - source.count))
        try source.write(to: file)

        let loaded = try BoundedDescriptorFileReader.read(at: file)
        let descriptor = try JSONDecoder().decode(ExtensionDescriptor.self, from: loaded)
        XCTAssertEqual(loaded.count, BoundedDescriptorFileReader.maximumDescriptorSize)
        XCTAssertEqual(descriptor.id, "max.skill")
    }

    func testRejectsOversizedFilesAndCallerBoundsBeyondThePolicyLimit() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oversized = root.appendingPathComponent("oversized.json")
        try Data(repeating: 0x20, count: BoundedDescriptorFileReader.maximumDescriptorSize + 1).write(to: oversized)

        XCTAssertThrowsError(try BoundedDescriptorFileReader.read(at: oversized))
        XCTAssertThrowsError(try BoundedDescriptorFileReader.read(at: oversized, maximumBytes: 32))
        XCTAssertThrowsError(try BoundedDescriptorFileReader.read(at: oversized, maximumBytes: -1))
        XCTAssertThrowsError(try BoundedDescriptorFileReader.read(
            at: oversized,
            maximumBytes: BoundedDescriptorFileReader.maximumDescriptorSize + 1
        ))
    }

    func testRejectsSymlinksDirectoriesAndNamedPipesWithoutReadingThem() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)

        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let directory = root.appendingPathComponent("directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let pipe = root.appendingPathComponent("pipe")
        let pipeStatus = pipe.path.withCString { mkfifo($0, mode_t(0o600)) }
        XCTAssertEqual(pipeStatus, 0)

        XCTAssertThrowsError(try BoundedDescriptorFileReader.read(at: link))
        XCTAssertThrowsError(try BoundedDescriptorFileReader.read(at: directory))
        XCTAssertThrowsError(try BoundedDescriptorFileReader.read(at: pipe))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBridge-DescriptorReader-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
