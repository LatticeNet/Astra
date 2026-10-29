import Foundation

// Ports of the console's query grammar (`lib/query/syntax.ts`, `engine.ts`,
// `values.ts`), section 6.14. Lists filter on device with a compiled query;
// the golden is `Checks/AstraCoreCheck/Fixtures/query-vectors.json`.
//
// This file reads the text into a tree (`syntax.ts`); `QueryEngine.swift`
// checks the tree against a page's fields and runs it, and `QueryValues.swift`
// reads typed values. Offsets are UTF-16 positions, as in the console, so an
// error points at the same character in both.

/// `:` contains, `=` exact, and the four comparisons.
public enum LatticeQueryOperator: String, Sendable, Hashable, CaseIterable {
    case contains = ":"
    case exact = "="
    case greater = ">"
    case greaterOrEqual = ">="
    case less = "<"
    case lessOrEqual = "<="
}

/// One value of a term, with its source offsets.
public struct LatticeQueryValue: Sendable, Hashable {
    public var text: String
    public var quoted: Bool
    public var start: Int
    public var end: Int

    public init(text: String, quoted: Bool, start: Int, end: Int) {
        self.text = text
        self.quoted = quoted
        self.start = start
        self.end = end
    }
}

/// `field:value`, `field=value`, `field>value`, with `|` alternatives.
public struct LatticeQueryTerm: Sendable, Hashable {
    /// The key as typed, lowercased.
    public var field: String
    public var op: LatticeQueryOperator
    public var values: [LatticeQueryValue]
    public var start: Int
    public var end: Int
    /// The word as typed, for a key that turns out to be text after all.
    public var raw: String
    /// The key alone, for an error that names an unknown field.
    public var fieldStart: Int
    public var fieldEnd: Int

    public init(field: String, op: LatticeQueryOperator, values: [LatticeQueryValue], start: Int, end: Int, raw: String) {
        self.init(field: field, op: op, values: values, start: start, end: end, raw: raw, fieldStart: start, fieldEnd: start + field.utf16.count)
    }

    public init(field: String, op: LatticeQueryOperator, values: [LatticeQueryValue], start: Int, end: Int, raw: String, fieldStart: Int, fieldEnd: Int) {
        self.field = field
        self.op = op
        self.values = values
        self.start = start
        self.end = end
        self.raw = raw
        self.fieldStart = fieldStart
        self.fieldEnd = fieldEnd
    }

    /// The console tests' compact form: `cpu>=80%`, `status:offline,degraded`.
    public var compact: String {
        field + op.rawValue + values.map(\.text).joined(separator: ",")
    }
}

/// `sort:-cpu,name`.
public struct LatticeQuerySortKey: Sendable, Hashable {
    public var field: String
    public var descending: Bool
    public var start: Int
    public var end: Int

    public init(field: String, descending: Bool) {
        self.init(field: field, descending: descending, start: 0, end: 0)
    }

    public init(field: String, descending: Bool, start: Int, end: Int) {
        self.field = field
        self.descending = descending
        self.start = start
        self.end = end
    }
}

/// The parsed tree.
public indirect enum LatticeQueryNode: Sendable, Hashable {
    case and([LatticeQueryNode])
    case or([LatticeQueryNode])
    case not(LatticeQueryNode)
    case term(LatticeQueryTerm)
    case text(String, quoted: Bool)
}

/// A parse or compile error with the offending source range (`QueryErrorCode`).
public struct LatticeQueryError: Error, Sendable, Hashable {
    public enum Code: String, Sendable, Hashable, CaseIterable {
        case unclosedParen, unexpectedParen, unclosedQuote, danglingOperator, nothingToNegate
        case emptyGroup, notArity, callArity, sortNested, emptyValue, unknownField, unknownValue
        case unknownFlag, unknownSort, badNumber, badDuration, badTime, badBool, badVersion
        case noCompare, needsCompare
    }

    public var code: Code
    public var start: Int
    public var end: Int
    public var params: [String: String]

    public init(code: Code, start: Int, end: Int, params: [String: String] = [:]) {
        self.code = code
        self.start = start
        self.end = end
        self.params = params
    }
}

/// A query as typed and parsed: the tree and the sort keys.
public struct LatticeQuery: Sendable, Hashable {
    public var source: String
    public var tree: LatticeQueryNode?
    public var sorts: [LatticeQuerySortKey]

    public init(source: String, tree: LatticeQueryNode?, sorts: [LatticeQuerySortKey]) {
        self.source = source
        self.tree = tree
        self.sorts = sorts
    }

    /// The empty query: every row, in the page's order.
    public static let empty = LatticeQuery(source: "", tree: nil, sorts: [])

    public var isEmpty: Bool { tree == nil && sorts.isEmpty }

    /// `parseQuery`.
    public static func parse(_ input: String) -> Result<LatticeQuery, LatticeQueryError> {
        parseWithSpans(input).map(\.query)
    }

    /// `withoutSorts`: the query text with its `sort:` terms removed, the
    /// rest as typed. A query that does not parse loses the words that start
    /// with `sort:`.
    public static func withoutSorts(_ input: String) -> String {
        guard case .success(let parsed) = parseWithSpans(input) else {
            let pattern = try? NSRegularExpression(pattern: #"(^|\s)sort:\S*"#)
            let range = NSRange(location: 0, length: (input as NSString).length)
            let stripped = pattern?.stringByReplacingMatches(in: input, range: range, withTemplate: "$1") ?? input
            return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var out = Array(input.utf16)
        for span in parsed.sortTerms.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            // Take one neighbouring space with the term, so "a sort:x b" reads "a b".
            var start = span.lowerBound
            var end = span.upperBound
            if start > 0, QueryLexer.isWhitespace(out[start - 1]) {
                start -= 1
            } else if end < out.count, QueryLexer.isWhitespace(out[end]) {
                end += 1
            }
            out.removeSubrange(start..<end)
        }
        return String(decoding: out, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseWithSpans(_ input: String) -> Result<(query: LatticeQuery, sortTerms: [Range<Int>]), LatticeQueryError> {
        do {
            let units = Array(input.utf16)
            var parser = QueryParser(tokens: try QueryLexer.lex(units), input: units)
            let split = QueryParser.splitSorts(try parser.parseQuery())
            return .success((LatticeQuery(source: input, tree: split.tree?.publicNode, sorts: split.sorts), split.sortTerms))
        } catch let error as LatticeQueryError {
            return .failure(error)
        } catch {
            return .failure(LatticeQueryError(code: .unexpectedParen, start: 0, end: 0))
        }
    }
}

// MARK: - Lexing

/// One token of the query text.
struct QueryToken {
    enum Kind { case word, lparen, rparen, comma, pipe, minus }

    var kind: Kind
    var start: Int
    var end: Int
    /// The word with quotes removed and escapes applied.
    var text: [UInt16] = []
    /// Source offset of each unit of `text`.
    var at: [Int] = []
    /// Index in `text` where the first quoted run begins; `text.count` when nothing was quoted.
    var bare: Int = 0

    var string: String { String(decoding: text, as: UTF16.self) }
    var isQuoted: Bool { bare < text.count }
}

enum QueryLexer {
    static let quote = UInt16(UInt8(ascii: "\""))
    static let backslash = UInt16(UInt8(ascii: "\\"))
    static let lparen = UInt16(UInt8(ascii: "("))
    static let rparen = UInt16(UInt8(ascii: ")"))
    static let comma = UInt16(UInt8(ascii: ","))
    static let pipe = UInt16(UInt8(ascii: "|"))
    static let minus = UInt16(UInt8(ascii: "-"))

    /// The separators of `syntax.ts` `isSpace`, including the no-break space.
    static func isSpace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x20, 0x09, 0x0A, 0x0D, 0x0C, 0x0B, 0xA0: true
        default: false
        }
    }

    /// JavaScript's `\s`, used where the console tests with a regular expression.
    static func isWhitespace(_ unit: UInt16) -> Bool {
        if isSpace(unit) { return true }
        switch unit {
        case 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        default: return false
        }
    }

    static func isBreak(_ unit: UInt16) -> Bool {
        unit == lparen || unit == rparen || unit == comma || unit == pipe
    }

    static func lex(_ input: [UInt16]) throws -> [QueryToken] {
        var tokens: [QueryToken] = []
        var i = 0
        let n = input.count
        while i < n {
            let ch = input[i]
            if isSpace(ch) {
                i += 1
                continue
            }
            switch ch {
            case lparen: tokens.append(QueryToken(kind: .lparen, start: i, end: i + 1))
            case rparen: tokens.append(QueryToken(kind: .rparen, start: i, end: i + 1))
            case comma: tokens.append(QueryToken(kind: .comma, start: i, end: i + 1))
            case pipe: tokens.append(QueryToken(kind: .pipe, start: i, end: i + 1))
            case minus where i + 1 >= n || input[i + 1] != minus:
                // A minus that opens a word or a group negates it: -cap:root, -(a OR b).
                // Inside a word it is a character: sing-box, sort:-cpu.
                tokens.append(QueryToken(kind: .minus, start: i, end: i + 1))
            default:
                i = try lexWord(input, from: i, into: &tokens)
                continue
            }
            i += 1
        }
        return tokens
    }

    private static func lexWord(_ input: [UInt16], from: Int, into tokens: inout [QueryToken]) throws -> Int {
        var text: [UInt16] = []
        var at: [Int] = []
        var bare = -1
        var i = from
        let n = input.count
        while i < n {
            let ch = input[i]
            if ch == quote {
                if bare < 0 { bare = text.count }
                let open = i
                i += 1
                var closed = false
                while i < n {
                    let c = input[i]
                    if c == backslash, i + 1 < n {
                        text.append(input[i + 1])
                        at.append(i + 1)
                        i += 2
                        continue
                    }
                    if c == quote {
                        closed = true
                        i += 1
                        break
                    }
                    text.append(c)
                    at.append(i)
                    i += 1
                }
                if !closed { throw LatticeQueryError(code: .unclosedQuote, start: open, end: n) }
                continue
            }
            if isSpace(ch) || isBreak(ch) { break }
            text.append(ch)
            at.append(i)
            i += 1
        }
        tokens.append(QueryToken(kind: .word, start: from, end: i, text: text, at: at, bare: bare < 0 ? text.count : bare))
        return i
    }
}

// MARK: - Parsing

/// The parser's tree: the public nodes plus the spans and sort nodes the
/// public tree drops.
indirect enum QueryParsedNode {
    case and([QueryParsedNode], start: Int, end: Int)
    case or([QueryParsedNode], start: Int, end: Int)
    case not(QueryParsedNode, start: Int, end: Int)
    case term(LatticeQueryTerm)
    case text(String, quoted: Bool, start: Int, end: Int)
    case sort([LatticeQuerySortKey], start: Int, end: Int)

    var start: Int {
        switch self {
        case .and(_, let start, _), .or(_, let start, _), .not(_, let start, _), .text(_, _, let start, _), .sort(_, let start, _): start
        case .term(let term): term.start
        }
    }

    var end: Int {
        switch self {
        case .and(_, _, let end), .or(_, _, let end), .not(_, _, let end), .text(_, _, _, let end), .sort(_, _, let end): end
        case .term(let term): term.end
        }
    }

    var isSort: Bool {
        if case .sort = self { return true }
        return false
    }

    /// The public node; a sort never reaches here because the parser refuses it below the top level.
    var publicNode: LatticeQueryNode {
        switch self {
        case .and(let items, _, _): .and(items.map(\.publicNode))
        case .or(let items, _, _): .or(items.map(\.publicNode))
        case .not(let item, _, _): .not(item.publicNode)
        case .term(let term): .term(term)
        case .text(let value, let quoted, _, _): .text(value, quoted: quoted)
        case .sort: .and([])
        }
    }
}

struct QueryParser {
    struct Context {
        /// The innermost bracket is an AND(...)/OR(...)/NOT(...) call: commas separate arguments.
        var inCall: Bool
        /// Inside a group, a call, an OR or a negation: sort: is refused here.
        var nested: Bool
    }

    private var pos = 0
    private let tokens: [QueryToken]
    private let input: [UInt16]

    init(tokens: [QueryToken], input: [UInt16]) {
        self.tokens = tokens
        self.input = input
    }

    private func peek(_ offset: Int = 0) -> QueryToken? {
        let index = pos + offset
        return index < tokens.count ? tokens[index] : nil
    }

    private mutating func next() -> QueryToken {
        let token = tokens[pos]
        pos += 1
        return token
    }

    private func isKeyword(_ token: QueryToken?, _ word: String) -> Bool {
        guard let token, token.kind == .word, !token.isQuoted else { return false }
        return token.string == word
    }

    /// The next word names a call (`and`, `OR`, `Not`) with "(" after it.
    private func isCall(_ offset: Int = 0) -> Bool {
        guard let token = peek(offset), token.kind == .word, !token.isQuoted,
              ["and", "or", "not"].contains(token.string.lowercased()) else { return false }
        return peek(offset + 1)?.kind == .lparen
    }

    private func atStop(_ context: Context) -> Bool {
        guard let token = peek() else { return true }
        if token.kind == .rparen { return true }
        return token.kind == .comma && context.inCall
    }

    private static func fail(_ code: LatticeQueryError.Code, _ start: Int, _ end: Int, _ params: [String: String] = [:]) -> LatticeQueryError {
        LatticeQueryError(code: code, start: start, end: end, params: params)
    }

    mutating func parseQuery() throws -> QueryParsedNode? {
        let tree = try parseAnd(Context(inCall: false, nested: false))
        // Outside a call only a ")" stops the top level.
        if let token = peek() { throw Self.fail(.unexpectedParen, token.start, token.end) }
        return tree
    }

    private mutating func parseAnd(_ context: Context) throws -> QueryParsedNode? {
        var items: [QueryParsedNode] = []
        var pendingAnd: QueryToken?
        while !atStop(context) {
            guard let token = peek() else { break }
            if token.kind == .comma {
                // Outside a call a comma separates terms as a space does.
                _ = next()
                continue
            }
            // After an operand AND is the operator; right after that operator, AND( is a call.
            if !items.isEmpty, isKeyword(token, "AND"), !(pendingAnd != nil && isCall()) {
                if let pending = pendingAnd { throw Self.fail(.danglingOperator, pending.start, pending.end, ["op": "AND"]) }
                pendingAnd = next()
                continue
            }
            items.append(try parseOr(context))
            pendingAnd = nil
        }
        if let pending = pendingAnd { throw Self.fail(.danglingOperator, pending.start, pending.end, ["op": "AND"]) }
        guard let first = items.first, let last = items.last else { return nil }
        return items.count == 1 ? first : .and(items, start: first.start, end: last.end)
    }

    private func isOr(_ token: QueryToken?) -> Bool {
        token?.kind == .pipe || isKeyword(token, "OR")
    }

    /// An operand starts here: not the end, a comma, `|`, or a bare AND/OR that is not a call.
    private func operandFollows(_ context: Context) -> Bool {
        guard !atStop(context), let token = peek() else { return false }
        if token.kind == .comma || token.kind == .pipe { return false }
        return !((isKeyword(token, "AND") || isKeyword(token, "OR")) && !isCall())
    }

    private mutating func parseOr(_ context: Context) throws -> QueryParsedNode {
        let first = try parseUnary(context)
        guard isOr(peek()) else { return first }
        let inner = Context(inCall: context.inCall, nested: true)
        var items = [first]
        while isOr(peek()) {
            let op = next()
            if !operandFollows(context) {
                throw Self.fail(.danglingOperator, op.start, op.end, ["op": op.kind == .pipe ? "|" : "OR"])
            }
            items.append(try parseUnary(inner))
        }
        // A sort inside an OR is refused; the first operand was read before the OR was seen.
        if let sort = items.first(where: \.isSort) { throw Self.fail(.sortNested, sort.start, sort.end) }
        return .or(items, start: first.start, end: items[items.count - 1].end)
    }

    private mutating func parseUnary(_ context: Context) throws -> QueryParsedNode {
        let token = peek()
        if token?.kind == .minus || (isKeyword(token, "NOT") && !isCall()) {
            let op = next()
            if !operandFollows(context) { throw Self.fail(.nothingToNegate, op.start, op.end) }
            let item = try parseUnary(Context(inCall: context.inCall, nested: true))
            if item.isSort { throw Self.fail(.sortNested, op.start, item.end) }
            return .not(item, start: op.start, end: item.end)
        }
        return try parsePrimary(context)
    }

    private mutating func parsePrimary(_ context: Context) throws -> QueryParsedNode {
        guard let token = peek() else { throw Self.fail(.danglingOperator, input.count, input.count) }
        switch token.kind {
        case .lparen:
            _ = next()
            if let close = peek(), close.kind == .rparen { throw Self.fail(.emptyGroup, token.start, close.end) }
            let inner = try parseAnd(Context(inCall: false, nested: true))
            guard let close = peek(), close.kind == .rparen else { throw Self.fail(.unclosedParen, token.start, token.end) }
            _ = next()
            guard let inner else { throw Self.fail(.emptyGroup, token.start, close.end) }
            return inner
        case .rparen:
            throw Self.fail(.unexpectedParen, token.start, token.end)
        case .comma, .pipe:
            throw Self.fail(.danglingOperator, token.start, token.end, ["op": token.kind == .pipe ? "|" : ","])
        case .word, .minus:
            break
        }
        if isCall() { return try parseCall() }
        if isKeyword(token, "AND") || isKeyword(token, "OR") {
            throw Self.fail(.danglingOperator, token.start, token.end, ["op": token.string])
        }
        return try parseWord(context)
    }

    private mutating func parseCall() throws -> QueryParsedNode {
        let name = next()
        let open = next()
        let op = name.string.uppercased()
        var args: [QueryParsedNode] = []
        let context = Context(inCall: true, nested: true)
        while true {
            guard let token = peek() else { throw Self.fail(.unclosedParen, open.start, open.end) }
            if token.kind == .rparen { break }
            if token.kind == .comma {
                // Empty arguments are dropped: OR(a,,b) is OR(a, b).
                _ = next()
                continue
            }
            if let arg = try parseAnd(context) {
                if arg.isSort { throw Self.fail(.sortNested, arg.start, arg.end) }
                args.append(arg)
            }
        }
        let close = next()
        if op == "NOT" {
            guard args.count == 1 else { throw Self.fail(.notArity, name.start, close.end) }
            return .not(args[0], start: name.start, end: close.end)
        }
        if args.isEmpty { throw Self.fail(.callArity, name.start, close.end, ["op": op]) }
        if args.count == 1 { return args[0] }
        return op == "AND" ? .and(args, start: name.start, end: close.end) : .or(args, start: name.start, end: close.end)
    }

    private mutating func parseWord(_ context: Context) throws -> QueryParsedNode {
        let word = next()
        guard var term = Self.readTerm(word) else {
            return .text(word.string, quoted: word.isQuoted, start: word.start, end: word.end)
        }
        // field:a,b lists values. Inside a call the comma separates arguments instead.
        if !context.inCall { try readValueList(&term) }
        guard term.field == "sort" else { return .term(term) }
        if context.nested { throw Self.fail(.sortNested, term.start, term.end) }
        var keys: [LatticeQuerySortKey] = []
        for value in term.values {
            if value.text.isEmpty || value.text == "-" {
                throw Self.fail(.emptyValue, value.start, value.end, ["field": "sort"])
            }
            let descending = value.text.hasPrefix("-")
            let field = (descending ? String(value.text.dropFirst()) : value.text).lowercased()
            keys.append(LatticeQuerySortKey(field: field, descending: descending, start: value.start, end: value.end))
        }
        return .sort(keys, start: term.start, end: term.end)
    }

    private mutating func readValueList(_ term: inout LatticeQueryTerm) throws {
        while true {
            guard let comma = peek(), comma.kind == .comma, comma.start == term.end else { return }
            // A member may start with a minus, which the lexer read as negation: sort:name,-cpu.
            let minus = peek(1).flatMap { $0.kind == .minus && $0.start == comma.end ? $0 : nil }
            let after = peek(minus == nil ? 1 : 2)
            guard let after, after.kind == .word, after.start == (minus ?? comma).end else {
                // "status:offline," while typing: the empty member is named.
                throw Self.fail(.emptyValue, comma.start, comma.end, ["field": term.field])
            }
            _ = next()
            if minus != nil { _ = next() }
            let word = next()
            term.values.append(LatticeQueryValue(
                text: minus == nil ? word.string : "-" + word.string,
                quoted: word.isQuoted,
                start: minus?.start ?? word.start,
                end: word.end
            ))
            term.end = word.end
            term.raw = String(decoding: input[term.start..<term.end], as: UTF16.self)
        }
    }

    /// A word as a field term, or nil when it is text. The key must be typed
    /// outside quotes and start with a letter, so `"node:x"`, `2001:db8::1`
    /// and `10.0.0.1:22` stay text.
    static func readTerm(_ word: QueryToken) -> LatticeQueryTerm? {
        let text = word.text
        let at = word.at
        let bare = word.bare
        let operators = Set(":<>=".utf16)
        var i = 0
        while i < bare, !operators.contains(text[i]) { i += 1 }
        if i == 0 || i >= bare { return nil }
        let key = String(decoding: text[0..<i], as: UTF16.self)
        guard isKey(key) else { return nil }
        let rest = String(decoding: text[i..<min(bare, i + 3)], as: UTF16.self)
        let op: LatticeQueryOperator
        var j = i
        if rest.hasPrefix(":>=") || rest.hasPrefix(":<=") {
            op = rest.hasPrefix(":>=") ? .greaterOrEqual : .lessOrEqual
            j += 3
        } else if rest.hasPrefix(":=") || rest.hasPrefix(":>") || rest.hasPrefix(":<") {
            op = rest.hasPrefix(":=") ? .exact : (rest.hasPrefix(":>") ? .greater : .less)
            j += 2
        } else if rest.hasPrefix(">=") || rest.hasPrefix("<=") {
            op = rest.hasPrefix(">=") ? .greaterOrEqual : .lessOrEqual
            j += 2
        } else if rest.hasPrefix("==") {
            op = .exact
            j += 2
        } else {
            op = LatticeQueryOperator(rawValue: String(rest.prefix(1))) ?? .contains
            j += 1
        }
        let valueText = String(decoding: text[j...], as: UTF16.self)
        let valueStart = j < at.count ? at[j] : word.end
        return LatticeQueryTerm(
            field: key.lowercased(),
            op: op,
            values: [LatticeQueryValue(text: valueText, quoted: bare < text.count && bare >= j, start: valueStart, end: word.end)],
            start: word.start,
            end: word.end,
            raw: word.string,
            fieldStart: word.start,
            fieldEnd: at[i - 1] + 1
        )
    }

    /// `^[a-z][a-z0-9_-]*$`, case-insensitive.
    private static func isKey(_ key: String) -> Bool {
        let units = Array(key.utf8)
        guard let first = units.first, isLetter(first) else { return false }
        return units.dropFirst().allSatisfy { isLetter($0) || ($0 >= 48 && $0 <= 57) || $0 == 95 || $0 == 45 }
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
    }

    /// Pulls the top-level sorts out; a sort anywhere else was refused while parsing.
    static func splitSorts(_ tree: QueryParsedNode?) -> (tree: QueryParsedNode?, sorts: [LatticeQuerySortKey], sortTerms: [Range<Int>]) {
        guard let tree else { return (nil, [], []) }
        switch tree {
        case .sort(let keys, let start, let end):
            return (nil, keys, [start..<end])
        case .and(let all, _, _):
            var sorts: [LatticeQuerySortKey] = []
            var sortTerms: [Range<Int>] = []
            var items: [QueryParsedNode] = []
            for item in all {
                if case .sort(let keys, let start, let end) = item {
                    sorts += keys
                    sortTerms.append(start..<end)
                } else {
                    items.append(item)
                }
            }
            guard let first = items.first, let last = items.last else { return (nil, sorts, sortTerms) }
            return (items.count == 1 ? first : .and(items, start: first.start, end: last.end), sorts, sortTerms)
        default:
            return (tree, [], [])
        }
    }
}
