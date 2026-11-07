#!/bin/bash

# OpenTelemetry Setup Automation Script
# Usage:
#    Show all options
#    ./last9-otel-setup.sh

#    Option 1: Install Everything (Recommended - Logs, Traces, Cluster Monitoring and Events)
#    ./last9-otel-setup.sh token="your-token-here" endpoint="your-endpoint-here" monitoring-endpoint="your-metrics-endpoint" username="your-username" password="your-password"

#    Option 2: For Traces alone --> Install OpenTelemetry Operator and collector
#    ./last9-otel-setup.sh operator-only endpoint="your-endpoint-here" token="your-token-here"

#    Option 3: For Logs use case --> Install Only Collector for Logs (No Operator)
#    ./last9-otel-setup.sh logs-only endpoint="your-endpoint-here" token="your-token-here"

#    Option 4: Install Only Cluster Monitoring (Using Metrics)
#    ./last9-otel-setup.sh monitoring-only monitoring-endpoint="your-metrics-endpoint" username="your-username" password="your-password"

#    Option 5: Install Only Kubernetes Events Agent
#    ./last9-otel-setup.sh events-only

#    Uninstall All components
#    ./last9-otel-setup.sh uninstall-all

# Quick Install (one-liner):
#    curl -fsSL https://raw.githubusercontent.com/last9/l9-otel-operator/main/last9-otel-setup.sh | bash -s -- token="your-token" endpoint="your-endpoint" monitoring-endpoint="your-metrics-endpoint" username="user" password="pass"

set -e  # Exit on any error

# Configuration defaults
NAMESPACE="last9"
OPERATOR_VERSION="0.92.1"
COLLECTOR_VERSION="0.165.0"
MONITORING_VERSION="75.15.1"
TA_VERSION="0.156.0"

WORK_DIR="l9-otel-setup-$(date +%s)"
DEFAULT_REPO="https://github.com/last9/l9-otel-operator.git"
ORIGINAL_DIR="$(pwd)"

# Initialize variables
AUTH_TOKEN=""
OTEL_ENDPOINT=""
MONITORING_ENDPOINT=""
APP_METRICS_KEEP=""
REPO_URL="$DEFAULT_REPO"
UNINSTALL_MODE=false
FUNCTION_TO_EXECUTE=""
VALUES_FILE=""
SETUP_MONITORING=true
CLUSTER_NAME=""
LAST9_USERNAME=""
LAST9_PASSWORD=""
OPERATOR_ONLY=false
LOGS_ONLY=false
MONITORING_ONLY=false
EVENTS_ONLY=false
TOLERATIONS_FILE=""
USE_YQ=false
DEPLOYMENT_ENV=""
KUBE_CONTEXT=""
EXISTING_PROMETHEUS_OPERATOR=""
EXISTING_PROMETHEUS_OPERATOR_IMAGE=""
SERVER_NAME=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

# Helper function to escape special characters for sed
escape_for_sed() {
    printf '%s\n' "$1" | sed 's:[[\.*^$()+?{|/]:\\&:g'
}

# Activate or update deployment.environment in an OTTL values YAML file.
# Replaces @DEPLOYMENT_ENVIRONMENT@ placeholders and updates existing OTTL set
# lines so re-running with a different env= is idempotent.
# $1 = file path, $2 = env value, $3 = "attributes" or "resource.attributes"
activate_deployment_environment_in_values() {
    local file="$1" env="$2" scope="$3"
    local escaped_env ottl_target
    escaped_env=$(escape_for_sed "$env")
    case "$scope" in
        attributes)
            ottl_target='attributes\["deployment.environment"\]'
            ;;
        resource.attributes)
            ottl_target='resource\.attributes\["deployment.environment"\]'
            ;;
        *)
            log_error "Invalid OTTL scope for deployment.environment: $scope"
            ;;
    esac

    sed -i.tmp \
        -e "s|^\([[:space:]]*\)- set(${ottl_target}, \"[^\"]*\")|\1- set(${ottl_target}, \"${escaped_env}\")|" \
        -e "s|^\([[:space:]]*\)# @DEPLOYMENT_ENVIRONMENT@.*|\1- set(${ottl_target}, \"${escaped_env}\")|" \
        "$file"
    rm -f "${file}.tmp"
}

# Check if yq is available
check_yq_available() {
    if command -v yq >/dev/null 2>&1; then
        USE_YQ=true
        log_info "✓ yq found: $(yq --version 2>&1 | head -n1)"
    else
        USE_YQ=false
        log_warn "⚠ yq not found - using awk/sed fallback for YAML parsing"
        log_warn "  For better reliability, install yq:"
        log_warn "  - macOS: brew install yq"
        log_warn "  - Linux: download yq for your arch (yq_linux_amd64 or yq_linux_arm64) from https://github.com/mikefarah/yq/releases/latest, then chmod +x and place on PATH"
    fi
}

# Extract a human-readable cluster name from a raw kubectl context string.
# EKS contexts are ARNs: arn:aws:eks:<region>:<account>:cluster/<name>
# GKE contexts: gke_<project>_<region>_<name>  — returned as-is (already readable)
# Plain names are returned unchanged.
sanitize_cluster_name() {
    local raw="$1"
    if echo "$raw" | grep -q "^arn:"; then
        # Extract the segment after the last /
        echo "$raw" | sed 's|.*/||'
    else
        echo "$raw"
    fi
}

# Detect host CPU architecture and package manager for EC2 binary installs.
# Sets HOST_ARCH (amd64|arm64) and HOST_PKG (deb|rpm) with matching
# HOST_PKG_CMD (dpkg -i|rpm -ivh) and HOST_PKG_EXT (.deb|.rpm).
HOST_ARCH=""
HOST_PKG=""
HOST_PKG_CMD=""
HOST_PKG_EXT=""
detect_host_platform() {
    local raw_arch
    raw_arch=$(uname -m 2>/dev/null || echo "x86_64")
    case "$raw_arch" in
        aarch64|arm64) HOST_ARCH="arm64" ;;
        x86_64|amd64)  HOST_ARCH="amd64" ;;
        *)
            log_warn "Unknown CPU architecture '$raw_arch' — defaulting to amd64"
            HOST_ARCH="amd64"
            ;;
    esac

    if command -v apt-get >/dev/null 2>&1; then
        HOST_PKG="deb"
        HOST_PKG_CMD="dpkg -i"
        HOST_PKG_EXT=".deb"
    elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
        HOST_PKG="rpm"
        HOST_PKG_CMD="rpm -ivh"
        HOST_PKG_EXT=".rpm"
    else
        log_warn "Could not detect package manager — defaulting to deb"
        HOST_PKG="deb"
        HOST_PKG_CMD="dpkg -i"
        HOST_PKG_EXT=".deb"
    fi

    log_info "Host platform: arch=${HOST_ARCH} pkg=${HOST_PKG}"
}

# Enable --skip-schema-validation whenever the installed Helm supports it.
#
# Helm 3.18.5+ (and Helm v4) enforce strict JSON Schema *metaschema* validation
# (Draft 2019-09) against a chart's own values.schema.json. Upstream charts with
# minor schema-spec violations are then rejected before install — e.g. the
# opentelemetry-operator chart declares `manager.featureGates.examples` as a
# string when the metaschema requires an array, producing:
#   "...values.schema.json#" is not valid against metaschema ... 'examples': got string, want array
# --skip-schema-validation (available since Helm 3.16) makes install/upgrade skip
# that validation entirely; Kubernetes admission controllers still validate every
# rendered resource, so this is safe.
#
# We probe for the flag's availability via `helm upgrade --help` rather than
# parsing version numbers. Version gating is fragile: the previous "major >= 4"
# check passed on developer machines running Helm v4 but silently left every
# customer on Helm 3.18.5–3.x exposed to the failure above.
HELM_SCHEMA_FLAG=""
detect_helm_schema_flag() {
    if helm upgrade --help 2>/dev/null | grep -q -- '--skip-schema-validation'; then
        HELM_SCHEMA_FLAG="--skip-schema-validation"
        log_info "Helm supports --skip-schema-validation — enabling it to tolerate upstream chart schema quirks"
    fi
}

# Return the Last9 OTLP exporter map key in a collector values file (otlp_grpc/last9
# or legacy otlp/last9). Empty when neither is present.
_collector_last9_exporter_key() {
    local file="$1"
    if grep -qE '^    otlp_grpc/last9:[[:space:]]*$' "$file"; then
        printf '%s' 'otlp_grpc/last9'
    elif grep -qE '^    otlp/last9:[[:space:]]*$' "$file"; then
        printf '%s' 'otlp/last9'
    fi
}

# True when a values file still uses pre-0.156 collector component names.
_collector_values_has_legacy_keys() {
    local file="$1"
    grep -qE '^[[:space:]]*otlp/last9:|^[[:space:]]*- otlp/last9$|^[[:space:]]*k8sattributes:|^[[:space:]]*- k8sattributes$|^[[:space:]]*k8sobjects(/topology)?:|^[[:space:]]*- k8sobjects$' "$file"
}

# True when presets.kubernetesEvents.enabled is true (deprecated with chart 0.165+).
_collector_values_has_kubernetes_events_preset_enabled() {
    local file="$1"
    [ -f "$file" ] || return 1
    awk '/^  kubernetesEvents:/{f=1} f && /^    enabled: true/{found=1; exit} END{exit !found}' "$file"
}

# Compare dotted version strings (e.g. 0.126.0 < 0.165.0).
version_lt() {
    local a="$1" b="$2"
    [ "$(printf '%s\n' "$a" "$b" | sort -V | head -1)" = "$a" ] && [ "$a" != "$b" ]
}

_helm_release_exists() {
    local release="$1" ns="$2"
    helm list -n "$ns" --filter "^${release}$" -q 2>/dev/null | grep -qx "$release"
}

# Chart version from an installed Helm release (e.g. 0.126.0), or empty when absent.
_helm_release_chart_version() {
    local release="$1" ns="$2"
    helm list -n "$ns" --filter "^${release}$" -o json 2>/dev/null \
        | tr -d '\n' \
        | sed -n 's/.*"chart":"[^"]*-\([^"]*\)".*/\1/p' \
        | head -1
}

# Migrate deprecated OTel collector config keys in a helm values file so chart
# 0.165.0 / collector 0.156.0 accept custom -f overrides from pre-0.156 installs.
# Idempotent — safe on already-migrated files (no-op).
migrate_collector_values_for_0165() {
    local file="$1"

    [ -f "$file" ] || return 0

    if ! _collector_values_has_legacy_keys "$file"; then
        return 0
    fi

    log_info "Migrating deprecated collector config keys in $file for chart $COLLECTOR_VERSION..."

    if [ ! -f "${file}.backup-migrate" ]; then
        cp "$file" "${file}.backup-migrate"
        log_info "Created backup: ${file}.backup-migrate"
    fi

    # Order matters: longest/most-specific patterns first.
    sed -i.tmp \
        -e 's|k8sobjects/topology|k8s_objects/topology|g' \
        -e 's|otlp/last9|otlp_grpc/last9|g' \
        -e 's|k8sattributes|k8s_attributes|g' \
        -e 's|k8sobjects|k8s_objects|g' \
        "$file"
    rm -f "${file}.tmp"

    log_info "✓ Migrated $file (otlp→otlp_grpc, k8sattributes→k8s_attributes, k8sobjects→k8s_objects)"
}

# Pre-upgrade sanity checks for collector chart installs. When an existing release
# is detected, call out the upgrade path and any values issues before helm runs.
# Optional release_name — omit on fresh installs that have no release yet.
prepare_collector_values_file() {
    local values_file="$1"
    local release_name="${2:-}"
    local component_label="${3:-OpenTelemetry Collector}"

    [ -f "$values_file" ] || return 0

    local current_chart=""
    if [ -n "$release_name" ] && _helm_release_exists "$release_name" "$NAMESPACE"; then
        current_chart=$(_helm_release_chart_version "$release_name" "$NAMESPACE")
        log_warn "Upgrade detected: $component_label release '$release_name' is already installed."
        if [ -n "$current_chart" ]; then
            log_warn "  Current chart: opentelemetry-collector-$current_chart → target: $COLLECTOR_VERSION (collector image 0.156.0)."
            if version_lt "$current_chart" "0.165.0"; then
                log_warn "  Chart <$COLLECTOR_VERSION uses renamed collector components (otlp_grpc, k8s_attributes, k8s_objects)."
            fi
        else
            log_warn "  Upgrading to opentelemetry-collector chart $COLLECTOR_VERSION (collector image 0.156.0)."
        fi
        log_warn "  Expect a one-time collector pod restart during the upgrade."
    fi

    if _collector_values_has_legacy_keys "$values_file"; then
        log_warn "  $values_file uses deprecated collector config keys (otlp/last9, k8sattributes, and/or k8sobjects)."
        log_warn "  These will be rewritten automatically; backup saved as ${values_file}.backup-migrate."
    fi

    if _collector_values_has_kubernetes_events_preset_enabled "$values_file"; then
        log_warn "  $values_file has presets.kubernetesEvents.enabled: true (removed in chart $COLLECTOR_VERSION)."
        log_warn "  Disable that preset and configure an explicit k8s_objects receiver — see bundled last9-kube-events-agent-values.yaml."
    fi

    migrate_collector_values_for_0165 "$values_file"

    if _collector_values_has_kubernetes_events_preset_enabled "$values_file"; then
        log_warn "  Action required before upgrade can succeed: disable presets.kubernetesEvents in $values_file."
    fi
}

# Retry helm upgrade --install on transient failures (chart download 5xx, network blips).
# All arguments are forwarded verbatim to `helm upgrade --install`.
helm_upgrade_install_with_retry() {
    local max_attempts="${HELM_INSTALL_RETRIES:-3}"
    local attempt=1
    local delay="${HELM_INSTALL_RETRY_DELAY:-5}"

    while [ "$attempt" -le "$max_attempts" ]; do
        if helm upgrade --install "$@"; then
            return 0
        fi
        if [ "$attempt" -lt "$max_attempts" ]; then
            log_warn "Helm upgrade --install failed (attempt ${attempt}/${max_attempts}); retrying in ${delay}s..."
            sleep "$delay"
            delay=$((delay * 2))
        fi
        attempt=$((attempt + 1))
    done
    return 1
}

# Load and parse tolerations from YAML file
load_tolerations_from_file() {
    local file_path="$1"

    log_info "Loading tolerations from file: $file_path"

    # Validate file exists and is readable
    if [ ! -f "$file_path" ]; then
        log_error "Tolerations file not found: $file_path"
    fi

    if [ ! -r "$file_path" ]; then
        log_error "Tolerations file is not readable: $file_path"
    fi

    # Check for yq
    check_yq_available

    log_info "✓ Tolerations file loaded successfully"

    # Store the file path for later use
    export TOLERATIONS_FILE_PATH="$file_path"
}

# Convert tolerations from YAML to Helm --set format
convert_tolerations_to_helm_set() {
    local file_path="$1"
    local prefix="$2"  # e.g., "" for operator, "manager" for other charts
    local helm_args=""
    local path_prefix=""

    # Add dot separator only if prefix is not empty
    [ -n "$prefix" ] && path_prefix="${prefix}."

    if [ "$USE_YQ" = true ]; then
        # Use yq to parse YAML and convert to --set format
        local count=0
        local tolerations_count=$(yq eval '.tolerations | length' "$file_path" 2>/dev/null || echo "0")

        if [ "$tolerations_count" != "0" ] && [ "$tolerations_count" != "null" ]; then
            while [ $count -lt $tolerations_count ]; do
                local key=$(yq eval ".tolerations[$count].key" "$file_path" 2>/dev/null)
                local operator=$(yq eval ".tolerations[$count].operator" "$file_path" 2>/dev/null)
                local value=$(yq eval ".tolerations[$count].value" "$file_path" 2>/dev/null)
                local effect=$(yq eval ".tolerations[$count].effect" "$file_path" 2>/dev/null)

                if [ "$key" != "null" ]; then
                    helm_args="$helm_args --set-string ${path_prefix}tolerations[$count].key=$key"
                    helm_args="$helm_args --set-string ${path_prefix}tolerations[$count].operator=$operator"
                    [ "$value" != "null" ] && helm_args="$helm_args --set-string ${path_prefix}tolerations[$count].value=$value"
                    [ "$effect" != "null" ] && helm_args="$helm_args --set-string ${path_prefix}tolerations[$count].effect=$effect"
                fi

                count=$((count + 1))
            done
        fi
    else
        # Awk fallback for parsing YAML
        log_warn "Using awk fallback for tolerations parsing"

        local in_tolerations=false
        local count=0
        local current_key=""
        local current_operator=""
        local current_value=""
        local current_effect=""

        while IFS= read -r line; do
            # Check if we're in the tolerations section
            if echo "$line" | grep -q "^tolerations:"; then
                in_tolerations=true
                continue
            fi

            # Exit tolerations section if we hit another top-level key
            if echo "$line" | grep -q "^[a-zA-Z]" && [ "$in_tolerations" = true ]; then
                in_tolerations=false
            fi

            if [ "$in_tolerations" = true ]; then
                # Parse toleration entry
                if echo "$line" | grep -q "^  - key:"; then
                    # Save previous entry if exists
                    if [ -n "$current_key" ]; then
                        helm_args="$helm_args --set-string ${path_prefix}tolerations[$count].key=$current_key"
                        helm_args="$helm_args --set-string ${path_prefix}tolerations[$count].operator=$current_operator"
                        [ -n "$current_value" ] && helm_args="$helm_args --set-string ${path_prefix}tolerations[$count].value=$current_value"
                        [ -n "$current_effect" ] && helm_args="$helm_args --set-string ${path_prefix}tolerations[$count].effect=$current_effect"
                        count=$((count + 1))
                    fi

                    # Start new entry
                    current_key=$(echo "$line" | sed -E 's/.*key: *"?([^"]*)"?.*/\1/')
                    current_operator=""
                    current_value=""
                    current_effect=""
                elif echo "$line" | grep -q "operator:"; then
                    current_operator=$(echo "$line" | sed -E 's/.*operator: *"?([^"]*)"?.*/\1/')
                elif echo "$line" | grep -q "value:"; then
                    current_value=$(echo "$line" | sed -E 's/.*value: *"?([^"]*)"?.*/\1/')
                elif echo "$line" | grep -q "effect:"; then
                    current_effect=$(echo "$line" | sed -E 's/.*effect: *"?([^"]*)"?.*/\1/')
                fi
            fi
        done < "$file_path"

        # Save last entry
        if [ -n "$current_key" ]; then
            helm_args="$helm_args --set-string ${path_prefix}tolerations[$count].key=$current_key"
            helm_args="$helm_args --set-string ${path_prefix}tolerations[$count].operator=$current_operator"
            [ -n "$current_value" ] && helm_args="$helm_args --set-string ${path_prefix}tolerations[$count].value=$current_value"
            [ -n "$current_effect" ] && helm_args="$helm_args --set-string ${path_prefix}tolerations[$count].effect=$current_effect"
        fi
    fi

    echo "$helm_args"
}

# Convert nodeSelector from YAML to Helm --set format
convert_node_selector_to_helm_set() {
    local file_path="$1"
    local prefix="$2"  # e.g., "" for operator, "manager" for other charts
    local helm_args=""
    local path_prefix=""

    # Add dot separator only if prefix is not empty
    [ -n "$prefix" ] && path_prefix="${prefix}."

    if [ "$USE_YQ" = true ]; then
        # Check if nodeSelector exists and is not empty
        local has_selector=$(yq eval '.nodeSelector | length' "$file_path" 2>/dev/null || echo "0")

        if [ "$has_selector" != "0" ] && [ "$has_selector" != "null" ]; then
            # Get all keys
            local keys=$(yq eval '.nodeSelector | keys | .[]' "$file_path" 2>/dev/null)

            while IFS= read -r key; do
                if [ -n "$key" ]; then
                    local value=$(yq eval ".nodeSelector.\"$key\"" "$file_path" 2>/dev/null)
                    # Escape special characters in key for Helm --set
                    local escaped_key=$(echo "$key" | sed 's/\./\\./g')
                    # Use --set-string to force string interpretation (prevents boolean conversion)
                    helm_args="$helm_args --set-string ${path_prefix}nodeSelector.${escaped_key}=$value"
                fi
            done <<< "$keys"
        fi
    else
        # Awk fallback for nodeSelector parsing
        local in_selector=false

        while IFS= read -r line; do
            if echo "$line" | grep -q "^nodeSelector:"; then
                in_selector=true
                # Check if it's empty object
                if echo "$line" | grep -q "nodeSelector: {}"; then
                    break
                fi
                continue
            fi

            # Exit nodeSelector section
            if echo "$line" | grep -q "^[a-zA-Z]" && [ "$in_selector" = true ]; then
                break
            fi

            if [ "$in_selector" = true ]; then
                # Parse key: value
                if echo "$line" | grep -q ":"; then
                    local key=$(echo "$line" | sed -E 's/^ *([^:]+):.*/\1/' | tr -d '"')
                    local value=$(echo "$line" | sed -E 's/.*: *"?([^"]*)"?.*/\1/')

                    if [ -n "$key" ]; then
                        local escaped_key=$(echo "$key" | sed 's/\./\\./g')
                        # Use --set-string to force string interpretation (prevents boolean conversion)
                        helm_args="$helm_args --set-string ${path_prefix}nodeSelector.${escaped_key}=$value"
                    fi
                fi
            fi
        done < "$file_path"
    fi

    echo "$helm_args"
}

# Apply tolerations to collector values file
apply_tolerations_to_collector_values() {
    local values_file="$1"
    local tolerations_file="$TOLERATIONS_FILE_PATH"

    log_info "Applying tolerations to collector values file: $values_file"

    # Create backup
    cp "$values_file" "${values_file}.backup-tolerations"
    log_info "Created backup: ${values_file}.backup-tolerations"

    if [ "$USE_YQ" = true ]; then
        # Use yq for precise YAML manipulation

        # Apply tolerations
        local has_tolerations=$(yq eval '.tolerations | length' "$tolerations_file" 2>/dev/null || echo "0")
        if [ "$has_tolerations" != "0" ] && [ "$has_tolerations" != "null" ]; then
            log_info "Applying tolerations array to collector values..."
            yq eval-all 'select(fileIndex == 0).tolerations = select(fileIndex == 1).tolerations | select(fileIndex == 0)' \
                "$values_file" "$tolerations_file" > "${values_file}.tmp"
            mv "${values_file}.tmp" "$values_file"
        fi

        # Apply nodeSelector
        local has_selector=$(yq eval '.nodeSelector | length' "$tolerations_file" 2>/dev/null || echo "0")
        if [ "$has_selector" != "0" ] && [ "$has_selector" != "null" ]; then
            log_info "Applying nodeSelector to collector values..."
            yq eval-all 'select(fileIndex == 0).nodeSelector = select(fileIndex == 1).nodeSelector | select(fileIndex == 0)' \
                "$values_file" "$tolerations_file" > "${values_file}.tmp"
            mv "${values_file}.tmp" "$values_file"
        fi
    else
        # Awk fallback - replace tolerations: [] and nodeSelector: {}
        log_warn "Using awk fallback for collector values injection"

        # Extract tolerations from file and format as YAML
        local tolerations_yaml=""
        local in_tolerations=false
        while IFS= read -r line; do
            if echo "$line" | grep -q "^tolerations:"; then
                in_tolerations=true
                continue
            fi
            if echo "$line" | grep -q "^[a-zA-Z]" && [ "$in_tolerations" = true ]; then
                break
            fi
            if [ "$in_tolerations" = true ]; then
                tolerations_yaml="${tolerations_yaml}${line}\n"
            fi
        done < "$tolerations_file"

        # Replace in values file
        if [ -n "$tolerations_yaml" ]; then
            awk -v tol="$tolerations_yaml" '
            /^tolerations: \[\]/ {
                print "tolerations:"
                printf "%s", tol
                next
            }
            {print}
            ' "$values_file" > "${values_file}.tmp"
            mv "${values_file}.tmp" "$values_file"
        fi

        # Extract and apply nodeSelector
        local selector_yaml=""
        local in_selector=false
        while IFS= read -r line; do
            if echo "$line" | grep -q "^nodeSelector:"; then
                in_selector=true
                if echo "$line" | grep -q "nodeSelector: {}"; then
                    break
                fi
                continue
            fi
            if echo "$line" | grep -q "^[a-zA-Z]" && [ "$in_selector" = true ]; then
                break
            fi
            if [ "$in_selector" = true ]; then
                selector_yaml="${selector_yaml}${line}\n"
            fi
        done < "$tolerations_file"

        if [ -n "$selector_yaml" ]; then
            awk -v sel="$selector_yaml" '
            /^nodeSelector: \{\}/ {
                print "nodeSelector:"
                printf "%s", sel
                next
            }
            {print}
            ' "$values_file" > "${values_file}.tmp"
            mv "${values_file}.tmp" "$values_file"
        fi
    fi

    log_info "✓ Tolerations applied to collector values file"
}

# Apply tolerations to monitoring values file
apply_tolerations_to_monitoring_values() {
    local values_file="$1"
    local tolerations_file="$TOLERATIONS_FILE_PATH"

    log_info "Applying tolerations to monitoring values file: $values_file"

    # Create backup
    cp "$values_file" "${values_file}.backup-tolerations"
    log_info "Created backup: ${values_file}.backup-tolerations"

    if [ "$USE_YQ" = true ]; then
        # Apply to Prometheus
        local has_tolerations=$(yq eval '.tolerations | length' "$tolerations_file" 2>/dev/null || echo "0")
        if [ "$has_tolerations" != "0" ] && [ "$has_tolerations" != "null" ]; then
            log_info "Applying tolerations to prometheus.prometheusSpec..."
            yq eval ".prometheus.prometheusSpec.tolerations = $(yq eval '.tolerations' "$tolerations_file")" -i "$values_file"

            log_info "Applying tolerations to kubeStateMetrics..."
            yq eval ".kubeStateMetrics.tolerations = $(yq eval '.tolerations' "$tolerations_file")" -i "$values_file"

            log_info "Applying tolerations to prometheusOperator..."
            yq eval ".prometheusOperator.tolerations = $(yq eval '.tolerations' "$tolerations_file")" -i "$values_file"
        fi

        # Apply nodeSelector
        local has_selector=$(yq eval '.nodeSelector | length' "$tolerations_file" 2>/dev/null || echo "0")
        if [ "$has_selector" != "0" ] && [ "$has_selector" != "null" ]; then
            log_info "Applying nodeSelector to prometheus.prometheusSpec..."
            yq eval ".prometheus.prometheusSpec.nodeSelector = $(yq eval '.nodeSelector' "$tolerations_file")" -i "$values_file"

            log_info "Applying nodeSelector to kubeStateMetrics..."
            yq eval ".kubeStateMetrics.nodeSelector = $(yq eval '.nodeSelector' "$tolerations_file")" -i "$values_file"

            log_info "Applying nodeSelector to prometheusOperator..."
            yq eval ".prometheusOperator.nodeSelector = $(yq eval '.nodeSelector' "$tolerations_file")" -i "$values_file"
        fi

        # Special handling for node-exporter - check for nodeExporterTolerations
        local has_node_exporter_tol=$(yq eval '.nodeExporterTolerations | length' "$tolerations_file" 2>/dev/null || echo "0")
        if [ "$has_node_exporter_tol" != "0" ] && [ "$has_node_exporter_tol" != "null" ]; then
            log_info "Applying special nodeExporterTolerations..."
            yq eval ".nodeExporter.tolerations = $(yq eval '.nodeExporterTolerations' "$tolerations_file")" -i "$values_file"
        else
            # Default: operator Exists (run on all nodes)
            log_info "Applying default permissive tolerations to node-exporter (operator: Exists)..."
            yq eval '.nodeExporter.tolerations = [{"operator": "Exists"}]' -i "$values_file"
        fi
    else
        # Awk fallback - using sed for simpler and more reliable injection
        log_warn "Using awk/sed fallback for monitoring values injection"

        # Create temp file for extracted sections
        local temp_dir=$(mktemp -d)
        local tol_file="$temp_dir/tolerations.txt"
        local ns_file="$temp_dir/nodeselector.txt"
        local ne_tol_file="$temp_dir/ne_tolerations.txt"

        # Extract sections from tolerations file
        awk '/^tolerations:/{flag=1; next} /^[a-zA-Z]/{flag=0} flag && NF' "$tolerations_file" > "$tol_file"
        awk '/^nodeSelector:/{flag=1; next} /^[a-zA-Z]/{flag=0} flag && NF && !/^#/' "$tolerations_file" > "$ns_file"
        awk '/^nodeExporterTolerations:/{flag=1; next} /^[a-zA-Z]/{flag=0} flag && NF' "$tolerations_file" > "$ne_tol_file"

        # Apply to prometheusOperator using sed
        if [ -s "$tol_file" ]; then
            log_info "Injecting tolerations to prometheusOperator..."
            # Find prometheusOperator: and insert tolerations after it
            sed '/^prometheusOperator:/a\
  tolerations:
' "$values_file" > "${values_file}.tmp1"
            # Now insert the actual toleration content
            awk -v tol_file="$tol_file" '
                /^prometheusOperator:/ {print; getline; print
                    while ((getline line < tol_file) > 0) {
                        print "  " line
                    }
                    close(tol_file)
                    next
                }
                {print}
            ' "${values_file}.tmp1" > "${values_file}.tmp"
            mv "${values_file}.tmp" "$values_file"
            rm -f "${values_file}.tmp1"
        fi

        # Apply to kubeStateMetrics
        if [ -s "$tol_file" ]; then
            log_info "Injecting tolerations to kubeStateMetrics..."
            sed '/^kubeStateMetrics:/a\
  tolerations:
' "$values_file" > "${values_file}.tmp1"
            awk -v tol_file="$tol_file" '
                /^kubeStateMetrics:/ {print; getline; print
                    while ((getline line < tol_file) > 0) {
                        print "  " line
                    }
                    close(tol_file)
                    next
                }
                {print}
            ' "${values_file}.tmp1" > "${values_file}.tmp"
            mv "${values_file}.tmp" "$values_file"
            rm -f "${values_file}.tmp1"
        fi

        # Apply nodeSelector to prometheusOperator
        if [ -s "$ns_file" ]; then
            log_info "Injecting nodeSelector to prometheusOperator..."
            sed '/^prometheusOperator:/a\
  nodeSelector:
' "$values_file" > "${values_file}.tmp1"
            awk -v ns_file="$ns_file" '
                /^prometheusOperator:/ {print; getline; print
                    while ((getline line < ns_file) > 0) {
                        print "  " line
                    }
                    close(ns_file)
                    next
                }
                {print}
            ' "${values_file}.tmp1" > "${values_file}.tmp"
            mv "${values_file}.tmp" "$values_file"
            rm -f "${values_file}.tmp1"
        fi

        # Apply nodeSelector to kubeStateMetrics
        if [ -s "$ns_file" ]; then
            log_info "Injecting nodeSelector to kubeStateMetrics..."
            sed '/^kubeStateMetrics:/a\
  nodeSelector:
' "$values_file" > "${values_file}.tmp1"
            awk -v ns_file="$ns_file" '
                /^kubeStateMetrics:/ {print; getline; print
                    while ((getline line < ns_file) > 0) {
                        print "  " line
                    }
                    close(ns_file)
                    next
                }
                {print}
            ' "${values_file}.tmp1" > "${values_file}.tmp"
            mv "${values_file}.tmp" "$values_file"
            rm -f "${values_file}.tmp1"
        fi

        # Apply node-exporter tolerations
        if [ -s "$ne_tol_file" ]; then
            log_info "Injecting nodeExporterTolerations..."
            sed '/^nodeExporter:/a\
  tolerations:
' "$values_file" > "${values_file}.tmp1"
            awk -v ne_file="$ne_tol_file" '
                /^nodeExporter:/ {print; getline; print
                    while ((getline line < ne_file) > 0) {
                        print "  " line
                    }
                    close(ne_file)
                    next
                }
                {print}
            ' "${values_file}.tmp1" > "${values_file}.tmp"
            mv "${values_file}.tmp" "$values_file"
            rm -f "${values_file}.tmp1"
        else
            log_info "Applying default permissive tolerations to node-exporter (operator: Exists)..."
            sed '/^nodeExporter:/a\
  tolerations:\
    - operator: Exists
' "$values_file" > "${values_file}.tmp"
            mv "${values_file}.tmp" "$values_file"
        fi

        # Cleanup temp files
        rm -rf "$temp_dir"

        log_info "✓ Awk/sed fallback completed"
    fi

    log_info "✓ Tolerations applied to monitoring values file"
}

# Function to patch monitoring components with tolerations and nodeSelector directly via kubectl
# This handles components that don't properly inherit tolerations from Helm values
# This is the primary method for applying tolerations/nodeSelector (more reliable than Helm values)
patch_monitoring_components_tolerations() {
    local tolerations_file="$TOLERATIONS_FILE_PATH"

    if [ -z "$tolerations_file" ]; then
        log_info "No tolerations file provided, skipping component patching"
        return 0
    fi

    log_info "Patching monitoring components with tolerations and nodeSelector from Kubernetes API..."

    # Extract tolerations in JSON format for kubectl patch
    local tolerations_json=""
    local node_exporter_tolerations_json=""
    local node_selector_json=""

    if [ "$USE_YQ" = true ]; then
        # Use yq to convert YAML to JSON
        tolerations_json=$(yq eval '.tolerations' "$tolerations_file" -o=json 2>/dev/null)
        if [ "$tolerations_json" = "null" ] || [ -z "$tolerations_json" ]; then
            log_warn "No tolerations found in file"
            tolerations_json=""
        fi

        # Check for special nodeExporterTolerations
        node_exporter_tolerations_json=$(yq eval '.nodeExporterTolerations' "$tolerations_file" -o=json 2>/dev/null)
        if [ "$node_exporter_tolerations_json" = "null" ] || [ -z "$node_exporter_tolerations_json" ]; then
            # Default: operator Exists (run on all nodes)
            node_exporter_tolerations_json='[{"operator":"Exists"}]'
        fi

        # Extract nodeSelector
        node_selector_json=$(yq eval '.nodeSelector' "$tolerations_file" -o=json 2>/dev/null)
        if [ "$node_selector_json" = "null" ] || [ -z "$node_selector_json" ]; then
            node_selector_json=""
        fi
    else
        # Awk fallback - build JSON manually
        log_warn "Using awk fallback to build JSON patch"

        local temp_file=$(mktemp)
        awk '/^tolerations:/{flag=1; next} /^[a-zA-Z]/{flag=0} flag && NF' "$tolerations_file" > "$temp_file"

        if [ -s "$temp_file" ]; then
            # Build JSON array from YAML tolerations
            tolerations_json="["
            local first=true
            local current_obj=""

            while IFS= read -r line; do
                if echo "$line" | grep -q "^  - key:"; then
                    # Start of new toleration object
                    if [ "$first" = false ]; then
                        tolerations_json="${tolerations_json},"
                    fi
                    first=false
                    local key=$(echo "$line" | sed -E 's/.*key: *"?([^"]*)"?.*/\1/')
                    current_obj="{\"key\":\"$key\""
                elif echo "$line" | grep -q "operator:"; then
                    local op=$(echo "$line" | sed -E 's/.*operator: *"?([^"]*)"?.*/\1/')
                    current_obj="${current_obj},\"operator\":\"$op\""
                elif echo "$line" | grep -q "value:"; then
                    local val=$(echo "$line" | sed -E 's/.*value: *"?([^"]*)"?.*/\1/')
                    current_obj="${current_obj},\"value\":\"$val\""
                elif echo "$line" | grep -q "effect:"; then
                    local eff=$(echo "$line" | sed -E 's/.*effect: *"?([^"]*)"?.*/\1/')
                    current_obj="${current_obj},\"effect\":\"$eff\"}"
                    tolerations_json="${tolerations_json}${current_obj}"
                fi
            done < "$temp_file"

            tolerations_json="${tolerations_json}]"
        fi
        rm -f "$temp_file"

        # Check for nodeExporterTolerations
        local ne_temp_file=$(mktemp)
        awk '/^nodeExporterTolerations:/{flag=1; next} /^[a-zA-Z]/{flag=0} flag && NF' "$tolerations_file" > "$ne_temp_file"

        if [ -s "$ne_temp_file" ]; then
            # Build JSON for node-exporter tolerations
            node_exporter_tolerations_json="["
            local first=true
            local current_obj=""

            while IFS= read -r line; do
                if echo "$line" | grep -q "^  - "; then
                    if [ "$first" = false ]; then
                        node_exporter_tolerations_json="${node_exporter_tolerations_json},"
                    fi
                    first=false

                    if echo "$line" | grep -q "operator:"; then
                        local op=$(echo "$line" | sed -E 's/.*operator: *"?([^"]*)"?.*/\1/')
                        node_exporter_tolerations_json="${node_exporter_tolerations_json}{\"operator\":\"$op\"}"
                    fi
                fi
            done < "$ne_temp_file"
            node_exporter_tolerations_json="${node_exporter_tolerations_json}]"
        else
            # Default: operator Exists
            node_exporter_tolerations_json='[{"operator":"Exists"}]'
        fi
        rm -f "$ne_temp_file"

        # Extract nodeSelector
        local ns_temp_file=$(mktemp)
        awk '/^nodeSelector:/{flag=1; next} /^[a-zA-Z]/{flag=0} flag && NF && !/^#/' "$tolerations_file" > "$ns_temp_file"

        if [ -s "$ns_temp_file" ]; then
            node_selector_json="{"
            local first=true
            while IFS= read -r line; do
                if echo "$line" | grep -q ":"; then
                    local key=$(echo "$line" | sed -E 's/^ *([^:]+):.*/\1/' | tr -d '"')
                    local value=$(echo "$line" | sed -E 's/.*: *"?([^"]*)"?.*/\1/')

                    if [ "$first" = false ]; then
                        node_selector_json="${node_selector_json},"
                    fi
                    first=false
                    node_selector_json="${node_selector_json}\"$key\":\"$value\""
                fi
            done < "$ns_temp_file"
            node_selector_json="${node_selector_json}}"
        fi
        rm -f "$ns_temp_file"
    fi

    [ -n "$tolerations_json" ] && log_info "Tolerations JSON: $tolerations_json"
    [ -n "$node_selector_json" ] && log_info "NodeSelector JSON: $node_selector_json"
    [ -n "$node_exporter_tolerations_json" ] && log_info "NodeExporter Tolerations JSON: $node_exporter_tolerations_json"

    # Wait for resources to be created by Helm
    log_info "Waiting for monitoring resources to be created..."
    sleep 5

    # Patch kube-state-metrics Deployment
    if [ -n "$tolerations_json" ] || [ -n "$node_selector_json" ]; then
        log_info "Patching kube-state-metrics Deployment..."
        if kubectl get deployment last9-k8s-monitoring-kube-state-metrics -n "$NAMESPACE" &>/dev/null; then
            if [ -n "$tolerations_json" ]; then
                kubectl patch deployment last9-k8s-monitoring-kube-state-metrics -n "$NAMESPACE" --type='json' -p="[{\"op\": \"add\", \"path\": \"/spec/template/spec/tolerations\", \"value\": $tolerations_json}]" 2>&1 | grep -v "Warning:" || true
            fi
            if [ -n "$node_selector_json" ]; then
                kubectl patch deployment last9-k8s-monitoring-kube-state-metrics -n "$NAMESPACE" --type='json' -p="[{\"op\": \"add\", \"path\": \"/spec/template/spec/nodeSelector\", \"value\": $node_selector_json}]" 2>&1 | grep -v "Warning:" || true
            fi
            log_info "✓ kube-state-metrics Deployment patched"
        else
            log_warn "kube-state-metrics Deployment not found, skipping"
        fi
    fi

    # Patch node-exporter DaemonSet with special tolerations
    if [ -n "$node_exporter_tolerations_json" ]; then
        log_info "Patching node-exporter DaemonSet with permissive tolerations..."
        if kubectl get daemonset last9-k8s-monitoring-prometheus-node-exporter -n "$NAMESPACE" &>/dev/null; then
            kubectl patch daemonset last9-k8s-monitoring-prometheus-node-exporter -n "$NAMESPACE" --type='json' -p="[{\"op\": \"add\", \"path\": \"/spec/template/spec/tolerations\", \"value\": $node_exporter_tolerations_json}]" 2>&1 | grep -v "Warning:" || true
            log_info "✓ node-exporter DaemonSet patched"
        else
            log_warn "node-exporter DaemonSet not found, skipping"
        fi
    fi

    # Wait for pods to be recreated and ready
    log_info "Waiting for monitoring pods to be ready..."
    sleep 10

    # Check pod status
    log_info "Monitoring pod status:"
    kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=kube-state-metrics" 2>/dev/null || true
    kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=prometheus" 2>/dev/null || true
    kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=prometheus-node-exporter" 2>/dev/null || true

    log_info "✓ Monitoring components patched with tolerations and nodeSelector"
}

# Parse named arguments
parse_arguments() {
    for arg in "$@"; do
        case $arg in
            monitoring-only)
                MONITORING_ONLY=true
                ;;
            events-only)
                EVENTS_ONLY=true
                ;;
            logs-only)
                LOGS_ONLY=true
                ;;
            operator-only)
                OPERATOR_ONLY=true
                ;;
            uninstall)
                UNINSTALL_MODE=true
                ;;
            uninstall-all)
                UNINSTALL_MODE=true
                FUNCTION_TO_EXECUTE="uninstall_all"
                ;;
            token=*)
                AUTH_TOKEN="${arg#*=}"
                ;;
            endpoint=*)
                OTEL_ENDPOINT="${arg#*=}"
                ;;
            monitoring-endpoint=*)
                MONITORING_ENDPOINT="${arg#*=}"
                ;;
            app-metrics-keep=*)
                APP_METRICS_KEEP="${arg#*=}"
                ;;
            repo=*)
                REPO_URL="${arg#*=}"
                ;;
            function=*)
                FUNCTION_TO_EXECUTE="${arg#*=}"
                ;;
            values=*)
                VALUES_FILE="${arg#*=}"
                ;;
            monitoring=*)
                if [ "${arg#*=}" = "false" ]; then
                    SETUP_MONITORING=false
                else
                    SETUP_MONITORING=true
                    CLUSTER_NAME="${arg#*=}"
                fi
                ;;
            cluster=*)
                CLUSTER_NAME="${arg#*=}"
                ;;
            context=*)
                KUBE_CONTEXT="${arg#*=}"
                ;;
            server-name=*)
                SERVER_NAME="${arg#*=}"
                ;;
            username=*)
                LAST9_USERNAME="${arg#*=}"
                ;;
            password=*)
                LAST9_PASSWORD="${arg#*=}"
                ;;
            tolerations-file=*)
                TOLERATIONS_FILE="${arg#*=}"

                # Validate tolerations file path immediately
                if [ -z "$TOLERATIONS_FILE" ]; then
                    log_error "tolerations-file argument is empty. Please provide an absolute path to the tolerations YAML file."
                    log_error "Example: tolerations-file=/absolute/path/to/tolerations.yaml"
                fi

                # Check if path is absolute (starts with /)
                if [[ ! "$TOLERATIONS_FILE" =~ ^/ ]]; then
                    log_error "tolerations-file must be an absolute path (starting with /)"
                    log_error "Provided: $TOLERATIONS_FILE"
                    log_error "Example: tolerations-file=/home/user/tolerations.yaml"
                fi

                # Check if file exists
                if [ ! -f "$TOLERATIONS_FILE" ]; then
                    log_error "Tolerations file not found at: $TOLERATIONS_FILE"
                    log_error "Please verify the file path and try again."
                fi

                # Check if file is readable
                if [ ! -r "$TOLERATIONS_FILE" ]; then
                    log_error "Tolerations file is not readable: $TOLERATIONS_FILE"
                    log_error "Please check file permissions and try again."
                fi

                log_info "✓ Tolerations file validated: $TOLERATIONS_FILE"
                ;;
            env=*)
                DEPLOYMENT_ENV="${arg#*=}"
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_warn "Unknown argument: $arg"
                show_help
                exit 1
                ;;
        esac
    done
}

# Show examples function (for no-args case)
show_examples() {
    echo "OpenTelemetry Setup Automation Script"
    echo ""
    echo "Quick Examples:"
    echo "  $0 token=\"your-token-here\" endpoint=\"your-otel-endpoint\" monitoring-endpoint=\"your-monitoring-endpoint\" username=\"my-user\" password=\"my-pass\"  # For All Sources(Logs, Traces, Metrics and Events) use this option"
    echo "  $0 operator-only token=\"your-token-here\" endpoint=\"your-otel-endpoint\"  # For Traces - Install OpenTelemetry Operator and Collector"
    echo "  $0 logs-only token=\"your-token-here\" endpoint=\"your-otel-endpoint\"  # For Logs - Install only Collector for logs (no operator)"
    echo "  $0 monitoring-only monitoring-endpoint=\"your-monitoring-endpoint\" username=\"user\" password=\"pass\"  # For Metrics - Install only monitoring"
    echo "  $0 events-only  # For Events - Install only Kubernetes Events Agent"
    echo "  $0 uninstall-all  # Use to Uninstall any components installed previously"
    echo ""
    echo "With Environment and Cluster Override:"
    echo "  $0 token=\"xxx\" endpoint=\"xxx\" env=production cluster=prod-us-east-1  # Set environment and cluster name"
    echo "  $0 token=\"xxx\" endpoint=\"xxx\" env=staging cluster=staging-cluster    # Set environment and cluster name"
    echo ""
    echo "With Tolerations and NodeSelector:"
    echo "  $0 tolerations-file=examples/tolerations-monitoring-nodes.yaml token=\"xxx\" endpoint=\"xxx\" ...  # Run on monitoring nodes"
    echo "  $0 tolerations-file=examples/tolerations-all-nodes.yaml operator-only token=\"xxx\" endpoint=\"xxx\"  # Operator on all nodes including control-plane"
    echo ""
    echo "See examples/ directory for more tolerations configurations"
    echo ""
}

# Show help function
show_help() {
    echo "OpenTelemetry Setup Automation Script"
    echo ""
    echo "Usage:"
    echo "  $0 token=\"your-token-here\" endpoint=\"your-otel-endpoint\" monitoring-endpoint=\"your-monitoring-endpoint\" username=\"my-user\" password=\"my-pass\"  # For All Sources(Logs, Traces, Metrics and Events) use this option"
    echo "  $0 operator-only token=\"your-token-here\" endpoint=\"your-otel-endpoint\"  # For Traces - Install OpenTelemetry Operator and Collector"
    echo "  $0 logs-only token=\"your-token-here\" endpoint=\"your-otel-endpoint\"  # For Logs - Install only Collector for logs (no operator)"
    echo "  $0 monitoring-only monitoring-endpoint=\"your-monitoring-endpoint\" username=\"user\" password=\"pass\"  # For Metrics - Install only monitoring"
    echo "  $0 events-only  # For Events - Install only Kubernetes Events Agent"
    echo "  $0 uninstall-all  # Use to Uninstall any components installed previously"
    echo ""
    echo "Advanced Options:"
    echo "  env=ENVIRONMENT          Override deployment.environment attribute (e.g., production, staging, dev)"
    echo "                           Updates both collector and auto-instrumentation configurations"
    echo "                           Default: unset — deployment.environment is omitted unless env= is provided"
    echo ""
    echo "  cluster=CLUSTER_NAME     Set cluster.name attribute for telemetry data"
    echo "                           If not provided, automatically detected from kubectl current-context"
    echo "                           Example: cluster=prod-us-east-1"
    echo ""
    echo "  app-metrics-keep=REGEX   Extra metric-name regex kept (in addition to the default allowlist)"
    echo "                           by the OTel metrics scraper. Example: app-metrics-keep='myapp_.*|http_requests_total'"
    echo ""
    echo "  context=CONTEXT_NAME     Use a specific kubectl context for all operations"
    echo "                           Useful on shared machines with multiple clusters"
    echo "                           If not provided, the current active context is used"
    echo "                           Example: context=prod-us-east-1"
    echo ""
    echo "  tolerations-file=FILE    Apply Kubernetes tolerations and nodeSelector from YAML file"
    echo "                           Allows running components on tainted nodes (e.g., monitoring nodes, control-plane)"
    echo "                           See examples/ directory for sample configurations"
    echo ""
    echo "Examples with Environment and Cluster Override:"
    echo "  # Set environment to production with cluster name"
    echo "  $0 token=\"xxx\" endpoint=\"xxx\" env=production cluster=prod-us-east-1"
    echo ""
    echo "  # Set environment to staging with auto-detected cluster name"
    echo "  $0 operator-only token=\"xxx\" endpoint=\"xxx\" env=staging"
    echo ""
    echo "  # Use custom cluster name only (environment will use default)"
    echo "  $0 token=\"xxx\" endpoint=\"xxx\" cluster=my-k8s-cluster"
    echo ""
    echo "Examples with Tolerations:"
    echo "  # Run on dedicated monitoring nodes"
    echo "  $0 tolerations-file=tolerations.yaml token=\"xxx\" endpoint=\"xxx\" ..."
    echo ""
    echo "  # Run on all nodes including control-plane/master"
    echo "  $0 tolerations-file=examples/tolerations-all-nodes.yaml operator-only token=\"xxx\" endpoint=\"xxx\""
    echo ""
    echo "  # Run on spot/preemptible instances"
    echo "  $0 tolerations-file=examples/tolerations-spot-instances.yaml monitoring-only monitoring-endpoint=\"xxx\" ..."
    echo ""
}

# Install kubectl/helm wrappers that inject --context/--kube-context when
# context= argument is provided. Shadowing the binaries means all existing
# calls throughout the script pick up the context automatically.
setup_context_wrappers() {
    if [ -z "$KUBE_CONTEXT" ]; then
        return 0
    fi

    # Validate context exists before wrapping
    if ! command kubectl config get-contexts "$KUBE_CONTEXT" >/dev/null 2>&1; then
        log_error "kubectl context '$KUBE_CONTEXT' not found. Run 'kubectl config get-contexts' to list available contexts."
    fi

    log_info "Using kubectl context: $KUBE_CONTEXT"

    kubectl() { command kubectl --context "$KUBE_CONTEXT" "$@"; }
    helm()    { command helm --kube-context "$KUBE_CONTEXT" "$@"; }
    export -f kubectl helm
}

# Function to check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Individual function= invocations validate their own arguments in main().
    if [ -n "$FUNCTION_TO_EXECUTE" ]; then
        command -v helm >/dev/null 2>&1 || log_error "helm is required but not installed. Aborting."
        command -v kubectl >/dev/null 2>&1 || log_error "kubectl is required but not installed. Aborting."
        if [ "$UNINSTALL_MODE" = false ]; then
            command -v git >/dev/null 2>&1 || log_error "git is required but not installed. Aborting."
        fi
        kubectl cluster-info >/dev/null 2>&1 || log_error "kubectl cannot connect to cluster. Aborting."
        log_info "Prerequisites check passed!"
        return 0
    fi
    
    # Skip token check for uninstall mode, logs-only mode, monitoring-only mode, and events-only mode
    # Note: operator-only mode will check for token later in its specific section
    # Help is printed before the terminal log_error so the red error line is the
    # last thing the user sees (log_error exits the process).
    if [ "$UNINSTALL_MODE" = false ] && [ "$LOGS_ONLY" = false ] && [ "$MONITORING_ONLY" = false ] && [ "$EVENTS_ONLY" = false ] && [ "$OPERATOR_ONLY" = false ] && [ -z "$AUTH_TOKEN" ]; then
        show_help
        log_error "Auth token is required for installation."
    fi

    # Check if endpoint is provided for non-monitoring and non-events modes
    if [ "$UNINSTALL_MODE" = false ] && [ "$MONITORING_ONLY" = false ] && [ "$EVENTS_ONLY" = false ] && [ -z "$OTEL_ENDPOINT" ]; then
        show_help
        log_error "OTEL endpoint is required. Provide endpoint=<your-otel-endpoint>."
    fi

    # Check if monitoring endpoint is provided for modes that include monitoring
    if [ "$UNINSTALL_MODE" = false ] && [ "$MONITORING_ONLY" = true ] && [ -z "$MONITORING_ENDPOINT" ]; then
        show_help
        log_error "Monitoring endpoint is required. Provide monitoring-endpoint=<your-monitoring-endpoint>."
    fi

    # Check if monitoring endpoint is provided for all sources mode (which includes monitoring).
    # events-only is excluded: the events agent forwards Kubernetes events to the
    # OTLP logs endpoint and does not need a metrics/monitoring endpoint.
    if [ "$UNINSTALL_MODE" = false ] && [ "$MONITORING_ONLY" = false ] && [ "$OPERATOR_ONLY" = false ] && [ "$LOGS_ONLY" = false ] && [ "$EVENTS_ONLY" = false ] && [ "$SETUP_MONITORING" = true ] && [ -z "$MONITORING_ENDPOINT" ]; then
        show_help
        log_error "Monitoring endpoint is required for all-sources install. Provide monitoring-endpoint=<your-monitoring-endpoint>."
    fi
    
    command -v helm >/dev/null 2>&1 || log_error "helm is required but not installed. Aborting."
    command -v kubectl >/dev/null 2>&1 || log_error "kubectl is required but not installed. Aborting."
    
    if [ "$UNINSTALL_MODE" = false ]; then
        command -v git >/dev/null 2>&1 || log_error "git is required but not installed. Aborting."
    fi
    
    # Check kubectl connectivity
    kubectl cluster-info >/dev/null 2>&1 || log_error "kubectl cannot connect to cluster. Aborting."
    
    log_info "Prerequisites check passed!"
    
    if [ "$UNINSTALL_MODE" = false ]; then
        if [ "$OPERATOR_ONLY" = true ]; then
            log_info "Running in operator-only mode"
        elif [ "$LOGS_ONLY" = true ]; then
            log_info "Running in logs-only mode"
            log_info "Using auth token: ${AUTH_TOKEN:0:10}..."  # Show only first 10 chars for security
            log_info "Using OTEL endpoint: ${OTEL_ENDPOINT:0:30}..."  # Show only first 30 chars for security
            log_info "Using repository: $REPO_URL"
        elif [ "$MONITORING_ONLY" = true ]; then
            log_info "Running in monitoring-only mode"
            log_info "Using monitoring endpoint: ${MONITORING_ENDPOINT:0:30}..."  # Show only first 30 chars for security
        else
            log_info "Using auth token: ${AUTH_TOKEN:0:10}..."  # Show only first 10 chars for security
            log_info "Using OTEL endpoint: ${OTEL_ENDPOINT:0:30}..."  # Show only first 30 chars for security
            if [ "$SETUP_MONITORING" = true ] && [ -n "$MONITORING_ENDPOINT" ]; then
                log_info "Using monitoring endpoint: ${MONITORING_ENDPOINT:0:30}..."  # Show only first 30 chars for security
            fi
            log_info "Using repository: $REPO_URL"
        fi
    else
        log_info "Running in uninstall mode"
    fi
}

# Function to setup repository and files
setup_repository() {
    log_info "Setting up repository and configuration files..."

    # Create temporary work directory
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    # Simple shallow clone - entire repo is small and focused
    log_info "Downloading configuration files from: $REPO_URL"
    git clone --depth=1 "$REPO_URL" . 2>&1 | grep -v "^hint:" || true

    log_info "✓ Configuration files downloaded successfully!"

    # Verify required files exist
    required_files=("last9-otel-collector-values.yaml" "collector-svc.yaml" "instrumentation.yaml")
    for file in "${required_files[@]}"; do
        if [ ! -f "$file" ]; then
            log_error "Required file '$file' not found in repository."
        fi
    done

    log_info "Repository setup completed!"

    # Upgrade custom/local values that still use pre-0.156 collector config keys.
    prepare_collector_values_file "last9-otel-collector-values.yaml" "" "OpenTelemetry Collector"

    # Update auth token and endpoint in the values file
    update_auth_token
    update_otel_endpoint

    # Inject TLS server name override if provided (no-op when unset)
    inject_collector_tls_server_name "last9-otel-collector-values.yaml"

    # Update deployment environment if provided
    if [ -n "$DEPLOYMENT_ENV" ]; then
        update_deployment_environment "$DEPLOYMENT_ENV"
    fi

    # Add cluster name attribute to collector values
    update_cluster_name_attribute

    # Load and apply tolerations if provided
    if [ -n "$TOLERATIONS_FILE" ]; then
        load_tolerations_from_file "$TOLERATIONS_FILE"
        apply_tolerations_to_collector_values "last9-otel-collector-values.yaml"
    fi
}

# Function to update auth token in values file
update_auth_token() {
    log_info "Updating auth token placeholder in last9-otel-collector-values.yaml..."
    
    # Check if the values file exists
    if [ ! -f "last9-otel-collector-values.yaml" ]; then
        log_error "last9-otel-collector-values.yaml not found!"
    fi
    
    # Create backup of original file
    cp last9-otel-collector-values.yaml last9-otel-collector-values.yaml.backup
    log_info "Created backup: last9-otel-collector-values.yaml.backup"
    
    # Replace placeholder with actual token (expects complete authorization header)
    log_info "Using auth token: ${AUTH_TOKEN:0:20}..."
    
    # Handle multiple placeholder formats
    if grep -q '{{AUTH_TOKEN}}' last9-otel-collector-values.yaml; then
        log_info "Found {{AUTH_TOKEN}} placeholder"
        escaped_token=$(escape_for_sed "$AUTH_TOKEN")
        sed -i.tmp "s|{{AUTH_TOKEN}}|$escaped_token|g" last9-otel-collector-values.yaml
    elif grep -q '${AUTH_TOKEN}' last9-otel-collector-values.yaml; then
        log_info "Found \${AUTH_TOKEN} placeholder"
        escaped_token=$(escape_for_sed "$AUTH_TOKEN")
        sed -i.tmp "s|\${AUTH_TOKEN}|$escaped_token|g" last9-otel-collector-values.yaml
    elif grep -q '{{ \.Values\.authToken }}' last9-otel-collector-values.yaml; then
        log_info "Found Helm template placeholder"
        escaped_token=$(escape_for_sed "$AUTH_TOKEN")
        sed -i.tmp "s|{{ \.Values\.authToken }}|$escaped_token|g" last9-otel-collector-values.yaml
    else
        log_warn "⚠ No auth token placeholder found in the file."
        log_warn "Assuming credentials are already configured in the YAML file."
        log_warn "Skipping token replacement..."
    fi
    
    # Remove the temporary file created by sed -i
    rm -f last9-otel-collector-values.yaml.tmp
    
    # Verify the change was made
    if grep -q "$AUTH_TOKEN" last9-otel-collector-values.yaml && ! grep -q -E '(\{\{|\$\{).*AUTH_TOKEN.*(\}\}|\})' last9-otel-collector-values.yaml; then
        log_info "✓ Auth token placeholder replaced successfully!"
    else
        log_warn "⚠ Could not verify token replacement. Please check the file manually."
    fi
}

# Function to update OTEL endpoint in values file
update_otel_endpoint() {
    log_info "Updating OTEL endpoint placeholder in last9-otel-collector-values.yaml..."
    
    # Check if the values file exists
    if [ ! -f "last9-otel-collector-values.yaml" ]; then
        log_error "last9-otel-collector-values.yaml not found!"
    fi
    
    # Create backup of original file (if not already created by update_auth_token)
    if [ ! -f "last9-otel-collector-values.yaml.backup" ]; then
        cp last9-otel-collector-values.yaml last9-otel-collector-values.yaml.backup
        log_info "Created backup: last9-otel-collector-values.yaml.backup"
    fi
    
    # Replace placeholder with actual endpoint
    log_info "Using OTEL endpoint: ${OTEL_ENDPOINT:0:30}..."
    
    # Handle multiple placeholder formats
    if grep -q '{{YOUR_OTEL_ENDPOINT}}' last9-otel-collector-values.yaml; then
        log_info "Found {{YOUR_OTEL_ENDPOINT}} placeholder"
        escaped_endpoint=$(escape_for_sed "$OTEL_ENDPOINT")
        sed -i.tmp "s|{{YOUR_OTEL_ENDPOINT}}|$escaped_endpoint|g" last9-otel-collector-values.yaml
    elif grep -q '{{OTEL_ENDPOINT}}' last9-otel-collector-values.yaml; then
        log_info "Found {{OTEL_ENDPOINT}} placeholder"
        escaped_endpoint=$(escape_for_sed "$OTEL_ENDPOINT")
        sed -i.tmp "s|{{OTEL_ENDPOINT}}|$escaped_endpoint|g" last9-otel-collector-values.yaml
    elif grep -q '\${OTEL_ENDPOINT}' last9-otel-collector-values.yaml; then
        log_info "Found \${OTEL_ENDPOINT} placeholder"
        escaped_endpoint=$(escape_for_sed "$OTEL_ENDPOINT")
        sed -i.tmp "s|\${OTEL_ENDPOINT}|$escaped_endpoint|g" last9-otel-collector-values.yaml
    elif grep -q 'https://<your_last9_endpoint>' last9-otel-collector-values.yaml; then
        log_info "Found old format https://<your_last9_endpoint> placeholder"
        escaped_endpoint=$(escape_for_sed "$OTEL_ENDPOINT")
        sed -i.tmp "s|https://<your_last9_endpoint>|$escaped_endpoint|g" last9-otel-collector-values.yaml
    else
        log_warn "⚠ No OTEL endpoint placeholder found in the file."
        log_warn "Assuming endpoint is already configured in the YAML file."
        log_warn "Skipping endpoint replacement..."
    fi
    
    # Remove the temporary file created by sed -i
    rm -f last9-otel-collector-values.yaml.tmp
    
    # Verify the change was made
    if grep -q "$OTEL_ENDPOINT" last9-otel-collector-values.yaml && ! grep -q -E '(\{\{|\$\{).*OTEL_ENDPOINT.*(\}\}|\})' last9-otel-collector-values.yaml; then
        log_info "✓ OTEL endpoint placeholder replaced successfully!"
    else
        log_warn "⚠ Could not verify endpoint replacement. Please check the file manually."
    fi
}

# Inject a TLS server_name_override under the otlp_grpc/last9 exporter of a collector
# values file. Used when the OTLP endpoint terminates TLS behind a proxy/NLB whose
# certificate name differs from the connection host. No-op when SERVER_NAME is empty
# (default), so existing installs are byte-identical. Idempotent on re-run.
inject_collector_tls_server_name() {
    local file="$1"

    [ -z "$SERVER_NAME" ] && return 0

    if [ ! -f "$file" ]; then
        log_warn "⚠ $file not found, skipping TLS server_name injection"
        return 0
    fi

    # Idempotency guard - don't add a second tls block
    if grep -q 'server_name_override:' "$file"; then
        log_info "TLS server_name_override already present in $file, skipping"
        return 0
    fi

    local exporter_key
    exporter_key=$(_collector_last9_exporter_key "$file")
    if [ -z "$exporter_key" ]; then
        log_warn "⚠ No otlp_grpc/last9 or otlp/last9 exporter in $file, skipping TLS injection"
        return 0
    fi

    log_info "Injecting TLS server_name_override ($SERVER_NAME) into $file..."

    if [ ! -f "$file.backup" ]; then
        cp "$file" "$file.backup"
        log_info "Created backup: $file.backup"
    fi

    # Does the otlp_grpc/last9 block already have a real (uncommented) tls: child? If so we
    # add server_name_override under it rather than emitting a second tls: key (which
    # would be a duplicate map key). Commented "# tls:" examples elsewhere don't match.
    local has_tls
    has_tls=$(awk -v key="$exporter_key" '
        $0 ~ "^    " key ":[[:space:]]*$" { in_block=1; next }
        in_block && /^ {0,4}[^[:space:]]/ { in_block=0 }
        in_block && /^      tls:[[:space:]]*$/ { print "yes"; exit }
    ' "$file")

    if [ -n "$has_tls" ]; then
        # Insert server_name_override as a child of the existing Last9 exporter tls: block.
        awk -v key="$exporter_key" -v sni="$SERVER_NAME" '
            $0 ~ "^    " key ":[[:space:]]*$" { in_block=1; print; next }
            in_block && /^ {0,4}[^[:space:]]/ { in_block=0 }
            {
                print
                if (in_block && $0 ~ /^      tls:[[:space:]]*$/) {
                    print "        server_name_override: " sni
                }
            }
        ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    else
        # No tls block yet: anchor on the Last9 exporter block (4-space key) and
        # insert a fresh tls block after its 6-space endpoint: line. This avoids the
        # decoy endpoint: lines for health_check, the otlp receivers, and
        # internalTelemetryViaOTLP, which live in other blocks.
        awk -v key="$exporter_key" -v sni="$SERVER_NAME" '
            $0 ~ "^    " key ":[[:space:]]*$" { in_block=1; print; next }
            in_block && /^ {0,4}[^[:space:]]/ { in_block=0 }
            {
                print
                if (in_block && $0 ~ /^      endpoint:/) {
                    print "      tls:"
                    print "        insecure: false"
                    print "        server_name_override: " sni
                }
            }
        ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    fi

    if grep -q "server_name_override: $SERVER_NAME" "$file"; then
        log_info "✓ TLS server_name_override injected into $file"
    else
        log_warn "⚠ Could not verify TLS injection in $file, restoring from backup."
        [ -f "$file.backup" ] && cp "$file.backup" "$file"
        rm -f "$file.tmp"
    fi
}

# Interactively ask for the deployment environment when run as a dev-tool CLI.
# Only prompts on a real terminal — curl|bash one-liners and CI have no TTY, so it
# stays unset there. An explicit env= argument always wins and suppresses the prompt.
prompt_deployment_environment() {
    [ "$UNINSTALL_MODE" = true ] && return 0
    [ -n "$DEPLOYMENT_ENV" ] && return 0   # env= provided — honor it, don't prompt
    [ -t 0 ] || return 0                   # non-interactive (piped/CI) — leave unset

    printf "%b" "${GREEN}[INPUT]${NC} Deployment environment (e.g. production, staging) [blank to skip]: " >&2
    read -r DEPLOYMENT_ENV || DEPLOYMENT_ENV=""
    if [ -n "$DEPLOYMENT_ENV" ]; then
        log_info "Using deployment.environment=$DEPLOYMENT_ENV"
    else
        log_info "No deployment environment entered — deployment.environment will be omitted"
    fi
}

# Function to update deployment environment in configuration files
update_deployment_environment() {
    local env="$1"

    # Trim surrounding whitespace; a whitespace-only value is treated as unset.
    env="$(printf '%s' "$env" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

    if [ -z "$env" ]; then
        log_info "No deployment environment specified — deployment.environment will be omitted"
        return 0
    fi

    # Reject values outside a safe identifier charset. env is interpolated raw into a
    # sed replacement (|, &, \ corrupt it), awk -v, and OTTL/YAML string literals (a "
    # breaks the literal) downstream — one guard closes all three sinks. (#review)
    case "$env" in
        *[!A-Za-z0-9._-]*)
            log_error "Invalid deployment environment '$env'. Use only letters, digits, '.', '_', '-'." ;;
    esac

    log_info "Setting deployment.environment to: $env"

    # Update collector values file (last9-otel-collector-values.yaml)
    # The attribute is a placeholder comment by default (unset); activate it with the value.
    if [ -f "last9-otel-collector-values.yaml" ]; then
        log_info "Activating deployment.environment in collector values file..."

        activate_deployment_environment_in_values "last9-otel-collector-values.yaml" "$env" attributes

        # Verify the change
        if grep -q "deployment.environment\"], \"$env\"" last9-otel-collector-values.yaml; then
            log_info "✓ Set deployment.environment=$env in collector values file"
        else
            log_warn "⚠ Could not verify deployment.environment update in collector values file"
        fi
    else
        log_warn "⚠ last9-otel-collector-values.yaml not found, skipping collector environment update"
    fi

    # Update instrumentation file (instrumentation.yaml)
    # OTEL_RESOURCE_ATTRIBUTES is empty by default (unset); populate it with the value.
    if [ -f "instrumentation.yaml" ]; then
        log_info "Setting deployment.environment in instrumentation file..."

        # Fill in the value on the line following each OTEL_RESOURCE_ATTRIBUTES env entry,
        # preserving its indentation (handles both quoted and unquoted styles).
        awk -v env="$env" '
            prev ~ /OTEL_RESOURCE_ATTRIBUTES/ && /value:/ {
                match($0, /^[[:space:]]*/); indent = substr($0, 1, RLENGTH)
                print indent "value: \"deployment.environment=" env "\""
                prev = $0; next
            }
            { prev = $0; print }
        ' instrumentation.yaml > instrumentation.yaml.tmp && mv instrumentation.yaml.tmp instrumentation.yaml

        # Verify the change
        if grep -q "deployment.environment=$env" instrumentation.yaml; then
            log_info "✓ Set deployment.environment=$env in instrumentation file"
        else
            log_warn "⚠ Could not verify deployment.environment update in instrumentation file"
        fi
    else
        log_warn "⚠ instrumentation.yaml not found, skipping instrumentation environment update"
    fi

    # Update kube-events agent values file (last9-kube-events-agent-values.yaml)
    # The attribute is a placeholder comment by default (unset); activate it with the value.
    if [ -f "last9-kube-events-agent-values.yaml" ]; then
        log_info "Activating deployment.environment in kube-events agent values file..."

        activate_deployment_environment_in_values "last9-kube-events-agent-values.yaml" "$env" resource.attributes

        # Verify the change
        if grep -q "deployment.environment\"], \"$env\"" last9-kube-events-agent-values.yaml; then
            log_info "✓ Set deployment.environment=$env in kube-events agent values file"
        else
            log_warn "⚠ Could not verify deployment.environment update in kube-events agent values file"
        fi
    else
        log_warn "⚠ last9-kube-events-agent-values.yaml not found, skipping kube-events agent environment update"
    fi

    log_info "✓ Deployment environment configuration completed"
}

# Function to add cluster name attribute to collector values file
update_cluster_name_attribute() {
    log_info "Adding cluster name attribute to collector values file..."

    # Detect cluster name from kubectl context
    local cluster_name="${CLUSTER_NAME}"

    if [ -z "$cluster_name" ]; then
        log_info "Cluster name not provided, attempting to detect from kubectl..."
        local raw_context
        raw_context=$(kubectl config current-context 2>/dev/null || echo "unknown-cluster")
        cluster_name=$(sanitize_cluster_name "$raw_context")
        log_info "Detected cluster name: $cluster_name"
    else
        cluster_name=$(sanitize_cluster_name "$cluster_name")
        log_info "Using provided cluster name: $cluster_name"
    fi

    # Update collector values file (last9-otel-collector-values.yaml)
    if [ -f "last9-otel-collector-values.yaml" ]; then
        # Check if cluster.name attribute already exists
        if grep -q "cluster\.name" last9-otel-collector-values.yaml; then
            log_info "cluster.name attribute already exists, updating value..."
            escaped_cluster=$(printf '%s\n' "$cluster_name" | sed 's/[&/\]/\\&/g')
            sed -i.tmp "s/cluster\.name\"], \"[^\"]*\"/cluster.name\"], \"$escaped_cluster\"/" last9-otel-collector-values.yaml
            rm -f last9-otel-collector-values.yaml.tmp
        else
            log_info "Adding cluster.name attribute (anchor: @DEPLOYMENT_ENVIRONMENT@ or deployment.environment)..."
            # Insert once after the env placeholder comment or an activated deployment.environment
            # set() line — never require env= to have run first (collector has multiple placeholders).
            awk -v cluster="$cluster_name" '
            !done && (/# @DEPLOYMENT_ENVIRONMENT@/ || /set\(attributes\["deployment\.environment"\]/) {
                print
                match($0, /^[[:space:]]*/);
                indent = substr($0, RSTART, RLENGTH);
                print indent "- set(attributes[\"cluster.name\"], \"" cluster "\")"
                done = 1
                next
            }
            {print}
            ' last9-otel-collector-values.yaml > last9-otel-collector-values.yaml.tmp
            mv last9-otel-collector-values.yaml.tmp last9-otel-collector-values.yaml
        fi

        # Verify the change
        if grep -q "cluster.name\"], \"$cluster_name\"" last9-otel-collector-values.yaml; then
            log_info "✓ Added/updated cluster.name=$cluster_name in collector values file"
        else
            log_warn "⚠ Could not verify cluster.name addition in collector values file"
        fi
    else
        log_warn "⚠ last9-otel-collector-values.yaml not found, skipping cluster name update"
    fi

    log_info "✓ Cluster name attribute configuration completed"
}

# Function to add cluster name attribute to events agent values file
update_events_agent_cluster_name() {
    log_info "Adding cluster name attribute to events agent values file..."

    # Detect cluster name from kubectl context
    local cluster_name="${CLUSTER_NAME}"

    if [ -z "$cluster_name" ]; then
        log_info "Cluster name not provided, attempting to detect from kubectl..."
        local raw_context
        raw_context=$(kubectl config current-context 2>/dev/null || echo "unknown-cluster")
        cluster_name=$(sanitize_cluster_name "$raw_context")
        log_info "Detected cluster name: $cluster_name"
    else
        cluster_name=$(sanitize_cluster_name "$cluster_name")
        log_info "Using provided cluster name: $cluster_name"
    fi

    # Update events agent values file (last9-kube-events-agent-values.yaml)
    if [ -f "last9-kube-events-agent-values.yaml" ]; then
        # Check if cluster.name attribute already exists
        if grep -q "cluster\.name" last9-kube-events-agent-values.yaml; then
            log_info "cluster.name attribute already exists, updating value..."
            escaped_cluster=$(printf '%s\n' "$cluster_name" | sed 's/[&/\]/\\&/g')
            sed -i.tmp "s/cluster\.name\"], \"[^\"]*\"/cluster.name\"], \"$escaped_cluster\"/" last9-kube-events-agent-values.yaml
            rm -f last9-kube-events-agent-values.yaml.tmp
        else
            log_info "Adding cluster.name attribute (anchor: @DEPLOYMENT_ENVIRONMENT@ or deployment.environment)..."
            # Insert after the env placeholder comment or an activated deployment.environment
            # set() line. Must not require env= — otherwise events-only installs drop cluster.name.
            awk -v cluster="$cluster_name" '
            !done && (/# @DEPLOYMENT_ENVIRONMENT@/ || /set\(resource\.attributes\["deployment\.environment"\]/) {
                print
                match($0, /^[[:space:]]*/);
                indent = substr($0, RSTART, RLENGTH);
                print indent "- set(resource.attributes[\"cluster.name\"], \"" cluster "\")"
                done = 1
                next
            }
            {print}
            ' last9-kube-events-agent-values.yaml > last9-kube-events-agent-values.yaml.tmp
            mv last9-kube-events-agent-values.yaml.tmp last9-kube-events-agent-values.yaml
        fi

        # Verify the change
        if grep -q "cluster.name\"], \"$cluster_name\"" last9-kube-events-agent-values.yaml; then
            log_info "✓ Added/updated cluster.name=$cluster_name in events agent values file"
        else
            log_warn "⚠ Could not verify cluster.name addition in events agent values file"
        fi
    else
        log_warn "⚠ last9-kube-events-agent-values.yaml not found, skipping cluster name update"
    fi

    log_info "✓ Events agent cluster name attribute configuration completed"
}

# Function to setup Helm repositories
setup_helm_repos() {
    log_info "Setting up Helm repositories..."

    # Enable --skip-schema-validation if this Helm supports it (compatibility)
    detect_helm_schema_flag

    # `helm repo add`/`update` fetch index.yaml over the network and can hit
    # transient TLS resets. Neither call was checked, so a failed add silently
    # left the repo missing and the script limped on for ~150 more lines
    # (CRD adoption, etc.) before crashing at the `helm template` step with a
    # confusing "repo not found" error. Retry a few times and fail fast here
    # instead, before any state-mutating steps run.
    local attempt
    for attempt in 1 2 3; do
        if helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts && \
           helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && \
           helm repo update open-telemetry prometheus-community; then
            log_info "Helm repositories updated!"
            return 0
        fi
        if [ "$attempt" -lt 3 ]; then
            log_warn "Helm repo add/update failed (attempt $attempt/3), retrying..."
            sleep 5
        fi
    done

    log_error "Failed to add/update Helm repositories (open-telemetry, prometheus-community) after 3 attempts."
    log_error "Check network connectivity to open-telemetry.github.io and prometheus-community.github.io."
}

# Adopt pre-existing OTel CRDs into this Helm release so that
# "helm upgrade --install" does not fail.
#
# Two distinct failures are handled:
#   1. Helm v3-style ownership check: CRDs without the
#      app.kubernetes.io/managed-by=Helm label and meta.helm.sh/release-*
#      annotations are rejected ("cannot be imported into the current release").
#      Fixed by patching the labels/annotations.
#   2. Helm v4 server-side-apply field-manager conflict: CRDs created via
#      "kubectl apply" are owned by the "kubectl-client-side-apply" field
#      manager, and Helm v4's SSA refuses to overwrite their fields
#      (.spec.versions, annotations). Fixed by re-applying each CRD with
#      "kubectl apply --server-side --force-conflicts --field-manager=helm",
#      which migrates field ownership to Helm's field manager.
# Generic CRD adoption: claim pre-existing CRDs matching a grep pattern into a
# target Helm release. Handles BOTH the Helm v3-style ownership check (label +
# annotations) AND the Helm v4 server-side-apply field-manager conflict
# (re-apply as field-manager "helm" with --force-conflicts).
#
# Args:
#   $1 - human-readable group label for log messages (e.g. "OpenTelemetry")
#   $2 - grep pattern matched against `kubectl get crd -o name` output
#        (e.g. '\.opentelemetry\.io' or 'monitoring\.coreos\.com')
#   $3 - target Helm release name to claim ownership for
# The target release namespace is always "$NAMESPACE".
adopt_crds_for_release() {
    local group_label="$1"
    local crd_pattern="$2"
    local release_name="$3"
    local release_ns="$NAMESPACE"

    log_info "Checking for pre-existing ${group_label} CRDs to adopt..."

    local crds
    crds=$(kubectl get crd -o name 2>/dev/null | grep "$crd_pattern" || true)

    if [ -z "$crds" ]; then
        log_info "No existing ${group_label} CRDs found, skipping adoption."
        return 0
    fi

    local adopted=0
    while IFS= read -r crd; do
        [ -z "$crd" ] && continue
        local managed_by
        managed_by=$(kubectl get "$crd" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)
        local rel_name
        rel_name=$(kubectl get "$crd" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || true)

        if [ "$managed_by" != "Helm" ] || [ "$rel_name" != "$release_name" ]; then
            log_info "Adopting CRD into Helm release: $crd"

            # (1) Helm ownership metadata
            kubectl label --overwrite "$crd" \
                "app.kubernetes.io/managed-by=Helm" 2>/dev/null || true
            kubectl annotate --overwrite "$crd" \
                "meta.helm.sh/release-name=$release_name" \
                "meta.helm.sh/release-namespace=$release_ns" 2>/dev/null || true

            # (2) Migrate field-manager ownership for Helm v4 server-side apply.
            # Re-apply the live CRD as field-manager "helm" with --force-conflicts
            # so Helm's subsequent SSA does not conflict with kubectl-client-side-apply
            # or terraform-provider-helm.
            local ssa_output
            ssa_output=$(kubectl get "$crd" -o yaml 2>/dev/null \
                | kubectl apply --server-side --force-conflicts --field-manager=helm -f - 2>&1) || true
            if [ -n "$ssa_output" ]; then
                while IFS= read -r line; do
                    [ -n "$line" ] && log_warn "CRD SSA: $line"
                done <<< "$ssa_output"
            fi

            adopted=$((adopted + 1))
        fi
    done <<< "$crds"

    if [ "$adopted" -gt 0 ]; then
        log_info "✓ Adopted $adopted ${group_label} CRD(s) into Helm release '$release_name' in namespace '$release_ns'"
    else
        log_info "✓ All existing ${group_label} CRDs already owned by correct Helm release"
    fi
}

# Adopt pre-existing OpenTelemetry CRDs (suffix .opentelemetry.io) into the
# "opentelemetry-operator" Helm release. Thin wrapper over adopt_crds_for_release.
adopt_otel_crds() {
    adopt_crds_for_release "OpenTelemetry" '\.opentelemetry\.io' "opentelemetry-operator"
}

# Adopt pre-existing Prometheus operator CRDs (suffix monitoring.coreos.com)
# into the "last9-k8s-monitoring" Helm release. Thin wrapper over
# adopt_crds_for_release. The release name MUST match the helm release used in
# setup_last9_monitoring (last9-k8s-monitoring / kube-prometheus-stack).
adopt_prometheus_crds() {
    adopt_crds_for_release "Prometheus operator" 'monitoring\.coreos\.com' "last9-k8s-monitoring"
}

# Function to install OpenTelemetry Operator
install_operator() {
    log_info "Installing OpenTelemetry Operator..."

    # Adopt any pre-existing OTel CRDs before Helm tries to manage them
    adopt_otel_crds

    # When OTel CRDs already exist (e.g. a prior cert-manager-based install),
    # cert-manager-cainjector owns .spec.conversion.webhook.clientConfig.caBundle
    # via server-side apply and re-injects it continuously. Helm v4's SSA does
    # NOT pass --force-conflicts, so its CRD apply fails fatally:
    #   conflict with "cert-manager-cainjector" ... .caBundle
    # The adoption migration above cannot win that race against an active
    # controller.
    #
    # Unlike kube-prometheus-stack (CRDs in the chart's crds/ dir, so
    # `helm show crds` + --skip-crds work), the opentelemetry-operator chart
    # ships its CRDs as TEMPLATES gated by crds.create — `helm show crds` is
    # empty and --skip-crds has NO effect. So instead: render the CRDs from the
    # chart template and force-apply them out-of-band (upgrades schema to the
    # chart version and forcibly takes field ownership from cainjector), then
    # disable Helm's own CRD rendering with crds.create=false so Helm never
    # applies — and never re-conflicts on — the CRDs.
    # Probe for ANY pre-existing *.opentelemetry.io CRD — a partial set (e.g.
    # instrumentations present but collectors absent) hits the same cainjector
    # conflict, so gate on any match rather than one well-known name. The
    # out-of-band force-apply below is idempotent and safe to run whenever any
    # OTel CRD exists. This mirrors what adopt_otel_crds already iterates.
    local disable_crds=""
    if kubectl get crd -o name 2>/dev/null | grep -q '\.opentelemetry\.io$'; then
        log_info "Pre-existing OpenTelemetry CRDs detected — force-applying chart CRDs and installing with crds.create=false"

        # NOTE: this script runs under `set -e` but NOT `set -o pipefail`, so a
        # piped `helm template | awk | kubectl apply` would mask an upstream
        # failure (a broken render or a failed apply) and still proceed to
        # crds.create=false — leaving stale/missing CRDs with no error. Capture
        # each stage and check it explicitly instead.
        local rendered_crds
        if ! rendered_crds=$(helm template opentelemetry-operator open-telemetry/opentelemetry-operator \
            --version "$OPERATOR_VERSION" --include-crds --set crds.create=true \
            $HELM_SCHEMA_FLAG 2>&1); then
            log_error "Failed to render opentelemetry-operator CRDs via 'helm template'. Output: $rendered_crds"
        fi

        # Isolate only the CustomResourceDefinition documents from the chart.
        local crd_manifests
        crd_manifests=$(printf '%s\n' "$rendered_crds" \
            | awk 'BEGIN{RS="\n---\n"} /(^|\n)kind: CustomResourceDefinition/ {print "---"; print $0}')

        if ! printf '%s' "$crd_manifests" | grep -q 'kind: CustomResourceDefinition'; then
            log_error "Rendered opentelemetry-operator chart contained no CustomResourceDefinition documents; refusing to install with crds.create=false."
        fi

        if ! printf '%s\n' "$crd_manifests" | kubectl apply --server-side --force-conflicts \
            --field-manager=helm -f -; then
            log_error "Failed to force-apply opentelemetry-operator CRDs (kubectl apply --server-side --force-conflicts)."
        fi

        # Helm tracks these CRDs in the previous release manifest when the first
        # install ran with crds.create=true. Upgrading with crds.create=false
        # drops them from the manifest, so Helm would DELETE them and cascade-
        # delete every Instrumentation / OpenTelemetryCollector CR. Helm skips
        # deleting resources whose live object carries resource-policy=keep.
        local otel_crd
        while IFS= read -r otel_crd; do
            [ -n "$otel_crd" ] || continue
            if ! kubectl annotate crd "${otel_crd##*/}" helm.sh/resource-policy=keep --overwrite; then
                log_error "Failed to annotate $otel_crd with helm.sh/resource-policy=keep; refusing to install with crds.create=false (Helm would delete the CRD and all its custom resources)."
            fi
        done < <(kubectl get crd -o name 2>/dev/null | grep '\.opentelemetry\.io$')
        disable_crds="yes"
    fi

    # Build helm command as array for proper argument handling
    local helm_args=(
        "upgrade" "--install"
        "opentelemetry-operator"
        "open-telemetry/opentelemetry-operator"
        "--version" "$OPERATOR_VERSION"
        "-n" "$NAMESPACE"
        "--create-namespace"
        "--set" "manager.collectorImage.repository=ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-k8s"
        "--set" "admissionWebhooks.certManager.enabled=false"
        "--set" "admissionWebhooks.autoGenerateCert.enabled=true"
    )

    # Disable Helm's CRD rendering when CRDs were pre-existing (handled above)
    if [ -n "$disable_crds" ]; then
        helm_args+=("--set" "crds.create=false")
    fi

    # Add tolerations and nodeSelector if provided
    if [ -n "$TOLERATIONS_FILE_PATH" ]; then
        log_info "Adding tolerations to operator installation..."

        # Note: For operator chart, tolerations and nodeSelector are at root level (no prefix)
        local tolerations_args=$(convert_tolerations_to_helm_set "$TOLERATIONS_FILE_PATH" "")
        local -a split_args
        if [ -n "$tolerations_args" ]; then
            # read -a, not xargs: xargs strips the `\.` escapes Helm needs in dotted keys
            read -r -a split_args <<< "$tolerations_args"
            helm_args+=("${split_args[@]}")
            log_info "✓ Tolerations added to operator"
        fi

        local node_selector_args=$(convert_node_selector_to_helm_set "$TOLERATIONS_FILE_PATH" "")
        if [ -n "$node_selector_args" ]; then
            read -r -a split_args <<< "$node_selector_args"
            helm_args+=("${split_args[@]}")
            log_info "✓ NodeSelector added to operator"
        fi
    fi

    # Add schema validation skip for Helm v4+ compatibility
    if [ -n "$HELM_SCHEMA_FLAG" ]; then
        helm_args+=("$HELM_SCHEMA_FLAG")
    fi

    # Execute helm command
    if ! helm "${helm_args[@]}"; then
        log_error "Helm install/upgrade failed for opentelemetry-operator. See output above."
    fi

    log_info "OpenTelemetry Operator installed!"

    # Wait on the operator's real readiness condition instead of a blind sleep.
    # The operator's mutating admission webhook only serves once its pod is
    # Ready; a fixed sleep races slow clusters (e.g. GKE Autopilot, which
    # schedules a fresh node and injects resource requests), and the downstream
    # Instrumentation apply then fails against an unready webhook. rollout
    # status returns as soon as the deployment is available (faster than a flat
    # 30s on normal clusters) and blocks up to the timeout on slow ones.
    # Non-fatal on timeout: create_instrumentation waits again and surfaces any
    # real error.
    log_info "Waiting for OpenTelemetry Operator deployment to be ready..."
    if ! kubectl rollout status deployment/opentelemetry-operator \
        -n "$NAMESPACE" --timeout="${OPERATOR_READY_TIMEOUT:-180s}"; then
        log_warn "Operator deployment not ready within timeout; continuing (readiness is re-checked before instrumentation)."
    fi
}

# Function to update deployment mode in values file
update_deployment_mode() {
    log_info "Updating deployment mode from daemonset to deployment..."
    
    # Check if the values file exists
    if [ ! -f "last9-otel-collector-values.yaml" ]; then
        log_error "last9-otel-collector-values.yaml not found!"
    fi
    
    # Create backup of original file
    cp last9-otel-collector-values.yaml last9-otel-collector-values.yaml.backup
    log_info "Created backup: last9-otel-collector-values.yaml.backup"
    
    # Replace daemonset with deployment
    sed -i.tmp 's/mode: "daemonset"/mode: "deployment"/' last9-otel-collector-values.yaml
    
    # Disable logsCollection preset for operator-only case (this disables filelog receiver)
    log_info "Disabling logsCollection preset to remove filelog receiver..."
    # Find the logsCollection section and change enabled: true to enabled: false
    awk '/^  logsCollection:/ {in_section=1; print; next} 
         in_section && /^    enabled: true/ {print "    enabled: false"; in_section=0; next}
         in_section && /^  [^ ]/ {in_section=0}
         {print}' last9-otel-collector-values.yaml > last9-otel-collector-values.yaml.tmp2
    mv last9-otel-collector-values.yaml.tmp2 last9-otel-collector-values.yaml
    
    # Comment out filelog receiver in logs pipeline for operator-only case (backup approach)
    log_info "Commenting out filelog receiver in logs pipeline..."
    sed -i.tmp 's/          - filelog/          # - filelog/' last9-otel-collector-values.yaml
    
    # Remove the temporary file created by sed -i
    rm -f last9-otel-collector-values.yaml.tmp
    
    # Verify the changes were made
    if grep -q 'mode: "deployment"' last9-otel-collector-values.yaml; then
        log_info "✓ Deployment mode updated successfully!"
    else
        log_warn "⚠ Could not verify deployment mode update. Please check the file manually."
    fi
    
    if grep -A 1 'logsCollection:' last9-otel-collector-values.yaml | grep -q 'enabled: false'; then
        log_info "✓ LogsCollection preset disabled successfully!"
    else
        log_warn "⚠ Could not verify logsCollection preset disable. Please check the file manually."
    fi
    
    if grep -q '          # - filelog' last9-otel-collector-values.yaml; then
        log_info "✓ Filelog receiver commented out successfully!"
    else
        log_warn "⚠ Could not verify filelog receiver comment. Please check the file manually."
    fi
}

# Function to install OpenTelemetry Collector
install_collector() {
    log_info "Installing OpenTelemetry Collector..."
    
    local values_file="last9-otel-collector-values.yaml"
    if [ -n "$VALUES_FILE" ]; then
        values_file="$VALUES_FILE"
        log_info "Using custom values file: $values_file"
    fi

    prepare_collector_values_file "$values_file" "last9-opentelemetry-collector" "OpenTelemetry Collector"
    
    if ! helm_upgrade_install_with_retry last9-opentelemetry-collector open-telemetry/opentelemetry-collector \
        --version "$COLLECTOR_VERSION" \
        -n "$NAMESPACE" \
        --create-namespace \
        -f "$values_file" \
        $HELM_SCHEMA_FLAG; then
        log_error "Helm install/upgrade failed for last9-opentelemetry-collector. See output above."
    fi

    log_info "OpenTelemetry Collector installed!"
}

# Function to create collector service
create_collector_service() {
    log_info "Creating Collector service..."
    
    # For operator-only mode, update the component selector to standalone-collector
    if [ "$OPERATOR_ONLY" = true ]; then
        log_info "Updating service selector for operator-only mode (component: standalone-collector)..."
        
        # Create a temporary copy of the service file
        cp collector-svc.yaml collector-svc-temp.yaml
        
        # Update the component selector
        sed -i.tmp 's/component: agent-collector/component: standalone-collector/' collector-svc-temp.yaml
        
        # Remove the temporary file created by sed -i
        rm -f collector-svc-temp.yaml.tmp
        
        # Apply the modified service file
        kubectl apply -f collector-svc-temp.yaml -n "$NAMESPACE"
        
        # Clean up temporary file
        rm -f collector-svc-temp.yaml
        
        log_info "✓ Service created with component: standalone-collector"
    else
        # Use the original service file for other modes
        kubectl apply -f collector-svc.yaml -n "$NAMESPACE"
        log_info "✓ Service created with component: agent-collector"
    fi
    
    log_info "Collector service created!"
}

# Function to create instrumentation
create_instrumentation() {
    log_info "Creating Common instrumentation..."

    # The Instrumentation custom resource is gated by the operator's mutating
    # admission webhook. Applying before the operator Deployment is Available
    # (and its webhook endpoints/caBundle are populated) fails with
    # "no endpoints available for service ...-webhook" or a TLS/x509 error.
    # A fixed sleep races this — on slower clusters (e.g. GKE Autopilot, which
    # schedules a fresh node and injects resource requests) the operator can
    # take well over a minute. Wait on the real readiness condition instead of
    # guessing with a timeout. Non-fatal on wait timeout: the apply retry loop
    # below still runs and now surfaces the real error.
    log_info "Waiting for OpenTelemetry Operator deployment to be Available..."
    if ! kubectl wait --for=condition=Available deployment/opentelemetry-operator \
        -n "$NAMESPACE" --timeout="${OPERATOR_READY_TIMEOUT:-180s}" 2>&1; then
        log_warn "Operator deployment not reported Available within timeout; proceeding to apply (will retry and surface any error)."
    fi

    # Retry logic for residual webhook-endpoint/caBundle propagation lag.
    local max_attempts=5
    local attempt=1
    local apply_output=""

    while [ $attempt -le $max_attempts ]; do
        log_info "Attempt $attempt of $max_attempts to create instrumentation..."

        # Capture stderr (do NOT discard it) so a persistent failure surfaces
        # the real API-server rejection instead of a blind "Attempt failed".
        if apply_output=$(kubectl apply -f instrumentation.yaml -n "$NAMESPACE" 2>&1); then
            log_info "✓ Common instrumentation created successfully!"
            return 0
        fi

        log_warn "Attempt $attempt failed: $apply_output"
        if [ $attempt -lt $max_attempts ]; then
            sleep 15
        fi
        attempt=$((attempt + 1))
    done

    log_info "You can try manually: kubectl apply -f instrumentation.yaml -n $NAMESPACE"
    log_error "Failed to create instrumentation after $max_attempts attempts. Last error: $apply_output"
}

# Function to verify installation
verify_installation() {
    log_info "Verifying installation..."
    
    # Check if operator pod is running
    if kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=opentelemetry-operator --no-headers | grep -q "Running"; then
        log_info "✓ OpenTelemetry Operator is running"
    else
        log_warn "⚠ OpenTelemetry Operator may not be ready yet"
    fi
    
    # Check if collector pod is running
    if kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=opentelemetry-collector --no-headers | grep -q "Running"; then
        log_info "✓ OpenTelemetry Collector is running"
    else
        log_warn "⚠ OpenTelemetry Collector may not be ready yet"
    fi
    
    # Show services
    log_info "Services in $NAMESPACE namespace:"
    kubectl get svc -n "$NAMESPACE"
}

# Function to create logs-only configuration
create_logs_only_config() {
    log_info "Creating logs-only configuration..."
    
    local base_values="last9-otel-collector-values.yaml"
    local logs_values="last9-otel-collector-logs-only.yaml"
    
    # Create a copy of the base values file
    cp "$base_values" "$logs_values"
    
    # Disable metrics collection
    log_info "Disabling metrics collection for logs-only setup..."
    sed -i.tmp 's/hostMetrics:/hostMetrics:\n    enabled: false/' "$logs_values"
    sed -i.tmp 's/kubeletMetrics:/kubeletMetrics:\n    enabled: false/' "$logs_values"
    sed -i.tmp 's/clusterMetrics:/clusterMetrics:\n    enabled: false/' "$logs_values"
    
    # Keep logs collection enabled (already enabled by default)
    log_info "Keeping logs collection enabled..."
    
    # Remove temporary files
    rm -f "$logs_values.tmp"
    
    VALUES_FILE="$logs_values"
    log_info "Logs-only values file created: $VALUES_FILE"
}

# Function to detect an existing Prometheus Operator running in the cluster.
# Returns 0 (found) or 1 (not found). Informational only: the bundled operator
# is always disabled now, so a customer operator no longer conflicts with ours,
# but the install still upgrades the cluster-scoped CRDs it relies on.
#
# Detection matches on the container image, not labels: kube-prometheus-stack
# labels its operator app.kubernetes.io/name=<nameOverride>-prometheus-operator,
# Bitnami and jsonnet installs use other labels, so label selectors miss real
# installs and the second operator gets deployed anyway.
detect_existing_prometheus_operator() {
    log_info "Checking for existing Prometheus Operator installation..."

    local found
    found=$(kubectl get deployment -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .spec.template.spec.containers[*]}{.image}{" "}{end}{"\n"}{end}' 2>/dev/null \
        | awk -F'\t' -v ns="$NAMESPACE" '
            $1 == ns { next }
            {
                n = split($3, imgs, " ")
                for (i = 1; i <= n; i++) {
                    repo = imgs[i]
                    sub(/@.*/, "", repo)
                    sub(/.*\//, "", repo)
                    sub(/:.*/, "", repo)
                    if (repo == "prometheus-operator") { print $1 "\t" $2 "\t" imgs[i]; exit }
                }
            }')

    if [ -n "$found" ]; then
        local found_ns found_name found_image
        IFS=$'\t' read -r found_ns found_name found_image <<< "$found"
        log_warn "⚠ Existing Prometheus Operator found: deployment '$found_name' in namespace '$found_ns' ($found_image)."
        log_warn "  Last9 no longer installs its own operator, so it will not conflict;"
        log_warn "  the cluster-scoped Prometheus CRDs may still be upgraded to the chart's version."
        EXISTING_PROMETHEUS_OPERATOR="$found_ns/$found_name"
        EXISTING_PROMETHEUS_OPERATOR_IMAGE="$found_image"
        return 0
    fi

    log_info "No existing Prometheus Operator found."
    return 1
}

# Function to setup Last9 monitoring stack
setup_last9_monitoring() {
    log_info "Setting up Last9 monitoring stack..."
    
    local cluster_name=""
    
    # Parse cluster name from arguments
    for arg in "$@"; do
        case $arg in
            cluster=*)
                cluster_name="${arg#*=}"
                shift
                ;;
        esac
    done
    
    # If cluster name not provided, try to get it from kubectl
    if [ -z "$cluster_name" ]; then
        log_info "Cluster name not provided, attempting to detect from kubectl..."
        cluster_name=$(kubectl config current-context 2>/dev/null || echo "unknown-cluster")
        log_info "Detected cluster name: $cluster_name"
    fi
    
    if [ -z "$cluster_name" ]; then
        log_error "Cluster name is required. Please provide cluster=<cluster-name>"
    fi
    
    log_info "Using cluster name: $cluster_name"
    
    # Use provided credentials
    if [ -z "$LAST9_USERNAME" ] || [ -z "$LAST9_PASSWORD" ]; then
        log_error "Last9 credentials are required for monitoring setup."
        log_error "Please provide username=<value> and password=<value> parameters."
    fi
    
    local username="$LAST9_USERNAME"
    local password="$LAST9_PASSWORD"
    
    log_info "Using Last9 credentials: username=${username:0:8}... password=${password:0:8}..."
    
    # Create the namespace first
    log_info "Creating namespace: $NAMESPACE"
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    log_info "✓ Namespace $NAMESPACE created/verified"
    
    # Create the secret for Last9 remote write
    log_info "Creating Last9 remote write secret..."
    kubectl create secret generic last9-remote-write-secret \
        -n "$NAMESPACE" \
        --from-literal=username="$username" \
        --from-literal=password="$password" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_info "✓ Last9 remote write secret created"
    
    # Check if k8s-monitoring-values.yaml exists
    if [ ! -f "k8s-monitoring-values.yaml" ]; then
        log_error "k8s-monitoring-values.yaml not found in current directory"
    fi
    # The cluster name and endpoint now live only in the OTel scraper values
    # (rendered by install_metrics_scraper); k8s-monitoring-values.yaml has no
    # placeholders left and is used as-is.

    # Load tolerations if provided (needed for kubectl patching later)
    # NOTE: We skip apply_tolerations_to_monitoring_values() to avoid yq lexer issues
    # and rely on kubectl patch approach which is more reliable
    if [ -n "$TOLERATIONS_FILE" ]; then
        # Load tolerations if not already loaded
        if [ -z "$TOLERATIONS_FILE_PATH" ]; then
            load_tolerations_from_file "$TOLERATIONS_FILE"
        fi
        log_info "Tolerations will be applied via kubectl patch after Helm install"
    fi

    # Add prometheus-community repo if not already added
    log_info "Adding prometheus-community Helm repository..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update prometheus-community

    # Detect an existing cluster-wide Prometheus Operator (informational; the bundled
    # operator is always disabled now that no Prometheus/PrometheusAgent is deployed).
    detect_existing_prometheus_operator || true

    # A pre-existing last9-k8s-monitoring release means we are migrating an install that
    # still runs the bundled Prometheus: bring the OTel scraper up first so there is no
    # gap in metrics, then flip Prometheus off.
    # Run helm list on its own and check its exit status: a helm/API failure must never be
    # read as "no release" (that would take the fresh path and flip Prometheus off before verify).
    local migrating=false release_list
    local list_err
    list_err=$(mktemp)
    if ! release_list=$(helm list -n "$NAMESPACE" --filter "^last9-k8s-monitoring$" -q 2>"$list_err"); then
        log_error "Could not list Helm releases in namespace $NAMESPACE: $(cat "$list_err"). No Helm releases were changed; fix cluster access and re-run."
    fi
    rm -f "$list_err"
    if printf '%s\n' "$release_list" | grep -qx last9-k8s-monitoring; then
        migrating=true
    fi

    # Adopt any pre-existing Prometheus operator CRDs (monitoring.coreos.com)
    # into the last9-k8s-monitoring release before Helm tries to manage them.
    # This prevents Helm v4 SSA field-manager conflicts (e.g. CRDs owned by
    # kubectl-client-side-apply or terraform-provider-helm).
    #
    # When CRDs already exist (e.g. installed by Terraform), SSA field-manager
    # migration via --force-conflicts can silently fail if the existing manager
    # holds conflicting entries. In that case Helm's CRD installer still errors.
    # The safest fix: skip CRD installation entirely when CRDs are pre-existing
    # (they stay in place; Helm only needs to own the release resources).
    local skip_crds_flag=""
    if kubectl get crd alertmanagerconfigs.monitoring.coreos.com &>/dev/null 2>&1; then
        log_info "Pre-existing Prometheus CRDs detected — upgrading schemas to chart version before install"
        # Terraform-managed CRDs may be older than the chart expects. Apply the
        # chart's CRD manifests directly with --force-conflicts so the schemas are
        # updated to the version the chart requires (e.g. PrometheusAgent.spec.tsdb,
        # ServiceMonitor trackTimestampsStaleness) without removing the CRDs.
        local crd_yaml=""
        if crd_yaml=$(helm show crds prometheus-community/kube-prometheus-stack \
                --version "$MONITORING_VERSION" 2>/dev/null) && [ -n "$crd_yaml" ]; then
            echo "$crd_yaml" | kubectl apply --server-side --force-conflicts \
                --field-manager=helm -f - 2>&1 | grep -v "^$" || true
        else
            log_warn "Could not fetch chart CRD manifests; skipping schema upgrade (install will use --skip-crds)"
        fi
        skip_crds_flag="--skip-crds"
    fi
    adopt_prometheus_crds

    local scraper_healthy=true
    if [ "$migrating" = true ]; then
        log_info "Existing last9-k8s-monitoring release found: migrating to the OTel metrics scraper"
        if ! install_metrics_scraper "$cluster_name" || ! verify_metrics_scraper; then
            if [ -n "$(kubectl get statefulset -n "$NAMESPACE" -l operator.prometheus.io/name -o name 2>/dev/null)" ]; then
                log_error "OTel metrics scraper did not become healthy. The bundled Prometheus is still running and was not modified. Fix the issue above and re-run this script."
            else
                log_error "OTel metrics scraper did not become healthy and no bundled Prometheus is running, so cluster metrics may not be reaching Last9. Fix the issue above and re-run this script."
            fi
        fi
        install_monitoring_stack "$skip_crds_flag"
        cleanup_orphaned_kubelet_service
    else
        install_monitoring_stack "$skip_crds_flag"
        if ! install_metrics_scraper "$cluster_name" || ! verify_metrics_scraper; then
            scraper_healthy=false
            log_warn "OTel metrics scraper installation/verification failed (see output above). Continuing; fix the issue and re-run this script."
        fi
    fi

    # Patch monitoring components with tolerations and nodeSelector if provided
    # This is the primary method for applying tolerations (more reliable than Helm values)
    if [ -n "$TOLERATIONS_FILE" ]; then
        patch_monitoring_components_tolerations
    fi

    # Show the deployed resources
    log_info "Monitoring stack resources in last9 namespace:"
    kubectl get pods -n last9 -l "app.kubernetes.io/instance=last9-otel-metrics" 2>/dev/null || true
    kubectl get pods -n last9 -l "app.kubernetes.io/instance=last9-target-allocator" 2>/dev/null || true
    kubectl get pods -n last9 -l "app.kubernetes.io/name=kube-state-metrics" 2>/dev/null || true
    kubectl get pods -n last9 -l "app.kubernetes.io/name=node-exporter" 2>/dev/null || true
    
    log_info "🎉 Last9 monitoring stack setup completed!"
    echo ""
    echo "Summary:"
    if [ "$scraper_healthy" != true ]; then
        echo "  ⚠ WARNING: the OTel metrics scraper is NOT verified healthy; no cluster metrics may be reaching Last9. Re-run this script after fixing the errors above."
    fi
    echo "  ✓ Created secret: last9-remote-write-secret"
    if [ "$scraper_healthy" = true ]; then
        echo "  ✓ Deployed OTel metrics scraper (collector + target allocator) with cluster name: $cluster_name"
    else
        echo "  ✗ OTel metrics scraper deployed but NOT verified (cluster name: $cluster_name)"
    fi
    echo "  ✓ Deployed kube-state-metrics and node-exporter (kube-prometheus-stack, Prometheus disabled)"
    echo ""
    echo "To verify the deployment:"
    echo "  kubectl get pods -n last9"
    echo "  kubectl get secrets -n last9 last9-remote-write-secret"
    echo "  kubectl get pods -n last9 -l app.kubernetes.io/instance=last9-otel-metrics"
}

# Delete the kubelet Service the old bundled operator created in kube-system (now orphaned and stale).
# Only our release's exact Service name AND the prometheus-operator managed-by label qualify;
# a customer operator's Service has a different name and is never touched.
cleanup_orphaned_kubelet_service() {
    local svc="last9-k8s-monitoring-kube-kubelet" managed_by
    managed_by=$(kubectl get service "$svc" -n kube-system --ignore-not-found \
        -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)
    if [ "$managed_by" = "prometheus-operator" ]; then
        log_info "Deleting orphaned operator-created kubelet Service kube-system/$svc"
        kubectl delete service "$svc" -n kube-system --ignore-not-found \
            || log_warn "Could not delete kube-system/$svc (harmless; delete it manually)"
    fi
}

# Install/upgrade kube-prometheus-stack with Prometheus, the bundled operator and the kubelet
# ServiceMonitor disabled via k8s-monitoring-values.yaml (still provides CRDs, kube-state-metrics, node-exporter). $1 = extra skip-crds flag.
install_monitoring_stack() {
    log_info "Installing/upgrading Last9 K8s monitoring stack..."
    if ! helm_upgrade_install_with_retry last9-k8s-monitoring prometheus-community/kube-prometheus-stack \
        --version "$MONITORING_VERSION" \
        -n "$NAMESPACE" \
        -f k8s-monitoring-values.yaml \
        --create-namespace \
        $HELM_SCHEMA_FLAG \
        $1; then
        log_error "Helm install/upgrade failed for last9-k8s-monitoring. See output above."
    fi
    log_info "✓ Last9 K8s monitoring stack deployed successfully!"
}

# Replace every literal occurrence of $2 with $3 in file $1 (no regex/& interpretation).
replace_literal_in_file() {
    local file="$1"
    P="$2" V="$3" awk '{
        out = ""; line = $0
        while ((i = index(line, ENVIRON["P"])) > 0) {
            out = out substr(line, 1, i - 1) ENVIRON["V"]
            line = substr(line, i + length(ENVIRON["P"]))
        }
        print out line
    }' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# Install the OTel metrics scraper: standalone Target Allocator, then the StatefulSet collector.
# $1 = cluster name. Uses MONITORING_ENDPOINT and APP_METRICS_KEEP. Returns non-zero on failure.
install_metrics_scraper() {
    local cluster_name="$1"
    local ta_values="last9-target-allocator-values.yaml"
    local col_src="last9-otel-metrics-values.yaml"
    local col_values="last9-otel-metrics-values.rendered.yaml"

    log_info "Installing OTel metrics scraper (Target Allocator + collector)..."
    if [ -z "$MONITORING_ENDPOINT" ]; then
        log_warn "Monitoring endpoint is empty; pass monitoring-endpoint=<value>"
        return 1
    fi
    if [ ! -f "$ta_values" ] || [ ! -f "$col_src" ]; then
        log_warn "$ta_values or $col_src not found in current directory"
        return 1
    fi

    # Working copy: never modify the committed values file.
    # The keep regex lands inside an OTTL double-quoted string within a YAML single-quoted
    # string: OTTL needs \ and " escaped, YAML needs ' doubled.
    local keep_alt=""
    if [ -n "$APP_METRICS_KEEP" ]; then
        keep_alt="|$(printf '%s' "$APP_METRICS_KEEP" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/'/''/g")"
    fi
    cp "$col_src" "$col_values"
    replace_literal_in_file "$col_values" "{{LAST9_METRICS_ENDPOINT}}" "$MONITORING_ENDPOINT"
    replace_literal_in_file "$col_values" "{{CLUSTER_NAME}}" "$cluster_name"
    replace_literal_in_file "$col_values" "{{APP_METRICS_KEEP_ALT}}" "$keep_alt"
    if [ -n "$SERVER_NAME" ]; then
        # server-name= keeps its meaning: TLS SNI/verification override on the remote-write exporter.
        S="$SERVER_NAME" awk '{ print } /^      endpoint: / && !d { print "      tls:"; print "        server_name_override: \"" ENVIRON["S"] "\""; d = 1 }' \
            "$col_values" > "${col_values}.tmp" && mv "${col_values}.tmp" "$col_values"
    fi

    # Tolerations/nodeSelector: both charts take them at the values root.
    local -a scheduling_args=()
    if [ -n "$TOLERATIONS_FILE" ] && [ -z "$TOLERATIONS_FILE_PATH" ]; then
        load_tolerations_from_file "$TOLERATIONS_FILE"
    fi
    if [ -n "$TOLERATIONS_FILE_PATH" ]; then
        # read -a splits on whitespace without xargs' backslash processing, so `kubernetes\.io` stays one key.
        read -r -a scheduling_args <<< "$(convert_tolerations_to_helm_set "$TOLERATIONS_FILE_PATH" "") $(convert_node_selector_to_helm_set "$TOLERATIONS_FILE_PATH" "")"
    fi

    if ! helm_upgrade_install_with_retry last9-target-allocator open-telemetry/opentelemetry-target-allocator \
        --version "$TA_VERSION" \
        -n "$NAMESPACE" \
        --create-namespace \
        -f "$ta_values" \
        "${scheduling_args[@]}" \
        $HELM_SCHEMA_FLAG; then
        log_warn "Helm install/upgrade failed for last9-target-allocator"
        return 1
    fi

    # The collector reads the secret via env at start; a credential change must roll the pod.
    # Only a hash reaches helm/the pod spec, never the credentials.
    local rw_checksum
    rw_checksum=$(printf '%s:%s' "$LAST9_USERNAME" "$LAST9_PASSWORD" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)

    if ! helm_upgrade_install_with_retry last9-otel-metrics open-telemetry/opentelemetry-collector \
        --version "$COLLECTOR_VERSION" \
        -n "$NAMESPACE" \
        -f "$col_values" \
        --set-string "podAnnotations.last9\\.io/rw-credentials-checksum=$rw_checksum" \
        "${scheduling_args[@]}" \
        $HELM_SCHEMA_FLAG; then
        log_warn "Helm install/upgrade failed for last9-otel-metrics"
        return 1
    fi

    log_info "✓ OTel metrics scraper installed"
}

# Wait until the Target Allocator serves the core scrape jobs and the collector exports samples.
# Returns 0 when healthy, 1 (after warning what is missing) on timeout.
verify_metrics_scraper() {
    local timeout="${VERIFY_SCRAPER_TIMEOUT:-180}" interval="${VERIFY_SCRAPER_INTERVAL:-10}"
    local waited=0 missing configs metrics totals sent failed
    local prev_sent="" prev_failed=""
    local ta_proxy="/api/v1/namespaces/$NAMESPACE/services/last9-target-allocator-ta:80/proxy"
    local col_proxy="/api/v1/namespaces/$NAMESPACE/pods/last9-otel-metrics-0:8888/proxy"
    # Collector's local `up` exporter (pipeline metrics/scrape_health in last9-otel-metrics-values.yaml)
    local health_proxy="/api/v1/namespaces/$NAMESPACE/pods/last9-otel-metrics-0:9465/proxy"
    local pf_dir ta_pid="" col_pid="" health_pid="" ta_port="" col_port="" health_port=""
    pf_dir=$(mktemp -d)
    # The apiserver proxy is blocked on some private clusters; fall back to kubectl port-forward
    # on a random free local port. Forwards are reused across polls and always killed on return.
    trap '{ [ -z "$ta_pid" ] || kill "$ta_pid" 2>/dev/null || true; }; { [ -z "$col_pid" ] || kill "$col_pid" 2>/dev/null || true; }; { [ -z "$health_pid" ] || kill "$health_pid" 2>/dev/null || true; }; rm -rf "$pf_dir"; trap - RETURN' RETURN

    # $1 = ta|col|health. Runs in the main shell (state lives in the <who>_pid/<who>_port vars):
    # prefers the apiserver proxy; otherwise (re)starts a port-forward and records its local port.
    scraper_access() {
        local who="$1" probe ref rport pid port="" i log="$pf_dir/$1.log"
        case "$who" in
            ta) probe="$ta_proxy/scrape_configs"; ref="svc/last9-target-allocator-ta"; rport=80; pid=$ta_pid ;;
            col) probe="$col_proxy/metrics"; ref="pod/last9-otel-metrics-0"; rport=8888; pid=$col_pid ;;
            health) probe="$health_proxy/metrics"; ref="pod/last9-otel-metrics-0"; rport=9465; pid=$health_pid ;;
        esac
        if kubectl get --raw "$probe" >/dev/null 2>&1; then
            { [ -z "$pid" ] || kill "$pid" 2>/dev/null || true; }
            pid=""
        elif [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
            : > "$log"
            kubectl port-forward -n "$NAMESPACE" "$ref" ":$rport" >"$log" 2>&1 &
            pid=$!
            for i in 1 2 3 4 5 6 7 8 9 10; do
                port=$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9][0-9]*\) .*/\1/p' "$log" | head -1)
                [ -n "$port" ] && break
                sleep 0.5
            done
        else
            port=$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9][0-9]*\) .*/\1/p' "$log" | head -1)
        fi
        case "$who" in
            ta) ta_pid=$pid; ta_port=$port ;;
            col) col_pid=$pid; col_port=$port ;;
            health) health_pid=$pid; health_port=$port ;;
        esac
    }

    # $1 = ta|col|health, $2 = path. Pure read (safe in $(...)); non-zero when unreachable.
    scraper_get() {
        local who="$1" path="$2" port proxy
        case "$who" in
            ta) port=$ta_port; proxy=$ta_proxy ;;
            col) port=$col_port; proxy=$col_proxy ;;
            health) port=$health_port; proxy=$health_proxy ;;
        esac
        if [ -n "$port" ]; then
            curl -fsS --max-time 10 "http://127.0.0.1:$port$path" 2>/dev/null
        else
            kubectl get --raw "$proxy$path" 2>/dev/null
        fi
    }

    log_info "Verifying OTel metrics scraper (up to ${timeout}s)..."
    while true; do
        missing=""
        scraper_access ta
        scraper_access col
        scraper_access health
        configs=$(scraper_get ta /scrape_configs || true)
        # Scope to this release's ServiceMonitors (TA job names: serviceMonitor/<ns>/<name>/<n>);
        # a customer's own KSM/node-exporter ServiceMonitor must not satisfy the check.
        printf '%s' "$configs" | grep -q "serviceMonitor/$NAMESPACE/[^\"]*kube-state-metrics" || missing="$missing target-allocator-job:kube-state-metrics"
        printf '%s' "$configs" | grep -q "serviceMonitor/$NAMESPACE/[^\"]*node-exporter" || missing="$missing target-allocator-job:node-exporter"
        printf '%s' "$configs" | grep -q '"kubelet"' || missing="$missing target-allocator-job:kubelet"
        # Job presence is not enough: kubelet discovery must yield at least one target.
        scraper_get ta /jobs/kubelet/targets 2>/dev/null \
            | grep -q '"targets": *\["' || missing="$missing kubelet-targets(0)"
        metrics=$(scraper_get col /metrics || true)
        # Sum series by name prefix; collector 0.156 may or may not append _total.
        totals=$(printf '%s\n' "$metrics" | awk '
            /^#/ { next }
            { n = $1; sub(/\{.*/, "", n) }
            n ~ /^otelcol_exporter_sent_metric_points(_total)?$/ { sent += $NF }
            n ~ /^otelcol_exporter_send_failed_metric_points(_total)?$/ { failed += $NF }
            END { print sent + 0, failed + 0 }')
        sent=${totals% *}; failed=${totals#* }
        # Judge export health as a delta between consecutive polls: a cumulative failed>0
        # from an earlier transient blip must not block forever.
        if [ -z "$prev_sent" ]; then
            missing="$missing collector-export(need 2 polls)"
        elif ! awk -v s="$sent" -v ps="$prev_sent" -v f="$failed" -v pf="$prev_failed" 'BEGIN { exit !(s > ps && f <= pf) }'; then
            missing="$missing collector-export(sent must grow, failed must not)"
        fi
        prev_sent=$sent; prev_failed=$failed
        # Exports alone are not proof: a blocked scrape still exports a synthetic up=0.
        # Require a successful scrape (up == 1) of each core target this release ships.
        missing="$missing$(scraper_get health /metrics 2>/dev/null | NS="$NAMESPACE" awk '
            function label(name,   m) {
                if (match($0, "[{,]" name "=\"[^\"]*\"")) { m = substr($0, RSTART, RLENGTH); sub(/^[^"]*"/, "", m); sub(/"$/, "", m); return m }
                return ""
            }
            !/^up\{/ || $NF != 1 { next }
            { job = label("job"); ns = label("namespace"); path = label("metrics_path") }
            job == "kube-state-metrics" && ns == ENVIRON["NS"] { ok["kube-state-metrics"] = 1 }
            job == "node-exporter" && ns == ENVIRON["NS"] { ok["node-exporter"] = 1 }
            job == "kubelet" && path == "/metrics" { ok["kubelet"] = 1 }
            job == "kubelet" && path == "/metrics/cadvisor" { ok["cadvisor"] = 1 }
            END {
                split("kube-state-metrics node-exporter kubelet cadvisor", want, " ")
                for (i = 1; i <= 4; i++) if (!(want[i] in ok)) printf " scrape-up:%s", want[i]
            }')"

        if [ -z "$missing" ]; then
            log_info "✓ OTel metrics scraper is healthy"
            return 0
        fi
        if [ "$waited" -ge "$timeout" ]; then
            log_warn "OTel metrics scraper not healthy after ${timeout}s; missing:$missing"
            return 1
        fi
        sleep "$interval"
        waited=$((waited + interval))
    done
}

# Remove the scraper releases (collector first); tolerates releases that are not installed.
uninstall_metrics_scraper() {
    local rel
    for rel in last9-otel-metrics last9-target-allocator; do
        log_info "Uninstalling $rel..."
        helm uninstall "$rel" -n "$NAMESPACE" || log_warn "Failed to uninstall $rel (may not be installed)"
    done
}

# Function to update auth token in events agent values file
update_events_agent_auth_token() {
    log_info "Updating auth token in last9-kube-events-agent-values.yaml..."

    # Check if the values file exists
    if [ ! -f "last9-kube-events-agent-values.yaml" ]; then
        log_warn "⚠ last9-kube-events-agent-values.yaml not found, skipping token update"
        return
    fi

    # Create backup of original file
    cp last9-kube-events-agent-values.yaml last9-kube-events-agent-values.yaml.backup
    log_info "Created backup: last9-kube-events-agent-values.yaml.backup"

    # Replace placeholder with actual token
    log_info "Using auth token: ${AUTH_TOKEN:0:20}..."

    # Handle multiple placeholder formats
    if grep -q '{{AUTH_TOKEN}}' last9-kube-events-agent-values.yaml; then
        log_info "Found {{AUTH_TOKEN}} placeholder"
        escaped_token=$(escape_for_sed "$AUTH_TOKEN")
        sed -i.tmp "s|{{AUTH_TOKEN}}|$escaped_token|g" last9-kube-events-agent-values.yaml
    elif grep -q '${AUTH_TOKEN}' last9-kube-events-agent-values.yaml; then
        log_info "Found \${AUTH_TOKEN} placeholder"
        escaped_token=$(escape_for_sed "$AUTH_TOKEN")
        sed -i.tmp "s|\${AUTH_TOKEN}|$escaped_token|g" last9-kube-events-agent-values.yaml
    else
        log_warn "⚠ No auth token placeholder found in events agent values file."
        log_warn "Assuming credentials are already configured."
    fi

    # Remove the temporary file created by sed -i
    rm -f last9-kube-events-agent-values.yaml.tmp
}

# Function to update OTEL endpoint in events agent values file
update_events_agent_endpoint() {
    log_info "Updating OTEL endpoint in last9-kube-events-agent-values.yaml..."

    # Check if the values file exists
    if [ ! -f "last9-kube-events-agent-values.yaml" ]; then
        log_warn "⚠ last9-kube-events-agent-values.yaml not found, skipping endpoint update"
        return
    fi

    # Replace placeholder with actual endpoint
    log_info "Using OTEL endpoint: ${OTEL_ENDPOINT:0:30}..."

    # Handle multiple placeholder formats
    if grep -q '{{OTEL_ENDPOINT}}' last9-kube-events-agent-values.yaml; then
        log_info "Found {{OTEL_ENDPOINT}} placeholder"
        escaped_endpoint=$(escape_for_sed "$OTEL_ENDPOINT")
        sed -i.tmp "s|{{OTEL_ENDPOINT}}|$escaped_endpoint|g" last9-kube-events-agent-values.yaml
    elif grep -q '\${OTEL_ENDPOINT}' last9-kube-events-agent-values.yaml; then
        log_info "Found \${OTEL_ENDPOINT} placeholder"
        escaped_endpoint=$(escape_for_sed "$OTEL_ENDPOINT")
        sed -i.tmp "s|\${OTEL_ENDPOINT}|$escaped_endpoint|g" last9-kube-events-agent-values.yaml
    else
        log_warn "⚠ No OTEL endpoint placeholder found in events agent values file."
        log_warn "Assuming endpoint is already configured."
    fi

    # Remove the temporary file created by sed -i
    rm -f last9-kube-events-agent-values.yaml.tmp
}

# Function to install Kubernetes Events Agent
install_events_agent() {
    log_info "Setting up Kubernetes Events Agent..."

    # Create the namespace first
    log_info "Creating namespace: $NAMESPACE"
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    log_info "✓ Namespace $NAMESPACE created/verified"

    # Check if last9-kube-events-agent-values.yaml exists
    if [ ! -f "last9-kube-events-agent-values.yaml" ]; then
        log_error "last9-kube-events-agent-values.yaml not found in current directory"
    fi

    # Update auth token and endpoint in events agent values file
    update_events_agent_auth_token
    update_events_agent_endpoint

    prepare_collector_values_file "last9-kube-events-agent-values.yaml" "last9-kube-events-agent" "Kubernetes Events Agent"

    # Inject TLS server name override if provided (no-op when unset)
    inject_collector_tls_server_name "last9-kube-events-agent-values.yaml"

    # Add cluster name attribute to events agent values file
    update_events_agent_cluster_name

    # Install/upgrade the events agent
    log_info "Installing/upgrading Last9 Kubernetes Events Agent..."
    if ! helm_upgrade_install_with_retry last9-kube-events-agent open-telemetry/opentelemetry-collector \
        --version 0.165.0 \
        -n "$NAMESPACE" \
        --create-namespace \
        -f last9-kube-events-agent-values.yaml \
        $HELM_SCHEMA_FLAG; then
        log_error "Helm install/upgrade failed for last9-kube-events-agent. See output above."
    fi

    log_info "✓ Last9 Kubernetes Events Agent deployed successfully!"

    # Show the deployed resources
    log_info "Events agent resources in $NAMESPACE namespace:"
    kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=last9-kube-events-agent" 2>/dev/null || true

    log_info "🎉 Kubernetes Events Agent setup completed!"
    echo ""
    echo "Summary:"
    echo "  ✓ Deployed opentelemetry-collector for Kubernetes events"
    echo "  ✓ Added cluster.name attribute to events agent configuration"
    echo "  ✓ Events will be collected and sent to Last9"
    echo ""
    echo "To verify the deployment:"
    echo "  kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=last9-kube-events-agent"
    echo "  kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=last9-kube-events-agent"
}

# Function to uninstall Last9 monitoring stack
uninstall_last9_monitoring() {
    log_info "🗑️  Starting Last9 monitoring stack uninstallation..."
    
    # Ask for confirmation
    echo ""
    log_warn "This will remove the Last9 monitoring stack components"
    echo "Components to be removed:"
    echo "  - Helm chart: last9-k8s-monitoring (kube-prometheus-stack)"
    echo "  - Helm charts: last9-otel-metrics, last9-target-allocator (OTel metrics scraper)"
    echo "  - Secret: last9-remote-write-secret"
    echo "  - Namespace 'last9' (only if empty after cleanup)"
    echo ""
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Uninstall cancelled."
        exit 0
    fi
    
    log_info "Proceeding with uninstallation..."
    
    # Remove the Helm chart
    if helm list -n last9 2>/dev/null | grep -q "last9-k8s-monitoring"; then
        log_info "Uninstalling Last9 K8s monitoring stack..."
        helm uninstall last9-k8s-monitoring -n last9 || log_warn "Failed to uninstall monitoring chart"
    else
        log_info "Last9 K8s monitoring stack chart not found"
    fi

    uninstall_metrics_scraper
    
    # Remove the secret
    log_info "Removing Last9 remote write secret..."
    kubectl delete secret last9-remote-write-secret -n last9 --ignore-not-found=true 2>/dev/null || true
    
    # Wait for Helm resources to be cleaned up
    log_info "Waiting for Helm resources to be cleaned up..."
    sleep 10
    
    # Check if namespace is empty and offer to delete it
    log_info "Checking if namespace 'last9' is empty..."
    remaining_resources=$(kubectl get all -n last9 --no-headers 2>/dev/null | wc -l || echo "0")
    
    if [ "$remaining_resources" -eq 0 ]; then
        log_info "Namespace 'last9' appears to be empty."
        read -p "Do you want to delete the empty namespace 'last9'? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kubectl delete namespace last9 --ignore-not-found=true
            log_info "✓ Namespace 'last9' deleted"
        else
            log_info "Keeping namespace 'last9'"
        fi
    else
        log_info "Namespace 'last9' contains other resources. Keeping namespace."
        echo "Remaining resources in namespace:"
        kubectl get all -n last9 2>/dev/null || true
    fi
    
    log_info "🎉 Last9 monitoring stack uninstallation completed!"
    echo ""
    echo "Summary of actions taken:"
    echo "  ✓ Removed Helm chart: last9-k8s-monitoring"
    echo "  ✓ Removed secret: last9-remote-write-secret"
    echo "  ✓ Preserved other resources in namespace (if any)"
    echo ""
    echo "To verify cleanup, run:"
    echo "  helm list -n last9 | grep last9-k8s-monitoring  # Should return nothing"
    echo "  kubectl get secrets -n last9 last9-remote-write-secret  # Should return nothing"
}

# Function to uninstall Kubernetes Events Agent
uninstall_events_agent() {
    log_info "🗑️  Starting Kubernetes Events Agent uninstallation..."

    # Ask for confirmation
    echo ""
    log_warn "This will remove the Kubernetes Events Agent"
    echo "Components to be removed:"
    echo "  - Helm chart: last9-kube-events-agent"
    echo ""
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Uninstall cancelled."
        exit 0
    fi

    log_info "Proceeding with uninstallation..."

    # Remove the Helm chart
    if helm list -n "$NAMESPACE" 2>/dev/null | grep -q "last9-kube-events-agent"; then
        log_info "Uninstalling Kubernetes Events Agent..."
        helm uninstall last9-kube-events-agent -n "$NAMESPACE" || log_warn "Failed to uninstall events agent chart"
    else
        log_info "Kubernetes Events Agent chart not found"
    fi

    # Wait for Helm resources to be cleaned up
    log_info "Waiting for Helm resources to be cleaned up..."
    sleep 5

    log_info "🎉 Kubernetes Events Agent uninstallation completed!"
    echo ""
    echo "Summary of actions taken:"
    echo "  ✓ Removed Helm chart: last9-kube-events-agent"
    echo ""
    echo "To verify cleanup, run:"
    echo "  helm list -n $NAMESPACE | grep last9-kube-events-agent  # Should return nothing"
    echo "  kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=last9-kube-events-agent  # Should return nothing"
}

# Function to uninstall OpenTelemetry components
uninstall_opentelemetry() {
    log_info "🗑️  Starting OpenTelemetry uninstallation..."
    
    # Ask for confirmation
    echo ""
    log_warn "This will remove ONLY the OpenTelemetry components installed by this script"
    echo "Components to be removed:"
    echo "  - Helm chart: last9-opentelemetry-collector"
    echo "  - Helm chart: opentelemetry-operator"
    echo "  - Helm chart: last9-k8s-monitoring (if exists)"
    echo "  - Service: collector-svc (from collector-svc.yaml)"
    echo "  - Instrumentation: from instrumentation.yaml"
    echo "  - Secret: last9-remote-write-secret (if exists)"
    echo "  - Namespace '$NAMESPACE' (only if empty after cleanup)"
    echo ""
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Uninstall cancelled."
        exit 0
    fi
    
    log_info "Proceeding with uninstallation..."
    
    # Step 1: Remove specific Helm charts installed by this script
    log_info "Removing Helm charts installed by this script..."
    
    # Remove OpenTelemetry Collector (specific release name from our script)
    if helm list -n "$NAMESPACE" 2>/dev/null | grep -q "last9-opentelemetry-collector"; then
        log_info "Uninstalling OpenTelemetry Collector (last9-opentelemetry-collector)..."
        helm uninstall last9-opentelemetry-collector -n "$NAMESPACE" || log_warn "Failed to uninstall collector chart"
    else
        log_info "OpenTelemetry Collector chart (last9-opentelemetry-collector) not found"
    fi
    
    # Remove OpenTelemetry Operator (specific release name from our script)
    if helm list -n "$NAMESPACE" 2>/dev/null | grep -q "opentelemetry-operator"; then
        log_info "Uninstalling OpenTelemetry Operator (opentelemetry-operator)..."
        helm uninstall opentelemetry-operator -n "$NAMESPACE" || log_warn "Failed to uninstall operator chart"
    else
        log_info "OpenTelemetry Operator chart (opentelemetry-operator) not found"
    fi
    
    # Remove Last9 K8s monitoring stack (if exists)
    if helm list -n "last9" 2>/dev/null | grep -q "last9-k8s-monitoring"; then
        log_info "Uninstalling Last9 K8s monitoring stack (last9-k8s-monitoring)..."
        helm uninstall last9-k8s-monitoring -n "last9" || log_warn "Failed to uninstall monitoring chart"
    else
        log_info "Last9 K8s monitoring stack chart (last9-k8s-monitoring) not found"
    fi
    
    # Wait for Helm resources to be cleaned up
    log_info "Waiting for Helm resources to be cleaned up..."
    sleep 10
    
    # Step 2: Remove specific Kubernetes resources created by our YAML files
    log_info "Removing specific Kubernetes resources created by this script..."
    
    # Remove instrumentation from instrumentation.yaml
    # Try to identify the instrumentation by common names or labels
    log_info "Removing instrumentation resources..."
    kubectl delete instrumentation l9-instrumentation -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || log_info "No instrumentation resource found"
    
    # Remove service from collector-svc.yaml
    # Common service names that might be in collector-svc.yaml
    log_info "Removing collector service..."
    potential_services=("collector-service" "otel-collector-service" "opentelemetry-collector" "last9-collector" "collector")
    for svc in "${potential_services[@]}"; do
        if kubectl get service "$svc" -n "$NAMESPACE" >/dev/null 2>&1; then
            kubectl delete service "$svc" -n "$NAMESPACE" --ignore-not-found=true
            log_info "Removed service: $svc"
        fi
    done
    
    # Step 3: Clean up any remaining resources with OpenTelemetry labels
    log_info "Cleaning up resources with OpenTelemetry labels..."
    
    # Remove resources with app.kubernetes.io/name=opentelemetry-*
    kubectl delete all -l "app.kubernetes.io/name=opentelemetry-operator" -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
    kubectl delete all -l "app.kubernetes.io/name=opentelemetry-collector" -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
    
    # Remove configmaps and secrets created by our installation
    kubectl delete configmaps -l "app.kubernetes.io/name=opentelemetry-operator" -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
    kubectl delete configmaps -l "app.kubernetes.io/name=opentelemetry-collector" -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
    kubectl delete secrets -l "app.kubernetes.io/name=opentelemetry-operator" -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
    kubectl delete secrets -l "app.kubernetes.io/name=opentelemetry-collector" -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
    
    # Remove RBAC resources created by our installation
    kubectl delete serviceaccounts -l "app.kubernetes.io/name=opentelemetry-operator" -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
    kubectl delete roles -l "app.kubernetes.io/name=opentelemetry-operator" -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
    kubectl delete rolebindings -l "app.kubernetes.io/name=opentelemetry-operator" -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
    
    # Remove Last9 monitoring secret (if exists)
    log_info "Removing Last9 monitoring secret..."
    kubectl delete secret last9-remote-write-secret -n "last9" --ignore-not-found=true 2>/dev/null || true
    
    # Step 4: Check if namespace is empty and offer to delete it
    log_info "Checking if namespace '$NAMESPACE' is empty..."
    remaining_resources=$(kubectl get all -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l || echo "0")
    
    if [ "$remaining_resources" -eq 0 ]; then
        log_info "Namespace '$NAMESPACE' appears to be empty."
        read -p "Do you want to delete the empty namespace '$NAMESPACE'? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kubectl delete namespace "$NAMESPACE" --ignore-not-found=true
            log_info "✓ Namespace '$NAMESPACE' deleted"
        else
            log_info "Keeping namespace '$NAMESPACE'"
        fi
    else
        log_info "Namespace '$NAMESPACE' contains other resources. Keeping namespace."
        echo "Remaining resources in namespace:"
        kubectl get all -n "$NAMESPACE" 2>/dev/null || true
    fi
    
    # Step 5: Only remove CRDs if no OpenTelemetry resources exist anywhere
    log_info "Checking OpenTelemetry CRDs..."
    if kubectl get crd instrumentations.opentelemetry.io >/dev/null 2>&1; then
        # Check if any instrumentation resources exist across all namespaces
        total_instrumentations=$(kubectl get instrumentations --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
        total_collectors=$(kubectl get opentelemetrycollectors --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
        
        if [ "$total_instrumentations" -eq 0 ] && [ "$total_collectors" -eq 0 ]; then
            read -p "No OpenTelemetry resources found cluster-wide. Remove OpenTelemetry CRDs? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                log_info "Removing OpenTelemetry CRDs..."
                kubectl delete crd instrumentations.opentelemetry.io --ignore-not-found=true || true
                kubectl delete crd opentelemetrycollectors.opentelemetry.io --ignore-not-found=true || true
                log_info "✓ OpenTelemetry CRDs removed"
            fi
        else
            log_info "Other OpenTelemetry resources found cluster-wide. Keeping CRDs."
        fi
    fi
    
    # Step 6: Optional Helm repository cleanup
    read -p "Do you want to remove the OpenTelemetry Helm repository? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        helm repo remove open-telemetry 2>/dev/null || log_warn "OpenTelemetry Helm repository not found"
        log_info "✓ OpenTelemetry Helm repository removed"
    fi
    
    log_info "🎉 OpenTelemetry uninstallation completed!"
    echo ""
    echo "Summary of actions taken:"
    echo "  ✓ Removed Helm chart: last9-opentelemetry-collector"
    echo "  ✓ Removed Helm chart: opentelemetry-operator"  
    echo "  ✓ Removed specific Kubernetes resources created by this script"
    echo "  ✓ Cleaned up OpenTelemetry labeled resources"
    echo "  ✓ Preserved other resources in namespace (if any)"
    echo ""
    echo "To verify cleanup, run:"
    echo "  helm list -n $NAMESPACE | grep opentelemetry  # Should return nothing"
    echo "  kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=opentelemetry-operator"
    echo "  kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=opentelemetry-collector"
}

# Function to uninstall everything (OpenTelemetry + Monitoring)
uninstall_all() {
    log_info "🗑️  Starting complete uninstallation (OpenTelemetry + Monitoring + Events)..."

    # Ask for confirmation
    echo ""
    log_warn "This will remove ALL components installed by this script"
    echo "Components to be removed:"
    echo "  - OpenTelemetry components (operator, collector, instrumentation)"
    echo "  - Last9 monitoring stack (kube-prometheus-stack)"
    echo "  - Kubernetes Events Agent"
    echo "  - Last9 remote write secret"
    echo "  - Namespaces (if empty after cleanup)"
    echo ""
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Uninstall cancelled."
        exit 0
    fi
    
    log_info "Proceeding with complete uninstallation..."

    # First uninstall monitoring stack
    log_info "Step 1: Uninstalling Last9 monitoring stack..."
    uninstall_last9_monitoring

    # Then uninstall Kubernetes Events Agent
    log_info "Step 2: Uninstalling Kubernetes Events Agent..."
    uninstall_events_agent

    # Finally uninstall OpenTelemetry components
    log_info "Step 3: Uninstalling OpenTelemetry components..."
    uninstall_opentelemetry

    log_info "🎉 Complete uninstallation finished!"
    echo ""
    echo "All components have been removed successfully!"
}

# Function to cleanup temporary files
cleanup() {
    # Always cleanup temporary files unless it's an uninstall operation
    if [ "$UNINSTALL_MODE" = false ] && [ -n "$WORK_DIR" ]; then
        log_info "Cleaning up temporary files..."
        # Go back to the original directory where script was executed
        cd "$ORIGINAL_DIR" 2>/dev/null || cd /tmp

        # Remove the work directory if it exists
        if [ -d "$WORK_DIR" ]; then
            rm -rf "$WORK_DIR"
            log_info "✓ Temporary directory '$WORK_DIR' removed"
        fi
    fi

    # Always cleanup all otel-setup-* directories from where script was run
    # Make sure we're in the original directory
    cd "$ORIGINAL_DIR" 2>/dev/null || true

    if ls otel-setup-* 1> /dev/null 2>&1; then
        log_info "Cleaning up all otel-setup-* directories..."
        rm -rf otel-setup-*
        log_info "✓ All otel-setup-* directories removed"
    fi
}

# Main execution function
main() {
    # Check if no arguments provided
    if [ $# -eq 0 ]; then
        echo ""
        log_info "No arguments provided. Showing available examples:"
        echo ""
        show_examples
        exit 0
    fi
    
    # Parse command line arguments
    parse_arguments "$@"

    # Install kubectl/helm context wrappers if context= was provided
    setup_context_wrappers

    # Check prerequisites
    check_prerequisites

    # Ask for deployment environment interactively when not passed via env=
    prompt_deployment_environment

    if [ "$UNINSTALL_MODE" = true ] && [ -n "$FUNCTION_TO_EXECUTE" ]; then
        # Handle special uninstall functions
        case "$FUNCTION_TO_EXECUTE" in
            uninstall_last9_monitoring)
                log_info "Running monitoring-specific uninstall..."
                uninstall_last9_monitoring
                ;;
            uninstall_events_agent)
                log_info "Running events agent uninstall..."
                uninstall_events_agent
                ;;
            uninstall_all)
                log_info "Running complete uninstall..."
                uninstall_all
                ;;
            *)
                log_warn "Unknown uninstall function: $FUNCTION_TO_EXECUTE"
                log_info "Running standard OpenTelemetry uninstall..."
                uninstall_opentelemetry
                ;;
        esac
    elif [ "$UNINSTALL_MODE" = true ]; then
        # Run standard uninstall process
        uninstall_opentelemetry
    elif [ -n "$FUNCTION_TO_EXECUTE" ]; then
        # Execute individual function
        log_info "Executing individual function: $FUNCTION_TO_EXECUTE"
        
        case "$FUNCTION_TO_EXECUTE" in
            setup_helm_repos)
                setup_helm_repos
                ;;
            install_operator)
                setup_helm_repos
                install_operator
                ;;
            install_collector)
                if [ -z "$AUTH_TOKEN" ]; then
                    log_error "Token is required for install_collector function"
                fi
                
                if [ -z "$OTEL_ENDPOINT" ]; then
                    log_error "OTEL endpoint is required for install_collector function"
                fi
                setup_helm_repos
                if [ -n "$VALUES_FILE" ]; then
                    log_info "Using custom values file from current directory: $VALUES_FILE"
                    # Check if values file exists in current directory
                    if [ ! -f "$VALUES_FILE" ]; then
                        log_error "Values file '$VALUES_FILE' not found in current directory"
                    fi
                    
                    # For individual function calls with custom values, use as-is (no token replacement)
                    log_info "Using values file as-is for individual function call"
                    prepare_collector_values_file "$VALUES_FILE" "last9-opentelemetry-collector" "OpenTelemetry Collector"
                    if ! helm_upgrade_install_with_retry last9-opentelemetry-collector open-telemetry/opentelemetry-collector \
                        --version "$COLLECTOR_VERSION" \
                        -n "$NAMESPACE" \
                        --create-namespace \
                        -f "$VALUES_FILE" \
                        $HELM_SCHEMA_FLAG; then
                        log_error "Helm install/upgrade failed for last9-opentelemetry-collector. See output above."
                    fi
                else
                    # Use default behavior - clone repo and use default values file with token replacement
                    setup_repository
                    install_collector
                fi
                ;;
            create_collector_service)
                setup_repository
                create_collector_service
                ;;
            create_instrumentation)
                setup_repository
                create_instrumentation
                ;;
            verify_installation)
                verify_installation
                ;;
            setup_last9_monitoring)
                setup_last9_monitoring "$@"
                ;;
            install_events_agent)
                setup_helm_repos
                install_events_agent
                ;;
            install_metrics_scraper)
                setup_helm_repos
                setup_repository
                if [ -z "$CLUSTER_NAME" ]; then
                    CLUSTER_NAME=$(sanitize_cluster_name "$(command kubectl config current-context 2>/dev/null || echo unknown-cluster)")
                fi
                install_metrics_scraper "$CLUSTER_NAME" || log_error "install_metrics_scraper failed. See output above."
                ;;
            verify_metrics_scraper)
                verify_metrics_scraper || log_error "OTel metrics scraper verification failed."
                ;;
            uninstall_metrics_scraper)
                uninstall_metrics_scraper
                ;;
            uninstall_last9_monitoring)
                uninstall_last9_monitoring
                ;;
            uninstall_events_agent)
                uninstall_events_agent
                ;;
            uninstall_all)
                uninstall_all
                ;;
            *)
                echo "Available functions: install_metrics_scraper, verify_metrics_scraper, uninstall_metrics_scraper, setup_helm_repos, install_operator, install_collector, create_collector_service, create_instrumentation, verify_installation, setup_last9_monitoring, install_events_agent, uninstall_last9_monitoring, uninstall_events_agent, uninstall_all"
                log_error "Unknown function: $FUNCTION_TO_EXECUTE"
                ;;
        esac
        
        # Cleanup for individual functions
        cleanup
        
        log_info "✅ Function '$FUNCTION_TO_EXECUTE' completed successfully!"
    elif [ "$MONITORING_ONLY" = true ]; then
        # Install only Cluster Monitoring (Prometheus stack)
        log_info "Starting Cluster Monitoring installation..."
        
        # Check if credentials and monitoring endpoint are provided
        if [ -z "$LAST9_USERNAME" ] || [ -z "$LAST9_PASSWORD" ]; then
            log_error "Last9 credentials are required for monitoring setup."
            log_error "Please provide username=<value> and password=<value> parameters."
        fi
        
        if [ -z "$MONITORING_ENDPOINT" ]; then
            log_error "Monitoring endpoint is required for monitoring setup."
            log_error "Please provide monitoring-endpoint=<value> parameter."
        fi
        
        # Check if cluster name is provided
        if [ -z "$CLUSTER_NAME" ]; then
            log_info "Cluster name not provided, attempting to detect from kubectl..."
            local raw_ctx
            if [ -n "$KUBE_CONTEXT" ]; then
                raw_ctx="$KUBE_CONTEXT"
            else
                raw_ctx=$(command kubectl config current-context 2>/dev/null || echo "unknown-cluster")
            fi
            CLUSTER_NAME=$(sanitize_cluster_name "$raw_ctx")
            log_info "Detected cluster name: $CLUSTER_NAME"
        fi
        
        setup_repository
        setup_helm_repos
        setup_last9_monitoring cluster="$CLUSTER_NAME"
        
        cleanup
        
        log_info "🎉 Cluster Monitoring installation completed successfully!"
        log_info "Next steps:"
        echo "  1. Wait for monitoring pods to be in Running state: kubectl get pods -n $NAMESPACE"
        echo "  2. Check scraper logs: kubectl logs -n $NAMESPACE last9-otel-metrics-0"
        echo "  3. Verify monitoring services: kubectl get svc -n $NAMESPACE"
        echo ""
        echo "📝 Note: Monitoring stack deployed with cluster name: $CLUSTER_NAME"
        echo ""
        echo "To add OpenTelemetry later, run: $0 token=\"your-token\" endpoint=\"your-otel-endpoint\""
        echo "To uninstall later, run: $0 uninstall function=\"uninstall_last9_monitoring\""
    elif [ "$EVENTS_ONLY" = true ]; then
        # Install only Kubernetes Events Agent
        log_info "Starting Kubernetes Events Agent installation..."

        setup_repository
        setup_helm_repos
        install_events_agent

        cleanup

        log_info "🎉 Kubernetes Events Agent installation completed successfully!"
        log_info "Next steps:"
        echo "  1. Wait for events agent pod to be in Running state: kubectl get pods -n $NAMESPACE"
        echo "  2. Check events agent logs: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=last9-kube-events-agent"
        echo "  3. Verify events agent service: kubectl get svc -n $NAMESPACE"
        echo ""
        echo "📝 Note: Kubernetes events will be collected and sent to Last9"
        echo ""
        echo "To add OpenTelemetry later, run: $0 token=\"your-token\" endpoint=\"your-otel-endpoint\""
        echo "To uninstall later, run: $0 uninstall"
    elif [ "$LOGS_ONLY" = true ]; then
        # Install only Collector for logs
        log_info "Starting OpenTelemetry Collector for logs installation..."
        
        setup_repository
        setup_helm_repos
        create_logs_only_config
        install_collector
        create_collector_service
        verify_installation
        
        cleanup
        
        log_info "🎉 OpenTelemetry Collector for logs installation completed successfully!"
        log_info "Next steps:"
        echo "  1. Wait for collector pod to be in Running state: kubectl get pods -n $NAMESPACE"
        echo "  2. Check collector logs if needed: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=opentelemetry-collector"
        echo "  3. Verify collector service: kubectl get svc -n $NAMESPACE"
        echo ""
        echo "📝 Note: Logs-only configuration file created: last9-otel-collector-logs-only.yaml"
        echo ""
        echo "To add operator later, run: $0 operator-only token=\"your-token\" endpoint=\"your-otel-endpoint\""
        echo "To add monitoring later, run: $0 token=\"your-token\" endpoint=\"your-otel-endpoint\" monitoring-endpoint=\"your-monitoring-endpoint\" cluster=\"cluster-name\" username=\"user\" password=\"pass\""
        echo "To uninstall later, run: $0 uninstall"
    elif [ "$OPERATOR_ONLY" = true ]; then
        # Install OpenTelemetry Operator and Collector
        log_info "Starting OpenTelemetry Operator and Collector installation..."
        
        # Check if token and endpoint are provided for collector installation
        if [ -z "$AUTH_TOKEN" ]; then
            log_error "Auth token is required for collector installation."
            log_error "Please provide token=<value> parameter for operator-only installation."
        fi
        
        if [ -z "$OTEL_ENDPOINT" ]; then
            log_error "OTEL endpoint is required for collector installation."
            log_error "Please provide endpoint=<value> parameter for operator-only installation."
        fi
        
        setup_repository
        setup_helm_repos
        update_deployment_mode
        install_operator
        install_collector
        create_collector_service
        create_instrumentation
        verify_installation
        
        cleanup
        
        log_info "🎉 OpenTelemetry Operator and Collector installation completed successfully!"
        log_info "Next steps:"
        echo "  1. Wait for operator pod to be in Running state: kubectl get pods -n $NAMESPACE"
        echo "  2. Wait for collector pod to be in Running state: kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=opentelemetry-collector"
        echo "  3. Check operator logs if needed: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=opentelemetry-operator"
        echo "  4. Check collector logs if needed: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=opentelemetry-collector"
        echo "  5. Verify services: kubectl get svc -n $NAMESPACE"
        echo "  6. Check instrumentation: kubectl get instrumentation -n $NAMESPACE"
        echo ""
        echo "📝 Note: Deployment mode changed from daemonset to deployment"
        echo "📝 Note: LogsCollection preset disabled (removes filelog receiver)"
        echo "📝 Note: Filelog receiver commented out in logs pipeline (backup approach)"
        echo "📝 Note: Service selector updated to component: standalone-collector"
        echo "📝 Note: Original values file backed up as last9-otel-collector-values.yaml.backup"
        echo ""
        echo "To add monitoring later, run: $0 token=\"your-token\" endpoint=\"your-otel-endpoint\" monitoring-endpoint=\"your-monitoring-endpoint\" cluster=\"cluster-name\" username=\"user\" password=\"pass\""
        echo "To uninstall later, run: $0 uninstall"
    else
        # Run installation process
        log_info "Starting OpenTelemetry setup automation..."
        
        setup_repository
        setup_helm_repos
        install_operator
        install_collector
        create_collector_service
        create_instrumentation
        verify_installation
        
        # Install monitoring stack if requested
        if [ "$SETUP_MONITORING" = true ]; then
            log_info "Installing Last9 monitoring stack..."
            setup_last9_monitoring cluster="$CLUSTER_NAME"
        fi

        # Install Kubernetes Events Agent
        log_info "Installing Kubernetes Events Agent..."
        install_events_agent

        cleanup
        
        log_info "🎉 OpenTelemetry setup completed successfully!"
        log_info "Next steps:"
        echo "  1. Wait for all pods to be in Running state: kubectl get pods -n $NAMESPACE"
        echo "  2. Check logs if needed: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=opentelemetry-collector"
        echo "  3. Verify services: kubectl get svc -n $NAMESPACE"
        echo ""
        echo "📝 Note: Original values file backed up as last9-otel-collector-values.yaml.backup"
        echo ""
        echo "To uninstall later, run: $0 uninstall"
    fi
}

# Handle script interruption and cleanup
trap cleanup EXIT INT TERM

# Run main function when executed directly (not sourced for testing).
# The || true prevents set -e from exiting when condition is false (sourced context).
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@" || true

