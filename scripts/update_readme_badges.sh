#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README_FILE="$REPO_ROOT/README.md"
PACKAGE_JSON="$REPO_ROOT/package.json"

if [[ ! -f "$README_FILE" ]]; then
    echo "Error: README not found at $README_FILE" >&2
    exit 1
fi

if [[ ! -f "$PACKAGE_JSON" ]]; then
    echo "Error: package.json not found at $PACKAGE_JSON" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required to read package.json" >&2
    exit 1
fi

if ! command -v rg >/dev/null 2>&1; then
    echo "Error: rg is required to count tests" >&2
    exit 1
fi

version="$(jq -r '.version' "$PACKAGE_JSON")"
if [[ -z "$version" || "$version" == "null" ]]; then
    echo "Error: could not determine version from package.json" >&2
    exit 1
fi

test_count="$(rg -n '^@test\s+"' "$REPO_ROOT/tests" | wc -l | tr -d '[:space:]')"
if [[ -z "$test_count" ]]; then
    echo "Error: failed to determine test count" >&2
    exit 1
fi

expected_version_line="![Version](https://img.shields.io/badge/version-${version}-blue)"
expected_tests_line="![Tests](https://img.shields.io/badge/tests-${test_count}%20passing-green)"

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

awk -v version_line="$expected_version_line" -v tests_line="$expected_tests_line" '
    {
        if ($0 ~ /^!\[Version\]\(https:\/\/img\.shields\.io\/badge\/version-/) {
            print version_line
        } else if ($0 ~ /^!\[Tests\]\(https:\/\/img\.shields\.io\/badge\/tests-/) {
            print tests_line
        } else {
            print $0
        }
    }
' "$README_FILE" > "$tmp_file"

if cmp -s "$README_FILE" "$tmp_file"; then
    echo "README badges already up to date (version=$version, tests=$test_count)."
    exit 0
fi

if [[ "${1:-}" == "--check" ]]; then
    echo "README badges are out of date." >&2
    echo "Expected:" >&2
    echo "  $expected_version_line" >&2
    echo "  $expected_tests_line" >&2
    exit 1
fi

mv "$tmp_file" "$README_FILE"
trap - EXIT

echo "Updated README badges (version=$version, tests=$test_count)."
