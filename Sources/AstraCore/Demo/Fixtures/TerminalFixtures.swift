import Foundation

/// Demo routes for the Terminal domain, owned by the Terminal module (section 8.6).
///
/// The sessions are the demo operator's own, as the server lists only those:
/// a polled bash session with colored output and progress bars, one running
/// htop on the alternate screen, a streamed session the server holds no
/// output for, one waiting for its agent, and three ended ones (closed, idle
/// and never picked up). `term_demo_x9other` belongs to another operator and
/// is answered 403, as `terminalSessionOwnedBy` does; any other unknown id is
/// 404. Every route needs terminal:open, which only the Root token and Full
/// administrator scenarios hold. Closing records the session in DemoState.
public enum TerminalFixtures {
    public static let closedSet = "terminal.closed"
    public static let otherOperatorSessionID = "term_demo_x9other"

    public static var routes: [DemoRoute] {
        [
            DemoRoute(pathPattern: "/api/terminal/sessions", body: listBody(closed: []), emptyBody: #"{"sessions":[]}"#) { _, state in
                .json(listBody(closed: await state.members(of: closedSet)))
            }.requiring(TerminalLimits.scope),
            DemoRoute(pathPattern: "/api/terminal/sessions/*/events", body: eventsBody(sessions[0], closed: false, cursor: 0),
                      emptyBody: eventsEmptyBody) { request, state in
                await events(request, state: state)
            }.requiring(TerminalLimits.scope),
            DemoRoute(method: "POST", pathPattern: "/api/terminal/sessions/*/close") { request, state in
                await close(request, state: state)
            }.requiring(TerminalLimits.scope),
        ]
    }

    // MARK: Sessions

    public struct Session: Sendable {
        public var id: String
        public var node: String
        public var tokenID: String = ""
        public var shell: String = "/bin/bash"
        public var status: String
        public var error: String = ""
        public var created: String
        public var opened: String?
        public var closed: String?
        public var lastSeen: String
        public var bytesIn: Int = 0
        /// The output, split into events at these places.
        public var output: [String] = []

        public var nodeID: String { DemoWorld.node(node).id }
        public var bytesOut: Int { output.reduce(0) { $0 + $1.utf8.count } }
    }

    private static let esc = "\u{1B}"
    private static let bel = "\u{07}"

    private static func prompt(_ node: String) -> String {
        "\(esc)]0;root@\(node): ~\(bel)\(esc)[?2004h\(esc)[01;32mroot@\(node)\(esc)[00m:\(esc)[01;34m~\(esc)[00m# "
    }

    private static func command(_ text: String) -> String {
        "\(text)\r\n\(esc)[?2004l\r"
    }

    /// One draw of apt's fancy progress line (apt-pkg PackageManagerFancy).
    private static func aptStatus(_ percent: String, _ bar: String) -> String {
        "\(esc)7\(esc)[24;0f\(esc)[42m\(esc)[30mProgress: [\(percent)%]\(esc)[49m\(esc)[39m [\(bar)] \(esc)8"
    }

    public static let sessions: [Session] = [
        Session(
            id: "term_demo_7f3k2a", node: "edge-tyo-1", status: "open",
            created: "-14m", opened: "-14m", lastSeen: "-40s", bytesIn: 212,
            output: [
                prompt("edge-tyo-1") + "sl" + "\u{08}\u{08}\(esc)[K" + command("systemctl status sing-box --no-pager"),
                "\(esc)[0;1;32m\u{25CF}\(esc)[0m sing-box.service - sing-box proxy\r\n"
                    + "     Loaded: loaded (/etc/systemd/system/sing-box.service; \(esc)[0;1;32menabled\(esc)[0m; preset: \(esc)[0;1;32menabled\(esc)[0m)\r\n"
                    + "     Active: \(esc)[0;1;32mactive (running)\(esc)[0m for 6 days\r\n"
                    + "   Main PID: 812 (sing-box)\r\n      Tasks: 9 (limit: 2307)\r\n     Memory: 41.2M\r\n        CPU: 18min 2.114s\r\n",
                prompt("edge-tyo-1") + command("apt install -y jq"),
                "Reading package lists... 0%\rReading package lists... 100%\rReading package lists... Done\r\n"
                    + "Building dependency tree... 0%\rBuilding dependency tree... 50%\rBuilding dependency tree... Done\r\n"
                    + "The following NEW packages will be installed:\r\n  jq libjq1 libonig5\r\n"
                    + "0 upgraded, 3 newly installed, 0 to remove and 0 not upgraded.\r\n"
                    + "Get:1 http://deb.example.net/debian bookworm/main amd64 libonig5 amd64 6.9.8-1 [188 kB]\r\n"
                    + "Get:2 http://deb.example.net/debian bookworm/main amd64 libjq1 amd64 1.6-2.1 [135 kB]\r\n"
                    + "Get:3 http://deb.example.net/debian bookworm/main amd64 jq amd64 1.6-2.1 [64.9 kB]\r\n"
                    + "Fetched 388 kB in 0s (1210 kB/s)\r\n",
                // apt's bottom progress line, as apt draws it: reserve the last
                // row, then save the cursor, jump there, draw and restore. The
                // second status draw is split across two events, inside a sequence.
                "\n\(esc)7\(esc)[0;23r\(esc)8\(esc)[1A"
                    + "Selecting previously unselected package libonig5:amd64.\r\n"
                    + "(Reading database ... 34512 files and directories currently installed.)\r\n"
                    + "Preparing to unpack .../libonig5_6.9.8-1_amd64.deb ...\r\n"
                    + aptStatus(" 20", "##########..................")
                    + "Unpacking libonig5:amd64 (6.9.8-1) ...\r\n"
                    + "\(esc)7\(esc)[24;0f\(esc)[42m\(esc)[30mProgress: [ 60%]\(esc)[49m\(esc)[39m [################",
                "....] \(esc)",
                "8Setting up libonig5:amd64 (6.9.8-1) ...\r\n" + aptStatus(" 80", "######################......")
                    + "Setting up libjq1:amd64 (1.6-2.1) ...\r\nSetting up jq (1.6-2.1) ...\r\n"
                    + "\n\(esc)7\(esc)[0;24r\(esc)8\(esc)[1A\(esc)[J",
                prompt("edge-tyo-1") + command("ls --color=auto /etc/sing-box"),
                "\(esc)[0m\(esc)[01;34mcerts\(esc)[0m  config.json  \(esc)[01;32mreload.sh\(esc)[0m  rules.srs\r\n",
                prompt("edge-tyo-1") + command("journalctl -u sing-box -n 3 --no-pager -o cat"),
                "\(esc)[0;1;31m+0900 ERROR [3021394561 2.1s] inbound/vless[in-reality]: process connection from 198.51.100.24:51644: TLS handshake: EOF\(esc)[0m\r\n"
                    + "+0900 INFO [1209331410 0ms] inbound/vless[in-reality]: inbound connection from 203.0.113.77:40112\r\n"
                    + "+0900 INFO [1209331410 0ms] outbound/direct[direct]: outbound connection to 192.0.2.80:443\r\n",
                prompt("edge-tyo-1"),
            ]
        ),
        Session(
            id: "term_demo_4m8q1c", node: "relay-fra-1", status: "open",
            created: "-6m", opened: "-6m", lastSeen: "-3s", bytesIn: 9,
            output: [
                prompt("relay-fra-1") + command("htop"),
                "\(esc)[?1049h\(esc)[22;0;0t\(esc)[1;24r\(esc)(B\(esc)[m\(esc)[4l\(esc)[?7h\(esc)[?1h\(esc)=\(esc)[?25l\(esc)[39;49m\(esc)[H\(esc)[2J"
                    + "\(esc)[2d  1  \(esc)[39;49m\(esc)[1m[\(esc)[32m||||||\(esc)[31m|\(esc)[39;49m\(esc)[1m      12.4%]\(esc)[m   Tasks: \(esc)[1m31\(esc)[m, \(esc)[1m52\(esc)[m thr; \(esc)[1m1\(esc)[m running\r\n"
                    + "\(esc)[3;3H2  [||||||||       21.0%]   Load average: 0.42 0.37 0.30\(esc)[5;3HMem[||||||||||||   1.21G/3.83G]",
                "\(esc)[7;1H\(esc)[30m\(esc)[42m    PID USER      PRI  NI  VIRT   RES   SHR S CPU% MEM%   TIME+  Command\(esc)[K\(esc)[8;1H\(esc)[m    812 root       20   0 1238M 41352 18244 S  3.9  1.0 18:02.11 /usr/local/bin/sing-box run",
            ]
        ),
        Session(
            id: "term_demo_2c6n0d", node: "home-nas", status: "open",
            created: "-22m", opened: "-22m", lastSeen: "-22m"
        ),
        Session(
            id: "term_demo_9w1e5f", node: "edge-iad-1", tokenID: "tok_demo0007cli", shell: "/bin/sh", status: "pending",
            created: "-40s", lastSeen: "-40s"
        ),
        Session(
            id: "term_demo_5h2r8g", node: "core-lon-1", status: "closed",
            created: "-31m", opened: "-31m", closed: "-12m", lastSeen: "-12m", bytesIn: 38,
            output: [
                prompt("core-lon-1") + command("df -h /var/lib/lattice"),
                "Filesystem      Size  Used Avail Use% Mounted on\r\n/dev/vda1        79G   41G   35G  54% /\r\n",
                prompt("core-lon-1") + command("exit"),
                "logout\r\n",
            ]
        ),
        Session(
            id: "term_demo_1b7t3h", node: "edge-sin-1", status: "failed", error: "terminal session expired after inactivity",
            created: "-2h", opened: "-2h", closed: "-25m", lastSeen: "-25m", bytesIn: 14,
            output: [
                prompt("edge-sin-1") + command("uptime"),
                " 10:12:41 up 41 days,  3:02,  0 users,  load average: 0.08, 0.05, 0.01\r\n",
                prompt("edge-sin-1"),
            ]
        ),
        Session(
            id: "term_demo_3k5u7m", node: "build-fra-4", shell: "/usr/bin/zsh", status: "failed",
            error: "shell not available: stat /usr/bin/zsh: no such file or directory",
            created: "-27m", closed: "-27m", lastSeen: "-27m"
        ),
        Session(
            id: "term_demo_6p0y4j", node: "relay-fra-2", shell: "/bin/sh", status: "failed",
            error: "terminal session expired before node accepted it",
            created: "-28m", closed: "-18m", lastSeen: "-18m"
        ),
    ]

    public static func session(_ id: String) -> Session? {
        sessions.first { $0.id == id }
    }

    // MARK: Bodies

    static func sessionJSON(_ session: Session, closed: Bool) -> DemoJSON {
        let closedNow = closed && (session.status == "open" || session.status == "pending")
        let status = closedNow ? "closed" : session.status
        return .object([
            "id": .string(session.id),
            "node_id": .string(session.nodeID),
            "actor_id": .string(DemoWorld.actorID),
            "token_id": session.tokenID.isEmpty ? nil : .string(session.tokenID),
            "shell": .string(session.shell),
            "cols": 120,
            "rows": 32,
            "status": .string(status),
            "error": session.error.isEmpty ? nil : .string(session.error),
            "bytes_in": session.bytesIn == 0 ? nil : .number(Double(session.bytesIn)),
            "bytes_out": session.bytesOut == 0 ? nil : .number(Double(session.bytesOut)),
            "created_at": .time(session.created),
            "opened_at": session.opened.map { .time($0) },
            "closed_at": closedNow ? .time() : session.closed.map { .time($0) },
            "last_seen": closedNow ? .time() : .time(session.lastSeen),
        ])
    }

    static func listBody(closed: Set<String>) -> String {
        DemoJSON.object([("sessions", .array(sessions.map { sessionJSON($0, closed: closed.contains($0.id)) }))]).text
    }

    static func eventsBody(_ session: Session, closed: Bool, cursor: Int64) -> String {
        let events: [DemoJSON] = session.output.enumerated().compactMap { index, data in
            let seq = Int64(index + 1)
            guard seq > cursor else { return nil }
            return .object([
                "seq": .number(Double(seq)),
                "kind": "output",
                "data": .string(data),
                "created_at": .time(session.opened ?? session.created),
            ])
        }
        return DemoJSON.object([("session", sessionJSON(session, closed: closed)), ("events", .array(events))]).text
    }

    static var eventsEmptyBody: String {
        var session = sessions[0]
        session.output = []
        return eventsBody(session, closed: false, cursor: 0)
    }

    // MARK: Answers

    static func events(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        let id = request.segments.count > 3 ? request.segments[3] : ""
        if id == otherOperatorSessionID { return otherOperator }
        guard let session = session(id) else { return notFound }
        let cursor = Int64(request.query["cursor"] ?? "") ?? 0
        return .json(eventsBody(session, closed: await state.contains(id, in: closedSet), cursor: max(0, cursor)))
    }

    static func close(_ request: DemoRequest, state: DemoState) async -> DemoResponse {
        let id = request.segments.count > 3 ? request.segments[3] : ""
        if id == otherOperatorSessionID { return otherOperator }
        guard let session = session(id) else { return notFound }
        let alreadyClosed = await state.contains(id, in: closedSet)
        guard !alreadyClosed, session.status == "open" || session.status == "pending" else {
            return .error(status: 400, code: "bad_request", message: TerminalServerMessages.alreadyClosed)
        }
        await state.insert(id, into: closedSet)
        return .json(sessionJSON(session, closed: true).text)
    }

    static let notFound = DemoResponse.error(status: 404, code: "not_found", message: TerminalServerMessages.notFound)
    static let otherOperator = DemoResponse.error(status: 403, code: "forbidden", message: "terminal session belongs to another operator")
}
