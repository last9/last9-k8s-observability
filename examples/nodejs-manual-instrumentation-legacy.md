# Manual Node.js 10/12 Instrumentation Guide

This guide shows how to manually instrument legacy Node.js 10 and 12 applications using compatible OpenTelemetry versions. Use this approach when:

- Running on VMs, bare metal, or AWS Lambda (not Kubernetes)
- Need more control over instrumentation
- Want to add custom spans for business logic
- Kubernetes operator not available

## ⚠️ Security Warning

- **Node 10**: EOL April 2021 - Critical security vulnerabilities exist
- **Node 12**: EOL April 2022 - Security vulnerabilities exist
- **Recommendation**: Use only during migration to Node 18+/20+

## 🎯 Approach

Instead of creating a wrapper package, we **pin to older OpenTelemetry versions** that supported Node 10/12. This is the standard industry approach.

## 📦 Installation

### For Node 10.x Applications

```bash
npm install --save \
  @opentelemetry/api@1.0.4 \
  @opentelemetry/sdk-node@0.25.0 \
  @opentelemetry/auto-instrumentations-node@0.25.0 \
  @opentelemetry/exporter-trace-otlp-http@0.25.0 \
  @opentelemetry/resources@0.25.0 \
  @opentelemetry/semantic-conventions@0.25.0
```

### For Node 12.x Applications

```bash
npm install --save \
  @opentelemetry/api@1.0.4 \
  @opentelemetry/sdk-node@0.27.0 \
  @opentelemetry/auto-instrumentations-node@0.27.3 \
  @opentelemetry/exporter-trace-otlp-http@0.27.0 \
  @opentelemetry/resources@0.27.0 \
  @opentelemetry/semantic-conventions@0.27.0
```

## 🚀 Basic Setup

### Step 1: Create Instrumentation File

Create `instrumentation.js` at the root of your project:

```javascript
// instrumentation.js
// This MUST be the first import in your application!

'use strict';

const { NodeSDK } = require('@opentelemetry/sdk-node');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');
const { Resource } = require('@opentelemetry/resources');
const { SemanticResourceAttributes } = require('@opentelemetry/semantic-conventions');

// Configuration from environment variables
const config = {
  serviceName: process.env.OTEL_SERVICE_NAME || 'my-service',
  endpoint: process.env.OTEL_EXPORTER_OTLP_ENDPOINT || 'https://otlp.last9.io',
  headers: process.env.OTEL_EXPORTER_OTLP_HEADERS || '',
  environment: process.env.DEPLOYMENT_ENVIRONMENT || 'production',
};

// Parse headers
const headers = {};
if (config.headers) {
  config.headers.split(',').forEach(pair => {
    const [key, ...value] = pair.split('=');
    if (key && value.length) {
      headers[key.trim()] = value.join('=').trim();
    }
  });
}

// Create resource
const resource = Resource.default().merge(
  new Resource({
    [SemanticResourceAttributes.SERVICE_NAME]: config.serviceName,
    [SemanticResourceAttributes.SERVICE_VERSION]: process.env.npm_package_version,
    [SemanticResourceAttributes.DEPLOYMENT_ENVIRONMENT]: config.environment,
  })
);

// Create OTLP exporter
const traceExporter = new OTLPTraceExporter({
  url: config.endpoint.replace(/\/$/, '') + '/v1/traces',
  headers,
  compression: 'gzip',
  timeoutMillis: 10000,
});

// Initialize SDK
const sdk = new NodeSDK({
  resource,
  traceExporter,
  instrumentations: [getNodeAutoInstrumentations()],
});

// Start SDK
sdk.start();

console.log(`[Last9] OpenTelemetry initialized`);
console.log(`[Last9] Service: ${config.serviceName}`);
console.log(`[Last9] Node version: ${process.version}`);
console.log(`[Last9] Endpoint: ${config.endpoint}`);

// Graceful shutdown
process.on('SIGTERM', () => {
  sdk.shutdown()
    .then(() => console.log('[Last9] Tracing terminated'))
    .catch((error) => console.error('[Last9] Error shutting down tracing', error))
    .finally(() => process.exit(0));
});

module.exports = sdk;
```

### Step 2: Load Instrumentation First

**Option A: Require in code (recommended)**

```javascript
// index.js or app.js
// IMPORTANT: This must be the FIRST line!
require('./instrumentation');

// Now import your application code
const express = require('express');
const app = express();

// Your routes and logic...
app.get('/', (req, res) => {
  res.json({ message: 'Hello World!' });
});

app.listen(3000, () => {
  console.log('Server started on port 3000');
});
```

**Option B: Use Node.js --require flag**

```bash
# In package.json scripts
{
  "scripts": {
    "start": "node --require ./instrumentation.js app.js"
  }
}
```

### Step 3: Set Environment Variables

```bash
# .env file or export in shell

# Required
export OTEL_EXPORTER_OTLP_ENDPOINT="https://otlp.last9.io"
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic YOUR_LAST9_TOKEN"

# Recommended
export OTEL_SERVICE_NAME="my-legacy-api"
export DEPLOYMENT_ENVIRONMENT="production"

# Optional
export OTEL_RESOURCE_ATTRIBUTES="team=backend,version=1.2.3"
```

### Step 4: Run Your Application

```bash
# Load environment and start
source .env
npm start
```

## 📊 Complete Example

### package.json

```json
{
  "name": "my-node12-app",
  "version": "1.0.0",
  "description": "Legacy Node 12 application with Last9 instrumentation",
  "main": "app.js",
  "engines": {
    "node": "12.x"
  },
  "scripts": {
    "start": "node -r ./instrumentation.js app.js",
    "dev": "nodemon -r ./instrumentation.js app.js"
  },
  "dependencies": {
    "express": "^4.17.1",
    "pg": "^8.7.1",
    "redis": "^3.1.2",
    "@opentelemetry/api": "1.0.4",
    "@opentelemetry/sdk-node": "0.27.0",
    "@opentelemetry/auto-instrumentations-node": "0.27.3",
    "@opentelemetry/exporter-trace-otlp-http": "0.27.0",
    "@opentelemetry/resources": "0.27.0",
    "@opentelemetry/semantic-conventions": "0.27.0"
  },
  "devDependencies": {
    "nodemon": "^2.0.15"
  }
}
```

### app.js

```javascript
// app.js
// Instrumentation already loaded via -r flag
const express = require('express');
const { Pool } = require('pg');
const redis = require('redis');

const app = express();
const port = process.env.PORT || 3000;

// Database connection (automatically instrumented)
const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
});

// Redis connection (automatically instrumented)
const redisClient = redis.createClient({
  url: process.env.REDIS_URL,
});

redisClient.on('error', (err) => console.error('Redis error:', err));

// Routes
app.get('/', (req, res) => {
  res.json({
    message: 'Hello from Node 12!',
    version: process.version,
    instrumented: true,
  });
});

app.get('/users', async (req, res) => {
  try {
    // Database query - automatically traced!
    const result = await pool.query('SELECT * FROM users LIMIT 10');
    res.json(result.rows);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.get('/cache/:key', async (req, res) => {
  // Redis operation - automatically traced!
  redisClient.get(req.params.key, (err, value) => {
    if (err) {
      return res.status(500).json({ error: err.message });
    }
    res.json({ key: req.params.key, value });
  });
});

app.listen(port, () => {
  console.log(`Server running on port ${port}`);
});
```

### Dockerfile

```dockerfile
FROM node:12-alpine

WORKDIR /app

# Copy package files
COPY package*.json ./

# Install dependencies
RUN npm ci --production

# Copy application code
COPY . .

# Set environment variables (override at runtime)
ENV PORT=3000
ENV NODE_ENV=production

EXPOSE 3000

# Start with instrumentation
CMD ["node", "-r", "./instrumentation.js", "app.js"]
```

## 🎨 Advanced Configuration

### Custom Span Creation

```javascript
// In your application code
const opentelemetry = require('@opentelemetry/api');

function processPayment(userId, amount) {
  const tracer = opentelemetry.trace.getTracer('my-service');

  return tracer.startActiveSpan('process-payment', async (span) => {
    try {
      span.setAttribute('user.id', userId);
      span.setAttribute('payment.amount', amount);

      // Your business logic
      const result = await chargeCard(userId, amount);

      span.setStatus({ code: opentelemetry.SpanStatusCode.OK });
      return result;
    } catch (error) {
      span.setStatus({
        code: opentelemetry.SpanStatusCode.ERROR,
        message: error.message,
      });
      span.recordException(error);
      throw error;
    } finally {
      span.end();
    }
  });
}
```

### Selective Instrumentation

```javascript
// instrumentation.js - disable specific instrumentations
const sdk = new NodeSDK({
  resource,
  traceExporter,
  instrumentations: [
    getNodeAutoInstrumentations({
      // Disable file system instrumentation (noisy)
      '@opentelemetry/instrumentation-fs': {
        enabled: false,
      },
      // Disable DNS instrumentation
      '@opentelemetry/instrumentation-dns': {
        enabled: false,
      },
      // Configure HTTP instrumentation
      '@opentelemetry/instrumentation-http': {
        ignoreIncomingPaths: ['/health', '/metrics'],
      },
    }),
  ],
});
```

### Sampling Configuration

```javascript
// instrumentation.js
const { ParentBasedSampler, TraceIdRatioBasedSampler } = require('@opentelemetry/sdk-trace-base');

const sdk = new NodeSDK({
  resource,
  traceExporter,
  sampler: new ParentBasedSampler({
    root: new TraceIdRatioBasedSampler(0.1), // Sample 10% of traces
  }),
  instrumentations: [getNodeAutoInstrumentations()],
});
```

## 🐛 Troubleshooting

### Problem: No Traces Appearing

**Check 1: Verify instrumentation loaded first**
```javascript
// This should be BEFORE any other imports
require('./instrumentation');

// NOT after:
const express = require('express'); // ❌ TOO LATE!
require('./instrumentation');
```

**Check 2: Check environment variables**
```bash
node -e "console.log(process.env.OTEL_EXPORTER_OTLP_ENDPOINT)"
```

**Check 3: Enable debug logging**
```javascript
// At top of instrumentation.js
const { DiagConsoleLogger, DiagLogLevel, diag } = require('@opentelemetry/api');
diag.setLogger(new DiagConsoleLogger(), DiagLogLevel.DEBUG);
```

**Check 4: Test connectivity**
```bash
curl -X POST https://otlp.last9.io/v1/traces \
  -H "Authorization: Basic YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"resourceSpans":[]}'
```

### Problem: Application Crashes

**Possible causes**:
1. **Dependency conflicts**: Old dependencies incompatible with OTel 0.25/0.27
2. **Memory issues**: Instrumentation adds ~50-100MB overhead
3. **Circular dependencies**: Instrumentation loaded incorrectly

**Solutions**:
```bash
# Check Node version
node --version  # Should match package.json engines

# Increase memory limit
node --max-old-space-size=2048 -r ./instrumentation.js app.js

# Try without auto-instrumentations (manual only)
# Remove getNodeAutoInstrumentations() and add manually
```

### Problem: Missing Spans for Database/Redis

**Cause**: Package version incompatible with instrumentation

**Solution**: Check supported versions
```bash
# For Node 12 with OTel 0.27:
# - pg: ^7.0.0 || ^8.0.0
# - mysql: ^2.0.0
# - redis: ^2.0.0 || ^3.0.0
# - mongodb: ^3.3.0 || ^4.0.0

# Upgrade if needed
npm install pg@8 redis@3
```

## 📊 What Gets Instrumented?

### Automatic (Zero Additional Code)

✅ **HTTP Frameworks**:
- Express 4.x
- Fastify 2.x/3.x
- Koa 2.x
- Hapi 17.x+

✅ **Databases**:
- PostgreSQL (pg 7.x/8.x)
- MySQL (mysql 2.x, mysql2 1.x/2.x)
- MongoDB (mongodb 3.3+)
- Redis (redis 2.x/3.x, ioredis 4.x)

✅ **HTTP Clients**:
- Built-in http/https
- axios
- got
- request (deprecated but still works)

✅ **Other**:
- DNS lookups
- gRPC (experimental)

### Limitations

❌ **Not Automatically Instrumented**:
- Custom business logic (need manual spans)
- WebSockets
- Message queues (RabbitMQ, Kafka - need manual)
- Non-standard database drivers

## 🔄 Migration Path

### Phase 1: Add Instrumentation (Week 1)
- Install pinned OpenTelemetry versions
- Add instrumentation.js
- Deploy to staging
- Verify traces in Last9

### Phase 2: Production Rollout (Week 2-3)
- Deploy to production with monitoring
- Tune sampling rates if needed
- Disable noisy instrumentations

### Phase 3: Plan Node Upgrade (Month 1-2)
- Use trace data to identify performance bottlenecks
- Test application with Node 18/20
- Update dependencies

### Phase 4: Upgrade Node (Month 2-3)
- Upgrade to Node 18 or 20
- Update OpenTelemetry to latest versions
- Remove version pins
- Add custom business logic spans

## 🆚 Comparison: Manual vs Operator

| Aspect | Manual (This Guide) | Operator |
|--------|-------------------|----------|
| **Environment** | Anywhere | Kubernetes only |
| **Setup** | Install packages + init code | Just annotation |
| **Flexibility** | Full control | Limited |
| **Custom spans** | ✅ Easy | Need SDK separately |
| **Version control** | package.json | Docker image tag |
| **Updates** | `npm update` | Change image |

## 📚 Package Compatibility Reference

### Node 10 (OpenTelemetry 0.25.0)

```json
{
  "@opentelemetry/api": "1.0.4",
  "@opentelemetry/sdk-node": "0.25.0",
  "@opentelemetry/auto-instrumentations-node": "0.25.0"
}
```

**Supported instrumentations**:
- HTTP/HTTPS
- Express 4.x
- PostgreSQL (pg 7.x/8.x)
- MySQL (mysql 2.x, mysql2 1.x/2.x)
- MongoDB 3.3+
- Redis 2.x/3.x

### Node 12 (OpenTelemetry 0.27.0)

```json
{
  "@opentelemetry/api": "1.0.4",
  "@opentelemetry/sdk-node": "0.27.0",
  "@opentelemetry/auto-instrumentations-node": "0.27.3"
}
```

**Supported instrumentations**: All Node 10 instrumentations plus:
- Fastify 3.x
- Koa 2.x
- ioredis 4.x
- gRPC (experimental)

## 🤝 Need Help?

- **Documentation**: See [nodejs-legacy-versions.md](./nodejs-legacy-versions.md) for operator approach
- **Last9 Support**: support@last9.io
- **Community**: Last9 Discord

## ⚖️ License

MIT License
