#!/usr/bin/env bash
# Compile demorec (top-level code needs the file to be called main.swift).
set -euo pipefail
cd "$(dirname "$0")"; mkdir -p bin
tmp=$(mktemp -d); cp demorec.swift "$tmp/main.swift"
swiftc -O -suppress-warnings "$tmp/main.swift" -o bin/demorec; rm -r "$tmp"
