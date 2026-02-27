const express = require("express");
const morgan = require("morgan");
const { v4: uuidv4 } = require("uuid");

const app = express();
app.use(express.json({ limit: "1mb" }));

/**
 * Failure/latency controls (can be toggled via admin endpoints)
 */
const state = {
  erp: { fail: false, slowMs: 10_000 },
  crm: { fail: false, slowMs: 10_000 },
  shipping: { fail: false, slowMs: 10_000 }
};

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Correlation ID middleware:
 * - Accepts common correlation headers if present
 * - Otherwise creates a new one
 * - Echoes it back in response
 */
app.use((req, res, next) => {
  const existing =
    req.header("x-correlation-id") ||
    req.header("x-request-id") ||
    req.header("x-b3-traceid");

  req.correlationId = existing || uuidv4();
  res.setHeader("x-correlation-id", req.correlationId);
  next();
});

morgan.token("cid", (req) => req.correlationId);
app.use(
  morgan(
    ':date[iso] :method :url :status :res[content-length] - :response-time ms cid=:cid'
  )
);

/**
 * Helpers to standardize responses
 */
function ok(service, operation, details) {
  return {
    service,
    operation,
    status: "OK",
    timestamp: new Date().toISOString(),
    ...details
  };
}

function problem(service, operation, message, extra = {}) {
  return {
    service,
    operation,
    status: "ERROR",
    timestamp: new Date().toISOString(),
    message,
    ...extra
  };
}

/**
 * Admin endpoints: toggle fail mode / configure slow latency
 * Example:
 *  POST /admin/erp/fail { "enabled": true }
 *  POST /admin/shipping/slow { "ms": 15000 }
 */
app.post("/admin/:svc/fail", (req, res) => {
  const svc = req.params.svc;
  if (!state[svc]) return res.status(404).json({ error: "Unknown service" });

  const enabled = !!req.body.enabled;
  state[svc].fail = enabled;

  res.json(
    ok("admin", "setFailMode", {
      target: svc,
      fail: state[svc].fail
    })
  );
});

app.post("/admin/:svc/slow", (req, res) => {
  const svc = req.params.svc;
  if (!state[svc]) return res.status(404).json({ error: "Unknown service" });

  const ms = Number(req.body.ms);
  if (!Number.isFinite(ms) || ms < 0)
    return res.status(400).json({ error: "Invalid ms" });

  state[svc].slowMs = ms;

  res.json(
    ok("admin", "setSlowLatency", {
      target: svc,
      slowMs: state[svc].slowMs
    })
  );
});

app.get("/admin/state", (_req, res) => {
  res.json(ok("admin", "getState", { state }));
});

/**
 * Health
 */
app.get("/health", (_req, res) => {
  res.json(
    ok("mock-backend", "health", {
      uptimeSec: Math.round(process.uptime()),
      state
    })
  );
});

/**
 * Shared handler builder for each mock service group
 */
function buildServiceRouter(serviceName) {
  const router = express.Router();

  // Normal endpoint (fast)
  router.post("/normal", async (req, res) => {
    const operation = "normal";
    if (state[serviceName].fail) {
      return res
        .status(503)
        .json(problem(serviceName, operation, "Service in fail mode", { cid: req.correlationId }));
    }

    const payload = req.body || {};
    res.json(
      ok(serviceName, operation, {
        cid: req.correlationId,
        request: payload,
        result: synthesizeResult(serviceName, payload)
      })
    );
  });

  // Slow endpoint (default 10s)
  router.post("/slow", async (req, res) => {
    const operation = "slow";
    if (state[serviceName].fail) {
      return res
        .status(503)
        .json(problem(serviceName, operation, "Service in fail mode", { cid: req.correlationId }));
    }

    const payload = req.body || {};
    await sleep(state[serviceName].slowMs);

    res.json(
      ok(serviceName, operation, {
        cid: req.correlationId,
        sleptMs: state[serviceName].slowMs,
        request: payload,
        result: synthesizeResult(serviceName, payload)
      })
    );
  });

  // Simple GET for quick manual test
  router.get("/ping", (req, res) => {
    if (state[serviceName].fail) {
      return res
        .status(503)
        .json(problem(serviceName, "ping", "Service in fail mode", { cid: req.correlationId }));
    }

    res.json(ok(serviceName, "ping", { cid: req.correlationId }));
  });

  return router;
}

/**
 * Deterministic fake backend results that look realistic in demo aggregations
 */
function synthesizeResult(serviceName, payload) {
  const orderId = payload.orderId || payload.id || "UNKNOWN";
  const amount = Number(payload.amount ?? payload.total ?? 0);

  if (serviceName === "erp") {
    return {
      erpOrderRef: `ERP-${orderId}`,
      creditStatus: amount > 50_000 ? "REQUIRES_APPROVAL" : "APPROVED",
      warehouse: amount > 5_000 ? "WH-PREMIUM" : "WH-STANDARD"
    };
  }

  if (serviceName === "crm") {
    return {
      customerTier: amount > 10_000 ? "GOLD" : "STANDARD",
      loyaltyId: payload.customerId ? `LOY-${payload.customerId}` : "LOY-ANON",
      flaggedCustomer: amount > 100_000 // exaggerate for anomaly story
    };
  }

  if (serviceName === "shipping") {
    return {
      carrier: amount > 10_000 ? "FAST_SHIP" : "ECONOMY_SHIP",
      etaDays: amount > 10_000 ? 1 : 3,
      trackingSeed: `TRK-${orderId}-${Math.floor(Math.random() * 10000)}`
    };
  }

  return { echo: payload };
}

// Mount service routers
app.use("/erp", buildServiceRouter("erp"));
app.use("/crm", buildServiceRouter("crm"));
app.use("/shipping", buildServiceRouter("shipping"));

/**
 * Error handler (keeps responses JSON so MI aggregation is clean)
 */
app.use((err, req, res, _next) => {
  console.error("Unhandled error cid=", req.correlationId, err);
  res.status(500).json(problem("mock-backend", "unhandled", err.message, { cid: req.correlationId }));
});

const PORT = process.env.PORT || 8081;
app.listen(PORT, () => {
  console.log(`Mock backend listening on port ${PORT}`);
  console.log("Routes:");
  console.log("  POST /erp/normal   POST /erp/slow");
  console.log("  POST /crm/normal   POST /crm/slow");
  console.log("  POST /shipping/normal POST /shipping/slow");
  console.log("  POST /admin/:svc/fail  POST /admin/:svc/slow  GET /admin/state");
});
