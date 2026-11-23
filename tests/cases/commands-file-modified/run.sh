#!/usr/bin/env bash
set -euo pipefail

CASE=commands-file-modified
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# Run this test case in a temporary directory.
WORK="$(mktemp -d)"
cp -R "$ROOT/tests/cases/$CASE/." "$WORK/"
cd "$WORK"
printf 'Case files: %s\n' "$WORK"

# Ensure the input command file has no newline at the end.
perl -pi -e 'chomp if eof' commands.txt
# Compare the exact input bytes before and after running Demorunner.
cp commands.txt original-commands.txt
DEMO_DELAY=0 bash "$ROOT/demorunner.sh" commands.txt
if cmp -s commands.txt original-commands.txt; then
  printf 'unchanged\n' > actual-output.txt
else
  printf 'modified\n' > actual-output.txt
fi
diff -u expected-output.txt actual-output.txt
