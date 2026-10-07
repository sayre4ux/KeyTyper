#!/bin/sh
# Everything that must pass before a push: tests, a build, and the audit.
# Run by make check and by the pre-push hook (enable with make hooks).
# The build goes to .build/check, so it does not reset Accessibility for your installed copy.
set -eu
cd "$(dirname "$0")/.."
export TYPETHRU_APP=.build/check/TypeThru.app
echo "== Tests"
scripts/test.sh
echo "== Build"
scripts/build.sh
echo "== Audit"
scripts/audit.sh
echo "All checks passed. Safe to push."
