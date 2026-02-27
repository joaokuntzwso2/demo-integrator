import ballerina/http;
import ballerina/log;
import ballerina/io;

service /bi on new http:Listener(BI_PORT) {

    resource function get health() returns json {
        return { status: "OK", runtime: "BI", time: nowIso() };
    }

    // POST /bi/events/anomaly
    resource function post events/anomaly(http:Request req) returns http:Response|error {
        string cid = getCorrelationId(req);

        json payload = check req.getJsonPayload();
        AnomalyEvent ev = normalizeAnomaly(payload, cid);

        anomalyStore.store(
            ev.anomalyType,
            ev.orderId,
            ev.amount,
            ev.customerId,
            ev.channel,
            ev.correlationId,
            ev.eventCount,
            ev.windowStartTime,
            ev.receivedAt,
            ANOMALY_BUFFER_MAX
        );

        _ = log:printInfo("BI_EVENT_INGESTED",
            correlationId = cid,
            anomalyType = ev.anomalyType,
            customerId = ev.customerId,
            channel = ev.channel,
            amount = ev.amount,
            buffered = anomalyStore.size()
        );

        http:Response res = new;
        res.statusCode = 202;
        res.setHeader("x-correlation-id", cid);
        res.setJsonPayload({
            status: "ACCEPTED",
            correlationId: cid,
            buffered: anomalyStore.size()
        });
        return res;
    }

    // GET /bi/reports/latest
    resource function get reports/latest() returns http:Response {
        http:Response res = new;
        string path = REPORT_DIR + "/latest.json";

        var content = io:fileReadString(path);
        if content is error {
            res.statusCode = 404;
            res.setJsonPayload({ status: "NOT_FOUND", message: "No report generated yet" });
            return res;
        }

        res.statusCode = 200;
        res.setHeader("content-type", "application/json");
        res.setPayload(content);
        return res;
    }

    // GET /bi/reports/latestCsv
    resource function get reports/latestCsv() returns http:Response {
        http:Response res = new;
        string path = REPORT_DIR + "/latest.csv";

        var content = io:fileReadString(path);
        if content is error {
            res.statusCode = 404;
            res.setHeader("content-type", "text/plain");
            res.setPayload("No CSV report generated yet\n");
            return res;
        }

        res.statusCode = 200;
        res.setHeader("content-type", "text/csv");
        res.setPayload(content);
        return res;
    }

    // POST /bi/ai/review
    resource function post ai/review(http:Request req) returns http:Response|error {
        string cid = getCorrelationId(req);

        json body = check req.getJsonPayload();

        OrderRequest ordReq = {
            orderId: jsonToString(body, "orderId", ""),
            amount: jsonToFloat(body, "amount", 0.0),
            customerId: jsonToOptString(body, "customerId"),
            channel: jsonToOptString(body, "channel")
        };

        if ordReq.orderId.trim().length() == 0 || ordReq.amount <= 0.0 {
            http:Response bad = new;
            bad.statusCode = 400;
            bad.setHeader("x-correlation-id", cid);
            bad.setJsonPayload({
                status: "INVALID",
                correlationId: cid,
                message: "orderId must be non-empty and amount must be > 0"
            });
            return bad;
        }

        // External context (mock CRM)
        json crm = check callCrm(ordReq, cid);

        // Local anomaly context
        string customerId = ordReq.customerId ?: "ANON";
        string channel = ordReq.channel ?: "unknown";
        AnomalyStats stats = anomalyStore.recentStats(customerId, channel, 15);

        // --- Decision via OpenAI agent (with fallback rules) ---
        string risk = "LOW";
        string action = "ALLOW";
        string rationale = "No risk indicators.";
        string decisionMode = "FALLBACK_RULES";

        AiDecision|error ai = callOpenAiDecision(ordReq, crm, stats, cid);
        if ai is AiDecision {
            risk = ai.risk;
            action = ai.recommendedAction;
            rationale = ai.rationale;
            decisionMode = "OPENAI_AGENT";
        } else {
            _ = log:printWarn("OpenAI decision failed; falling back to rules",
                correlationId = cid,
                errorMessage = ai.message()
            );

            boolean singleHigh = ordReq.amount >= 100000.0;
            boolean burst = stats.highRisk >= 3 || stats.total >= 3;

            if singleHigh {
                risk = "HIGH";
                action = "TRIGGER_MI_REVIEW";
                rationale = "Single high-value order (>=100000).";
            } else if burst {
                risk = "HIGH";
                action = "TRIGGER_MI_REVIEW";
                rationale = "Burst anomaly detected for customer/channel in last 15 minutes.";
            } else if ordReq.amount >= 10000.0 {
                risk = "MEDIUM";
                action = "ALLOW_BUT_MONITOR";
                rationale = "Premium amount; proceed but monitor.";
            }
        }

        // Act: trigger MI review only when recommended
        json? miReview = ();
        if action == "TRIGGER_MI_REVIEW" {
            miReview = check triggerMiReview(ordReq, cid, risk, stats);
        }

        http:Response res = new;
        res.statusCode = 200;
        res.setHeader("x-correlation-id", cid);
        res.setJsonPayload({
            status: "RECOMMENDATION_READY",
            correlationId: cid,
            orderReq: ordReq,
            risk: risk,
            recommendedAction: action,
            rationale: rationale,
            anomalyContext: { totalLast15m: stats.total, highRiskLast15m: stats.highRisk },
            crm: crm,
            miReview: miReview,
            decisionMode: decisionMode
        });
        return res;
    }
}