import Foundation

/// Terraform Cloud's API as Loupe reads it, over runs held in memory: a run with its plan
/// included, the plan's JSON output, which it answers by redirecting to a signed link on another
/// host as Terraform Cloud does, and the plan's log at its own signed link. It refuses any token
/// but `token` on the API, and fails the request if the token is sent to the signed links or
/// anything but a GET is sent. Each path asked for is recorded, so tests can see what was read
/// again.
public actor FakeTerraformCloud {
    public static let token = "fake-terraform-token"
    public static let host = "app.terraform.io"
    /// Where the signed links point, as Terraform Cloud's archivist.
    public static let archive = "archivist.terraform.io"

    public struct Run: Sendable {
        public var id: String
        public var organization: String
        public var workspace: String
        /// The run's status, such as "planned_and_finished", "planning" or "errored".
        public var status: String
        /// The plan's status: "finished", "running", "errored" and so on.
        public var planStatus: String
        /// The JSON plan, once finished.
        public var plan: Data?
        public var log: String

        public init(id: String, organization: String, workspace: String, status: String = "planned_and_finished", planStatus: String = "finished", plan: Data? = nil, log: String = "") {
            self.id = id
            self.organization = organization
            self.workspace = workspace
            self.status = status
            self.planStatus = planStatus
            self.plan = plan
            self.log = log
        }

        var planId: String { "plan-" + id.dropFirst("run-".count) }
    }

    private var runs: [Run]
    /// Each path asked for, on any host, in order.
    public private(set) var requests: [String] = []

    public init(runs: [Run] = []) {
        self.runs = runs
    }

    /// The plans of `tamarinworks/bedrock#2193`'s runs in `probe/pr-status.json`.
    public static func fixture() -> FakeTerraformCloud {
        FakeTerraformCloud(runs: [
            Run(id: "run-6G6GOK8hrFoqYv2m", organization: "tamarinworks", workspace: "prod-platform", plan: grpcPlan(environment: "prod")),
            Run(id: "run-fix8MJqSoTyhdSIM", organization: "tamarinworks", workspace: "stage-platform", plan: grpcPlan(environment: "stage")),
        ])
    }

    public func add(_ run: Run) {
        runs.append(run)
    }

    public func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try require(request.url)
        try expect((request.httpMethod ?? "GET") == "GET", "a \(request.httpMethod ?? "") to Terraform Cloud, which Loupe only reads")
        requests.append(url.path())
        let parts = url.pathComponents.filter { $0 != "/" }
        if url.host() == Self.archive {
            try expect(request.value(forHTTPHeaderField: "Authorization") == nil, "the Terraform Cloud token sent to \(url.absoluteString)")
            guard parts.count == 2, let run = runs.first(where: { $0.id == parts[1] }) else { return notFound(url) }
            switch parts[0] {
            case "json": return (run.plan ?? Data(), response(url, status: 200, type: "application/octet-stream"))
            case "log": return (Data(run.log.utf8), response(url, status: 200, type: "text/plain"))
            default: return notFound(url)
            }
        }
        try expect(url.host() == Self.host, "a request for \(url.absoluteString), which isn't Terraform Cloud")
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)" else {
            return json(["errors": [["status": "401", "title": "unauthorized"]]], url, status: 401)
        }
        switch Array(parts.prefix(3)) {
        case ["api", "v2", "runs"] where parts.count == 4:
            guard let run = runs.first(where: { $0.id == parts[3] }) else { return notFound(url) }
            return json(wire(run), url)
        case ["api", "v2", "plans"] where parts.count == 5 && parts[4] == "json-output":
            guard let run = runs.first(where: { $0.planId == parts[3] }) else { return notFound(url) }
            guard run.planStatus == "finished", run.plan != nil else { return notFound(url) }
            let location = "https://\(Self.archive)/json/\(run.id)"
            return (Data(), HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": location])!)
        default:
            throw mismatch("unknown", "no fake Terraform Cloud answers \(url.path())")
        }
    }

    private func wire(_ run: Run) -> [String: Any] {
        let plan: [String: Any] = [
            "id": run.planId, "type": "plans",
            "attributes": ["status": run.planStatus, "has-changes": true, "log-read-url": "https://\(Self.archive)/log/\(run.id)"] as [String: Any],
        ]
        return [
            "data": [
                "id": run.id, "type": "runs",
                "attributes": ["status": run.status, "plan-only": true, "message": "Triggered via GitHub"] as [String: Any],
                "relationships": ["plan": ["data": ["id": run.planId, "type": "plans"]]],
            ] as [String: Any],
            "included": [plan],
        ]
    }

    private func json(_ object: Any, _ url: URL, status: Int = 200) -> (Data, HTTPURLResponse) {
        ((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), response(url, status: status, type: "application/vnd.api+json"))
    }

    private func notFound(_ url: URL) -> (Data, HTTPURLResponse) {
        json(["errors": [["status": "404", "title": "not found"]]], url, status: 404)
    }

    private func response(_ url: URL, status: Int, type: String) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
    }
}

extension FakeTerraformCloud {
    /// A JSON plan, as `terraform show -json` writes one, of `changes`.
    public static func plan(_ changes: [ResourceChange], outputs: [String: [String: Any]] = [:]) -> Data {
        let plan: [String: Any] = [
            "format_version": "1.2", "terraform_version": "1.10.5", "applyable": true, "complete": true, "errored": false,
            "resource_changes": changes.map(\.wire),
            "output_changes": outputs,
        ]
        return (try? JSONSerialization.data(withJSONObject: plan, options: [.sortedKeys])) ?? Data()
    }

    /// One resource's change in a JSON plan.
    public struct ResourceChange {
        public var address: String
        public var actions: [String]
        public var before: [String: Any]?
        public var after: [String: Any]?
        public var afterUnknown: [String: Any]
        public var replacePaths: [[String]]
        public var reason: String?

        public init(_ address: String, _ actions: [String], before: [String: Any]? = nil, after: [String: Any]? = nil, unknown: [String] = [], replacePaths: [[String]] = [], reason: String? = nil) {
            self.address = address
            self.actions = actions
            self.before = before
            self.after = after
            afterUnknown = Dictionary(uniqueKeysWithValues: unknown.map { ($0, true as Any) })
            self.replacePaths = replacePaths
            self.reason = reason
        }

        var wire: [String: Any] {
            let resource = address.split(separator: ".").suffix(2)
            var change: [String: Any] = [
                "actions": actions, "before": before ?? NSNull(), "after": after ?? NSNull(), "after_unknown": afterUnknown,
                "before_sensitive": [String: Any](), "after_sensitive": [String: Any](),
            ]
            if !replacePaths.isEmpty { change["replace_paths"] = replacePaths }
            var wire: [String: Any] = ["address": address, "mode": "managed", "type": String(resource.first ?? ""), "name": String(resource.last ?? ""), "provider_name": "registry.terraform.io/hashicorp/aws", "change": change]
            if let reason { wire["action_reason"] = reason }
            return wire
        }
    }
}

/// gazette's new gRPC process in one environment: eight resources to add, one of them replacing
/// another, and its task's policy changed.
private func grpcPlan(environment: String) -> Data {
    let module = "module.gazette"
    let tags = ["Service": "gazette", "Environment": environment]
    let account = environment == "prod" ? "111111111111" : "222222222222"
    let containers = #"[{"name":"gazette-grpc","image":"registry.example.com/gazette:2193","portMappings":[{"containerPort":9090}],"command":["serve","--grpc"]}]"#
    let policy: (Bool) -> String = { grpc in
        let actions = grpc ? #"["logs:CreateLogStream","logs:PutLogEvents","servicediscovery:DiscoverInstances"]"# : #"["logs:CreateLogStream","logs:PutLogEvents"]"#
        return #"{"Statement":[{"Action":\#(actions),"Effect":"Allow","Resource":"*"}],"Version":"2012-10-17"}"#
    }
    return FakeTerraformCloud.plan([
        .init("\(module).aws_cloudwatch_log_group.grpc", ["create"], after: ["name": "/ecs/\(environment)/gazette-grpc", "retention_in_days": 30, "tags": tags], unknown: ["arn", "id"]),
        .init("\(module).aws_ecs_service.grpc", ["create"], after: ["name": "gazette-grpc", "cluster": "\(environment)-platform", "desired_count": environment == "prod" ? 3 : 1, "launch_type": "FARGATE", "tags": tags], unknown: ["id", "task_definition"]),
        .init("\(module).aws_ecs_task_definition.grpc", ["create"], after: ["family": "gazette-grpc", "cpu": "256", "memory": "512", "network_mode": "awsvpc", "container_definitions": containers], unknown: ["arn", "id", "revision"]),
        .init("\(module).aws_iam_role_policy.task", ["update"], before: ["id": "gazette-task:gazette", "name": "gazette", "role": "gazette-task", "policy": policy(false)], after: ["id": "gazette-task:gazette", "name": "gazette", "role": "gazette-task", "policy": policy(true)]),
        .init("\(module).aws_lb_listener_rule.grpc", ["create"], after: ["priority": 20, "condition": [["host_header": [["values": ["gazette-grpc.\(environment).internal"]]]]], "action": [["type": "forward"]]], unknown: ["arn", "id", "listener_arn"]),
        .init("\(module).aws_lb_target_group.grpc", ["create"], after: ["name": "gazette-grpc-\(environment)", "port": 9090, "protocol": "HTTP", "protocol_version": "GRPC", "target_type": "ip", "health_check": [["matcher": "0-99", "path": "/grpc.health.v1.Health/Check"]]], unknown: ["arn", "id", "vpc_id"]),
        .init("\(module).aws_route53_record.grpc", ["create"], after: ["name": "gazette-grpc.\(environment).internal", "type": "CNAME", "ttl": 60, "records": ["internal-\(environment).elb.example.com"]], unknown: ["fqdn", "id", "zone_id"]),
        .init("\(module).aws_security_group_rule.grpc_ingress", ["create"], after: ["type": "ingress", "from_port": 9090, "to_port": 9090, "protocol": "tcp", "cidr_blocks": ["10.0.0.0/8"]], unknown: ["id", "security_group_id"]),
        .init("\(module).aws_service_discovery_service.gazette", ["delete", "create"], before: ["id": "srv-\(environment)0001", "name": "gazette", "arn": "arn:aws:servicediscovery:eu-west-1:\(account):service/srv-\(environment)0001", "tags": tags], after: ["name": "gazette-http", "tags": tags], unknown: ["arn", "id"], replacePaths: [["name"]], reason: "replace_because_cannot_update"),
    ])
}
