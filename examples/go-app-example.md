# Go Application Auto-Instrumentation Example

This example demonstrates how to enable eBPF-based automatic instrumentation for Go applications using the Last9 Operator.

## 🎯 Overview

Unlike Java, Python, and Node.js which use bytecode instrumentation, Go uses **eBPF (Extended Berkeley Packet Filter)** for zero-code instrumentation. This approach:

- ✅ Requires **no code changes** to your Go application
- ✅ Works with **any compiled Go binary** (Go 1.17+)
- ✅ Automatically traces **HTTP, database/sql, gRPC, and Kafka**
- ⚠️ Requires **Linux kernel 4.4+** and **privileged access**
- ⚠️ Only works in **Kubernetes** environments

## 📋 Prerequisites

1. **Last9 Operator installed** (run `./last9-otel-setup.sh`)
2. **Go application compiled** with Go 1.17 or later
3. **Kubernetes cluster** running Linux nodes

## 🚀 Quick Start

### Step 1: Add Annotation to Your Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-go-app
spec:
  template:
    metadata:
      annotations:
        # This single annotation enables auto-instrumentation!
        instrumentation.opentelemetry.io/inject-go: "true"
    spec:
      # Required for eBPF
      shareProcessNamespace: true
      containers:
      - name: my-go-app
        image: my-go-app:latest
        env:
        # Required: Path to your Go binary inside the container
        - name: OTEL_GO_AUTO_TARGET_EXE
          value: "/app/main"  # Adjust to your binary path
        # Optional: Override service name
        - name: OTEL_SERVICE_NAME
          value: "my-go-service"
```

### Step 2: Deploy

```bash
kubectl apply -f your-deployment.yaml
```

### Step 3: Verify Instrumentation

Check that the sidecar was injected:

```bash
kubectl get pods
# You should see 2/2 containers (your app + instrumentation sidecar)

kubectl describe pod <your-pod-name>
# Look for "opentelemetry-auto-instrumentation-go" container
```

View traces in Last9:
```bash
# Generate some traffic
curl http://your-go-app/api/endpoint

# Check Last9 dashboard for traces
```

## 📝 Complete Example

See [`../deploy-go.yaml`](../deploy-go.yaml) for a full working example.

## 🎛️ Configuration Options

### Required Environment Variables

| Variable | Purpose | Example |
|----------|---------|---------|
| `OTEL_GO_AUTO_TARGET_EXE` | Path to Go binary | `/app/main` |

### Optional Environment Variables

| Variable | Purpose | Default | Example |
|----------|---------|---------|---------|
| `OTEL_SERVICE_NAME` | Service identifier | Binary name | `user-service` |
| `OTEL_RESOURCE_ATTRIBUTES` | Additional attributes | `deployment.environment=local` | `team=backend,version=1.0` |
| `OTEL_GO_AUTO_INCLUDE_DB_STATEMENT` | Include SQL in spans | `false` | `true` |

### Example with All Options

```yaml
env:
- name: OTEL_GO_AUTO_TARGET_EXE
  value: "/usr/local/bin/myapp"
- name: OTEL_SERVICE_NAME
  value: "payment-service"
- name: OTEL_RESOURCE_ATTRIBUTES
  value: "deployment.environment=production,team=payments,version=v2.1.0"
- name: OTEL_GO_AUTO_INCLUDE_DB_STATEMENT
  value: "true"
```

## 🔍 What Gets Instrumented Automatically?

The eBPF agent automatically captures:

### HTTP Servers
- ✅ **net/http** - Standard library HTTP servers
- ✅ **gin-gonic/gin** - Gin framework
- ✅ **gorilla/mux** - Gorilla Mux
- ✅ **labstack/echo** - Echo framework
- ✅ **go-chi/chi** - Chi router

### Databases
- ✅ **database/sql** - Standard SQL interface (PostgreSQL, MySQL, SQLite)
- ✅ **Query execution time**
- ✅ **Rows affected**
- ⚠️ SQL statements (opt-in via `OTEL_GO_AUTO_INCLUDE_DB_STATEMENT`)

### gRPC
- ✅ **google.golang.org/grpc** - gRPC servers and clients

### Kafka
- ✅ **github.com/segmentio/kafka-go** - Kafka producers and consumers

## ⚖️ SDK vs eBPF: When to Use Each

### Use **eBPF Auto-Instrumentation** (this method) when:
- ✅ Running in Kubernetes
- ✅ Want zero code changes
- ✅ Standardizing across many services
- ✅ Don't need custom spans
- ✅ Security team approves privileged containers

### Use **Last9 Go SDK** ([github.com/last9/go-agent](https://github.com/last9/go-agent)) when:
- ✅ Running on VMs, Lambda, or bare metal
- ✅ Need custom business logic spans
- ✅ Want fine-grained control
- ✅ Developing locally (no K8s)
- ✅ Privileged access not allowed

### Use **Both** when:
- ✅ eBPF for base framework tracing (HTTP, DB, gRPC)
- ✅ SDK for custom spans in business logic
- ✅ Best of both worlds!

## 🔧 Troubleshooting

### Pod Shows 1/2 Containers Ready

**Problem:** Instrumentation sidecar failed to inject

**Solution:**
```bash
# Check operator logs
kubectl logs -n last9 deployment/opentelemetry-operator-controller-manager

# Verify instrumentation object exists
kubectl get instrumentation -n last9

# Check pod events
kubectl describe pod <your-pod-name>
```

### No Traces Appearing in Last9

**Check 1:** Verify OTEL_GO_AUTO_TARGET_EXE is correct
```bash
# Exec into your pod and check binary path
kubectl exec -it <pod-name> -- sh
ls -la /app/main  # Should exist
```

**Check 2:** Verify Go version compatibility
```bash
# Your binary must be compiled with Go 1.17+
# Check your Dockerfile/build process
```

**Check 3:** Check sidecar logs
```bash
kubectl logs <pod-name> -c opentelemetry-auto-instrumentation-go
```

### Permission Denied Errors

**Problem:** eBPF requires elevated privileges

**Solution:** Ensure `shareProcessNamespace: true` is set in your pod spec.

## 🆚 Comparison with Manual SDK

### Code Required

**eBPF (This Method):**
```yaml
# Just annotation - no code changes!
annotations:
  instrumentation.opentelemetry.io/inject-go: "true"
```

**SDK Method:**
```go
// Requires code changes
import "github.com/last9/go-agent"

func main() {
    agent.Start()
    defer agent.Shutdown()
    // ...
}
```

### Coverage

| Aspect | eBPF | SDK |
|--------|------|-----|
| HTTP frameworks | ✅ Auto | ✅ Auto (with wrappers) |
| database/sql | ✅ Auto | ✅ Auto (with helper) |
| Redis | ✅ Auto | ✅ Auto (with helper) |
| Custom spans | ❌ No | ✅ Yes |
| 3rd-party libs | ✅ Yes | ❌ Only if wrapped |
| Environment | K8s only | Anywhere |
| Privileges | Root/eBPF | None |

## 📚 Learn More

- **SDK Approach:** https://github.com/last9/go-agent
- **OpenTelemetry Go eBPF:** https://opentelemetry.io/docs/zero-code/go/autosdk/
- **Last9 Docs:** https://last9.io/docs/integrations/containers-and-k8s/kubernetes-operator/

## 🐛 Reporting Issues

If you encounter issues with Go auto-instrumentation:

1. Check [Troubleshooting](#troubleshooting) section above
2. Review [OpenTelemetry Go issues](https://github.com/open-telemetry/opentelemetry-go-instrumentation/issues)
3. Open issue at [Last9 Operator repo](https://github.com/last9/last9-k8s-observability-installer/issues)

Include:
- Go version (`go version`)
- Kubernetes version (`kubectl version`)
- Kernel version (`uname -r`)
- Pod describe output
- Sidecar logs
