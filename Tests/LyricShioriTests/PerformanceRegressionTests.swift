import AppKit
import CoreText
import Darwin
import Foundation
import Network
import XCTest
@testable import LyricShiori

final class PerformanceRegressionTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func entry() -> SharedLyricsCache.Entry {
        .init(kind: .enhanced, trackUri: "spotify:track:test", cachedAt: 1, expiresAt: Int64(Date().timeIntervalSince1970 * 1_000) + 10_000,
              lines: [.init(time: 0, text: "歌詞", words: nil)], cacheSource: .manual)
    }

    func testCacheRejectsOverflowAndInvalidTimingsWithoutTrapping() throws {
        let cache = SharedLyricsCache(url: try directory().appendingPathComponent("cache.json"))
        var value = entry()
        value.cachedAt = .min
        value.expiresAt = .max
        if case .rejected = try cache.save(value) {} else { XCTFail("Overflow accepted") }
        value.cachedAt = Int64(Date().timeIntervalSince1970 * 1_000)
        value.expiresAt = value.cachedAt + 10_000
        for time in [Double.nan, .infinity, -.infinity, 1e100] {
            value.lines[0].time = time
            if case .rejected = try cache.save(value) {} else { XCTFail("Invalid timing accepted") }
        }
        value.lines[0].time = 1_000
        if case .saved = try cache.save(value) {} else { XCTFail("Valid entry rejected") }
    }

    private func document(_ text: String) -> LyricsDocument {
        .init(metadata: .init(translationLanguages: []),
              lines: [.init(position: 1, content: text, translations: [:], wordTimings: [])],
              offsetMilliseconds: 0, needsPersist: false)
    }

    func testLocalCacheInvalidatesOnReplacementAndDeletion() throws {
        let storage = LocalLyricsStorage(baseDirectory: try directory())
        let track = TrackIdentity(id: "spotify:track:test", title: "Song", artist: "Artist")
        let url = try storage.save(document("旧歌词"), for: track)
        let first = try XCTUnwrap(storage.loadLyrics(for: track))
        let cached = try XCTUnwrap(storage.loadLyrics(for: track))
        XCTAssertEqual(first.id, cached.id, "Repeated loads should reuse parsed document")
        try LyricsCacheFile.encodedString(document: document("新歌词"), track: track).write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try storage.loadLyrics(for: track)?.lines.first?.content, "新歌词")
        try LyricsCacheFile.encodedString(document: document("再歌词"), track: track).write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(1)], ofItemAtPath: url.path)
        XCTAssertEqual(try storage.loadLyrics(for: track)?.lines.first?.content, "再歌词")
        var localizedTrack = track
        localizedTrack.title = "Localized song title"
        XCTAssertEqual(try storage.loadLyrics(for: localizedTrack)?.lines.first?.content, "再歌词")
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(try storage.loadLyrics(for: track))
    }

    func testLocalImportRejectsOversizedAndExtremeData() throws {
        let root = try directory()
        let storage = LocalLyricsStorage(baseDirectory: root)
        let url = root.appendingPathComponent("huge.lrcs")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: UInt64(LyricsResourceLimits.maximumFileBytes + 1))
        try file.close()
        XCTAssertThrowsError(try storage.importLyrics(from: url))
        var bad = document("bad")
        bad.lines[0].position = .infinity
        XCTAssertThrowsError(try storage.export(bad, to: url))
        bad.lines[0].position = 1e100
        XCTAssertThrowsError(try LyricsCacheFile(document: bad, track: nil))
        let content = LyricsCacheFile.encodedString(document: document("歌词"), track: nil)
            .replacingOccurrences(of: "\"startMilliseconds\" : 1000", with: "\"startMilliseconds\" : 9223372036854775807")
        XCTAssertThrowsError(try LyricsCacheFile.decode(content, sourceName: nil, localURL: nil, track: nil))
    }

    @MainActor
    func testVerticalRendererPreservesPixelsAndReusesFrames() throws {
        let optimized = WordVerticalLyricTextView()
        let original = ReferenceVerticalLyricTextView()
        var line = DesktopLyricsDisplayLine(id: "test", lineID: UUID(), text: "春の歌 ABC、春。", wordTimings: [
            .init(start: 1, duration: 3, text: "春の歌 ABC、春。")
        ], lineStart: 1, lineEnd: 5, playbackTime: 1, isPlaying: true, isActive: true, distanceFromActive: 0, progress: 0)
        for active in [true, false] {
            line.isActive = active
            for fontSize in [24.0, 42.0] {
                for alignment in [DesktopLyricsAlignment.left, .center, .right] {
                    for time in [1.0, 1.7, 3.8, 5.0] {
                        for view in [optimized, original] { view.frame = NSRect(x: 0, y: 0, width: 80, height: 360) }
                        optimized.configure(line: line, playbackTime: time, pendingColor: .gray, playedColor: .cyan, secondaryColor: .white, shadowColor: .black, fontSize: fontSize, alignment: alignment)
                        original.configure(line: line, playbackTime: time, pendingColor: .gray, playedColor: .cyan, secondaryColor: .white, shadowColor: .black, fontSize: fontSize, alignment: alignment)
                        let expected = try render(original)
                        let actual = try render(optimized)
                        XCTAssertTrue(actual.contains { $0 != 0 }, "Blank: active=\(active), size=\(fontSize), alignment=\(alignment), time=\(time)")
                        XCTAssertGreaterThan(optimized.frameBuildCount, 0)
                        XCTAssertEqual(actual, expected, "Pixels differ: active=\(active), size=\(fontSize), alignment=\(alignment), time=\(time)")
                        let builds = optimized.frameBuildCount
                        let layouts = optimized.layoutBuildCount
                        _ = try render(optimized)
                        XCTAssertEqual(optimized.frameBuildCount, builds)
                        XCTAssertEqual(optimized.layoutBuildCount, layouts)
                    }
                }
            }
        }
    }

    @MainActor
    func testVerticalPartialRedrawMatchesFullFramesThroughPlaybackAndSeeking() throws {
        let optimized = WordVerticalLyricTextView()
        let original = ReferenceVerticalLyricTextView()
        let text = "春の歌 ABC、春。星空に響く歌聲"
        var line = DesktopLyricsDisplayLine(id: "partial", lineID: UUID(), text: text,
            wordTimings: [.init(start: 1, duration: 8, text: text)], lineStart: 1, lineEnd: 10,
            playbackTime: 1, isPlaying: true, isActive: true, distanceFromActive: 0, progress: 0)
        for height in [1_000.0, 180.0] {
            for alignment in [DesktopLyricsAlignment.left, .center, .right] {
                for view in [optimized, original] { view.frame = NSRect(x: 0, y: 0, width: 80, height: height) }
                let bitmap = try makeBitmap(for: optimized)
                var first = true
                let times = [-1.0] + (0..<120).map { 1 + Double($0) / 60 } + [5.9, 9.5, 11, 2.4, 1.05]
                for time in times {
                    optimized.configure(line: line, playbackTime: time, pendingColor: .gray, playedColor: .cyan,
                        secondaryColor: .white, shadowColor: .black, fontSize: 24, alignment: alignment)
                    original.configure(line: line, playbackTime: time, pendingColor: .gray, playedColor: .cyan,
                        secondaryColor: .white, shadowColor: .black, fontSize: 24, alignment: alignment)
                    let dirty = first ? optimized.bounds : optimized.lastInvalidatedRect
                    if !dirty.isEmpty { _ = try render(optimized, into: bitmap, dirtyRect: dirty) }
                    first = false
                    let expected = try render(original)
                    let actual = Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
                    XCTAssertTrue(actual == expected, "Partial repaint changed pixels: height=\(height), alignment=\(alignment), time=\(time)")
                }
                // Promotion changes font weight and shadow; invalidate even if
                // the playback time itself has not changed.
                line.isActive = false
                optimized.configure(line: line, playbackTime: 1.05, pendingColor: .gray, playedColor: .cyan,
                    secondaryColor: .white, shadowColor: .black, fontSize: 24, alignment: alignment)
                original.configure(line: line, playbackTime: 1.05, pendingColor: .gray, playedColor: .cyan,
                    secondaryColor: .white, shadowColor: .black, fontSize: 24, alignment: alignment)
                XCTAssertEqual(optimized.lastInvalidatedRect, optimized.bounds)
                XCTAssertTrue(try render(optimized, into: bitmap, dirtyRect: optimized.lastInvalidatedRect) == render(original))
                line.isActive = true
            }
        }
    }

    @MainActor
    func testVerticalRendererSkipsStaticFramesAndRepaintsFewerWords() throws {
        let view = WordVerticalLyricTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 1_000))
        let text = "春の歌が星空に響いて遠い街まで届く"
        var line = DesktopLyricsDisplayLine(id: "static", lineID: UUID(), text: text,
            wordTimings: [.init(start: 1, duration: 10, text: text)], lineStart: 1, lineEnd: 12,
            playbackTime: 1, isPlaying: true, isActive: true, distanceFromActive: 0, progress: 0)
        func configure(_ time: Double, shadow: NSColor = .black) {
            view.configure(line: line, playbackTime: time, pendingColor: .gray, playedColor: .cyan,
                secondaryColor: .white, shadowColor: shadow, fontSize: 24, alignment: .center)
        }
        configure(-1)
        _ = try render(view)
        view.needsDisplay = false
        configure(0)
        XCTAssertTrue(view.lastInvalidatedRect.isEmpty, "No word or scroll position changed")
        configure(1.1)
        XCTAssertFalse(view.lastInvalidatedRect.isEmpty)
        let fullCount = view.unitDrawCount
        let bitmap = try makeBitmap(for: view)
        _ = try render(view, into: bitmap, dirtyRect: view.lastInvalidatedRect)
        XCTAssertLessThan(view.unitDrawCount - fullCount, fullCount, "Animation should not redraw the entire column")
        view.needsDisplay = false
        configure(1.1)
        XCTAssertTrue(view.lastInvalidatedRect.isEmpty)
        configure(1.1, shadow: .red)
        XCTAssertEqual(view.lastInvalidatedRect, view.bounds)
        configure(15)
        view.needsDisplay = false
        configure(16)
        XCTAssertTrue(view.lastInvalidatedRect.isEmpty, "Completed karaoke should remain static")
        line.isActive = false
        configure(2)
        view.needsDisplay = false
        configure(3)
        XCTAssertTrue(view.lastInvalidatedRect.isEmpty, "Upcoming columns have no per-word animation")
    }

    func testReusableAppleScriptRetainsCompiledStateAndSerializesExecutions() async throws {
        let script = ReusableAppleScript(source: """
        property invocationCount : 0
        set invocationCount to invocationCount + 1
        return invocationCount as string
        """)
        let started = Date()
        let values = try await withThrowingTaskGroup(of: ReusableAppleScript.Result.self) { group in
            for _ in 0..<12 { group.addTask { try await script.execute() } }
            var values: [Int] = []
            for try await result in group {
                values.append(try XCTUnwrap(Int(result.output)))
                XCTAssertGreaterThanOrEqual(result.capturedAt, started)
                XCTAssertLessThanOrEqual(result.capturedAt, Date())
            }
            return values.sorted()
        }
        XCTAssertEqual(values, Array(1...12))
        let result = try await script.execute()
        XCTAssertEqual(result.output, "13")
        let failing = ReusableAppleScript(source: "error \"expected failure\" number -1743")
        do { _ = try await failing.execute(); XCTFail("Script failure was ignored") }
        catch ServiceError.automationDenied {} // Preserve the existing TCC mapping.
    }

    @MainActor
    func testLayerBackedVerticalViewHonorsPartialInvalidation() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 1_000),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = WordVerticalLyricTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 1_000))
        view.wantsLayer = true
        window.contentView = view
        let text = "春の歌が星空に響いて遠い街まで届く"
        let line = DesktopLyricsDisplayLine(id: "backing", lineID: UUID(), text: text,
            wordTimings: [.init(start: 1, duration: 10, text: text)], lineStart: 1, lineEnd: 12,
            playbackTime: 1, isPlaying: true, isActive: true, distanceFromActive: 0, progress: 0)
        func configure(_ time: Double) {
            view.configure(line: line, playbackTime: time, pendingColor: .gray, playedColor: .cyan,
                secondaryColor: .white, shadowColor: .black, fontSize: 24, alignment: .center)
        }
        configure(0)
        view.displayIfNeeded()
        let fullCount = view.unitDrawCount
        XCTAssertGreaterThan(fullCount, 0, "AppKit must actually draw the backing store")
        configure(1.1)
        view.displayIfNeeded()
        let partialCount = view.unitDrawCount - fullCount
        XCTAssertGreaterThan(partialCount, 0)
        XCTAssertLessThan(partialCount, fullCount, "Layer backing must preserve partial repainting")
        configure(1.1)
        view.displayIfNeeded()
        XCTAssertEqual(view.unitDrawCount, fullCount + partialCount)
        print("Layer-backed vertical repaint: \(fullCount) units full, \(partialCount) units partial, 0 units unchanged")
    }

    @MainActor
    private func makeBitmap(for view: NSView) throws -> NSBitmapImageRep {
        let width = Int(view.bounds.width * 2)
        let height = Int(view.bounds.height * 2)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
        bitmap.size = view.bounds.size
        return bitmap
    }

    @MainActor
    private func render(_ view: NSView, into existingBitmap: NSBitmapImageRep? = nil, dirtyRect: NSRect? = nil) throws -> Data {
        let bitmap = try existingBitmap ?? makeBitmap(for: view)
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let dirty = dirtyRect ?? view.bounds
        graphics.cgContext.clear(dirty)
        view.draw(dirty)
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    func testBridgeTerminalConnectionsStopReceiving() async throws {
        let server = SharedLyricsCacheServer(cache: SharedLyricsCache(url: try directory().appendingPathComponent("cache.json")), port: .any, connectionTimeout: 0.25)
        server.start()
        defer { server.stop() }
        for _ in 0..<100 where server.listeningPort == nil { try await Task.sleep(for: .milliseconds(20)) }
        let port = try XCTUnwrap(server.listeningPort)
        for mode in 0..<3 {
            let fd = try connect(port)
            let partial = Array("POST /lyrics-cache HTTP/1.1\r\nContent-Length: 100\r\n\r\nx".utf8)
            XCTAssertEqual(partial.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }, partial.count)
            if mode == 0 { shutdown(fd, SHUT_WR) }
            if mode == 1 {
                var option = linger(l_onoff: 1, l_linger: 0)
                setsockopt(fd, SOL_SOCKET, SO_LINGER, &option, socklen_t(MemoryLayout<linger>.size))
                close(fd)
            }
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(server.activeConnectionCount, 0)
            let callbacks = server.receiveCallbackCount
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(server.receiveCallbackCount, callbacks, "Terminal receive loop in mode \(mode)")
            if mode != 1 { close(fd) }
        }
        let fd = try connect(port)
        defer { close(fd) }
        try await Task.sleep(for: .milliseconds(50))
        server.stop()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.activeConnectionCount, 0)
        let callbacks = server.receiveCallbackCount
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.receiveCallbackCount, callbacks)
    }

    func testBridgeServesFragmentedRequestAndBoundsConcurrentConnections() async throws {
        let server = SharedLyricsCacheServer(cache: SharedLyricsCache(url: try directory().appendingPathComponent("cache.json")), port: .any)
        server.start()
        defer { server.stop() }
        for _ in 0..<100 where server.listeningPort == nil { try await Task.sleep(for: .milliseconds(20)) }
        let port = try XCTUnwrap(server.listeningPort)
        let fd = try connect(port)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        for part in ["GET /bridge-session HTTP/1.1\r\n", "Host: localhost\r\n\r\n"] {
            let bytes = Array(part.utf8)
            XCTAssertEqual(bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }, bytes.count)
            try await Task.sleep(for: .milliseconds(20))
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let size = recv(fd, &buffer, buffer.count, 0)
            if size <= 0 { break }
            response.append(contentsOf: buffer.prefix(size))
        }
        close(fd)
        let text = try XCTUnwrap(String(data: response, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(text.contains("protocolVersion"))
        var sockets: [Int32] = []
        defer { sockets.forEach { close($0) } }
        for _ in 0..<40 { sockets.append(try connect(port)) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.activeConnectionCount, 32)
        server.stop()
        XCTAssertEqual(server.activeConnectionCount, 0)
    }

    func testInstallerStagesBeforeReplacingAndRollsBackFailedSwap() throws {
        let root = try directory()
        let source = root.appendingPathComponent("New.app")
        let destination = root.appendingPathComponent("Installed.app")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "dev.lyricshiori.app", "CFBundleExecutable": "app", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: source.appendingPathComponent("Contents/Info.plist"))
        let binary = source.appendingPathComponent("Contents/MacOS/app")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
        XCTAssertEqual(try run("/usr/bin/codesign", ["--force", "--sign", "-", source.path]), 0)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("old-marker")
        try Data("old app".utf8).write(to: marker)
        let script = root.appendingPathComponent("replace.sh")

        // Copy/verification failure must leave the old app untouched.
        try GitHubUpdateService.replacementScript.write(to: script, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(try run("/bin/bash", [script.path, root.appendingPathComponent("missing.app").path, destination.path]), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        // Fault injection after moving the old app exercises the real EXIT rollback.
        let failingSwap = GitHubUpdateService.replacementScript.replacingOccurrences(of: #"/bin/mv "$staged" "$destination""#, with: "/usr/bin/false")
        XCTAssertNotEqual(failingSwap, GitHubUpdateService.replacementScript)
        try failingSwap.write(to: script, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(try run("/bin/bash", [script.path, source.path, destination.path]), 0)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "old app")

        try GitHubUpdateService.replacementScript.write(to: script, atomically: true, encoding: .utf8)
        XCTAssertEqual(try run("/bin/bash", [script.path, source.path, destination.path]), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", destination.path]), 0)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".LyricShiori-install.") })
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func connect(_ port: NWEndpoint.Port) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.rawValue.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return fd
    }
}
