# Examples

This directory contains examples for deploying and configuring the Last9 observability stack.

## Language-Specific Auto-Instrumentation Examples

| Language | Instrumentation Type | Guide |
|----------|---------------------|-------|
| **Go** | eBPF (zero-code) | [go-app-example.md](go-app-example.md) |
| **Node.js** | Bytecode injection | See main README |
| **Node.js (Legacy)** | Legacy versions (10, 12) | [nodejs-legacy-versions.md](nodejs-legacy-versions.md) |
| **Java** | Bytecode injection | See main README |
| **Python** | Library injection | See main README |

### Go eBPF Auto-Instrumentation

Go uses **eBPF** for zero-code instrumentation. This requires:
- Linux kernel 4.4+ (5.x recommended)
- Go 1.17+ compiled binary
- `shareProcessNamespace: true` in pod spec
- `OTEL_GO_AUTO_TARGET_EXE` environment variable

**Quick start:**
```yaml
annotations:
  instrumentation.opentelemetry.io/inject-go: "true"
spec:
  shareProcessNamespace: true
  containers:
  - name: app
    env:
    - name: OTEL_GO_AUTO_TARGET_EXE
      value: "/app/server"
```

See [go-app-example.md](go-app-example.md) for complete documentation and [autoinstrumentation/go/](../autoinstrumentation/go/) for advanced configuration.

---

# Tolerations Examples

This section contains example tolerations configurations for deploying the Last9 observability stack on nodes with specific taints.

## What are Tolerations?

In Kubernetes, **taints** prevent pods from being scheduled on certain nodes unless the pods have matching **tolerations**. This is useful for:
- Dedicating nodes to specific workloads
- Isolating control-plane/master nodes
- Managing spot/preemptible instances
- Creating dedicated monitoring nodes

## Available Examples

### 1. `tolerations-all-nodes.yaml`

**Use Case:** Deploy monitoring on ALL nodes, including control-plane/master nodes

**Description:** This configuration allows the observability stack to run on every node in the cluster, including control-plane (master) nodes that are typically tainted.

**Usage:**
```bash
./last9-otel-setup.sh \
  tolerations-file=examples/tolerations-all-nodes.yaml \
  token="..." \
  endpoint="..." \
  monitoring-endpoint="..." \
  username="..." \
  password="..."
```

**When to use:**
- You want complete cluster coverage
- You need to monitor control-plane node metrics
- You have a small cluster where every node counts

**Tolerations included:**
- `node-role.kubernetes.io/control-plane:NoSchedule`
- `node-role.kubernetes.io/master:NoSchedule`

---

### 2. `tolerations-monitoring-nodes.yaml`

**Use Case:** Deploy only on dedicated monitoring nodes

**Description:** Runs the observability stack exclusively on nodes labeled with `workload=monitoring`.

**Usage:**
```bash
./last9-otel-setup.sh \
  tolerations-file=examples/tolerations-monitoring-nodes.yaml \
  token="..." \
  endpoint="..." \
  monitoring-endpoint="..." \
  username="..." \
  password="..."
```

**When to use:**
- You have dedicated monitoring infrastructure
- You want to isolate observability workloads
- You need predictable resource allocation

**Node labeling required:**
```bash
# Label your monitoring nodes
kubectl label node <node-name> workload=monitoring
kubectl taint node <node-name> workload=monitoring:NoSchedule
```

---

### 3. `tolerations-spot-instances.yaml`

**Use Case:** Run on spot/preemptible instances

**Description:** Allows deployment on cost-effective spot instances that may be terminated at any time.

**Usage:**
```bash
./last9-otel-setup.sh \
  tolerations-file=examples/tolerations-spot-instances.yaml \
  token="..." \
  endpoint="..." \
  monitoring-endpoint="..." \
  username="..." \
  password="..."
```

**When to use:**
- Cost optimization is important
- You can tolerate occasional pod restarts
- Your cluster uses spot/preemptible nodes

**Tolerations included:**
- `node.kubernetes.io/instance-type:PreferNoSchedule` (spot instances)
- `scheduling.k8s.io/spot:NoSchedule`
- Fallback to regular nodes if no spot nodes available

**Cloud provider labels:**
- AWS: `eks.amazonaws.com/capacityType=SPOT`
- GCP: `cloud.google.com/gke-preemptible=true`
- Azure: `kubernetes.azure.com/scalesetpriority=spot`

---

### 4. `tolerations-multi-taint.yaml`

**Use Case:** Handle multiple taints simultaneously

**Description:** Comprehensive configuration for complex clusters with multiple types of tainted nodes.

**Usage:**
```bash
./last9-otel-setup.sh \
  tolerations-file=examples/tolerations-multi-taint.yaml \
  token="..." \
  endpoint="..." \
  monitoring-endpoint="..." \
  username="..." \
  password="..."
```

**When to use:**
- Mixed workload clusters
- Multiple node types (control-plane, spot, dedicated)
- Need maximum flexibility

**Tolerations included:**
- Control-plane taints
- Custom environment taints
- Spot instance taints
- Monitoring node taints

---

### 5. `tolerations-nodeSelector-only.yaml`

**Use Case:** Use node selectors without tolerations

**Description:** Deploys on specific nodes using labels only, without requiring tolerations.

**Usage:**
```bash
./last9-otel-setup.sh \
  tolerations-file=examples/tolerations-nodeSelector-only.yaml \
  token="..." \
  endpoint="..." \
  monitoring-endpoint="..." \
  username="..." \
  password="..."
```

**When to use:**
- Nodes are labeled but not tainted
- Simple node selection based on labels
- No special permissions needed

**Node labeling required:**
```bash
kubectl label node <node-name> monitoring=enabled
```

---

### 6. `tolerations-no-selector.yaml`

**Use Case:** Tolerate specific taints but run anywhere

**Description:** Allows pods to run on tainted nodes but doesn't restrict them to specific nodes.

**Usage:**
```bash
./last9-otel-setup.sh \
  tolerations-file=examples/tolerations-no-selector.yaml \
  token="..." \
  endpoint="..." \
  monitoring-endpoint="..." \
  username="..." \
  password="..."
```

**When to use:**
- You want flexibility in scheduling
- Need to tolerate specific taints but no node preference
- Dynamic node pools

---

## Creating Custom Tolerations

To create your own tolerations file:

1. **Identify node taints:**
   ```bash
   kubectl get nodes -o json | jq '.items[].spec.taints'
   ```

2. **Create a YAML file:**
   ```yaml
   tolerations:
     - key: "your-taint-key"
       operator: "Equal"  # or "Exists"
       value: "your-taint-value"
       effect: "NoSchedule"  # or "NoExecute" or "PreferNoSchedule"

   nodeSelector:
     your-label-key: "your-label-value"

   nodeExporterTolerations:
     - operator: "Exists"  # node-exporter should run on all nodes
   ```

3. **Test your configuration:**
   ```bash
   ./last9-otel-setup.sh \
     tolerations-file=path/to/your-tolerations.yaml \
     token="..." \
     endpoint="..."
   ```

4. **Verify deployment:**
   ```bash
   # Check which nodes pods are running on
   kubectl get pods -n last9 -o wide
   ```

---

## Understanding Toleration Effects

| Effect | Description | Use Case |
|--------|-------------|----------|
| **NoSchedule** | New pods won't be scheduled unless they tolerate the taint | Standard workload isolation |
| **PreferNoSchedule** | Scheduler tries to avoid scheduling, but not required | Soft preferences |
| **NoExecute** | Existing pods are evicted if they don't tolerate | Strong isolation requirements |

## Understanding Toleration Operators

| Operator | Description | Example |
|----------|-------------|---------|
| **Equal** | Key and value must match exactly | `key=value:NoSchedule` |
| **Exists** | Only key needs to exist (any value) | `key:NoSchedule` (any value) |

---

## Common Taint Keys

| Taint Key | Description | Used By |
|-----------|-------------|---------|
| `node-role.kubernetes.io/control-plane` | Control plane nodes (k8s 1.24+) | Kubernetes |
| `node-role.kubernetes.io/master` | Master nodes (k8s <1.24) | Kubernetes |
| `node.kubernetes.io/not-ready` | Node is not ready | Kubernetes |
| `node.kubernetes.io/unreachable` | Node is unreachable | Kubernetes |
| `scheduling.k8s.io/spot` | Spot/preemptible instance | Cloud providers |
| `workload=<value>` | Custom workload isolation | User-defined |

---

## Troubleshooting

### Pods stuck in Pending state

```bash
# Check why pods aren't scheduling
kubectl describe pod <pod-name> -n last9

# Look for events like:
# "0/3 nodes are available: 3 node(s) had taint {key: value}, that the pod didn't tolerate"
```

**Solution:** Update your tolerations file to include the taint mentioned in the error.

### Pods only on some nodes

```bash
# Check node taints
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints

# Verify your nodeSelector matches
kubectl get nodes --show-labels
```

**Solution:** Adjust `nodeSelector` to match available node labels or use a less restrictive configuration.

### node-exporter not on all nodes

The `nodeExporterTolerations` section is specifically for the node-exporter DaemonSet, which typically needs to run on ALL nodes. Use:

```yaml
nodeExporterTolerations:
  - operator: "Exists"  # Tolerate all taints
```

---

## Best Practices

1. **Start permissive**: Use `tolerations-all-nodes.yaml` first to ensure everything works
2. **Then restrict**: Move to more specific configurations as needed
3. **Test thoroughly**: Verify pods are scheduled as expected
4. **Document custom taints**: Keep track of custom taints in your cluster
5. **Use consistent labels**: Standardize node labeling across your infrastructure

---

## Need Help?

- 📖 [Kubernetes Taints and Tolerations Documentation](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/)
- 💬 [Last9 Community Slack](https://last9.io/slack)
- 🐛 [Report Issues](https://github.com/last9/last9-k8s-observability-installer/issues)

---

<p align="center">
  Made with ❤️ by <a href="https://last9.io">Last9</a>
</p>
