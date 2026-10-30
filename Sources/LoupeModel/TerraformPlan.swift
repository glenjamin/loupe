import Foundation

/// What a plan would do, from Terraform's JSON plan (`terraform show -json`, which Terraform
/// Cloud serves as a plan's JSON output): each resource's change and each output's.
public struct TerraformPlan: Sendable, Equatable, Decodable {
    public var resourceChanges: [ResourceChange]
    /// By output name.
    public var outputChanges: [String: Change]

    public init(resourceChanges: [ResourceChange], outputChanges: [String: Change] = [:]) {
        self.resourceChanges = resourceChanges
        self.outputChanges = outputChanges
    }

    /// Reads the JSON plan.
    public init(json data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resourceChanges = try container.decodeIfPresent([ResourceChange].self, forKey: .resourceChanges) ?? []
        outputChanges = try container.decodeIfPresent([String: Change].self, forKey: .outputChanges) ?? [:]
    }

    /// The plan's counts, as Terraform's "Plan:" line gives them.
    public var counts: TerraformPlanCounts {
        resourceChanges.reduce(.zero) { counts, change in
            var counts = counts
            let actions = change.change.actions
            if actions.contains("create") { counts.add += 1 }
            if actions.contains("delete") { counts.destroy += 1 }
            if actions == ["update"] { counts.change += 1 }
            if change.change.importing != nil { counts.import += 1 }
            return counts
        }
    }

    private enum CodingKeys: String, CodingKey {
        case resourceChanges = "resource_changes"
        case outputChanges = "output_changes"
    }

    public struct ResourceChange: Sendable, Equatable, Decodable {
        public var address: String
        public var previousAddress: String?
        /// "managed" for a resource, "data" for a data source.
        public var mode: String
        public var type: String
        public var name: String
        /// Set when the object is a deposed one, left over from a create-before-destroy.
        public var deposed: String?
        public var actionReason: String?
        public var change: Change

        public init(address: String, previousAddress: String? = nil, mode: String = "managed", type: String, name: String, deposed: String? = nil, actionReason: String? = nil, change: Change) {
            self.address = address
            self.previousAddress = previousAddress
            self.mode = mode
            self.type = type
            self.name = name
            self.deposed = deposed
            self.actionReason = actionReason
            self.change = change
        }

        private enum CodingKeys: String, CodingKey {
            case address, mode, type, name, deposed, change
            case previousAddress = "previous_address"
            case actionReason = "action_reason"
        }
    }

    /// One object's or output's change: its value before and after, which parts of the after
    /// aren't known until applied, which are sensitive on each side, and which force replacement.
    public struct Change: Sendable, Equatable, Decodable {
        /// "no-op", "create", "read", "update", "delete", and for a replacement "delete", "create"
        /// or, created before destroyed, "create", "delete".
        public var actions: [String]
        public var before: JSONValue
        public var after: JSONValue
        /// `true` for a value not known until applied, or the same shape as `after` saying where.
        public var afterUnknown: JSONValue
        public var beforeSensitive: JSONValue
        public var afterSensitive: JSONValue
        /// Each path, a list of keys and indices, whose change forces the replacement.
        public var replacePaths: [[JSONValue]]
        /// Set when the plan imports the object.
        public var importing: JSONValue?

        public init(actions: [String], before: JSONValue = .null, after: JSONValue = .null, afterUnknown: JSONValue = .bool(false), beforeSensitive: JSONValue = .bool(false), afterSensitive: JSONValue = .bool(false), replacePaths: [[JSONValue]] = [], importing: JSONValue? = nil) {
            self.actions = actions
            self.before = before
            self.after = after
            self.afterUnknown = afterUnknown
            self.beforeSensitive = beforeSensitive
            self.afterSensitive = afterSensitive
            self.replacePaths = replacePaths
            self.importing = importing
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            actions = try container.decode([String].self, forKey: .actions)
            before = try container.decodeIfPresent(JSONValue.self, forKey: .before) ?? .null
            after = try container.decodeIfPresent(JSONValue.self, forKey: .after) ?? .null
            afterUnknown = try container.decodeIfPresent(JSONValue.self, forKey: .afterUnknown) ?? .bool(false)
            beforeSensitive = try container.decodeIfPresent(JSONValue.self, forKey: .beforeSensitive) ?? .bool(false)
            afterSensitive = try container.decodeIfPresent(JSONValue.self, forKey: .afterSensitive) ?? .bool(false)
            replacePaths = try container.decodeIfPresent([[JSONValue]].self, forKey: .replacePaths) ?? []
            importing = try container.decodeIfPresent(JSONValue.self, forKey: .importing)
        }

        private enum CodingKeys: String, CodingKey {
            case actions, before, after, importing
            case afterUnknown = "after_unknown"
            case beforeSensitive = "before_sensitive"
            case afterSensitive = "after_sensitive"
            case replacePaths = "replace_paths"
        }
    }
}

/// Any JSON value. A number keeps the text it was written as, so a large or precise one reads
/// as it did in the plan.
public enum JSONValue: Sendable, Hashable, Decodable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Decimal.self) {
            self = .number("\(number)")
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public var isNull: Bool { self == .null }

    public subscript(key: String) -> JSONValue? {
        if case let .object(object) = self { object[key] } else { nil }
    }
}
