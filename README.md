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

```text
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

## 1️⃣ Micro Integrator (MI)

### APIs Hosted

| API      | Endpoint          |
| -------- | ----------------- |
| Order v1 | `POST /v1/orders` |
| Order v2 | `POST /v2/orders` |
| Review   | `POST /review`    |

---

### Order Flow (Technical Breakdown)

#### Step 1 — Validation & Enrichment

Sequence: `Order_Validate_Enrich`

* Extracts:

  * `orderId`
  * `amount`
* Validates required fields
* Generates or propagates correlation ID
* Sets `IS_PREMIUM=true` if `amount > 10000`

---

#### Step 2 — Synchronous Orchestration

Sequence: `Order_Orchestrate_ERP_CRM`

```text
Order → ERP (/erp/normal)
      → CRM (/crm/normal)
```

Fail-fast logic:

* If ERP or CRM returns HTTP `>= 400`
* MI invokes centralized `CommonFaultHandler`
* Returns structured JSON error immediately

Success response shape:

```json
{
  "status": "ACCEPTED",
  "correlationId": "abc-123",
  "order": {
    "orderId": "1001",
    "amount": 12000,
    "premium": true
  },
  "erp": { "...": "..." },
  "crm": { "...": "..." }
}
```

---

#### Step 3 — Asynchronous Shipping

Sequence: `Order_Async_Store_Shipping`

Shipping target:

```text
POST /shipping/slow
```

Decoupled using:

* `ShippingMS` — In-memory message store
* `ShippingMP` — `ScheduledMessageForwardingProcessor`
* `OUT_ONLY` dispatch

Version behavior:

| Version | Shipping behavior |
| ------- | ----------------- |
| v1      | Always async      |
| v2      | Only if premium   |

This means the caller gets the response immediately after ERP and CRM complete. Shipping continues in the background.

---

### Review API

#### Endpoint

```http
POST /review
```

#### What it is for

The Review API is the **manual or automated escalation endpoint** for suspicious orders.

It is used by:

* **SI**, when anomaly detection rules fire
* **BI**, when AI or fallback rules recommend escalation
* direct testers/operators, to simulate or force a review flow

#### What it does

Sequence: `Review_Process`

* Ensures / generates `CORRELATION_ID`
* Extracts `orderId` and `amount`
* Logs the review event
* Calls CRM synchronously using the same correlation ID
* Returns a `REVIEW_TRIGGERED` JSON response

It is intentionally lightweight: it acts as the review entrypoint and returns CRM-enriched review context.

#### Example request

```bash
curl -X POST http://localhost:8290/review \
  -H "Content-Type: application/json" \
  -H "x-correlation-id: review-demo-001" \
  -d '{
    "orderId": "ORD-REV-001",
    "amount": 110000,
    "reason": "HIGH_RISK",
    "customerId": "CUST-300",
    "channel": "web"
  }'
```

#### Expected response

```json
{
  "status": "REVIEW_TRIGGERED",
  "correlationId": "review-demo-001",
  "orderId": "ORD-REV-001",
  "amount": 110000,
  "crm": {
    "...": "..."
  }
}
```

---

### Health Endpoints

```text
GET http://localhost:9201/healthz
GET http://localhost:9201/liveness
```

* `healthz` = MI readiness
* `liveness` = MI runtime liveness

---

## 2️⃣ Streaming Integrator (SI)

### Siddhi Application

App name: `OrderAnomalyDetector`

Ingress:

```text
POST http://localhost:8007/OrderEvents
```

Expected payload:

```json
{
  "event": {
    "orderId": "ORD-1",
    "amount": 15000,
    "customerId": "CUST-1",
    "channel": "web",
    "correlationId": "cid-123"
  }
}
```

---

### Detection Rules

#### Immediate High Value

```text
amount >= 100000
```

Emits:

```text
SINGLE_HIGH_VALUE
```

---

#### Burst Anomaly

```text
3+ orders >= 10000
within 2 minutes
grouped by customerId + channel
```

Implemented with:

```text
#window.timeBatch(2 min)
group by customerId, channel
having count() >= 3
```

Important: because this uses a **2-minute time batch**, the burst anomaly is emitted when the batch closes, not necessarily immediately on the third POST.

---

### Actions on Anomaly

When an anomaly is detected, SI fans out to:

* **MI Review API**
* **BI anomaly ingestion**
* SI logs

MI target:

```text
POST http://mi:8290/review
```

BI target:

```text
POST http://bi:9090/bi/events/anomaly
```

Headers propagated:

* `x-correlation-id`
* `x-request-id`

---

## 3️⃣ Business Integrator (BI)

BI demonstrates three integration styles.

---

### A) Event Integration

Endpoint:

```text
POST /bi/events/anomaly
```

Behavior:

* normalizes incoming anomaly event payload
* stores events in a bounded in-memory anomaly buffer
* maintains rolling statistics

Metrics derived from this buffer include:

* anomalies in last 15 minutes
* high-risk anomaly count
* top customers/channels

---

### B) Scheduled Automation

Timer-based reconciliation:

```text
Every RECON_INTERVAL_SECONDS (default: 300)
```

The automation pulls:

* mock backend `/admin/state`
* MI `/healthz`
* MI `/liveness`
* anomaly buffer statistics

It generates:

```text
/data/reports/latest.json
/data/reports/latest.csv
```

It also writes timestamped historical report JSON files.

---

### C) AI-Assisted Review Decision

Endpoint:

```text
POST /bi/ai/review
```

Flow:

1. Validate request
2. Call mock CRM
3. Pull anomaly stats for customer/channel over the last 15 minutes
4. Call OpenAI with a strict JSON schema
5. Fall back to deterministic rules if OpenAI is unavailable or fails
6. If result recommends escalation, call MI `/review`

Decision modes:

* `OPENAI_AGENT`
* `FALLBACK_RULES`

Possible actions:

* `ALLOW`
* `ALLOW_BUT_MONITOR`
* `TRIGGER_MI_REVIEW`

---

### D) Conversational Agent

Endpoint:

```text
POST /agente/chat
```

This exposes a lightweight AI assistant backed by Ballerina AI integration and short-term memory. It is useful for demo conversations about anomaly events, BI behavior, and review decisions.

---

## 4️⃣ ICP (Integration Control Plane)

ICP connects to:

* MI
* SI
* BI

Provides:

* node visibility
* artifact drill-down
* runtime metadata inspection
* control-plane style management visibility

---

# 🐳 Local Setup (Docker-Based Deployment)

This demo runs fully containerized using Docker Compose.

## 📦 Prerequisites

* Docker Desktop
* Docker Compose
* 8 GB RAM recommended

> ⚠️ On Apple Silicon, this demo mixes `linux/amd64` and `linux/arm64` images. Ensure emulation is enabled if required.

---

# 🛠 First-Time Setup

## 1️⃣ Clone the repository

```bash
git clone https://github.com/joaokuntzwso2/demo-integrator.git
cd demo-integrator
```

---

## 2️⃣ Create BI Configuration File

Before starting the stack, create:

```text
demo-bi/Config.toml
```

Suggested contents:

```toml
MOCK_BASE_URL = "http://mock-backend:8081"
MI_RUNTIME_URL = "http://mi:9201"
MI_API_URL = "http://mi:8290"
BI_PORT = 9090

RECON_INTERVAL_SECONDS = 300
ANOMALY_BUFFER_MAX = 500
REPORT_DIR = "/data/reports"

OPENAI_API_KEY = "YOUR-KEY-GOES-HERE"
OPENAI_BASE_URL = "https://api.openai.com/v1"
OPENAI_TEMPERATURE = 0.2

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

Why it is required:

* BI uses configurable values for runtime URLs and scheduling
* BI optionally uses OpenAI
* BI registers into ICP / exposes management endpoints
* your `docker-compose.yml` mounts this file into the BI container

If the file is missing, BI will not start correctly.

---

# 🚀 Start the Full Platform

From the project root:

```bash
docker compose up --build
```

For a clean rebuild:

```bash
docker compose build --no-cache
docker compose up
```

---

# 🌐 Access Points

| Runtime         | URL                                 |
| --------------- | ----------------------------------- |
| MI APIs         | `http://localhost:8290`             |
| MI Health       | `http://localhost:9201/healthz`     |
| SI HTTP Ingress | `http://localhost:8007/OrderEvents` |
| BI API          | `http://localhost:9090`             |
| ICP Dashboard   | `https://localhost:9743/dashboard`  |
| Mock backend    | `http://localhost:8081`             |

> ICP uses HTTPS with self-signed certificates.

---

# 🧭 Verifying ICP in Action

Once all containers are running:

1. Open:

```text
https://localhost:9743/dashboard
```

2. You should see nodes for:

* MI
* SI
* BI

3. Trigger activity:

* call MI APIs
* send SI anomaly events
* invoke BI AI review
* wait for BI reconciliation ticks

ICP should reflect heartbeat and runtime activity.

---

# 🚀 End-to-End Testing and Full curl Cookbook

The following cookbook covers all HTTP endpoints exposed by the implementation.

You can optionally define:

```bash
CID=test-cid-001
```

---

## 1️⃣ Mock Backend

### Health

```bash
curl -s http://localhost:8081/health
```

What happens:

* Returns uptime and current fail/slow state for ERP, CRM, and Shipping.

Expected:

* JSON with `status: "OK"` and `state`.

---

### Admin State

```bash
curl -s http://localhost:8081/admin/state
```

What happens:

* Returns runtime fault-injection state.

Expected:

* current `fail` and `slowMs` values.

---

### Enable ERP fail mode

```bash
curl -s -X POST http://localhost:8081/admin/erp/fail \
  -H 'Content-Type: application/json' \
  -d '{"enabled": true}'
```

What happens:

* ERP starts returning `503`.

Expected:

* JSON confirming `fail: true`.

Disable again:

```bash
curl -s -X POST http://localhost:8081/admin/erp/fail \
  -H 'Content-Type: application/json' \
  -d '{"enabled": false}'
```

---

### Enable CRM fail mode

```bash
curl -s -X POST http://localhost:8081/admin/crm/fail \
  -H 'Content-Type: application/json' \
  -d '{"enabled": true}'
```

Disable:

```bash
curl -s -X POST http://localhost:8081/admin/crm/fail \
  -H 'Content-Type: application/json' \
  -d '{"enabled": false}'
```

What happens:

* CRM mock toggles between healthy and `503` failure mode.

Expected:

* confirmation payload.

---

### Enable Shipping fail mode

```bash
curl -s -X POST http://localhost:8081/admin/shipping/fail \
  -H 'Content-Type: application/json' \
  -d '{"enabled": true}'
```

Disable:

```bash
curl -s -X POST http://localhost:8081/admin/shipping/fail \
  -H 'Content-Type: application/json' \
  -d '{"enabled": false}'
```

What happens:

* async shipping attempts from MI will fail while this is enabled.

Expected:

* confirmation payload.

---

### Set ERP slow latency

```bash
curl -s -X POST http://localhost:8081/admin/erp/slow \
  -H 'Content-Type: application/json' \
  -d '{"ms": 12000}'
```

---

### Set CRM slow latency

```bash
curl -s -X POST http://localhost:8081/admin/crm/slow \
  -H 'Content-Type: application/json' \
  -d '{"ms": 7000}'
```

---

### Set Shipping slow latency

```bash
curl -s -X POST http://localhost:8081/admin/shipping/slow \
  -H 'Content-Type: application/json' \
  -d '{"ms": 15000}'
```

What happens:

* updates artificial delay for the `/slow` endpoint of the chosen backend.

Expected:

* confirmation payload with `slowMs`.

---

### ERP ping

```bash
curl -s -H "x-correlation-id: $CID" http://localhost:8081/erp/ping
```

### CRM ping

```bash
curl -s -H "x-correlation-id: $CID" http://localhost:8081/crm/ping
```

### Shipping ping

```bash
curl -s -H "x-correlation-id: $CID" http://localhost:8081/shipping/ping
```

What happens:

* quick health-style checks for each mock service.

Expected:

* `status: "OK"` unless fail mode is enabled.

---

### ERP normal

```bash
curl -s -X POST http://localhost:8081/erp/normal \
  -H 'Content-Type: application/json' \
  -H "x-correlation-id: $CID" \
  -d '{
    "orderId": "ORD-1001",
    "amount": 12000,
    "customerId": "CUST-1"
  }'
```

What happens:

* ERP mock returns deterministic enrichment like ERP order reference, credit status, and warehouse.

Expected:

* fast JSON response with `result`.

---

### CRM normal

```bash
curl -s -X POST http://localhost:8081/crm/normal \
  -H 'Content-Type: application/json' \
  -H "x-correlation-id: $CID" \
  -d '{
    "orderId": "ORD-1002",
    "amount": 15000,
    "customerId": "CUST-9"
  }'
```

What happens:

* CRM mock returns tier, loyalty, and potential flagged customer marker.

Expected:

* fast JSON response with CRM-style enrichment.

---

### Shipping normal

```bash
curl -s -X POST http://localhost:8081/shipping/normal \
  -H 'Content-Type: application/json' \
  -H "x-correlation-id: $CID" \
  -d '{
    "orderId": "ORD-1003",
    "amount": 8000,
    "premium": false
  }'
```

What happens:

* Shipping mock returns carrier, ETA, and tracking seed.

Expected:

* fast JSON response with shipping-like result.

---

### ERP slow

```bash
time curl -s -X POST http://localhost:8081/erp/slow \
  -H 'Content-Type: application/json' \
  -H "x-correlation-id: $CID" \
  -d '{
    "orderId": "ORD-1004",
    "amount": 9000
  }'
```

### CRM slow

```bash
time curl -s -X POST http://localhost:8081/crm/slow \
  -H 'Content-Type: application/json' \
  -H "x-correlation-id: $CID" \
  -d '{
    "orderId": "ORD-1005",
    "amount": 20000,
    "customerId": "CUST-77"
  }'
```

### Shipping slow

```bash
time curl -s -X POST http://localhost:8081/shipping/slow \
  -H 'Content-Type: application/json' \
  -H "x-correlation-id: $CID" \
  -d '{
    "orderId": "ORD-1006",
    "amount": 25000,
    "premium": true
  }'
```

What happens:

* these endpoints wait for the configured slow delay and then respond.

Expected:

* delayed response with service-specific payload.

---

## 2️⃣ Micro Integrator

### MI readiness

```bash
curl -s http://localhost:9201/healthz
```

### MI liveness

```bash
curl -s http://localhost:9201/liveness
```

What happens:

* checks runtime readiness and liveness.

Expected:

* healthy response when MI is up.

---

### v1 happy path

```bash
curl -s -X POST http://localhost:8290/v1/orders \
  -H 'Content-Type: application/json' \
  -H "x-correlation-id: $CID" \
  -d '{
    "orderId": "ORD-V1-001",
    "amount": 12000,
    "customerId": "CUST-100",
    "channel": "web"
  }'
```

What happens:

* validates request
* calls ERP synchronously
* calls CRM synchronously
* builds accepted response
* stores shipping request asynchronously

Expected:

* immediate JSON response with:

  * `status: "ACCEPTED"`
  * `order`
  * `erp`
  * `crm`

Shipping continues in background.

---

### v1 validation failure

```bash
curl -s -X POST http://localhost:8290/v1/orders \
  -H 'Content-Type: application/json' \
  -d '{
    "amount": 12000
  }'
```

What happens:

* validation fails because `orderId` is missing.

Expected:

* HTTP `400`
* JSON:

  * `status: "INVALID"`
  * message stating `orderId and amount are required`

---

### v1 ERP failure path

```bash
curl -s -X POST http://localhost:8081/admin/erp/fail \
  -H 'Content-Type: application/json' \
  -d '{"enabled": true}'
```

```bash
curl -s -i -X POST http://localhost:8290/v1/orders \
  -H 'Content-Type: application/json' \
  -H "x-correlation-id: $CID" \
  -d '{
    "orderId": "ORD-V1-ERP-FAIL",
    "amount": 5000,
    "customerId": "CUST-101",
    "channel": "mobile"
  }'
```

What happens:

* ERP returns `503`
* MI fail-fast logic invokes `CommonFaultHandler`
* CRM and shipping are not executed

Expected:

* HTTP `503`
* integration error payload mentioning ERP failure

Reset ERP afterward:

```bash
curl -s -X POST http://localhost:8081/admin/erp/fail \
  -H 'Content-Type: application/json' \
  -d '{"enabled": false}'
```

---

### v1 CRM failure path

```bash
curl -s -X POST http://localhost:8081/admin/crm/fail \
  -H 'Content-Type: application/json' \
  -d '{"enabled": true}'
```

```bash
curl -s -i -X POST http://localhost:8290/v1/orders \
  -H 'Content-Type: application/json' \
  -H "x-correlation-id: $CID" \
  -d '{
    "orderId": "ORD-V1-CRM-FAIL",
    "amount": 9000,
    "customerId": "CUST-102",
    "channel": "store"
  }'
```

What happens:

* ERP succeeds
* CRM fails
* centralized fault handler returns JSON error

Expected:

* HTTP `503`
* integration failure payload mentioning CRM

Reset CRM afterward.

---

### v2 non-premium

```bash
curl -s -X POST http://localhost:8290/v2/orders \
  -H 'Content-Type: application/json' \
  -H "x-correlation-id: $CID" \
  -d '{
    "orderId": "ORD-V2-001",
    "amount": 5000,
    "customerId": "CUST-200",
    "channel": "web"
  }'
```

What happens:

* validates and orchestrates ERP + CRM
* shipping is skipped because not premium

Expected:

* immediate accepted response without async shipping dispatch.

---

### v2 premium

```bash
curl -s -X POST http://localhost:8290/v2/orders \
  -H 'Content-Type: application/json' \
  -H "x-correlation-id: $CID" \
  -d '{
    "orderId": "ORD-V2-002",
    "amount": 25000,
    "customerId": "CUST-201",
    "channel": "web"
  }'
```

What happens:

* validates and orchestrates ERP + CRM
* because amount is premium, shipping is stored asynchronously

Expected:

* immediate accepted response
* background shipping dispatch later

---

### v2 validation failure

```bash
curl -s -X POST http://localhost:8290/v2/orders \
  -H 'Content-Type: application/json' \
  -d '{
    "orderId": "",
    "amount": 0
  }'
```

Expected:

* HTTP `400`
* invalid request payload

---

### Direct review call

```bash
curl -s -X POST http://localhost:8290/review \
  -H 'Content-Type: application/json' \
  -H "x-correlation-id: $CID" \
  -d '{
    "orderId": "ORD-REV-001",
    "amount": 110000,
    "reason": "HIGH_RISK",
    "customerId": "CUST-300",
    "channel": "web"
  }'
```

What happens:

* MI review flow logs the event
* CRM is called synchronously
* response returns `REVIEW_TRIGGERED`

Expected:

* JSON response including `crm`.

---

### Review call with CRM failure

```bash
curl -s -X POST http://localhost:8081/admin/crm/fail \
  -H 'Content-Type: application/json' \
  -d '{"enabled": true}'
```

```bash
curl -s -i -X POST http://localhost:8290/review \
  -H 'Content-Type: application/json' \
  -d '{
    "orderId": "ORD-REV-FAIL",
    "amount": 70000
  }'
```

What happens:

* review flow attempts CRM
* CRM fails
* centralized fault handler returns integration error

Reset CRM afterward.

---

## 3️⃣ Streaming Integrator

### Normal SI event

```bash
curl -s -X POST http://localhost:8007/OrderEvents \
  -H 'Content-Type: application/json' \
  -d '{
    "event": {
      "orderId": "ORD-SI-001",
      "amount": 5000,
      "customerId": "CUST-S1",
      "channel": "web",
      "correlationId": "si-cid-001"
    }
  }'
```

What happens:

* event is normalized
* no anomaly rule matches

Expected:

* accepted by SI, no anomaly actions fired.

---

### Immediate high-value anomaly

```bash
curl -s -X POST http://localhost:8007/OrderEvents \
  -H 'Content-Type: application/json' \
  -d '{
    "event": {
      "orderId": "ORD-SI-HIGH-001",
      "amount": 150000,
      "customerId": "CUST-S2",
      "channel": "mobile",
      "correlationId": "si-cid-high-001"
    }
  }'
```

What happens:

* SI emits `SINGLE_HIGH_VALUE`
* logs anomaly
* calls MI `/review`
* posts event to BI `/bi/events/anomaly`

Expected:

* anomaly side effects across MI and BI.

---

### Burst anomaly

Run these three within the same 2-minute window:

```bash
curl -s -X POST http://localhost:8007/OrderEvents \
  -H 'Content-Type: application/json' \
  -d '{
    "event": {
      "orderId": "ORD-SI-B1",
      "amount": 12000,
      "customerId": "CUST-BURST",
      "channel": "web",
      "correlationId": "burst-1"
    }
  }'
```

```bash
curl -s -X POST http://localhost:8007/OrderEvents \
  -H 'Content-Type: application/json' \
  -d '{
    "event": {
      "orderId": "ORD-SI-B2",
      "amount": 13000,
      "customerId": "CUST-BURST",
      "channel": "web",
      "correlationId": "burst-2"
    }
  }'
```

```bash
curl -s -X POST http://localhost:8007/OrderEvents \
  -H 'Content-Type: application/json' \
  -d '{
    "event": {
      "orderId": "ORD-SI-B3",
      "amount": 14000,
      "customerId": "CUST-BURST",
      "channel": "web",
      "correlationId": "burst-3"
    }
  }'
```

What happens:

* when the 2-minute batch closes, Siddhi emits one `BURST_HIGH_VALUE` anomaly for that customer/channel group
* SI posts it to MI review and BI ingestion

Expected:

* one burst anomaly event after batch close.

---

### SI normalization with missing optional fields

```bash
curl -s -X POST http://localhost:8007/OrderEvents \
  -H 'Content-Type: application/json' \
  -d '{
    "event": {
      "orderId": "",
      "amount": 20000,
      "customerId": "",
      "channel": "",
      "correlationId": ""
    }
  }'
```

What happens:

* SI normalizes blanks into fallback values:

  * `orderId = "UNKNOWN"`
  * `customerId = "ANON"`
  * `channel = "unknown"`

Expected:

* accepted event; may still contribute to anomalies.

---

## 4️⃣ Business Integrator

### BI health

```bash
curl -s http://localhost:9090/bi/health
```

Expected:

* `status: "OK"`

---

### Direct BI anomaly ingestion

```bash
curl -s -X POST http://localhost:9090/bi/events/anomaly \
  -H 'Content-Type: application/json' \
  -H "x-correlation-id: $CID" \
  -d '{
    "anomalyType": "SINGLE_HIGH_VALUE",
    "orderId": "ORD-BI-ANOM-001",
    "amount": 120000,
    "customerId": "CUST-BI",
    "channel": "web",
    "correlationId": "bi-anom-001",
    "eventCount": 1,
    "windowStartTime": 1740000000
  }'
```

What happens:

* BI stores the anomaly in its bounded buffer

Expected:

* HTTP `202`
* response with updated `buffered` count

---

### Latest JSON report

```bash
curl -s http://localhost:9090/bi/reports/latest
```

What happens:

* returns the most recent generated reconciliation report

Expected:

* report JSON if a reconciliation tick has already run
* `404` if not generated yet

---

### Latest CSV report

```bash
curl -s http://localhost:9090/bi/reports/latestCsv
```

Expected:

* CSV report or `404` if not yet generated

---

### BI AI review with OpenAI

```bash
curl -s -X POST http://localhost:9090/bi/ai/review \
  -H 'Content-Type: application/json' \
  -H "x-correlation-id: $CID" \
  -d '{
    "orderId": "ORD-AI-001",
    "amount": 15000,
    "customerId": "CUST-AI",
    "channel": "web"
  }'
```

What happens:

* BI validates input
* calls CRM
* reads rolling anomaly stats
* asks OpenAI for a structured recommendation
* may optionally call MI review if action is escalation

Expected:

* `RECOMMENDATION_READY`
* includes:

  * `risk`
  * `recommendedAction`
  * `rationale`
  * `crm`
  * optional `miReview`
  * `decisionMode`

---

### BI AI review with fallback rules

If `OPENAI_API_KEY` is empty:

```bash
curl -s -X POST http://localhost:9090/bi/ai/review \
  -H 'Content-Type: application/json' \
  -d '{
    "orderId": "ORD-AI-FALLBACK-001",
    "amount": 105000,
    "customerId": "CUST-AI2",
    "channel": "web"
  }'
```

What happens:

* OpenAI call fails or is skipped
* fallback deterministic rules decide:

  * high-value single order => `HIGH`
  * action => `TRIGGER_MI_REVIEW`

Expected:

* response with `decisionMode: "FALLBACK_RULES"` and likely `miReview`.

---

### BI AI review medium-risk case

```bash
curl -s -X POST http://localhost:9090/bi/ai/review \
  -H 'Content-Type: application/json' \
  -d '{
    "orderId": "ORD-AI-FALLBACK-002",
    "amount": 15000,
    "customerId": "CUST-AI3",
    "channel": "mobile"
  }'
```

Expected:

* medium risk style outcome, often `ALLOW_BUT_MONITOR`.

---

### BI AI review invalid request

```bash
curl -s -i -X POST http://localhost:9090/bi/ai/review \
  -H 'Content-Type: application/json' \
  -d '{
    "orderId": "",
    "amount": 0
  }'
```

Expected:

* HTTP `400`
* invalid payload message

---

### Conversational agent

```bash
curl -s -X POST http://localhost:9090/agente/chat \
  -H 'Content-Type: application/json' \
  -d '{
    "message": "Summarize the BI anomaly handling flow in one paragraph",
    "sessionId": "demo-session-1"
  }'
```

What happens:

* BI agent sends the prompt through the configured AI model provider using session memory.

Expected:

* a chat response payload with a generated answer.

---

## 5️⃣ End-to-End Scenario Tests

### v1 order with async shipping

```bash
curl -s -X POST http://localhost:8290/v1/orders \
  -H 'Content-Type: application/json' \
  -H 'x-correlation-id: e2e-v1-001' \
  -d '{
    "orderId": "ORD-E2E-V1",
    "amount": 18000,
    "customerId": "CUST-E2E",
    "channel": "web"
  }'
```

Expected:

* immediate accepted response
* shipping continues asynchronously

---

### v2 non-premium

```bash
curl -s -X POST http://localhost:8290/v2/orders \
  -H 'Content-Type: application/json' \
  -H 'x-correlation-id: e2e-v2-001' \
  -d '{
    "orderId": "ORD-E2E-V2-LOW",
    "amount": 3000,
    "customerId": "CUST-E2E2",
    "channel": "mobile"
  }'
```

Expected:

* ERP + CRM only
* shipping skipped

---

### SI anomaly → MI review + BI ingest

```bash
curl -s -X POST http://localhost:8007/OrderEvents \
  -H 'Content-Type: application/json' \
  -d '{
    "event": {
      "orderId": "ORD-E2E-SI-1",
      "amount": 125000,
      "customerId": "CUST-ANOM",
      "channel": "web",
      "correlationId": "e2e-si-001"
    }
  }'
```

Expected:

* SI emits anomaly
* MI review invoked
* BI anomaly stored
* later BI reports reflect the anomaly

---

### Shipping retry story

```bash
curl -s -X POST http://localhost:8081/admin/shipping/fail \
  -H 'Content-Type: application/json' \
  -d '{"enabled": true}'
```

```bash
curl -s -X POST http://localhost:8290/v1/orders \
  -H 'Content-Type: application/json' \
  -H 'x-correlation-id: e2e-ship-retry-1' \
  -d '{
    "orderId": "ORD-SHIP-RETRY",
    "amount": 22000,
    "customerId": "CUST-RETRY",
    "channel": "web"
  }'
```

```bash
curl -s -X POST http://localhost:8081/admin/shipping/fail \
  -H 'Content-Type: application/json' \
  -d '{"enabled": false}'
```

What happens:

* original order response is still immediate
* shipping dispatch fails in the background while shipping is unhealthy
* MI message processor retries until shipping recovers

Expected:

* eventual successful async shipping after retries

---

## 6️⃣ Useful Log Tail

```bash
docker compose logs -f mock-backend mi si bi
```

This is the best way to observe:

* correlation ID propagation
* SI anomaly detection
* MI review calls
* BI anomaly ingestion
* shipping retries/faults

---

# 🔐 OpenAI (Optional)

To enable AI decision support, set in `demo-bi/Config.toml`:

```toml
OPENAI_API_KEY = "your-key-here"
```

If left empty, BI automatically falls back to deterministic rules.

---

# 📁 Generated Reports

BI automation writes to:

```text
demo-bi-data/reports/latest.json
demo-bi-data/reports/latest.csv
```

It also writes timestamped historical JSON snapshots in the same reports directory.

---

# 🧱 Common Troubleshooting

### BI fails because `Config.toml` is missing

Ensure this file exists:

```text
demo-bi/Config.toml
```

---

### ICP does not show the dashboard properly

Use:

```text
https://localhost:9743/dashboard
```

---

### SI seems to “delay” burst anomalies

That is expected. Burst anomalies are based on a `timeBatch(2 min)` window and are emitted when the batch closes.

---

### Shipping seems missing from MI response

That is expected. Shipping is asynchronous and decoupled from the synchronous order API response.

---

### BI reports return 404

Wait for the first reconciliation tick, or reduce `RECON_INTERVAL_SECONDS` in BI config.

---

# 🧠 Architectural Significance

This demo is intentionally designed to show:

* API orchestration with controlled failure handling
* asynchronous backend resiliency
* real-time stateful streaming intelligence
* event-driven integration
* AI-assisted review decisions
* scheduled reconciliation and reporting
* unified visibility across heterogeneous runtimes