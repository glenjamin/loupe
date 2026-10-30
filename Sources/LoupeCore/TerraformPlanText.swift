import Foundation
import LoupeModel

/// A plan as `terraform plan` and `terraform show` print it, written from its JSON plan, with
/// the CLI's colours as SGR escapes for `TerminalText`: each resource's change under a comment
/// saying what will happen to it, then the "Plan:" line and the outputs' changes.
///
/// The JSON plan carries no provider schemas, so nested blocks read as attributes holding
/// objects or lists of them, and a map's keys as bare names where they can be.
public enum TerraformPlanText {
    public static func render(_ plan: TerraformPlan) -> String {
        var lines: [String] = []
        // Unchanged objects are left out, unless they moved or are imported.
        let resources = plan.resourceChanges
            .filter { $0.change.actions != ["no-op"] || $0.previousAddress != nil || $0.change.importing != nil }
            .sorted { ($0.address, $0.deposed ?? "") < ($1.address, $1.deposed ?? "") }
        for resource in resources {
            lines += header(resource)
            lines += body(resource).map(\.text)
            lines.append("")
        }
        let outputs = plan.outputChanges.filter { $0.value.actions != ["no-op"] }.sorted { $0.key < $1.key }
        if resources.isEmpty && outputs.isEmpty {
            lines.append(bold(color("No changes.", .green)) + bold(" Your infrastructure matches the configuration."))
            return lines.joined(separator: "\n") + "\n"
        }
        if !resources.isEmpty {
            lines.append(bold("Plan:") + " " + summary(plan.counts) + ".")
        }
        if !outputs.isEmpty {
            if !resources.isEmpty { lines.append("") }
            lines.append("Changes to Outputs:")
            let width = outputs.map(\.key.count).max() ?? 0
            for (name, change) in outputs {
                let symbol = Symbol(actions: change.actions)
                let value = Values(change: change)
                lines += Renderer().attribute(key: name.padding(toLength: width, withPad: " ", startingAt: 0), value.before, value.after, symbol: symbol, isTopLevel: true).map(\.text)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// "8 to add, 1 to change, 1 to destroy", with "1 to import, " first when there are imports.
    public static func summary(_ counts: TerraformPlanCounts) -> String {
        (counts.import > 0 ? "\(counts.import) to import, " : "") + "\(counts.add) to add, \(counts.change) to change, \(counts.destroy) to destroy"
    }

    private static func header(_ resource: TerraformPlan.ResourceChange) -> [String] {
        let change = resource.change
        let address = bold("  # \(resource.address)" + (resource.deposed.map { " (deposed object \($0))" } ?? ""))
        var lines: [String]
        switch Symbol(actions: change.actions) {
        case .create:
            lines = ["\(address) will be created"]
        case .delete:
            lines = ["\(address) will be \(bold(color("destroyed", .red)))"]
            if let reason = deleteReason(resource) { lines.append("  # (\(reason))") }
        case .update:
            lines = ["\(address) will be updated in-place"]
        case .replace:
            let how = switch resource.actionReason {
            case "replace_because_tainted": "is tainted, so must be \(bold(color("replaced", .red)))"
            case "replace_by_request": "will be \(bold(color("replaced", .red))), as requested"
            default: "must be \(bold(color("replaced", .red)))"
            }
            lines = ["\(address) \(how)"]
        case .read:
            lines = ["\(address) will be read during apply"]
            switch resource.actionReason {
            case "read_because_config_unknown": lines.append("  # (config refers to values not yet known)")
            case "read_because_dependency_pending": lines.append("  # (depends on a resource or a module with changes pending)")
            default: break
            }
        case .none:
            if let previous = resource.previousAddress {
                return [bold("  # \(previous)") + " has moved to " + bold(resource.address)]
            }
            return ["\(address) will be imported"]
        }
        if let previous = resource.previousAddress { lines.append("  # (moved from \(previous))") }
        if case let .string(id)? = change.importing?["id"] { lines.append("  # (imported from \"\(id)\")") }
        return lines
    }

    private static func deleteReason(_ resource: TerraformPlan.ResourceChange) -> String? {
        let index = resource.address.hasSuffix("]") ? resource.address.lastIndex(of: "[").map { String(resource.address[$0...]) } : nil
        switch resource.actionReason {
        case "delete_because_no_resource_config": return "because \(resource.address) is not in configuration"
        case "delete_because_no_module": return "because its module is not in configuration"
        case "delete_because_count_index": return "because index \(index ?? "") is out of range for count"
        case "delete_because_each_key": return "because key \(index ?? "") is not in for_each map"
        case "delete_because_wrong_repetition":
            guard let index else { return "because resource uses count or for_each" }
            return index.hasPrefix("[\"") ? "because resource does not use for_each" : "because resource does not use count"
        default: return nil
        }
    }

    /// The resource's block: `resource "type" "name" {`, its attributes' changes, `}`.
    private static func body(_ resource: TerraformPlan.ResourceChange) -> [Line] {
        let symbol = Symbol(actions: resource.change.actions)
        let values = Values(change: resource.change)
        let renderer = Renderer(replacePaths: resource.change.replacePaths)
        let keyword = resource.mode == "data" ? "data" : "resource"
        let open = "\(keyword) \"\(resource.type)\" \"\(resource.name)\" {"
        var children: [Line]
        switch symbol {
        case .create, .read:
            children = renderer.objectChildren(nil, values.after, symbol: .create, path: [], topLevel: true)
        case .delete:
            children = renderer.objectChildren(values.before, nil, symbol: .delete, path: [], topLevel: true)
        case .update, .replace, .none:
            children = renderer.objectChildren(values.before, values.after, symbol: .update, path: [], topLevel: true)
        }
        return [Line(depth: 0, symbol: symbol, runs: [Run(open)])] + children + [Line(depth: 0, symbol: .none, runs: [Run("}")])]
    }
}

/// One side of a change: its value, and which parts of it are unknown or sensitive.
private struct Side {
    var value: JSONValue
    var unknown: JSONValue = .bool(false)
    var sensitive: JSONValue = .bool(false)

    var isUnknown: Bool { unknown == .bool(true) }
    var isSensitive: Bool { sensitive == .bool(true) }

    /// Present unless null and not unknown.
    var isPresent: Bool { !value.isNull || isUnknown }

    func child(_ key: String) -> Side {
        Side(value: value[key] ?? .null, unknown: unknown[key] ?? .bool(false), sensitive: sensitive[key] ?? .bool(false))
    }

    func element(_ index: Int) -> Side {
        Side(value: item(of: value, index) ?? .null, unknown: item(of: unknown, index) ?? .bool(false), sensitive: item(of: sensitive, index) ?? .bool(false))
    }

    /// Equal, unknowns and sensitivity included.
    func same(as other: Side) -> Bool {
        value == other.value && !isUnknown && !other.isUnknown && normalized(sensitive) == normalized(other.sensitive)
    }
}

private struct Values {
    var before: Side?
    var after: Side?

    init(change: TerraformPlan.Change) {
        let before = Side(value: change.before, sensitive: change.beforeSensitive)
        let after = Side(value: change.after, unknown: change.afterUnknown, sensitive: change.afterSensitive)
        self.before = before.isPresent ? before : nil
        self.after = after.isPresent ? after : nil
    }
}

private enum Symbol: Equatable {
    case none, create, delete, update, read
    case replace(createFirst: Bool)

    init(actions: [String]) {
        switch actions {
        case ["create"]: self = .create
        case ["delete"]: self = .delete
        case ["update"]: self = .update
        case ["read"]: self = .read
        case ["delete", "create"]: self = .replace(createFirst: false)
        case ["create", "delete"]: self = .replace(createFirst: true)
        default: self = .none
        }
    }

    /// Right-aligned in three columns, as Terraform's gutter has it.
    var text: String {
        switch self {
        case .none: "   "
        case .create: "  " + color("+", .green)
        case .delete: "  " + color("-", .red)
        case .update: "  " + color("~", .yellow)
        case .read: " " + color("<=", .cyan)
        case .replace(createFirst: false): color("-", .red) + "/" + color("+", .green)
        case .replace(createFirst: true): color("+", .green) + "/" + color("-", .red)
        }
    }
}

private struct Run {
    var text: String
    var style: SGR?

    init(_ text: String, _ style: SGR? = nil) {
        self.text = text
        self.style = style
    }
}

/// A line of the plan: four columns for each level it's nested, the symbol's gutter, and its
/// text.
private struct Line {
    var depth: Int
    var symbol: Symbol
    var runs: [Run]

    var text: String {
        String(repeating: " ", count: depth * 4) + symbol.text + " " + runs.map { run in run.style.map { color(run.text, $0) } ?? run.text }.joined()
    }

    func nested(by levels: Int) -> Line {
        Line(depth: depth + levels, symbol: symbol, runs: runs)
    }
}

/// Writes values and their changes as lines whose depth is relative to where they start: a
/// value's first line carries on the line that introduces it (after `key = `), and its last
/// line takes whatever follows (` -> null`, `,`).
private struct Renderer {
    var replacePaths: [[JSONValue]] = []

    /// `key = value` for an attribute, its first line marked with `symbol`.
    func attribute(key: String, _ before: Side?, _ after: Side?, symbol: Symbol, isTopLevel: Bool = false, path: [JSONValue] = [], showsUnchanged: Bool = false) -> [Line] {
        var lines: [Line]
        var shownSymbol = symbol
        switch (before, after) {
        case (nil, nil):
            return []
        case let (nil, after?):
            lines = created(after)
            shownSymbol = .create
        case let (before?, nil):
            lines = deleted(before)
            shownSymbol = .delete
            if isTopLevel || symbol != .delete { lines[lines.count - 1].runs.append(Run(" -> null", .darkGray)) }
        case let (before?, after?):
            if before.same(as: after) {
                lines = unchanged(before)
                shownSymbol = .none
            } else {
                lines = changed(before, after, path: path, showsUnchanged: showsUnchanged)
                shownSymbol = .update
            }
        }
        lines[0].runs.insert(Run("\(key) = "), at: 0)
        lines[0].symbol = shownSymbol
        if shownSymbol == .update, replacePaths.contains(path) {
            lines[lines.count - 1].runs.append(Run(" # forces replacement", .red))
        }
        return lines
    }

    /// The attributes inside an object's braces, at depth 1. Within a change, those that
    /// haven't changed are counted rather than shown, except `id`, `name` and `tags`, which say
    /// which object it is and are shown whole.
    func objectChildren(_ before: Side?, _ after: Side?, symbol: Symbol, path: [JSONValue], topLevel: Bool = false, showsUnchanged: Bool = false) -> [Line] {
        let keys = Set(objectKeys(before) + objectKeys(after)).filter { key in
            before.map { $0.child(key).isPresent } == true || after.map { $0.child(key).isPresent } == true
        }.sorted()
        let width = keys.map { displayKey($0).count }.max() ?? 0
        var lines: [Line] = []
        var hidden = 0
        for key in keys {
            let old = before.map { $0.child(key) }.flatMap { $0.isPresent ? $0 : nil }
            let new = after.map { $0.child(key) }.flatMap { $0.isPresent ? $0 : nil }
            if symbol == .update, !showsUnchanged, let old, let new, old.same(as: new), !Self.identifying.contains(key) {
                hidden += 1
                continue
            }
            let name = displayKey(key).padding(toLength: width, withPad: " ", startingAt: 0)
            let showsAll = showsUnchanged || Self.identifying.contains(key)
            lines += attribute(key: name, old, new, symbol: symbol, isTopLevel: topLevel, path: path + [.string(key)], showsUnchanged: showsAll).map { $0.nested(by: 1) }
        }
        if hidden > 0 {
            lines.append(Line(depth: 1, symbol: .none, runs: [Run("# (\(hidden) unchanged \(hidden == 1 ? "attribute" : "attributes") hidden)", .darkGray)]))
        }
        return lines
    }

    // MARK: Whole values

    func created(_ side: Side) -> [Line] {
        whole(side, symbol: .create)
    }

    func deleted(_ side: Side) -> [Line] {
        whole(side, symbol: .delete)
    }

    func unchanged(_ side: Side) -> [Line] {
        whole(side, symbol: .none)
    }

    /// A value all of whose parts are created, deleted or unchanged alike.
    private func whole(_ side: Side, symbol: Symbol) -> [Line] {
        if side.isSensitive { return [Line(depth: 0, symbol: .none, runs: [Run("(sensitive value)")])] }
        if side.isUnknown { return [Line(depth: 0, symbol: .none, runs: [Run("(known after apply)")])] }
        switch side.value {
        case .object:
            let children = switch symbol {
            case .create: objectChildren(nil, side, symbol: .create, path: [])
            case .delete: objectChildren(side, nil, symbol: .delete, path: [])
            default: objectChildren(side, side, symbol: .none, path: [])
            }
            return braces("{", children, "}")
        case let .array(elements):
            let children = elements.indices.flatMap { index in
                element(whole(side.element(index), symbol: symbol), symbol: symbol)
            }
            return braces("[", children, "]")
        case let .string(string):
            if let json = embeddedJSON(string) {
                return jsonencode(whole(Side(value: json), symbol: symbol), symbol: .none)
            }
            if isMultiline(string) {
                return heredoc(lines(of: string).map { (.none, $0) })
            }
            return [primitive(side.value)]
        default:
            return [primitive(side.value)]
        }
    }

    // MARK: Changes

    /// A value that changed: object by object, list by list, a multi-line string by its lines,
    /// a JSON string by its JSON, anything else as the old value `->` the new.
    private static let identifying: Set<String> = ["id", "name", "tags"]

    private func changed(_ before: Side, _ after: Side, path: [JSONValue], showsUnchanged: Bool = false) -> [Line] {
        if before.isSensitive || after.isSensitive {
            return [Line(depth: 0, symbol: .none, runs: [Run("(sensitive value)")])]
        }
        if after.isUnknown {
            var lines = whole(before, symbol: .delete)
            lines[lines.count - 1].runs.append(Run(" -> "))
            lines[lines.count - 1].runs.append(Run("(known after apply)"))
            return lines
        }
        switch (before.value, after.value) {
        case (.object, .object):
            return braces("{", objectChildren(before, after, symbol: .update, path: path, showsUnchanged: showsUnchanged), "}")
        case (.array, .array):
            return braces("[", listChildren(before, after, path: path, showsUnchanged: showsUnchanged), "]")
        case let (.string(old), .string(new)):
            if let oldJSON = embeddedJSON(old), let newJSON = embeddedJSON(new) {
                var inner = changed(Side(value: oldJSON), Side(value: newJSON), path: [])
                inner[0].symbol = .update
                return jsonencode(inner, symbol: .update)
            }
            if isMultiline(old) || isMultiline(new) {
                return heredoc(lineChanges(lines(of: old), lines(of: new)))
            }
        default:
            break
        }
        var lines = whole(before, symbol: .delete)
        lines[lines.count - 1].runs.append(Run(" -> ", .yellow))
        let replacement = whole(after, symbol: .create)
        lines[lines.count - 1].runs += replacement[0].runs
        return lines + replacement.dropFirst()
    }

    /// A list's elements, at depth 1. Lists of the same length are compared element by element,
    /// others by what was removed and inserted; unchanged elements are shown only beside a
    /// change.
    private func listChildren(_ before: Side, _ after: Side, path: [JSONValue], showsUnchanged: Bool) -> [Line] {
        let old = arrayCount(before.value)
        let new = arrayCount(after.value)
        enum Step { case same(Int, Int), removed(Int), inserted(Int), changed(Int) }
        var steps: [Step] = []
        if old == new {
            steps = (0..<old).map { before.element($0).same(as: after.element($0)) ? .same($0, $0) : .changed($0) }
        } else {
            let a = (0..<old).map { before.element($0).value }
            let b = (0..<new).map { after.element($0).value }
            let (removals, insertions) = offsets(b.difference(from: a))
            var i = 0, j = 0
            while i < old || j < new {
                if i < old, removals.contains(i) { steps.append(.removed(i)); i += 1 }
                else if j < new, insertions.contains(j) { steps.append(.inserted(j)); j += 1 }
                else { steps.append(.same(i, j)); i += 1; j += 1 }
            }
        }
        let isChange = steps.map { if case .same = $0 { false } else { true } }
        var lines: [Line] = []
        var hidden = 0
        func countHidden() {
            guard hidden > 0 else { return }
            lines.append(Line(depth: 1, symbol: .none, runs: [Run("# (\(hidden) unchanged \(hidden == 1 ? "element" : "elements") hidden)", .darkGray)]))
            hidden = 0
        }
        for (index, step) in steps.enumerated() {
            let nearChange = (index > 0 && isChange[index - 1]) || (index + 1 < steps.count && isChange[index + 1])
            if case .same = step, !nearChange, !showsUnchanged {
                hidden += 1
                continue
            }
            countHidden()
            switch step {
            case let .same(i, _):
                lines += element(unchanged(before.element(i)), symbol: .none)
            case let .removed(i):
                lines += element(deleted(before.element(i)), symbol: .delete)
            case let .inserted(j):
                lines += element(created(after.element(j)), symbol: .create)
            case let .changed(i):
                lines += element(changed(before.element(i), after.element(i), path: path + [.number("\(i)")]), symbol: .update)
            }
        }
        countHidden()
        return lines
    }

    /// A multi-line string's lines, compared, with unchanged lines more than a few from a
    /// change counted rather than shown.
    private func lineChanges(_ old: [String], _ new: [String]) -> [(Symbol, String)] {
        let (removals, insertions) = offsets(new.difference(from: old))
        var steps: [(Symbol, String)] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removals.contains(i) { steps.append((.delete, old[i])); i += 1 }
            else if j < new.count, insertions.contains(j) { steps.append((.create, new[j])); j += 1 }
            else { steps.append((.none, old[i])); i += 1; j += 1 }
        }
        let changes = steps.indices.filter { steps[$0].0 != .none }
        var shown: [(Symbol, String)] = []
        var hidden = 0
        for (index, step) in steps.enumerated() {
            if step.0 == .none, !changes.contains(where: { abs($0 - index) <= Self.lineContext }) {
                hidden += 1
                continue
            }
            if hidden > 0 {
                shown.append((.none, "\u{0}\(hidden)"))
                hidden = 0
            }
            shown.append(step)
        }
        if hidden > 0 { shown.append((.none, "\u{0}\(hidden)")) }
        return shown
    }

    private static let lineContext = 3

    // MARK: Pieces

    private func braces(_ open: String, _ children: [Line], _ close: String) -> [Line] {
        guard !children.isEmpty else { return [Line(depth: 0, symbol: .none, runs: [Run(open + close)])] }
        return [Line(depth: 0, symbol: .none, runs: [Run(open)])] + children + [Line(depth: 0, symbol: .none, runs: [Run(close)])]
    }

    /// A list element's lines at depth 1, ended with a comma.
    private func element(_ lines: [Line], symbol: Symbol) -> [Line] {
        var lines = lines.map { $0.nested(by: 1) }
        lines[0].symbol = symbol
        lines[lines.count - 1].runs.append(Run(","))
        return lines
    }

    /// `jsonencode(`, the value at depth 1, `)`.
    private func jsonencode(_ inner: [Line], symbol: Symbol) -> [Line] {
        var inner = inner.map { $0.nested(by: 1) }
        inner[0].symbol = symbol == .update ? inner[0].symbol : .none
        return [Line(depth: 0, symbol: .none, runs: [Run("jsonencode(")])] + inner + [Line(depth: 0, symbol: .none, runs: [Run(")")])]
    }

    /// `<<-EOT`, each line one level in, `EOT`. A line starting with NUL counts hidden lines.
    private func heredoc(_ lines: [(Symbol, String)]) -> [Line] {
        let body = lines.map { symbol, text in
            if text.hasPrefix("\u{0}") {
                let count = Int(text.dropFirst()) ?? 0
                return Line(depth: 1, symbol: .none, runs: [Run("# (\(count) unchanged \(count == 1 ? "line" : "lines") hidden)", .darkGray)])
            }
            return Line(depth: 1, symbol: symbol, runs: [Run(text)])
        }
        return [Line(depth: 0, symbol: .none, runs: [Run("<<-EOT")])] + body + [Line(depth: 0, symbol: .none, runs: [Run("EOT")])]
    }

    private func primitive(_ value: JSONValue) -> Line {
        Line(depth: 0, symbol: .none, runs: [Run(literal(value))])
    }
}

private func literal(_ value: JSONValue) -> String {
    switch value {
    case .null: "null"
    case let .bool(bool): bool ? "true" : "false"
    case let .number(number): number
    case let .string(string): quoted(string)
    case .array: "[...]"
    case .object: "{...}"
    }
}

private func quoted(_ string: String) -> String {
    var text = "\""
    for scalar in string.unicodeScalars {
        switch scalar {
        case "\"": text += "\\\""
        case "\\": text += "\\\\"
        case "\n": text += "\\n"
        case "\r": text += "\\r"
        case "\t": text += "\\t"
        default: text.unicodeScalars.append(scalar)
        }
    }
    return text + "\""
}

/// A key as Terraform writes it: bare when it's a name, quoted otherwise.
private func displayKey(_ key: String) -> String {
    guard let first = key.unicodeScalars.first, CharacterSet.letters.contains(first) || first == "_",
          key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }) else { return quoted(key) }
    return key
}

private func objectKeys(_ side: Side?) -> [String] {
    guard let side else { return [] }
    var keys: [String] = []
    if case let .object(object) = side.value { keys += object.keys }
    if case let .object(object) = side.unknown { keys += object.keys }
    return keys
}

/// Where a difference removes from the old collection and inserts into the new.
private func offsets<T>(_ difference: CollectionDifference<T>) -> (removals: Set<Int>, insertions: Set<Int>) {
    var removals: Set<Int> = []
    var insertions: Set<Int> = []
    for change in difference {
        switch change {
        case let .remove(offset, _, _): removals.insert(offset)
        case let .insert(offset, _, _): insertions.insert(offset)
        }
    }
    return (removals, insertions)
}

private func arrayCount(_ value: JSONValue) -> Int {
    if case let .array(elements) = value { elements.count } else { 0 }
}

private func item(of value: JSONValue, _ index: Int) -> JSONValue? {
    if case let .array(elements) = value, elements.indices.contains(index) { elements[index] } else { nil }
}

/// Sensitivity marks with the falses dropped, as `{}` and `{"a": false}` say the same.
private func normalized(_ marks: JSONValue) -> JSONValue {
    switch marks {
    case .bool(true):
        return .bool(true)
    case let .object(object):
        let kept = object.mapValues(normalized).filter { $0.value != .bool(false) }
        return kept.isEmpty ? .bool(false) : .object(kept)
    case let .array(elements):
        let kept = elements.map(normalized)
        return kept.allSatisfy { $0 == .bool(false) } ? .bool(false) : .array(kept)
    default:
        return .bool(false)
    }
}

private func isMultiline(_ string: String) -> Bool {
    string.contains("\n")
}

/// A multi-line string's lines, without the empty one after a final newline.
private func lines(of string: String) -> [String] {
    var lines = string.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    return lines
}

/// A string holding a JSON object or array, as a policy document does, parsed.
private func embeddedJSON(_ string: String) -> JSONValue? {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["), let value = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else { return nil }
    return value
}

private enum SGR: String {
    case red = "31", green = "32", yellow = "33", cyan = "36", darkGray = "90"
}

private func color(_ text: String, _ style: SGR) -> String {
    "\u{1B}[\(style.rawValue)m\(text)\u{1B}[0m"
}

private func bold(_ text: String) -> String {
    "\u{1B}[1m\(text)\u{1B}[0m"
}
