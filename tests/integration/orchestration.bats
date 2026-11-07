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
    export HELM_INSTALL_RETRY_DELAY=0
    # Healthy scraper by default so monitoring flows pass verify quickly; tests override as needed.
    export SIMULATE_SCRAPER_HEALTHY=1 VERIFY_SCRAPER_TIMEOUT=3 VERIFY_SCRAPER_INTERVAL=1

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

@test "helm install retries on transient failure then succeeds" {
    export SIMULATE_HELM_TRANSIENT_FAILURE=1
    export HELM_INSTALL_RETRY_DELAY=0
    rm -f "${HELM_CALLS_LOG}.failcount"
    run_monitoring_only
    [ "$status" -eq 0 ]
    [ "$(grep -c 'upgrade --install last9-k8s-monitoring' "$HELM_CALLS_LOG")" -eq 2 ]
    [[ "$output" == *"retrying"* ]]
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

# ---------------------------------------------------------------------------
# setup_helm_repos retry / fail-fast (PR #36)
# ---------------------------------------------------------------------------

@test "helm repo failure retries 3 times then exits before chart install" {
    export SIMULATE_HELM_REPO_FAILURE=1
    run_monitoring_only
    [ "$status" -ne 0 ]
    [[ "$output" == *"Failed to add/update Helm repositories"* ]]
    [ "$(echo "$output" | grep -c 'retrying')" -eq 2 ]
    ! echo "$output" | grep -q 'attempt 3/3), retrying'
    # Each failed attempt stops at the first repo add in the && chain.
    [ "$(grep -c '^repo add open-telemetry' "$HELM_CALLS_LOG")" -eq 3 ]
    ! grep -q "upgrade --install" "$HELM_CALLS_LOG"
}

# ---------------------------------------------------------------------------
# Custom values migration (pre-0.156 collector config keys)
# ---------------------------------------------------------------------------

@test "install_collector with legacy custom values migrates keys before helm" {
    cat > legacy-values.yaml <<'YAML'
config:
  exporters:
    otlp/last9:
      endpoint: "https://example"
  processors:
    k8sattributes:
      {}
  receivers:
    k8sobjects/topology:
      auth_type: serviceAccount
  service:
    pipelines:
      logs:
        processors:
          - k8sattributes
        exporters:
          - otlp/last9
YAML
    run bash "$SCRIPT" function=install_collector token=tok endpoint=https://example.com values=legacy-values.yaml
    [ "$status" -eq 0 ]
    [[ "$output" == *"deprecated collector config keys"* ]]
    grep -q 'otlp_grpc/last9' legacy-values.yaml
    ! grep -qE '^[[:space:]]*otlp/last9:|^[[:space:]]*- otlp/last9$|^[[:space:]]*k8sattributes:|^[[:space:]]*- k8sattributes$|^[[:space:]]*k8sobjects(/topology)?:|^[[:space:]]*- k8sobjects$' legacy-values.yaml
    grep -q 'upgrade --install last9-opentelemetry-collector' "$HELM_CALLS_LOG"
}

@test "install_collector upgrade calls out existing release before helm" {
    export SIMULATE_EXISTING_COLLECTOR_RELEASE=1
    cat > legacy-values.yaml <<'YAML'
config:
  exporters:
    otlp/last9:
      endpoint: "https://example"
  service:
    pipelines:
      logs:
        exporters:
          - otlp/last9
YAML
    run bash "$SCRIPT" function=install_collector token=tok endpoint=https://example.com values=legacy-values.yaml
    [ "$status" -eq 0 ]
    [[ "$output" == *"Upgrade detected"* ]]
    [[ "$output" == *"0.126.0"* ]]
    grep -q 'upgrade --install last9-opentelemetry-collector' "$HELM_CALLS_LOG"
}

# ---------------------------------------------------------------------------
# Uninstall instrumentation scoping (PR #37)
# ---------------------------------------------------------------------------

@test "uninstall deletes only l9-instrumentation, not instrumentations --all" {
  run bash -c "printf 'y\nn\nn\nn\n' | bash '$SCRIPT' uninstall"
  [ "$status" -eq 0 ]
  grep -q "delete instrumentation l9-instrumentation" "$KUBECTL_CALLS_LOG"
  ! grep -q "delete instrumentations --all" "$KUBECTL_CALLS_LOG"
}

# ---------------------------------------------------------------------------
# OTel metrics scraper (target allocator + collector)
# ---------------------------------------------------------------------------

run_scraper() {
    run bash "$SCRIPT" function=install_metrics_scraper \
        token=tok endpoint=https://example.com \
        monitoring-endpoint="https://mock.last9.io/write" \
        cluster=test-cluster \
        "$@"
}

@test "install_metrics_scraper installs target allocator before collector" {
    run_scraper
    [ "$status" -eq 0 ]
    ta=$(grep -n "upgrade --install last9-target-allocator open-telemetry/opentelemetry-target-allocator --version 0.156.0 -n last9" "$HELM_CALLS_LOG" | cut -d: -f1)
    col=$(grep -n "upgrade --install last9-otel-metrics open-telemetry/opentelemetry-collector --version 0.165.0 -n last9" "$HELM_CALLS_LOG" | cut -d: -f1)
    [ -n "$ta" ] && [ -n "$col" ] && [ "$ta" -lt "$col" ]
}

@test "install_metrics_scraper fills placeholders" {
    run_scraper
    [ "$status" -eq 0 ]
    v="${HELM_CALLS_LOG}.values.last9-otel-metrics"
    grep -q 'endpoint: "https://mock.last9.io/write"' "$v"
    grep -q 'cluster: "test-cluster"' "$v"
    ! grep -q '{{' "$v"
}

@test "install_metrics_scraper fails when helm fails" {
    export SIMULATE_HELM_FAILURE=1
    run_scraper
    [ "$status" -ne 0 ]
}

@test "app-metrics-keep survives special characters" {
    run_scraper 'app-metrics-keep=foo_.*|bar\.baz/x&y'
    [ "$status" -eq 0 ]
    # backslash is doubled: OTTL string literals reject a bare \. (verified against collector 0.156.0)
    grep -qF '|foo_.*|bar\\.baz/x&y)$' "${HELM_CALLS_LOG}.values.last9-otel-metrics"
}

@test "app-metrics-keep escapes double quotes and single quotes" {
    run_scraper "app-metrics-keep=a\"b'c"
    [ "$status" -eq 0 ]
    grep -qF "|a\\\"b''c)\$" "${HELM_CALLS_LOG}.values.last9-otel-metrics"
}

@test "tolerations-file applies to scraper releases" {
    run_scraper tolerations-file="$REPO_ROOT/examples/tolerations-all-nodes.yaml"
    [ "$status" -eq 0 ]
    grep "upgrade --install last9-target-allocator" "$HELM_CALLS_LOG" | grep -q 'tolerations\[0\].key=node-role.kubernetes.io/control-plane'
    grep "upgrade --install last9-otel-metrics" "$HELM_CALLS_LOG" | grep -q 'tolerations\[0\].key=node-role.kubernetes.io/control-plane'
}

@test "no tolerations-file means no toleration flags on scraper releases" {
    run_scraper
    [ "$status" -eq 0 ]
    ! grep -q 'tolerations' "$HELM_CALLS_LOG"
}

@test "uninstall-all removes scraper releases" {
    run bash -c "printf 'yyyyyyyy' | bash '$SCRIPT' uninstall-all"
    grep -q "uninstall last9-otel-metrics" "$HELM_CALLS_LOG"
    grep -q "uninstall last9-target-allocator" "$HELM_CALLS_LOG"
}

@test "verify_metrics_scraper succeeds when targets and export are healthy" {
    export SIMULATE_SCRAPER_HEALTHY=1
    run bash "$SCRIPT" function=verify_metrics_scraper
    [ "$status" -eq 0 ]
    grep -q "services/last9-target-allocator-ta:80/proxy/scrape_configs" "$KUBECTL_CALLS_LOG"
    grep -q "pods/last9-otel-metrics-0:8888/proxy/metrics" "$KUBECTL_CALLS_LOG"
}

@test "verify_metrics_scraper warns and fails on timeout" {
    unset SIMULATE_SCRAPER_HEALTHY
    export VERIFY_SCRAPER_TIMEOUT=1 VERIFY_SCRAPER_INTERVAL=1
    run bash "$SCRIPT" function=verify_metrics_scraper
    [ "$status" -ne 0 ]
    [[ "$output" == *"[WARN]"* ]]
}

@test "verify_metrics_scraper fails when export is failing" {
    export SIMULATE_SCRAPER_HEALTHY=1 SIMULATE_SCRAPER_SEND_FAILED=1
    export VERIFY_SCRAPER_TIMEOUT=1 VERIFY_SCRAPER_INTERVAL=1
    run bash "$SCRIPT" function=verify_metrics_scraper
    [ "$status" -ne 0 ]
}

@test "verify_metrics_scraper passes when failed counter is non-zero but constant" {
    export SIMULATE_SCRAPER_HEALTHY=1 SIMULATE_SCRAPER_FAILED_CONST=1
    export VERIFY_SCRAPER_TIMEOUT=3 VERIFY_SCRAPER_INTERVAL=1
    run bash "$SCRIPT" function=verify_metrics_scraper
    [ "$status" -eq 0 ]
}

@test "verify_metrics_scraper fails when failed counter keeps growing" {
    export SIMULATE_SCRAPER_HEALTHY=1 SIMULATE_SCRAPER_SEND_FAILED=1
    export VERIFY_SCRAPER_TIMEOUT=3 VERIFY_SCRAPER_INTERVAL=1
    run bash "$SCRIPT" function=verify_metrics_scraper
    [ "$status" -ne 0 ]
    [[ "$output" == *"[WARN]"* ]]
}

@test "install_metrics_scraper returns 1 with a warning when monitoring endpoint is empty" {
    run bash "$SCRIPT" function=install_metrics_scraper \
        token=tok endpoint=https://example.com cluster=test-cluster
    [ "$status" -ne 0 ]
    [[ "$output" == *"[WARN]"* ]]
    ! grep -q "upgrade --install last9-target-allocator" "$HELM_CALLS_LOG"
}

# ---------------------------------------------------------------------------
# setup_last9_monitoring: bundled Prometheus flipped off, scraper ordering
# ---------------------------------------------------------------------------

line_of() { grep -n "$1" "$HELM_CALLS_LOG" | head -1 | cut -d: -f1; }

@test "monitoring always disables bundled prometheus operator" {
    run_monitoring_only
    [ "$status" -eq 0 ]
    grep "upgrade --install last9-k8s-monitoring" "$HELM_CALLS_LOG" | grep -q -- "--set prometheusOperator.enabled=false"
    grep -q '^  enabled: false' <(awk '/^prometheus:/{f=1;next} /^[^ ]/{f=0} f' "$REPO_ROOT/k8s-monitoring-values.yaml")
}

@test "monitoring disables prometheus operator with a detected existing operator too" {
    export SIMULATE_EXISTING_CRDS=1
    run_monitoring_only
    [ "$status" -eq 0 ]
    grep "upgrade --install last9-k8s-monitoring" "$HELM_CALLS_LOG" | grep -q -- "--set prometheusOperator.enabled=false"
}

@test "migration (existing release) installs scraper before flipping monitoring" {
    export SIMULATE_EXISTING_MONITORING_RELEASE=1 SIMULATE_SCRAPER_HEALTHY=1
    export VERIFY_SCRAPER_TIMEOUT=3 VERIFY_SCRAPER_INTERVAL=1
    run_monitoring_only
    [ "$status" -eq 0 ]
    ta=$(line_of "upgrade --install last9-target-allocator")
    col=$(line_of "upgrade --install last9-otel-metrics")
    kps=$(line_of "upgrade --install last9-k8s-monitoring")
    [ -n "$ta" ] && [ -n "$col" ] && [ -n "$kps" ]
    [ "$ta" -lt "$col" ] && [ "$col" -lt "$kps" ]
}

@test "fresh install (no release) installs monitoring before scraper" {
    export SIMULATE_SCRAPER_HEALTHY=1
    export VERIFY_SCRAPER_TIMEOUT=3 VERIFY_SCRAPER_INTERVAL=1
    run_monitoring_only
    [ "$status" -eq 0 ]
    kps=$(line_of "upgrade --install last9-k8s-monitoring")
    ta=$(line_of "upgrade --install last9-target-allocator")
    col=$(line_of "upgrade --install last9-otel-metrics")
    [ -n "$ta" ] && [ -n "$col" ] && [ -n "$kps" ]
    [ "$kps" -lt "$ta" ] && [ "$ta" -lt "$col" ]
}

@test "fresh install: verify failure exits non-zero with a clear message" {
    unset SIMULATE_SCRAPER_HEALTHY
    export VERIFY_SCRAPER_TIMEOUT=1 VERIFY_SCRAPER_INTERVAL=1
    run_monitoring_only
    [ "$status" -ne 0 ]
    [[ "$output" == *"[ERROR]"* ]]
    [[ "$output" == *"verification failed"* ]]
}

@test "verify failure leaves prometheus running" {
    unset SIMULATE_SCRAPER_HEALTHY
    export SIMULATE_EXISTING_MONITORING_RELEASE=1
    export VERIFY_SCRAPER_TIMEOUT=1 VERIFY_SCRAPER_INTERVAL=1
    run_monitoring_only
    [ "$status" -ne 0 ]
    ! grep -q "upgrade --install last9-k8s-monitoring" "$HELM_CALLS_LOG"
    [[ "$output" == *"still running"* ]]
    [[ "$output" == *"re-run"* ]]
}

@test "re-run after verify failure completes migration" {
    unset SIMULATE_SCRAPER_HEALTHY
    export SIMULATE_EXISTING_MONITORING_RELEASE=1
    export VERIFY_SCRAPER_TIMEOUT=1 VERIFY_SCRAPER_INTERVAL=1
    run_monitoring_only
    [ "$status" -ne 0 ]
    : > "$HELM_CALLS_LOG"; rm -f "$KUBECTL_CALLS_LOG.metrics_polls"
    export SIMULATE_SCRAPER_HEALTHY=1 VERIFY_SCRAPER_TIMEOUT=3
    run_monitoring_only
    [ "$status" -eq 0 ]
    grep -q "upgrade --install last9-k8s-monitoring" "$HELM_CALLS_LOG"
}

@test "full mode includes scraper" {
    export SIMULATE_SCRAPER_HEALTHY=1 VERIFY_SCRAPER_TIMEOUT=3 VERIFY_SCRAPER_INTERVAL=1
    run bash "$SCRIPT" token=tok endpoint=https://example.com \
        monitoring-endpoint="https://mock.last9.io/write" username=u password=p cluster=test-cluster
    grep -q "upgrade --install last9-otel-metrics" "$HELM_CALLS_LOG"
}

@test "logs-only, operator-only, events-only never install scraper" {
    run bash "$SCRIPT" logs-only token=tok endpoint=https://example.com
    run bash "$SCRIPT" operator-only token=tok endpoint=https://example.com
    run bash "$SCRIPT" events-only
    ! grep -q "last9-otel-metrics\|last9-target-allocator" "$HELM_CALLS_LOG"
}

@test "server-name= adds tls server_name_override to the metrics exporter" {
    run_scraper server-name=ingest.example.internal
    [ "$status" -eq 0 ]
    grep -q 'server_name_override: "ingest.example.internal"' "${HELM_CALLS_LOG}.values.last9-otel-metrics"
}

@test "no server-name= means no server_name_override in metrics values" {
    run_scraper
    [ "$status" -eq 0 ]
    ! grep -q 'server_name_override' "${HELM_CALLS_LOG}.values.last9-otel-metrics"
}
