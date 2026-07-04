import Foundation

/// Incremental Server-Sent-Events framer. Feed it raw byte chunks as they
/// arrive; it returns completed frames. Handles the case that always bites:
/// frames split arbitrarily across chunk boundaries (and CRLF line endings,
/// comments, multi-line data).
public struct SSEParser: Sendable {
    public struct Frame: Equatable, Sendable {
        public var event: String?
        public var data: String
        public var id: String?
        public var isComment: Bool
    }

    private var buffer = Data()

    public init() {}

    /// Feed a chunk; get back every frame completed by it.
    public mutating func feed(_ chunk: Data) -> [Frame] {
        buffer.append(chunk)
        var frames: [Frame] = []

        // A frame ends at a blank line: \n\n or \r\n\r\n (CRLF streams never
        // contain a literal \n\n — the boundary bytes are 0D0A0D0A).
        while let boundary = Self.nextBoundary(in: buffer) {
            let raw = buffer.subdata(in: buffer.startIndex..<boundary.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<boundary.upperBound)
            if let frame = Self.parseFrame(raw) { frames.append(frame) }
        }
        return frames
    }

    /// Earliest frame boundary — whichever of \n\n / \r\n\r\n comes first.
    private static func nextBoundary(in data: Data) -> Range<Data.Index>? {
        let lf = data.range(of: Data("\n\n".utf8))
        let crlf = data.range(of: Data("\r\n\r\n".utf8))
        switch (lf, crlf) {
        case (nil, nil): return nil
        case (let l?, nil): return l
        case (nil, let c?): return c
        case (let l?, let c?): return c.lowerBound <= l.lowerBound ? c : l
        }
    }

    private static func parseFrame(_ raw: Data) -> Frame? {
        guard let text = String(data: raw, encoding: .utf8) else { return nil }
        var event: String?
        var id: String?
        var dataLines: [String] = []
        var sawComment = false

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
            if line.isEmpty { continue }
            if line.hasPrefix(":") { sawComment = true; continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let field = String(line[..<colon])
            var value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
            switch field {
            case "event": event = value
            case "data": dataLines.append(value)
            case "id": id = value
            default: break
            }
        }

        if dataLines.isEmpty && event == nil && id == nil {
            return sawComment ? Frame(event: nil, data: "", id: nil, isComment: true) : nil
        }
        return Frame(event: event, data: dataLines.joined(separator: "\n"), id: id, isComment: false)
    }
}
