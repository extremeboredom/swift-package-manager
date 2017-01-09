/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import XCTest

import Basic
import PackageDescription
import PackageModel

import func POSIX.getenv
import func POSIX.popen

import TestSupport

@testable import PackageLoading
@testable import Utility

class ManifestTests: XCTestCase {
    let manifestLoader = ManifestLoader(resources: Resources())

    private func loadManifest(_ inputName: String, line: UInt = #line, body: (Manifest) -> Void) {
        do {
            let input = AbsolutePath(#file).parentDirectory.appending(component: "Inputs").appending(component: inputName)
            body(try manifestLoader.loadFile(path: input, baseURL: input.parentDirectory.asString, version: nil))
        } catch {
            XCTFail("Unexpected error: \(error)", file: #file, line: line)
        }
    }

    private func loadManifest(_ contents: ByteString, baseURL: String? = nil) throws -> Manifest {
        let fs = InMemoryFileSystem()
        let manifestPath = AbsolutePath.root.appending(component: Manifest.filename)
        try fs.writeFileContents(manifestPath, bytes: contents)
        return try manifestLoader.loadFile(path: manifestPath, baseURL: baseURL ?? AbsolutePath.root.asString, version: nil, fileSystem: fs)
    }

    private func loadManifest(_ contents: ByteString, baseURL: String? = nil, line: UInt = #line, body: (Manifest) -> Void) {
        do {
            body(try loadManifest(contents, baseURL: baseURL))
        } catch {
            XCTFail("Unexpected error: \(error)", file: #file, line: line)
        }
    }

    func testManifestLoading() {
        // Check a trivial manifest.
        loadManifest("trivial-manifest.swift") { manifest in
            XCTAssertEqual(manifest.package.name, "Trivial")
            XCTAssertEqual(manifest.package.targets, [])
            XCTAssertEqual(manifest.package.dependencies, [])
        }

        // Check a manifest with package specifications.
        loadManifest("package-deps-manifest.swift") { manifest in
            XCTAssertEqual(manifest.package.name, "PackageDeps")
            XCTAssertEqual(manifest.package.targets, [])
            XCTAssertEqual(manifest.package.dependencies, [Package.Dependency.Package(url: "https://example.com/example", majorVersion: 1)])
        }

        // Check a manifest with targets.
        loadManifest("target-deps-manifest.swift") { manifest in
            XCTAssertEqual(manifest.package.name, "TargetDeps")
            XCTAssertEqual(manifest.package.targets, [
                Target(
                    name: "sys",
                    dependencies: [.Target(name: "libc")]),
                Target(
                    name: "dep",
                    dependencies: [.Target(name: "sys"), .Target(name: "libc")])])
        }

        // Check loading a manifest from a file system.
        let trivialManifest = ByteString(encodingAsUTF8: (
                "import PackageDescription\n" +
                "let package = Package(name: \"Trivial\")"))
        loadManifest(trivialManifest) { manifest in
            XCTAssertEqual(manifest.package.name, "Trivial")
            XCTAssertEqual(manifest.package.targets, [])
            XCTAssertEqual(manifest.package.dependencies, [])
        }
    }

    func testNoManifest() {
        XCTAssertThrows(PackageModel.Package.Error.noManifest(baseURL: "/foo", version: nil)) {
            _ = try manifestLoader.loadFile(path: AbsolutePath("/non-existent-file"), baseURL: "/foo", version: nil)
        }

        XCTAssertThrows(PackageModel.Package.Error.noManifest(baseURL: "/bar", version: "1.0.0")) {
            _ = try manifestLoader.loadFile(path: AbsolutePath("/non-existent-file"), baseURL: "/bar", version: "1.0.0", fileSystem: InMemoryFileSystem())
        }
    }

    func testNonexistentBaseURL() {
        let trivialManifest = ByteString(encodingAsUTF8: (
                "import PackageDescription\n" +
                "let package = Package(name: \"Trivial\")"))
        loadManifest(trivialManifest, baseURL: "/non-existent-path") { manifest in
            XCTAssertEqual(manifest.package.name, "Trivial")
            XCTAssertEqual(manifest.package.targets, [])
            XCTAssertEqual(manifest.package.dependencies, [])
        }
    }

    func testInvalidTargetName() {
        fixture(name: "Miscellaneous/PackageWithInvalidTargets") { (prefix: AbsolutePath) in
            do {
                let manifest = try manifestLoader.loadFile(path: prefix.appending(component: "Package.swift"), baseURL: prefix.asString, version: nil)
                _ = try PackageBuilder(manifest: manifest, path: prefix, dependencies: []).construct(includingTestModules: false)
            } catch ModuleError.modulesNotFound(let moduleNames) {
                XCTAssertEqual(Set(moduleNames), Set(["Bake", "Fake"]))
            } catch {
                XCTFail("Failed with error: \(error)")
            }
        }
    }

    /// Check that we load the manifest appropriate for the current version, if
    /// version specific customization is used.
    func testVersionSpecificLoading() throws {
        let bogusManifest: ByteString = "THIS WILL NOT PARSE"
        let trivialManifest = ByteString(encodingAsUTF8: (
                "import PackageDescription\n" +
                "let package = Package(name: \"Trivial\")"))

        // Check at each possible spelling.
        let currentVersion = Versioning.currentVersion
        let possibleSuffixes = [
            "\(currentVersion.major).\(currentVersion.minor).\(currentVersion.patch)",
            "\(currentVersion.major).\(currentVersion.minor)",
            "\(currentVersion.major)"
        ]
        for (i, key) in possibleSuffixes.enumerated() {
            let root = AbsolutePath.root
            // Create a temporary FS with the version we want to test, and everything else as bogus.
            let fs = InMemoryFileSystem()
            // Write the good manifests.
            try fs.writeFileContents(
                root.appending(component: Manifest.basename + "@swift-\(key).swift"),
                bytes: trivialManifest)
            // Write the bad manifests.
            let badManifests = [Manifest.filename] + possibleSuffixes[i+1 ..< possibleSuffixes.count].map{
                Manifest.basename + "@swift-\($0).swift"
            }
            try badManifests.forEach {
                try fs.writeFileContents(
                    root.appending(component: $0),
                    bytes: bogusManifest)
            }
            // Check we can load the repository.
            let manifest = try manifestLoader.load(packagePath: root, baseURL: root.asString, version: nil, fileSystem: fs)
            XCTAssertEqual(manifest.name, "Trivial")
        }
    }

    func testEmptyManifest() throws {
        do {
            let stream = BufferedOutputByteStream()
            stream <<< "import PackageDescription" <<< "\n"
            let manifest = try loadManifest(stream.bytes)
            XCTFail("Unexpected success \(manifest)")
        } catch ManifestParseError.emptyManifestFile {}

        do {
            let manifest = try loadManifest("")
            XCTFail("Unexpected success \(manifest)")
        } catch ManifestParseError.emptyManifestFile {}
    }

    func testRuntimeManifestErrors() throws {
        let stream = BufferedOutputByteStream()
        stream <<< "import PackageDescription" <<< "\n"
        stream <<< "let package = Package(" <<< "\n"
        stream <<< "   name: \"Foo\"," <<< "\n"
        stream <<< "           dependencies: [" <<< "\n"
        stream <<< "              .Package(url: \"/url\", \"1.0,0\")" <<< "\n"
        stream <<< "           ])" <<< "\n" <<< "\n"

        do {
            let manifest = try loadManifest(stream.bytes)
            XCTFail("Unexpected success \(manifest)")
        } catch ManifestParseError.runtimeManifestErrors(let errors) {
            XCTAssertEqual(errors, ["Invalid version string: 1.0,0"])
        }
    }

    func testProducts() throws {
        let stream = BufferedOutputByteStream()
        stream <<< "import PackageDescription" <<< "\n"
        stream <<< "let package = Package(" <<< "\n"
        stream <<< "    name: \"Foo\"," <<< "\n"
        stream <<< "    products: [" <<< "\n"
        stream <<< "    .Library(name: \"libfooA\", targets: [\"Foo\"])," <<< "\n"
        stream <<< "    .Library(name: \"libfooS\", type: .static, targets: [\"Foo\"])," <<< "\n"
        stream <<< "    .Library(name: \"libfooD\", type: .dynamic, targets: [\"Foo\"])," <<< "\n"
        stream <<< "    .Executable(name: \"exe\", targets: [\"Bar\"])," <<< "\n"
        stream <<< "    ])" <<< "\n" <<< "\n"

        let manifest = try loadManifest(stream.bytes)
        let products = Dictionary(items: manifest.package.products.map{ ($0.name, $0) })

        XCTAssertEqual(products["libfooA"], .Library(name: "libfooA", targets: ["Foo"]))
        XCTAssertEqual(products["libfooS"], .Library(name: "libfooS", type: .static, targets: ["Foo"]))
        XCTAssertEqual(products["libfooD"], .Library(name: "libfooD", type: .dynamic, targets: ["Foo"]))
        XCTAssertEqual(products["exe"], .Executable(name: "exe", targets: ["Bar"]))
    }

    func testSwiftInterpreterErrors() throws {
        // Forgot importing package description.
        var stream = BufferedOutputByteStream()
        stream <<< "let package = Package(" <<< "\n"
        stream <<< "   name: \"Foo\")"

        assertManifestContainsError(error: "use of unresolved identifier 'Package'", stream: stream)

        // Missing name in package object.
        stream = BufferedOutputByteStream()
        stream <<< "import PackageDescription" <<< "\n"
        stream <<< "let package = Package()" <<< "\n"

        assertManifestContainsError(error: "missing argument for parameter 'name' in call", stream: stream)

        // Random syntax error.
        stream = BufferedOutputByteStream()
        stream <<< "import PackageDescription" <<< "\n"
        stream <<< "let package = Package(name: \"foo\")'" <<< "\n"

        assertManifestContainsError(error: "error: unterminated string literal", stream: stream)
    }

    /// Helper to check for swift interpreter errors while loading manifest.
    private func assertManifestContainsError(error: String, stream: BufferedOutputByteStream, file: StaticString = #file, line: UInt = #line) {
        do {
            let manifest = try loadManifest(stream.bytes)
            XCTFail("Unexpected success \(manifest)", file: file, line: line)
        } catch ManifestParseError.invalidManifestFormat(let errors) {
            XCTAssertTrue(errors.contains(error), "\nActual:\n\(errors) \n\nExpected: \(error)", file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }
    
    static var allTests = [
        ("testEmptyManifest", testEmptyManifest),
        ("testManifestLoading", testManifestLoading),
        ("testNoManifest", testNoManifest),
        ("testNonexistentBaseURL", testNonexistentBaseURL),
        ("testInvalidTargetName", testInvalidTargetName),
        ("testVersionSpecificLoading", testVersionSpecificLoading),
        ("testRuntimeManifestErrors", testRuntimeManifestErrors),
        ("testSwiftInterpreterErrors", testSwiftInterpreterErrors),
    ]
}
