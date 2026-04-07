# Last9 OpenTelemetry Operator

A setup script that deploys the OpenTelemetry Operator, Collector, Kubernetes monitoring stack, and events collection to your cluster — all wired to Last9. You need `kubectl` and `helm` (v3+) configured before running anything.

## Install

The default install deploys everything: OTel Operator, Collector, kube-prometheus-stack, and the events agent.

```bash
./last9-otel-setup.sh \
  token="Basic <your-base64-token>" \
  endpoint="<your-otlp-endpoint>" \
  monitoring-endpoint="<your-metrics-endpoint>" \
  username="<your-username>" \
  password="<your-password>"
```

Or pipe it directly:

```bash
curl -fsSL https://raw.githubusercontent.com/last9/l9-otel-operator/main/last9-otel-setup.sh | bash -s -- \
  token="Basic <your-token>" \
  endpoint="<your-otlp-endpoint>" \
  monitoring-endpoint="<your-metrics-endpoint>" \
  username="<user>" \
  password="<pass>"
```

## Partial Installs

If you only need a subset of the stack:

```bash
# Traces and logs only (Operator + Collector, no monitoring stack)
./last9-otel-setup.sh operator-only \
  token="Basic <your-token>" \
  endpoint="<your-otlp-endpoint>"

# Logs only (Collector without Operator)
./last9-otel-setup.sh logs-only \
  token="Basic <your-token>" \
  endpoint="<your-otlp-endpoint>"

# Cluster metrics only (kube-prometheus-stack)
./last9-otel-setup.sh monitoring-only \
  monitoring-endpoint="<your-metrics-endpoint>" \
  username="<your-username>" \
  password="<your-password>"

# Kubernetes events only
./last9-otel-setup.sh events-only \
  token="Basic <your-base64-token>" \
  endpoint="<your-otlp-endpoint>" \
  monitoring-endpoint="<your-metrics-endpoint>"
```

## Configuration Options

**Cluster name** — defaults to the current kubectl context. Override it:

```bash
./last9-otel-setup.sh \
  token="..." endpoint="..." \
  cluster="prod-us-east-1"
```

**Deployment environment** — defaults to `staging` for the collector and `local` for auto-instrumentation. Override it:

```bash
./last9-otel-setup.sh \
  token="..." endpoint="..." \
  env="production"
```

**Tolerations** — for nodes with taints (control-plane, spot instances, GPU nodes):

```bash
./last9-otel-setup.sh \
  token="..." endpoint="..." \
  tolerations-file=examples/tolerations-gpu-nodes.yaml
```

The `examples/` directory has ready-made tolerations files for common scenarios: all nodes, monitoring-dedicated nodes, spot instances, multi-taint, nodeSelector-only, and GPU nodes.

## Auto-Instrumentation

The install sets up zero-code instrumentation for Java, Python, and Node.js via the OTel Operator. Go requires manual instrumentation.

Annotate your pods to opt in:

```yaml
instrumentation.opentelemetry.io/inject-java: "true"
instrumentation.opentelemetry.io/inject-python: "true"
instrumentation.opentelemetry.io/inject-nodejs: "true"
```

## Application Metrics Scraping

By default the collector handles traces and logs. To also scrape Prometheus-format application metrics, layer on the metrics values file:

```bash
helm upgrade --install last9-opentelemetry-collector open-telemetry/opentelemetry-collector \
  --namespace last9 \
  --version 0.125.0 \
  --values last9-otel-collector-values.yaml \
  --values last9-otel-collector-metrics-values.yaml
```

Any pod with `prometheus.io/scrape: "true"` will be discovered and scraped automatically. The supported annotations are:

| Annotation | Required | Default |
|---|---|---|
| `prometheus.io/scrape` | yes | — |
| `prometheus.io/port` | yes | — |
| `prometheus.io/path` | no | `/metrics` |

## GPU and Ray Metrics

For NVIDIA GPU (DCGM) and Ray metrics, use `last9-otel-collector-gpu-values.yaml` instead of the base metrics file — it includes all application scrape jobs plus DCGM and Ray.

```bash
helm upgrade --install last9-opentelemetry-collector open-telemetry/opentelemetry-collector \
  --namespace last9 \
  --version 0.125.0 \
  --values last9-otel-collector-values.yaml \
  --values last9-otel-collector-gpu-values.yaml
```

The values file ships two DCGM variants. Variant A (default) targets `nvidia-dcgm-exporter` pods from the NVIDIA GPU Operator — used on EKS, AKS, and bare-metal. Variant B targets `gke-managed-dcgm-exporter` in the `gke-managed-system` namespace — used on GKE. Check which is running in your cluster:

```bash
# GKE
kubectl get pods -n gke-managed-system -l app.kubernetes.io/name=gke-managed-dcgm-exporter

# Self-managed (NVIDIA GPU Operator)
kubectl get pods -A -l app.kubernetes.io/name=nvidia-dcgm-exporter
```

If you're on GKE, comment out Variant A and uncomment Variant B in the values file. See the inline comments for specifics.

DCGM collection is capped to 18 key metrics (utilization, memory, temperature, power, errors, PCIe, clock) via a `metric_relabel_configs` keep-list. To collect additional DCGM metrics, extend that regex in `last9-otel-collector-gpu-values.yaml`.

Ray metrics are discovered by label (`ray.io/node-type`) and require [KubeRay Operator](https://docs.ray.io/en/latest/cluster/kubernetes/getting-started.html).

For GPU nodes with `nvidia.com/gpu` taints, pass a tolerations file so the collector can schedule there:

```bash
./last9-otel-setup.sh \
  token="..." endpoint="..." monitoring-endpoint="..." \
  username="..." password="..." \
  tolerations-file=examples/tolerations-gpu-nodes.yaml
```

Collector resource needs scale with the number of GPU nodes. These numbers are starting points, not guarantees — benchmark against your actual scrape load:

| GPU Nodes | CPU Request/Limit | Memory Request/Limit |
|---|---|---|
| 1–10 | 250m / 500m | 512Mi / 1Gi |
| 10–50 | 500m / 1000m | 1Gi / 2Gi |
| 50–100 | 1000m / 2000m | 2Gi / 4Gi |

## Uninstall

```bash
# Everything
./last9-otel-setup.sh uninstall-all

# Only the monitoring stack
./last9-otel-setup.sh uninstall function="uninstall_last9_monitoring"

# Only the events agent
./last9-otel-setup.sh uninstall function="uninstall_events_agent"

# OTel Operator and Collector only
./last9-otel-setup.sh uninstall
```

## Verify

```bash
kubectl get pods -n last9
kubectl logs -n last9 -l app.kubernetes.io/name=opentelemetry-collector
kubectl get prometheus -n last9
kubectl get pods -n last9 -l app.kubernetes.io/name=last9-kube-events-agent
```

For metrics scraping specifically:

```bash
kubectl port-forward -n last9 daemonset/last9-otel-collector 8888:8888
curl http://localhost:8888/metrics | grep scrape_samples_scraped
```
