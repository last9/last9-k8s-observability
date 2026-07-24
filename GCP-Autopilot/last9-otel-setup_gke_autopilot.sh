#!/bin/bash

# GKE Autopilot-specific Installation Script for Last9 OpenTelemetry Stack
# This script uses pre-configured local values files optimized for GKE Autopilot
#
# Usage:
#   Install:
#     ./install-autopilot.sh endpoint="<endpoint>" token="<token>" monitoring-endpoint="<monitoring-endpoint>" username="<username>" password="<password>"
#
#   Uninstall:
#     ./install-autopilot.sh uninstall-all
#
# Example:
#   ./install-autopilot.sh endpoint="https://otlp-aps1.last9.io:443" token="Basic xxx" monitoring-endpoint="https://app-tsdb.last9.io/v1/metrics/xxx/sender/last9/write" username="xxx" password="xxx"

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Configuration
NAMESPACE="last9"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse command line arguments
AUTH_TOKEN=""
OTEL_ENDPOINT=""
MONITORING_ENDPOINT=""
LAST9_USERNAME=""
LAST9_PASSWORD=""
UNINSTALL_MODE=false
DEPLOYMENT_ENV=""

for arg in "$@"; do
    case $arg in
        uninstall-all)
            UNINSTALL_MODE=true
            ;;
        env=*)
            DEPLOYMENT_ENV="${arg#*=}"
            ;;
        endpoint=*)
            OTEL_ENDPOINT="${arg#*=}"
            ;;
        token=*)
            AUTH_TOKEN="${arg#*=}"
            ;;
        monitoring-endpoint=*)
            MONITORING_ENDPOINT="${arg#*=}"
            ;;
        username=*)
            LAST9_USERNAME="${arg#*=}"
            ;;
        password=*)
            LAST9_PASSWORD="${arg#*=}"
            ;;
    esac
done

# Handle uninstall mode
if [ "$UNINSTALL_MODE" = true ]; then
    log_info "=========================================="
    log_info "Uninstalling Last9 OpenTelemetry Stack..."
    log_info "=========================================="
    echo ""

    # Check prerequisites
    log_info "Checking prerequisites..."
    command -v kubectl >/dev/null 2>&1 || { log_error "kubectl is required but not installed."; exit 1; }
    command -v helm >/dev/null 2>&1 || { log_error "helm is required but not installed."; exit 1; }

    CONTEXT=$(kubectl config current-context)
    log_info "✓ Using Kubernetes context: $CONTEXT"
    echo ""

    # Uninstall helm releases
    log_info "Uninstalling Helm releases..."
    helm uninstall last9-kube-events-agent -n $NAMESPACE 2>&1 | grep -v "not found" || true
    log_info "  ✓ last9-kube-events-agent uninstalled"

    helm uninstall last9-k8s-monitoring -n $NAMESPACE 2>&1 | grep -v "not found" || true
    log_info "  ✓ last9-k8s-monitoring uninstalled"

    helm uninstall last9-opentelemetry-collector -n $NAMESPACE 2>&1 | grep -v "not found" || true
    log_info "  ✓ last9-opentelemetry-collector uninstalled"

    sleep 5

    helm uninstall opentelemetry-operator -n $NAMESPACE 2>&1 | grep -v "not found" || true
    log_info "  ✓ opentelemetry-operator uninstalled"
    echo ""

    # Delete custom resources
    log_info "Cleaning up custom resources..."
    kubectl delete instrumentation -n $NAMESPACE --all 2>&1 | grep -v "not found" || true
    kubectl delete svc otel-collector-service -n $NAMESPACE 2>&1 | grep -v "not found" || true
    kubectl delete secret last9-remote-write-secret -n $NAMESPACE 2>&1 | grep -v "not found" || true
    log_info "✓ Custom resources cleaned up"
    echo ""

    # Wait for resources to be fully deleted
    log_info "Waiting for resources to be fully deleted..."
    sleep 10

    # Show remaining resources
    log_info "Checking for remaining resources in namespace $NAMESPACE..."
    REMAINING=$(kubectl get all -n $NAMESPACE 2>&1 | grep -v "No resources found" || echo "")
    if [ -z "$REMAINING" ]; then
        log_info "✓ All resources cleaned up successfully!"
    else
        log_warn "Some resources still exist:"
        kubectl get all -n $NAMESPACE
    fi

    echo ""
    log_info "=========================================="
    log_info "✓ Uninstallation completed!"
    log_info "=========================================="
    echo ""
    log_info "To reinstall, run the script without 'uninstall-all' parameter"
    exit 0
fi

# Validate required parameters
if [ -z "$AUTH_TOKEN" ] || [ -z "$OTEL_ENDPOINT" ] || [ -z "$MONITORING_ENDPOINT" ] || [ -z "$LAST9_USERNAME" ] || [ -z "$LAST9_PASSWORD" ]; then
    log_error "All parameters are required"
    log_error "Usage: $0 endpoint=\"<endpoint>\" token=\"<token>\" monitoring-endpoint=\"<monitoring-endpoint>\" username=\"<username>\" password=\"<password>\" [env=<environment>]"
    log_error "  env=<environment>  Optional. Sets deployment.environment attribute. Default: unset (attribute omitted)"
    exit 1
fi

# Ask for the deployment environment interactively when not passed via env=.
# Only prompts on a real terminal — curl|bash one-liners and CI have no TTY, so it
# stays unset there. An explicit env= argument always wins and suppresses the prompt.
if [ -z "$DEPLOYMENT_ENV" ] && [ -t 0 ]; then
    printf "%b" "${GREEN}[INPUT]${NC} Deployment environment (e.g. production, staging) [blank to skip]: " >&2
    read -r DEPLOYMENT_ENV || DEPLOYMENT_ENV=""
    if [ -n "$DEPLOYMENT_ENV" ]; then
        log_info "Using deployment.environment=$DEPLOYMENT_ENV"
    else
        log_info "No deployment environment entered — deployment.environment will be omitted"
    fi
fi

# Trim surrounding whitespace, then reject values outside a safe identifier charset.
# DEPLOYMENT_ENV is interpolated raw into a sed replacement (|, &, \ corrupt it), awk -v,
# and OTTL string literals (a " breaks the literal) below — one guard closes all sinks.
# (log_error here does not exit, so exit explicitly.) (#review)
DEPLOYMENT_ENV="$(printf '%s' "$DEPLOYMENT_ENV" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
case "$DEPLOYMENT_ENV" in
    *[!A-Za-z0-9._-]*)
        log_error "Invalid deployment environment '$DEPLOYMENT_ENV'. Use only letters, digits, '.', '_', '-'."
        exit 1 ;;
esac

log_info "=========================================="
log_info "Starting GKE Autopilot OpenTelemetry installation..."
log_info "=========================================="
log_info "Using configuration files from: $SCRIPT_DIR"
echo ""

# Function to replace placeholders in values files
replace_placeholders() {
    local file=$1
    local temp_file="${file}.tmp"

    # Get cluster name from current context
    CLUSTER_NAME=$(kubectl config current-context)

    # Create a copy and replace placeholders
    cp "$file" "$temp_file"

    # Escape special characters for sed
    ESCAPED_TOKEN=$(printf '%s\n' "$AUTH_TOKEN" | sed 's:[\/&]:\\&:g')
    ESCAPED_ENDPOINT=$(printf '%s\n' "$OTEL_ENDPOINT" | sed 's:[\/&]:\\&:g')
    ESCAPED_MONITORING=$(printf '%s\n' "$MONITORING_ENDPOINT" | sed 's:[\/&]:\\&:g')
    ESCAPED_CLUSTER=$(printf '%s\n' "$CLUSTER_NAME" | sed 's:[\/&]:\\&:g')

    # Replace placeholders
    sed -i.bak "s|{{AUTH_TOKEN}}|${ESCAPED_TOKEN}|g" "$temp_file"
    sed -i.bak "s|{{OTEL_ENDPOINT}}|${ESCAPED_ENDPOINT}|g" "$temp_file"
    sed -i.bak "s|{{MONITORING_ENDPOINT}}|${ESCAPED_MONITORING}|g" "$temp_file"
    sed -i.bak "s|{{CLUSTER_NAME}}|${ESCAPED_CLUSTER}|g" "$temp_file"

    # deployment.environment is unset by default (placeholder comment). Activate or
    # update it only when env=<environment> was provided, preserving indentation.
    if [ -n "$DEPLOYMENT_ENV" ]; then
        local escaped_env ottl_target
        escaped_env=$(printf '%s\n' "$DEPLOYMENT_ENV" | sed 's:[\/&]:\\&:g')
        if [[ "$file" == *kube-events* ]]; then
            ottl_target='resource\.attributes\["deployment.environment"\]'
        else
            ottl_target='attributes\["deployment.environment"\]'
        fi
        sed -i.bak \
            -e "s|^\([[:space:]]*\)- set(${ottl_target}, \"[^\"]*\")|\1- set(${ottl_target}, \"${escaped_env}\")|" \
            -e "s|^\([[:space:]]*\)# @DEPLOYMENT_ENVIRONMENT@.*|\1- set(${ottl_target}, \"${escaped_env}\")|" \
            "$temp_file"
    fi

    # Remove backup files
    rm -f "${temp_file}.bak"

    echo "$temp_file"
}

# Function to cleanup temp files
cleanup_temp_files() {
    rm -f "$SCRIPT_DIR"/*.tmp
}

# Trap to ensure cleanup on exit
trap cleanup_temp_files EXIT

# Check prerequisites
log_info "Checking prerequisites..."
command -v kubectl >/dev/null 2>&1 || { log_error "kubectl is required but not installed."; exit 1; }
command -v helm >/dev/null 2>&1 || { log_error "helm is required but not installed."; exit 1; }

# Verify we're on a GKE cluster
CONTEXT=$(kubectl config current-context)
log_info "✓ Prerequisites check passed"
log_info "Using Kubernetes context: $CONTEXT"
echo ""

# Add Helm repositories
log_info "Adding Helm repositories..."
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update 
log_info "✓ Helm repositories updated"
echo ""

# Create namespace
log_info "Creating namespace: $NAMESPACE"
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
log_info "✓ Namespace $NAMESPACE created/verified"
echo ""

# Install cert-manager (required by OpenTelemetry Operator)
log_info "=========================================="
log_info "Installing cert-manager..."
log_info "=========================================="
log_info "Checking if cert-manager is already installed..."
if kubectl get namespace cert-manager  2>&1 | grep -q "NotFound\|not found"; then
    log_info "Installing cert-manager..."
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.2/cert-manager.yaml
    log_info "Waiting for cert-manager to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/cert-manager -n cert-manager
    kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-webhook -n cert-manager
    kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-cainjector -n cert-manager
    log_info "✓ cert-manager installed"
else
    log_info "✓ cert-manager already installed"
fi
echo ""

# Install OpenTelemetry Operator
log_info "=========================================="
log_info "Installing OpenTelemetry Operator..."
log_info "=========================================="
helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
  --namespace $NAMESPACE \
  --version 0.92.1 \
  --create-namespace \
  --wait \
  --timeout 5m

log_info "✓ OpenTelemetry Operator installed"
echo ""

# Wait for webhook to be ready
log_info "Waiting for OpenTelemetry Operator webhook to be ready..."
kubectl wait --for=condition=available --timeout=120s \
  deployment/opentelemetry-operator -n $NAMESPACE

# Additional wait for webhook certificates to propagate
log_info "Waiting for webhook certificates to propagate (30 seconds)..."
sleep 30
log_info "✓ Operator webhook is ready"
echo ""

# Install OpenTelemetry Collector
log_info "=========================================="
log_info "Installing OpenTelemetry Collector..."
log_info "=========================================="
COLLECTOR_VALUES=$(replace_placeholders "$SCRIPT_DIR/last9-otel-collector-values.yaml")
helm upgrade --install last9-opentelemetry-collector open-telemetry/opentelemetry-collector \
  --namespace $NAMESPACE \
  --values "$COLLECTOR_VALUES" \
  --version 0.165.0 \
  --wait \
  --timeout 5m

log_info "✓ OpenTelemetry Collector installed"
echo ""

# Create Collector Service
log_info "Creating OpenTelemetry Collector service..."
kubectl apply -f "$SCRIPT_DIR/collector-svc.yaml" -n $NAMESPACE 
log_info "✓ Collector service created"
echo ""

# Create Instrumentation (with retry logic)
# deployment.environment is unset by default; fill OTEL_RESOURCE_ATTRIBUTES only when env= was provided.
INSTRUMENTATION_FILE="$SCRIPT_DIR/instrumentation.yaml.tmp"
cp "$SCRIPT_DIR/instrumentation.yaml" "$INSTRUMENTATION_FILE"
if [ -n "$DEPLOYMENT_ENV" ]; then
    log_info "Creating OpenTelemetry Instrumentation (deployment.environment=$DEPLOYMENT_ENV)..."
    awk -v env="$DEPLOYMENT_ENV" '
        prev ~ /OTEL_RESOURCE_ATTRIBUTES/ && /value:/ {
            match($0, /^[[:space:]]*/); indent = substr($0, 1, RLENGTH)
            print indent "value: \"deployment.environment=" env "\""
            prev = $0; next
        }
        { prev = $0; print }
    ' "$INSTRUMENTATION_FILE" > "${INSTRUMENTATION_FILE}.awk.tmp" && mv "${INSTRUMENTATION_FILE}.awk.tmp" "$INSTRUMENTATION_FILE"
else
    log_info "Creating OpenTelemetry Instrumentation (deployment.environment unset)..."
fi
MAX_RETRIES=5
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if kubectl apply -f "$INSTRUMENTATION_FILE" -n $NAMESPACE ; then
        log_info "✓ Instrumentation created"
        break
    else
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            log_warn "Failed to create instrumentation (attempt $RETRY_COUNT/$MAX_RETRIES). Retrying in 10 seconds..."
            sleep 10
        else
            log_error "Failed to create instrumentation after $MAX_RETRIES attempts"
            # $INSTRUMENTATION_FILE is a *.tmp removed by the EXIT trap — point at the source
            # file (re-run with env=<environment> to re-apply deployment.environment). (#review)
            log_warn "You can manually apply it later: kubectl apply -f $SCRIPT_DIR/instrumentation.yaml -n $NAMESPACE"
        fi
    fi
done
echo ""

# Install Kubernetes Monitoring Stack
log_info "=========================================="
log_info "Installing Kubernetes Monitoring Stack..."
log_info "=========================================="

# Create secret for Prometheus remote write
log_info "Creating Prometheus remote write secret..."
kubectl create secret generic last9-remote-write-secret \
  --from-literal=username="$LAST9_USERNAME" \
  --from-literal=password="$LAST9_PASSWORD" \
  --namespace=$NAMESPACE \
  --dry-run=client -o yaml | kubectl apply -f - 

log_info "✓ Remote write secret created"
echo ""

log_info "Deploying Prometheus stack (this may take a few minutes)..."
MONITORING_VALUES=$(replace_placeholders "$SCRIPT_DIR/k8s-monitoring-values.yaml")
helm install last9-k8s-monitoring prometheus-community/kube-prometheus-stack \
  --namespace $NAMESPACE \
  --values "$MONITORING_VALUES" \
  --version 75.15.1 \
  --wait \
  --timeout 10m 

log_info "✓ Kubernetes Monitoring Stack installed"
echo ""

# Install Kubernetes Events Agent
log_info "=========================================="
log_info "Installing Kubernetes Events Agent..."
log_info "=========================================="
EVENTS_VALUES=$(replace_placeholders "$SCRIPT_DIR/last9-kube-events-agent-values.yaml")
helm install last9-kube-events-agent open-telemetry/opentelemetry-collector \
  --namespace $NAMESPACE \
  --values "$EVENTS_VALUES" \
  --version 0.165.0 \
  --wait \
  --timeout 5m 

log_info "✓ Kubernetes Events Agent installed"
echo ""

# Verify installation
log_info "=========================================="
log_info "Verifying installation..."
log_info "=========================================="
echo ""
log_info "Pods in namespace $NAMESPACE:"
kubectl get pods -n $NAMESPACE

echo ""
log_info "Services in namespace $NAMESPACE:"
kubectl get svc -n $NAMESPACE

echo ""
log_info "Instrumentation:"
kubectl get instrumentation -n $NAMESPACE 2>/dev/null || log_warn "Instrumentation CRD may not be ready yet"

echo ""
log_info "=========================================="
log_info "✓ Installation completed successfully!"
log_info "=========================================="
echo ""
log_info "Summary of installed components:"
log_info "  • OpenTelemetry Operator - Manages collectors and instrumentation"
log_info "  • OpenTelemetry Collector - Collects traces, metrics, and logs (OTLP)"
log_info "  • Prometheus Stack - Monitors cluster metrics"
log_info "  • Events Agent - Forwards Kubernetes events"
log_info "  • Auto-Instrumentation - Ready for workload instrumentation"
echo ""
log_info "GKE Autopilot Adjustments:"
log_info "  ⚠ File-based log collection: DISABLED (hostPath restrictions)"
log_info "  ⚠ Node-exporter: DISABLED (requires host access)"
log_info "  ⚠ Kubelet monitoring: DISABLED (kube-system access restricted)"
log_info "  ℹ Applications can still send logs via OTLP protocol"
echo ""
log_info "Next steps:"
log_info "  1. Check pod status: kubectl get pods -n $NAMESPACE"
log_info "  2. View collector logs: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=opentelemetry-collector"
log_info "  3. Test instrumentation by annotating a deployment"
log_info "  4. Check your Last9 dashboard for incoming telemetry"
echo ""
log_info "For more information, see: $SCRIPT_DIR/README.md"
