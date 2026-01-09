# Last9 Kubernetes Observability

One-command OpenTelemetry setup for Kubernetes with automatic instrumentation, service discovery, and Last9 integration.

[![OpenTelemetry](https://img.shields.io/badge/OpenTelemetry-supported-blueviolet)](https://opentelemetry.io/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.24+-blue)](https://kubernetes.io/)
[![License](https://img.shields.io/badge/License-Apache%202.0-green.svg)](LICENSE)

## Why This Exists

Setting up observability in Kubernetes typically requires:
- Installing and configuring the OTel Operator
- Deploying and tuning collectors
- Creating instrumentation resources
- Manually annotating every namespace
- Configuring service names and environments

**This project reduces all of that to a single command.**

## Features

| Feature | Description |
|---------|-------------|
| **One-Command Install** | Deploy everything with a single command |
| **Auto-Instrumentation** | Java, Python, Node.js, .NET, PHP — zero code changes |
| **Namespace Management** | Whitelist, blacklist, or instrument all namespaces |
| **Smart Service Naming** | Auto-detect `service.name` from K8s labels |
| **Environment Detection** | Auto-detect `deployment.environment` from namespace |
| **Full Stack** | Traces, logs, metrics, and K8s events |

## Quick Start

### Prerequisites

- `kubectl` configured with cluster access
- `helm` v3+

### Install Everything

```bash
./last9-otel-setup.sh \
  token="Basic <your-base64-token>" \
  endpoint="<your-otlp-endpoint>" \
  monitoring-endpoint="<your-metrics-endpoint>" \
  username="<your-username>" \
  password="<your-password>"
```

### One-Liner Install

```bash
curl -fsSL https://raw.githubusercontent.com/last9/last9-k8s-observability/main/last9-otel-setup.sh | bash -s -- \
  token="Basic <your-token>" \
  endpoint="<your-otlp-endpoint>" \
  monitoring-endpoint="<your-metrics-endpoint>" \
  username="<user>" \
  password="<pass>"
```

## Auto-Instrumentation

### Supported Languages

| Language | Status | Notes |
|----------|--------|-------|
| Java | Enabled | Automatic OTLP export |
| Python | Enabled | Automatic OTLP export |
| Node.js | Enabled | Automatic OTLP export |
| .NET | Enabled | Automatic OTLP export |
| PHP | Enabled | Automatic OTLP export |
| Go | Optional | eBPF-based, requires annotation |
| Apache HTTPD | Optional | Web server instrumentation |
| Nginx | Optional | Web server instrumentation |
| Rust | Not Supported | Compiled language, use SDK |

### Namespace-Level Instrumentation

Instrument namespaces without modifying deployments:

```bash
# Instrument ALL namespaces (excludes system namespaces)
./last9-otel-setup.sh auto-instrument=all token="..." endpoint="..."

# Whitelist specific namespaces
./last9-otel-setup.sh auto-instrument=app1,app2,app3 token="..." endpoint="..."

# Exclude specific namespaces
./last9-otel-setup.sh auto-instrument-exclude=staging,dev token="..." endpoint="..."

# Instrument AND restart existing workloads immediately
./last9-otel-setup.sh auto-instrument=all restart-workloads token="..." endpoint="..."
```

**System namespaces are always excluded:** `kube-system`, `kube-public`, `kube-node-lease`, `cert-manager`, `istio-system`, `linkerd`, `monitoring`, `prometheus`, `grafana`, `argocd`, `flux-system`, `last9`

### Workload Restart Control

By default, only **new pods** are instrumented. Existing pods require a restart.

```bash
# Option 1: Restart during setup (recommended for initial deployment)
./last9-otel-setup.sh auto-instrument=all restart-workloads token="..." endpoint="..."

# Option 2: Manual restart after setup
kubectl rollout restart deployment -n <namespace>
```

### Per-Deployment Instrumentation

Add annotation to your deployment:

```yaml
metadata:
  annotations:
    instrumentation.opentelemetry.io/inject-java: "last9/l9-instrumentation"
    # Or for other languages:
    # instrumentation.opentelemetry.io/inject-python: "last9/l9-instrumentation"
    # instrumentation.opentelemetry.io/inject-nodejs: "last9/l9-instrumentation"
    # instrumentation.opentelemetry.io/inject-dotnet: "last9/l9-instrumentation"
    # instrumentation.opentelemetry.io/inject-php: "last9/l9-instrumentation"
```

### Opt-Out Specific Deployments

Exclude specific pods/deployments from namespace-level instrumentation:

```yaml
metadata:
  annotations:
    # Disable Java instrumentation for this deployment
    instrumentation.opentelemetry.io/inject-java: "false"
    # Disable all languages
    instrumentation.opentelemetry.io/inject-python: "false"
    instrumentation.opentelemetry.io/inject-nodejs: "false"
    instrumentation.opentelemetry.io/inject-dotnet: "false"
    instrumentation.opentelemetry.io/inject-php: "false"
```

## Service Name & Environment Detection

### Automatic Detection

The collector automatically resolves `service.name` and `deployment.environment` from Kubernetes metadata:

**service.name priority:**
1. `last9.io/service` annotation
2. `app.kubernetes.io/name` label
3. `app.kubernetes.io/component` label
4. Deployment name
5. `app` label
6. Container name

**deployment.environment priority:**
1. `last9.io/env` annotation
2. `environment` label
3. `app.kubernetes.io/environment` label
4. Namespace name

### Explicit Override

Override via annotations when needed:

```yaml
metadata:
  annotations:
    last9.io/service: "payment-service"
    last9.io/env: "production"
```

## Sampling Configuration

Two approaches for controlling trace sampling:

| Approach | Where | Pros | Cons |
|----------|-------|------|------|
| **SDK-level (Head)** | Application | Efficient, low overhead | Decision at trace start |
| **Collector-level (Tail)** | OTel Collector | See full trace before deciding | Higher memory, latency |

### Global Sampling Rate

The default sampling rate is 100% (`1.0`). Modify `instrumentation.yaml`:

```yaml
spec:
  sampler:
    type: parentbased_traceidratio
    argument: "0.1"  # 10% sampling
```

### Per-Service Sampling (SDK-level, OTel Standard)

Create multiple Instrumentation CRDs with different sampling rates (provided in `instrumentation-sampling.yaml`):

```bash
# Apply sampling variants
kubectl apply -f instrumentation-sampling.yaml -n last9
```

Available presets:
- `l9-instrumentation` - 100% (default)
- `l9-instrumentation-50pct` - 50%
- `l9-instrumentation-10pct` - 10%
- `l9-instrumentation-1pct` - 1%

Reference by name in your deployment:

```yaml
metadata:
  annotations:
    # Use 10% sampling for this high-traffic service
    instrumentation.opentelemetry.io/inject-java: "last9/l9-instrumentation-10pct"
```

### Per-Service Sampling (Collector-level, Tail Sampling)

For more flexible sampling decisions (e.g., always keep errors, sample by attribute), use the `last9.io/sample-rate` annotation with collector tail sampling.

**Step 1:** Add annotation to your deployment:

```yaml
metadata:
  annotations:
    last9.io/sample-rate: "0.1"  # Hint for 10% sampling
```

**Step 2:** Enable tail sampling in `last9-otel-collector-values.yaml` (see commented example).

The annotation is extracted to `last9.sample_rate` trace attribute for use in sampling policies.

### When to Use Which

| Use Case | Recommended Approach |
|----------|---------------------|
| Simple rate limiting | SDK-level (head sampling) |
| Always keep errors | Collector-level (tail sampling) |
| Sample by service name | Either |
| Sample by trace duration | Collector-level (tail sampling) |
| Lowest overhead | SDK-level (head sampling) |

## Installation Options

### Traces Only

```bash
./last9-otel-setup.sh operator-only \
  token="Basic <your-token>" \
  endpoint="<your-otlp-endpoint>"
```

### Logs Only

```bash
./last9-otel-setup.sh logs-only \
  token="Basic <your-token>" \
  endpoint="<your-otlp-endpoint>"
```

### Metrics Only

```bash
./last9-otel-setup.sh monitoring-only \
  monitoring-endpoint="<your-metrics-endpoint>" \
  username="<your-username>" \
  password="<your-password>"
```

### Events Only

```bash
./last9-otel-setup.sh events-only \
  endpoint="<your-otlp-endpoint>" \
  token="Basic <your-token>" \
  monitoring-endpoint="<your-metrics-endpoint>"
```

## Configuration

### Override Cluster Name

```bash
./last9-otel-setup.sh cluster="prod-us-east-1" token="..." endpoint="..."
```

Auto-detected from `kubectl config current-context` if not provided.

### Set Environment

```bash
./last9-otel-setup.sh env="production" token="..." endpoint="..."
```

### Tolerations

Deploy on tainted nodes:

```bash
./last9-otel-setup.sh tolerations-file=/path/to/tolerations.yaml token="..." endpoint="..."
```

Example files in `examples/`:
- `tolerations-all-nodes.yaml`
- `tolerations-monitoring-nodes.yaml`
- `tolerations-spot-instances.yaml`

## Application Metrics Scraping

Enable Prometheus-style metrics scraping with annotations:

```yaml
metadata:
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8080"
    prometheus.io/path: "/metrics"  # Optional, defaults to /metrics
```

Deploy with metrics configuration:

```bash
helm upgrade last9-opentelemetry-collector open-telemetry/opentelemetry-collector \
  --namespace last9 \
  --values last9-otel-collector-values.yaml \
  --values last9-otel-collector-metrics-values.yaml
```

## Verification

```bash
# Check all components
kubectl get pods -n last9

# Check collector logs
kubectl logs -n last9 -l app.kubernetes.io/name=opentelemetry-collector

# Check instrumentation
kubectl get instrumentation -n last9

# Verify auto-instrumented namespaces
kubectl get ns -o json | jq '.items[] | select(.metadata.annotations["instrumentation.opentelemetry.io/inject-java"] != null) | .metadata.name'
```

## Uninstallation

```bash
# Uninstall everything
./last9-otel-setup.sh uninstall-all

# Uninstall specific components
./last9-otel-setup.sh uninstall                                    # OTel components
./last9-otel-setup.sh uninstall function="uninstall_last9_monitoring"  # Monitoring
./last9-otel-setup.sh uninstall function="uninstall_events_agent"      # Events
```

## Configuration Files

| File | Purpose |
|------|---------|
| `last9-otel-collector-values.yaml` | Collector config (logs, traces) |
| `last9-otel-collector-metrics-values.yaml` | Optional metrics scraping |
| `k8s-monitoring-values.yaml` | Kube-prometheus-stack config |
| `last9-kube-events-agent-values.yaml` | K8s events agent |
| `instrumentation.yaml` | Auto-instrumentation config (100% sampling) |
| `instrumentation-sampling.yaml` | Per-service sampling variants (50%, 10%, 1%) |
| `collector-svc.yaml` | Collector service |

## Troubleshooting

### Pods not instrumented

1. Check namespace has instrumentation annotation:
   ```bash
   kubectl get ns <namespace> -o yaml | grep instrumentation
   ```

2. Verify instrumentation resource exists:
   ```bash
   kubectl get instrumentation -n last9
   ```

3. Check operator logs:
   ```bash
   kubectl logs -n last9 -l app.kubernetes.io/name=opentelemetry-operator
   ```

### Service name not detected

1. Ensure pods have `app.kubernetes.io/name` label
2. Or add explicit annotation: `last9.io/service: "my-service"`

### Traces not appearing

1. Check collector is receiving data:
   ```bash
   kubectl logs -n last9 -l app.kubernetes.io/name=opentelemetry-collector | grep "TracesExporter"
   ```

2. Verify endpoint connectivity:
   ```bash
   kubectl exec -n last9 -it <collector-pod> -- wget -q -O- <endpoint>/health
   ```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Your Application                          │
│  (Auto-instrumented via OTel Operator MutatingWebhook)          │
└──────────────────────────┬──────────────────────────────────────┘
                           │ OTLP (traces)
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                    OTel Collector (DaemonSet)                    │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │  Receivers  │→ │ Processors  │→ │       Exporters         │  │
│  │  - OTLP     │  │ - Transform │  │ - OTLP/HTTP (Last9)     │  │
│  │  - Filelog  │  │ - Batch     │  │                         │  │
│  └─────────────┘  └─────────────┘  └─────────────────────────┘  │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
                    ┌─────────────┐
                    │    Last9    │
                    └─────────────┘
```

## License

Apache 2.0
