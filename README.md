# 🧩 Order-to-Fulfillment Integration Demo

## WSO2 MI + SI + BI + ICP Unified Integration Platform

---

# Executive Overview

This repository demonstrates a realistic enterprise integration journey:

> **Order-to-fulfillment integration with real-time intelligence, AI-assisted decisions, and centralized operational control.**

A customer places an order through a digital channel.

The enterprise must:

* Validate and enrich the order
* Orchestrate ERP and CRM synchronously
* Decouple shipping asynchronously
* Detect suspicious order patterns in real time
* Automatically trigger review workflows
* Run scheduled reconciliation automation
* Use AI to assist fraud-risk decisions
* Operate everything from one unified control plane

Although deployed as separate runtimes (MI, SI, BI, ICP), this solution behaves as **one logical integration fabric**.

---

# 🏗 Architecture Overview

```
Customer → MI Order API
            ├─ ERP (sync)
            ├─ CRM (sync)
            └─ Shipping (async via Message Store)

Orders → SI (Streaming)
            └─ Detect anomaly → Call MI Review API

Anomalies → BI (Event Integration)
                ├─ Maintain rolling stats
                ├─ AI-assisted decision
                └─ Optional MI Review trigger

BI Automation → Scheduled reconciliation
                    ├─ Mock backend state
                    ├─ MI readiness/liveness
                    └─ Generate JSON + CSV reports

All runtimes → ICP (Integration Control Plane)
```

---

# 🧠 Runtime Responsibilities

---

# 1️⃣ Micro Integrator (MI)

## APIs Hosted

| API      | Endpoint          |
| -------- | ----------------- |
| Order v1 | `POST /v1/orders` |
| Order v2 | `POST /v2/orders` |
| Review   | `POST /review`    |

---

## Order Flow (Technical Breakdown)

### Step 1 — Validation & Enrichment

Sequence: `Order_Validate_Enrich`

* Extracts:

  * `orderId`
  * `amount`
* Validates required fields
* Generates or propagates correlation ID
* Sets `IS_PREMIUM` if `amount > 10000`

---

### Step 2 — Synchronous Orchestration

Sequence: `Order_Orchestrate_ERP_CRM`

```
Order → ERP (/erp/normal)
      → CRM (/crm/normal)
```

Fail-fast logic:

* If ERP or CRM returns HTTP ≥ 400
* Invoke centralized `CommonFaultHandler`
* Return structured JSON error

Success response example:

```json
{
  "status": "ACCEPTED",
  "correlationId": "abc-123",
  "order": { ... },
  "erp": { ... },
  "crm": { ... }
}
```

---

### Step 3 — Asynchronous Shipping

Sequence: `Order_Async_Store_Shipping`

Shipping is sent to:

```
POST /shipping/slow
```

Decoupled using:

* `ShippingMS` (InMemory Message Store)
* `ShippingMP` (ScheduledMessageForwardingProcessor)
* OUT_ONLY dispatch

Version behavior:

| Version | Shipping        |
| ------- | --------------- |
| v1      | Always async    |
| v2      | Only if premium |

---

## Health Endpoints

```
GET http://localhost:9201/healthz
GET http://localhost:9201/liveness
```

* `healthz` = Ready only if all CApps deployed
* `liveness` = Runtime started successfully

---

# 2️⃣ Streaming Integrator (SI)

## Siddhi Application

App Name: `OrderAnomalyDetector`

Ingress:

```
POST http://localhost:8007/OrderEvents
```

Expected format:

```json
{
  "event": {
    "orderId": "...",
    "amount": 15000,
    "customerId": "...",
    "channel": "...",
    "correlationId": "..."
  }
}
```

---

## Detection Rules

### Immediate High Value

```
amount >= 100000
```

Emit:

```
SINGLE_HIGH_VALUE
```

---

### Burst Anomaly (Stateful)

```
3+ orders ≥ 10000
within 2 minutes
grouped by customerId + channel
```

Uses:

```
#window.timeBatch(2 min)
group by customerId, channel
having count() >= 3
```

---

## Action

When anomaly detected:

```
POST http://mi:8290/review
```

Headers forwarded:

* x-correlation-id
* x-request-id

---

# 3️⃣ Business Integrator (BI)

BI demonstrates 3 integration styles.

---

## A) Event Integration

```
POST /bi/events/anomaly
```

Stores anomaly events in bounded in-memory store.

Maintains:

* Rolling 15-minute statistics
* High-risk count
* Top customers

---

## B) Scheduled Automation

Timer-based:

```
Every RECON_INTERVAL_SECONDS (default: 300)
```

Automation pulls:

* `/admin/state` (mock backend)
* `/healthz` (MI readiness)
* `/liveness` (MI liveness)
* Anomaly stats

Generates:

```
/data/reports/latest.json
/data/reports/latest.csv
```

---

## C) AI Agent Integration

```
POST /bi/ai/review
```

Flow:

1. Validate request
2. Call mock CRM
3. Pull anomaly stats
4. Call OpenAI (strict JSON schema)
5. Fallback to rules if AI fails
6. If HIGH risk → call MI `/review`

Decision modes:

* `OPENAI_AGENT`
* `FALLBACK_RULES`

---

# 4️⃣ ICP (Integration Control Plane)

ICP connects to:

* MI
* SI
* BI

Provides:

* Node visibility
* Artifact drill-down
* Log-level management
* Runtime metadata inspection

ICP is a true control plane — not just dashboards.

---

# 🚀 End-to-End Testing Guide

Assumes all runtimes running locally.

---

# 1️⃣ Verify Health

### MI

```bash
curl http://localhost:9201/healthz
curl http://localhost:9201/liveness
```

### BI

```bash
curl http://localhost:9090/bi/health
```

### Mock backend

```bash
curl http://localhost:8081/health
```

---

# 2️⃣ Normal Order (v1)

```bash
curl -X POST http://localhost:8290/v1/orders \
  -H "Content-Type: application/json" \
  -d '{"orderId":"100","amount":100}'
```

Expected:

* ACCEPTED
* ERP + CRM in response
* Shipping handled asynchronously

---

# 3️⃣ Premium Order (v2)

```bash
curl -X POST http://localhost:8290/v2/orders \
  -H "Content-Type: application/json" \
  -d '{"orderId":"200","amount":20000}'
```

Expected:

* Async shipping triggered

---

# 4️⃣ Simulate Slow Shipping

```bash
curl -X POST http://localhost:8081/admin/shipping/slow \
  -H "Content-Type: application/json" \
  -d '{"ms":15000}'
```

Send premium order again — API still responds immediately.

---

# 5️⃣ Immediate Anomaly (SI)

```bash
curl -X POST http://localhost:8007/OrderEvents \
  -H "Content-Type: application/json" \
  -d '{
        "event":{
          "orderId":"999",
          "amount":100000,
          "customerId":"C1",
          "channel":"web"
        }
      }'
```

Expected:

* SI logs anomaly
* MI Review API triggered

---

# 6️⃣ Burst Anomaly

---

Run 3 times quickly:

```bash
curl -X POST http://localhost:8007/OrderEvents \
  -H "Content-Type: application/json" \
  -d '{
        "event":{
          "orderId":"B1",
          "amount":15000,
          "customerId":"C2",
          "channel":"mobile"
        }
      }'
```

Expected:

* Burst anomaly detected
* MI Review triggered

---

# 7️⃣ BI Event Ingestion

---

```bash
curl -X POST http://localhost:9090/bi/events/anomaly \
  -H "Content-Type: application/json" \
  -d '{
        "anomalyType":"BURST_HIGH_VALUE",
        "orderId":"X1",
        "amount":15000,
        "customerId":"C2",
        "channel":"mobile",
        "correlationId":"demo-123",
        "eventCount":3,
        "windowStartTime":123456
      }'
```

---

# 8️⃣ AI Agent Decision

---

```bash
curl -X POST http://localhost:9090/bi/ai/review \
  -H "Content-Type: application/json" \
  -d '{
        "orderId":"AI-1",
        "amount":120000,
        "customerId":"C2",
        "channel":"mobile"
      }'
```

Expected response includes:

* risk
* recommendedAction
* rationale
* decisionMode
* optional miReview

---

# 9️⃣ Fetch Automation Report

---

```bash
curl http://localhost:9090/bi/reports/latest
curl http://localhost:9090/bi/reports/latestCsv
```

---

# 🐳 Local Setup (Docker-Based Deployment)

This demo runs fully containerized using Docker Compose.

## 📦 Prerequisites

* Docker Desktop (Mac / Linux)
* Docker Compose
* Minimum 8GB RAM recommended

> ⚠️ On Apple Silicon (M1/M2/M3 Macs), this demo mixes `linux/amd64` and `linux/arm64` images. Ensure Docker Desktop has Rosetta emulation enabled if needed.

---

# 🛠 First-Time Setup

## 1️⃣ Clone the repository

```bash
git clone https://github.com/joaokuntzwso2/demo-integrator.git
cd demo-integrator
```

---

## 2️⃣ Create BI Configuration File (Required)

Before starting the stack, you must manually create:

```
demo-bi/Config.toml
```

Create the file with the following contents:

```toml
# ---------------------------
# Your BI app config (demo/bi_order_intelligence)
# ---------------------------
MOCK_BASE_URL = "http://mock-backend:8081"
MI_RUNTIME_URL = "http://mi:9201"
MI_API_URL = "http://mi:8290"
BI_PORT = 9090

RECON_INTERVAL_SECONDS = 300
ANOMALY_BUFFER_MAX = 500
REPORT_DIR = "/data/reports"

# ---------------------------
# OPEN AI configs
# ---------------------------
OPENAI_API_KEY="YOUR-KEY-GOES-HERE"
OPENAI_BASE_URL = "https://api.openai.com/v1"
OPENAI_TEMPERATURE = 0.2

# ---------------------------
# ICP / Control Plane Agent (ballerinax/wso2.controlplane)
# ---------------------------
[ballerinax.wso2.controlplane]
keyStorePath = "/app/resources/ballerinaKeystore.p12"
trustStorePath = "/app/resources/ballerinaTruststore.p12"
icpServicePort = 9264

[ballerinax.wso2.controlplane.dashboard]
url = "https://icp:9743/dashboard/api"
heartbeatInterval = 10
groupId = "demo-local"
mgtApiUrl = "https://bi:9264/management/"
```

---

## 🔎 Why This File Is Required

The BI runtime:

* Registers itself to ICP
* Exposes a secure management API
* Uses internal keystore/truststore generated at build time
* Optionally calls OpenAI

Without this file, BI will fail to start due to missing configurable variables.

---

# 🚀 Start the Full Platform

From the project root:

```bash
docker-compose build --no-cache
docker-compose up
```

Or:

```bash
docker-compose up --build
```

---

# 🌐 Access Points

| Runtime         | URL                                                                    |
| --------------- | ---------------------------------------------------------------------- |
| MI APIs         | [http://localhost:8290](http://localhost:8290)                         |
| MI Health       | [http://localhost:9201/healthz](http://localhost:9201/healthz)         |
| SI HTTP Ingress | [http://localhost:8007/OrderEvents](http://localhost:8007/OrderEvents) |
| BI API          | [http://localhost:9090](http://localhost:9090)                         |
| ICP Dashboard   | [https://localhost:9743/dashboard](https://localhost:9743/dashboard)   |

> ICP uses HTTPS with self-signed certificates.

---

# 🧭 Verifying ICP in Action

Once all containers are running:

1. Open:

```
https://localhost:9743/
```

2. You should see:

* Node: MI
* Node: SI
* Node: BI
* Group: demo-local

3. Trigger activity:

* Send anomaly events
* Call MI APIs
* Run BI reconciliation
* Observe nodes updating heartbeat timestamps

ICP provides:

* Artifact visibility
* Runtime grouping
* Health monitoring
* Management API introspection

---

# 🔐 OpenAI (Optional)

If you want AI decision support enabled:

Edit:

```
demo-bi/Config.toml
```

Set:

```toml
OPENAI_API_KEY="your-key-here"
```

If empty, BI automatically falls back to deterministic rules.

---

# 📁 Generated Reports

BI automation writes:

```
demo-bi-data/reports/latest.json
demo-bi-data/reports/latest.csv
```

These demonstrate:

* Cross-runtime reconciliation
* Operational reporting
* Event-driven + scheduled integration fusion

---

# 🧠 Architectural Significance

This demo is intentionally designed to show:

* API orchestration (MI)
* Stateful streaming intelligence (SI)
* Event-driven integration (BI)
* AI-assisted decisions
* Scheduled automation
* Control-plane governance (ICP)

All running as a unified integration fabric.

---

# 🧱 Common Troubleshooting

### BI fails with “dashboard config missing”

Ensure `Config.toml` exists in:

```
demo-bi/Config.toml
```

---

### ICP shows internal error

Use:

```
https://localhost:9743/dashboard
```

(not root `/`)

---

### SI drops events

Ensure JSON payload matches expected format:

```json
{
  "event": {
    "orderId": "...",
    "amount": 10000,
    "customerId": "...",
    "channel": "...",
    "correlationId": "..."
  }
}
```

---

# 🎯 What This Demo Proves

---

* API orchestration with controlled failure handling
* Async backend resiliency
* Real-time stateful streaming intelligence
* AI-assisted integration decisions
* Scheduled automation & reconciliation
* Unified observability across heterogeneous runtimes

---