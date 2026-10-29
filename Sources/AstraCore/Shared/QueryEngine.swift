import Foundation

// A port of the console's `lib/query/engine.ts`: runs a parsed query against
// a page's typed fields. Every term is checked against the fields before
// anything is filtered, so a typo (`stauts:offline`, `cpu>eighty`) is an
// error that names the field and the character, never a silent empty list.

/// The kind of value a field holds, which decides how terms compare.
public enum LatticeQueryFieldType: String, Sendable, Hashable, CaseIterable {
    case string, list, enumeration = "enum", bool, number, duration, time, version
}

/// Which suffixes a number value may carry (`values.ts` `NumberUnit`).
public enum LatticeQueryNumberUnit: String, Sendable, Hashable, CaseIterable {
    case plain, percent, bytes, rate
}

/// A row's value for one field.
public enum LatticeQueryFieldValue: Sendable, Hashable {
    case none
    case string(String)
    case strings([String])
    case number(Double)
    case numbers([Double])
    case bool(Bool)
    case time(Date)
}

/// One field of a domain's query schema (`engine.ts` `QueryField`).
public struct LatticeQueryField<Row>: Sendable {
    /// The canonical name, lowercase.
    public var key: String
    public var aliases: [String]
    public var type: LatticeQueryFieldType
    public var unit: LatticeQueryNumberUnit
    /// For enum fields: the vocabulary, in the order `sort:` uses.
    public var values: [String]
    /// Words that stand for a value: `never` for `never_reported`.
    public var valueAliases: [String: String]
    /// A bool field listed under `is:`.
    public var flag: Bool
    /// False when the field does not sort.
    public var sortable: Bool
    public var get: @Sendable (Row) -> LatticeQueryFieldValue
    /// A matcher for `:` and `=` that knows more than the value; nil falls back to the value.
    public var match: (@Sendable (Row, String, Bool) -> Bool?)?

    public init(
        key: String,
        aliases: [String] = [],
        type: LatticeQueryFieldType,
        unit: LatticeQueryNumberUnit = .plain,
        values: [String] = [],
        valueAliases: [String: String] = [:],
        flag: Bool = false,
        sortable: Bool = true,
        get: @escaping @Sendable (Row) -> LatticeQueryFieldValue,
        match: (@Sendable (Row, String, Bool) -> Bool?)? = nil
    ) {
        self.key = key
        self.aliases = aliases
        self.type = type
        self.unit = unit
        self.values = values
        self.valueAliases = valueAliases
        self.flag = flag
        self.sortable = sortable
        self.get = get
        self.match = match
    }
}

/// A domain's query schema: its fields and the texts a bare word searches.
/// Nodes use the fields of `lib/query/nodeFields.ts`.
public protocol QueryFieldProvider: SendableMetatype {
    associatedtype Row
    static var fields: [LatticeQueryField<Row>] { get }
    static func text(_ row: Row) -> [String]
    /// One more way a bare word may match a row; false by default.
    static func bare(_ row: Row, word: String) -> Bool
}

public extension QueryFieldProvider {
    static func bare(_ row: Row, word: String) -> Bool { false }
}

/// A query compiled against a schema (`engine.ts` `CompiledQuery`).
public struct LatticeCompiledQuery<Row>: Sendable {
    public var source: String
    /// Whether a row passes; `now` is what ages are measured against.
    public var test: @Sendable (Row, Date) -> Bool
    /// Relevance from the bare words outside a negation; nil when there are none.
    public var score: (@Sendable (Row) -> Double)?
    public var sorts: [(field: LatticeQueryField<Row>, descending: Bool)]
    /// Kept for source compatibility. The console refuses an unknown field
    /// with an `unknownField` error (the shared vectors pin it), so a
    /// compiled query never carries one.
    public var unknownFields: [String]
    /// The query asks for nothing: every row, in the page's order.
    public var isEmpty: Bool

    public init(
        source: String,
        test: @escaping @Sendable (Row, Date) -> Bool,
        score: (@Sendable (Row) -> Double)? = nil,
        sorts: [(field: LatticeQueryField<Row>, descending: Bool)] = [],
        unknownFields: [String] = [],
        isEmpty: Bool
    ) {
        self.source = source
        self.test = test
        self.score = score
        self.sorts = sorts
        self.unknownFields = unknownFields
        self.isEmpty = isEmpty
    }
}

/// `compileQuery` and `applyQuery`.
public enum LatticeQueryEngine {
    /// The shared value aliases for bare words and string fields (`TOKEN_ALIASES`).
    public static let tokenAliases: [String: String] = ["macos": "darwin", "mac": "darwin", "drawin": "darwin"]

    public static func compile<Provider: QueryFieldProvider>(
        _ input: String,
        provider: Provider.Type
    ) -> Result<LatticeCompiledQuery<Provider.Row>, LatticeQueryError> {
        compile(
            input,
            fields: Provider.fields,
            text: { Provider.text($0) },
            bare: { Provider.bare($0, word: $1) }
        )
    }

    /// Compiles against a schema given as values, for schemas built at run time.
    public static func compile<Row>(
        _ input: String,
        fields: [LatticeQueryField<Row>],
        text: @escaping @Sendable (Row) -> [String],
        bare: (@Sendable (Row, String) -> Bool)? = nil,
        aliases: [String: String] = LatticeQueryEngine.tokenAliases
    ) -> Result<LatticeCompiledQuery<Row>, LatticeQueryError> {
        let parsed: LatticeQuery
        switch LatticeQuery.parse(input) {
        case .success(let query): parsed = query
        case .failure(let error): return .failure(error)
        }
        let schema = QuerySchema(fields: fields, text: text, bare: bare, aliases: aliases)
        do {
            let sorts = try parsed.sorts.map { key -> (field: LatticeQueryField<Row>, descending: Bool) in
                guard let field = schema.index[key.field], field.sortable else {
                    let sortable = fields.filter(\.sortable).flatMap { [$0.key] + $0.aliases }
                    throw LatticeQueryError(code: .unknownSort, start: key.start, end: key.end, params: [
                        "field": key.field,
                        "suggestion": QuerySchema<Row>.closest(key.field, sortable) ?? "",
                    ])
                }
                return (field, key.descending)
            }
            var scorers: [@Sendable (Row) -> Double] = []
            let test: @Sendable (Row, Date) -> Bool
            if let tree = parsed.tree {
                test = try schema.compile(tree, negated: false, scorers: &scorers)
            } else {
                test = { _, _ in true }
            }
            let collected = scorers
            let score: (@Sendable (Row) -> Double)? = collected.isEmpty ? nil : { @Sendable row in
                collected.reduce(0) { $0 + $1(row) }
            }
            return .success(LatticeCompiledQuery(
                source: input,
                test: test,
                score: score,
                sorts: sorts,
                isEmpty: parsed.tree == nil && sorts.isEmpty
            ))
        } catch let error as LatticeQueryError {
            return .failure(error)
        } catch {
            return .failure(LatticeQueryError(code: .unknownField, start: 0, end: 0))
        }
    }

    /// Filters and orders `rows`. The rows arrive in the page's own order; a
    /// sort replaces it, relevance floats bare-word matches up within it, and
    /// ties keep it.
    public static func apply<Row>(_ query: LatticeCompiledQuery<Row>, to rows: [Row], now: Date) -> [Row] {
        if query.isEmpty { return rows }
        let kept = rows.filter { query.test($0, now) }
        if !query.sorts.isEmpty {
            return stableSorted(kept) { compareSorted($0, $1, sorts: query.sorts) }
        }
        if let score = query.score {
            let scored = kept.map { (row: $0, score: score($0)) }
            return stableSorted(scored) { $1.score < $0.score ? -1 : ($1.score > $0.score ? 1 : 0) }.map(\.row)
        }
        return kept
    }

    /// The comparator for a query's sorts; missing values go last whichever the direction.
    public static func compareSorted<Row>(_ a: Row, _ b: Row, sorts: [(field: LatticeQueryField<Row>, descending: Bool)]) -> Int {
        for (field, descending) in sorts {
            let x = sortKey(field, a)
            let y = sortKey(field, b)
            if x == nil || y == nil {
                let diff = compareKeys(x, y, version: false)
                if diff != 0 { return diff }
                continue
            }
            let diff = compareKeys(x, y, version: field.type == .version)
            if diff != 0 { return descending ? -diff : diff }
        }
        return 0
    }

    private static func stableSorted<T>(_ items: [T], by compare: (T, T) -> Int) -> [T] {
        items.enumerated().sorted { lhs, rhs in
            let diff = compare(lhs.element, rhs.element)
            return diff != 0 ? diff < 0 : lhs.offset < rhs.offset
        }.map(\.element)
    }

    private enum SortKey {
        case number(Double)
        case text(String)

        var asText: String {
            switch self {
            case .number(let value): QueryValueReading.jsString(value)
            case .text(let text): text
            }
        }
    }

    private static func sortKey<Row>(_ field: LatticeQueryField<Row>, _ row: Row) -> SortKey? {
        let raw = field.get(row)
        switch field.type {
        case .number, .duration:
            return QueryValueReading.numbers(raw).min().map(SortKey.number)
        case .time:
            return QueryValueReading.timeValue(raw).map(SortKey.number)
        case .bool:
            if case .bool(let value) = raw { return .number(value ? 1 : 0) }
            return nil
        case .enumeration:
            guard let first = QueryValueReading.lowerTexts(raw).first else { return nil }
            if let index = field.values.firstIndex(where: { $0.lowercased() == first }) { return .number(Double(index)) }
            return .text(first)
        case .string, .list, .version:
            switch raw {
            case .number(let value): return .number(value)
            case .string(let text): return text.isEmpty ? nil : .text(text)
            case .strings(let texts):
                let present = texts.filter { !$0.isEmpty }
                return present.isEmpty ? nil : .text(present.joined(separator: ", "))
            case .numbers(let values): return values.isEmpty ? nil : .text(values.map(QueryValueReading.jsString).joined(separator: ", "))
            case .bool(let value): return .text(value ? "true" : "false")
            case .time(let date): return .text(AstraDateParser.string(from: date))
            case .none: return nil
            }
        }
    }

    private static func compareKeys(_ a: SortKey?, _ b: SortKey?, version: Bool) -> Int {
        guard let a, let b else {
            if a == nil && b == nil { return 0 }
            return a == nil ? 1 : -1
        }
        if case .number(let x) = a, case .number(let y) = b { return x < y ? -1 : (x > y ? 1 : 0) }
        if version { return LatticeQueryValues.compareVersions(a.asText, b.asText) }
        return LatticeQueryValues.localeCompare(a.asText, b.asText, numeric: true, ignoreCase: true)
    }
}

/// Reading field values the way the console's engine reads JavaScript values.
enum QueryValueReading {
    static func lowerTexts(_ value: LatticeQueryFieldValue) -> [String] {
        switch value {
        case .none: []
        case .string(let text): text.isEmpty ? [] : [text.lowercased()]
        case .strings(let texts): texts.filter { !$0.isEmpty }.map { $0.lowercased() }
        case .number(let number): [jsString(number)]
        case .numbers(let numbers): numbers.map(jsString)
        case .bool(let flag): [flag ? "true" : "false"]
        case .time(let date): [AstraDateParser.string(from: date).lowercased()]
        }
    }

    static func numbers(_ value: LatticeQueryFieldValue) -> [Double] {
        switch value {
        case .number(let number): number.isFinite ? [number] : []
        case .numbers(let numbers): numbers.filter(\.isFinite)
        default: []
        }
    }

    /// A time as epoch milliseconds; the zero time Go serialises counts as never.
    static func timeValue(_ value: LatticeQueryFieldValue) -> Double? {
        let date: Date
        switch value {
        case .number(let number): return number.isFinite ? number : nil
        case .time(let time): date = time
        case .string(let text):
            guard let parsed = AstraDateParser.date(from: text) else { return nil }
            date = parsed
        default: return nil
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard utc.component(.year, from: date) > 1 else { return nil }
        return (date.timeIntervalSince1970 * 1_000).rounded()
    }

    /// JavaScript's `String(number)` for the values rows hold.
    static func jsString(_ number: Double) -> String {
        if number.isFinite, number == number.rounded(), abs(number) < 1e21 {
            return String(Int64(number))
        }
        return String(number)
    }
}

/// A schema with its field index, and the compiler of `engine.ts` `Compiler`.
private struct QuerySchema<Row> {
    let fields: [LatticeQueryField<Row>]
    let text: @Sendable (Row) -> [String]
    let bare: (@Sendable (Row, String) -> Bool)?
    let aliases: [String: String]
    /// The first field to claim a name keeps it.
    let index: [String: LatticeQueryField<Row>]
    /// Index order of names, for suggestions that read like the console's.
    let names: [String]

    init(fields: [LatticeQueryField<Row>], text: @escaping @Sendable (Row) -> [String], bare: (@Sendable (Row, String) -> Bool)?, aliases: [String: String]) {
        self.fields = fields
        self.text = text
        self.bare = bare
        self.aliases = aliases
        var index: [String: LatticeQueryField<Row>] = [:]
        var names: [String] = []
        for field in fields {
            for name in [field.key] + field.aliases where index[name.lowercased()] == nil {
                index[name.lowercased()] = field
                names.append(name.lowercased())
            }
        }
        self.index = index
        self.names = names
    }

    /// The name closest to a typo, among keys and aliases.
    static func closest(_ word: String, _ names: [String]) -> String? {
        var best: String?
        var bestDistance = 3
        for name in names {
            if name.hasPrefix(word), word.utf16.count >= 2 { return name }
            let distance = LatticeQueryValues.editDistance(word, name, cap: 2)
            if distance < bestDistance {
                best = name
                bestDistance = distance
            }
        }
        return best
    }

    typealias Test = @Sendable (Row, Date) -> Bool

    func compile(_ node: LatticeQueryNode, negated: Bool, scorers: inout [@Sendable (Row) -> Double]) throws -> Test {
        switch node {
        case .and(let items):
            let tests = try items.map { try compile($0, negated: negated, scorers: &scorers) }
            return { row, now in tests.allSatisfy { $0(row, now) } }
        case .or(let items):
            let tests = try items.map { try compile($0, negated: negated, scorers: &scorers) }
            return { row, now in tests.contains { $0(row, now) } }
        case .not(let item):
            let test = try compile(item, negated: !negated, scorers: &scorers)
            return { row, now in !test(row, now) }
        case .text(let value, let quoted):
            return text(value, quoted: quoted, negated: negated, scorers: &scorers)
        case .term(let term):
            return try self.term(term, negated: negated, scorers: &scorers)
        }
    }

    private func text(_ value: String, quoted: Bool, negated: Bool, scorers: inout [@Sendable (Row) -> Double]) -> Test {
        let word = value.lowercased()
        if word.isEmpty { return { _, _ in true } }
        let texts = self.text
        let score: @Sendable (Row) -> Double
        if !quoted, word.contains("*") {
            score = { row in
                texts(row).contains { !$0.isEmpty && LatticeQueryValues.globMatches(word, $0) } ? 50 : 0
            }
        } else {
            let alias = quoted ? nil : aliases[word]
            let fuzzy = !quoted && !negated
            let bare = quoted ? nil : self.bare
            score = { row in
                let haystacks = texts(row).filter { !$0.isEmpty }.map { $0.lowercased() }
                var best = 0.0
                for haystack in haystacks {
                    best = max(best, LatticeQueryValues.textScore(haystack, word, fuzzy: fuzzy))
                }
                if best < 60, let alias, haystacks.contains(where: { $0.contains(alias) }) { best = 60 }
                if best < 60, let bare, bare(row, word) { best = 60 }
                return best
            }
        }
        if !negated { scorers.append(score) }
        return { row, _ in score(row) > 0 }
    }

    private func refuse(_ code: LatticeQueryError.Code, _ start: Int, _ end: Int, _ params: [String: String] = [:]) -> LatticeQueryError {
        LatticeQueryError(code: code, start: start, end: end, params: params)
    }

    private func term(_ term: LatticeQueryTerm, negated: Bool, scorers: inout [@Sendable (Row) -> Double]) throws -> Test {
        if term.field == "is" { return try flags(term) }
        guard let field = index[term.field] else {
            if Self.looksLikeIPv6(term.raw) {
                return text(term.raw, quoted: false, negated: negated, scorers: &scorers)
            }
            throw refuse(.unknownField, term.fieldStart, term.fieldEnd, [
                "field": term.field,
                "suggestion": Self.closest(term.field, names) ?? "",
            ])
        }
        for value in term.values where value.text.isEmpty {
            let span = value.start == value.end ? (term.start, term.end) : (value.start, value.end)
            throw refuse(.emptyValue, span.0, span.1, ["field": field.key])
        }
        let exact = term.op == .exact
        let ordered = term.op != .contains && term.op != .exact
        switch field.type {
        case .string, .list:
            if ordered { throw refuse(.noCompare, term.start, term.end, ["field": field.key]) }
            return stringMatch(field, term.values, exact: exact)
        case .version:
            if ordered { return try versionCompare(field, term) }
            return stringMatch(field, term.values, exact: exact)
        case .enumeration:
            if ordered { throw refuse(.noCompare, term.start, term.end, ["field": field.key]) }
            return try enumMatch(field, term.values, exact: exact)
        case .bool:
            if ordered { throw refuse(.noCompare, term.start, term.end, ["field": field.key]) }
            let wanted = try term.values.map { value -> Bool in
                guard let parsed = LatticeQueryValues.parseBool(value.text) else {
                    throw refuse(.badBool, value.start, value.end, ["field": field.key])
                }
                return parsed
            }
            let get = field.get
            return { row, _ in
                if case .bool(let have) = get(row) { return wanted.contains(have) }
                return false
            }
        case .number:
            let wanted = try term.values.map { value -> Double in
                guard let parsed = LatticeQueryValues.parseNumber(value.text, unit: field.unit) else {
                    throw refuse(.badNumber, value.start, value.end, ["field": field.key, "unit": field.unit.rawValue])
                }
                return parsed
            }
            let op = ordered ? term.op : .exact
            let get = field.get
            return { row, _ in
                QueryValueReading.numbers(get(row)).contains { have in wanted.contains { Self.compare(have, op, $0) } }
            }
        case .duration:
            if !ordered { throw refuse(.needsCompare, term.start, term.end, ["field": field.key, "example": "\(field.key)>1h"]) }
            let wanted = try term.values.map { value -> Double in
                guard let parsed = LatticeQueryValues.parseDuration(value.text) else {
                    throw refuse(.badDuration, value.start, value.end, ["field": field.key])
                }
                return parsed
            }
            let op = term.op
            let get = field.get
            return { row, _ in
                QueryValueReading.numbers(get(row)).contains { have in wanted.contains { Self.compare(have, op, $0) } }
            }
        case .time:
            if !ordered { throw refuse(.needsCompare, term.start, term.end, ["field": field.key, "example": "\(field.key)>10m"]) }
            let op = term.op
            let checks = try term.values.map { value -> @Sendable (Double, Double) -> Bool in
                // An age: last_seen>10m is longer ago than ten minutes.
                if let age = LatticeQueryValues.parseDuration(value.text) {
                    return { time, now in Self.compare((now - time) / 1_000, op, age) }
                }
                guard let at = LatticeQueryValues.parseTime(value.text) else {
                    throw refuse(.badTime, value.start, value.end, ["field": field.key])
                }
                return { time, _ in Self.compare(time, op, at) }
            }
            let get = field.get
            return { row, now in
                guard let time = QueryValueReading.timeValue(get(row)) else { return false }
                let nowMillis = (now.timeIntervalSince1970 * 1_000).rounded()
                return checks.contains { $0(time, nowMillis) }
            }
        }
    }

    private func stringMatch(_ field: LatticeQueryField<Row>, _ values: [LatticeQueryValue], exact: Bool) -> Test {
        let matchers = values.map { value -> QueryStringMatcher in
            let word = value.text.lowercased()
            return QueryStringMatcher(
                word: word,
                alias: value.quoted ? nil : aliases[word],
                glob: !value.quoted && word.contains("*"),
                raw: value.text
            )
        }
        let get = field.get
        let custom = field.match
        return { row, _ in
            for matcher in matchers {
                if let result = custom?(row, matcher.raw, exact) {
                    if result { return true }
                    continue
                }
                let have = QueryValueReading.lowerTexts(get(row))
                if matcher.glob {
                    if have.contains(where: { LatticeQueryValues.globMatches(matcher.word, $0) }) { return true }
                    continue
                }
                func hit(_ word: String) -> Bool {
                    have.contains { exact ? $0 == word : $0.contains(word) }
                }
                if hit(matcher.word) { return true }
                if let alias = matcher.alias, hit(alias) { return true }
            }
            return false
        }
    }

    private func versionCompare(_ field: LatticeQueryField<Row>, _ term: LatticeQueryTerm) throws -> Test {
        let wanted = try term.values.map { value -> String in
            guard LatticeQueryValues.looksLikeVersion(value.text) else {
                throw refuse(.badVersion, value.start, value.end, ["field": field.key])
            }
            return value.text
        }
        let op = term.op
        let get = field.get
        return { row, _ in
            let have = QueryValueReading.lowerTexts(get(row)).filter(LatticeQueryValues.looksLikeVersion)
            return have.contains { version in
                wanted.contains { Self.compare(Double(LatticeQueryValues.compareVersions(version, $0)), op, 0) }
            }
        }
    }

    private func enumMatch(_ field: LatticeQueryField<Row>, _ values: [LatticeQueryValue], exact: Bool) throws -> Test {
        let vocabulary = field.values.map { $0.lowercased() }
        var allowed = Set<String>()
        for value in values {
            let word = value.text.lowercased()
            let canonical = (field.valueAliases[word] ?? word).lowercased()
            let isGlob = !value.quoted && canonical.contains("*")
            // A word that is a value means that value; otherwise the values that contain it.
            let named = vocabulary.filter { $0 == canonical }
            let hits: [String]
            if isGlob {
                hits = vocabulary.filter { LatticeQueryValues.globMatches(canonical, $0) }
            } else if exact || !named.isEmpty {
                hits = named
            } else {
                hits = vocabulary.filter { $0.contains(canonical) }
            }
            if hits.isEmpty {
                throw refuse(.unknownValue, value.start, value.end, [
                    "field": field.key,
                    "value": value.text,
                    "values": field.values.joined(separator: ", "),
                ])
            }
            allowed.formUnion(hits)
        }
        let get = field.get
        let accepted = allowed
        return { row, _ in QueryValueReading.lowerTexts(get(row)).contains { accepted.contains($0) } }
    }

    private func flags(_ term: LatticeQueryTerm) throws -> Test {
        if term.op != .contains && term.op != .exact { throw refuse(.noCompare, term.start, term.end, ["field": "is"]) }
        let flagNames = fields.filter { $0.type == .bool }.flatMap { [$0.key] + $0.aliases }
        let tests = try term.values.map { value -> @Sendable (Row) -> LatticeQueryFieldValue in
            if value.text.isEmpty { throw refuse(.emptyValue, term.start, term.end, ["field": "is"]) }
            guard let field = index[value.text.lowercased()], field.type == .bool else {
                throw refuse(.unknownFlag, value.start, value.end, [
                    "flag": value.text,
                    "suggestion": Self.closest(value.text.lowercased(), flagNames) ?? "",
                ])
            }
            return field.get
        }
        return { row, _ in tests.contains { $0(row) == .bool(true) } }
    }

    private static func compare(_ a: Double, _ op: LatticeQueryOperator, _ b: Double) -> Bool {
        switch op {
        case .greater: a > b
        case .greaterOrEqual: a >= b
        case .less: a < b
        case .lessOrEqual: a <= b
        case .contains, .exact: a == b
        }
    }

    /// `fe80::1` and its kind read as text, not as a field named fe80.
    static func looksLikeIPv6(_ raw: String) -> Bool {
        let range = NSRange(location: 0, length: (raw as NSString).length)
        return queryIPv6Pattern.firstMatch(in: raw, range: range) != nil || queryIPv6MappedPattern.firstMatch(in: raw, range: range) != nil
    }
}

private let queryIPv6Pattern = try! NSRegularExpression(pattern: #"^[0-9a-f]{0,4}(:[0-9a-f]{0,4}){2,7}(%\S+)?$"#, options: [.caseInsensitive])
private let queryIPv6MappedPattern = try! NSRegularExpression(pattern: #"^[0-9a-f:]+:\d+\.\d+\.\d+\.\d+$"#, options: [.caseInsensitive])

/// One value of a string term, read once at compile time.
private struct QueryStringMatcher: Sendable {
    var word: String
    var alias: String?
    var glob: Bool
    var raw: String
}
