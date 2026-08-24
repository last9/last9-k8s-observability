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
# validate_namespace_list / build_namespace_regex
# ---------------------------------------------------------------------------

@test "validate_namespace_list: accepts a valid single namespace" {
    run bash -c "
        log_error() { echo \"[ERROR] \$1\" >&2; exit 1; }
        $(awk '/^validate_namespace_list\(\)/,/^}/' "$SCRIPT")
        validate_namespace_list 'production'
        echo OK
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "validate_namespace_list: accepts a valid comma-separated list" {
    run bash -c "
        log_error() { echo \"[ERROR] \$1\" >&2; exit 1; }
        $(awk '/^validate_namespace_list\(\)/,/^}/' "$SCRIPT")
        validate_namespace_list 'production,prod-apps,kube-system'
        echo OK
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "validate_namespace_list: rejects an entry with uppercase letters" {
    run bash -c "
        log_error() { echo \"[ERROR] \$1\" >&2; exit 1; }
        $(awk '/^validate_namespace_list\(\)/,/^}/' "$SCRIPT")
        validate_namespace_list 'Production'
        echo SHOULD_NOT_REACH
    " 2>&1
    [ "$status" -eq 1 ]
    echo "$output" | grep -qF "Invalid namespace"
    [[ "$output" != *"SHOULD_NOT_REACH"* ]]
}

@test "validate_namespace_list: rejects an entry with an underscore" {
    run bash -c "
        log_error() { echo \"[ERROR] \$1\" >&2; exit 1; }
        $(awk '/^validate_namespace_list\(\)/,/^}/' "$SCRIPT")
        validate_namespace_list 'prod_apps'
        echo SHOULD_NOT_REACH
    " 2>&1
    [ "$status" -eq 1 ]
    echo "$output" | grep -qF "Invalid namespace"
    [[ "$output" != *"SHOULD_NOT_REACH"* ]]
}

@test "validate_namespace_list: rejects an entry starting with a hyphen" {
    run bash -c "
        log_error() { echo \"[ERROR] \$1\" >&2; exit 1; }
        $(awk '/^validate_namespace_list\(\)/,/^}/' "$SCRIPT")
        validate_namespace_list '-production'
        echo SHOULD_NOT_REACH
    " 2>&1
    [ "$status" -eq 1 ]
    echo "$output" | grep -qF "Invalid namespace"
    [[ "$output" != *"SHOULD_NOT_REACH"* ]]
}

@test "validate_namespace_list: rejects an entry over 63 characters" {
    run bash -c "
        log_error() { echo \"[ERROR] \$1\" >&2; exit 1; }
        $(awk '/^validate_namespace_list\(\)/,/^}/' "$SCRIPT")
        validate_namespace_list \"\$(printf 'a%.0s' {1..64})\"
        echo SHOULD_NOT_REACH
    " 2>&1
    [ "$status" -eq 1 ]
    echo "$output" | grep -qF "Invalid namespace"
    [[ "$output" != *"SHOULD_NOT_REACH"* ]]
}

@test "validate_namespace_list: rejects an entry with a shell metacharacter" {
    run bash -c "
        log_error() { echo \"[ERROR] \$1\" >&2; exit 1; }
        $(awk '/^validate_namespace_list\(\)/,/^}/' "$SCRIPT")
        validate_namespace_list 'production;rm -rf /'
        echo SHOULD_NOT_REACH
    " 2>&1
    [ "$status" -eq 1 ]
    echo "$output" | grep -qF "Invalid namespace"
    [[ "$output" != *"SHOULD_NOT_REACH"* ]]
}

@test "build_namespace_regex: include mode wraps list with optional-empty anchor" {
    run bash -c "
        $(awk '/^build_namespace_regex\(\)/,/^}/' "$SCRIPT")
        build_namespace_regex 'production,prod-apps' include
    "
    [ "$status" -eq 0 ]
    [ "$output" = '^(production|prod-apps)?$' ]
}

@test "build_namespace_regex: exclude mode has no optional-empty anchor" {
    run bash -c "
        $(awk '/^build_namespace_regex\(\)/,/^}/' "$SCRIPT")
        build_namespace_regex 'dev,staging' exclude
    "
    [ "$status" -eq 0 ]
    [ "$output" = '^(dev|staging)$' ]
}

@test "build_namespace_regex: single-entry list has no stray pipe" {
    run bash -c "
        $(awk '/^build_namespace_regex\(\)/,/^}/' "$SCRIPT")
        build_namespace_regex 'production' include
    "
    [ "$status" -eq 0 ]
    [ "$output" = '^(production)?$' ]
}

# ---------------------------------------------------------------------------
# parse_arguments: metrics-namespace-include / metrics-namespace-exclude
# ---------------------------------------------------------------------------

parse_namespace_args_func() {
    echo "
        $(awk '/^validate_namespace_list\(\)/,/^}/' "$SCRIPT")
        $(awk '/^check_namespace_filter_mutual_exclusion\(\)/,/^}/' "$SCRIPT")
        METRICS_NAMESPACE_INCLUDE=''
        METRICS_NAMESPACE_EXCLUDE=''
        $(awk '/^parse_arguments\(\)/,/^}/' "$SCRIPT")
    "
}

@test "parse_arguments: metrics-namespace-include sets METRICS_NAMESPACE_INCLUDE" {
    run bash -c "
        log_error() { echo \"[ERROR] \$1\" >&2; exit 1; }
        log_warn() { :; }
        show_help() { :; }
        $(parse_namespace_args_func)
        parse_arguments metrics-namespace-include=production,prod-apps
        echo \"INCLUDE=\$METRICS_NAMESPACE_INCLUDE\"
        echo \"EXCLUDE=\$METRICS_NAMESPACE_EXCLUDE\"
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "INCLUDE=production,prod-apps"
    echo "$output" | grep -qF "EXCLUDE="
}

@test "parse_arguments: metrics-namespace-exclude sets METRICS_NAMESPACE_EXCLUDE" {
    run bash -c "
        log_error() { echo \"[ERROR] \$1\" >&2; exit 1; }
        log_warn() { :; }
        show_help() { :; }
        $(parse_namespace_args_func)
        parse_arguments metrics-namespace-exclude=dev,staging
        echo \"INCLUDE=\$METRICS_NAMESPACE_INCLUDE\"
        echo \"EXCLUDE=\$METRICS_NAMESPACE_EXCLUDE\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"EXCLUDE=dev,staging"* ]]
}

@test "parse_arguments: no namespace args leaves both empty" {
    run bash -c "
        log_error() { echo \"[ERROR] \$1\" >&2; exit 1; }
        log_warn() { :; }
        show_help() { :; }
        $(parse_namespace_args_func)
        parse_arguments monitoring-only
        echo \"INCLUDE=[\$METRICS_NAMESPACE_INCLUDE]\"
        echo \"EXCLUDE=[\$METRICS_NAMESPACE_EXCLUDE]\"
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "INCLUDE=[]"
    echo "$output" | grep -qF "EXCLUDE=[]"
}

@test "parse_arguments: invalid namespace in include list fails before Helm" {
    run bash -c "
        log_error() { echo \"[ERROR] \$1\" >&2; exit 1; }
        log_warn() { :; }
        show_help() { :; }
        $(parse_namespace_args_func)
        parse_arguments metrics-namespace-include=Bad_Namespace
        echo SHOULD_NOT_REACH
    " 2>&1
    [ "$status" -eq 1 ]
    echo "$output" | grep -qF "Invalid namespace"
    [[ "$output" != *"SHOULD_NOT_REACH"* ]]
}

@test "parse_arguments: both include and exclude set is a hard error" {
    run bash -c "
        log_error() { echo \"[ERROR] \$1\" >&2; exit 1; }
        log_warn() { :; }
        show_help() { :; }
        $(parse_namespace_args_func)
        parse_arguments metrics-namespace-include=production metrics-namespace-exclude=dev
        echo SHOULD_NOT_REACH
    " 2>&1
    [ "$status" -eq 1 ]
    echo "$output" | grep -qE "both|mutually exclusive"
    [[ "$output" != *"SHOULD_NOT_REACH"* ]]
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
        export PATH='$tmpdir:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH'
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
        export PATH='$tmpdir:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH'
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
        export PATH='$tmpdir:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH'
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
        export PATH='$tmpdir:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH'
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
        export PATH='$tmpdir:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH'
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
# migrate_collector_values_for_0165 / _collector_last9_exporter_key
# ---------------------------------------------------------------------------

collector_values_helpers_func() {
    awk '/^_collector_last9_exporter_key\(\)/,/^}/' "$SCRIPT"
    awk '/^_collector_values_has_legacy_keys\(\)/,/^}/' "$SCRIPT"
    awk '/^_collector_values_has_kubernetes_events_preset_enabled\(\)/,/^}/' "$SCRIPT"
    awk '/^version_lt\(\)/,/^}/' "$SCRIPT"
    awk '/^_helm_release_exists\(\)/,/^}/' "$SCRIPT"
    awk '/^_helm_release_chart_version\(\)/,/^}/' "$SCRIPT"
    awk '/^migrate_collector_values_for_0165\(\)/,/^}/' "$SCRIPT"
    awk '/^prepare_collector_values_file\(\)/,/^}/' "$SCRIPT"
}

collector_tls_func() {
    collector_values_helpers_func
    awk '/^inject_collector_tls_server_name\(\)/,/^}/' "$SCRIPT"
}
monitoring_tls_func() {
    awk '/^inject_monitoring_tls_server_name\(\)/,/^}/' "$SCRIPT"
}

legacy_collector_values_fixture() {
    cat <<'YAML'
config:
  exporters:
    otlp/last9:
      endpoint: "{{OTEL_ENDPOINT}}"
      headers:
        "Authorization": "{{AUTH_TOKEN}}"
  processors:
    k8sattributes:
      extract_all_pod_labels: true
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
}

@test "migrate_collector_values: renames legacy otlp, processor, and receiver keys" {
    tmpdir=$(mktemp -d)
    legacy_collector_values_fixture > "$tmpdir/legacy-values.yaml"
    func_body=$(collector_values_helpers_func)
    run bash -c "
        cd '$tmpdir'
        COLLECTOR_VERSION='0.165.0'
        log_info() { :; }; log_warn() { :; }; log_error() { exit 1; }
        $func_body
        migrate_collector_values_for_0165 legacy-values.yaml
        grep -E 'otlp_grpc/last9|k8s_attributes|k8s_objects/topology' legacy-values.yaml
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"otlp_grpc/last9"* ]]
    [[ "$output" == *"k8s_attributes"* ]]
    [[ "$output" == *"k8s_objects/topology"* ]]
    ! grep -qE '^[[:space:]]*otlp/last9:|^[[:space:]]*- otlp/last9$|^[[:space:]]*k8sattributes:|^[[:space:]]*- k8sattributes$|^[[:space:]]*k8sobjects(/topology)?:|^[[:space:]]*- k8sobjects$' "$tmpdir/legacy-values.yaml"
    rm -rf "$tmpdir"
}

@test "migrate_collector_values: no-op on already-migrated bundled values" {
    tmpdir=$(mktemp -d)
    cp "$BATS_TEST_DIRNAME/../last9-otel-collector-values.yaml" "$tmpdir/values.yaml"
    cp "$tmpdir/values.yaml" "$tmpdir/orig.yaml"
    func_body=$(collector_values_helpers_func)
    run bash -c "
        cd '$tmpdir'
        COLLECTOR_VERSION='0.165.0'
        log_info() { :; }; log_warn() { :; }; log_error() { exit 1; }
        $func_body
        migrate_collector_values_for_0165 values.yaml
        diff orig.yaml values.yaml && echo SAME
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"SAME"* ]]
    [ ! -f "$tmpdir/values.yaml.backup-migrate" ]
    rm -rf "$tmpdir"
}

@test "migrate_collector_values: idempotent on second run" {
    tmpdir=$(mktemp -d)
    legacy_collector_values_fixture > "$tmpdir/legacy-values.yaml"
    func_body=$(collector_values_helpers_func)
    run bash -c "
        cd '$tmpdir'
        COLLECTOR_VERSION='0.165.0'
        log_info() { :; }; log_warn() { :; }; log_error() { exit 1; }
        $func_body
        migrate_collector_values_for_0165 legacy-values.yaml
        cp legacy-values.yaml once.yaml
        migrate_collector_values_for_0165 legacy-values.yaml
        diff once.yaml legacy-values.yaml && echo SAME
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"SAME"* ]]
    rm -rf "$tmpdir"
}

@test "migrate_collector_values: creates backup-migrate only once" {
    tmpdir=$(mktemp -d)
    legacy_collector_values_fixture > "$tmpdir/legacy-values.yaml"
    func_body=$(collector_values_helpers_func)
    run bash -c "
        cd '$tmpdir'
        COLLECTOR_VERSION='0.165.0'
        log_info() { :; }; log_warn() { :; }; log_error() { exit 1; }
        $func_body
        migrate_collector_values_for_0165 legacy-values.yaml
        migrate_collector_values_for_0165 legacy-values.yaml
        ls legacy-values.yaml.backup-migrate
    "
    [ "$status" -eq 0 ]
    grep -q 'otlp/last9' "$tmpdir/legacy-values.yaml.backup-migrate"
    rm -rf "$tmpdir"
}

@test "migrate_collector_values: warns when kubernetesEvents preset still enabled" {
    tmpdir=$(mktemp -d)
    legacy_collector_values_fixture > "$tmpdir/legacy-values.yaml"
    cat >> "$tmpdir/legacy-values.yaml" <<'YAML'
presets:
  kubernetesEvents:
    enabled: true
YAML
    func_body=$(collector_values_helpers_func)
    run bash -c "
        cd '$tmpdir'
        COLLECTOR_VERSION='0.165.0'
        NAMESPACE='last9'
        log_info() { :; }
        log_warn() { echo \"[WARN] \$1\"; }
        log_error() { exit 1; }
        helm() { :; }
        $func_body
        prepare_collector_values_file legacy-values.yaml '' 'OpenTelemetry Collector'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"kubernetesEvents.enabled: true"* ]]
    [[ "$output" == *"Action required"* ]]
    rm -rf "$tmpdir"
}

@test "prepare_collector_values: calls out upgrade when release already installed" {
    tmpdir=$(mktemp -d)
    cp "$BATS_TEST_DIRNAME/integration/stubs/helm" "$tmpdir/helm"
    chmod +x "$tmpdir/helm"
    legacy_collector_values_fixture > "$tmpdir/legacy-values.yaml"
    func_body=$(collector_values_helpers_func)
    run bash -c "
        export PATH='$tmpdir:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH'
        export SIMULATE_EXISTING_COLLECTOR_RELEASE=1
        export HELM_CALLS_LOG='$tmpdir/helm.log'
        cd '$tmpdir'
        COLLECTOR_VERSION='0.165.0'
        NAMESPACE='last9'
        log_info() { :; }
        log_warn() { echo \"[WARN] \$1\"; }
        log_error() { exit 1; }
        $func_body
        prepare_collector_values_file legacy-values.yaml last9-opentelemetry-collector 'OpenTelemetry Collector'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"Upgrade detected"* ]]
    [[ "$output" == *"0.126.0"* ]]
    [[ "$output" == *"0.165.0"* ]]
    [[ "$output" == *"deprecated collector config keys"* ]]
    grep -q 'otlp_grpc/last9' "$tmpdir/legacy-values.yaml"
    rm -rf "$tmpdir"
}

@test "prepare_collector_values: fresh install skips upgrade banner" {
    tmpdir=$(mktemp -d)
    cp "$BATS_TEST_DIRNAME/../last9-otel-collector-values.yaml" "$tmpdir/values.yaml"
    func_body=$(collector_values_helpers_func)
    run bash -c "
        cd '$tmpdir'
        COLLECTOR_VERSION='0.165.0'
        NAMESPACE='last9'
        log_info() { :; }
        log_warn() { echo \"[WARN] \$1\"; }
        log_error() { exit 1; }
        helm() { echo '[]'; }
        $func_body
        prepare_collector_values_file values.yaml last9-opentelemetry-collector 'OpenTelemetry Collector'
    "
    [ "$status" -eq 0 ]
    [[ "$output" != *"Upgrade detected"* ]]
    rm -rf "$tmpdir"
}

@test "collector_last9_exporter_key: detects legacy otlp/last9" {
    tmpdir=$(mktemp -d)
    cat > "$tmpdir/values.yaml" <<'YAML'
config:
  exporters:
    otlp/last9:
      endpoint: x
YAML
    func_body=$(collector_values_helpers_func)
    run bash -c "
        $func_body
        _collector_last9_exporter_key '$tmpdir/values.yaml'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "otlp/last9" ]
    rm -rf "$tmpdir"
}

@test "inject_collector_tls: works on legacy otlp/last9 exporter" {
    tmpdir=$(mktemp -d)
    cat > "$tmpdir/last9-otel-collector-values.yaml" <<'YAML'
config:
  exporters:
    otlp/last9:
      endpoint: "{{OTEL_ENDPOINT}}"
YAML
    func_body=$(collector_tls_func)
    run bash -c "
        cd '$tmpdir'
        log_info() { :; }; log_warn() { :; }; log_error() { exit 1; }
        SERVER_NAME='otlp.last9.io'
        $func_body
        inject_collector_tls_server_name last9-otel-collector-values.yaml
        grep 'server_name_override' last9-otel-collector-values.yaml
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"server_name_override: otlp.last9.io"* ]]
    rm -rf "$tmpdir"
}

@test "inject_collector_tls: adds tls block under otlp_grpc/last9 with correct indent" {
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
    otlp_grpc/last9:
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
# inject_metrics_namespace_filter
# ---------------------------------------------------------------------------

namespace_filter_func() {
    echo "
        $(awk '/^build_namespace_regex\(\)/,/^}/' "$SCRIPT")
        $(awk '/^inject_metrics_namespace_filter\(\)/,/^}/' "$SCRIPT")
    "
}

@test "inject_metrics_namespace_filter: no-op and byte-identical when both unset" {
    tmpdir=$(mktemp -d)
    cp "$BATS_TEST_DIRNAME/../k8s-monitoring-values.yaml" "$tmpdir/orig.yaml"
    cp "$tmpdir/orig.yaml" "$tmpdir/k8s-monitoring-values.yaml"
    func_body=$(namespace_filter_func)
    run bash -c "
        cd '$tmpdir'
        log_info() { :; }; log_warn() { :; }; log_error() { exit 1; }
        METRICS_NAMESPACE_INCLUDE=''
        METRICS_NAMESPACE_EXCLUDE=''
        $func_body
        inject_metrics_namespace_filter
        diff orig.yaml k8s-monitoring-values.yaml && echo SAME
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"SAME"* ]]
    rm -rf "$tmpdir"
}

@test "inject_metrics_namespace_filter: include list renders keep rule with empty-carve-out" {
    tmpdir=$(mktemp -d)
    cp "$BATS_TEST_DIRNAME/../k8s-monitoring-values.yaml" "$tmpdir/k8s-monitoring-values.yaml"
    func_body=$(namespace_filter_func)
    run bash -c "
        cd '$tmpdir'
        log_info() { :; }; log_warn() { :; }; log_error() { exit 1; }
        METRICS_NAMESPACE_INCLUDE='production,prod-apps'
        METRICS_NAMESPACE_EXCLUDE=''
        $func_body
        inject_metrics_namespace_filter
        grep -n 'sourceLabels: \[namespace\]' -A2 k8s-monitoring-values.yaml
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF 'regex: "^(production|prod-apps)?$"'
    echo "$output" | grep -qF "action: keep"
    rm -rf "$tmpdir"
}

@test "inject_metrics_namespace_filter: exclude list renders drop rule without carve-out" {
    tmpdir=$(mktemp -d)
    cp "$BATS_TEST_DIRNAME/../k8s-monitoring-values.yaml" "$tmpdir/k8s-monitoring-values.yaml"
    func_body=$(namespace_filter_func)
    run bash -c "
        cd '$tmpdir'
        log_info() { :; }; log_warn() { :; }; log_error() { exit 1; }
        METRICS_NAMESPACE_INCLUDE=''
        METRICS_NAMESPACE_EXCLUDE='dev,staging'
        $func_body
        inject_metrics_namespace_filter
        grep -n 'sourceLabels: \[namespace\]' -A2 k8s-monitoring-values.yaml
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF 'regex: "^(dev|staging)$"'
    echo "$output" | grep -qF "action: drop"
    rm -rf "$tmpdir"
}

@test "inject_metrics_namespace_filter: existing metric-name keep/drop rules are untouched" {
    tmpdir=$(mktemp -d)
    cp "$BATS_TEST_DIRNAME/../k8s-monitoring-values.yaml" "$tmpdir/k8s-monitoring-values.yaml"
    func_body=$(namespace_filter_func)
    run bash -c "
        cd '$tmpdir'
        log_info() { :; }; log_warn() { :; }; log_error() { exit 1; }
        METRICS_NAMESPACE_INCLUDE='production'
        METRICS_NAMESPACE_EXCLUDE=''
        $func_body
        inject_metrics_namespace_filter
        grep -c 'sourceLabels: \[__name__\]' k8s-monitoring-values.yaml
    "
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | tail -1)" -eq 2 ]
    rm -rf "$tmpdir"
}

@test "inject_metrics_namespace_filter: idempotent on re-run (single namespace rule)" {
    tmpdir=$(mktemp -d)
    cp "$BATS_TEST_DIRNAME/../k8s-monitoring-values.yaml" "$tmpdir/k8s-monitoring-values.yaml"
    func_body=$(namespace_filter_func)
    run bash -c "
        cd '$tmpdir'
        log_info() { :; }; log_warn() { :; }; log_error() { exit 1; }
        METRICS_NAMESPACE_INCLUDE='production'
        METRICS_NAMESPACE_EXCLUDE=''
        $func_body
        inject_metrics_namespace_filter
        inject_metrics_namespace_filter
        grep -c 'sourceLabels: \[namespace\]' k8s-monitoring-values.yaml
    "
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | tail -1)" -eq 1 ]
    rm -rf "$tmpdir"
}

@test "inject_metrics_namespace_filter: creates a distinct backup file" {
    tmpdir=$(mktemp -d)
    cp "$BATS_TEST_DIRNAME/../k8s-monitoring-values.yaml" "$tmpdir/k8s-monitoring-values.yaml"
    func_body=$(namespace_filter_func)
    run bash -c "
        cd '$tmpdir'
        log_info() { :; }; log_warn() { :; }; log_error() { exit 1; }
        METRICS_NAMESPACE_INCLUDE='production'
        METRICS_NAMESPACE_EXCLUDE=''
        $func_body
        inject_metrics_namespace_filter
        ls k8s-monitoring-values.yaml.backup-namespace-filter
    "
    [ "$status" -eq 0 ]
    rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# update_deployment_environment / activate_deployment_environment_in_values
# ---------------------------------------------------------------------------

load_deployment_env_helpers() {
    helm()    { :; }
    kubectl() { :; }
    git()     { :; }
    export -f helm kubectl git

    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

    eval "$(awk '/^escape_for_sed\(\)/,/^}/' "$SCRIPT")"
    eval "$(awk '/^activate_deployment_environment_in_values\(\)/,/^}/' "$SCRIPT")"
    eval "$(awk '/^log_error\(\)/,/^}/' "$SCRIPT")"
    eval "$(awk '/^log_warn\(\)/,/^}/' "$SCRIPT")"
    eval "$(awk '/^log_info\(\)/,/^}/' "$SCRIPT")"
    eval "$(awk '/^update_deployment_environment\(\)/,/^}/' "$SCRIPT")"
}

@test "update_deployment_environment: env=production stamps collector, events, instrumentation" {
    tmpdir=$(mktemp -d)
    cp "$BATS_TEST_DIRNAME/../last9-otel-collector-values.yaml" "$tmpdir/"
    cp "$BATS_TEST_DIRNAME/../last9-kube-events-agent-values.yaml" "$tmpdir/"
    cp "$BATS_TEST_DIRNAME/../instrumentation.yaml" "$tmpdir/"

    run bash -c "
        cd '$tmpdir'
        $(declare -f load_deployment_env_helpers 2>/dev/null || true)
        helm() { :; }; kubectl() { :; }; git() { :; }
        RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
        $(awk '/^escape_for_sed\(\)/,/^}/' "$SCRIPT")
        $(awk '/^activate_deployment_environment_in_values\(\)/,/^}/' "$SCRIPT")
        log_info() { :; }; log_warn() { :; }
        log_error() { echo \"[ERROR] \$1\" >&2; exit 1; }
        $(awk '/^update_deployment_environment\(\)/,/^}/' "$SCRIPT")
        update_deployment_environment production
        grep -c 'deployment.environment\", \"production\"' last9-otel-collector-values.yaml
        grep 'resource.attributes\[\"deployment.environment\"\], \"production\"' last9-kube-events-agent-values.yaml
        grep -c 'deployment.environment=production' instrumentation.yaml
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"resource.attributes[\"deployment.environment\"], \"production\""* ]]
    rm -rf "$tmpdir"
}

@test "update_deployment_environment: empty env leaves placeholders unset" {
    tmpdir=$(mktemp -d)
    cp "$BATS_TEST_DIRNAME/../last9-kube-events-agent-values.yaml" "$tmpdir/"

    run bash -c "
        cd '$tmpdir'
        RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
        $(awk '/^escape_for_sed\(\)/,/^}/' "$SCRIPT")
        $(awk '/^activate_deployment_environment_in_values\(\)/,/^}/' "$SCRIPT")
        log_info() { :; }; log_warn() { :; }
        log_error() { echo \"[ERROR] \$1\" >&2; exit 1; }
        $(awk '/^update_deployment_environment\(\)/,/^}/' "$SCRIPT")
        update_deployment_environment ''
        grep '@DEPLOYMENT_ENVIRONMENT@' last9-kube-events-agent-values.yaml
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"@DEPLOYMENT_ENVIRONMENT@"* ]]
    rm -rf "$tmpdir"
}

@test "update_deployment_environment: re-run updates existing OTTL lines" {
    tmpdir=$(mktemp -d)
    cp "$BATS_TEST_DIRNAME/../last9-kube-events-agent-values.yaml" "$tmpdir/"

    run bash -c "
        cd '$tmpdir'
        RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
        $(awk '/^escape_for_sed\(\)/,/^}/' "$SCRIPT")
        $(awk '/^activate_deployment_environment_in_values\(\)/,/^}/' "$SCRIPT")
        log_info() { :; }; log_warn() { :; }
        log_error() { echo \"[ERROR] \$1\" >&2; exit 1; }
        $(awk '/^update_deployment_environment\(\)/,/^}/' "$SCRIPT")
        update_deployment_environment production
        update_deployment_environment staging
        grep 'resource.attributes\[\"deployment.environment\"\], \"staging\"' last9-kube-events-agent-values.yaml
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"staging"* ]]
    rm -rf "$tmpdir"
}

@test "update_deployment_environment: rejects unsafe env values" {
    tmpdir=$(mktemp -d)
    cp "$BATS_TEST_DIRNAME/../last9-kube-events-agent-values.yaml" "$tmpdir/"

    run bash -c "
        cd '$tmpdir'
        RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
        $(awk '/^escape_for_sed\(\)/,/^}/' "$SCRIPT")
        $(awk '/^activate_deployment_environment_in_values\(\)/,/^}/' "$SCRIPT")
        log_info() { :; }; log_warn() { :; }
        log_error() { echo \"[ERROR] \$1\" >&2; exit 1; }
        $(awk '/^update_deployment_environment\(\)/,/^}/' "$SCRIPT")
        update_deployment_environment 'prod\"; malicious'
        echo SHOULD_NOT_REACH
    " 2>&1
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid deployment environment"* ]]
    [[ "$output" != *"SHOULD_NOT_REACH"* ]]
    rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# GKE Autopilot: namespace filtering (standalone script — no sourcing)
# ---------------------------------------------------------------------------

GKE_SCRIPT="$BATS_TEST_DIRNAME/../GCP-Autopilot/last9-otel-setup_gke_autopilot.sh"

@test "gke: validate_namespace_list rejects invalid namespace" {
    run bash -c "
        log_error() { echo \"[ERROR] \$1\" >&2; exit 1; }
        $(awk '/^validate_namespace_list\(\)/,/^}/' "$GKE_SCRIPT")
        validate_namespace_list 'Bad_Namespace'
        echo SHOULD_NOT_REACH
    " 2>&1
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid namespace"* ]]
    [[ "$output" != *"SHOULD_NOT_REACH"* ]]
}

@test "gke: build_namespace_regex matches standard script's output shape" {
    run bash -c "
        $(awk '/^build_namespace_regex\(\)/,/^}/' "$GKE_SCRIPT")
        build_namespace_regex 'production,prod-apps' include
    "
    [ "$status" -eq 0 ]
    [ "$output" = '^(production|prod-apps)?$' ]
}

@test "gke: arg loop sets METRICS_NAMESPACE_INCLUDE from metrics-namespace-include=" {
    run bash -c "
        log_error() { echo \"[ERROR] \$1\" >&2; exit 1; }
        $(awk '/^validate_namespace_list\(\)/,/^}/' "$GKE_SCRIPT")
        METRICS_NAMESPACE_INCLUDE=''
        METRICS_NAMESPACE_EXCLUDE=''
        set -- metrics-namespace-include=production,prod-apps
        $(awk '/^for arg in "\$@"; do/,/^done$/' "$GKE_SCRIPT")
        echo \"INCLUDE=\$METRICS_NAMESPACE_INCLUDE\"
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "INCLUDE=production,prod-apps"
}

@test "gke: both include and exclude set is a hard error" {
    run bash -c "
        log_error() { echo \"[ERROR] \$1\" >&2; exit 1; }
        $(awk '/^validate_namespace_list\(\)/,/^}/' "$GKE_SCRIPT")
        $(awk '/^check_namespace_filter_mutual_exclusion\(\)/,/^}/' "$GKE_SCRIPT")
        METRICS_NAMESPACE_INCLUDE='production'
        METRICS_NAMESPACE_EXCLUDE='dev'
        check_namespace_filter_mutual_exclusion
        echo SHOULD_NOT_REACH
    " 2>&1
    [ "$status" -eq 1 ]
    [[ "$output" == *"both"* ]] || [[ "$output" == *"mutually exclusive"* ]]
    [[ "$output" != *"SHOULD_NOT_REACH"* ]]
}

@test "gke: replace_placeholders injects namespace filter into temp file, leaves source untouched" {
    tmpdir=$(mktemp -d)
    cp "$BATS_TEST_DIRNAME/../GCP-Autopilot/k8s-monitoring-values.yaml" "$tmpdir/k8s-monitoring-values.yaml"
    cp "$tmpdir/k8s-monitoring-values.yaml" "$tmpdir/orig.yaml"
    run bash -c "
        cd '$tmpdir'
        log_info() { :; }; log_warn() { :; }; log_error() { exit 1; }
        kubectl() { echo 'gke-cluster'; }
        AUTH_TOKEN='t'; OTEL_ENDPOINT='e'; MONITORING_ENDPOINT='m'
        DEPLOYMENT_ENV=''
        METRICS_NAMESPACE_INCLUDE='production'
        METRICS_NAMESPACE_EXCLUDE=''
        $(awk '/^build_namespace_regex\(\)/,/^}/' "$GKE_SCRIPT")
        $(awk '/^replace_placeholders\(\)/,/^}/' "$GKE_SCRIPT")
        out=\$(replace_placeholders k8s-monitoring-values.yaml)
        grep -n 'sourceLabels: \[namespace\]' -A2 \"\$out\"
        diff orig.yaml k8s-monitoring-values.yaml && echo SOURCE_UNCHANGED
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF 'regex: "^(production)?$"'
    [[ "$output" == *"SOURCE_UNCHANGED"* ]]
    rm -rf "$tmpdir"
}
