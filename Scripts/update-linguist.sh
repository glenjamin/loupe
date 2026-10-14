#!/bin/sh
# Refreshes the GitHub Linguist data Loupe uses to pick a grammar for a path
# and to hide vendored files. Usage: Scripts/update-linguist.sh v9.7.0
#
# The YAML is converted to JSON here so the app can read it with JSONDecoder;
# languages.yml keeps only the file names and extensions the lookup reads.
set -eu

tag=${1:?usage: $0 <linguist tag, e.g. v9.7.0>}
dir=Sources/LoupeCore/Resources/linguist
raw=https://raw.githubusercontent.com/github-linguist/linguist/$tag
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for file in languages vendor documentation; do
  curl -fsSL "$raw/lib/linguist/$file.yml" -o "$tmp/$file.yml"
done
curl -fsSL "$raw/LICENSE" -o "$tmp/LICENSE"

mkdir -p "$dir"
ruby -ryaml -rjson -e '
  keep = %w[extensions filenames]
  languages = YAML.load_file(ARGV[0]).transform_values { |l| l.slice(*keep) }
  File.write(ARGV[1], JSON.generate(languages) + "\n")
  File.write(ARGV[3], JSON.generate(YAML.load_file(ARGV[2])) + "\n")
  File.write(ARGV[5], JSON.generate(YAML.load_file(ARGV[4])) + "\n")
' "$tmp/languages.yml" "$dir/languages.json" \
  "$tmp/vendor.yml" "$dir/vendor.json" \
  "$tmp/documentation.yml" "$dir/documentation.json"
cp "$tmp/LICENSE" "$dir/LICENSE"
echo "$tag" > "$dir/VERSION"
echo "Linguist $tag written to $dir"
