import ballerina/http;
import ballerina/time;
import ballerina/file;
import ballerina/uuid;
import ballerina/lang.'float as fl;
import ballerina/lang.'int as intlang;

// ---------------------------
// Isolated anomaly store
// ---------------------------
isolated class AnomalyStore {
    private AnomalyEvent[] buffer = [];

    isolated function store(
        string anomalyType,
        string orderId,
        float amount,
        string customerId,
        string channel,
        string correlationId,
        int eventCount,
        int windowStartTime,
        int receivedAt,
        int maxSize
    ) {
        lock {
            AnomalyEvent ev = {
                anomalyType: anomalyType,
                orderId: orderId,
                amount: amount,
                customerId: customerId,
                channel: channel,
                correlationId: correlationId,
                eventCount: eventCount,
                windowStartTime: windowStartTime,
                receivedAt: receivedAt
            };

            self.buffer.push(ev);

            if self.buffer.length() > maxSize {
                int n = self.buffer.length();
                self.buffer = self.buffer.slice(n - maxSize, n);
            }
        }
    }

    isolated function size() returns int {
        lock {
            return self.buffer.length();
        }
    }

    isolated function recentStats(string customerId, string channel, int minutes) returns AnomalyStats {
        int cutoff = nowEpochSeconds() - (minutes * 60);
        int total = 0;
        int high = 0;

        lock {
            foreach var ev in self.buffer {
                if ev.receivedAt < cutoff {
                    continue;
                }
                boolean custOk = (customerId == "*") || (ev.customerId == customerId);
                boolean chOk = (channel == "*") || (ev.channel == channel);

                if custOk && chOk {
                    total += 1;
                    if ev.anomalyType == "SINGLE_HIGH_VALUE" || ev.anomalyType == "BURST_HIGH_VALUE" {
                        high += 1;
                    }
                }
            }
        }

        return { total: total, highRisk: high };
    }

    isolated function topCustomers(int minutes) returns json {
        int cutoff = nowEpochSeconds() - (minutes * 60);
        map<int> counts = {};

        lock {
            foreach var ev in self.buffer {
                if ev.receivedAt < cutoff {
                    continue;
                }
                string key = ev.customerId + "|" + ev.channel;
                counts[key] = (counts[key] ?: 0) + 1;
            }
        }

        json[] out = [];
        foreach var [k, v] in counts.entries() {
            int? sepOpt = k.indexOf("|");

            string cust = "ANON";
            string ch = "unknown";

            if sepOpt is int {
                int sep = sepOpt;
                cust = k.substring(0, sep);
                if sep + 1 < k.length() {
                    ch = k.substring(sep + 1);
                }
            } else {
                cust = k;
            }

            out.push({ customerId: cust, channel: ch, anomalies: v });
        }
        return out;
    }
}

// ---------------------------
// Report formatting
// ---------------------------
isolated function reportToCsv(Report r) returns string {
    return string `reportId,generatedAt,anomalyBufferSize,anomaliesLast15m,highRiskLast15m
${r.reportId},${r.generatedAt},${r.anomalyBufferSize},${r.anomaliesLast15m},${r.highRiskAnomaliesLast15m}
`;
}

// ---------------------------
// HTTP helpers (isolated for automation path)
// ---------------------------
isolated function correlationHeaders(string cid) returns map<string|string[]> {
    return {
        "x-correlation-id": cid,
        "x-request-id": cid
    };
}

isolated function getJson(http:Client c, string path, string cid) returns json|error {
    http:Response resp = check c->get(path, headers = correlationHeaders(cid));
    return check resp.getJsonPayload();
}

// These two are used from HTTP resources (non-isolated), so they can remain non-isolated.
function callCrm(OrderRequest ordReq, string cid) returns json|error {
    http:Request r = new;
    r.setJsonPayload({
        orderId: ordReq.orderId,
        amount: ordReq.amount,
        customerId: ordReq.customerId ?: "ANON",
        channel: ordReq.channel ?: "unknown"
    });
    setCorrelationHeaders(r, cid);

    http:Response resp = check mockClient->post("/crm/normal", r);
    return check resp.getJsonPayload();
}

function triggerMiReview(OrderRequest ordReq, string cid, string risk, AnomalyStats stats) returns json|error {
    http:Request r = new;
    r.setJsonPayload({
        orderId: ordReq.orderId,
        amount: ordReq.amount,
        reason: risk,
        anomalyContext: { anomaliesLast15m: stats.total, highRiskLast15m: stats.highRisk }
    });
    setCorrelationHeaders(r, cid);

    http:Response resp = check miApiClient->post("/review", r);
    return check resp.getJsonPayload();
}

function setCorrelationHeaders(http:Request r, string cid) {
    r.setHeader("x-correlation-id", cid);
    r.setHeader("x-request-id", cid);
}

// ---------------------------
// Correlation ID extraction
// ---------------------------
function getCorrelationId(http:Request req) returns string {
    string? cid = headerAsString(req, "x-correlation-id");
    if cid is string && cid.trim().length() > 0 {
        return cid;
    }
    cid = headerAsString(req, "x-request-id");
    if cid is string && cid.trim().length() > 0 {
        return cid;
    }
    cid = headerAsString(req, "x-b3-traceid");
    if cid is string && cid.trim().length() > 0 {
        return cid;
    }
    return uuid:createType1AsString();
}

function headerAsString(http:Request req, string name) returns string? {
    var h = req.getHeader(name);
    return h is string ? h : ();
}

// ---------------------------
// Normalize anomaly JSON from SI
// ---------------------------
function normalizeAnomaly(json payload, string fallbackCid) returns AnomalyEvent {
    string anomalyType = jsonToString(payload, "anomalyType", "UNKNOWN");
    string orderId = jsonToString(payload, "orderId", "UNKNOWN");
    float amount = jsonToFloat(payload, "amount", 0.0);
    string customerId = jsonToString(payload, "customerId", "ANON");
    string channel = jsonToString(payload, "channel", "unknown");
    string correlationId = jsonToString(payload, "correlationId", fallbackCid);
    int eventCount = jsonToInt(payload, "eventCount", 1);
    int windowStartTime = jsonToInt(payload, "windowStartTime", nowEpochSeconds());

    return {
        anomalyType: anomalyType,
        orderId: orderId,
        amount: amount,
        customerId: customerId,
        channel: channel,
        correlationId: correlationId,
        eventCount: eventCount,
        windowStartTime: windowStartTime,
        receivedAt: nowEpochSeconds()
    };
}

function jsonToOptString(json j, string k) returns string? {
    if j is map<json> {
        json? v = j[k];
        if v is string && v.trim().length() > 0 {
            return v;
        }
    }
    return ();
}

function jsonToString(json j, string k, string def) returns string {
    string? s = jsonToOptString(j, k);
    return s ?: def;
}

function jsonToFloat(json j, string k, float def) returns float {
    if j is map<json> {
        json? v = j[k];
        if v is float {
            return v;
        }
        if v is int {
            return <float>v;
        }
        if v is decimal {
            return <float>v;
        }
        if v is string {
            var p = fl:fromString(v);
            if p is float {
                return p;
            }
        }
    }
    return def;
}

function jsonToInt(json j, string k, int def) returns int {
    if j is map<json> {
        json? v = j[k];
        if v is int {
            return v;
        }
        if v is float {
            return <int>v;
        }
        if v is decimal {
            return <int>v;
        }
        if v is string {
            var p = intlang:fromString(v);
            if p is int {
                return p;
            }
        }
    }
    return def;
}

// ---------------------------
// File/Dir helpers (isolated for automation path)
// ---------------------------
isolated function ensureReportDir() returns error? {
    boolean exists = check file:test(REPORT_DIR, file:EXISTS);
    if !exists {
        check file:createDir(REPORT_DIR, file:RECURSIVE);
    }
    return ();
}

isolated function safeStamp() returns string {
    time:Civil c = time:utcToCivil(time:utcNow());
    int sec = <int>((c.second ?: 0.0));
    return string `${c.year}${pad2(c.month)}${pad2(c.day)}-${pad2(c.hour)}${pad2(c.minute)}${pad2(sec)}Z`;
}

isolated function pad2(int n) returns string =>
    n < 10 ? "0" + n.toString() : n.toString();

// ---------------------------
// Time helpers (isolated for automation path)
// ---------------------------
isolated function nowEpochSeconds() returns int {
    return time:utcNow()[0];
}

isolated function nowIso() returns string {
    return time:utcToString(time:utcNow());
}


// Extract first output_text from Responses API result
function extractFirstOutputText(json respJson) returns string? {

    if respJson is map<json> {

        json? out = respJson["output"];
        if out is json[] {

            foreach var item in out {
                if item is map<json> {

                    json? content = item["content"];
                    if content is json[] {

                        foreach var c in content {
                            if c is map<json> {

                                json? t = c["type"];
                                if t is string && t == "output_text" {

                                    json? txt = c["text"];
                                    if txt is string {
                                        return txt;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    return ();
}