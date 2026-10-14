import Foundation
import LoupeCore
import Testing

struct DiffParserTests {
    @Test func parsesARealPRDiffMatchingGitNumstat() throws {
        let diff = try Diff(parsing: fixture("atrium-2912.diff"))

        // From `git diff --numstat` on the same range.
        let stats = diff.files.map { "\($0.additions)\t\($0.deletions)\t\($0.path)" }
        #expect(stats == [
            "21\t2\tgo.mod",
            "4\t7\tledger/kilntest/s3.go",
            "2\t1\tledger/cmd/grpc/cmd.go",
            "11\t51\tledger/cmd/grpc/snapshotter.go",
        ])
        #expect(diff.files.allSatisfy { $0.change == .modified })
    }

    @Test func numbersLinesFromTheHunkHeader() throws {
        let goMod = try #require(Diff(parsing: fixture("atrium-2912.diff")).files.first)
        let lines = goMod.hunks[0].lines

        #expect(goMod.hunks[0].header == "@@ -7,7 +7,7 @@ retract v0.657.0")
        #expect(lines[0] == DiffLine(kind: .context(old: 7, new: 7), text: "require ("))
        #expect(lines[3] == DiffLine(kind: .deletion(old: 10), text: "\tgithub.com/aws/aws-sdk-go v1.49.23"))
        #expect(lines[4] == DiffLine(kind: .addition(new: 10), text: "\tgithub.com/aws/aws-sdk-go-v2/feature/s3/transfermanager v0.4.14"))
        #expect(lines[5].kind == .context(old: 11, new: 11))
    }

    @Test(arguments: ["atrium-2912.diff", "edge-cases.diff"])
    func everyHunkHasTheLineCountsItsHeaderDeclares(name: String) throws {
        for file in try Diff(parsing: fixture(name)).files {
            for hunk in file.hunks {
                let declared = declaredCounts(hunk.header)
                let old = hunk.lines.count { $0.oldLine != nil }
                let new = hunk.lines.count { $0.newLine != nil }
                #expect(old == declared.old && new == declared.new, "\(file.path) \(hunk.header)")
            }
        }
    }

    @Test func handlesRenamesCopiesDeletionsAndMissingNewlines() throws {
        let files = try Diff(parsing: fixture("edge-cases.diff")).files
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })

        let pureRename = try #require(byPath["vendor/github.com/aws/aws-sdk-go-v2/service/internal/s3shared/arn/s3_object_lambda_arn.go"])
        #expect(pureRename.change == .renamed(from: "vendor/github.com/aws/aws-sdk-go/internal/s3shared/arn/s3_object_lambda_arn.go", similarity: 100))
        #expect(pureRename.hunks.isEmpty)

        let editedRename = try #require(byPath["vendor/github.com/aws/aws-sdk-go-v2/aws/arn/arn.go"])
        #expect(editedRename.change == .renamed(from: "vendor/github.com/aws/aws-sdk-go/aws/arn/arn.go", similarity: 94))
        #expect(!editedRename.hunks.isEmpty)

        let copy = try #require(byPath["vendor/github.com/aws/aws-sdk-go-v2/aws/protocol/eventstream/debug.go"])
        #expect(copy.change == .copied(from: "vendor/github.com/aws/aws-sdk-go/private/protocol/eventstream/debug.go", similarity: 92))

        let deleted = try #require(byPath["vendor/github.com/aws/aws-sdk-go/internal/s3shared/resource_request.go"])
        #expect(deleted.change == .deleted)
        #expect(deleted.additions == 0 && deleted.deletions == 45)

        let added = try #require(byPath["vendor/github.com/aws/aws-sdk-go-v2/internal/endpoints/awsrulesfn/partitions.json"])
        #expect(added.change == .added)
        let last = try #require(added.hunks.last?.lines.last)
        #expect(last.text == "}" && last.missingNewline)
    }

    @Test func keepsCarriageReturnsInsideLines() {
        let diff = Diff(parsing: "diff --git a/x.txt b/x.txt\n--- a/x.txt\n+++ b/x.txt\n@@ -1 +1 @@\n-old\r\n+new\r\n")
        #expect(diff.files[0].hunks[0].lines.map(\.text) == ["old\r", "new\r"])
    }

    /// A review thread's `line` (with `diffSide: RIGHT`) is the new-file line number, and its
    /// `diffHunk` ends on the commented line. Checked against the API response saved in probe/.
    @Test func reviewThreadLineIsTheLastLineOfItsDiffHunk() throws {
        let data = try Data(contentsOf: projectRoot.appending(path: "probe/pr-marmot-14569.json"))
        let response = try JSONDecoder().decode(ProbeResponse.self, from: data)
        let thread = try #require(response.data.repository.pullRequest.reviewThreads.nodes.first)
        let hunkText = try #require(thread.comments.nodes.first?.diffHunk)

        let last = try #require(DiffParser.parseHunks(hunkText).last?.lines.last)
        #expect(thread.diffSide == "RIGHT")
        #expect(last.newLine == thread.line)
    }

    @Test func hidesVendoredCodeAndLockfilesAsGitHubDoes() {
        let paths = [
            "vendor/github.com/pkg/errors/errors.go", "tools/vendor/b.go", "web/node_modules/x/index.js", "static/js/jquery.min.js",
            "go.sum", "web/package-lock.json", "src/vendor.go", "main.go", "docs/setup.md",
        ]
        let filter = PathFilter.default
        #expect(paths.filter { filter.excludes($0) } == Array(paths.prefix(6)))
    }

    @Test func keepsReviewWorthyPathsLinguistCallsVendored() {
        let kept = [
            "integration/voip/testdata/golden-recipe.json", ".github/workflows/ci.yml", ".gitignore",
            "spec/fixtures/users.json", "src/types.d.ts", "Jenkinsfile",
        ]
        #expect(kept.filter { PathFilter.default.excludes($0) } == [])
        // Each pattern on the keep-list must still exist in Linguist's list, or an update has changed it.
        #expect(PathFilter.reviewedDespiteLinguist.subtracting(PathFilter.linguistVendorPatterns) == [])
    }

    @Test func hidesDocumentationOnlyWhenAsked() {
        #expect(!PathFilter.default.excludes("docs/setup.md"))
        #expect(PathFilter(hidesDocumentation: true).excludes("docs/setup.md"))
        #expect(!PathFilter(hidesDocumentation: true).excludes("cmd/main.go"))
    }

    @Test func letsGitAttributesOverrideLinguistsRules() {
        let filter = PathFilter.default
        #expect(filter.excludes("gen/schema.go", attributes: LinguistAttributes(generated: true)))
        #expect(!filter.excludes("vendor/patched/lib.go", attributes: LinguistAttributes(vendored: false)))
        #expect(!filter.excludes("go.sum", attributes: LinguistAttributes(generated: false)))
    }
}

private struct ProbeResponse: Decodable {
    struct Thread: Decodable {
        struct Comment: Decodable { let diffHunk: String }
        struct Comments: Decodable { let nodes: [Comment] }
        let line: Int
        let diffSide: String
        let comments: Comments
    }

    struct Threads: Decodable { let nodes: [Thread] }
    struct PullRequest: Decodable { let reviewThreads: Threads }
    struct Repository: Decodable { let pullRequest: PullRequest }
    struct Payload: Decodable { let repository: Repository }
    let data: Payload
}

let projectRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func fixture(_ name: String) throws -> String {
    try String(contentsOf: projectRoot.appending(path: "Tests/LoupeTests/Fixtures/\(name)"), encoding: .utf8)
}

func declaredCounts(_ header: String) -> (old: Int, new: Int) {
    let fields = header.split(separator: " ")
    func count(_ prefix: Character) -> Int {
        guard let field = fields.first(where: { $0.first == prefix }) else { return 0 }
        let parts = field.dropFirst().split(separator: ",")
        return parts.count > 1 ? Int(parts[1]) ?? 0 : 1
    }
    return (count("-"), count("+"))
}
