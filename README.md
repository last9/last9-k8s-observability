# Last9 OpenTelemetry Operator Setup

Automated setup script for deploying OpenTelemetry Operator, Collector, Kubernetes monitoring, and Events collection to your Kubernetes cluster with Last9 integration.

## Features

- ✅ **One-command installation** - Deploy everything with a single command
- ✅ **Flexible deployment options** - Install only what you need (logs, traces, metrics, events)
- ✅ **Auto-instrumentation** - Automatic instrumentation for Java, Python, Node.js, and more
- ✅ **Kubernetes monitoring** - Full cluster observability with kube-prometheus-stack
- ✅ **Events collection** - Capture and forward Kubernetes events
- ✅ **Cluster identification** - Automatic cluster name detection and attribution
- ✅ **Tolerations support** - Deploy on tainted nodes (control-plane, spot instances, etc.)
- ✅ **Environment customization** - Override deployment environment and cluster name

## Quick Start

### Prerequisites

- `kubectl` configured to access your Kubernetes cluster
- `helm` (v3+) installed

### Option 1: Install Everything (Recommended)

Installs OpenTelemetry Operator, Collector, Kubernetes monitoring stack, and Events agent:

```bash
./last9-otel-setup.sh \
  token="Basic <your-base64-token>" \
  endpoint="<your-otlp-endpoint>" \
  monitoring-endpoint="<your-metrics-endpoint>" \
  username="<your-username>" \
  password="<your-password>"
```

### Quick Install (One-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/last9/l9-otel-operator/main/last9-otel-setup.sh | bash -s -- \
  token="Basic <your-token>" \
  endpoint="<your-otlp-endpoint>" \
  monitoring-endpoint="<your-metrics-endpoint>" \
  username="<user>" \
  password="<pass>"
```

## Installation Options

### Option 2: Traces Only (Operator + Collector)

For applications that need distributed tracing:

```bash
./last9-otel-setup.sh operator-only \
  token="Basic <your-token>" \
  endpoint="<your-otlp-endpoint>"
```

### Option 3: Logs Only (Collector without Operator)

For log collection use cases:

```bash
./last9-otel-setup.sh logs-only \
  token="Basic <your-token>" \
  endpoint="<your-otlp-endpoint>"
```

### Option 4: Metrics Only (Kubernetes Monitoring)

For cluster metrics and monitoring:

```bash
./last9-otel-setup.sh monitoring-only \
  monitoring-endpoint="<your-metrics-endpoint>" \
  username="<your-username>" \
  password="<your-password>"
```

### Option 5: Kubernetes Events Only

For Kubernetes events collection:

```bash
./last9-otel-setup.sh events-only \
  endpoint="<your-otlp-endpoint>" \
  token="Basic <your-base64-token>" \
  monitoring-endpoint="<your-metrics-endpoint>"
```

## Advanced Configuration

### Override Cluster Name

```bash
./last9-otel-setup.sh \
  token="..." \
  endpoint="..." \
  cluster="prod-us-east-1"
```

If not provided, the cluster name is auto-detected from `kubectl config current-context`.

### Set Deployment Environment

```bash
./last9-otel-setup.sh \
  token="..." \
  endpoint="..." \
  env="production"
```

Default: `staging` for collector, `local` for auto-instrumentation.

### Deploy with Tolerations

For deploying on nodes with taints (e.g., control-plane, monitoring nodes):

```bash
./last9-otel-setup.sh \
  token="..." \
  endpoint="..." \
  tolerations-file=/path/to/tolerations.yaml
```

**Example tolerations files** are provided in the `examples/` directory:
- `tolerations-all-nodes.yaml` - Deploy on all nodes including control-plane
- `tolerations-monitoring-nodes.yaml` - Deploy on dedicated monitoring nodes
- `tolerations-spot-instances.yaml` - Deploy on spot/preemptible instances
- `tolerations-multi-taint.yaml` - Handle multiple taints
- `tolerations-nodeSelector-only.yaml` - Use nodeSelector without tolerations

## Configuration Files

| File | Description |
|------|-------------|
| `last9-otel-collector-values.yaml` | OpenTelemetry Collector configuration for logs and traces |
| `k8s-monitoring-values.yaml` | Kube-prometheus-stack configuration for metrics |
| `last9-kube-events-agent-values.yaml` | Events collection agent configuration |
| `collector-svc.yaml` | Collector service for application instrumentation |
| `instrumentation.yaml` | Auto-instrumentation configuration |
| `deploy.yaml` | Sample application deployment with auto-instrumentation |
| `tolerations.yaml` | Sample tolerations configuration |

### Placeholders

The following placeholders are automatically replaced during installation:

- `{{AUTH_TOKEN}}` - Your Last9 authorization token
- `{{OTEL_ENDPOINT}}` - Your OTEL endpoint URL
- `{{MONITORING_ENDPOINT}}` - Your metrics endpoint URL

## Uninstallation

### Uninstall Everything

```bash
./last9-otel-setup.sh uninstall-all
```

### Uninstall Specific Components

```bash
# Uninstall only monitoring stack
./last9-otel-setup.sh uninstall function="uninstall_last9_monitoring"

# Uninstall only events agent
./last9-otel-setup.sh uninstall function="uninstall_events_agent"

# Uninstall OpenTelemetry components (operator + collector)
./last9-otel-setup.sh uninstall
```

## Verification

After installation, verify the deployment:

```bash
# Check all pods in last9 namespace
kubectl get pods -n last9

# Check collector logs
kubectl logs -n last9 -l app.kubernetes.io/name=opentelemetry-collector

# Check monitoring stack
kubectl get prometheus -n last9

# Check events agent
kubectl get pods -n last9 -l app.kubernetes.io/name=last9-kube-events-agent
```

## Auto-Instrumentation

The script automatically sets up instrumentation for:

- ☕ **Java** - Automatic OTLP export
- 🐍 **Python** - Automatic OTLP export
- 🟢 **Node.js** - Automatic OTLP export
- 🔵 **Go** - Manual instrumentation supported
- 💎 **Ruby** - Coming soon

## Application Metrics Scraping (Optional)

The OpenTelemetry Collector can automatically discover and scrape application metrics using Kubernetes service discovery with Prometheus-compatible scraping.

**Note:** This is an optional feature. Use `last9-otel-collector-metrics-values.yaml` to enable metrics scraping.

### Enable Metrics Scraping

To enable application metrics scraping, deploy with the additional metrics configuration file:

```bash
# Deploy with metrics scraping enabled
helm upgrade last9-opentelemetry-collector opentelemetry-collector \
  --namespace last9 \
  --values last9-otel-collector-values.yaml \
  --values last9-otel-collector-metrics-values.yaml
```

**Configure Last9 Metrics Endpoint:**

Before deploying, update these placeholders in `last9-otel-collector-metrics-values.yaml`:
- `{{LAST9_METRICS_ENDPOINT}}` - Your Last9 Prometheus remote write URL
- `{{LAST9_METRICS_USERNAME}}` - Your Last9 metrics username
- `{{LAST9_METRICS_PASSWORD}}` - Your Last9 metrics password

### Quick Start

Add these annotations to your pod template or service to enable automatic metrics scraping:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  template:
    metadata:
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"  # Optional, defaults to /metrics
```

That's it! Your application metrics will be automatically:
- **Discovered** - No manual configuration needed
- **Scraped** - Every 30 seconds by default
- **Enriched** - With pod, namespace, node labels
- **Exported** - To Last9 via Prometheus remote write

### How It Works

1. **Automatic Discovery** - OTel Collector watches Kubernetes API for all pods/services
2. **Annotation-Based Filtering** - Only scrapes resources with `prometheus.io/scrape: "true"`
3. **Metadata Enrichment** - Adds Kubernetes labels automatically (pod, namespace, node, app)
4. **Direct Export** - Sends metrics to Last9 Prometheus endpoint

### Supported Annotations

| Annotation | Required | Default | Description |
|------------|----------|---------|-------------|
| `prometheus.io/scrape` | Yes | - | Set to "true" to enable scraping |
| `prometheus.io/port` | Yes | - | Port number exposing /metrics |
| `prometheus.io/path` | No | /metrics | HTTP path for metrics endpoint |

### Scaling

This setup scales automatically:
- **1 service** → Automatically scraped
- **1000 services** → Automatically scraped
- **No configuration changes needed** when adding new services

### Configuration Files

**Base Configuration:** `last9-otel-collector-values.yaml`
- Traces and logs collection
- Basic OTLP receiver
- No metrics scraping

**Optional Metrics Configuration:** `last9-otel-collector-metrics-values.yaml`
- **Prometheus receiver** with kubernetes_sd_configs for auto-discovery
- **prometheusremotewrite exporter** for sending to Last9
- **RBAC** for Kubernetes API access
- **Increased resource limits** for collector pods
- **BasicAuth extension** for Last9 metrics endpoint

To use both: `--values last9-otel-collector-values.yaml --values last9-otel-collector-metrics-values.yaml`

### Verification

Check if metrics are being scraped:

```bash
# Check collector logs for scraping
kubectl logs -n last9 -l app.kubernetes.io/name=last9-otel-collector | grep kubernetes-pods

# Port-forward to collector metrics endpoint
kubectl port-forward -n last9 daemonset/last9-otel-collector 8888:8888

# Check scrape status
curl http://localhost:8888/metrics | grep scrape_samples_scraped
```
