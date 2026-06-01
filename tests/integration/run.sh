#!/usr/bin/env bash
# Local entrypoint for integration tests.
#
#   tests/integration/run.sh layer1     # fast, no cluster (bats + stubs)
#   tests/integration/run.sh layer2 all # kind cluster, all modes
#   tests/integration/run.sh layer2 monitoring-only
#   tests/integration/run.sh coverage   # static test-coverage estimate
#
# CI calls the same script so local and CI behaviour stay identical.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

case "${1:-layer1}" in
    layer1)
        command -v bats >/dev/null 2>&1 || {
            echo "bats not installed. macOS: brew install bats-core" >&2
            exit 1
        }
        bats "$HERE/orchestration.bats"
        ;;
    layer2)
        shift
        "$HERE/kind-e2e.sh" "${1:-all}"
        ;;
    coverage)
        # Static test-coverage estimate for last9-otel-setup.sh. Runtime line
        # coverage (kcov) does not work here — its bash instrumentation is
        # Linux-only and does not reach the grandchild `bash "$SCRIPT"` the tests
        # spawn — so we estimate statically from the function call graph.
        command -v python3 >/dev/null 2>&1 || {
            echo "python3 not installed." >&2
            exit 1
        }
        shift || true
        python3 "$REPO_ROOT/tests/coverage-report.py" "$@"
        ;;
    *)
        echo "Usage: $0 <layer1|layer2|coverage> [mode]" >&2
        exit 1
        ;;
esac
