# Go eBPF Auto-Instrumentation

This directory contains documentation and reference materials for Go eBPF-based auto-instrumentation using the OpenTelemetry Operator.

## Overview

Go auto-instrumentation uses **eBPF (Extended Berkeley Packet Filter)** to instrument compiled Go binaries without code changes. Unlike bytecode instrumentation used for Java/Python/Node.js, eBPF operates at the kernel level.

```
┌─────────────────────────────────────────────────────────┐
│                    Kubernetes Pod                       │
│  ┌─────────────────┐    ┌─────────────────────────┐    │
│  │   Go App        │    │  eBPF Instrumentation   │    │
│  │   Container     │◄───│  Sidecar Container      │    │
│  │                 │    │                         │    │
│  │  ┌───────────┐  │    │  - Hooks into kernel    │    │
│  │  │ Go Binary │  │    │  - Traces HTTP/DB/gRPC  │    │
│  │  └───────────┘  │    │  - Exports to OTel      │    │
│  └─────────────────┘    └─────────────────────────┘    │
│          ▲                         │                    │
│          └─────────────────────────┘                    │
│            shareProcessNamespace: true                  │
└─────────────────────────────────────────────────────────┘
```

## Requirements

| Requirement | Minimum Version | Notes |
|-------------|-----------------|-------|
| **Linux Kernel** | 4.4+ | eBPF support required |
| **Go Version** | 1.17+ | Compile-time requirement |
| **Kubernetes** | 1.19+ | For operator support |
| **Container Runtime** | Any | Docker, containerd, CRI-O |

### Kernel Feature Check

Verify your nodes support eBPF:

```bash
# Check kernel version
kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.kernelVersion}'

# Should be 4.4+ (ideally 5.x for best support)
```

## Compatibility Matrix

| Go Version | eBPF Support | OTel Go Instrumentation Version |
|------------|--------------|--------------------------------|
| 1.17.x | Supported | v0.2.0+ |
| 1.18.x | Supported | v0.2.0+ |
| 1.19.x | Supported | v0.3.0+ |
| 1.20.x | Supported | v0.4.0+ |
| 1.21.x | Supported | v0.6.0+ |
| 1.22.x+ | Supported | v0.7.0+ (latest recommended) |

## Automatic Instrumentation Coverage

### Supported Libraries

| Library | Package | Coverage |
|---------|---------|----------|
| **HTTP Server** | `net/http` | Incoming requests, status codes, latency |
| **Gin** | `github.com/gin-gonic/gin` | Routes, middleware, handlers |
| **Echo** | `github.com/labstack/echo` | Routes, middleware |
| **Chi** | `github.com/go-chi/chi` | Router patterns |
| **Gorilla Mux** | `github.com/gorilla/mux` | Route matching |
| **gRPC** | `google.golang.org/grpc` | Server/client calls, metadata |
| **database/sql** | `database/sql` | Query execution, connection pooling |
| **Kafka** | `github.com/segmentio/kafka-go` | Produce/consume operations |

### What Gets Captured

```
HTTP Request Trace Example:
├── http.method: GET
├── http.url: /api/users/123
├── http.status_code: 200
├── http.request_content_length: 0
├── http.response_content_length: 256
└── duration: 45ms

Database Span Example:
├── db.system: postgresql
├── db.name: users_db
├── db.operation: SELECT
├── db.statement: SELECT * FROM users WHERE id = ? (opt-in)
└── duration: 12ms

gRPC Span Example:
├── rpc.system: grpc
├── rpc.service: UserService
├── rpc.method: GetUser
├── rpc.grpc.status_code: 0 (OK)
└── duration: 23ms
```

## Configuration

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `OTEL_GO_AUTO_TARGET_EXE` | **Yes** | - | Absolute path to Go binary in container |
| `OTEL_SERVICE_NAME` | No | Binary name | Service identifier in traces |
| `OTEL_RESOURCE_ATTRIBUTES` | No | - | Additional resource attributes |
| `OTEL_GO_AUTO_INCLUDE_DB_STATEMENT` | No | `false` | Include SQL in db.statement |
| `OTEL_GO_AUTO_GLOBAL` | No | `false` | Register global TracerProvider |
| `OTEL_GO_AUTO_SHOW_VERIFIER_LOG` | No | `false` | Show eBPF verifier logs (debug) |
| `OTEL_TRACES_SAMPLER` | No | `parentbased_always_on` | Sampling strategy |
| `OTEL_TRACES_SAMPLER_ARG` | No | - | Sampler argument (e.g., ratio) |

### Sampling Configuration

```yaml
env:
# Always sample (development)
- name: OTEL_TRACES_SAMPLER
  value: "always_on"

# OR: Sample 10% of traces (production)
- name: OTEL_TRACES_SAMPLER
  value: "traceidratio"
- name: OTEL_TRACES_SAMPLER_ARG
  value: "0.1"

# OR: Parent-based with ratio (recommended for production)
- name: OTEL_TRACES_SAMPLER
  value: "parentbased_traceidratio"
- name: OTEL_TRACES_SAMPLER_ARG
  value: "0.1"
```

## Deployment Examples

### Basic Deployment

**IMPORTANT**: The binary path MUST be specified via annotation, not just environment variable.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-go-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-go-app
  template:
    metadata:
      labels:
        app: my-go-app
      annotations:
        # Enable Go eBPF auto-instrumentation
        instrumentation.opentelemetry.io/inject-go: "true"
        # REQUIRED: Path to Go binary (must be annotation!)
        instrumentation.opentelemetry.io/otel-go-auto-target-exe: "/app/server"
    spec:
      shareProcessNamespace: true  # Required for eBPF
      containers:
      - name: app
        image: my-go-app:v1.0.0
```

### Production Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-service
spec:
  replicas: 3
  selector:
    matchLabels:
      app: payment-service
  template:
    metadata:
      labels:
        app: payment-service
      annotations:
        instrumentation.opentelemetry.io/inject-go: "true"
        # REQUIRED: Binary path via annotation
        instrumentation.opentelemetry.io/otel-go-auto-target-exe: "/usr/local/bin/payment"
    spec:
      shareProcessNamespace: true
      containers:
      - name: app
        image: payment-service:v2.1.0
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        env:
        - name: OTEL_SERVICE_NAME
          value: "payment-service"
        - name: OTEL_RESOURCE_ATTRIBUTES
          value: "deployment.environment=production,service.version=2.1.0,team=payments"
```

### Multi-Binary Container

If your container has multiple Go binaries, instrument the main one:

```yaml
env:
- name: OTEL_GO_AUTO_TARGET_EXE
  value: "/app/main-server"  # Only this binary is instrumented
```

## Cloud Provider Setup

### Amazon EKS

EKS nodes generally support eBPF out of the box. Verify:

```bash
# Check node kernel version
kubectl get nodes -o wide

# EKS optimized AMI uses kernel 5.x by default
```

**EKS-specific considerations:**
- Fargate: eBPF is **not supported** (no access to host kernel)
- Managed nodes: Fully supported
- Bottlerocket: Fully supported with kernel 5.10+

### Google GKE

GKE supports eBPF on most node images:

```bash
# Recommended: Use Container-Optimized OS (COS)
gcloud container clusters create my-cluster \
  --image-type=COS_CONTAINERD
```

**GKE-specific considerations:**
- GKE Autopilot: eBPF is supported but with some restrictions
- GKE Standard: Fully supported
- Anthos: Fully supported

### Azure AKS

AKS supports eBPF on Ubuntu-based node pools:

```bash
# Use Ubuntu node image (default)
az aks create --name my-cluster \
  --node-vm-size Standard_DS2_v2
```

**AKS-specific considerations:**
- Ubuntu nodes: Fully supported (kernel 5.4+)
- Windows nodes: Not supported (Linux only)
- Azure CNI with eBPF: Compatible

## Troubleshooting

### Common Issues

#### 1. Sidecar Not Injecting

**Symptoms:** Pod shows 1/1 instead of 2/2 containers

**Debug:**
```bash
# Check instrumentation object
kubectl get instrumentation -n last9 -o yaml

# Check operator logs
kubectl logs -n last9 -l app.kubernetes.io/name=opentelemetry-operator

# Check mutating webhook
kubectl get mutatingwebhookconfigurations | grep opentelemetry
```

**Solutions:**
- Ensure `instrumentation.opentelemetry.io/inject-go: "true"` annotation is on pod spec, not deployment
- Verify namespace has instrumentation object or use cross-namespace injection

#### 2. No Traces Appearing

**Symptoms:** Sidecar runs but no traces in Last9

**Debug:**
```bash
# Check sidecar logs
kubectl logs <pod> -c opentelemetry-auto-instrumentation-go

# Verify binary path
kubectl exec <pod> -c app -- ls -la /app/server

# Check environment
kubectl exec <pod> -c app -- env | grep OTEL
```

**Solutions:**
- Verify `OTEL_GO_AUTO_TARGET_EXE` matches actual binary path
- Ensure binary was compiled with Go 1.17+
- Check binary wasn't stripped (`-ldflags "-s -w"` is OK, but avoid `-trimpath` issues)

#### 3. Permission Denied / eBPF Errors

**Symptoms:** Sidecar crashes with permission errors

**Debug:**
```bash
# Check sidecar logs for eBPF errors
kubectl logs <pod> -c opentelemetry-auto-instrumentation-go 2>&1 | grep -i "ebpf\|permission\|capability"

# Verify shareProcessNamespace
kubectl get pod <pod> -o jsonpath='{.spec.shareProcessNamespace}'
# Should return: true
```

**Solutions:**
- Add `shareProcessNamespace: true` to pod spec
- Check if PodSecurityPolicy/PodSecurity restricts capabilities
- Some environments require explicit capability grants:

```yaml
securityContext:
  capabilities:
    add:
    - SYS_PTRACE
```

#### 4. High Memory Usage

**Symptoms:** Instrumentation sidecar using excessive memory

**Debug:**
```bash
kubectl top pod <pod> --containers
```

**Solutions:**
- eBPF maps have fixed memory overhead (~50-100MB)
- For memory-constrained environments, consider SDK instead
- Adjust resource limits:

```yaml
# In Instrumentation CRD
spec:
  go:
    resources:
      limits:
        memory: "128Mi"
        cpu: "200m"
```

### eBPF Verifier Errors

If you see verifier errors, enable debug logging:

```yaml
env:
- name: OTEL_GO_AUTO_SHOW_VERIFIER_LOG
  value: "true"
```

Common causes:
- Kernel version too old (need 4.4+, prefer 5.x)
- BTF (BPF Type Format) not available
- Missing kernel headers on node

## Performance Impact

### Overhead Benchmarks

| Metric | Without eBPF | With eBPF | Overhead |
|--------|--------------|-----------|----------|
| HTTP latency (p50) | 2ms | 2.1ms | ~5% |
| HTTP latency (p99) | 8ms | 8.5ms | ~6% |
| Memory | 50MB | 100MB | +50MB |
| CPU | 10% | 12% | +2% |

*Benchmarks performed on Go 1.21 HTTP server with net/http*

### Optimization Tips

1. **Use sampling in production** - Reduce trace volume with `OTEL_TRACES_SAMPLER`
2. **Limit DB statement capture** - Keep `OTEL_GO_AUTO_INCLUDE_DB_STATEMENT=false`
3. **Right-size resources** - eBPF has baseline memory requirements

## Comparison: eBPF vs SDK

| Aspect | eBPF Auto-Instrumentation | OpenTelemetry Go SDK |
|--------|---------------------------|---------------------|
| **Code changes** | None | Import + init code |
| **Custom spans** | Not supported | Fully supported |
| **Environment** | Kubernetes only | Anywhere |
| **Privileges** | Requires elevated | None |
| **Coverage** | Standard libraries | Standard + custom |
| **Performance** | Minimal overhead | Minimal overhead |
| **Deployment** | Annotation + operator | Code + build |

### When to Use eBPF

- Standardizing observability across many services
- Services without dedicated observability budget
- Polyglot environments (Java + Go + Python)
- Quick wins without code changes

### When to Use SDK

- Need custom business spans
- Running outside Kubernetes
- Strict security requirements (no elevated privileges)
- Need baggage propagation

### Hybrid Approach

You can use both! eBPF provides base coverage, SDK adds custom spans:

```go
import "go.opentelemetry.io/otel"

func processOrder(ctx context.Context, order Order) {
    // eBPF auto-instruments the HTTP handler
    // SDK adds custom business span
    _, span := otel.Tracer("orders").Start(ctx, "process-order")
    defer span.End()

    span.SetAttributes(
        attribute.String("order.id", order.ID),
        attribute.Float64("order.total", order.Total),
    )
    // ...
}
```

## Resources

- [OpenTelemetry Go Auto-Instrumentation](https://github.com/open-telemetry/opentelemetry-go-instrumentation)
- [OpenTelemetry Operator](https://github.com/open-telemetry/opentelemetry-operator)
- [eBPF Documentation](https://ebpf.io/what-is-ebpf/)
- [Last9 Go Integration](https://last9.io/docs/integrations/languages/go/)

## Contributing

Found an issue? Please open an issue or PR at the [Last9 Operator repository](https://github.com/last9/last9-k8s-observability-installer/issues).
