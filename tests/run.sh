#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
"$PROJECT_ROOT/tests/test.sh"
for test in "$PROJECT_ROOT"/tests/test-*.sh; do
    "$test"
done
