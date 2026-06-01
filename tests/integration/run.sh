#!/usr/bin/env bash
# Local entrypoint for integration tests.
#
#   tests/integration/run.sh layer1     # fast, no cluster (bats + stubs)
#   tests/integration/run.sh layer2 all # kind cluster, all modes
#   tests/integration/run.sh layer2 monitoring-only
#
# CI calls the same script so local and CI behaviour stay identical.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
    *)
        echo "Usage: $0 <layer1|layer2> [mode]" >&2
        exit 1
        ;;
esac
