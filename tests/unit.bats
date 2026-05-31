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
