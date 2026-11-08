@testable import LoupeFakeGitHub
import Foundation
import LoupeCore
import LoupeGit
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

@MainActor
struct FileOrderTests {
    @Test func filesAreListedByFolderUntilAskedForDependencyOrderForThatTabAlone() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest(changing: ["docs/b.md": "b\n", "docs/a.md": "a\n", "README.md": "readme\n"])
        let tab = try await app.open(pullRequest)
        #expect(tab.fileOrder == .directories, "folders as a tab opens")
        #expect(tab.fileGroups == nil)

        await tab.setFileOrder(.bottomUp)

        #expect(tab.fileOrder == .bottomUp)
        #expect(tab.fileGroups == [FileGraph.Group(files: ["docs/a.md", "docs/b.md", "README.md"], isStandalone: true)], "files using nothing list as the tree does")
        #expect(app.tabs.tabs.allSatisfy { $0 === tab || $0.fileOrder == .directories }, "only this tab")
        await tab.setFileOrder(.directories)
        #expect(tab.fileGroups == nil)
    }

    @Test func goFilesUseThePackagesTheyImportAndTestsTheirOwnPackage() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest(startingWith: ["go.mod": "module example.com/shop\n\ngo 1.22\n"], changing: [
            "model/user.go": "package model\n\ntype User struct{ Name string }\n",
            "store/users.go": "package store\n\nimport \"example.com/shop/model\"\n\nfunc Find() model.User { return model.User{} }\n",
            "store/users_test.go": "package store\n\nimport \"testing\"\n\nfunc TestFind(t *testing.T) { Find() }\n",
            "api/server.go": "package api\n\nimport (\n\t\"fmt\"\n\n\t\"example.com/shop/store\"\n)\n\nfunc Serve() { fmt.Println(store.Find()) }\n",
            "README.md": "# shop\n",
        ])
        let tab = try await app.open(pullRequest)

        await tab.setFileOrder(.bottomUp)

        #expect(outline(tab) == [
            "group",
            "  model/user.go",
            "  store/users.go",
            "  api/server.go",
            "  store/users_test.go",
            "standalone",
            "  README.md",
        ])
        await tab.setFileOrder(.topDown)
        #expect(outline(tab) == [
            "group",
            "  api/server.go",
            "  store/users_test.go",
            "  store/users.go",
            "  model/user.go",
            "standalone",
            "  README.md",
        ])
        #expect(tab.selectedFile == "api/server.go", "the file the PR opened on stays shown")
        tab.selectAdjacentFile(1)
        #expect(tab.selectedFile == "store/users_test.go", "moving on follows the list")
        #expect(tab.nextUnviewedFile(after: "store/users_test.go") == "store/users.go")
    }

    @Test func goModulesNestedInTheRepoResolveFromTheirOwnGoMod() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest(startingWith: ["services/billing/go.mod": "module github.com/acme/billing\n"], changing: [
            "services/billing/invoice/invoice.go": "package invoice\n\ntype Invoice struct{}\n",
            "services/billing/cmd/billing/main.go": "package main\n\nimport `github.com/acme/billing/invoice`\n\nvar _ invoice.Invoice\n",
        ])
        let tab = try await app.open(pullRequest)
        await tab.setFileOrder(.bottomUp)
        #expect(outline(tab) == ["group", "  services/billing/invoice/invoice.go", "  services/billing/cmd/billing/main.go"])
    }

    @Test func scriptsUseTheFilesTheyImportRequireOrReExportByRelativePath() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest(changing: [
            "src/api/client.ts": "export const get = (url: string) => fetch(url)\n",
            "src/api/index.ts": "export * from './client'\n",
            "src/hooks/useUser.ts": "import { get } from '../api'\nimport type { User } from '../types/user.js'\n\nexport const useUser = () => get('/user') as Promise<User>\n",
            "src/types/user.ts": "export interface User { name: string }\n",
            "src/components/Profile.tsx": "import React from 'react'\nimport { useUser } from '../hooks/useUser'\nimport './Profile.scss'\n\nexport const Profile = () => <div />\n",
            "src/components/Profile.scss": ".profile { color: red; }\n",
            "scripts/build.js": "const lazy = () => import('../src/api/client')\nconst fs = require('fs')\n",
        ])
        let tab = try await app.open(pullRequest)

        await tab.setFileOrder(.bottomUp)

        #expect(outline(tab) == [
            "group",
            "  src/api/client.ts",
            "  scripts/build.js",
            "  src/api/index.ts",
            "  src/components/Profile.scss",
            "  src/types/user.ts",
            "  src/hooks/useUser.ts",
            "  src/components/Profile.tsx",
        ])
    }

    @Test func bareSpecifiersResolveThroughTheTsconfigsPathsAndBaseUrl() async throws {
        let app = try await ThreadsApp()
        let tsconfig = """
            {
              // Aliases for the app's own code.
              "compilerOptions": {
                "baseUrl": "web",
                "paths": {
                  "@/*": ["src/*"], /* the app */
                  "~config": ["config/index.ts"],
                },
              },
            }
            """
        let pullRequest = try await app.pushPullRequest(startingWith: ["tsconfig.json": tsconfig], changing: [
            "web/src/store.ts": "export const store = {}\n",
            "web/config/index.ts": "export default {}\n",
            "web/lib/format.ts": "export const format = String\n",
            "web/src/App.tsx": "import { store } from '@/store'\nimport config from '~config'\nimport { format } from 'lib/format'\nimport lodash from 'lodash'\n",
        ])
        let tab = try await app.open(pullRequest)
        await tab.setFileOrder(.topDown)
        #expect(outline(tab) == ["group", "  web/src/App.tsx", "  web/config/index.ts", "  web/lib/format.ts", "  web/src/store.ts"])
    }

    @Test func terraformFilesUseWhatTheirModuleDefinesElsewhereAndTheLocalModulesTheyCall() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest(changing: [
            "modules/cache/variables.tf": "variable \"name\" {\n  type = string\n}\n",
            "modules/cache/main.tf": "resource \"aws_elasticache_cluster\" \"this\" {\n  cluster_id = var.name\n}\n",
            "modules/cache/outputs.tf": "output \"endpoint\" {\n  value = aws_elasticache_cluster.this.cache_nodes[0].address\n}\n",
            "envs/prod/locals.tf": "locals {\n  # Services\n  services = { cache = \"cache\" }\n}\n",
            "envs/prod/main.tf": "module \"cache\" {\n  source = \"../../modules/cache\"\n  name   = \"${local.services.cache}-prod\"\n}\n\nmodule \"vpc\" {\n  source = \"terraform-aws-modules/vpc/aws\"\n}\n",
            "envs/prod/outputs.tf": "output \"cache\" {\n  value = module.cache.endpoint\n}\n\ndata \"aws_region\" \"current\" {}\n",
            "envs/prod/region.tf": "output \"region\" {\n  value = data.aws_region.current.name\n}\n",
        ])
        let tab = try await app.open(pullRequest)

        await tab.setFileOrder(.bottomUp)

        #expect(outline(tab) == [
            "group",
            "  envs/prod/locals.tf",
            "  modules/cache/variables.tf",
            "  modules/cache/main.tf",
            "  modules/cache/outputs.tf",
            "  envs/prod/main.tf",
            "  envs/prod/outputs.tf",
            "  envs/prod/region.tf",
        ])
    }
}

/// The shown changes' groups, each as a line saying what kind it is, then its files indented.
@MainActor
private func outline(_ tab: PullRequestTab) -> [String] {
    (tab.fileGroups ?? []).flatMap { [$0.isStandalone ? "standalone" : "group"] + $0.files.map { "  \($0)" } }
}

extension ThreadsApp {
    /// Makes the first to-review PR one commit writing `files` (nil deletes) after `base` on
    /// main, and returns it as the lists now have it.
    func pushPullRequest(startingWith base: [String: String?] = [".gitignore": "*.tmp\n"], changing files: [String: String?]) async throws -> PullRequestSummary {
        let listed = try #require(tabs.lists.pullRequests(in: .toReview).first)
        try await conversations.add(listed.id, number: listed.number)
        try await store.updateLocalRepos(saving: [LocalRepo(nameWithOwner: listed.repository, path: repo.checkout, verifiedAt: .now)])
        let branchPoint = try await repo.commit(base, message: "Start")
        try await repo.push()
        try await repo.switchTo("feature", creatingFrom: "main")
        let head = try await repo.commit(files, message: "Change files")
        try await repo.push(asPullRequest: listed.number)
        try await github.edit(listed.id) { $0.headRefOid = head; $0.baseRefOid = branchPoint }
        await conversations.setHead(head, of: listed.id)
        await tabs.lists.refresh()
        return try #require(tabs.lists.pullRequest(id: listed.id))
    }
}
