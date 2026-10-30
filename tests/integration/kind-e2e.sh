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
#   full-install     Default customer path: operator + collector + monitoring + events
#   crd-conflict     Pre-seed Terraform-owned Prometheus CRDs, then monitoring-only
#   operator-crd-conflict  Pre-seed foreign-owned OTel CRDs, then operator-only
#   context          monitoring-only pinned to an explicit kubectl context
#   existing-operator  Pre-install a customer kube-prometheus-stack (older operator +
#                    Prometheus server), then monitoring-only; both must stay healthy
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

# Fixture Helm release seeded by test_existing_operator ("<release> <namespace>
# <created-namespace:0|1>"). On a shared cluster it must be removed on exit,
# success or failure, or it lingers and the next run hits "release exists".
FIXTURE_RELEASE=""

cleanup_fixture_release() {
    [ -z "$FIXTURE_RELEASE" ] && return 0
    local release ns created_ns
    read -r release ns created_ns <<< "$FIXTURE_RELEASE"
    info "Uninstalling fixture release '$release' from '$ns'"
    helm uninstall "$release" -n "$ns" --wait >/dev/null 2>&1 \
        || warn "could not uninstall fixture release '$release' in '$ns'"
    [ "$created_ns" = "1" ] && kubectl delete namespace "$ns" --ignore-not-found >/dev/null 2>&1
    FIXTURE_RELEASE=""
}

cleanup_cluster() {
    # Never delete a user-provided existing cluster; only remove what we seeded
    if [ -n "$EXISTING_CONTEXT" ]; then
        cleanup_fixture_release
        return 0
    fi
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
    run_setup events-only token="$DUMMY_TOKEN" endpoint="$DUMMY_OTLP" env=production
    assert_pods_ready "app.kubernetes.io/name=last9-kube-events-agent"
    local cm
    cm=$(kubectl get configmap -n "$NAMESPACE" -l app.kubernetes.io/instance=last9-kube-events-agent -o name 2>/dev/null | head -1)
    [ -n "$cm" ] || fail "events agent configmap not found"
    kubectl get "$cm" -n "$NAMESPACE" -o yaml | grep -q 'deployment.environment.*production' \
        || fail "events agent config missing deployment.environment=production"
    info "✓ events-only passed"
}

# README "Install Everything" path — one cluster, all components together (not the
# partial *-only modes). Matches the default branch of last9-otel-setup.sh when
# no mode flag is passed.
test_full_install() {
    create_cluster "${CLUSTER_PREFIX}-full"
    run_setup token="$DUMMY_TOKEN" endpoint="$DUMMY_OTLP" \
        monitoring-endpoint="$DUMMY_METRICS" username="$DUMMY_USER" password="$DUMMY_PASS"
    assert_rollout deployment opentelemetry-operator
    assert_pods_ready "app.kubernetes.io/name=last9-otel-collector"
    assert_resource_exists instrumentation l9-instrumentation
    assert_resource_exists prometheusagent last9-k8s-monitoring-kube-prometheus
    assert_rollout deployment last9-k8s-monitoring-kube-state-metrics
    assert_pods_ready "app.kubernetes.io/name=last9-kube-events-agent"
    info "✓ full-install passed"
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

# Reproduce the customer failure on the OTel operator path: OTel CRDs already on
# the cluster, owned by a non-Helm field manager (cert-manager-cainjector, which
# in a live cluster owns .spec.conversion.webhook.clientConfig.caBundle). The
# opentelemetry-operator chart ships CRDs as templates gated by crds.create (NOT
# the chart's crds/ dir), so the script must render them with
# `helm template --include-crds`, force-apply them out-of-band, and install with
# crds.create=false so Helm never re-applies — and never conflicts on — them.
#
# Note: this is a PATH-ASSERTION test, not a live-race test. With no running
# cainjector re-asserting ownership, adopt_otel_crds would itself resolve a
# static conflict — so the guard here is that the crds.create=false mitigation
# path is taken (catches removal of the fix), not that an active-controller race
# is won. The live race only manifests with real cert-manager + Helm v4; that is
# verified by a manual repro (cert-manager + seed operator -> cainjector owns
# caBundle -> the unpatched script reproduces the exact customer conflict and the
# patched script installs cleanly).
test_operator_crd_conflict() {
    create_cluster "${CLUSTER_PREFIX}-operator-crdconflict"

    info "Pre-seeding OTel CRDs as field-manager cert-manager-cainjector"
    # Pin to the operator tag matching the chart the script installs, so the
    # seeded CRD schema is the one the mitigation upgrades from — not a moving
    # `main` that can drift. Chart OPERATOR_VERSION=0.92.1 (last9-otel-setup.sh)
    # has appVersion 0.129.1, i.e. operator tag v0.129.1. Bump both together.
    local crd_base="https://raw.githubusercontent.com/open-telemetry/opentelemetry-operator/v0.129.1/config/crd/bases"
    for crd in \
        opentelemetry.io_opentelemetrycollectors \
        opentelemetry.io_instrumentations \
        opentelemetry.io_opampbridges; do
        kubectl apply --server-side --field-manager=cert-manager-cainjector \
            -f "${crd_base}/${crd}.yaml" \
            || warn "could not pre-seed $crd (continuing)"
    done

    local out
    out=$(run_setup operator-only token="$DUMMY_TOKEN" endpoint="$DUMMY_OTLP" 2>&1) \
        || { echo "$out"; fail "operator-only failed with pre-existing CRDs"; }

    echo "$out" | grep -q -- "crds.create=false\|Pre-existing OpenTelemetry CRDs detected" \
        || fail "script did not take the crds.create=false path with pre-existing OTel CRDs"
    assert_rollout deployment opentelemetry-operator
    info "✓ operator-crd-conflict passed"
}

# Reproduce the Loco failure: a customer kube-prometheus-stack (operator v0.81.0,
# chart 70.4.2) already runs a Prometheus server in its own namespace. Installing
# a second cluster-wide operator makes both reconcile every Prometheus/
# PrometheusAgent, flip-flopping config-reloader image tags so neither pod stays
# up. The script must detect the existing operator by image, skip its own, and
# leave the customer's Prometheus untouched.
test_existing_operator() {
    create_cluster "${CLUSTER_PREFIX}-existing-operator"

    info "Installing customer kube-prometheus-stack 70.4.2 (operator v0.81.0) into 'prometheus'"
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
    helm repo update prometheus-community >/dev/null
    # Only arm the destructive EXIT cleanup once both lookups have CONFIRMED the
    # release (and, for deletion, the namespace) are absent. A failed lookup is
    # not absence: fail closed rather than risk uninstalling someone else's stack.
    local existing ns_lookup created_ns
    existing=$(helm list -n prometheus --filter '^prom$' -q 2>/dev/null) \
        || fail "could not check for an existing 'prom' release; refusing to continue"
    [ -n "$existing" ] && fail "release 'prom' already exists in namespace 'prometheus'; refusing to touch it"
    ns_lookup=$(kubectl get namespace prometheus --ignore-not-found -o name 2>/dev/null) \
        || fail "could not check for namespace 'prometheus'; refusing to continue"
    created_ns=1
    [ -n "$ns_lookup" ] && created_ns=0
    FIXTURE_RELEASE="prom prometheus $created_ns"
    local install_out
    if ! install_out=$(helm install prom prometheus-community/kube-prometheus-stack --version 70.4.2 \
        -n prometheus --create-namespace --wait --timeout 10m \
        --set alertmanager.enabled=false --set grafana.enabled=false \
        --set prometheus-node-exporter.enabled=false --set kubeStateMetrics.enabled=false 2>&1); then
        echo "$install_out"
        # The name was taken between our lookup and install: it isn't ours, so disarm cleanup.
        if echo "$install_out" | grep -q "cannot re-use a name"; then
            FIXTURE_RELEASE=""
        fi
        fail "could not install customer kube-prometheus-stack"
    fi
    kubectl rollout status statefulset/prometheus-prom-kube-prometheus-stack-prometheus \
        -n prometheus --timeout="$WAIT_TIMEOUT" || fail "customer Prometheus not ready before install"

    local out
    out=$(run_setup monitoring-only \
        monitoring-endpoint="$DUMMY_METRICS" username="$DUMMY_USER" password="$DUMMY_PASS" 2>&1) \
        || { echo "$out"; fail "monitoring-only failed with an existing operator"; }

    echo "$out" | grep -q "Existing Prometheus Operator found" \
        || { echo "$out"; fail "script did not detect the customer's kube-prometheus-stack operator"; }
    if kubectl get deployment -n "$NAMESPACE" -o jsonpath='{.items[*].spec.template.spec.containers[*].image}' \
        | grep -q "prometheus-operator/prometheus-operator"; then
        fail "a second Prometheus Operator was installed in $NAMESPACE"
    fi

    assert_rollout statefulset prom-agent-last9-k8s-monitoring-kube-prometheus

    # A fight shows up as repeated StatefulSet template rewrites: watch both
    # StatefulSets' generations over several reconcile cycles (~17s each).
    local gen_l9 gen_cust
    gen_l9=$(kubectl get sts prom-agent-last9-k8s-monitoring-kube-prometheus -n "$NAMESPACE" -o jsonpath='{.metadata.generation}')
    gen_cust=$(kubectl get sts prometheus-prom-kube-prometheus-stack-prometheus -n prometheus -o jsonpath='{.metadata.generation}')
    sleep 90
    [ "$gen_l9" = "$(kubectl get sts prom-agent-last9-k8s-monitoring-kube-prometheus -n "$NAMESPACE" -o jsonpath='{.metadata.generation}')" ] \
        || fail "Last9 PrometheusAgent StatefulSet keeps being rewritten (operator fight)"
    [ "$gen_cust" = "$(kubectl get sts prometheus-prom-kube-prometheus-stack-prometheus -n prometheus -o jsonpath='{.metadata.generation}')" ] \
        || fail "customer Prometheus StatefulSet keeps being rewritten (operator fight)"

    kubectl rollout status statefulset/prometheus-prom-kube-prometheus-stack-prometheus \
        -n prometheus --timeout=60s || fail "customer Prometheus not healthy after install"
    assert_rollout statefulset prom-agent-last9-k8s-monitoring-kube-prometheus
    info "✓ existing-operator passed"
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
        full-install)    test_full_install ;;
        crd-conflict)    test_crd_conflict ;;
        operator-crd-conflict) test_operator_crd_conflict ;;
        context)         test_context ;;
        existing-operator) test_existing_operator ;;
        all)
            test_operator_only;          cleanup_cluster
            test_logs_only;              cleanup_cluster
            test_monitoring_only;        cleanup_cluster
            test_events_only;            cleanup_cluster
            test_full_install;           cleanup_cluster
            test_crd_conflict;           cleanup_cluster
            test_operator_crd_conflict;  cleanup_cluster
            test_existing_operator;      cleanup_cluster
            test_context
            ;;
        *)
            echo "Usage: $0 <operator-only|logs-only|monitoring-only|events-only|full-install|crd-conflict|operator-crd-conflict|context|all>" >&2
            exit 1
            ;;
    esac

    # Leave a shared/existing cluster clean
    [ -n "$EXISTING_CONTEXT" ] && uninstall_releases

    info "All requested e2e checks passed ✅"
}

main "$@"
