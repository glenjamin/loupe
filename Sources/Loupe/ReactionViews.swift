import LoupeCore
import LoupeInbox
import LoupeModel
import SwiftUI

/// A comment's reactions as github.com shows them: a toggle per reaction anyone has made, on
/// where the viewer has made it, then a menu of all eight. Each change shows at once.
struct ReactionsRow: View {
    let tab: PullRequestTab
    let subjectId: String
    let groups: [ReactionGroup]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(groups, id: \.content) { group in
                Toggle(isOn: reacted(group.content)) {
                    Text(verbatim: "\(group.content.emoji) \(group.count)")
                        .monospacedDigit()
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help(help(for: group))
            }
            Menu {
                ForEach(Reaction.allCases) { content in
                    Toggle(isOn: reacted(content)) {
                        Text(verbatim: "\(content.emoji)  \(content.name)")
                    }
                }
            } label: {
                Image(systemName: "face.smiling")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("Add a reaction")
        }
    }

    /// On where the viewer has reacted with `content`; turning it on or off reacts or stops.
    private func reacted(_ content: Reaction) -> Binding<Bool> {
        Binding {
            groups.viewerHasReacted(content)
        } set: { [tab, subjectId] on in
            Task { await tab.react(ReactionLink(on ? .add : .remove, content, on: subjectId)) }
        }
    }

    private func help(for group: ReactionGroup) -> String {
        let others = group.count - (group.viewerHasReacted ? 1 : 0)
        let who = group.viewerHasReacted ? (others == 0 ? "You" : "You and \(others) more") : "\(group.count) \(group.count == 1 ? "person" : "people")"
        return "\(who) reacted with \(group.content.name)"
    }
}
