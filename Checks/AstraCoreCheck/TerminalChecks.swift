import Foundation
import AstraCore

public func checkTerminal() async throws {
    try checkTerminalDecoding()
    try checkTranscriptCleaner()
    try checkTerminalDerivations()
    try await checkTerminalRequests()
    try await checkTerminalCloseOutcomes()
    try await checkTerminalDemo()
}

private let terminalBase = "https://lattice.example.com"

private struct TerminalAuthStub: WriteAuthenticator {
    var outcome: DeviceAuthOutcome = .confirmed
    func authenticate(reason: String) async -> DeviceAuthOutcome { outcome }
}

private func terminalClient(_ responses: [String: (Int, Data)]) -> (LatticeClient, MockTransport) {
    let transport = MockTransport(responses: responses)
    let client = LatticeClient(baseURL: URL(string: terminalBase)!, credential: LatticeCredential(bearerToken: "lat_check.notasecret"), transport: transport)
    return (client, transport)
}

private func terminalInstant(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
}

// The server's JSON for one session of each lifecycle stage, as
// `model.TerminalSession` marshals it (omitempty and omitzero fields absent).
private let terminalSessionsJSON = #"""
{"sessions":[
 {"id":"term_a","node_id":"n-edge","actor_id":"u-ops","token_id":"tok_cli","shell":"/bin/bash","cols":120,"rows":32,"status":"open","bytes_in":40,"bytes_out":5120,
  "created_at":"2026-10-28T11:40:00Z","opened_at":"2026-10-28T11:40:01Z","last_seen":"2026-10-28T11:59:00Z"},
 {"id":"term_b","node_id":"n-nas","actor_id":"u-ops","shell":"/bin/sh","cols":120,"rows":32,"status":"pending","created_at":"2026-10-28T11:59:30Z","opened_at":"0001-01-01T00:00:00Z","last_seen":"2026-10-28T11:59:30Z"},
 {"id":"term_c","node_id":"n-edge","actor_id":"u-ops","status":"failed","error":"terminal session expired after inactivity","bytes_out":12,
  "created_at":"2026-10-28T10:00:00Z","opened_at":"2026-10-28T10:00:02Z","closed_at":"2026-10-28T11:30:00Z","last_seen":"2026-10-28T11:30:00Z"}
]}
"""#

// MARK: Decoding

private func checkTerminalDecoding() throws {
    struct Envelope: Decodable { var sessions: [TerminalSession] }
    let sessions = try JSONDecoder().decode(Envelope.self, from: json(terminalSessionsJSON)).sessions
    try expectEqual(sessions.count, 3, "three sessions decode")
    let open = sessions[0]
    try expectEqual(open.nodeID, "n-edge", "node id")
    try expectEqual(open.tokenID, "tok_cli", "token id")
    try expectEqual(open.bytesOut, 5120, "bytes out")
    try expectEqual(open.openedAt, terminalInstant("2026-10-28T11:40:01Z"), "opened at")
    try expect(open.closedAt == nil, "an open session has no close time")
    let pending = sessions[1]
    try expect(pending.openedAt == nil, "Go's zero time reads as absent, not year one")
    try expectEqual(pending.tokenID, "", "a browser session has no token")
    try expectEqual(sessions[2].shellPath, "/bin/sh", "a missing shell is the server's default")
    try expectEqual(sessions[2].error, "terminal session expired after inactivity", "the close reason")

    let events = try JSONDecoder().decode(TerminalEventsResponse.self, from: json(#"""
    {"session":{"id":"term_a","node_id":"n-edge","status":"open","created_at":"2026-10-28T11:40:00Z"},
     "events":[{"seq":7,"kind":"output","data":"\u001b[32mok\u001b[0m\r\n","created_at":"2026-10-28T11:41:00Z"},{"seq":8,"kind":"output","created_at":"2026-10-28T11:41:01Z"}]}
    """#))
    try expectEqual(events.events.map(\.seq), [7, 8], "event sequence numbers")
    try expectEqual(events.events[0].data, "\u{1B}[32mok\u{1B}[0m\r\n", "escape sequences survive decoding")
    try expectEqual(events.events[1].data, "", "an event without data")
    let noEvents = try JSONDecoder().decode(TerminalEventsResponse.self, from: json(#"{"session":{"id":"t","node_id":"n","status":"closed","created_at":"2026-10-28T11:40:00Z"},"events":null}"#))
    try expect(noEvents.events.isEmpty, "a null event list reads as empty")
    let closed = try JSONDecoder().decode(TerminalSession.self, from: json(#"{"id":"t","node_id":"n","status":"closed","created_at":"2026-10-28T11:40:00Z","closed_at":"2026-10-28T11:50:00Z"}"#))
    try expect(!closed.isLive, "the close answer is a session")
}

// MARK: Transcript cleaner

private let e = "\u{1B}"

private func lines(_ raw: String) -> [String] {
    TranscriptCleaner.clean(raw).lines.map(\.text)
}

private func checkTranscriptCleaner() throws {
    // Colors and other SGR attributes are removed.
    try expectEqual(lines("\(e)[01;32mroot@edge\(e)[00m:\(e)[01;34m~\(e)[00m# ls\r\n\(e)[0m\(e)[01;34mcerts\(e)[0m  config.json\r\n"),
                    ["root@edge:~# ls", "certs  config.json"], "colors")
    try expectEqual(lines("\u{9B}31mred\u{9B}0m\r\n"), ["red"], "a C1 CSI")
    // OSC (BEL and ST), DCS and charset designations.
    try expectEqual(lines("\(e)]0;root@edge: ~\u{07}text\(e)]2;title\(e)\\more\r\n"), ["textmore"], "OSC ended by BEL and by ST")
    try expectEqual(lines("\(e)Pq#0;2;0;0;0\(e)\\ok\r\n"), ["ok"], "DCS")
    try expectEqual(lines("\(e)(Babc\(e))0def\(e)#8\r\n"), ["abcdef"], "charset and line-size sequences")
    try expectEqual(lines("\(e)[200~pasted\(e)[201~\r\n"), ["pasted"], "bracketed paste markers")
    try expectEqual(lines("\(e)7saved\(e)8\(e)=\(e)>\r\n"), ["saved"], "single-character escapes")

    // Cursor moves on the current line rewrite it; moves off the line are dropped.
    try expectEqual(lines("abcdef\(e)[3D\(e)[KXY\r\n"), ["abcXY"], "cursor back and erase to end")
    try expectEqual(lines("hello\(e)[1Gj\r\n"), ["jello"], "absolute column")
    try expectEqual(lines("a\(e)[3Cb\r\n"), ["a   b"], "cursor forward pads")
    try expectEqual(lines("abcdef\r\(e)[2Pz\r\n"), ["zdef"], "delete characters")
    try expectEqual(lines("abc\r\(e)[2@xy\r\n"), ["xyabc"], "insert blanks")
    try expectEqual(lines("abcdef\r\(e)[3X\r\n"), ["   def"], "erase characters")
    try expectEqual(lines("abcdef\(e)[3D\(e)[1K\r\n"), ["    ef"], "erase to start")
    try expectEqual(lines("abc\(e)[2K\r\n"), [""], "erase the whole line")
    try expectEqual(lines("\(e)[1K\(e)[2Kok\r\n"), ["ok"], "erasing an empty line")
    try expectEqual(lines("\(e)[5;10Hpos\(e)[2Aup\(e)[3Bdown\(e)[2J\r\n"), ["posupdown"], "moves off the line and screen clears are dropped")
    try expectEqual(lines("sl\u{08}\u{08}\(e)[Kls\r\n"), ["ls"], "a corrected command")

    // apt's fancy progress: save, jump to the bottom row, draw, restore.
    func aptStatus(_ percent: String, _ bar: String) -> String {
        "\(e)7\(e)[24;0f\(e)[42m\(e)[30mProgress: [\(percent)%]\(e)[49m\(e)[39m [\(bar)] \(e)8"
    }
    let apt = "\n\(e)7\(e)[0;23r\(e)8\(e)[1A"
        + "Selecting previously unselected package jq.\r\n" + aptStatus(" 20", "####......")
        + "Unpacking jq (1.6-2.1) ...\r\n" + aptStatus(" 60", "######....")
        + "Setting up jq (1.6-2.1) ...\r\n" + aptStatus("100", "##########")
        + "\n\(e)7\(e)[0;24r\(e)8\(e)[1A\(e)[J$ "
    let aptLines = lines(apt)
    try expect(!aptLines.contains { $0.contains("Progress") || $0.contains("#") }, "apt's status line is not merged into output: \(aptLines)")
    for line in ["Selecting previously unselected package jq.", "Unpacking jq (1.6-2.1) ...", "Setting up jq (1.6-2.1) ..."] {
        try expect(aptLines.contains(line), "a dpkg line stays whole: \(line) in \(aptLines)")
    }
    try expectEqual(aptLines.last, "$", "the prompt after apt")
    try expectEqual(lines("half\(e)7\(e)[24;1Hstatus\(e)8 done\r\n"), ["half done"], "a restore returns to the saved column")
    try expectEqual(lines("\(e)[s\(e)[1;1Htop\(e)[ukept\r\n"), ["kept"], "CSI s and u save and restore")
    try expectEqual(lines("a\(e)7\(e)[5;1Hmoved\r\nnext\r\n"), ["a", "moved", "next"], "whole lines after a move are kept when no restore comes")
    var splitApt = TranscriptCleaner()
    splitApt.feed("x\(e)7\(e)[24;0fProg")
    try expectEqual(splitApt.lines.map(\.text), ["x"], "a half-drawn status line never shows")
    splitApt.feed("ress\(e)8y\r\n")
    try expectEqual(splitApt.lines.map(\.text), ["xy"], "the status line split across events")
    try expectEqual(lines("lss\u{08} \u{08}\r\n"), ["ls"], "a backspace echo")
    try expectEqual(lines("a\tb\r\n12345678\tc\r\n"), ["a       b", "12345678        c"], "tab stops")

    // Carriage-return progress bars end as their last frame.
    try expectEqual(lines("10%\r20%\r100%\r\n"), ["100%"], "a carriage-return counter")
    try expectEqual(lines("Progress: [ 20%] [##....]\r\(e)[KProgress: [ 60%] [####..]\r\(e)[KDone\r\n"), ["Done"], "a progress bar cleared with erase")
    try expectEqual(lines("loading 100%\rdone\r\n"), ["doneing 100%"], "an overwrite without erase keeps what a terminal shows")
    try expectEqual(lines("a\nb\n"), ["a", "b"], "a bare line feed ends a line")
    try expectEqual(lines("one\r\ntwo   \r\n$ "), ["one", "two", "$"], "trailing blanks trimmed, the prompt kept as the last line")
    try expectEqual(lines("bell\u{07}\u{00}\u{7F}\r\n"), ["bell"], "other controls draw nothing")
    try expectEqual(lines("\(e)[" + String(repeating: "1;", count: 80) + "mtext\r\n"), ["text"], "an overlong sequence stops growing and is still dropped")

    // Counts come from the remote shell: huge ones must neither trap nor grow a line.
    let width = TranscriptCleaner.defaultMaxColumns
    let hostile = [
        "ab\(e)[9223372036854775807X\r\n",
        "ab\(e)[9223372036854775807C\(e)[5Cz\r\n",
        "x\(e)[200000000Cy\r\n",
        "x\(e)[9223372036854775807G\(e)[9223372036854775807@\(e)[9223372036854775807Py\r\n",
        "ab\(e)[9223372036854775807D\tc\r\n",
    ]
    for raw in hostile {
        let cleaned = TranscriptCleaner.clean(raw)
        try expect(cleaned.lines.allSatisfy { $0.text.unicodeScalars.count <= width }, "a hostile count stays inside \(width) columns")
    }
    try expectEqual(lines("ab\(e)[9223372036854775807X\r\n"), ["ab"], "erasing past the end erases nothing")
    try expectEqual(lines("x\(e)[200000000Cy\r\n").first?.count, width, "a far move stops at the right margin")
    try expectEqual(lines("abc\(e)[10X\r\n"), ["abc"], "erasing beyond the line from past its end")
    let long = String(repeating: "0123456789", count: 110)
    try expectEqual(lines(long + "\r\n"), [String(long.prefix(width)), String(long.dropFirst(width))], "a line past the margin wraps")
    try expectEqual(lines(String(repeating: "\t", count: 400) + "t\r\n").first?.count, width, "tabs stop at the margin")

    // Alternate screen: a full-screen program is left out and marked.
    var htop = TranscriptCleaner.clean("$ htop\r\n\(e)[?1049h\(e)[H\(e)[2Jframe one\(e)[5;1Hframe two\r\nmore")
    try expectEqual(htop.lines.map(\.kind), [.text, .fullScreen], "the program's frames become one marker")
    try expectEqual(htop.lines.map(\.text), ["$ htop", ""], "no frame text leaks")
    try expect(htop.fullScreenActive, "the program is still running")
    try expectEqual(htop.fullScreenEntries, 1, "one entry")
    htop.feed("\(e)[?1049l$ ")
    try expect(!htop.fullScreenActive, "the program exited")
    try expectEqual(htop.lines.map(\.text), ["$ htop", "", "$"], "the prompt returns after the marker")
    try expectEqual(htop.text, "$ htop\n\(TranscriptCleaner.fullScreenPlaceholder)\n$", "copied text names the left-out output")
    let vim = TranscriptCleaner.clean("vi x\r\n\(e)[?47hscreen\(e)[?47l\(e)[?1047hagain\(e)[?1047l\(e)[?1;1049hthird")
    try expectEqual(vim.fullScreenEntries, 3, "the 47 and 1047 forms, and 1049 among other modes")
    try expect(vim.fullScreenActive, "still inside the third program")
    let partial = TranscriptCleaner.clean("typed\(e)[?1049hx")
    try expectEqual(partial.lines.map(\.text), ["typed", ""], "an unfinished line is kept before the marker")

    // Incremental feeding keeps a sequence split across events.
    let whole = TranscriptCleaner.clean("\(e)[01;32mgreen\(e)[0m\r\nx\(e)[Ky\(e)]0;t\u{07}z\r\n")
    var pieces = TranscriptCleaner()
    for piece in ["\(e)[01;3", "2mgreen\(e)", "[0m\r", "\nx\(e)", "[Ky\(e)]0", ";t\u{07}z\r\n"] { pieces.feed(piece) }
    try expectEqual(pieces.lines, whole.lines, "split sequences read the same as one piece")
    try expectEqual(pieces.lines.map(\.text), ["green", "xyz"], "the split result")

    // Line numbers stay stable while old lines are dropped.
    let capped = TranscriptCleaner.clean((1...10).map { "line \($0)\r\n" }.joined() + "$ ", maxLines: 3)
    try expectEqual(capped.lines.map(\.id), [8, 9, 10, 11], "ids keep counting")
    try expectEqual(capped.droppedLines, 7, "dropped lines are counted")
    try expect(TranscriptCleaner.clean("\(e)[?2004h\(e)[0m\r").isEmpty, "only sequences is empty")
    try expect(!TranscriptCleaner.clean("x").isEmpty, "text is not empty")
}

// MARK: Derivations

private func terminalSession(_ status: String, error: String = "", bytesOut: Int64 = 0, bytesIn: Int64 = 0, opened: String? = nil, closed: String? = nil,
                             created: String = "2026-10-28T11:00:00Z", node: String = "n-a", id: String = "t", token: String = "") -> TerminalSession {
    TerminalSession(id: id, nodeID: node, actorID: "u-ops", tokenID: token, status: status, error: error, bytesIn: bytesIn, bytesOut: bytesOut,
                    createdAt: terminalInstant(created), openedAt: opened.map(terminalInstant), closedAt: closed.map(terminalInstant))
}

private func checkTerminalDerivations() throws {
    let now = terminalInstant("2026-10-28T12:00:00Z")
    // States, with the server's time limits read as expiry rather than failure.
    try expectEqual(TerminalSessionState.of(terminalSession("pending")), .pending, "pending")
    try expectEqual(TerminalSessionState.of(terminalSession("open")), .open, "open")
    try expectEqual(TerminalSessionState.of(terminalSession("starting")), .open, "an unknown live status reads as live")
    try expectEqual(TerminalSessionState.of(terminalSession("closed")), .closed, "closed")
    for reason in ["terminal session expired before node accepted it", "terminal session reached maximum duration",
                   "terminal session expired after inactivity", "terminal viewer disconnected and did not return"] {
        try expectEqual(TerminalSessionState.of(terminalSession("failed", error: reason)), .expired, "a time limit expires: \(reason)")
    }
    try expectEqual(TerminalSessionState.of(terminalSession("failed", error: "pty: exec format error")), .failed, "anything else fails")
    try expect(TerminalSessionState.pending.isLive && TerminalSessionState.open.isLive && !TerminalSessionState.expired.isLive, "live states")

    // Close reasons.
    try expect(TerminalCloseReason.of(terminalSession("open")) == nil, "a live session has no close reason")
    try expectEqual(TerminalCloseReason.of(terminalSession("failed", error: "Terminal session EXPIRED BEFORE NODE ACCEPTED IT (req_1)"))?.kind, .pendingExpired, "matched as a substring, any case")
    try expectEqual(TerminalCloseReason.of(terminalSession("closed", error: "node deleted"))?.kind, .nodeDeleted, "node deleted")
    try expectEqual(TerminalCloseReason.of(terminalSession("failed", error: "the node agent did not connect"))?.kind, .nodeOffline, "agent did not connect")
    try expectEqual(TerminalCloseReason.of(terminalSession("closed"))?.sentence, "Closed by an operator or by the agent.", "a plain close")
    try expectEqual(TerminalCloseReason.of(terminalSession("closed", error: "exit status 130"))?.sentence, "Closed: exit status 130.", "the agent's words")
    try expectEqual(TerminalCloseReason.of(terminalSession("failed", error: "pty: exec format error"))?.sentence, "Failed: pty: exec format error.", "a failure in the server's words")
    try expectEqual(TerminalCloseReason(kind: .idle).sentence, "It expired after 30 minutes without activity.", "idle sentence")
    try expectEqual(TerminalCloseReason(kind: .pendingExpired).sentence, "The node agent did not pick it up within 10 minutes.", "pending sentence")

    // Transport: bytes through the server prove polling.
    try expectEqual(TerminalTransport.of(terminalSession("open", bytesOut: 10, opened: "2026-10-28T11:00:00Z"), runtime: "stream", now: now), .poll, "bytes win over the runtime")
    try expectEqual(TerminalTransport.of(terminalSession("open", bytesIn: 3, opened: "2026-10-28T11:59:59Z"), runtime: nil, now: now), .poll, "input bytes too")
    try expectEqual(TerminalTransport.of(terminalSession("open", opened: "2026-10-28T11:59:50Z"), runtime: "stream", now: now), .stream, "the runtime says stream")
    try expectEqual(TerminalTransport.of(terminalSession("open", opened: "2026-10-28T11:58:00Z"), runtime: nil, now: now), .stream, "a minute of silence means stream")
    try expectEqual(TerminalTransport.of(terminalSession("open", opened: "2026-10-28T11:59:30Z"), runtime: "poll", now: now), .poll, "a fresh polled session")
    try expectEqual(TerminalTransport.of(terminalSession("open", opened: "2026-10-28T11:59:30Z"), runtime: nil, now: now), .unknown, "too early to tell")
    try expectEqual(TerminalTransport.of(terminalSession("pending"), runtime: nil, now: now), .unknown, "a pending session has no transport yet")
    try expectEqual(TerminalTransport.of(terminalSession("closed", opened: "2026-10-28T11:00:00Z", closed: "2026-10-28T11:00:30Z"), runtime: nil, now: now), .unknown,
                    "an ended session is judged up to its end")

    // Who opened it.
    try expectEqual(TerminalOpener.of(terminalSession("open"), currentTokenID: "tok_phone"), .signedInSession, "no token: a browser")
    try expectEqual(TerminalOpener.of(terminalSession("open", token: "tok_phone"), currentTokenID: "tok_phone"), .thisToken, "this token")
    try expectEqual(TerminalOpener.of(terminalSession("open", token: "tok_cli"), currentTokenID: "tok_phone").phrase, "with another token", "another token, its id kept out of prose")

    // Lists.
    let sessions = [
        terminalSession("closed", closed: "2026-10-28T11:10:00Z", id: "c1"),
        terminalSession("open", created: "2026-10-28T11:30:00Z", node: "n-b", id: "o1"),
        terminalSession("pending", created: "2026-10-28T11:50:00Z", id: "p1"),
        terminalSession("failed", closed: "2026-10-28T11:40:00Z", id: "f1"),
    ]
    try expectEqual(TerminalSessionList.live(sessions).map(\.id), ["p1", "o1"], "live, newest first")
    try expectEqual(TerminalSessionList.ended(sessions).map(\.id), ["f1", "c1"], "ended, most recently ended first")
    try expectEqual(TerminalSessionList.summary(sessions), "2 live, 2 ended", "summary")
    try expect(TerminalSessionList.matches(sessions[1], nodeName: "relay-fra-1", transport: .poll, query: "FRA poll"), "matches node name and transport")
    try expect(!TerminalSessionList.matches(sessions[1], nodeName: "relay-fra-1", transport: .poll, query: "tyo"), "no match")
    try expect(TerminalSessionList.matches(sessions[0], nodeName: "x", transport: .unknown, query: " "), "an empty query matches")

    // Transcript notices.
    let htop = TranscriptCleaner.clean("$ htop\r\n\(e)[?1049h")
    try expectEqual(TerminalTranscriptNotice.of(terminalSession("open"), transport: .poll, cleaner: htop, firstSeq: 1), [.fullScreenRunning], "a running program")
    try expectEqual(TerminalTranscriptNotice.of(terminalSession("closed"), transport: .poll, cleaner: htop, firstSeq: 1), [], "an ended session with a program left open says nothing more")
    try expectEqual(TerminalTranscriptNotice.of(terminalSession("open"), transport: .stream, cleaner: TranscriptCleaner(), firstSeq: nil), [.streamed], "streamed")
    try expectEqual(TerminalTranscriptNotice.of(terminalSession("open"), transport: .poll, cleaner: TranscriptCleaner(), firstSeq: nil), [.noOutputYet], "nothing printed yet")
    try expectEqual(TerminalTranscriptNotice.of(terminalSession("pending"), transport: .unknown, cleaner: TranscriptCleaner(), firstSeq: nil), [.waitingForAgent], "waiting for the agent")
    try expectEqual(TerminalTranscriptNotice.of(terminalSession("open"), transport: .poll, cleaner: TranscriptCleaner.clean("x"), firstSeq: 41), [.truncated], "older output dropped")
    let trimmed = TranscriptCleaner.clean((1...5).map { "line \($0)\r\n" }.joined(), maxLines: 3)
    try expectEqual(TerminalTranscriptNotice.of(terminalSession("open"), transport: .poll, cleaner: trimmed, firstSeq: 1), [.trimmedOnPhone], "lines past the phone's cap are noticed")
    try expect(TerminalLimits.sentence.contains("30 minutes without activity") && TerminalLimits.sentence.contains("4 live sessions per node"), "limits sentence")
}

// MARK: Requests

private func checkTerminalRequests() async throws {
    let base = "\(terminalBase)/api/terminal/sessions"
    let closedJSON = json(#"{"id":"term_a","node_id":"n-edge","status":"closed","created_at":"2026-10-28T11:40:00Z","closed_at":"2026-10-28T12:00:00Z"}"#)
    let (client, transport) = terminalClient([
        base: (200, json(terminalSessionsJSON)),
        "\(base)/term_a/events?cursor=12": (200, json(#"{"session":{"id":"term_a","node_id":"n-edge","status":"open","created_at":"2026-10-28T11:40:00Z"},"events":[]}"#)),
        "\(base)/term_a/events?cursor=0": (200, json(#"{"session":{"id":"term_a","node_id":"n-edge","status":"open","created_at":"2026-10-28T11:40:00Z"},"events":[]}"#)),
        "\(base)/term_a/close": (200, closedJSON),
    ])
    _ = try await client.terminalListSessions()
    _ = try await client.terminalEvents(sessionID: "term_a", cursor: 12)
    _ = try await client.terminalEvents(sessionID: "term_a", cursor: -4)
    let closed = try await client.terminalCloseSession(id: "term_a")
    try expectEqual(closed.status, "closed", "close answers the session")
    let urls = await transport.requestURLs
    let methods = await transport.methods
    let bodies = await transport.bodies
    try expectEqual(urls, [base, "\(base)/term_a/events?cursor=12", "\(base)/term_a/events?cursor=0", "\(base)/term_a/close"], "request URLs; a negative cursor is sent as 0")
    try expectEqual(methods, ["GET", "GET", "GET", "POST"], "methods")
    try expect(bodies[0] == nil && bodies[1] == nil, "reads send no body")
    try expectEqual(String(decoding: try expectUnwrapped(bodies[3], "close body"), as: UTF8.self), "{}", "the close body is {}")
    let auth = await transport.authorizationHeaders
    try expect(auth.allSatisfy { $0 == "Bearer lat_check.notasecret" }, "every call carries the token")
}

private func checkTerminalCloseOutcomes() async throws {
    let session = terminalSession("open", node: "n-edge", id: "term_a")
    let intent = TerminalIntents.close(session, nodeName: "edge-tyo-1")
    try expect(intent.tier == .t2, "close is T2")
    try expectEqual(intent.scopes, ["terminal:open"], "close needs terminal:open")
    try expectEqual(intent.changes, [.terminal], "close bumps terminal")
    try expectEqual(intent.title, "Close the session on edge-tyo-1", "the dialog title names the node")
    try expect(intent.idempotent, "closing twice changes nothing")
    try expect(intent.inverse == nil, "a closed session cannot be reopened")

    let base = "\(terminalBase)/api/terminal/sessions"
    // Through the write flow, against each answer the close route gives.
    func run(_ status: Int, _ body: String) async throws -> (WriteOutcome, [String]) {
        let (client, transport) = terminalClient(["\(base)/term_a/close": (status, json(body))])
        let result = await WriteFlow(intent: intent, client: client, authenticator: TerminalAuthStub()).commit(choices: ConfirmChoices())
        guard case .finished(let outcome) = result else { throw CheckFailure.failed("close finishes") }
        return (outcome, await transport.methods.compactMap { $0 })
    }
    let (done, methods) = try await run(200, #"{"id":"term_a","node_id":"n-edge","status":"closed","created_at":"2026-10-28T11:40:00Z"}"#)
    try expectEqual(done.message, "Closed the session on edge-tyo-1", "closed")
    try expectEqual(methods, ["POST"], "one POST and nothing else")
    let (again, _) = try await run(400, #"{"error":{"code":"bad_request","message":"terminal session is closed","request_id":"req_1"}}"#)
    try expect(again.isCleanSuccess, "already closed reads as done")
    try expectEqual(again.message, "The session on edge-tyo-1 had already ended", "already ended")
    let (gone, _) = try await run(404, #"{"error":{"code":"not_found","message":"terminal session not found","request_id":"req_2"}}"#)
    guard case .refused(.notFound, let goneMessage) = gone else { throw CheckFailure.failed("404 is not found: \(gone)") }
    try expect(goneMessage.contains("30 minutes"), "404 says the server forgets ended sessions")
    let (other, _) = try await run(403, #"{"error":{"code":"forbidden","message":"terminal session belongs to another operator","request_id":"req_3"}}"#)
    guard case .refused(.validation, let otherMessage) = other else { throw CheckFailure.failed("ownership refusal: \(other)") }
    try expect(otherMessage.contains("another operator"), "names the owner rule")
    let (scope, _) = try await run(403, #"{"error":{"code":"capability_denied","message":"missing scope terminal:open","request_id":"req_4"}}"#)
    guard case .refused(.forbidden, _) = scope else { throw CheckFailure.failed("a scope refusal stays forbidden: \(scope)") }
    let pending = TerminalIntents.outcome(ofClose: terminalSession("pending"), nodeName: "edge-iad-1")
    try expect(pending.message.hasPrefix("Close requested"), "a session still live after close says so")
}

// MARK: Demo

private func checkTerminalDemo() async throws {
    let state = DemoState()
    let clock = DemoClock(pinned: "2026-10-28T12:00:00Z")!
    func client(_ scenario: DemoScenario = .rootToken) -> LatticeClient {
        LatticeClient(baseURL: DemoWorld.baseURL, credential: LatticeCredential(bearerToken: DemoWorld.token),
                      transport: DemoTransport(identity: .pat, scenario: scenario, clock: clock, state: state))
    }
    let now = clock.anchor
    let sessions = try await client().terminalListSessions()
    try expectEqual(sessions.count, TerminalFixtures.sessions.count, "every demo session is listed")
    try expect(sessions.allSatisfy { $0.actorID == DemoWorld.actorID }, "only the operator's own sessions")
    try expectEqual(Set(sessions.map(TerminalSessionState.of)), Set(TerminalSessionState.allCases), "the demo covers every state")
    try expectEqual(Set(sessions.map { TerminalTransport.of($0, runtime: nil, now: now) }), [.poll, .stream, .unknown], "polled, streamed and not yet known")
    try expect(sessions.allSatisfy { DemoWorld.node(id: $0.nodeID) != nil }, "sessions sit on demo nodes")

    // The polled session's transcript, read in two polls, cleans to readable lines.
    let first = try await client().terminalEvents(sessionID: "term_demo_7f3k2a", cursor: 0)
    try expect(first.events.count > 4, "several events")
    var cleaner = TranscriptCleaner()
    for event in first.events.prefix(5) { cleaner.feed(event.data) }
    let cursor = first.events.prefix(5).last!.seq
    let rest = try await client().terminalEvents(sessionID: "term_demo_7f3k2a", cursor: cursor)
    try expectEqual(rest.events.first?.seq, cursor + 1, "the cursor reads only what is new")
    for event in rest.events { cleaner.feed(event.data) }
    let text = cleaner.lines.map(\.text)
    try expect(text.contains("root@edge-tyo-1:~# systemctl status sing-box --no-pager"), "the corrected command reads cleanly: \(text.prefix(2))")
    for line in ["Unpacking libonig5:amd64 (6.9.8-1) ...", "Setting up libonig5:amd64 (6.9.8-1) ...", "Setting up jq (1.6-2.1) ..."] {
        try expect(text.contains(line), "apt's status line, split across events, leaves dpkg lines whole: \(line)")
    }
    try expect(!text.contains { $0.contains("\u{1B}") || $0.contains("Progress:") }, "no escape or progress residue")
    try expectEqual(text.last, "root@edge-tyo-1:~#", "the prompt is the last line")
    let empty = try await client().terminalEvents(sessionID: "term_demo_7f3k2a", cursor: rest.events.last!.seq)
    try expect(empty.events.isEmpty, "nothing new")

    let htop = try await client().terminalEvents(sessionID: "term_demo_4m8q1c")
    let screen = TranscriptCleaner.clean(htop.events.map(\.data).joined())
    try expect(screen.fullScreenActive, "htop holds the screen")
    try expectEqual(TerminalTranscriptNotice.of(htop.session, transport: .poll, cleaner: screen, firstSeq: 1), [.fullScreenRunning], "the full-screen notice")
    let streamed = try await client().terminalEvents(sessionID: "term_demo_2c6n0d")
    try expectEqual(TerminalTranscriptNotice.of(streamed.session, transport: TerminalTransport.of(streamed.session, runtime: nil, now: now),
                                                cleaner: TranscriptCleaner(), firstSeq: nil), [.streamed], "the streamed session holds no output")

    // Refusals by id.
    do {
        _ = try await client().terminalEvents(sessionID: TerminalFixtures.otherOperatorSessionID)
        throw CheckFailure.failed("another operator's session is refused")
    } catch LatticeAPIError.forbidden(_, let message) {
        try expect(message.contains(TerminalServerMessages.otherOperator), "the owner refusal")
    }
    do {
        _ = try await client().terminalEvents(sessionID: "term_gone")
        throw CheckFailure.failed("an unknown session is 404")
    } catch LatticeAPIError.notFound {}
    do {
        _ = try await client(.normal).terminalListSessions()
        throw CheckFailure.failed("the Operator preset lacks terminal:open")
    } catch LatticeAPIError.forbidden {}

    // Close through the write flow, then the list and transcript agree.
    let open = try expectUnwrapped(sessions.first { $0.id == "term_demo_7f3k2a" }, "the open session")
    let flow = WriteFlow(intent: TerminalIntents.close(open, nodeName: "edge-tyo-1"), client: client(), authenticator: TerminalAuthStub())
    guard case .finished(let outcome) = await flow.commit(choices: ConfirmChoices()) else { throw CheckFailure.failed("demo close finishes") }
    try expect(outcome.isCleanSuccess, "demo close is done")
    let after = try await client().terminalListSessions().first { $0.id == open.id }
    try expectEqual(after?.status, "closed", "the list shows it closed")
    try expectEqual(try await client().terminalEvents(sessionID: open.id).session.status, "closed", "the transcript shows it closed")
    guard case .finished(let again) = await flow.commit(choices: ConfirmChoices()) else { throw CheckFailure.failed("second close finishes") }
    try expectEqual(again.message, "The session on edge-tyo-1 had already ended", "a second close is harmless")
}
