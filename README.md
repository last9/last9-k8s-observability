# Last9 OpenTelemetry Operator Setup

Automated setup for deploying OpenTelemetry-based observability to your Kubernetes cluster with Last9 integration.

## Features

- **Split Architecture** - Node agent (DaemonSet) + Cluster agent (Deployment)
- **Auto-instrumentation** - Java, Python, Node.js with trace-log correlation
- **Service Name Inference** - Automatic service naming from K8s metadata
- **Trace-Log Correlation** - SDK injection + collector fallback
- **Resource Topology** - K8s resource relationships for dependency graphs
- **Kubernetes Events** - Enriched events with topology context

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│           Cluster Agent (Deployment, 1 replica)             │
│                   values-cluster.yaml                        │
│  • K8s Events (watch mode)                                  │
│  • Resource Topology (pull mode)                            │
│  • 256MB / 200m CPU                                         │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│            Node Agent (DaemonSet, 1 per node)               │
│                      values.yaml                             │
│  • Container Logs (filelog receiver)                        │
│  • App Traces (OTLP receiver)                               │
│  • App Metrics (prometheus receiver)                        │
│  • 512MB / 250m CPU per node                                │
└─────────────────────────────────────────────────────────────┘
```

## Quick Start

### Prerequisites

- `kubectl` configured with cluster access
- `helm` v3+

### Install Node Agent (DaemonSet)

Collects logs, traces, and metrics from each node:

```bash
helm install last9-collector opentelemetry/opentelemetry-collector \
  -f values.yaml \
  -n last9 --create-namespace \
  --set extraEnvs[0].name=LAST9_OTLP_ENDPOINT \
  --set extraEnvs[0].value="<your-otlp-endpoint>" \
  --set extraEnvs[1].name=LAST9_AUTH_TOKEN \
  --set extraEnvs[1].value="Basic <your-token>"
```

### Install Cluster Agent (Deployment)

Collects events and topology (single replica to avoid duplication):

```bash
helm install last9-cluster opentelemetry/opentelemetry-collector \
  -f values-cluster.yaml \
  -n last9 \
  --set extraEnvs[0].name=LAST9_OTLP_ENDPOINT \
  --set extraEnvs[0].value="<your-otlp-endpoint>" \
  --set extraEnvs[1].name=LAST9_AUTH_TOKEN \
  --set extraEnvs[1].value="Basic <your-token>"
```

### Install Auto-Instrumentation

Enable automatic tracing for applications:

```bash
# Install OTel Operator
helm install opentelemetry-operator open-telemetry/opentelemetry-operator \
  -n last9

# Apply instrumentation config
kubectl apply -f instrumentation.yaml
```

### Enable App Instrumentation

Add annotation to your deployments:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  template:
    metadata:
      annotations:
        # Choose your language:
        instrumentation.opentelemetry.io/inject-java: "true"
        # instrumentation.opentelemetry.io/inject-python: "true"
        # instrumentation.opentelemetry.io/inject-nodejs: "true"
```

## Configuration Files

| File | Description |
|------|-------------|
| `values.yaml` | Node Agent (DaemonSet) - logs, traces, metrics |
| `values-cluster.yaml` | Cluster Agent (Deployment) - events, topology, service catalog |
| `values-ebpf.yaml` | eBPF addon for network flow collection (optional) |
| `instrumentation.yaml` | Auto-instrumentation (Java, Python, Node, .NET, Go) |
| `scripts/detect-cluster.sh` | Cluster detection for eBPF compatibility |
| `scripts/detect-databases.sh` | Database detection and exporter recommendations |

### Legacy Files (deprecated)

| File | Replaced By |
|------|-------------|
| `last9-otel-collector-values.yaml` | `values.yaml` |
| `last9-otel-collector-metrics-values.yaml` | Merged into `values.yaml` |
| `last9-kube-events-agent-values.yaml` | `values-cluster.yaml` |

## Key Features

### Multi-Language Auto-Instrumentation

| Language | Annotation | Trace-Log Correlation | DB Tracing |
|----------|------------|----------------------|------------|
| Java | `inject-java: "true"` | Logback/Log4j MDC | JDBC, Hibernate |
| Python | `inject-python: "true"` | logging module | psycopg2, pymysql, pymongo |
| Node.js | `inject-nodejs: "true"` | Winston/Pino/Bunyan | pg, mysql, mongodb, redis |
| .NET | `inject-dotnet: "true"` | ILogger | SqlClient, Npgsql |
| Go | `inject-go: "true"` | eBPF-based | database/sql, pgx |
| Apache | `inject-apache-httpd: "true"` | - | - |
| Nginx | `inject-nginx: "true"` | - | - |

### Service Catalog

The cluster agent automatically builds a service catalog from your K8s workloads using standard Kubernetes labels:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
  labels:
    # Standard K8s recommended labels
    app.kubernetes.io/name: "checkout-api"
    app.kubernetes.io/version: "1.2.3"
    app.kubernetes.io/component: "backend"
    app.kubernetes.io/part-of: "ecommerce"      # Used as team/project
    app.kubernetes.io/managed-by: "helm"
  annotations:
    kubernetes.io/description: "Handles checkout flow"
```

**Standard K8s Labels (app.kubernetes.io/*):**

| Label | Description |
|-------|-------------|
| `app.kubernetes.io/name` | Application name (used as service name) |
| `app.kubernetes.io/instance` | Instance identifier |
| `app.kubernetes.io/version` | Application version |
| `app.kubernetes.io/component` | Component within architecture |
| `app.kubernetes.io/part-of` | Higher-level app grouping (team/project) |
| `app.kubernetes.io/managed-by` | Tool managing the resource |
| `kubernetes.io/description` | Resource description (annotation) |

### Service Name Inference

Service names are automatically inferred with this priority:

1. `last9.io/service-name` annotation
2. `OTEL_SERVICE_NAME` env var (SDK)
3. `helm.sh/release-name` label
4. Deployment/StatefulSet/DaemonSet name
5. `app.kubernetes.io/name` label
6. `app` label
7. Container name (fallback)

### Trace-Log Correlation

Logs are automatically correlated with traces:

**SDK Injection (Primary)**
- `OTEL_LOGS_EXPORTER=otlp` enabled
- Java: Logback/Log4j appenders inject trace context
- Python: Logging auto-instrumentation enabled
- Node.js: Built-in trace context propagation

**Collector Fallback (Legacy Apps)**
- Extracts `trace_id`/`span_id` from JSON log bodies
- Supports patterns: `trace_id`, `traceId`, `traceID`, `dd.trace_id`

### Application Metrics

Enable Prometheus scraping with annotations:

```yaml
metadata:
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8080"
    prometheus.io/path: "/metrics"  # Optional
```

### Database Detection

Automatically detect databases in your cluster and get exporter recommendations:

```bash
# Scan all namespaces
./scripts/detect-databases.sh

# Scan specific namespace
./scripts/detect-databases.sh -n production

# Generate exporter values file
./scripts/detect-databases.sh --generate postgresql
```

**Supported databases:**
- PostgreSQL, MySQL, MongoDB, Redis
- Elasticsearch, Kafka, Cassandra
- RabbitMQ, Memcached, MSSQL
- ClickHouse, CockroachDB, etcd, Consul, Vault

### eBPF Network Flows (Advanced)

Enable network flow collection for service dependency mapping using eBPF.

**Check Cluster Compatibility:**

```bash
./scripts/detect-cluster.sh
```

This detects:
- Cluster type (EKS, GKE, AKS, vanilla K8s, etc.)
- Kernel version for eBPF support (5.x+ recommended)
- Privileged container support
- Existing network tools (Cilium, Istio, etc.)

**Requirements:**

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| Kernel | 4.14+ | 5.8+ |
| Privileged containers | Required | Required |
| Memory per node | 512Mi | 1Gi |

**Cluster Support:**

| Cluster | eBPF Support | Notes |
|---------|--------------|-------|
| EKS | ✅ Full | Standard nodes |
| GKE Standard | ✅ Full | Standard nodes |
| GKE Autopilot | ❌ None | No privileged containers |
| AKS | ✅ Full | Standard nodes |
| OpenShift | ✅ With SCC | Requires SCC configuration |
| Vanilla K8s | ✅ Full | Self-hosted |

**Install with eBPF:**

```bash
# Check compatibility first
./scripts/detect-cluster.sh

# Install with eBPF overlay
helm install last9-collector opentelemetry/opentelemetry-collector \
  -f values.yaml -f values-ebpf.yaml \
  -n last9 --create-namespace \
  --set extraEnvs[0].name=LAST9_OTLP_ENDPOINT \
  --set extraEnvs[0].value="<your-otlp-endpoint>" \
  --set extraEnvs[1].name=LAST9_AUTH_TOKEN \
  --set extraEnvs[1].value="Basic <your-token>"
```

**OpenShift Setup:**

```bash
# Grant privileged SCC to service account
oc adm policy add-scc-to-user privileged \
  -z last9-otel-collector -n last9

# Then install with eBPF values
helm install last9-collector opentelemetry/opentelemetry-collector \
  -f values.yaml -f values-ebpf.yaml -n last9
```

**Integration with Cilium Hubble:**

If using Cilium CNI, enable Hubble for network flows:

```bash
# Enable Hubble with OTLP export
cilium hubble enable --ui

# Configure Hubble to export to collector
# Flows will be received on port 4319
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `LAST9_OTLP_ENDPOINT` | Yes | Last9 OTLP endpoint URL |
| `LAST9_AUTH_TOKEN` | Yes | Authorization token (Basic auth) |
| `LAST9_METRICS_ENDPOINT` | No | Prometheus remote write URL |
| `LAST9_METRICS_USERNAME` | No | Metrics auth username |
| `LAST9_METRICS_PASSWORD` | No | Metrics auth password |
| `CLUSTER_NAME` | No | Override cluster name |
| `DEPLOYMENT_ENVIRONMENT` | No | Environment label (default: production) |

## Verification

```bash
# Check all pods
kubectl get pods -n last9

# Check node agent logs
kubectl logs -n last9 -l app.kubernetes.io/name=last9-otel-collector --tail=50

# Check cluster agent logs
kubectl logs -n last9 -l app.kubernetes.io/name=last9-cluster-agent --tail=50

# Verify instrumentation
kubectl get instrumentation -n last9
```

## Uninstall

```bash
# Remove cluster agent
helm uninstall last9-cluster -n last9

# Remove node agent
helm uninstall last9-collector -n last9

# Remove instrumentation
kubectl delete -f instrumentation.yaml

# Remove operator
helm uninstall opentelemetry-operator -n last9
```

## Troubleshooting

### Logs not appearing

1. Check filelog receiver is enabled: `kubectl logs -n last9 <pod> | grep filelog`
2. Verify RBAC: `kubectl auth can-i list pods -n last9 --as=system:serviceaccount:last9:last9-otel-collector`

### Traces not correlated with logs

1. Ensure `OTEL_LOGS_EXPORTER=otlp` in instrumentation.yaml
2. Check SDK version supports log bridge
3. Verify logs are JSON formatted with trace context

### Duplicate events

Ensure only ONE cluster agent is running:
```bash
kubectl get pods -n last9 -l app.kubernetes.io/name=last9-cluster-agent
# Should show exactly 1 pod
```

## Documentation

- [SPEC.md](./SPEC.md) - Full specification and architecture decisions
- [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)
- [OTel Operator](https://github.com/open-telemetry/opentelemetry-operator)
