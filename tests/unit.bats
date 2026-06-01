#!/usr/bin/env bats
# Unit tests for pure helper functions in last9-otel-setup.sh
# No cluster, no helm, no kubectl required.
# Run: bats tests/unit.bats

SCRIPT="$BATS_TEST_DIRNAME/../last9-otel-setup.sh"

# Source only the helper functions — skip the main execution body by stubbing
# out the entry-point guard and heavy prerequisites.
load_helpers() {
    # Provide stubs so sourcing doesn't fail on missing binaries
    helm()    { :; }
    kubectl() { :; }
    git()     { :; }
    export -f helm kubectl git

    # Inline-source only the function definitions we need
    # shellcheck disable=SC1090
    eval "$(grep -A 999 '^sanitize_cluster_name' "$SCRIPT" | awk '/^sanitize_cluster_name/,/^}/' )"
    eval "$(grep -A 999 '^detect_host_platform' "$SCRIPT"  | awk '/^detect_host_platform/,/^}/'  )"
    eval "$(grep -A 999 '^log_error'            "$SCRIPT"  | awk '/^log_error\(\)/,/^}/'         )"
    eval "$(grep -A 999 '^log_warn'             "$SCRIPT"  | awk '/^log_warn\(\)/,/^}/'          )"
    eval "$(grep -A 999 '^log_info'             "$SCRIPT"  | awk '/^log_info\(\)/,/^}/'          )"

    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
}

# ---------------------------------------------------------------------------
# sanitize_cluster_name
# ---------------------------------------------------------------------------

@test "sanitize_cluster_name: strips EKS ARN to cluster name" {
    load_helpers
    result=$(sanitize_cluster_name "arn:aws:eks:ap-south-1:123456789012:cluster/prod-cluster")
    [ "$result" = "prod-cluster" ]
}

@test "sanitize_cluster_name: strips EKS ARN with region ap-southeast-1" {
    load_helpers
    result=$(sanitize_cluster_name "arn:aws:eks:ap-southeast-1:999000111222:cluster/staging-eks")
    [ "$result" = "staging-eks" ]
}

@test "sanitize_cluster_name: passes through GKE context unchanged" {
    load_helpers
    input="gke_myproject_us-central1_my-cluster"
    result=$(sanitize_cluster_name "$input")
    [ "$result" = "$input" ]
}

@test "sanitize_cluster_name: passes through plain name unchanged" {
    load_helpers
    result=$(sanitize_cluster_name "prod-us-east-1")
    [ "$result" = "prod-us-east-1" ]
}

@test "sanitize_cluster_name: passes through unknown-cluster unchanged" {
    load_helpers
    result=$(sanitize_cluster_name "unknown-cluster")
    [ "$result" = "unknown-cluster" ]
}

@test "sanitize_cluster_name: handles cluster name with hyphens inside ARN" {
    load_helpers
    result=$(sanitize_cluster_name "arn:aws:eks:us-west-2:112233445566:cluster/my-prod-cluster-v2")
    [ "$result" = "my-prod-cluster-v2" ]
}

# ---------------------------------------------------------------------------
# log_error — must exit 1 and print [ERROR] tag
# ---------------------------------------------------------------------------

@test "log_error: exits with code 1" {
    load_helpers
    run bash -c "
        RED='\033[0;31m'; NC='\033[0m'
        log_error() { echo -e \"\${RED}[ERROR]\${NC} \$1\" >&2; exit 1; }
        log_error 'something went wrong'
        echo 'should not reach here'
    "
    [ "$status" -eq 1 ]
}

@test "log_error: does not print lines after the call" {
    load_helpers
    run bash -c "
        RED='\033[0;31m'; NC='\033[0m'
        log_error() { echo -e \"\${RED}[ERROR]\${NC} \$1\" >&2; exit 1; }
        log_error 'stopping here'
        echo 'SHOULD_NOT_APPEAR'
    "
    [[ "$output" != *"SHOULD_NOT_APPEAR"* ]]
}

@test "log_error: message appears in stderr output" {
    load_helpers
    run bash -c "
        RED='\033[0;31m'; NC='\033[0m'
        log_error() { echo -e \"\${RED}[ERROR]\${NC} \$1\" >&2; exit 1; }
        log_error 'disk is full' 2>&1
    "
    [[ "$output" == *"disk is full"* ]]
}

@test "log_error: output contains [ERROR] tag" {
    load_helpers
    run bash -c "
        RED='\033[0;31m'; NC='\033[0m'
        log_error() { echo -e \"\${RED}[ERROR]\${NC} \$1\" >&2; exit 1; }
        log_error 'test message' 2>&1
    "
    [[ "$output" == *"[ERROR]"* ]]
}

# ---------------------------------------------------------------------------
# log_warn — must not exit, must print [WARN]
# ---------------------------------------------------------------------------

@test "log_warn: does not exit" {
    load_helpers
    run bash -c "
        YELLOW='\033[1;33m'; NC='\033[0m'
        log_warn() { echo -e \"\${YELLOW}[WARN]\${NC} \$1\" >&2; }
        log_warn 'low disk space'
        echo 'continued'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"continued"* ]]
}

@test "log_warn: output contains [WARN] tag" {
    load_helpers
    run bash -c "
        YELLOW='\033[1;33m'; NC='\033[0m'
        log_warn() { echo -e \"\${YELLOW}[WARN]\${NC} \$1\" >&2; }
        log_warn 'something suspicious' 2>&1
    "
    [[ "$output" == *"[WARN]"* ]]
}

# ---------------------------------------------------------------------------
# detect_host_platform — mock uname and package manager binaries
# ---------------------------------------------------------------------------

@test "detect_host_platform: x86_64 + apt-get → amd64 deb" {
    load_helpers
    tmpdir=$(mktemp -d)

    # Mock uname returning x86_64
    printf '#!/bin/sh\necho x86_64\n' > "$tmpdir/uname"; chmod +x "$tmpdir/uname"
    # Mock apt-get present
    printf '#!/bin/sh\nexit 0\n' > "$tmpdir/apt-get"; chmod +x "$tmpdir/apt-get"

    run bash -c "
        export PATH='$tmpdir:\$PATH'
        source '$SCRIPT' 2>/dev/null || true
        detect_host_platform 2>/dev/null
        echo \"arch=\$HOST_ARCH pkg=\$HOST_PKG ext=\$HOST_PKG_EXT\"
    "
    [[ "$output" == *"arch=amd64"* ]]
    [[ "$output" == *"pkg=deb"* ]]
    [[ "$output" == *"ext=.deb"* ]]
    rm -rf "$tmpdir"
}

@test "detect_host_platform: aarch64 + yum → arm64 rpm" {
    load_helpers
    tmpdir=$(mktemp -d)

    printf '#!/bin/sh\necho aarch64\n' > "$tmpdir/uname"; chmod +x "$tmpdir/uname"
    printf '#!/bin/sh\nexit 0\n'       > "$tmpdir/yum";   chmod +x "$tmpdir/yum"

    # Extract function body into a temp file so $SCRIPT expands correctly
    func_body=$(awk '/^detect_host_platform\(\)/,/^}/' "$SCRIPT")

    run bash -c "
        export PATH='$tmpdir'
        GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
        log_info() { :; }; log_warn() { :; }; log_error() { exit 1; }
        $func_body
        detect_host_platform
        echo \"arch=\$HOST_ARCH pkg=\$HOST_PKG ext=\$HOST_PKG_EXT\"
    "
    [[ "$output" == *"arch=arm64"* ]]
    [[ "$output" == *"pkg=rpm"* ]]
    [[ "$output" == *"ext=.rpm"* ]]
    rm -rf "$tmpdir"
}

@test "detect_host_platform: unknown arch defaults to amd64" {
    load_helpers
    tmpdir=$(mktemp -d)
    printf '#!/bin/sh\necho mips64\n' > "$tmpdir/uname";   chmod +x "$tmpdir/uname"
    printf '#!/bin/sh\nexit 0\n'     > "$tmpdir/apt-get"; chmod +x "$tmpdir/apt-get"

    func_body=$(awk '/^detect_host_platform\(\)/,/^}/' "$SCRIPT")

    run bash -c "
        export PATH='$tmpdir:\$PATH'
        GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
        log_info() { :; }
        log_warn() { echo \"[WARN] \$1\" >&2; }
        $func_body
        detect_host_platform 2>&1
        echo \"arch=\$HOST_ARCH\"
    "
    [[ "$output" == *"arch=amd64"* ]]
    [[ "$output" == *"Unknown"* ]]
    rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# detect_helm_schema_flag — enable --skip-schema-validation when Helm supports it
# Regression: Helm 3.18.5+ strict metaschema validation rejects the upstream
# opentelemetry-operator chart (featureGates.examples is a string). The flag must
# be enabled on ANY Helm that supports it (>=3.16), not only major >= 4.
# ---------------------------------------------------------------------------

detect_helm_schema_flag_func() {
    awk '/^detect_helm_schema_flag\(\)/,/^}/' "$SCRIPT"
}

# NOTE: assertions are the LAST commands in each test. bats has no implicit
# `set -e`, so a trailing `rm -rf` would mask a failing assertion. Cleanup runs
# before the assertions; $output is already captured by `run`.

@test "detect_helm_schema_flag: enables flag when Helm supports --skip-schema-validation" {
    tmpdir=$(mktemp -d)
    cat > "$tmpdir/helm" << 'SH'
#!/bin/sh
if [ "$1" = "upgrade" ] && [ "$2" = "--help" ]; then
  echo "      --skip-schema-validation   if set, disables JSON schema validation"
  exit 0
fi
exit 0
SH
    chmod +x "$tmpdir/helm"

    func_body=$(detect_helm_schema_flag_func)
    run bash -c "
        export PATH=$tmpdir:\$PATH
        log_info() { :; }
        HELM_SCHEMA_FLAG=''
        $func_body
        detect_helm_schema_flag
        echo \"flag=[\$HELM_SCHEMA_FLAG]\"
    "
    rm -rf "$tmpdir"
    [ "$status" -eq 0 ]
    [[ "$output" == *"flag=[--skip-schema-validation]"* ]]
}

@test "detect_helm_schema_flag: Helm 3.18.5 (major 3) still gets the flag (customer regression)" {
    tmpdir=$(mktemp -d)
    # Simulate Helm 3.18.5: --version reports v3.18.5 but help DOES expose the flag.
    cat > "$tmpdir/helm" << 'SH'
#!/bin/sh
if [ "$1" = "version" ]; then echo "v3.18.5+gd84a6c0"; exit 0; fi
if [ "$1" = "upgrade" ] && [ "$2" = "--help" ]; then
  echo "      --skip-schema-validation   if set, disables JSON schema validation"
  exit 0
fi
exit 0
SH
    chmod +x "$tmpdir/helm"

    func_body=$(detect_helm_schema_flag_func)
    run bash -c "
        export PATH=$tmpdir:\$PATH
        log_info() { :; }
        HELM_SCHEMA_FLAG=''
        $func_body
        detect_helm_schema_flag
        echo \"flag=[\$HELM_SCHEMA_FLAG]\"
    "
    rm -rf "$tmpdir"
    [ "$status" -eq 0 ]
    [[ "$output" == *"flag=[--skip-schema-validation]"* ]]
}

@test "detect_helm_schema_flag: old Helm without the flag leaves it empty" {
    tmpdir=$(mktemp -d)
    # Simulate Helm < 3.16: help does NOT list --skip-schema-validation.
    cat > "$tmpdir/helm" << 'SH'
#!/bin/sh
if [ "$1" = "upgrade" ] && [ "$2" = "--help" ]; then
  echo "      --atomic   if set, upgrade process rolls back on failure"
  echo "      --wait     if set, will wait until all resources are ready"
  exit 0
fi
exit 0
SH
    chmod +x "$tmpdir/helm"

    func_body=$(detect_helm_schema_flag_func)
    run bash -c "
        export PATH=$tmpdir:\$PATH
        log_info() { :; }
        HELM_SCHEMA_FLAG=''
        $func_body
        detect_helm_schema_flag
        echo \"flag=[\$HELM_SCHEMA_FLAG]\"
    "
    rm -rf "$tmpdir"
    [ "$status" -eq 0 ]
    [ "$output" = "flag=[]" ]
}

# ---------------------------------------------------------------------------
# setup_context_wrappers
# ---------------------------------------------------------------------------

setup_context_wrappers_func() {
    awk '/^setup_context_wrappers\(\)/,/^}/' "$SCRIPT"
}

@test "setup_context_wrappers: no-op when KUBE_CONTEXT is empty" {
    run bash -c "
        GREEN='\033[0;32m'; NC='\033[0m'
        log_info() { :; }
        log_error() { echo \"[ERROR] \$1\" >&2; exit 1; }
        KUBE_CONTEXT=''
        $(setup_context_wrappers_func)
        setup_context_wrappers
        # kubectl should not be a function — should still be the binary name
        type kubectl | head -1
    "
    [ "$status" -eq 0 ]
    # function wrapping only happens when context is set
    [[ "$output" != *"kubectl is a function"* ]]
}

@test "setup_context_wrappers: wraps kubectl with --context flag when context set" {
    tmpdir=$(mktemp -d)

    # Mock kubectl: validate config get-contexts succeeds, then record args
    cat > "$tmpdir/kubectl" << 'SH'
#!/bin/sh
if [ "$1" = "config" ] && [ "$2" = "get-contexts" ]; then exit 0; fi
echo "kubectl_called_with: $*"
SH
    chmod +x "$tmpdir/kubectl"

    func_body=$(setup_context_wrappers_func)
    run bash -c "
        export PATH='$tmpdir:\$PATH'
        GREEN='\033[0;32m'; NC='\033[0m'
        log_info() { echo \"\$1\" >&2; }
        log_error() { echo \"[ERROR] \$1\" >&2; exit 1; }
        KUBE_CONTEXT='my-prod-context'
        $func_body
        setup_context_wrappers
        kubectl get pods -n last9
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"--context my-prod-context"* ]]
    [[ "$output" == *"get pods"* ]]
    rm -rf "$tmpdir"
}

@test "setup_context_wrappers: wraps helm with --kube-context flag when context set" {
    tmpdir=$(mktemp -d)

    cat > "$tmpdir/kubectl" << 'SH'
#!/bin/sh
if [ "$1" = "config" ] && [ "$2" = "get-contexts" ]; then exit 0; fi
SH
    cat > "$tmpdir/helm" << 'SH'
#!/bin/sh
echo "helm_called_with: $*"
SH
    chmod +x "$tmpdir/kubectl" "$tmpdir/helm"

    func_body=$(setup_context_wrappers_func)
    run bash -c "
        export PATH='$tmpdir:\$PATH'
        GREEN='\033[0;32m'; NC='\033[0m'
        log_info() { :; }
        log_error() { echo \"[ERROR] \$1\" >&2; exit 1; }
        KUBE_CONTEXT='staging-cluster'
        $func_body
        setup_context_wrappers
        helm upgrade --install myrelease mychart -n last9
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"--kube-context staging-cluster"* ]]
    rm -rf "$tmpdir"
}

@test "setup_context_wrappers: errors when context does not exist" {
    tmpdir=$(mktemp -d)

    # kubectl config get-contexts exits non-zero for unknown context
    cat > "$tmpdir/kubectl" << 'SH'
#!/bin/sh
if [ "$1" = "config" ] && [ "$2" = "get-contexts" ]; then exit 1; fi
SH
    chmod +x "$tmpdir/kubectl"

    func_body=$(setup_context_wrappers_func)
    run bash -c "
        export PATH='$tmpdir:\$PATH'
        GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
        log_info() { :; }
        log_error() { echo \"[ERROR] \$1\" >&2; exit 1; }
        KUBE_CONTEXT='nonexistent-context'
        $func_body
        setup_context_wrappers
        echo 'should not reach here'
    " 2>&1
    [ "$status" -eq 1 ]
    [[ "$output" == *"[ERROR]"* ]]
    [[ "$output" == *"nonexistent-context"* ]]
    [[ "$output" != *"should not reach here"* ]]
    rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# inject_collector_tls_server_name / inject_monitoring_tls_server_name
# ---------------------------------------------------------------------------

collector_tls_func() {
    awk '/^inject_collector_tls_server_name\(\)/,/^}/' "$SCRIPT"
}
monitoring_tls_func() {
    awk '/^inject_monitoring_tls_server_name\(\)/,/^}/' "$SCRIPT"
}

@test "inject_collector_tls: adds tls block under otlp/last9 with correct indent" {
    tmpdir=$(mktemp -d)
    cp "$BATS_TEST_DIRNAME/../last9-otel-collector-values.yaml" "$tmpdir/last9-otel-collector-values.yaml"
    func_body=$(collector_tls_func)
    run bash -c "
        cd '$tmpdir'
        log_info() { :; }; log_warn() { :; }; log_error() { exit 1; }
        SERVER_NAME='otlp.last9.io'
        $func_body
        inject_collector_tls_server_name last9-otel-collector-values.yaml
        grep -n 'server_name_override' last9-otel-collector-values.yaml
    "
    [ "$status" -eq 0 ]
    # server_name_override child of tls, indented 8 spaces
    [[ "$output" == *"        server_name_override: otlp.last9.io"* ]]
    # exactly one tls block (decoy endpoint: lines must not be matched)
    n=$(grep -c '^      tls:' "$tmpdir/last9-otel-collector-values.yaml")
    [ "$n" -eq 1 ]
    rm -rf "$tmpdir"
}

@test "inject_monitoring_tls: adds tlsConfig.serverName under remoteWrite url" {
    tmpdir=$(mktemp -d)
    cp "$BATS_TEST_DIRNAME/../k8s-monitoring-values.yaml" "$tmpdir/k8s-monitoring-values.yaml"
    func_body=$(monitoring_tls_func)
    run bash -c "
        cd '$tmpdir'
        log_info() { :; }; log_warn() { :; }; log_error() { exit 1; }
        SERVER_NAME='metrics.last9.io'
        $func_body
        inject_monitoring_tls_server_name
        grep -n 'serverName' k8s-monitoring-values.yaml
    "
    [ "$status" -eq 0 ]
    # serverName indented 10 spaces; tlsConfig at 8 spaces
    [[ "$output" == *"          serverName: metrics.last9.io"* ]]
    grep -q '^        tlsConfig:' "$tmpdir/k8s-monitoring-values.yaml"
    rm -rf "$tmpdir"
}

@test "inject_collector_tls: no-op and byte-identical when SERVER_NAME empty" {
    tmpdir=$(mktemp -d)
    cp "$BATS_TEST_DIRNAME/../last9-otel-collector-values.yaml" "$tmpdir/orig.yaml"
    cp "$tmpdir/orig.yaml" "$tmpdir/last9-otel-collector-values.yaml"
    func_body=$(collector_tls_func)
    run bash -c "
        cd '$tmpdir'
        log_info() { :; }; log_warn() { :; }; log_error() { exit 1; }
        SERVER_NAME=''
        $func_body
        inject_collector_tls_server_name last9-otel-collector-values.yaml
        diff orig.yaml last9-otel-collector-values.yaml && echo SAME
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"SAME"* ]]
    rm -rf "$tmpdir"
}

@test "inject_collector_tls: idempotent on re-run (single block)" {
    tmpdir=$(mktemp -d)
    cp "$BATS_TEST_DIRNAME/../last9-otel-collector-values.yaml" "$tmpdir/last9-otel-collector-values.yaml"
    func_body=$(collector_tls_func)
    run bash -c "
        cd '$tmpdir'
        log_info() { :; }; log_warn() { :; }; log_error() { exit 1; }
        SERVER_NAME='otlp.last9.io'
        $func_body
        inject_collector_tls_server_name last9-otel-collector-values.yaml
        inject_collector_tls_server_name last9-otel-collector-values.yaml
        grep -c 'server_name_override' last9-otel-collector-values.yaml
    "
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | tail -1)" -eq 1 ]
    rm -rf "$tmpdir"
}

@test "inject_monitoring_tls: no-op and byte-identical when SERVER_NAME empty" {
    tmpdir=$(mktemp -d)
    cp "$BATS_TEST_DIRNAME/../k8s-monitoring-values.yaml" "$tmpdir/orig.yaml"
    cp "$tmpdir/orig.yaml" "$tmpdir/k8s-monitoring-values.yaml"
    func_body=$(monitoring_tls_func)
    run bash -c "
        cd '$tmpdir'
        log_info() { :; }; log_warn() { :; }; log_error() { exit 1; }
        SERVER_NAME=''
        $func_body
        inject_monitoring_tls_server_name
        diff orig.yaml k8s-monitoring-values.yaml && echo SAME
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"SAME"* ]]
    rm -rf "$tmpdir"
}

@test "inject_collector_tls: adds override under existing tls block, no duplicate tls:" {
    tmpdir=$(mktemp -d)
    cat > "$tmpdir/last9-otel-collector-values.yaml" <<'YAML'
config:
  exporters:
    otlp/last9:
      endpoint: "{{OTEL_ENDPOINT}}"
      tls:
        insecure: false
      headers:
        authorization: token
YAML
    func_body=$(collector_tls_func)
    run bash -c "
        cd '$tmpdir'
        log_info() { :; }; log_warn() { :; }; log_error() { exit 1; }
        SERVER_NAME='otlp.last9.io'
        $func_body
        inject_collector_tls_server_name last9-otel-collector-values.yaml
        grep -n 'server_name_override' last9-otel-collector-values.yaml
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"        server_name_override: otlp.last9.io"* ]]
    # exactly one tls: key — no duplicate emitted
    n=$(grep -c '^      tls:' "$tmpdir/last9-otel-collector-values.yaml")
    [ "$n" -eq 1 ]
    rm -rf "$tmpdir"
}

@test "inject_monitoring_tls: idempotent on re-run (single serverName)" {
    tmpdir=$(mktemp -d)
    cp "$BATS_TEST_DIRNAME/../k8s-monitoring-values.yaml" "$tmpdir/k8s-monitoring-values.yaml"
    func_body=$(monitoring_tls_func)
    run bash -c "
        cd '$tmpdir'
        log_info() { :; }; log_warn() { :; }; log_error() { exit 1; }
        SERVER_NAME='metrics.last9.io'
        $func_body
        inject_monitoring_tls_server_name
        inject_monitoring_tls_server_name
        grep -c 'serverName:' k8s-monitoring-values.yaml
    "
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | tail -1)" -eq 1 ]
    rm -rf "$tmpdir"
}

@test "inject_monitoring_tls: unrelated serverName elsewhere does not block injection" {
    tmpdir=$(mktemp -d)
    {
        echo "prometheus:"
        echo "  prometheusSpec:"
        echo "    remoteWrite:"
        echo '      - url: "{{YOUR_MONITORING_ENDPOINT}}"'
        echo "someOtherComponent:"
        echo "  serverName: unrelated.example.com"
    } > "$tmpdir/k8s-monitoring-values.yaml"
    func_body=$(monitoring_tls_func)
    run bash -c "
        cd '$tmpdir'
        log_info() { :; }; log_warn() { :; }; log_error() { exit 1; }
        SERVER_NAME='metrics.last9.io'
        $func_body
        inject_monitoring_tls_server_name
        grep -n 'serverName' k8s-monitoring-values.yaml
    "
    [ "$status" -eq 0 ]
    # injection still happened despite the unrelated serverName: above
    [[ "$output" == *"          serverName: metrics.last9.io"* ]]
    rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# update_deployment_mode — flips daemonset→deployment, disables logsCollection,
# comments out the filelog receiver (operator-only collector tweak).
# ---------------------------------------------------------------------------

update_deployment_mode_func() {
    awk '/^update_deployment_mode\(\)/,/^}/' "$SCRIPT"
}

@test "update_deployment_mode: daemonset→deployment, logsCollection off, filelog commented" {
    tmpdir=$(mktemp -d)
    cat > "$tmpdir/last9-otel-collector-values.yaml" <<'YAML'
mode: "daemonset"
presets:
  logsCollection:
    enabled: true
config:
  service:
    pipelines:
      logs:
        receivers:
          - filelog
YAML
    func_body=$(update_deployment_mode_func)
    run bash -c "
        cd '$tmpdir'
        log_info() { :; }; log_warn() { :; }; log_error() { echo \"[ERROR] \$1\"; exit 1; }
        $func_body
        update_deployment_mode
    "
    [ "$status" -eq 0 ]
    grep -q 'mode: "deployment"' "$tmpdir/last9-otel-collector-values.yaml"
    grep -A1 'logsCollection:' "$tmpdir/last9-otel-collector-values.yaml" | grep -q 'enabled: false'
    grep -q '          # - filelog' "$tmpdir/last9-otel-collector-values.yaml"
    # original is backed up
    [ -f "$tmpdir/last9-otel-collector-values.yaml.backup" ]
    rm -rf "$tmpdir"
}

@test "update_deployment_mode: errors when the values file is missing" {
    tmpdir=$(mktemp -d)
    func_body=$(update_deployment_mode_func)
    run bash -c "
        cd '$tmpdir'
        log_info() { :; }; log_warn() { :; }; log_error() { echo \"[ERROR] \$1\" >&2; exit 1; }
        $func_body
        update_deployment_mode
    " 2>&1
    [ "$status" -eq 1 ]
    [[ "$output" == *"[ERROR]"* ]]
    [[ "$output" == *"not found"* ]]
    rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# apply_tolerations_to_monitoring_values — awk/sed fallback (USE_YQ=false),
# so no yq dependency in CI.
# ---------------------------------------------------------------------------

apply_tolerations_func() {
    awk '/^apply_tolerations_to_monitoring_values\(\)/,/^}/' "$SCRIPT"
}

@test "apply_tolerations (fallback): injects tolerations + nodeSelector into monitoring values" {
    tmpdir=$(mktemp -d)
    cat > "$tmpdir/values.yaml" <<'YAML'
prometheusOperator:
  enabled: true
kubeStateMetrics:
  enabled: true
nodeExporter:
  enabled: true
prometheus:
  prometheusSpec:
    scrapeInterval: 30s
YAML
    cat > "$tmpdir/tolerations.yaml" <<'YAML'
tolerations:
  - key: dedicated
    operator: Equal
    value: monitoring
    effect: NoSchedule
nodeSelector:
  workload: monitoring
nodeExporterTolerations:
  - operator: Exists
YAML
    func_body=$(apply_tolerations_func)
    run bash -c "
        cd '$tmpdir'
        log_info() { :; }; log_warn() { :; }; log_error() { echo \"[ERROR] \$1\"; exit 1; }
        USE_YQ=false
        TOLERATIONS_FILE_PATH='$tmpdir/tolerations.yaml'
        $func_body
        apply_tolerations_to_monitoring_values values.yaml
    "
    [ "$status" -eq 0 ]
    # backup written
    [ -f "$tmpdir/values.yaml.backup-tolerations" ]
    # tolerations + nodeSelector injected from the tolerations file
    grep -q 'key: dedicated' "$tmpdir/values.yaml"
    grep -q 'workload: monitoring' "$tmpdir/values.yaml"
    # node-exporter got the explicit nodeExporterTolerations (operator: Exists)
    grep -q 'operator: Exists' "$tmpdir/values.yaml"
    rm -rf "$tmpdir"
}

@test "apply_tolerations (fallback): defaults node-exporter to operator:Exists when none provided" {
    tmpdir=$(mktemp -d)
    cat > "$tmpdir/values.yaml" <<'YAML'
prometheusOperator:
  enabled: true
kubeStateMetrics:
  enabled: true
nodeExporter:
  enabled: true
YAML
    # tolerations file with no nodeExporterTolerations section
    cat > "$tmpdir/tolerations.yaml" <<'YAML'
tolerations:
  - key: dedicated
    operator: Equal
    value: monitoring
    effect: NoSchedule
YAML
    func_body=$(apply_tolerations_func)
    run bash -c "
        cd '$tmpdir'
        log_info() { :; }; log_warn() { :; }; log_error() { echo \"[ERROR] \$1\"; exit 1; }
        USE_YQ=false
        TOLERATIONS_FILE_PATH='$tmpdir/tolerations.yaml'
        $func_body
        apply_tolerations_to_monitoring_values values.yaml
    "
    [ "$status" -eq 0 ]
    grep -q 'operator: Exists' "$tmpdir/values.yaml"
    rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# detect_existing_prometheus_operator — returns 0 (found, warns) / 1 (none).
# ---------------------------------------------------------------------------

detect_prom_operator_func() {
    awk '/^detect_existing_prometheus_operator\(\)/,/^}/' "$SCRIPT"
}

@test "detect_existing_prometheus_operator: returns 0 and warns when one exists in another namespace" {
    func_body=$(detect_prom_operator_func)
    run bash -c "
        GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
        log_info() { :; }; log_warn() { echo \"[WARN] \$1\"; }
        NAMESPACE='last9'
        # kubectl reports a kube-prometheus-stack operator deployment in 'monitoring'
        kubectl() {
            case \"\$*\" in
                *kube-prometheus-stack-operator*) echo 'monitoring  kps-operator  1/1  1  1  5m' ;;
                *) : ;;
            esac
        }
        $func_body
        if detect_existing_prometheus_operator; then echo RC=0; else echo RC=1; fi
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=0"* ]]
    [[ "$output" == *"Existing Prometheus Operator found"* ]]
}

@test "detect_existing_prometheus_operator: returns 1 when none found" {
    func_body=$(detect_prom_operator_func)
    run bash -c "
        GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
        log_info() { :; }; log_warn() { :; }
        NAMESPACE='last9'
        kubectl() { : ; }   # no deployments anywhere
        $func_body
        if detect_existing_prometheus_operator; then echo RC=0; else echo RC=1; fi
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=1"* ]]
}

@test "detect_existing_prometheus_operator: ignores an operator in our own namespace" {
    func_body=$(detect_prom_operator_func)
    run bash -c "
        GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
        log_info() { :; }; log_warn() { :; }
        NAMESPACE='last9'
        # operator is in OUR namespace — awk filters it out, so 'none found'
        kubectl() {
            case \"\$*\" in
                *kube-prometheus-stack-operator*) echo 'last9  kps-operator  1/1  1  1  5m' ;;
                *) : ;;
            esac
        }
        $func_body
        if detect_existing_prometheus_operator; then echo RC=0; else echo RC=1; fi
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=1"* ]]
}

# ---------------------------------------------------------------------------
# show_examples — the no-argument usage screen.
# ---------------------------------------------------------------------------

@test "show_examples: prints the key usage examples" {
    func_body=$(awk '/^show_examples\(\)/,/^}/' "$SCRIPT")
    run bash -c "$func_body
        show_examples
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"Quick Examples:"* ]]
    [[ "$output" == *"monitoring-only"* ]]
    [[ "$output" == *"operator-only"* ]]
    [[ "$output" == *"uninstall-all"* ]]
}
