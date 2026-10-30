import AppKit
import LoupeCore
import LoupeModel
import Testing

struct TerraformPlanOutlineTests {
    @Test func eachResourceIsARowSayingWhatWillHappenAndWhyCollapsedUntilExpanded() {
        let outline = TerraformPlanOutline(plan)

        let collapsed = outline.shown(expanded: []).text.string
        #expect(collapsed == """
              - aws_sns_topic.ec2-alerts will be destroyed
                (because aws_sns_topic.ec2-alerts is not in configuration)
            -/+ module.queue.aws_sqs_queue.jobs must be replaced
                # forces replacement: fifo_queue, name

            Plan: 1 to add, 0 to change, 2 to destroy.

            """)

        // Expanding one shows its attributes' changes under its row, the other staying shut.
        let expanded = outline.shown(expanded: ["aws_sns_topic.ec2-alerts"]).text.string
        #expect(expanded.contains("""
              - aws_sns_topic.ec2-alerts will be destroyed
                (because aws_sns_topic.ec2-alerts is not in configuration)
              - resource "aws_sns_topic" "ec2-alerts" {
                  - display_name = "EC2 alerts" -> null
                  - name         = "ec2-alerts" -> null
                }
            """))
        #expect(!expanded.contains("fifo_queue = true -> false"))
        #expect(outline.shown(expanded: Set(outline.resources.map(\.id))).text.string.contains("~ fifo_queue = true -> false # forces replacement"))
        #expect(outline.resources.map(\.title) == [
            "aws_sns_topic.ec2-alerts will be destroyed, (because aws_sns_topic.ec2-alerts is not in configuration)",
            "module.queue.aws_sqs_queue.jobs must be replaced, # forces replacement: fifo_queue, name",
        ])
    }

    @Test func searchingFindsTextInCollapsedResourcesAndSaysWhichToExpand() throws {
        let outline = TerraformPlanOutline(plan)
        let full = outline.fullText as NSString
        let match = full.range(of: "EC2 alerts")
        let collapsed = outline.shown(expanded: [])

        #expect(collapsed.shownRange(forFull: match) == nil, "not shown while its resource is collapsed")
        #expect(collapsed.collapsedResources(holding: match) == ["aws_sns_topic.ec2-alerts"])

        let expanded = outline.shown(expanded: collapsed.collapsedResources(holding: match))
        let shown = try #require(expanded.shownRange(forFull: match))
        #expect((expanded.text.string as NSString).substring(with: shown) == "EC2 alerts")
        #expect(expanded.fullRange(forShown: shown) == match)
        #expect(expanded.resource(at: shown.location) == "aws_sns_topic.ec2-alerts")

        // Text in a row is shown either way.
        let row = full.range(of: "must be replaced")
        let inRow = try #require(collapsed.shownRange(forFull: row))
        #expect((collapsed.text.string as NSString).substring(with: inRow) == "must be replaced")
    }

    @Test func valuesAreColouredByKindWithTheDiffsPalette() throws {
        let text = TerraformPlanOutline(plan).shown(expanded: ["module.queue.aws_sqs_queue.jobs"]).text

        #expect(color(of: "\"jobs.fifo\"", in: text) == DiffColors.syntaxString)
        #expect(color(of: "true -> false", in: text) == DiffColors.syntaxConstant)
        #expect(color(of: "(known after apply)", in: text) == DiffColors.syntaxComment)
        #expect(color(of: " -> ", in: text) == DiffColors.attentionText)
        #expect(color(of: "fifo_queue", in: text) != color(of: "\"jobs.fifo\"", in: text), "names stand apart from values")
        // What will happen is in Terraform's colours, a replacement in the destroy colour.
        #expect(color(of: "must be replaced", in: text) == DiffColors.dangerText)
        #expect(isBold("must be replaced", in: text))
        #expect(color(of: "will be destroyed", in: text) == DiffColors.dangerText)
        #expect(isBold("module.queue.aws_sqs_queue.jobs", in: text))
        // What forces a replacement stands out, in the row and beside the attribute.
        #expect(color(of: "# forces replacement: fifo_queue", in: text) == DiffColors.dangerText)
        #expect(isBold("# forces replacement: fifo_queue", in: text))
        let inline = (text.string as NSString).range(of: " # forces replacement\n")
        #expect(text.attribute(.foregroundColor, at: inline.location + 1, effectiveRange: nil) as? NSColor == DiffColors.dangerText)
        // The reason why is muted.
        #expect(color(of: "(because", in: text) == DiffColors.syntaxComment)
    }
}

/// A replacement forced by two attributes, and a resource destroyed for leaving the
/// configuration.
private let plan = TerraformPlan(resourceChanges: [
    TerraformPlan.ResourceChange(
        address: "module.queue.aws_sqs_queue.jobs", type: "aws_sqs_queue", name: "jobs", actionReason: "replace_because_cannot_update",
        change: .init(
            actions: ["delete", "create"],
            before: .object(["name": .string("jobs.fifo"), "fifo_queue": .bool(true), "arn": .string("arn:aws:sqs:eu-west-1:000000000000:jobs.fifo")]),
            after: .object(["name": .string("jobs"), "fifo_queue": .bool(false)]),
            afterUnknown: .object(["arn": .bool(true)]),
            replacePaths: [[.string("fifo_queue")], [.string("name")]]
        )
    ),
    TerraformPlan.ResourceChange(
        address: "aws_sns_topic.ec2-alerts", type: "aws_sns_topic", name: "ec2-alerts", actionReason: "delete_because_no_resource_config",
        change: .init(actions: ["delete"], before: .object(["name": .string("ec2-alerts"), "display_name": .string("EC2 alerts")]))
    ),
])

private func color(of words: String, in text: NSAttributedString) -> NSColor? {
    let range = (text.string as NSString).range(of: words)
    return text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
}

private func isBold(_ words: String, in text: NSAttributedString) -> Bool {
    let range = (text.string as NSString).range(of: words)
    let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
    return font?.fontDescriptor.symbolicTraits.contains(.bold) == true
}
