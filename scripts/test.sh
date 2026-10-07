#!/bin/sh
# Exercise actual event construction without posting any input or reading the clipboard.
set -eu
cd "$(dirname "$0")/.."
# DECISION: a reused folder under .build (git-ignored) instead of a temp folder removed with rm -rf;
# it also keeps the module cache, so later runs are faster.
TEST_DIR="$PWD/.build/tests"
export TEST_DIR
mkdir -p "$TEST_DIR"
for file in Sources/*.swift; do [ "$file" = Sources/main.swift ] || cat "$file"; done > "$TEST_DIR/main.swift"
sed '/^\/\/ MARK: - Entry point/,$d' Sources/main.swift >> "$TEST_DIR/main.swift"
echo 'enum ResourceHashes { static let sha256: [String: String] = [:] }' >> "$TEST_DIR/main.swift"
cat Tests/Tests.swift >> "$TEST_DIR/main.swift"
clang++ -std=c++23 -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all \
    -I helper Tests/fuzz-protocol.cpp -o "$TEST_DIR/fuzz-protocol"
"$TEST_DIR/fuzz-protocol"
swiftc -module-cache-path "$TEST_DIR/module-cache" "$TEST_DIR/main.swift" -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
