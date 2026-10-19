#!/bin/sh
set -eu
project=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
testdir=$(mktemp -d)
trap 'rm -rf "$testdir"' EXIT
xcrun swiftc "$project/Sources/Core.swift" "$project/Helper/Writer.swift" "$project/Tests/main.swift" -o "$testdir/check"
"$testdir/check" "$@"
