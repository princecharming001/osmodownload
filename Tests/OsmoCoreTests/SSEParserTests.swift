import Testing
import Foundation
@testable import OsmoCore

@Suite("SSE parser — chunked framing")
struct SSEParserTests {

    @Test("A frame split across arbitrary chunk boundaries reassembles")
    func chunkSplit() {
        var parser = SSEParser()
        let full = "data: {\"type\":\"sync.dirty\",\"seq\":7}\n\n"
        // Split mid-token, three ways.
        let parts = [String(full.prefix(9)), String(full.dropFirst(9).prefix(15)), String(full.dropFirst(24))]
        var frames: [SSEParser.Frame] = []
        for part in parts { frames += parser.feed(Data(part.utf8)) }
        #expect(frames.count == 1)
        #expect(frames[0].data == "{\"type\":\"sync.dirty\",\"seq\":7}")
        #expect(!frames[0].isComment)
    }

    @Test("Multiple frames in one chunk all emit")
    func multiFrame() {
        var parser = SSEParser()
        let chunk = "data: one\n\ndata: two\n\n: ping\n\n"
        let frames = parser.feed(Data(chunk.utf8))
        #expect(frames.count == 3)
        #expect(frames[0].data == "one")
        #expect(frames[1].data == "two")
        #expect(frames[2].isComment)
    }

    @Test("Comments (heartbeats) are flagged, not dropped")
    func comments() {
        var parser = SSEParser()
        let frames = parser.feed(Data(": connected\n\n".utf8))
        #expect(frames.count == 1)
        #expect(frames[0].isComment)
    }

    @Test("Multi-line data joins with newline; event/id fields parse")
    func multiLineData() {
        var parser = SSEParser()
        let frames = parser.feed(Data("event: update\nid: 42\ndata: line1\ndata: line2\n\n".utf8))
        #expect(frames.count == 1)
        #expect(frames[0].event == "update")
        #expect(frames[0].id == "42")
        #expect(frames[0].data == "line1\nline2")
    }

    @Test("CRLF line endings are tolerated")
    func crlf() {
        var parser = SSEParser()
        let frames = parser.feed(Data("data: hi\r\n\r\ndata: extra\n\n".utf8))
        // The \r\n\r\n boundary: our splitter keys on \n\n which appears at "\r\n\r\n"…
        // "data: hi\r" parses with the \r stripped.
        #expect(frames.contains { $0.data == "hi" })
        #expect(frames.contains { $0.data == "extra" })
    }

    @Test("BackendEvent decodes the wire event payloads")
    func eventDecode() {
        #expect(BackendEvent.decode(#"{"type":"sync.dirty","seq":9}"#) == .syncDirty(seq: 9))
        #expect(BackendEvent.decode(#"{"type":"connection.status","platform":"linkedin","status":"connected","connectionId":"c1"}"#)
                == .connectionStatus(platform: "linkedin", status: "connected", connectionId: "c1"))
        #expect(BackendEvent.decode(#"{"type":"backfill.progress","platform":"slack","progress":0.5}"#)
                == .backfillProgress(platform: "slack", progress: 0.5))
        #expect(BackendEvent.decode(#"{"type":"future.thing"}"#) == nil)   // forward compat
        #expect(BackendEvent.decode("not json") == nil)
    }
}
