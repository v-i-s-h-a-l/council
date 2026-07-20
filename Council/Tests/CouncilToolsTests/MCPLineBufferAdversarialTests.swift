@testable import CouncilTools
import Foundation
import Testing

/// Direct unit tests for the lock-guarded line buffer. These need no
/// process-spawning fixture and sit exactly on the byte-cap boundaries that
/// the integration tests approach only from far away.
struct MCPLineBufferAdversarialTests {
    @Test func lineSplitAcrossChunksReassembles() throws {
        let buffer = MCPLineBuffer()
        #expect(try buffer.append(Data(#"{"a":"#.utf8)) == [])
        #expect(try buffer.append(Data("1}\n".utf8)) == [#"{"a":1}"#])
    }

    @Test func exactlyMaxLineBytesUnterminatedSucceedsThenCompletes() throws {
        let buffer = MCPLineBuffer()
        let payload = Data(repeating: UInt8(ascii: "x"), count: MCPLineBuffer.maxLineBytes)
        // Exactly at the cap with no newline yet: must not throw.
        #expect(try buffer.append(payload) == [])
        // The newline completes the line and the full payload is returned.
        let lines = try buffer.append(Data("\n".utf8))
        #expect(lines == [String(repeating: "x", count: MCPLineBuffer.maxLineBytes)])
    }

    @Test func maxLineBytesPlusOneUnterminatedThrows() throws {
        let buffer = MCPLineBuffer()
        let payload = Data(repeating: UInt8(ascii: "x"), count: MCPLineBuffer.maxLineBytes + 1)
        do {
            _ = try buffer.append(payload)
            Issue.record("expected protocolError one byte past the line cap")
        } catch ToolConnectorError.protocolError(let message) {
            #expect(message.contains("unterminated line"))
        }
    }

    @Test func backlogCapTripsBeforeLineExtraction() throws {
        let buffer = MCPLineBuffer()
        // A single >8 MB chunk of fully-terminated lines: the backlog cap is
        // checked on the raw buffered bytes before any line is extracted.
        var chunk = Data()
        chunk.reserveCapacity(9_000_000)
        let line = Data("xxxxxxxxxx\n".utf8)
        while chunk.count < 9_000_000 {
            chunk.append(line)
        }
        do {
            _ = try buffer.append(chunk)
            Issue.record("expected protocolError from the backlog cap")
        } catch ToolConnectorError.protocolError(let message) {
            #expect(message.contains("backlog cap"))
        }
    }

    @Test func invalidUTF8LineIsSilentlyDiscarded() throws {
        // Pin current behavior: a line that does not decode as UTF-8 is dropped
        // with no error and no log. If that is ever made loud, update this test
        // deliberately.
        let buffer = MCPLineBuffer()
        #expect(try buffer.append(Data([0xFF, 0xFE, 0x0A])) == [])
    }

    @Test func crlfLineEndingKeepsCarriageReturn() throws {
        // The buffer splits on \n only, so a CRLF server's \r stays attached
        // to the line. JSONSerialization tolerates the trailing \r downstream.
        let buffer = MCPLineBuffer()
        #expect(try buffer.append(Data("hello\r\n".utf8)) == ["hello\r"])
    }

    @Test func severalLinesArrivingInOneChunkAllReturnInOrder() throws {
        let buffer = MCPLineBuffer()
        #expect(try buffer.append(Data("one\ntwo\nthree\n".utf8)) == ["one", "two", "three"])
        #expect(try buffer.append(Data("four\n".utf8)) == ["four"])
    }
}
