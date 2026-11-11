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
    @Test func aTabOpensTopDownOnItsFirstFileAndCanBeListedByFolderForThatTabAlone() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest(startingWith: ["go.mod": "module example.com/shop\n"], changing: [
            "cmd/shop/main.go": "package main\n\nimport \"example.com/shop/catalog\"\n\nfunc main() { catalog.Load() }\n",
            "catalog/load.go": "package catalog\n\nfunc Load() {}\n",
            "docs/b.md": "b\n",
            "docs/a.md": "a\n",
        ])
        let tab = try await app.open(pullRequest)
        #expect(tab.fileOrder == .topDown, "top down as a tab opens")
        #expect(!tab.isOrderingFiles)
        #expect(tab.fileGroups == [
            FileGraph.Group(files: ["cmd/shop/main.go", "catalog/load.go"], isStandalone: false),
            FileGraph.Group(files: ["docs/a.md", "docs/b.md"], isStandalone: true),
        ])
        #expect(tab.selectedFile == "cmd/shop/main.go", "the first file top down, not by folder")

        await tab.setFileOrder(.directories)

        #expect(tab.fileOrder == .directories)
        #expect(tab.fileGroups == nil)
        #expect(tab.selectedFile == "cmd/shop/main.go", "the file shown stays")
        tab.selectAdjacentFile(1)
        #expect(tab.selectedFile == "docs/a.md", "moving on follows the folders")
        #expect(app.tabs.tabs.allSatisfy { $0 === tab || $0.fileOrder == .topDown }, "only this tab")
    }

    @Test func aTabWhoseFilesDontUseEachOtherOpensByFolderUnlessDependencyOrderIsPicked() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest(changing: [
            "docs/setup.md": "Setup.\n",
            "config/app.yml": "debug: false\n",
            "Makefile": "test:\n\tgo test ./...\n",
        ])
        let tab = try await app.open(pullRequest)
        #expect(tab.fileOrder == .directories, "nothing to order by")
        #expect(tab.fileGroups == nil)
        #expect(tab.selectedFile == "config/app.yml", "the first file by folder")

        await tab.setFileOrder(.topDown)

        #expect(tab.fileOrder == .topDown, "as picked, though nothing links")
        #expect(tab.fileGroups == [FileGraph.Group(files: ["config/app.yml", "docs/setup.md", "Makefile"], isStandalone: true)])
        #expect(tab.selectedFile == "config/app.yml")
    }

    @Test func anOrderPickedBeforeTheFilesAreOrderedIsKept() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest(changing: ["docs/a.md": "a\n", "docs/b.md": "b\n"])
        let listed = try #require(app.tabs.lists.pullRequest(id: pullRequest.id))
        app.tabs.open(listed)
        let tab = try #require(app.tabs.tab(id: listed.id))
        await tab.setFileOrder(.bottomUp)
        await tab.load()
        #expect(tab.fileOrder == .bottomUp)
        #expect(tab.fileGroups == [FileGraph.Group(files: ["docs/a.md", "docs/b.md"], isStandalone: true)])
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
            "  store/users_test.go",
            "  api/server.go",
            "standalone",
            "  README.md",
        ])
        await tab.setFileOrder(.topDown)
        #expect(outline(tab) == [
            "group",
            "  api/server.go",
            "  store/users.go",
            "  store/users_test.go",
            "  model/user.go",
            "standalone",
            "  README.md",
        ])
        #expect(tab.selectedFile == "api/server.go", "the file the PR opened on stays shown")
        tab.selectAdjacentFile(1)
        #expect(tab.selectedFile == "store/users.go", "moving on follows the list")
        #expect(tab.nextUnviewedFile(after: "store/users.go") == "store/users_test.go", "a test comes straight after what it tests")
    }

    @Test func aGoTestNamedForAFileInAnotherPackageFollowsWhatItUsesInItsOwn() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest(startingWith: ["go.mod": "module example.com/shop\n\ngo 1.22\n"], changing: [
            "billing/invoice/id.go": "package invoice\n\nfunc NewID() string { return \"id\" }\n",
            "billing/invoice/render.go": "package invoice\n\nfunc Render() string { return NewID() }\n",
            "billing/invoice/invoice_test.go": "package invoice\n\nimport \"testing\"\n\nfunc TestRender(t *testing.T) { Render() }\n\nfunc TestNewID(t *testing.T) { NewID() }\n",
            "server/invoice.go": "package server\n\nimport \"example.com/shop/billing/invoice\"\n\nfunc Show() string { return invoice.Render() }\n",
        ])
        let tab = try await app.open(pullRequest)

        await tab.setFileOrder(.bottomUp)

        #expect(outline(tab) == [
            "group",
            "  billing/invoice/id.go",
            "  billing/invoice/render.go",
            "  billing/invoice/invoice_test.go",
            "  server/invoice.go",
        ])
    }

    @Test func goFilesInOnePackageUseThoseDefiningTheTopLevelNamesTheyReferTo() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest(changing: [
            "report/filter.go": "package report\n\n// Filter narrows a report's rows.\ntype Filter struct{ Field string }\n\nfunc (f Filter) Apply() {}\n",
            "report/report.go": "package report\n\ntype Report struct{ filters []Filter }\n\nfunc New() *Report { return &Report{} }\n",
            "report/copy.go": "package report\n\nfunc Copy(r *Report) *Report {\n\tclone := New()\n\tclone.filters = r.filters\n\treturn clone\n}\n",
            "report/limits.go": "package report\n\nconst maxRows = 100\n",
        ])
        let tab = try await app.open(pullRequest)
        await tab.setFileOrder(.bottomUp)
        #expect(outline(tab) == ["group", "  report/filter.go", "  report/report.go", "  report/copy.go", "standalone", "  report/limits.go"])
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

    @Test func aSmallTerraformModulesChangedFilesGroupThoughNeitherUsesTheOtherButALargeOnesDont() async throws {
        let app = try await ThreadsApp()
        var base: [String: String?] = ["modules/app/main.tf": "module \"queue\" {\n  source = \"../queue\"\n}\n"]
        // With the new file, more than a small module holds.
        for index in 1...12 {
            base["envs/prod/service\(index).tf"] = "resource \"aws_sqs_queue\" \"service\(index)\" {}\n"
        }
        let pullRequest = try await app.pushPullRequest(startingWith: base, changing: [
            "modules/app/config.tf": "variable \"name\" {\n  type = string\n}\n",
            "modules/app/outputs.tf": "output \"queue\" {\n  value = module.queue.url\n}\n",
            "envs/prod/service1.tf": "resource \"aws_sqs_queue\" \"service1\" {\n  name = \"one\"\n}\n",
            "envs/prod/service2.tf": "resource \"aws_sqs_queue\" \"service2\" {\n  name = \"two\"\n}\n",
            "envs/prod/new.tf": "resource \"aws_sqs_queue\" \"new\" {}\n",
        ])
        let tab = try await app.open(pullRequest)

        await tab.setFileOrder(.topDown)

        #expect(outline(tab) == [
            "group",
            "  modules/app/config.tf",
            "  modules/app/outputs.tf",
            "standalone",
            "  envs/prod/new.tf",
            "  envs/prod/service1.tf",
            "  envs/prod/service2.tf",
        ])
    }

    @Test func swiftFilesUseTheTargetsTheyImportAndTheTypesBesideThemTheyName() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest(changing: [
            "Sources/Model/Deployment.swift": "public struct Deployment {\n    public let url: String\n}\n",
            "Sources/Model/Conversation.swift": "public struct Conversation {\n    public var deployments: [Deployment]\n}\n",
            "Sources/Store/Store.swift": "import Foundation\nimport Model\n\nfunc save(_ conversation: Conversation) {}\n",
            "Tests/StoreTests/StoreTests.swift": "@testable import Store\nimport Testing\n\nstruct StoreTests {}\n",
            "Package.swift": "// swift-tools-version: 6.0\n",
        ])
        let tab = try await app.open(pullRequest)
        await tab.setFileOrder(.bottomUp)
        #expect(outline(tab) == [
            "group",
            "  Sources/Model/Deployment.swift",
            "  Sources/Model/Conversation.swift",
            "  Sources/Store/Store.swift",
            "  Tests/StoreTests/StoreTests.swift",
            "standalone",
            "  Package.swift",
        ])
    }

    @Test func stylesheetsUseThePartialsTheyUseForwardOrImport() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest(changing: [
            "styles/_colors.scss": "$brand: #36c;\n",
            "styles/mixins/_index.scss": "@forward 'buttons';\n",
            "styles/mixins/_buttons.scss": "@use '../colors';\n\n@mixin button { color: colors.$brand; }\n",
            "styles/app.scss": "@use 'sass:math';\n@use 'mixins';\n@import \"vendor/reset\";\n\n.app { @include mixins.button; }\n",
            "styles/vendor/reset.css": "* { margin: 0; }\n",
        ])
        let tab = try await app.open(pullRequest)
        await tab.setFileOrder(.bottomUp)
        #expect(outline(tab) == [
            "group",
            "  styles/vendor/reset.css",
            "  styles/_colors.scss",
            "  styles/mixins/_buttons.scss",
            "  styles/mixins/_index.scss",
            "  styles/app.scss",
        ])
    }

    @Test func rubyFilesUseWhatTheyRequireRelativeAndTheConstantsTheyNameByRailsConvention() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest(changing: [
            "app/models/billing/line_item.rb": "module Billing\n  class LineItem < ApplicationRecord\n  end\nend\n",
            "app/models/invoice.rb": "class Invoice < ApplicationRecord\n  has_many :items, class_name: Billing::LineItem.name\nend\n",
            "app/services/http_client.rb": "class HTTPClient\nend\n",
            "app/controllers/invoices_controller.rb": "class InvoicesController < ApplicationController\n  def show\n    @invoice = Invoice.find(params[:id])\n    HTTPClient.new\n  end\nend\n",
            "spec/models/invoice_spec.rb": "require_relative '../support/factories'\n\nRSpec.describe Invoice do\nend\n",
            "spec/support/factories.rb": "FACTORIES = {}\n",
        ])
        let tab = try await app.open(pullRequest)
        await tab.setFileOrder(.bottomUp)
        #expect(outline(tab) == [
            "group",
            "  app/models/billing/line_item.rb",
            "  app/services/http_client.rb",
            "  spec/support/factories.rb",
            "  app/models/invoice.rb",
            "  spec/models/invoice_spec.rb",
            "  app/controllers/invoices_controller.rb",
        ], "a spec follows its subject, after the support it requires")
    }

    @Test func aDeletedFileJoinsTheFilesItUsedAndThatUsedItBeforeTheChange() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest(startingWith: [
            "go.mod": "module example.com/shop\n",
            "legacy/prices.go": "package legacy\n\nimport \"example.com/shop/money\"\n\nfunc Price() money.Amount { return 0 }\n",
            "money/amount.go": "package money\n\ntype Amount int\n",
            "checkout/total.go": "package checkout\n\nimport \"example.com/shop/legacy\"\n\nvar total = legacy.Price()\n",
            "src/oldApi.ts": "export const get = () => 1\n",
            "src/view.ts": "import { get } from './oldApi'\n\nget()\n",
        ], changing: [
            "legacy/prices.go": nil,
            "money/amount.go": "package money\n\n// Amount is in pence.\ntype Amount int\n",
            "checkout/total.go": "package checkout\n\nvar total = 0\n",
            "src/oldApi.ts": nil,
            "src/view.ts": "export const view = 1\n",
            "NOTES.md": "notes\n",
        ])
        let tab = try await app.open(pullRequest)
        await tab.setFileOrder(.bottomUp)
        #expect(outline(tab) == [
            "group",
            "  money/amount.go",
            "  legacy/prices.go",
            "  checkout/total.go",
            "group",
            "  src/oldApi.ts",
            "  src/view.ts",
            "standalone",
            "  NOTES.md",
        ])
    }

    @Test func aRenamedFileIsKnownByItsOldPathOnTheBaseSide() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest(startingWith: [
            "src/helpers.ts": "export const one = 1\nexport const two = 2\nexport const three = 3\nexport const four = 4\n",
            "src/legacy.ts": "import { one } from './helpers'\n\nexport const legacy = one\n",
        ], changing: [
            "src/helpers.ts": nil,
            "src/util/helpers.ts": "export const one = 1\nexport const two = 2\nexport const three = 3\nexport const four = 4\n",
            "src/legacy.ts": nil,
        ])
        let tab = try await app.open(pullRequest)
        await tab.setFileOrder(.bottomUp)
        #expect(outline(tab) == ["group", "  src/util/helpers.ts", "  src/legacy.ts"])
    }

    @Test func scriptsGroupWithTheStylesheetsTheyImport() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest(changing: [
            "web/Button.tsx": "import './Button.scss'\n\nexport const Button = () => null\n",
            "web/Button.scss": ".button { color: red; }\n",
            "web/Card.jsx": "import styles from './Card.module.scss'\n\nexport const Card = () => styles.card\n",
            "web/Card.module.scss": ".card { padding: 0; }\n",
        ])
        let tab = try await app.open(pullRequest)
        await tab.setFileOrder(.bottomUp)
        #expect(outline(tab) == ["group", "  web/Button.scss", "  web/Button.tsx", "group", "  web/Card.module.scss", "  web/Card.jsx"])
    }

    @Test func goTestsUseTheHelpersOtherTestsDefineAndTheFixturesTheyNameWithTheirReadme() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest(startingWith: ["go.mod": "module example.com/shop\n", "importer/importer.go": "package importer\n\nfunc Import() {}\n"], changing: [
            "importer/helper_test.go": "package importer\n\nfunc fixtureServer(path string) string { return path }\n",
            "importer/sync_test.go": "package importer\n\nimport \"testing\"\n\nfunc TestSync(t *testing.T) {\n\tfixtureServer(\"testdata/orders.json\")\n}\n",
            "importer/refund_test.go": "package importer\n\nimport \"testing\"\n\nfunc TestRefund(t *testing.T) {\n\tfixtureServer(`testdata/refunds.json`)\n}\n",
            "importer/testdata/orders.json": "[]\n",
            "importer/testdata/refunds.json": "[]\n",
            "importer/testdata/README.md": "Made-up orders.\n",
            "importer/MIGRATION.md": "Moved the tests.\n",
        ])
        let tab = try await app.open(pullRequest)
        await tab.setFileOrder(.bottomUp)
        #expect(outline(tab) == [
            "group",
            "  importer/testdata/orders.json",
            "  importer/testdata/refunds.json",
            "  importer/testdata/README.md",
            "  importer/helper_test.go",
            "  importer/refund_test.go",
            "  importer/sync_test.go",
            "standalone",
            "  importer/MIGRATION.md",
        ])
    }

    @Test func aStoryComesAfterWhatItShowsAndBeforeItsTestsEitherWayUp() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest(changing: [
            "src/panel/panel.tsx": "import { Table } from './table'\n\nexport const Panel = () => Table\n",
            "src/panel/table.tsx": "export const Table = null\n",
            "src/panel/panel.stories.tsx": "import { Panel } from './panel'\nimport { sample } from '../../stories/sample'\n\nexport default { component: Panel, args: sample }\n",
            "src/panel/panel.test.tsx": "import { Panel } from './panel'\nimport data from './fixtures/rows.json'\n\nit('renders', () => Panel)\n",
            "src/panel/fixtures/rows.json": "[]\n",
            "stories/sample.ts": "export const sample = {}\n",
        ])
        let tab = try await app.open(pullRequest)
        await tab.setFileOrder(.topDown)
        #expect(outline(tab) == [
            "group",
            "  src/panel/panel.tsx",
            "  src/panel/panel.stories.tsx",
            "  src/panel/panel.test.tsx",
            "  src/panel/fixtures/rows.json",
            "  src/panel/table.tsx",
            "  stories/sample.ts",
        ])
        await tab.setFileOrder(.bottomUp)
        #expect(outline(tab) == [
            "group",
            "  src/panel/fixtures/rows.json",
            "  src/panel/table.tsx",
            "  stories/sample.ts",
            "  src/panel/panel.tsx",
            "  src/panel/panel.stories.tsx",
            "  src/panel/panel.test.tsx",
        ])
    }

    @Test func anImportResolvingToADeclarationFileUsesTheScriptItDeclaresToo() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest(changing: [
            "ui/picker/picker.js": "export const pick = () => 1\n",
            "ui/picker/picker.d.ts": "export declare const pick: () => number\n",
            "ui/picker/picker.test.js": "import { pick } from './picker'\n\nit('picks', () => pick())\n",
            "ui/picker/README.mdx": "# Picker\n",
        ])
        let tab = try await app.open(pullRequest)
        await tab.setFileOrder(.bottomUp)
        #expect(outline(tab) == ["group", "  ui/picker/picker.js", "  ui/picker/picker.d.ts", "  ui/picker/picker.test.js", "  ui/picker/README.mdx"])
        await tab.setFileOrder(.topDown)
        #expect(outline(tab) == ["group", "  ui/picker/picker.js", "  ui/picker/picker.d.ts", "  ui/picker/picker.test.js", "  ui/picker/README.mdx"])
    }

    @Test func railsViewsUseTheHelpersTheyCallAndThePartialsTheyRenderWithSpecsAfterWhatTheyTest() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest(changing: [
            "app/helpers/application_helper.rb": "module ApplicationHelper\n  def bundle_tags(name)\n    name\n  end\nend\n",
            "app/views/layouts/application.html.erb": "<html>\n<%= render 'shared/head' %>\n<%= bundle_tags 'app' %>\n</html>\n",
            "app/views/shared/_head.html.erb": "<%# The page's head %>\n<title><%= page_title %></title>\n",
            "spec/helpers/bundle_tags_spec.rb": "RSpec.describe 'bundle tags' do\n  it { expect(helper.bundle_tags('a')).to eq('a') }\nend\n",
            "NOTES.md": "notes\n",
        ])
        let tab = try await app.open(pullRequest)
        #expect(outline(tab) == [
            "group",
            "  app/views/layouts/application.html.erb",
            "  app/helpers/application_helper.rb",
            "  spec/helpers/bundle_tags_spec.rb",
            "  app/views/shared/_head.html.erb",
            "standalone",
            "  NOTES.md",
        ], "a spec named for no file follows the helper it calls")
        await tab.setFileOrder(.bottomUp)
        #expect(outline(tab) == [
            "group",
            "  app/helpers/application_helper.rb",
            "  spec/helpers/bundle_tags_spec.rb",
            "  app/views/shared/_head.html.erb",
            "  app/views/layouts/application.html.erb",
            "standalone",
            "  NOTES.md",
        ])
    }

    @Test func railsRoutesUseTheirControllersAndControllersTheirViewsDeletedOnesToo() async throws {
        let app = try await ThreadsApp()
        let pullRequest = try await app.pushPullRequest(startingWith: [
            "app/controllers/reports_controller.rb": "class ReportsController < ApplicationController\n  def show; end\nend\n",
            "app/views/reports/show.html.erb": "<h1>Report</h1>\n",
            "app/controllers/home_controller.rb": "class HomeController < ApplicationController\n  def index; end\nend\n",
            "config/routes.rb": "Rails.application.routes.draw do\n  get 'reports/:id' => 'reports#show'\n  get 'home', to: 'home#index'\nend\n",
        ], changing: [
            "app/controllers/reports_controller.rb": nil,
            "app/views/reports/show.html.erb": nil,
            "app/controllers/home_controller.rb": "class HomeController < ApplicationController\n  def index\n    @greeting = 'hi'\n  end\nend\n",
            "app/views/home/index.html.erb": "<p><%= @greeting %></p>\n",
            "config/routes.rb": "Rails.application.routes.draw do\n  get 'home', to: 'home#index'\nend\n",
        ])
        let tab = try await app.open(pullRequest)
        #expect(outline(tab) == [
            "group",
            "  config/routes.rb",
            "  app/controllers/home_controller.rb",
            "  app/controllers/reports_controller.rb",
            "  app/views/home/index.html.erb",
            "  app/views/reports/show.html.erb",
        ], "routes, then controllers, then their views")
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
