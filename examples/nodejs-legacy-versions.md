# Node.js 10/12 Auto-Instrumentation Example

This guide demonstrates how to enable automatic OpenTelemetry instrumentation for legacy Node.js applications (versions 10 and 12) using Last9's custom instrumentation images.

## 🎯 Overview

**Problem**: Current OpenTelemetry releases (v1.0+) only support Node.js 14+
**Solution**: Use Last9's custom images with compatible OpenTelemetry versions
**Result**: Zero-code instrumentation for legacy Node.js applications

## ⚠️ Important Notes

- **Node 10** reached End-of-Life in April 2021 - **Security Risk**
- **Node 12** reached End-of-Life in April 2022 - **Security Risk**
- These images should only be used during **migration periods**
- **Plan to upgrade** to Node 18+ or 20+ as soon as possible

## 📋 Prerequisites

1. Kubernetes cluster with Last9 operator installed
2. Legacy Node.js application (10.x or 12.x)
3. Last9 account with OTLP endpoint and credentials

## 🚀 Quick Start

### Step 1: Create Custom Instrumentation Resource

Create a separate `Instrumentation` resource for your legacy Node.js application:

```yaml
# instrumentation-node12.yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: l9-instrumentation-node12
  namespace: default
spec:
  propagators:
    - tracecontext
    - baggage
    - b3

  sampler:
    type: parentbased_traceidratio
    argument: "1.0"

  nodejs:
    # Specify the Node 12 image (or node10 for Node 10.x)
    image: ghcr.io/last9/autoinstrumentation-nodejs:node12

    env:
    # Last9 Configuration
    - name: OTEL_EXPORTER_OTLP_ENDPOINT
      value: "https://otlp.last9.io"

    - name: OTEL_EXPORTER_OTLP_HEADERS
      value: "Authorization=Basic YOUR_LAST9_TOKEN_HERE"

    # Protocol and Performance
    - name: OTEL_EXPORTER_OTLP_PROTOCOL
      value: "http/protobuf"

    - name: OTEL_BSP_MAX_EXPORT_BATCH_SIZE
      value: "512"

    - name: OTEL_BSP_EXPORT_TIMEOUT
      value: "2s"

    - name: OTEL_BSP_SCHEDULE_DELAY
      value: "1s"

    - name: OTEL_EXPORTER_OTLP_COMPRESSION
      value: "gzip"

    - name: OTEL_EXPORTER_OTLP_TIMEOUT
      value: "10s"

    # Disable metrics and logs (traces only)
    - name: OTEL_METRICS_EXPORTER
      value: "none"

    - name: OTEL_LOGS_EXPORTER
      value: "none"

    # Resource attributes
    - name: OTEL_RESOURCE_ATTRIBUTES
      value: "deployment.environment=production,node.version=12"
```

Apply the instrumentation:

```bash
kubectl apply -f instrumentation-node12.yaml
```

### Step 2: Annotate Your Deployment

Add the instrumentation annotation to your Node 12 application deployment:

```yaml
# deployment-node12-app.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-node12-app
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: my-node12-app
  template:
    metadata:
      labels:
        app: my-node12-app
      annotations:
        # Enable auto-instrumentation
        instrumentation.opentelemetry.io/inject-nodejs: "true"

        # Optional: Use specific instrumentation (if you have multiple)
        instrumentation.opentelemetry.io/instrumentation: "l9-instrumentation-node12"

    spec:
      containers:
      - name: app
        image: my-registry/my-node12-app:latest
        ports:
        - containerPort: 3000
          name: http

        env:
        # Your application environment variables
        - name: PORT
          value: "3000"

        # Optional: Override service name
        - name: OTEL_SERVICE_NAME
          value: "legacy-api"

        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "512Mi"
            cpu: "500m"

---
apiVersion: v1
kind: Service
metadata:
  name: my-node12-app-service
  namespace: default
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 3000
    protocol: TCP
  selector:
    app: my-node12-app
```

Apply the deployment:

```bash
kubectl apply -f deployment-node12-app.yaml
```

### Step 3: Verify Instrumentation

**Check pod status:**

```bash
kubectl get pods -l app=my-node12-app

# Should show READY 2/2 (app + init container)
```

**Describe pod to see injected volumes:**

```bash
kubectl describe pod <pod-name>

# Look for:
# - Init container: opentelemetry-auto-instrumentation
# - Volume: opentelemetry-auto-instrumentation
# - Environment: NODE_OPTIONS with --require
```

**Check application logs:**

```bash
kubectl logs -l app=my-node12-app -c app

# Should show OpenTelemetry initialization messages
```

**View init container logs:**

```bash
kubectl logs <pod-name> -c opentelemetry-auto-instrumentation

# Should show successful copy of instrumentation files
```

### Step 4: Generate Traffic and View Traces

```bash
# Port-forward to the service
kubectl port-forward service/my-node12-app-service 8080:80

# Generate some requests
for i in {1..20}; do
  curl http://localhost:8080/
  sleep 1
done
```

**Check Last9 Dashboard:**
1. Navigate to your Last9 APM
2. Find service: `legacy-api` (or your OTEL_SERVICE_NAME)
3. View traces with automatic instrumentation for:
   - HTTP requests (Express, Fastify, etc.)
   - Database queries (PostgreSQL, MySQL, MongoDB)
   - Redis commands
   - External HTTP calls

## 📦 Complete Example Application

Here's a simple Express app that works with Node 12:

```javascript
// app.js
// NO OpenTelemetry imports needed - handled by operator!

const express = require('express');
const app = express();
const port = process.env.PORT || 3000;

app.get('/', (req, res) => {
  res.json({ message: 'Hello from Node 12!', version: process.version });
});

app.get('/health', (req, res) => {
  res.json({ status: 'healthy', node: process.version });
});

app.listen(port, () => {
  console.log(`Server running on port ${port}`);
  console.log(`Node version: ${process.version}`);
});
```

```dockerfile
# Dockerfile
FROM node:12-alpine

WORKDIR /app

COPY package*.json ./
RUN npm ci --production

COPY . .

EXPOSE 3000

CMD ["node", "app.js"]
```

```json
// package.json
{
  "name": "my-node12-app",
  "version": "1.0.0",
  "description": "Legacy Node 12 application",
  "main": "app.js",
  "engines": {
    "node": "12.x"
  },
  "dependencies": {
    "express": "^4.17.1"
  }
}
```

## 🆚 Node 10 vs Node 12

### For Node 10.x Applications

Change the image in your Instrumentation resource:

```yaml
nodejs:
  image: ghcr.io/last9/autoinstrumentation-nodejs:node10
```

### Compatibility Matrix

| Node Version | Image Tag | OpenTelemetry Version | Status |
|--------------|-----------|----------------------|--------|
| 10.x | `node10` | 0.25.0 | ⚠️ High Risk - EOL 2021 |
| 12.x | `node12` | 0.27.0 | ⚠️ Risk - EOL 2022 |
| 14.x+ | `latest` or default | Current | ✅ Supported |

## 🐛 Troubleshooting

### Problem: Pod Shows 1/1 Instead of 2/2

**Cause**: Init container failed to inject instrumentation

**Solution**:
```bash
# Check operator logs
kubectl logs -n last9 deployment/opentelemetry-operator-controller-manager

# Verify instrumentation exists
kubectl get instrumentation

# Check pod events
kubectl describe pod <pod-name>
```

### Problem: No Traces Appearing in Last9

**Check 1: Verify environment variables**
```bash
kubectl exec <pod-name> -- env | grep OTEL
```

**Check 2: Verify image was used**
```bash
kubectl describe pod <pod-name> | grep -A5 "Init Containers"
# Should show node12 or node10 image
```

**Check 3: Check application startup**
```bash
kubectl logs <pod-name> -c app
# Look for OpenTelemetry messages
```

**Check 4: Test connectivity**
```bash
kubectl exec <pod-name> -- wget -O- https://otlp.last9.io
```

### Problem: Application Crashes After Instrumentation

**Possible causes**:
1. **Package conflicts**: Legacy app dependencies might conflict with OTel 0.25/0.27
2. **Memory limits**: Instrumentation adds overhead (~50-100MB)
3. **Node version mismatch**: Using node10 image with Node 12 app

**Solutions**:
```yaml
# Increase memory limits
resources:
  limits:
    memory: "1Gi"  # Increase from 512Mi

# Check Node version in pod
kubectl exec <pod-name> -- node --version

# Disable specific instrumentations
env:
- name: OTEL_NODE_DISABLED_INSTRUMENTATIONS
  value: "fs,dns"  # Disable problematic instrumentations
```

## 📊 What Gets Instrumented?

### Automatic (Zero Code)

✅ **HTTP Frameworks**:
- Express
- Fastify
- Koa
- Hapi

✅ **Databases**:
- PostgreSQL (pg)
- MySQL (mysql, mysql2)
- MongoDB (mongodb)
- Redis (redis, ioredis)

✅ **HTTP Clients**:
- http/https (built-in)
- axios
- got
- request

✅ **Other**:
- DNS lookups
- File system operations (optional)
- Child processes

### Limitations

❌ **Not Instrumented**:
- Custom business logic (need manual spans for this)
- Internal function calls
- Non-standard libraries

## 🔄 Migration Strategy

### Phase 1: Enable Observability (Week 1-2)
- Deploy with legacy Node 10/12 images
- Gain visibility into application behavior
- Identify bottlenecks and errors

### Phase 2: Plan Upgrade (Month 1-2)
- Audit dependencies for Node 18/20 compatibility
- Update package.json
- Test in staging environment

### Phase 3: Upgrade Node (Month 2-3)
- Upgrade application to Node 18 or 20
- Remove custom image specification
- Use default/latest OpenTelemetry
- Monitor performance improvements

### Phase 4: Optimize (Month 3+)
- Add custom spans for business logic
- Fine-tune sampling rates
- Optimize instrumentation overhead

## 📚 Additional Resources

- [OpenTelemetry JS 0.25.0 Documentation](https://github.com/open-telemetry/opentelemetry-js/tree/v0.25.0)
- [OpenTelemetry JS 0.27.0 Documentation](https://github.com/open-telemetry/opentelemetry-js/tree/v0.27.0)
- [Node.js Release Schedule](https://nodejs.org/en/about/releases/)
- [Last9 Documentation](https://docs.last9.io)
- [autoinstrumentation/nodejs/README.md](../autoinstrumentation/nodejs/README.md)

## 🤝 Need Help?

- **Documentation Issues**: Open an issue in this repo
- **Last9 Support**: Contact support@last9.io
- **Community**: Join Last9 Discord

## ⚖️ License

MIT License
