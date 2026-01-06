#!/bin/bash
# =============================================================================
# Last9 Cluster Detection Script
# =============================================================================
# Detects Kubernetes cluster type and eBPF compatibility for network flow
# collection. Recommends appropriate configuration based on cluster capabilities.
#
# Usage: ./detect-cluster.sh
#
# Version: 1.0.0
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Detection results
CLUSTER_TYPE="unknown"
CLUSTER_VERSION=""
KERNEL_VERSION=""
EBPF_SUPPORT="unknown"
PRIVILEGED_ALLOWED="unknown"
RECOMMENDED_CONFIG=""

print_header() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Last9 Cluster Detection${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}\n"
}

print_section() {
    echo -e "\n${YELLOW}▸ $1${NC}"
    echo -e "${YELLOW}$(printf '─%.0s' {1..60})${NC}"
}

print_result() {
    local label="$1"
    local value="$2"
    local status="${3:-}"

    case "$status" in
        "good")
            echo -e "  ${label}: ${GREEN}${value}${NC}"
            ;;
        "warn")
            echo -e "  ${label}: ${YELLOW}${value}${NC}"
            ;;
        "bad")
            echo -e "  ${label}: ${RED}${value}${NC}"
            ;;
        *)
            echo -e "  ${label}: ${CYAN}${value}${NC}"
            ;;
    esac
}

# Detect cluster type from node labels and API server
detect_cluster_type() {
    print_section "Detecting Cluster Type"

    # Get node info
    local node_info
    node_info=$(kubectl get nodes -o json 2>/dev/null || echo '{"items":[]}')

    local first_node_labels
    first_node_labels=$(echo "$node_info" | jq -r '.items[0].metadata.labels // {}')

    local first_node_provider
    first_node_provider=$(echo "$node_info" | jq -r '.items[0].spec.providerID // ""')

    # Check for EKS
    if echo "$first_node_labels" | jq -e '."eks.amazonaws.com/nodegroup"' &>/dev/null || \
       echo "$first_node_provider" | grep -qi "aws"; then
        CLUSTER_TYPE="eks"
        print_result "Cluster Type" "Amazon EKS" "good"
        return
    fi

    # Check for GKE
    if echo "$first_node_labels" | jq -e '."cloud.google.com/gke-nodepool"' &>/dev/null || \
       echo "$first_node_provider" | grep -qi "gce"; then
        # Check for Autopilot
        if echo "$first_node_labels" | jq -e '."cloud.google.com/gke-autopilot"' &>/dev/null; then
            CLUSTER_TYPE="gke-autopilot"
            print_result "Cluster Type" "Google GKE Autopilot" "warn"
        else
            CLUSTER_TYPE="gke-standard"
            print_result "Cluster Type" "Google GKE Standard" "good"
        fi
        return
    fi

    # Check for AKS
    if echo "$first_node_labels" | jq -e '."kubernetes.azure.com/cluster"' &>/dev/null || \
       echo "$first_node_provider" | grep -qi "azure"; then
        CLUSTER_TYPE="aks"
        print_result "Cluster Type" "Azure AKS" "good"
        return
    fi

    # Check for OpenShift
    if kubectl api-resources | grep -q "route.openshift.io" 2>/dev/null; then
        CLUSTER_TYPE="openshift"
        print_result "Cluster Type" "Red Hat OpenShift" "good"
        return
    fi

    # Check for Rancher/RKE
    if echo "$first_node_labels" | jq -e '."rke.cattle.io/machine"' &>/dev/null; then
        CLUSTER_TYPE="rke"
        print_result "Cluster Type" "Rancher RKE" "good"
        return
    fi

    # Check for k3s
    if kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null | grep -qi "k3s"; then
        CLUSTER_TYPE="k3s"
        print_result "Cluster Type" "K3s" "good"
        return
    fi

    # Check for kind
    if echo "$first_node_labels" | jq -e '."io.x-k8s.kind.cluster"' &>/dev/null; then
        CLUSTER_TYPE="kind"
        print_result "Cluster Type" "kind (local)" "warn"
        return
    fi

    # Check for minikube
    if echo "$first_node_labels" | jq -e '.minikube' &>/dev/null || \
       kubectl config current-context 2>/dev/null | grep -qi "minikube"; then
        CLUSTER_TYPE="minikube"
        print_result "Cluster Type" "Minikube (local)" "warn"
        return
    fi

    # Check for Docker Desktop
    if kubectl config current-context 2>/dev/null | grep -qi "docker-desktop"; then
        CLUSTER_TYPE="docker-desktop"
        print_result "Cluster Type" "Docker Desktop" "warn"
        return
    fi

    # Default to vanilla Kubernetes
    CLUSTER_TYPE="vanilla"
    print_result "Cluster Type" "Vanilla Kubernetes (self-hosted)" "good"
}

# Get Kubernetes version
detect_k8s_version() {
    print_section "Kubernetes Version"

    CLUSTER_VERSION=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // "unknown"')

    local major minor
    major=$(echo "$CLUSTER_VERSION" | sed -E 's/v([0-9]+)\..*/\1/')
    minor=$(echo "$CLUSTER_VERSION" | sed -E 's/v[0-9]+\.([0-9]+).*/\1/')

    if [[ "$major" -ge 1 && "$minor" -ge 25 ]]; then
        print_result "Version" "$CLUSTER_VERSION (supported)" "good"
    elif [[ "$major" -ge 1 && "$minor" -ge 21 ]]; then
        print_result "Version" "$CLUSTER_VERSION (legacy support)" "warn"
    else
        print_result "Version" "$CLUSTER_VERSION (unsupported)" "bad"
    fi
}

# Detect kernel version for eBPF support
detect_kernel_version() {
    print_section "Kernel Version (eBPF Support)"

    # Get kernel version from a node
    KERNEL_VERSION=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kernelVersion}' 2>/dev/null || echo "unknown")

    if [[ "$KERNEL_VERSION" == "unknown" ]]; then
        print_result "Kernel" "Unable to detect" "warn"
        return
    fi

    # Parse major.minor version
    local major minor
    major=$(echo "$KERNEL_VERSION" | cut -d. -f1)
    minor=$(echo "$KERNEL_VERSION" | cut -d. -f2)

    # eBPF support levels:
    # - 4.4+: Basic eBPF
    # - 4.14+: BTF (BPF Type Format) - better portability
    # - 5.2+: BPF LSM, ring buffer
    # - 5.8+: BPF iterator, sleepable BPF

    if [[ "$major" -ge 5 && "$minor" -ge 8 ]]; then
        print_result "Kernel" "$KERNEL_VERSION (full eBPF support)" "good"
        EBPF_SUPPORT="full"
    elif [[ "$major" -ge 5 ]]; then
        print_result "Kernel" "$KERNEL_VERSION (good eBPF support)" "good"
        EBPF_SUPPORT="good"
    elif [[ "$major" -ge 4 && "$minor" -ge 14 ]]; then
        print_result "Kernel" "$KERNEL_VERSION (basic eBPF with BTF)" "warn"
        EBPF_SUPPORT="basic"
    elif [[ "$major" -ge 4 && "$minor" -ge 4 ]]; then
        print_result "Kernel" "$KERNEL_VERSION (limited eBPF)" "warn"
        EBPF_SUPPORT="limited"
    else
        print_result "Kernel" "$KERNEL_VERSION (no eBPF support)" "bad"
        EBPF_SUPPORT="none"
    fi
}

# Check if privileged containers are allowed
check_privileged_support() {
    print_section "Privileged Container Support"

    # Check for PodSecurityPolicy (deprecated but still in use)
    local psp_exists=false
    if kubectl api-resources | grep -q "podsecuritypolicies" 2>/dev/null; then
        local restricted_psp
        restricted_psp=$(kubectl get psp 2>/dev/null | grep -i "restricted" || true)
        if [[ -n "$restricted_psp" ]]; then
            psp_exists=true
        fi
    fi

    # Check for Pod Security Admission (PSA) - K8s 1.25+
    local psa_restricted=false
    local namespaces_with_psa
    namespaces_with_psa=$(kubectl get namespaces -o json 2>/dev/null | \
        jq -r '.items[] | select(.metadata.labels["pod-security.kubernetes.io/enforce"] == "restricted") | .metadata.name' || true)
    if [[ -n "$namespaces_with_psa" ]]; then
        psa_restricted=true
    fi

    # Cluster-specific restrictions
    case "$CLUSTER_TYPE" in
        "gke-autopilot")
            print_result "Privileged" "Not allowed (GKE Autopilot restriction)" "bad"
            PRIVILEGED_ALLOWED="no"
            ;;
        "openshift")
            print_result "Privileged" "Requires SCC configuration" "warn"
            PRIVILEGED_ALLOWED="scc-required"
            ;;
        *)
            if [[ "$psp_exists" == true ]]; then
                print_result "Privileged" "May be restricted by PodSecurityPolicy" "warn"
                PRIVILEGED_ALLOWED="psp-check"
            elif [[ "$psa_restricted" == true ]]; then
                print_result "Privileged" "Some namespaces use restricted PSA" "warn"
                PRIVILEGED_ALLOWED="psa-check"
            else
                print_result "Privileged" "Likely allowed" "good"
                PRIVILEGED_ALLOWED="yes"
            fi
            ;;
    esac
}

# Check for existing eBPF/network monitoring tools
detect_existing_tools() {
    print_section "Existing Network Monitoring"

    local tools_found=false

    # Check for Cilium
    if kubectl get pods -A -l app.kubernetes.io/name=cilium 2>/dev/null | grep -q "cilium"; then
        print_result "Cilium" "Detected (can use Hubble for network flows)" "good"
        tools_found=true
    fi

    # Check for Calico
    if kubectl get pods -A -l k8s-app=calico-node 2>/dev/null | grep -q "calico"; then
        print_result "Calico" "Detected (limited flow visibility)" "warn"
        tools_found=true
    fi

    # Check for Istio
    if kubectl get pods -A -l app=istiod 2>/dev/null | grep -q "istiod"; then
        print_result "Istio" "Detected (service mesh telemetry available)" "good"
        tools_found=true
    fi

    # Check for Linkerd
    if kubectl get pods -A -l app.kubernetes.io/name=linkerd 2>/dev/null | grep -q "linkerd"; then
        print_result "Linkerd" "Detected (service mesh telemetry available)" "good"
        tools_found=true
    fi

    # Check for Pixie
    if kubectl get pods -A -l app=vizier-pem 2>/dev/null | grep -q "vizier"; then
        print_result "Pixie" "Detected (full eBPF observability)" "good"
        tools_found=true
    fi

    if [[ "$tools_found" == false ]]; then
        print_result "Tools" "No existing network monitoring detected" ""
    fi
}

# Generate recommendation
generate_recommendation() {
    print_section "Recommendation"

    # Determine recommended config
    case "$CLUSTER_TYPE" in
        "gke-autopilot")
            RECOMMENDED_CONFIG="metadata-only"
            echo -e "${YELLOW}GKE Autopilot does not support privileged containers.${NC}"
            echo -e "  → Use: ${CYAN}values.yaml${NC} (metadata-based topology only)"
            echo -e "  → eBPF network flows: ${RED}Not available${NC}"
            echo ""
            echo -e "Alternative: Consider GKE Standard for full observability."
            ;;
        "openshift")
            RECOMMENDED_CONFIG="ebpf-scc"
            echo -e "${GREEN}OpenShift supports eBPF with proper SCC configuration.${NC}"
            echo -e "  → Use: ${CYAN}values-ebpf.yaml${NC} with SCC"
            echo -e "  → Run: ${CYAN}oc adm policy add-scc-to-user privileged -z last9-otel-collector${NC}"
            ;;
        *)
            if [[ "$EBPF_SUPPORT" == "full" || "$EBPF_SUPPORT" == "good" ]] && \
               [[ "$PRIVILEGED_ALLOWED" == "yes" ]]; then
                RECOMMENDED_CONFIG="ebpf-full"
                echo -e "${GREEN}Full eBPF support available!${NC}"
                echo -e "  → Use: ${CYAN}values-ebpf.yaml${NC} for network flow collection"
                echo -e "  → Features: Pod-to-pod traffic, external connections, latency"
            elif [[ "$EBPF_SUPPORT" == "basic" || "$EBPF_SUPPORT" == "limited" ]]; then
                RECOMMENDED_CONFIG="ebpf-limited"
                echo -e "${YELLOW}Limited eBPF support. Some features may not work.${NC}"
                echo -e "  → Use: ${CYAN}values-ebpf.yaml${NC} (test thoroughly)"
                echo -e "  → Consider upgrading kernel to 5.x+ for full support"
            else
                RECOMMENDED_CONFIG="metadata-only"
                echo -e "${YELLOW}eBPF not recommended for this cluster.${NC}"
                echo -e "  → Use: ${CYAN}values.yaml${NC} (metadata-based topology)"
                echo -e "  → Reason: Kernel $KERNEL_VERSION lacks eBPF support"
            fi
            ;;
    esac

    echo ""
    print_section "Next Steps"

    case "$RECOMMENDED_CONFIG" in
        "ebpf-full"|"ebpf-limited"|"ebpf-scc")
            echo "1. Review values-ebpf.yaml configuration"
            echo "2. Install with: helm install last9-collector opentelemetry/opentelemetry-collector \\"
            echo "     -f values.yaml -f values-ebpf.yaml -n last9"
            echo "3. Verify eBPF is working: kubectl logs -n last9 -l app=last9-otel-collector | grep ebpf"
            ;;
        "metadata-only")
            echo "1. Use standard installation: helm install last9-collector \\"
            echo "     opentelemetry/opentelemetry-collector -f values.yaml -n last9"
            echo "2. Topology will be based on Kubernetes metadata (ownerReferences)"
            echo "3. For network flows, consider: Cilium Hubble, Istio, or Pixie"
            ;;
    esac
}

# Output summary as JSON (for automation)
output_json() {
    if [[ "${1:-}" == "--json" ]]; then
        cat <<EOF
{
  "cluster_type": "$CLUSTER_TYPE",
  "kubernetes_version": "$CLUSTER_VERSION",
  "kernel_version": "$KERNEL_VERSION",
  "ebpf_support": "$EBPF_SUPPORT",
  "privileged_allowed": "$PRIVILEGED_ALLOWED",
  "recommended_config": "$RECOMMENDED_CONFIG"
}
EOF
        exit 0
    fi
}

# Main
main() {
    # Check for JSON output flag
    for arg in "$@"; do
        if [[ "$arg" == "--json" ]]; then
            # Run detections silently
            exec 3>&1 4>&2
            exec 1>/dev/null 2>&1

            detect_cluster_type
            detect_k8s_version
            detect_kernel_version
            check_privileged_support
            detect_existing_tools
            generate_recommendation

            exec 1>&3 2>&4
            output_json --json
            exit 0
        fi
    done

    # Check kubectl access
    if ! kubectl cluster-info &>/dev/null; then
        echo -e "${RED}Error: Cannot connect to Kubernetes cluster${NC}"
        echo "Please ensure kubectl is configured correctly."
        exit 1
    fi

    print_header

    detect_cluster_type
    detect_k8s_version
    detect_kernel_version
    check_privileged_support
    detect_existing_tools
    generate_recommendation

    echo ""
}

main "$@"
