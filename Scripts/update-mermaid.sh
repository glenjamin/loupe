#!/bin/sh
# Refreshes the vendored Mermaid that draws GitHub's mermaid diagrams in the
# app's web views. Usage: Scripts/update-mermaid.sh 11.17.2
#
# Takes the npm package's single-file browser build, which bundles every
# diagram type, so the app never fetches anything to draw one.
set -eu

version=${1:?usage: $0 <mermaid version, e.g. 11.17.2>}
dir=Sources/LoupeCore/Resources/mermaid
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "https://registry.npmjs.org/mermaid/-/mermaid-$version.tgz" -o "$tmp/mermaid.tgz"
tar -xzf "$tmp/mermaid.tgz" -C "$tmp" package/dist/mermaid.min.js package/LICENSE

mkdir -p "$dir"
cp "$tmp/package/dist/mermaid.min.js" "$dir/mermaid.min.js"
cp "$tmp/package/LICENSE" "$dir/LICENSE"
echo "$version" > "$dir/VERSION"
echo "Mermaid $version written to $dir"
