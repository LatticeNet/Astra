import Foundation

// The console's token grammar (`lib/queryTokens.ts`) that the Runs and Audit
// query fields speak: `key:value` words whose keys are the list endpoint's
// own parameters, comma lists, quotes, and free text. Distinct from the
// filter grammar of section 6.14: every token here becomes a server
// parameter, so a word the server would ignore is reported, not dropped.

/// How a token's value is read.
public enum TasksTokenKind: Sendable, Hashable {
    /// One value, resolved through the field's resolver when it has one.
    case value
    /// A comma list of known values; unknown ones are reported and left out.
    case enumeration([String])
}

public struct TasksTokenField: Sendable, Hashable {
    public var key: String
    public var kind: TasksTokenKind
    /// Names a resolver (`node`) that turns a typed name into an id.
    public var resolve: String?

    public init(key: String, kind: TasksTokenKind = .value, resolve: String? = nil) {
        self.key = key
        self.kind = kind
        self.resolve = resolve
    }
}

public struct TasksTokenGrammar: Sendable, Hashable {
    public var fields: [TasksTokenField]

    public init(fields: [TasksTokenField]) {
        self.fields = fields
    }

    public func field(_ key: String) -> TasksTokenField? {
        fields.first { $0.key == key }
    }
}

public struct TasksTokenProblem: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case emptyValue = "empty-value"
        case unknownValue = "unknown-value"
        case unresolved
    }

    public var token: String
    public var kind: Kind

    public init(token: String, kind: Kind) {
        self.token = token
        self.kind = kind
    }
}

/// A parsed field: ids, not names.
public struct TasksParsedTokens: Sendable, Hashable {
    /// Value fields; absent when unset.
    public var values: [String: String] = [:]
    /// Enumeration fields in the grammar's canonical order; absent when unset.
    public var enums: [String: [String]] = [:]
    public var text: String = ""
    public var problems: [TasksTokenProblem] = []

    public init(values: [String: String] = [:], enums: [String: [String]] = [:], text: String = "", problems: [TasksTokenProblem] = []) {
        self.values = values
        self.enums = enums
        self.text = text
        self.problems = problems
    }

    public var isEmpty: Bool { values.isEmpty && enums.isEmpty && text.isEmpty }
}

public enum TasksTokens {
    /// One word of the field and how much of it was typed outside quotes; a
    /// key counts only when its colon falls in that bare prefix.
    public struct Word: Sendable, Hashable {
        public var word: String
        public var bare: Int
    }

    /// `scanQueryWords`: splits on whitespace outside quotes; a backslash
    /// inside quotes escapes the next character.
    public static func scan(_ input: String) -> [Word] {
        var words: [Word] = []
        var current = ""
        var bare = -1
        var quoted = false
        var started = false
        var escaped = false
        func close() {
            if started, !current.isEmpty { words.append(Word(word: current, bare: bare < 0 ? current.count : bare)) }
            current = ""
            bare = -1
            started = false
        }
        for ch in input {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if quoted, ch == "\\" {
                escaped = true
                continue
            }
            if ch == "\"" {
                if !quoted, bare < 0 { bare = current.count }
                quoted.toggle()
                started = true
                continue
            }
            if !quoted, ch.isWhitespace {
                close()
                continue
            }
            current.append(ch)
            started = true
        }
        close()
        return words
    }

    /// `parseTokens`. A later token for the same key replaces an earlier
    /// one, except enumerations, which add up. `resolvers` maps a resolver
    /// name to a function returning the id, or nil when the name is unknown.
    public static func parse(_ input: String, grammar: TasksTokenGrammar, resolvers: [String: @Sendable (String) -> String?] = [:]) -> TasksParsedTokens {
        var parsed = TasksParsedTokens()
        var sets: [String: Set<String>] = [:]
        var text: [String] = []
        for word in scan(input) {
            let characters = Array(word.word)
            let colon = characters.firstIndex(of: ":")
            let key = colon.flatMap { $0 > 0 && $0 < word.bare ? String(characters[..<$0]).lowercased() : nil } ?? ""
            guard !key.isEmpty, let colon, let field = grammar.field(key) else {
                text.append(word.word)
                continue
            }
            let value = String(characters[(colon + 1)...]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else {
                parsed.problems.append(TasksTokenProblem(token: word.word, kind: .emptyValue))
                continue
            }
            switch field.kind {
            case .value:
                if let name = field.resolve, let resolve = resolvers[name] {
                    if let id = resolve(value) {
                        parsed.values[field.key] = id
                    } else {
                        parsed.problems.append(TasksTokenProblem(token: word.word, kind: .unresolved))
                        parsed.values[field.key] = value
                    }
                } else {
                    parsed.values[field.key] = value
                }
            case .enumeration(let known):
                var set = sets[field.key] ?? []
                for part in value.lowercased().split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
                    if known.contains(part) {
                        set.insert(part)
                    } else {
                        parsed.problems.append(TasksTokenProblem(token: word.word, kind: .unknownValue))
                    }
                }
                sets[field.key] = set
            }
        }
        for field in grammar.fields {
            guard case .enumeration(let known) = field.kind, let set = sets[field.key], !set.isEmpty else { continue }
            parsed.enums[field.key] = known.filter { set.contains($0) }
        }
        parsed.text = text.joined(separator: " ")
        return parsed
    }
}
