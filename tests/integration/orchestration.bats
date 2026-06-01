#!/usr/bin/env bats
# Layer 1 integration tests — command orchestration.
#
# Runs the real last9-otel-setup.sh end-to-end with kubectl/helm/git replaced
# by recording stubs (tests/integration/stubs). No cluster required. Asserts
# that the script calls helm/kubectl with the right flags and release names,
# and exits correctly on failure.
#
# Run: bats tests/integration/orchestration.bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    STUBS="$BATS_TEST_DIRNAME/stubs"
    SCRIPT="$REPO_ROOT/last9-otel-setup.sh"

    export PATH="$STUBS:$PATH"
    export REPO_SRC="$REPO_ROOT"

    # Per-test call logs
    export KUBECTL_CALLS_LOG="$BATS_TEST_TMPDIR/kubectl.log"
    export HELM_CALLS_LOG="$BATS_TEST_TMPDIR/helm.log"
    : > "$KUBECTL_CALLS_LOG"
    : > "$HELM_CALLS_LOG"

    # Run each invocation from an isolated working dir so WORK_DIR cleanup is safe
    cd "$BATS_TEST_TMPDIR"
}

run_monitoring_only() {
    run bash "$SCRIPT" monitoring-only \
        monitoring-endpoint="https://mock.last9.io/write" \
        username="testuser" \
        password="testpass" \
        "$@"
}

# ---------------------------------------------------------------------------
# CRD-conflict handling
# ---------------------------------------------------------------------------

@test "monitoring-only with pre-existing CRDs passes --skip-crds to helm" {
    export SIMULATE_EXISTING_CRDS=1
    run_monitoring_only
    [ "$status" -eq 0 ]
    grep -q -- "--skip-crds" "$HELM_CALLS_LOG"
}

@test "monitoring-only on clean cluster does NOT pass --skip-crds" {
    export SIMULATE_EXISTING_CRDS=0
    run_monitoring_only
    [ "$status" -eq 0 ]
    ! grep -q -- "--skip-crds" "$HELM_CALLS_LOG"
}

# ---------------------------------------------------------------------------
# Helm failure must fail the script (no false success)
# ---------------------------------------------------------------------------

@test "helm install failure makes the script exit non-zero" {
    export SIMULATE_HELM_FAILURE=1
    run_monitoring_only
    [ "$status" -ne 0 ]
}

@test "helm install failure suppresses the success message" {
    export SIMULATE_HELM_FAILURE=1
    run_monitoring_only
    [[ "$output" != *"deployed successfully"* ]]
}

@test "helm install failure prints an error line" {
    export SIMULATE_HELM_FAILURE=1
    run_monitoring_only
    [[ "$output" == *"[ERROR]"* ]]
    [[ "$output" == *"Helm install/upgrade failed"* ]]
}

# ---------------------------------------------------------------------------
# Correct release name and chart
# ---------------------------------------------------------------------------

@test "monitoring-only installs the last9-k8s-monitoring release" {
    run_monitoring_only
    [ "$status" -eq 0 ]
    grep -q "upgrade --install last9-k8s-monitoring" "$HELM_CALLS_LOG"
}

@test "monitoring-only uses the kube-prometheus-stack chart" {
    run_monitoring_only
    [ "$status" -eq 0 ]
    grep -q "prometheus-community/kube-prometheus-stack" "$HELM_CALLS_LOG"
}

@test "monitoring-only installs into the last9 namespace" {
    run_monitoring_only
    [ "$status" -eq 0 ]
    grep -q -- "-n last9" "$HELM_CALLS_LOG"
}

# ---------------------------------------------------------------------------
# context= argument injection
# ---------------------------------------------------------------------------

@test "context= injects --kube-context into every helm call" {
    run_monitoring_only context="prod-cluster"
    [ "$status" -eq 0 ]
    # Every recorded helm call must carry the context flag
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        [[ "$line" == "--kube-context prod-cluster"* ]] || {
            echo "helm call missing context: $line"
            return 1
        }
    done < "$HELM_CALLS_LOG"
}

@test "context= injects --context into every kubectl call after validation" {
    run_monitoring_only context="prod-cluster"
    [ "$status" -eq 0 ]
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # The context-validation call runs before the wrapper is installed and
        # legitimately has no --context flag; skip it.
        [[ "$line" == "config get-contexts "* ]] && continue
        [[ "$line" == "--context prod-cluster"* ]] || {
            echo "kubectl call missing context: $line"
            return 1
        }
    done < "$KUBECTL_CALLS_LOG"
}

@test "no context= means no --kube-context flag" {
    run_monitoring_only
    [ "$status" -eq 0 ]
    ! grep -q -- "--kube-context" "$HELM_CALLS_LOG"
}
