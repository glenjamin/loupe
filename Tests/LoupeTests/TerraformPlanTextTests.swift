import AppKit
import LoupeCore
import LoupeModel
import Testing

struct TerraformPlanTextTests {
    /// `Fixtures/terraform` holds a made-up configuration of `terraform_data` resources, applied
    /// at stage 1 and planned at stage 2 with Terraform 1.10.5: `terraform show -json` of the
    /// plan, and `terraform show -no-color` of it, which the rendering should read as.
    @Test func readsAsTerraformPrintsThePlan() throws {
        let plan = try TerraformPlan(json: Data(fixture("terraform/plan.json").utf8))
        let printed = try fixture("terraform/plan.txt")
        // Terraform starts with a key to the symbols and a line introducing the actions.
        let expected = String(printed[try #require(printed.range(of: "  # ")).lowerBound...])

        let shown = shownText(TerraformPlanText.render(plan))

        // Terraform marks what forces a replacement only on attributes of a known type, as
        // providers' are, not on `terraform_data`'s dynamic ones; the rendering always does.
        #expect(shown.replacingOccurrences(of: "1 -> 2 # forces replacement", with: "1 -> 2") == expected)
        #expect(plan.counts == TerraformPlanCounts(add: 2, change: 1, destroy: 2))
    }

    @Test func symbolsAndHeadersAreColouredAsTheCLIColoursThem() throws {
        let plan = try TerraformPlan(json: Data(fixture("terraform/plan.json").utf8))
        let shown = TerminalText.attributed(TerraformPlanText.render(plan))

        #expect(color(of: "+ resource", in: shown) == color(of: "+ id", in: shown))
        #expect(color(of: "+ resource", in: shown) != color(of: "- resource", in: shown))
        #expect(color(of: "~ resource", in: shown) != color(of: "+ resource", in: shown))
        #expect(isBold("# terraform_data.service", in: shown))
    }

    @Test func aResourceReplacedForAnAttributeSaysWhichForcesIt() {
        let plan = TerraformPlan(resourceChanges: [
            TerraformPlan.ResourceChange(
                address: "module.queue.aws_sqs_queue.jobs", type: "aws_sqs_queue", name: "jobs", actionReason: "replace_because_cannot_update",
                change: .init(
                    actions: ["create", "delete"],
                    before: .object(["name": .string("jobs.fifo"), "fifo_queue": .bool(true), "arn": .string("arn:aws:sqs:eu-west-1:000000000000:jobs.fifo"), "delay_seconds": .number("0")]),
                    after: .object(["name": .string("jobs"), "fifo_queue": .bool(false), "delay_seconds": .number("0")]),
                    afterUnknown: .object(["arn": .bool(true)]),
                    replacePaths: [[.string("fifo_queue")], [.string("name")]]
                )
            ),
        ])

        let shown = shownText(TerraformPlanText.render(plan))

        #expect(shown == """
              # module.queue.aws_sqs_queue.jobs must be replaced
            +/- resource "aws_sqs_queue" "jobs" {
                  ~ arn           = "arn:aws:sqs:eu-west-1:000000000000:jobs.fifo" -> (known after apply)
                  ~ fifo_queue    = true -> false # forces replacement
                  ~ name          = "jobs.fifo" -> "jobs" # forces replacement
                    # (1 unchanged attribute hidden)
                }

            Plan: 1 to add, 0 to change, 1 to destroy.

            """)
    }

    @Test func sensitiveValuesAreNeverShown() {
        let plan = TerraformPlan(resourceChanges: [
            TerraformPlan.ResourceChange(
                address: "aws_db_instance.reports", type: "aws_db_instance", name: "reports",
                change: .init(
                    actions: ["update"],
                    before: .object(["id": .string("reports"), "password": .string("hunter2"), "settings": .object(["token": .string("old-secret"), "size": .number("2")])]),
                    after: .object(["id": .string("reports"), "password": .string("correct-horse"), "settings": .object(["token": .string("new-secret"), "size": .number("4")])]),
                    beforeSensitive: .object(["password": .bool(true), "settings": .object(["token": .bool(true)])]),
                    afterSensitive: .object(["password": .bool(true), "settings": .object(["token": .bool(true)])])
                )
            ),
        ], outputChanges: ["admin_password": .init(actions: ["create"], after: .string("swordfish"), afterSensitive: .bool(true))])

        let shown = shownText(TerraformPlanText.render(plan))

        for secret in ["hunter2", "correct-horse", "old-secret", "new-secret", "swordfish"] {
            #expect(!shown.contains(secret))
        }
        #expect(shown.contains("~ password = (sensitive value)"))
        #expect(shown.contains("~ size  = 2 -> 4"))
        #expect(shown.contains("+ admin_password = (sensitive value)"))
    }

    @Test func aDataSourceReadDuringApplyAndAMovedResourceSayWhy() {
        let plan = TerraformPlan(resourceChanges: [
            TerraformPlan.ResourceChange(
                address: "data.aws_iam_policy_document.deploy", mode: "data", type: "aws_iam_policy_document", name: "deploy", actionReason: "read_because_config_unknown",
                change: .init(actions: ["read"], after: .object(["version": .string("2012-10-17")]), afterUnknown: .object(["json": .bool(true), "id": .bool(true)]))
            ),
            TerraformPlan.ResourceChange(
                address: "aws_s3_bucket.exports", previousAddress: "aws_s3_bucket.reports", type: "aws_s3_bucket", name: "exports",
                change: .init(actions: ["no-op"], before: .object(["id": .string("tamarin-exports"), "acl": .string("private")]), after: .object(["id": .string("tamarin-exports"), "acl": .string("private")]))
            ),
        ])

        let shown = shownText(TerraformPlanText.render(plan))

        #expect(shown.contains("""
              # aws_s3_bucket.reports has moved to aws_s3_bucket.exports
                resource "aws_s3_bucket" "exports" {
                    id  = "tamarin-exports"
                    # (1 unchanged attribute hidden)
                }
            """))
        #expect(shown.contains("""
              # data.aws_iam_policy_document.deploy will be read during apply
              # (config refers to values not yet known)
             <= data "aws_iam_policy_document" "deploy" {
                  + id      = (known after apply)
                  + json    = (known after apply)
                  + version = "2012-10-17"
                }
            """))
    }

    @Test func aLongListShowsOnlyTheElementsBesideAChange() {
        let before = (1...8).map { JSONValue.string("10.0.\($0).0/24") }
        var after = before
        after.insert(.string("10.0.42.0/24"), at: 4)
        let plan = TerraformPlan(resourceChanges: [
            TerraformPlan.ResourceChange(
                address: "aws_security_group.web", type: "aws_security_group", name: "web",
                change: .init(actions: ["update"], before: .object(["cidr_blocks": .array(before)]), after: .object(["cidr_blocks": .array(after)]))
            ),
        ])

        let shown = shownText(TerraformPlanText.render(plan))

        #expect(shown.contains("""
                  ~ cidr_blocks = [
                        # (3 unchanged elements hidden)
                        "10.0.4.0/24",
                      + "10.0.42.0/24",
                        "10.0.5.0/24",
                        # (3 unchanged elements hidden)
                    ]
            """))
    }

    @Test func aPlanWithNothingToDoSaysSo() {
        #expect(shownText(TerraformPlanText.render(TerraformPlan(resourceChanges: []))) == "No changes. Your infrastructure matches the configuration.\n")
    }
}

/// The text as shown, without its escapes.
private func shownText(_ text: String) -> String {
    TerminalText.attributed(text).string
}

private func color(of words: String, in text: NSAttributedString) -> NSColor? {
    let range = (text.string as NSString).range(of: words)
    return text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
}

private func isBold(_ words: String, in text: NSAttributedString) -> Bool {
    let range = (text.string as NSString).range(of: words)
    let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
    return font?.fontDescriptor.symbolicTraits.contains(.bold) == true
}
