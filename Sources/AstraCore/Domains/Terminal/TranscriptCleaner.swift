import Foundation

/// Turns raw terminal output into readable transcript lines (section 5.13).
///
/// CSI, OSC, DCS and charset sequences are removed. Carriage returns,
/// backspaces, tabs and the in-line cursor and erase sequences rewrite the
/// current line the way a terminal does, so a progress bar ends as its last
/// frame. Output written to the alternate screen (a full-screen program such
/// as htop or vim) is cursor-addressed and unreadable as lines, so it is left
/// out and marked with one `.fullScreen` line; `fullScreenActive` says the
/// program is still running when the output ends.
///
/// A program that saves the cursor, draws somewhere else on the screen and
/// restores it (apt's bottom progress line) does not touch the line it left:
/// what it draws after moving away goes to a scratch line that the restore
/// throws away. A move without a saved cursor is ignored, so the output after
/// `clear` is kept.
///
/// Lines are at most `maxColumns` wide: a cursor move stops at the right
/// margin and a character written past it wraps to a new line, as a terminal
/// with autowrap does. The bound matters because the counts in a cursor
/// sequence come from the remote shell, so one escape sequence in a printed
/// log must not overflow arithmetic or grow a line without limit.
///
/// The cleaner is incremental: `feed` keeps a sequence that was split across
/// two output events, so a poll only feeds what is new.
public struct TranscriptCleaner: Sendable, Equatable {
    public struct Line: Sendable, Equatable, Hashable, Identifiable {
        public enum Kind: Sendable, Equatable, Hashable {
            case text
            /// Where a full-screen program drew on the alternate screen.
            case fullScreen
        }

        /// The line number, from 1, stable while earlier lines are dropped.
        public var id: Int
        public var kind: Kind
        public var text: String

        public init(id: Int, kind: Kind = .text, text: String) {
            self.id = id
            self.kind = kind
            self.text = text
        }
    }

    /// The text a copied transcript carries for a `.fullScreen` line.
    public static let fullScreenPlaceholder = "[full-screen program output not shown]"

    private enum Mode: Sendable, Equatable {
        case ground
        case escape
        case escapeIntermediate
        case csi(String)
        /// OSC, DCS, SOS, PM and APC bodies, ended by BEL or ST (ESC \).
        case string(sawEscape: Bool)
    }

    /// Where ESC 7 or CSI s left the cursor: its column, and the line it was on.
    private struct SavedCursor: Sendable, Equatable {
        var column: Int
        var lineID: Int
    }

    /// The real line, set aside while the program draws elsewhere.
    private struct Parked: Sendable, Equatable {
        var line: [Unicode.Scalar]
        var column: Int
    }

    /// Lines kept in memory; older ones are dropped and counted.
    public var maxLines: Int
    /// The widest a line gets before it wraps.
    public let maxColumns: Int
    /// Completed lines, oldest first.
    private var completed: [Line] = []
    private var current: [Unicode.Scalar] = []
    private var column = 0
    private var mode = Mode.ground
    private var saved: SavedCursor?
    private var parked: Parked?
    private var nextID = 1
    /// True while a full-screen program holds the alternate screen.
    public private(set) var fullScreenActive = false
    /// How many times a full-screen program took the screen.
    public private(set) var fullScreenEntries = 0
    /// Lines dropped from the start to stay under `maxLines`.
    public private(set) var droppedLines = 0

    private static let tabWidth = 8
    private static let maxSequenceLength = 64

    /// The server caps a session at 300 columns, so 1,024 keeps every real
    /// line whole and still bounds a hostile one.
    public static let defaultMaxColumns = 1_024

    public init(maxLines: Int = 5_000, maxColumns: Int = TranscriptCleaner.defaultMaxColumns) {
        self.maxLines = max(1, maxLines)
        self.maxColumns = max(Self.tabWidth, maxColumns)
    }

    /// A cleaner that has read `raw` in one piece.
    public static func clean(_ raw: String, maxLines: Int = 5_000, maxColumns: Int = TranscriptCleaner.defaultMaxColumns) -> TranscriptCleaner {
        var cleaner = TranscriptCleaner(maxLines: maxLines, maxColumns: maxColumns)
        cleaner.feed(raw)
        return cleaner
    }

    /// Every line, with the unfinished last line (often the prompt) included
    /// when it has text.
    public var lines: [Line] {
        let tail = currentText
        guard !tail.isEmpty else { return completed }
        return completed + [Line(id: nextID, text: tail)]
    }

    /// The transcript as plain text, for Copy.
    public var text: String {
        lines.map { $0.kind == .fullScreen ? Self.fullScreenPlaceholder : $0.text }.joined(separator: "\n")
    }

    /// True when no line has any text.
    public var isEmpty: Bool {
        lines.allSatisfy { $0.kind == .text && $0.text.isEmpty }
    }

    /// The unfinished real line; a scratch line drawn elsewhere never shows.
    private var currentText: String {
        Self.trimmed(parked?.line ?? current)
    }

    private static func trimmed(_ scalars: [Unicode.Scalar]) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        var text = String(view)
        while text.last == " " { text.removeLast() }
        return text
    }

    // MARK: Input

    public mutating func feed(_ raw: String) {
        for scalar in raw.unicodeScalars {
            consume(scalar)
        }
    }

    private mutating func consume(_ scalar: Unicode.Scalar) {
        let value = scalar.value
        switch mode {
        case .ground:
            ground(scalar)
        case .escape:
            escape(scalar)
        case .escapeIntermediate:
            if value == 0x1B {
                mode = .escape
            } else if (0x20...0x2F).contains(value) {
                return
            } else {
                // The final byte (a charset name, a line-size code) ends it.
                mode = .ground
            }
        case .csi(let collected):
            if value == 0x1B {
                mode = .escape
            } else if (0x40...0x7E).contains(value) {
                mode = .ground
                dispatchCSI(parameters: collected, final: scalar)
            } else if (0x20...0x3F).contains(value) {
                // Past the cap the sequence stops growing but is still dropped whole.
                mode = collected.unicodeScalars.count >= Self.maxSequenceLength ? .csi(collected) : .csi(collected + String(scalar))
            } else if value < 0x20 {
                // A terminal executes a control character met inside a sequence.
                control(scalar)
            } else {
                mode = .ground
            }
        case .string(let sawEscape):
            if value == 0x07 || (sawEscape && value == 0x5C) || value == 0x9C {
                mode = .ground
            } else if sawEscape {
                // ESC followed by anything but "\" abandons the string and starts a sequence.
                mode = .escape
                escape(scalar)
            } else {
                mode = .string(sawEscape: value == 0x1B)
            }
        }
    }

    private mutating func ground(_ scalar: Unicode.Scalar) {
        let value = scalar.value
        switch value {
        case 0x1B:
            mode = .escape
        case 0x9B:
            mode = .csi("")
        case 0x90, 0x98, 0x9D, 0x9E, 0x9F:
            mode = .string(sawEscape: false)
        case 0x00...0x1F:
            control(scalar)
        case 0x7F...0x9F:
            return
        default:
            put(scalar)
        }
    }

    private mutating func escape(_ scalar: Unicode.Scalar) {
        switch scalar.value {
        case 0x5B: // [
            mode = .csi("")
        case 0x5D, 0x50, 0x58, 0x5E, 0x5F: // ] P X ^ _
            mode = .string(sawEscape: false)
        case 0x20...0x2F: // charset designations and other intermediates
            mode = .escapeIntermediate
        case 0x1B:
            mode = .escape
        case 0x45: // E, next line
            mode = .ground
            newline()
        case 0x37: // 7, save cursor
            mode = .ground
            saveCursor()
        case 0x38: // 8, restore cursor
            mode = .ground
            restoreCursor()
        case 0x44, 0x4D: // D index, M reverse index
            mode = .ground
            moveOffLine()
        case 0x63: // c, full reset
            mode = .ground
            returnToLine()
            saved = nil
        case 0x00...0x1F:
            control(scalar)
        default:
            // Keypad modes and the like draw nothing.
            mode = .ground
        }
    }

    private mutating func control(_ scalar: Unicode.Scalar) {
        switch scalar.value {
        case 0x0A, 0x0B, 0x0C:
            newline()
        case 0x0D:
            column = 0
        case 0x08:
            column = max(0, column - 1)
        case 0x09:
            column = min((column / Self.tabWidth + 1) * Self.tabWidth, lastColumn)
        default:
            // BEL, NUL, SO, SI and the rest draw nothing.
            return
        }
    }

    private mutating func dispatchCSI(parameters: String, final: Unicode.Scalar) {
        let isPrivate = parameters.hasPrefix("?")
        let numbers = parameters
            .trimmingCharacters(in: CharacterSet(charactersIn: "?<>="))
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0.filter(\.isNumber)) }
        let first = numbers.first.flatMap { $0 }
        // Clamped before any arithmetic: no move or edit reaches past the margin.
        let count = min(max(1, first ?? 1), maxColumns)

        if isPrivate, final == "h" || final == "l" {
            let alternate = numbers.contains { [1049, 1047, 47].contains($0 ?? -1) }
            if alternate { setFullScreen(final == "h") }
            return
        }
        // Everything drawn on the alternate screen is left out.
        guard !fullScreenActive else { return }

        if !isPrivate {
            switch final {
            case "s" where parameters.isEmpty:
                saveCursor()
                return
            case "u" where parameters.isEmpty:
                restoreCursor()
                return
            case "H", "f", "A", "B", "d", "E", "F", "r":
                // Off the line only matters while a restore is due; otherwise
                // the move is dropped and output keeps going to this line.
                moveOffLine()
                return
            default:
                break
            }
        }

        switch final {
        case "K":
            eraseInLine(first ?? 0)
        case "C", "a":
            column = min(column + count, lastColumn)
        case "D":
            column = max(0, column - count)
        case "G", "`":
            column = min(count - 1, lastColumn)
        case "P":
            if column < current.count {
                current.removeSubrange(column..<min(current.count, column + count))
            }
        case "@":
            if column <= current.count {
                current.insert(contentsOf: Array(repeating: " ", count: count), at: column)
                if current.count > maxColumns { current.removeSubrange(maxColumns...) }
            }
        case "X":
            if column < current.count {
                for index in column..<min(column + count, current.count) {
                    current[index] = " "
                }
            }
        default:
            // Colors (m), screen clears and modes do not change a transcript line.
            return
        }
    }

    // MARK: Line editing

    private var lastColumn: Int { maxColumns - 1 }

    private mutating func put(_ scalar: Unicode.Scalar) {
        guard !fullScreenActive else { return }
        if column >= maxColumns { newline() }
        if column < current.count {
            current[column] = scalar
        } else {
            if column > current.count {
                current.append(contentsOf: Array(repeating: " ", count: column - current.count))
            }
            current.append(scalar)
        }
        column += 1
    }

    private mutating func eraseInLine(_ mode: Int) {
        switch mode {
        case 0:
            if column < current.count { current.removeSubrange(column...) }
        case 1:
            guard !current.isEmpty else { return }
            for index in 0...min(column, current.count - 1) {
                current[index] = " "
            }
        default:
            current.removeAll()
        }
    }

    private mutating func newline() {
        guard !fullScreenActive else { return }
        if let parked {
            // A program that prints whole lines after moving away was not
            // drawing a status line, so its output is kept, after the real line.
            self.parked = nil
            saved = nil
            let text = Self.trimmed(parked.line)
            if !text.isEmpty { commit(Line(id: nextID, text: text)) }
        }
        commit(Line(id: nextID, text: currentText))
        current.removeAll()
        column = 0
    }

    private mutating func saveCursor() {
        guard !fullScreenActive, parked == nil else { return }
        saved = SavedCursor(column: column, lineID: nextID)
    }

    private mutating func restoreCursor() {
        guard !fullScreenActive, let saved else { return }
        returnToLine()
        // After a newline the saved line is committed; the cursor stays put.
        if saved.lineID == nextID { column = min(saved.column, lastColumn) }
        // Forgotten once used, so a later move (a clear before the prompt)
        // is dropped instead of sending the output to a scratch line.
        self.saved = nil
    }

    private mutating func moveOffLine() {
        guard !fullScreenActive, saved != nil, parked == nil else { return }
        parked = Parked(line: current, column: column)
        current.removeAll()
        column = 0
    }

    /// Drops the scratch line and puts the real line back.
    private mutating func returnToLine() {
        guard let parked else { return }
        current = parked.line
        column = parked.column
        self.parked = nil
    }

    private mutating func setFullScreen(_ on: Bool) {
        guard on != fullScreenActive else { return }
        returnToLine()
        saved = nil
        if on {
            if !currentText.isEmpty { newline() }
            current.removeAll()
            column = 0
            fullScreenEntries += 1
            commit(Line(id: nextID, kind: .fullScreen, text: ""))
        } else {
            // The main screen comes back as it was; the program's frames are gone.
            current.removeAll()
            column = 0
        }
        fullScreenActive = on
    }

    private mutating func commit(_ line: Line) {
        completed.append(line)
        nextID += 1
        if completed.count > maxLines {
            let overflow = completed.count - maxLines
            completed.removeFirst(overflow)
            droppedLines += overflow
        }
    }
}
