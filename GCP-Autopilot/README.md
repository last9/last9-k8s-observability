# GKE Autopilot Configuration for Last9 OpenTelemetry Stack

This folder contains GKE Autopilot-specific configurations and installation script for deploying the Last9 OpenTelemetry observability stack.

## Overview

GKE Autopilot has stricter security policies compared to standard GKE clusters. This configuration has been specifically adapted to work within Autopilot's constraints while providing comprehensive observability coverage.

## What's Included

- **Installation Script**: `last9-otel-setup_gke_autopilot.sh` - Automated setup for all components
- **Configuration Files**: Pre-configured Helm values files with placeholders
- **GKE Autopilot Optimizations**: All configurations adapted for Autopilot restrictions

## Components Installed

1. **cert-manager** - Certificate management for webhook TLS (prerequisite)
2. **OpenTelemetry Operator** - Manages OpenTelemetry Collectors and auto-instrumentation
3. **OpenTelemetry Collector** - Collects traces, metrics, and logs via OTLP protocol
4. **Prometheus Stack** - Kubernetes metrics collection and forwarding
5. **Kubernetes Events Agent** - Captures and forwards K8s cluster events

## Prerequisites

- **kubectl**: Configured to access your GKE Autopilot cluster
- **Helm**: Version 3.18.4 or later
- **GKE Autopilot Cluster**: A running GKE Autopilot cluster
- **Last9 Account**: With OTLP endpoint and credentials

## Quick Start

### Installation

```bash
cd GCP-Autopilot

./last9-otel-setup_gke_autopilot.sh \
  endpoint="<YOUR_OTLP_ENDPOINT>" \
  token="<YOUR_AUTH_TOKEN>" \
  monitoring-endpoint="<YOUR_PROMETHEUS_ENDPOINT>" \
  username="<YOUR_USERNAME>" \
  password="<YOUR_PASSWORD>"
```

**Example:**
```bash
./last9-otel-setup_gke_autopilot.sh \
  endpoint="https://otlp-aps1.last9.io:443" \
  token="Basic YOUR_TOKEN_HERE" \
  monitoring-endpoint="https://app-tsdb.last9.io/v1/metrics/YOUR_ENDPOINT/sender/last9/write" \
  username="your-username" \
  password="your-password"
```

### Uninstallation

```bash
./last9-otel-setup_gke_autopilot.sh uninstall-all
```

## GKE Autopilot-Specific Changes

GKE Autopilot enforces strict security policies. The following modifications have been made to accommodate these restrictions:

### 1. Disabled File-Based Log Collection

**Reason**: Autopilot does not allow hostPath volumes at `/var/lib/docker/containers`

**Impact**: Cannot collect logs directly from container log files

**Solution**:
- Applications can send logs via OTLP protocol (supported)
- Logs are collected through stdout/stderr (standard Kubernetes logging)

**Configuration**:
```yaml
presets:
  logsCollection:
    enabled: false  # Disabled for Autopilot
```

### 2. Disabled Node-Exporter

**Reason**: Node-exporter requires:
- Host PID namespace access
- Host network access
- HostPath volumes (`/proc`, `/sys`, `/`)

All of these are denied by Autopilot's security policies.

**Impact**: Cannot collect node-level metrics (CPU, memory, disk, network at host level)

**Alternatives**:
- Use GKE's built-in monitoring (Cloud Monitoring)
- kube-state-metrics still provides pod/container metrics
- Kubelet metrics (when available) provide container-level insights

**Configuration**:
```yaml
nodeExporter:
  enabled: false
```

### 3. Disabled Kubelet Monitoring

**Reason**: Attempts to access `kube-system` namespace which is restricted in Autopilot

**Impact**: Cannot scrape metrics directly from kubelet

**Alternative**: kube-state-metrics provides similar insights

**Configuration**:
```yaml
kubelet:
  enabled: false
```

### 4. Added Resource Limits

**Reason**: Autopilot requires all workloads to have resource limits defined

**Impact**: None - actually improves resource management

**Configuration**:
```yaml
resources:
  limits:
    cpu: 500m
    memory: 1Gi
  requests:
    cpu: 200m
    memory: 512Mi
```

### 5. Disabled API Server Monitoring

**Reason**: Cannot create services in `kube-system` namespace

**Configuration**:
```yaml
kubeApiServer:
  enabled: false
```

## Configuration Files

All configuration files use placeholders that are replaced at runtime by the script:

### Placeholders

- `{{AUTH_TOKEN}}` - Your Last9 authentication token
- `{{OTEL_ENDPOINT}}` - Your OTLP endpoint URL
- `{{MONITORING_ENDPOINT}}` - Your Prometheus remote write endpoint
- `{{CLUSTER_NAME}}` - Auto-detected from kubectl context

### Files

| File | Purpose |
|------|---------|
| `last9-otel-collector-values.yaml` | OpenTelemetry Collector configuration |
| `last9-kube-events-agent-values.yaml` | Events agent configuration |
| `k8s-monitoring-values.yaml` | Prometheus stack configuration |
| `collector-svc.yaml` | Collector service definition |
| `instrumentation.yaml` | Auto-instrumentation configuration |

**Note**: NO credentials are hardcoded in any files. All values are parameterized.

## Verification

After installation, verify all components are running:

```bash
# Check pods
kubectl get pods -n last9

# Check services
kubectl get svc -n last9

# Check collector logs
kubectl logs -n last9 -l app.kubernetes.io/name=opentelemetry-collector --tail=50

# Check events agent logs
kubectl logs -n last9 -l app.kubernetes.io/name=last9-kube-events-agent --tail=50
```

Expected output:
- 10+ pods in Running state
- 8 services created
- No error messages in logs

## Using Auto-Instrumentation

To enable automatic instrumentation for your applications:

### Java Applications

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-java-app
spec:
  template:
    metadata:
      annotations:
        instrumentation.opentelemetry.io/inject-java: "true"
    spec:
      containers:
      - name: app
        image: your-java-app:latest
```

### Python Applications

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-python-app
spec:
  template:
    metadata:
      annotations:
        instrumentation.opentelemetry.io/inject-python: "true"
    spec:
      containers:
      - name: app
        image: your-python-app:latest
```

### Node.js Applications

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-nodejs-app
spec:
  template:
    metadata:
      annotations:
        instrumentation.opentelemetry.io/inject-nodejs: "true"
    spec:
      containers:
      - name: app
        image: your-nodejs-app:latest
```

## Troubleshooting

### Pods Not Starting

**Check Autopilot has allocated resources:**
```bash
kubectl describe pod <pod-name> -n last9
```

Look for events indicating resource constraints or policy violations.

### Collector Not Receiving Data

**Check collector logs:**
```bash
kubectl logs -n last9 deployment/last9-opentelemetry-collector-last9-otel-collector-agent
```

**Verify endpoints:**
```bash
kubectl get svc otel-collector-service -n last9
```

### Instrumentation Not Working

**Check instrumentation resource:**
```bash
kubectl get instrumentation -n last9
kubectl describe instrumentation l9-instrumentation -n last9
```

**Verify webhook certificates:**
```bash
kubectl get certificate -n last9
```

If certificates show as not ready, wait 5-10 minutes or restart the operator:
```bash
kubectl rollout restart deployment/opentelemetry-operator -n last9
```

### Connection Errors

**Verify network policies:**
```bash
kubectl get networkpolicies -n last9
```

**Test connectivity from a pod:**
```bash
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl -v http://otel-collector-service.last9.svc:4318
```

## Comparison: Standard GKE vs Autopilot

| Feature | Standard GKE | GKE Autopilot |
|---------|--------------|---------------|
| Node-level metrics | ✅ Supported | ❌ Not allowed (hostPath restriction) |
| File-based log collection | ✅ Supported | ❌ Not allowed (hostPath restriction) |
| OTLP log collection | ✅ Supported | ✅ Supported |
| Trace collection | ✅ Supported | ✅ Supported |
| Metrics collection | ✅ Supported | ✅ Supported (pod/container level) |
| Events collection | ✅ Supported | ✅ Supported |
| Auto-instrumentation | ✅ Supported | ✅ Supported |
| Custom resource limits | Optional | Required |

## What Data is Collected

### ✅ Collected in Autopilot

- **Traces**: Application traces via OTLP
- **Metrics**:
  - Pod and container metrics (kube-state-metrics)
  - Application metrics via OTLP
  - Kubernetes API server metrics (when accessible)
- **Logs**:
  - Application logs via OTLP protocol
  - Kubernetes events
- **Events**: All Kubernetes cluster events

### ❌ Not Collected in Autopilot

- **Host-level metrics**: CPU, memory, disk, network from nodes
- **File-based logs**: Direct container log files from `/var/lib/docker/containers`
- **Kubelet metrics**: Direct kubelet scraping

## Best Practices

1. **Always use OTLP for logs**: Configure your applications to send logs via OTLP protocol
2. **Set resource limits**: Even though Autopilot enforces them, define appropriate limits
3. **Monitor costs**: Autopilot auto-scales - monitor your node usage
4. **Use GKE's native monitoring**: For node-level metrics, use Cloud Monitoring alongside this stack
5. **Test instrumentation**: Always test auto-instrumentation in dev before production

## Additional Resources

- [GKE Autopilot Documentation](https://cloud.google.com/kubernetes-engine/docs/concepts/autopilot-overview)
- [OpenTelemetry Operator](https://github.com/open-telemetry/opentelemetry-operator)
- [Last9 Documentation](https://docs.last9.io)
- [GKE Autopilot Restrictions](https://cloud.google.com/kubernetes-engine/docs/concepts/autopilot-security)

## Support

For issues specific to:
- **Last9 platform**: Contact Last9 support
- **GKE Autopilot**: Refer to Google Cloud documentation
- **This configuration**: Open an issue in the repository

## License

This configuration is part of the Last9 Kubernetes observability repository.
