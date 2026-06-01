#!/usr/bin/env bash
# Layer 2 integration tests — real helm/kubectl against an ephemeral kind cluster.
#
# Exercises each install mode end-to-end, asserting that releases install and
# pods reach Ready. Endpoints are dummies (data delivery is out of scope — that
# is Layer 3 / real-cluster smoke); we verify orchestration and scheduling.
#
# Runnable locally AND in CI — CI installs the deps then calls this same script.
#
# Usage:
#   tests/integration/kind-e2e.sh <mode>
#
# Modes:
#   operator-only    OTel Operator + collector (traces)
#   logs-only        Collector for logs
#   monitoring-only  kube-prometheus-stack (metrics)
#   events-only      Kubernetes events agent
#   crd-conflict     Pre-seed Terraform-owned Prometheus CRDs, then monitoring-only
#   context          monitoring-only pinned to an explicit kubectl context
#   all              Run every mode above, each in its own cluster
#
# Env:
#   KEEP_CLUSTER=1   Do not delete the kind cluster on exit (debugging)
#   CLUSTER_PREFIX   kind cluster name prefix (default: l9-e2e)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/last9-otel-setup.sh"
CLUSTER_PREFIX="${CLUSTER_PREFIX:-l9-e2e}"
NAMESPACE="last9"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300s}"
POD_APPEAR_TRIES="${POD_APPEAR_TRIES:-90}"   # x2s = up to 3min for pod to be created

# Dummy credentials — pods come up; remote-write failing is expected and fine.
DUMMY_TOKEN="Basic dGVzdDp0ZXN0"
DUMMY_OTLP="http://localhost:4318"
DUMMY_METRICS="http://localhost:9090/write"
DUMMY_USER="testuser"
DUMMY_PASS="testpass"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[E2E]${NC} $1"; }
warn()  { echo -e "${YELLOW}[E2E]${NC} $1"; }
fail()  { echo -e "${RED}[E2E FAIL]${NC} $1"; exit 1; }

# When EXISTING_CONTEXT is set, run against that already-running cluster
# (minikube, an existing kind cluster, etc.) instead of creating ephemeral
# ones. The script then never creates or deletes clusters — it only installs,
# asserts, and (best-effort) uninstalls the release it created.
EXISTING_CONTEXT="${EXISTING_CONTEXT:-}"

CURRENT_CLUSTER=""

cleanup_cluster() {
    # Never delete a user-provided existing cluster
    [ -n "$EXISTING_CONTEXT" ] && return 0
    [ -z "$CURRENT_CLUSTER" ] && return 0
    if [ "${KEEP_CLUSTER:-0}" = "1" ]; then
        warn "KEEP_CLUSTER=1 — leaving cluster '$CURRENT_CLUSTER' running"
        return 0
    fi
    info "Deleting kind cluster '$CURRENT_CLUSTER'"
    kind delete cluster --name "$CURRENT_CLUSTER" >/dev/null 2>&1 || true
}
trap cleanup_cluster EXIT

require_tools() {
    # kind only required when we create clusters ourselves
    local tools=(kubectl helm)
    [ -z "$EXISTING_CONTEXT" ] && tools+=(kind)
    for t in "${tools[@]}"; do
        command -v "$t" >/dev/null 2>&1 || fail "$t is required but not installed"
    done
}

create_cluster() {
    local name="$1"
    if [ -n "$EXISTING_CONTEXT" ]; then
        info "Using existing cluster via context '$EXISTING_CONTEXT'"
        kubectl config use-context "$EXISTING_CONTEXT" >/dev/null \
            || fail "context '$EXISTING_CONTEXT' not found"
        return 0
    fi
    CURRENT_CLUSTER="$name"
    info "Creating kind cluster '$name'"
    kind delete cluster --name "$name" >/dev/null 2>&1 || true
    kind create cluster --name "$name" --wait 120s
    # kind sets context to kind-<name>
    kubectl config use-context "kind-$name" >/dev/null
}

# Run the setup script against the local checkout (repo= points at this repo so
# the branch's code is what gets installed, not GitHub main).
run_setup() {
    info "Running: last9-otel-setup.sh $*"
    bash "$SCRIPT" "$@" repo="$REPO_ROOT"
}

assert_rollout() {
    local kind="$1" name="$2"
    info "Waiting for $kind/$name to be available"
    kubectl rollout status "$kind/$name" -n "$NAMESPACE" --timeout="$WAIT_TIMEOUT" \
        || fail "$kind/$name did not become ready"
}

assert_pods_ready() {
    local selector="$1"
    # kubectl wait errors with "no matching resources found" if it fires before
    # the workload has created any pods. Poll until at least one pod exists, then
    # wait for readiness (covers slow image pulls on kind).
    info "Waiting for pods ($selector) to be created"
    local tries=0
    until [ -n "$(kubectl get pod -l "$selector" -n "$NAMESPACE" \
                   -o name 2>/dev/null)" ]; do
        tries=$((tries + 1))
        [ "$tries" -ge "$POD_APPEAR_TRIES" ] && fail "no pods matched ($selector)"
        sleep 2
    done
    info "Waiting for pods ($selector) to be Ready"
    kubectl wait --for=condition=ready pod -l "$selector" -n "$NAMESPACE" \
        --timeout="$WAIT_TIMEOUT" || fail "pods ($selector) not ready"
}

assert_resource_exists() {
    local kind="$1" name="$2"
    kubectl get "$kind" "$name" -n "$NAMESPACE" >/dev/null 2>&1 \
        || fail "expected $kind/$name to exist"
    info "✓ $kind/$name exists"
}

# ---------------------------------------------------------------------------
# Per-mode test bodies
# ---------------------------------------------------------------------------

test_operator_only() {
    create_cluster "${CLUSTER_PREFIX}-operator"
    run_setup operator-only token="$DUMMY_TOKEN" endpoint="$DUMMY_OTLP"
    assert_rollout deployment opentelemetry-operator
    info "✓ operator-only passed"
}

test_logs_only() {
    create_cluster "${CLUSTER_PREFIX}-logs"
    run_setup logs-only token="$DUMMY_TOKEN" endpoint="$DUMMY_OTLP"
    assert_pods_ready "app.kubernetes.io/name=last9-otel-collector"
    info "✓ logs-only passed"
}

test_monitoring_only() {
    create_cluster "${CLUSTER_PREFIX}-monitoring"
    run_setup monitoring-only \
        monitoring-endpoint="$DUMMY_METRICS" username="$DUMMY_USER" password="$DUMMY_PASS"
    assert_resource_exists prometheusagent last9-k8s-monitoring-kube-prometheus
    assert_rollout deployment last9-k8s-monitoring-kube-state-metrics
    info "✓ monitoring-only passed"
}

test_events_only() {
    create_cluster "${CLUSTER_PREFIX}-events"
    run_setup events-only token="$DUMMY_TOKEN" endpoint="$DUMMY_OTLP"
    assert_pods_ready "app.kubernetes.io/name=last9-kube-events-agent"
    info "✓ events-only passed"
}

# Reproduce the customer failure: Prometheus CRDs already on the cluster, owned
# by a non-Helm field manager (terraform-provider-helm). The script must detect
# them, pass --skip-crds, and still install successfully.
test_crd_conflict() {
    create_cluster "${CLUSTER_PREFIX}-crdconflict"

    info "Pre-seeding Prometheus CRDs as field-manager terraform-provider-helm"
    local crd_base="https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds"
    for crd in crd-alertmanagerconfigs crd-prometheuses crd-servicemonitors; do
        kubectl apply --server-side --field-manager=terraform-provider-helm \
            -f "${crd_base}/${crd}.yaml" \
            || warn "could not pre-seed $crd (continuing)"
    done

    local out
    out=$(run_setup monitoring-only \
        monitoring-endpoint="$DUMMY_METRICS" username="$DUMMY_USER" password="$DUMMY_PASS" 2>&1) \
        || { echo "$out"; fail "monitoring-only failed with pre-existing CRDs"; }

    echo "$out" | grep -q -- "--skip-crds\|Pre-existing Prometheus CRDs detected" \
        || fail "script did not take the --skip-crds path with pre-existing CRDs"
    assert_resource_exists prometheusagent last9-k8s-monitoring-kube-prometheus
    info "✓ crd-conflict passed"
}

test_context() {
    create_cluster "${CLUSTER_PREFIX}-context"
    # Use the existing context when provided, else the kind-<name> context
    local ctx="${EXISTING_CONTEXT:-kind-${CLUSTER_PREFIX}-context}"
    kubectl config use-context "$ctx" >/dev/null
    run_setup monitoring-only context="$ctx" \
        monitoring-endpoint="$DUMMY_METRICS" username="$DUMMY_USER" password="$DUMMY_PASS"
    assert_resource_exists prometheusagent last9-k8s-monitoring-kube-prometheus
    info "✓ context passed"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

# Best-effort uninstall of everything the script installed. Only used when
# running against an existing/shared cluster, to leave it as we found it.
uninstall_releases() {
    info "Uninstalling Last9 releases from $NAMESPACE"
    bash "$SCRIPT" uninstall-all >/dev/null 2>&1 || true
}

main() {
    require_tools
    local mode="${1:-}"

    # On an existing cluster the modes collide (several install last9-k8s-monitoring)
    # and there is no ephemeral teardown between them, so 'all' is disallowed.
    if [ -n "$EXISTING_CONTEXT" ] && [ "$mode" = "all" ]; then
        fail "'all' is not supported with EXISTING_CONTEXT — run one mode at a time"
    fi

    case "$mode" in
        operator-only)   test_operator_only ;;
        logs-only)       test_logs_only ;;
        monitoring-only) test_monitoring_only ;;
        events-only)     test_events_only ;;
        crd-conflict)    test_crd_conflict ;;
        context)         test_context ;;
        all)
            test_operator_only;   cleanup_cluster
            test_logs_only;       cleanup_cluster
            test_monitoring_only; cleanup_cluster
            test_events_only;     cleanup_cluster
            test_crd_conflict;    cleanup_cluster
            test_context
            ;;
        *)
            echo "Usage: $0 <operator-only|logs-only|monitoring-only|events-only|crd-conflict|context|all>" >&2
            exit 1
            ;;
    esac

    # Leave a shared/existing cluster clean
    [ -n "$EXISTING_CONTEXT" ] && uninstall_releases

    info "All requested e2e checks passed ✅"
}

main "$@"
