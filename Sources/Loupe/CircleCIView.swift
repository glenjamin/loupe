import AppKit
import LoupeCore
import LoupeFakeGitHub
import LoupeInbox
import LoupeModel
import SwiftUI

/// The sidebar's row for the PR's failed CircleCI jobs, under Conversation, while any of its
/// checks that CircleCI ran have failed.
struct CircleCIRow: View {
    @Bindable var tab: PullRequestTab
    @State private var isHovered = false

    var body: some View {
        let isShown = tab.shownSection == .circleCI
        let checks = tab.failedCircleCIChecks
        Button { tab.showCircleCI() } label: {
            HStack(spacing: 4) {
                Label("CircleCI", systemImage: "xmark.octagon")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: "\(checks.count)")
                    .monospacedDigit()
                    .foregroundStyle(isShown ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.diffDanger))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: "Show the failed CircleCI jobs: \(checks.map(\.name).joined(separator: ", ")) (⌃4)"))
        .accessibilityAddTraits(isShown ? .isSelected : [])
        .foregroundStyle(isShown ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(sidebarRowStyle(isShown: isShown, isHovered: isHovered), in: RoundedRectangle(cornerRadius: 5))
        .onHover { isHovered = $0 }
        // Sits right under the Conversation row, whose own padding spaces them.
        .padding([.horizontal, .bottom], 8)
    }
}

/// The failed CircleCI jobs beside the sidebar: a tab for each job, and for the one shown its
/// failed steps' output, its failed tests and its artifacts. Read from CircleCI when first shown.
struct CircleCIPane: View {
    @Bindable var failures: CircleCIFailures
    let checks: [FailedCircleCICheck]
    let isShown: Bool

    var body: some View {
        VStack(spacing: 0) {
            jobBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("circleci-pane")
        // Read again whenever the failed checks change, as after a new push.
        .task(id: isShown ? checks : nil) {
            if isShown { await failures.show(checks) }
        }
    }

    private var jobBar: some View {
        HStack(spacing: 2) {
            if let jobs = failures.jobs.value {
                ForEach(jobs) { job in
                    JobTab(job: job, isSelected: job.id == failures.selectedJobId) {
                        Task { await failures.select(job: job.id) }
                    }
                }
            } else {
                Label("CircleCI", systemImage: "xmark.octagon")
                    .font(.headline)
                    .padding(.horizontal, 8)
            }
            Spacer(minLength: 8)
            if let url = failures.selectedJob?.webURL {
                Button("Open on CircleCI", systemImage: "safari") { openInBrowser(url) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Open the job on CircleCI in the default browser")
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var content: some View {
        switch failures.jobs {
        case .loading:
            LoadingLabel(title: "Finding the failed jobs on CircleCI…")
        case let .failed(failure):
            FailureView(failure: failure) { Task { await failures.retry() } }
        case let .loaded(jobs):
            if let job = failures.selectedJob {
                JobView(failures: failures, job: job)
                    .id(job.id)
            } else {
                Text(jobs.isEmpty ? "CircleCI has no failed jobs for these checks" : "No job selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// A job's tab in the pane's bar: its name, marked as failed, filled while shown.
private struct JobTab: View {
    let job: CircleCIJob
    let isSelected: Bool
    let select: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            Label {
                Text(verbatim: job.name).lineLimit(1)
            } icon: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.diffDanger))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(sidebarRowStyle(isShown: isSelected, isHovered: isHovered), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(Text(verbatim: "Show the \(job.name) job"))
    }
}

/// One job: a choice of its failed steps, failed tests and artifacts, then the one chosen.
private struct JobView: View {
    @Bindable var failures: CircleCIFailures
    let job: CircleCIJob

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $failures.panel) {
                Text(verbatim: "Failed steps (\(job.failedSteps.count))").tag(CircleCIFailures.Panel.steps)
                Text(verbatim: "Failed tests\(count(failures.tests[job.id]))").tag(CircleCIFailures.Panel.tests)
                Text(verbatim: "Artifacts\(count(failures.artifacts[job.id]))").tag(CircleCIFailures.Panel.artifacts)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, 6)
            .accessibilityIdentifier("circleci-panel")
            Divider()
            switch failures.panel {
            case .steps: StepsPanel(failures: failures, job: job)
            case .tests: TestsPanel(failures: failures, job: job)
            case .artifacts: ArtifactsPanel(failures: failures, job: job)
            }
        }
    }

    private func count<Value: Collection & Sendable>(_ loading: CircleCIFailures.Loading<Value>?) -> String {
        loading?.value.map { " (\($0.count))" } ?? ""
    }
}

/// The job's failed steps, listed when there's more than one, and the chosen one's output as
/// the terminal showed it, from its end.
private struct StepsPanel: View {
    let failures: CircleCIFailures
    let job: CircleCIJob

    var body: some View {
        let steps = job.failedSteps
        if let step = failures.selectedStep(in: job) {
            HStack(spacing: 0) {
                if steps.count > 1 {
                    List(selection: Binding(get: { step.id }, set: { id in
                        if let picked = steps.first(where: { $0.id == id }) { Task { await failures.select(step: picked, in: job) } }
                    })) {
                        ForEach(steps) { step in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: step.name).lineLimit(1)
                                Text(verbatim: stepDetail(step))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(step.id)
                        }
                    }
                    .frame(width: 220)
                    .accessibilityIdentifier("circleci-steps")
                    Divider()
                }
                VStack(spacing: 0) {
                    stepHeader(step)
                    Divider()
                    output(of: step)
                }
            }
        } else {
            ContentUnavailableView {
                Label("No step failed", systemImage: "questionmark.circle")
            } description: {
                Text("CircleCI says the job \(job.outcome ?? "hasn't ended"), but none of its steps failed. Its page on CircleCI may say why.")
            }
        }
    }

    private func stepHeader(_ step: CircleCIStep) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: step.name).font(.headline).lineLimit(1)
            Text(verbatim: stepDetail(step)).foregroundStyle(.secondary).lineLimit(1)
            if let command = step.command, command != step.name {
                Text(verbatim: command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(command)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func output(of step: CircleCIStep) -> some View {
        switch failures.output(of: step, in: job) {
        case .loading, nil:
            LoadingLabel(title: "Reading the step's output…")
        case let .failed(failure):
            FailureView(failure: failure) { Task { await failures.retry(job) } }
        case let .loaded(text):
            if text.isEmpty {
                Text("The step printed nothing")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TerminalTextView(text: text, identity: "\(job.id)/\(step.id)", scrollsToEnd: true)
                    .accessibilityIdentifier("circleci-output")
            }
        }
    }

    /// Its outcome or exit code, and which parallel run it was on when there were several.
    private func stepDetail(_ step: CircleCIStep) -> String {
        let outcome = step.exitCode.map { "exit code \($0)" } ?? (step.outcome ?? "")
        return job.executionCount > 1 ? "\(outcome) · run \(step.execution + 1) of \(job.executionCount)" : outcome
    }
}

/// The tests the job's stored results say failed, and the chosen one's message.
private struct TestsPanel: View {
    @Bindable var failures: CircleCIFailures
    let job: CircleCIJob

    var body: some View {
        switch failures.tests[job.id] {
        case .loading, nil:
            LoadingLabel(title: "Reading the job's test results…")
        case let .failed(failure):
            FailureView(failure: failure) { Task { await failures.retry(job) } }
        case let .loaded(tests) where tests.isEmpty:
            ContentUnavailableView {
                Label("No failed tests", systemImage: "checklist")
            } description: {
                Text("The job stored no test results that failed. Its failed steps' output says what went wrong.")
            }
        case let .loaded(tests):
            let selected = tests.first { $0.id == failures.selectedTestIds[job.id] } ?? tests[0]
            HStack(spacing: 0) {
                List(selection: Binding(get: { selected.id }, set: { failures.selectedTestIds[job.id] = $0 })) {
                    ForEach(tests) { test in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: test.name).lineLimit(2)
                            Text(verbatim: test.classname)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .help(Text(verbatim: "\(test.classname) › \(test.name)"))
                        .tag(test.id)
                    }
                }
                .frame(width: 300)
                .accessibilityIdentifier("circleci-tests")
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: selected.name).font(.headline).textSelection(.enabled)
                        Text(verbatim: [selected.classname, selected.runTime.map { String(format: "%.1fs", $0) }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    Divider()
                    TerminalTextView(text: selected.message.isEmpty ? "No message was stored with this failure." : selected.message, identity: "\(job.id)/test/\(selected.id)", scrollsToEnd: false)
                        .accessibilityIdentifier("circleci-test-message")
                }
            }
        }
    }
}

/// The files the job kept, as a tree of their directories; clicking one opens it in the
/// browser, which is signed in to CircleCI.
private struct ArtifactsPanel: View {
    let failures: CircleCIFailures
    let job: CircleCIJob
    @State private var collapsed: Set<String> = []

    var body: some View {
        switch failures.artifacts[job.id] {
        case .loading, nil:
            LoadingLabel(title: "Reading the job's artifacts…")
        case let .failed(failure):
            FailureView(failure: failure) { Task { await failures.retry(job) } }
        case let .loaded(artifacts) where artifacts.isEmpty:
            ContentUnavailableView {
                Label("No artifacts", systemImage: "shippingbox")
            } description: {
                Text("The job kept no files.")
            }
        case let .loaded(artifacts):
            let byPath = Dictionary(artifacts.map { (shownPath($0, among: artifacts), $0) }) { first, _ in first }
            List {
                FileTreeRows(tree: FileTree(paths: byPath.keys), collapsed: $collapsed) { path in
                    if let artifact = byPath[path] {
                        Button { openInBrowser(artifact.url) } label: {
                            HStack(spacing: 6) {
                                Color.clear.frame(width: 14, height: 14)
                                FileName(path: path)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(Text(verbatim: "Open \(artifact.path) in the default browser"))
                    }
                }
            }
            .accessibilityIdentifier("circleci-artifacts")
        }
    }

    /// Its path, under which parallel run kept it when there were several.
    private func shownPath(_ artifact: CircleCIArtifact, among artifacts: [CircleCIArtifact]) -> String {
        artifacts.contains { $0.execution != artifact.execution } ? "run \(artifact.execution + 1)/\(artifact.path)" : artifact.path
    }
}

private struct FailureView: View {
    let failure: CircleCIJobs.Failure
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(failure.title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(LocalizedStringKey(failure.message)).textSelection(.enabled)
        } actions: {
            Button("Try Again", action: retry)
        }
    }
}

/// Text printed to a terminal, coloured as it was, read-only and searchable with ⌘F. It's set
/// afresh only when `identity` changes, so a selection or scroll isn't lost to an update; set,
/// it shows its end, where a failure's error is, when `scrollsToEnd`.
private struct TerminalTextView: NSViewRepresentable {
    let text: String
    let identity: String
    let scrollsToEnd: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.usesFindBar = true
            textView.isIncrementalSearchingEnabled = true
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.drawsBackground = true
            textView.backgroundColor = .textBackgroundColor
            // Lines aren't wrapped, as a terminal's output is laid out for its width.
            textView.isHorizontallyResizable = true
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard context.coordinator.identity != identity, let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.identity = identity
        textView.textStorage?.setAttributedString(TerminalText.attributed(text))
        textView.setAccessibilityValue(textView.string)
        if scrollsToEnd {
            textView.scrollToEndOfDocument(nil)
            textView.scroll(NSPoint(x: 0, y: textView.visibleRect.minY))
        } else {
            textView.scroll(.zero)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var identity: String?
    }
}

/// Each tab's CircleCI failures, made when first shown and kept while the tab lives, read with
/// the `circleci` CLI's token, or from the fake CircleCI in a fixture run.
@MainActor
enum CircleCIPages {
    private static let pages = NSMapTable<PullRequestTab, CircleCIFailures>.weakToStrongObjects()
    private static let client: CircleCIJobs = {
        guard let fake = FixtureRun.circleCI else { return CircleCIJobs.live(environment: FixtureRun.circleCIEnvironment) }
        return CircleCIJobs(token: FakeCircleCI.token, transport: transport(to: fake))
    }()

    static func failures(for tab: PullRequestTab) -> CircleCIFailures {
        if let failures = pages.object(forKey: tab) { return failures }
        let failures = CircleCIFailures(client: client)
        pages.setObject(failures, forKey: tab)
        return failures
    }

    static func existingFailures(for tab: PullRequestTab) -> CircleCIFailures? {
        pages.object(forKey: tab)
    }
}

private func transport(to fake: FakeCircleCI) -> CircleCIJobs.Transport {
    { request in try await fake.send(request) }
}
