import AppKit
import LoupeCore
import Testing

@MainActor
struct SyntaxHighlightingTests {
    @Test func colorsAGoHunkLikeGitHubOnBothSides() throws {
        let rendered = try showing(greet(path: "greet.go"))

        #expect(colors(of: "func", in: rendered) == [DiffColors.syntaxKeyword])
        #expect(colors(of: "Greet()", in: rendered, length: 5) == [DiffColors.syntaxEntity])
        #expect(colors(of: "// Greet says hello.", in: rendered) == [DiffColors.syntaxComment])
        #expect(colors(of: "\"hello\"", in: rendered) == [DiffColors.syntaxString])
        // Deleted rows are coloured from the old side's code.
        #expect(colors(of: "// Greet says hi.", in: rendered) == [DiffColors.syntaxComment])
        #expect(colors(of: "\"hi\"", in: rendered) == [DiffColors.syntaxString])
        // The surrounding code and the gutter keep their own colours.
        #expect(colors(of: "main", in: rendered) == [NSColor.textColor])
        #expect(colors(of: "@@ -1,5", in: rendered) == [NSColor.secondaryLabelColor])
    }

    @Test func aLargeFileShowsPlainFirstThenTakesItsColours() async throws {
        let view = DiffTextView.make()
        view.inlineHighlightRows = 0
        view.show(RenderedDiff(file: try greet(path: "greet.go")))
        #expect(colors(of: "func", in: view) == [NSColor.textColor])

        // The deadline only guards against a hang, so it outlasts a whole suite on a busy machine.
        let deadline = ContinuousClock.now + .seconds(300)
        while colors(of: "func", in: view) == [NSColor.textColor], ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(colors(of: "func", in: view) == [DiffColors.syntaxKeyword])
    }

    @Test(arguments: [
        ("a.go", "// note"), ("a.js", "// note"), ("a.ts", "// note"), ("a.tsx", "// note"),
        ("Gemfile", "# note"), ("a.swift", "// note"), ("a.json", "\"note\""), ("a.yml", "# note"),
        ("a.sh", "# note"), ("a.css", "/* note */"), ("a.html", "<!-- note -->"),
        ("Dockerfile", "# note"), ("a.sql", "-- note"), ("go.mod", "// note"), ("a.py", "# note"), ("a.md", "# Note"),
        ("a.proto", "// note"), ("main.tf", "# note"), ("prod.tfvars", "# note"), ("a.hcl", "# note"),
        ("a.graphql", "# note"), ("a.gql", "# note"), ("schema.graphqls", "# note"),
        ("a.scss", "// note"),
        ("Makefile", "# note"), ("GNUmakefile", "# note"), ("rules.mk", "# note"), ("build.mak", "# note"),
        ("a.tmpl", "{{/* note */}}"), ("a.gotmpl", "{{/* note */}}"), ("a.gohtml", "{{/* note */}}"),
        ("a.html.tmpl", "{{/* note */}}"), ("a.tpl", "{{/* note */}}"), ("_helpers.tpl", "{{/* note */}}"),
    ])
    func everySupportedLanguageHighlights(path: String, line: String) throws {
        #expect(SyntaxLanguage(path: path) != nil)
        let file = try #require(Diff(parsing: """
        diff --git a/\(path) b/\(path)
        --- a/\(path)
        +++ b/\(path)
        @@ -0,0 +1 @@
        +\(line)

        """).files.first)
        #expect(colors(of: line, in: showing(file)) != [NSColor.textColor])
    }

    @Test(arguments: ["Dockerfile.prod", "deploy/Containerfile", "build.dockerfile"])
    func recognisesDockerfilesByName(path: String) throws {
        let file = try #require(Diff(parsing: """
        diff --git a/\(path) b/\(path)
        --- a/\(path)
        +++ b/\(path)
        @@ -0,0 +1 @@
        +FROM golang

        """).files.first)
        #expect(colors(of: "FROM", in: showing(file)) == [DiffColors.syntaxKeyword])
    }

    @Test func picksALanguageByFileNameBeforeExtension() {
        #expect(SyntaxLanguage(path: "deploy/Dockerfile") == SyntaxLanguage(path: "a.dockerfile"))
        #expect(SyntaxLanguage(path: "go.mod") != nil)
        #expect(SyntaxLanguage(path: "go.mod") != SyntaxLanguage(path: "a.go"))
        #expect(SyntaxLanguage(path: "Makefile") == SyntaxLanguage(path: "rules.mk"))
        #expect(SyntaxLanguage(path: "Makefile.in") == SyntaxLanguage(path: "rules.mk"))
    }

    @Test func picksALanguageByTheLongestExtension() {
        #expect(SyntaxLanguage(path: "db/schema.yml.mysql") == SyntaxLanguage(path: "a.yml"))
        #expect(SyntaxLanguage(path: "a.mysql") == SyntaxLanguage(path: "a.sql"))
        #expect(SyntaxLanguage(path: "build.gradle.kts") == SyntaxLanguage(path: "a.kt"))
    }

    @Test(arguments: ["config/database.yml.ci", "vault.yml.ci", "memcache.yml.docker"])
    func takesTheLanguageFromBeforeASuffixLinguistDoesNotKnow(path: String) throws {
        let settings = { (path: String) in
            try #require(Diff(parsing: """
            diff --git a/\(path) b/\(path)
            --- a/\(path)
            +++ b/\(path)
            @@ -0,0 +1,2 @@
            +# Test settings.
            +host: localhost

            """).files.first)
        }
        let rendered = showing(try settings(path))
        let yaml = showing(try settings("config/database.yml"))

        #expect(colors(of: "# Test settings.", in: rendered) == [DiffColors.syntaxComment])
        #expect(colors(of: "host", in: rendered) != [NSColor.textColor])
        #expect(colors(of: "host", in: rendered) == colors(of: "host", in: yaml))
    }

    @Test func aSuffixLinguistKnowsIsNotPassedOver() {
        #expect(SyntaxLanguage(path: "config.json.example") == SyntaxLanguage(path: "a.json"))
        #expect(SyntaxLanguage(path: "settings.json.sample") == SyntaxLanguage(path: "a.json"))
        // `.html.tmpl` is Go Template's own extension, so it isn't taken for HTML.
        #expect(SyntaxLanguage(path: "page.html.tmpl") == SyntaxLanguage(path: "a.tmpl"))
        #expect(SyntaxLanguage(path: "page.html.tmpl") != SyntaxLanguage(path: "a.html"))
        // `.txt` is Text, which has no grammar, so the file stays plain rather than YAML.
        #expect(SyntaxLanguage(path: "notes.yml.txt") == nil)
        // Only the name's own suffix is passed over, not a directory's.
        #expect(SyntaxLanguage(path: "config.yml/README") == nil)
    }

    @Test func colorsAProtocolBufferFile() throws {
        let file = try #require(Diff(parsing: """
        diff --git a/user.proto b/user.proto
        --- a/user.proto
        +++ b/user.proto
        @@ -0,0 +1,10 @@
        +syntax = "proto3";
        +
        +// Users of the service.
        +package x;
        +option go_package = "example.com/x";
        +
        +message Foo {
        +  string name = 1;
        +  repeated int32 ids = 2;
        +}

        """).files.first)
        let rendered = showing(file)

        for keyword in ["syntax", "package", "option", "message", "repeated"] {
            #expect(colors(of: keyword, in: rendered) == [DiffColors.syntaxKeyword], "\(keyword)")
        }
        #expect(colors(of: "\"proto3\"", in: rendered) == [DiffColors.syntaxString])
        #expect(colors(of: "\"example.com/x\"", in: rendered) == [DiffColors.syntaxString])
        #expect(colors(of: "// Users of the service.", in: rendered) == [DiffColors.syntaxComment])
        #expect(colors(of: "Foo", in: rendered) == [DiffColors.syntaxEntity])
        // Scalar types are built in, so they take the keyword colour, as Go's do.
        #expect(colors(of: "string name", in: rendered, length: 6) == [DiffColors.syntaxKeyword])
        #expect(colors(of: "int32", in: rendered) == [DiffColors.syntaxKeyword])
        #expect(colors(of: "name =", in: rendered, length: 4) == [DiffColors.syntaxConstant])
        #expect(colors(of: "1;", in: rendered, length: 1) == [DiffColors.syntaxConstant])
        #expect(colors(of: "2;", in: rendered, length: 1) == [DiffColors.syntaxConstant])
    }

    @Test func colorsATerraformFile() throws {
        let file = try #require(Diff(parsing: """
        diff --git a/main.tf b/main.tf
        --- a/main.tf
        +++ b/main.tf
        @@ -0,0 +1,9 @@
        +# The app's bucket.
        +resource "aws_s3_bucket" "app" {
        +  bucket = "app-${var.env}"
        +  count  = 2
        +  tags   = merge(local.tags, { public = false })
        +  lifecycle {
        +    prevent_destroy = true
        +  }
        +}

        """).files.first)
        let rendered = showing(file)

        #expect(colors(of: "# The app's bucket.", in: rendered) == [DiffColors.syntaxComment])
        #expect(colors(of: "resource", in: rendered) == [DiffColors.syntaxKeyword])
        #expect(colors(of: "\"aws_s3_bucket\"", in: rendered) == [DiffColors.syntaxString])
        #expect(colors(of: "\"app-", in: rendered) == [DiffColors.syntaxString])
        #expect(colors(of: "var.env", in: rendered, length: 3) == [DiffColors.syntaxConstant])
        #expect(colors(of: "2\n", in: rendered, length: 1) == [DiffColors.syntaxConstant])
        #expect(colors(of: "merge", in: rendered) == [DiffColors.syntaxEntity])
        #expect(colors(of: "false", in: rendered) == [DiffColors.syntaxConstant])
        // A nested block is named as a type is.
        #expect(colors(of: "lifecycle", in: rendered) == [DiffColors.syntaxEntity])
    }

    @Test func colorsAGraphQLFile() throws {
        let file = try #require(Diff(parsing: """
        diff --git a/repo.graphql b/repo.graphql
        --- a/repo.graphql
        +++ b/repo.graphql
        @@ -0,0 +1,13 @@
        +# Looks up a repository.
        +query Repo($owner: String!, $first: Int = 10) {
        +  repository(owner: $owner, name: "app") {
        +    issues(first: $first) @include(if: true) {
        +      totalCount
        +    }
        +  }
        +}
        +
        +"Someone with an account."
        +type User implements Node {
        +  login: String!
        +}

        """).files.first)
        let rendered = showing(file)

        #expect(colors(of: "# Looks up a repository.", in: rendered) == [DiffColors.syntaxComment])
        #expect(colors(of: "query", in: rendered) == [DiffColors.syntaxKeyword])
        #expect(colors(of: "$owner:", in: rendered, length: 6) == [DiffColors.syntaxVariable])
        #expect(colors(of: "String!", in: rendered, length: 6) == [DiffColors.syntaxEntity])
        #expect(colors(of: "10", in: rendered) == [DiffColors.syntaxConstant])
        #expect(colors(of: "repository(", in: rendered, length: 10) == [DiffColors.syntaxConstant])
        #expect(colors(of: "name:", in: rendered, length: 4) == [DiffColors.syntaxVariable])
        #expect(colors(of: "\"app\"", in: rendered) == [DiffColors.syntaxString])
        #expect(colors(of: "@include", in: rendered) == [DiffColors.syntaxEntity])
        // A description is documentation, so it reads as a comment.
        #expect(colors(of: "\"Someone with an account.\"", in: rendered) == [DiffColors.syntaxComment])
        #expect(colors(of: "type", in: rendered) == [DiffColors.syntaxKeyword])
        #expect(colors(of: "User", in: rendered) == [DiffColors.syntaxEntity])
        #expect(colors(of: "implements", in: rendered) == [DiffColors.syntaxKeyword])
        #expect(colors(of: "login", in: rendered) == [DiffColors.syntaxConstant])
    }

    @Test func colorsAnSCSSFile() throws {
        let file = try #require(Diff(parsing: """
        diff --git a/button.scss b/button.scss
        --- a/button.scss
        +++ b/button.scss
        @@ -0,0 +1,14 @@
        +// Buttons.
        +@use "sass:math";
        +$gap: 4px;
        +
        +@mixin pad($size) {
        +  padding: math.div($size, 2);
        +}
        +
        +.button {
        +  color: #fff;
        +  @include pad($gap);
        +  &:hover { font-weight: bold; }
        +  /* Lifted. */
        +}

        """).files.first)
        let rendered = showing(file)

        #expect(colors(of: "// Buttons.", in: rendered) == [DiffColors.syntaxComment])
        #expect(colors(of: "/* Lifted. */", in: rendered) == [DiffColors.syntaxComment])
        #expect(colors(of: "@use", in: rendered) == [DiffColors.syntaxKeyword])
        #expect(colors(of: "\"sass:math\"", in: rendered) == [DiffColors.syntaxString])
        #expect(colors(of: "@mixin", in: rendered) == [DiffColors.syntaxKeyword])
        #expect(colors(of: "@include", in: rendered) == [DiffColors.syntaxKeyword])
        #expect(colors(of: "pad($gap)", in: rendered, length: 3) == [DiffColors.syntaxEntity])
        #expect(colors(of: "4px", in: rendered, length: 1) == [DiffColors.syntaxConstant])
        // CSS's own syntax is coloured as in a CSS file.
        #expect(colors(of: "button", in: rendered) == [DiffColors.syntaxConstant])
        #expect(colors(of: "color", in: rendered) == [DiffColors.syntaxConstant])
        #expect(colors(of: "font-weight", in: rendered) == [DiffColors.syntaxConstant])
        #expect(colors(of: "hover", in: rendered) == [DiffColors.syntaxConstant])
    }

    @Test func colorsAMakefile() throws {
        let file = try #require(Diff(parsing: """
        diff --git a/Makefile b/Makefile
        --- a/Makefile
        +++ b/Makefile
        @@ -0,0 +1,10 @@
        +# Builds the app.
        +.PHONY: build
        +GO ?= go
        +SOURCES := $(wildcard *.go)
        +
        +build: $(SOURCES)
        +\t@$(GO) build -o $@ ./...
        +ifeq ($(CI),true)
        +include ci.mk
        +endif

        """).files.first)
        let rendered = showing(file)

        #expect(colors(of: "# Builds the app.", in: rendered) == [DiffColors.syntaxComment])
        #expect(colors(of: ".PHONY", in: rendered) == [DiffColors.syntaxEntity])
        #expect(colors(of: "build:", in: rendered, length: 5) == [DiffColors.syntaxEntity])
        // A variable's name takes the string colour, as the query matches the shell's.
        #expect(colors(of: "GO ?=", in: rendered, length: 2) == [DiffColors.syntaxString])
        #expect(colors(of: "?=", in: rendered) == [DiffColors.syntaxKeyword])
        #expect(colors(of: "wildcard", in: rendered) == [DiffColors.syntaxEntity])
        #expect(colors(of: "$(SOURCES)", in: rendered, length: 2) == [DiffColors.syntaxKeyword])
        #expect(colors(of: "SOURCES)", in: rendered, length: 7) == [DiffColors.syntaxString])
        for keyword in ["ifeq", "include", "endif"] {
            #expect(colors(of: keyword, in: rendered) == [DiffColors.syntaxKeyword], "\(keyword)")
        }
        // A recipe is shell, which isn't parsed, so only Make's own syntax in it is coloured.
        #expect(colors(of: "build -o", in: rendered) == [NSColor.textColor])
    }

    @Test func colorsAGoTemplate() throws {
        let file = try #require(Diff(parsing: """
        diff --git a/page.html.tmpl b/page.html.tmpl
        --- a/page.html.tmpl
        +++ b/page.html.tmpl
        @@ -0,0 +1,8 @@
        +{{/* The list of users. */}}
        +<ul class="users">
        +{{- range $i, $user := .Users }}
        +  <li>{{ printf "%d: %s" $i $user.Name | html }}</li>
        +{{- else }}
        +  <li>None, {{ len .Users }} in all</li>
        +{{- end }}
        +</ul>

        """).files.first)
        let rendered = showing(file)

        #expect(colors(of: "/* The list of users. */", in: rendered) == [DiffColors.syntaxComment])
        for keyword in ["range", "else", "end"] {
            #expect(colors(of: keyword, in: rendered) == [DiffColors.syntaxKeyword], "\(keyword)")
        }
        #expect(colors(of: ":=", in: rendered) == [DiffColors.syntaxKeyword])
        #expect(colors(of: "printf", in: rendered) == [DiffColors.syntaxEntity])
        #expect(colors(of: "\"%d: %s\"", in: rendered) == [DiffColors.syntaxString])
        #expect(colors(of: "Name", in: rendered) == [DiffColors.syntaxConstant])
        #expect(colors(of: "len", in: rendered) == [DiffColors.syntaxEntity])
        // The HTML around the actions isn't parsed, so it stays plain.
        #expect(colors(of: "<ul class=\"users\">", in: rendered) == [NSColor.textColor])
        #expect(colors(of: "None, ", in: rendered) == [NSColor.textColor])
    }

    @Test func aHunkStartingInsideADeclarationIsColouredAsPartOfIt() throws {
        let file = try #require(Diff(parsing: """
        diff --git a/client.go b/client.go
        --- a/client.go
        +++ b/client.go
        @@ -25,5 +25,7 @@ type Client struct {
         \tCreateFn     func(*pb.CreateRequest) (*pb.CreateResponse, error)
         \tCreateCalled int64
        +
        +\tUpdateFn     func(*pb.UpdateRequest) (*pb.UpdateResponse, error)
        +\tUpdateCalled int64
         }

        """).files.first)
        let rendered = showing(file)

        // Alone, the fields would parse as statements and miss most of their colours.
        #expect(colors(of: "func(*pb.Create", in: rendered, length: 4) == [DiffColors.syntaxKeyword])
        #expect(colors(of: "func(*pb.Update", in: rendered, length: 4) == [DiffColors.syntaxKeyword])
        #expect(colors(of: "UpdateCalled", in: rendered) == [DiffColors.syntaxConstant])
        #expect(colors(of: "int64", in: rendered) == [DiffColors.syntaxEntity])
        // The header itself isn't coloured as code.
        #expect(colors(of: "type Client", in: rendered) == [NSColor.textColor])
    }

    @Test func aHunkAfterItsHeadersDeclarationHasClosedIsColouredOnItsOwn() throws {
        let file = try #require(Diff(parsing: """
        diff --git a/request.pb.go b/request.pb.go
        --- a/request.pb.go
        +++ b/request.pb.go
        @@ -1262,7 +1262,7 @@ func (x *Request) String() string {
         func (*Request) ProtoMessage() {}

         func (x *Request) ProtoReflect() protoreflect.Message {
        -\tmi := &file_proto_msgTypes[17]
        +\tmi := &file_proto_msgTypes[19]
         \tif protoimpl.UnsafeEnabled && x != nil {
         \t\tms := protoimpl.X.MessageStateOf(protoimpl.Pointer(x))
         \t\tif ms.LoadMessageInfo() == nil {

        """).files.first)
        let rendered = showing(file)

        // Led by the header's line, the methods would parse as nested in String's body.
        #expect(colors(of: "func (*Request)", in: rendered, length: 4) == [DiffColors.syntaxKeyword])
        #expect(colors(of: "if protoimpl", in: rendered, length: 2) == [DiffColors.syntaxKeyword])
        #expect(colors(of: "if ms", in: rendered, length: 2) == [DiffColors.syntaxKeyword])
        #expect(colors(of: "LoadMessageInfo", in: rendered) == [DiffColors.syntaxEntity])
    }

    @Test func aHunkHeaderCutShortIsNotTakenAsItsDeclaration() throws {
        let file = try #require(Diff(parsing: """
        diff --git a/cmd.go b/cmd.go
        --- a/cmd.go
        +++ b/cmd.go
        @@ -54,3 +57,5 @@ func NewClientWithKeyring(keyringClient keyring.EncryptionProvider) (*consulate.Client,

         \treturn consulate.NewClient(consulateServiceClient, keyringClient), nil
         }
        +
        +func TracingExtra() {}

        """).files.first)
        let rendered = showing(file)

        // Led by half a signature, the body's first lines would parse as its parameters.
        #expect(colors(of: "return", in: rendered) == [DiffColors.syntaxKeyword])
        #expect(colors(of: "keyringClient), nil", in: rendered, length: 13) == [NSColor.textColor])
    }

    @Test func leavesAFileInAnUnknownLanguageUncoloured() throws {
        let plain = try showing(greet(path: "greet.unknown"))

        for needle in ["func", "// Greet says hello.", "\"hello\"", "\"hi\""] {
            #expect(colors(of: needle, in: plain) == [NSColor.textColor])
        }
    }
}

private func greet(path: String) throws -> FileDiff {
    try #require(Diff(parsing: """
    diff --git a/\(path) b/\(path)
    --- a/\(path)
    +++ b/\(path)
    @@ -1,5 +1,5 @@
     package main

    -// Greet says hi.
    +// Greet says hello.
     func Greet() string {
    -\treturn "hi"
    +\treturn "hello"

    """).files.first)
}

@MainActor
private func showing(_ file: FileDiff) -> DiffTextView {
    let view = DiffTextView.make()
    view.show(RenderedDiff(file: file))
    return view
}

/// The distinct colours the view draws across the first occurrence of `needle` (or its first `length` characters).
@MainActor
private func colors(of needle: String, in view: DiffTextView, length: Int? = nil) -> [NSColor] {
    guard let layoutManager = view.layoutManager, let storage = view.textStorage else { return [] }
    let found = (storage.string as NSString).range(of: needle)
    var seen: [NSColor] = []
    for index in found.location..<(found.location + (length ?? found.length)) {
        let drawn = layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil)
            ?? storage.attribute(.foregroundColor, at: index, effectiveRange: nil)
        if let color = drawn as? NSColor, !seen.contains(color) { seen.append(color) }
    }
    return seen
}
