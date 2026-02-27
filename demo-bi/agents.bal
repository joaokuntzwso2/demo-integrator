import ballerina/http;

function callOpenAiDecision(OrderRequest ordReq, json crm, AnomalyStats stats, string cid) returns AiDecision|error {
    if OPENAI_API_KEY.trim().length() == 0 {
        return error("OPENAI_API_KEY not set");
    }

    string instructions =
        "You are a fraud-risk decision agent for an order review API. " +
        "Return ONLY JSON that matches the provided schema. " +
        "Prefer conservative decisions when risk signals exist.";

    // IMPORTANT for Ballerina: quote JSON keys like "type" because `type` is a keyword.
    json schema = {
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "risk": {
                "type": "string",
                "enum": ["LOW", "MEDIUM", "HIGH"]
            },
            "recommendedAction": {
                "type": "string",
                "enum": ["ALLOW", "ALLOW_BUT_MONITOR", "TRIGGER_MI_REVIEW"]
            },
            "rationale": {
                "type": "string"
            }
        },
        "required": ["risk", "recommendedAction", "rationale"]
    };

    json input = [
        {
            "role": "user",
            "content": [
                {
                    "type": "input_text",
                    "text": string `Decide risk and action for this order.

Order:
${ordReq.toJsonString()}

CRM:
${crm.toJsonString()}

Anomaly stats (last 15m):
{"total": ${stats.total}, "highRisk": ${stats.highRisk}}

Policy:
- HIGH if amount >= 100000 OR highRisk anomalies >= 3
- MEDIUM if amount >= 10000
- Else LOW
Actions:
- HIGH => TRIGGER_MI_REVIEW
- MEDIUM => ALLOW_BUT_MONITOR
- LOW => ALLOW

Return a short rationale.`
                }
            ]
        }
    ];

    http:Request req = new;
    req.setHeader("authorization", "Bearer " + OPENAI_API_KEY);
    req.setHeader("content-type", "application/json");
    req.setHeader("x-correlation-id", cid);

    // setJsonPayload() is not error-returning in this distribution, so `check` is invalid.
    req.setJsonPayload({
        "model": OPENAI_MODEL,
        "instructions": instructions,
        "input": input,
        "temperature": OPENAI_TEMPERATURE,
        "text": {
            "format": {
                "type": "json_schema",
                "name": "ai_decision",
                "strict": true,
                "schema": schema
            }
        }
    });

    http:Response resp = check openaiClient->post("/responses", req);
    json respJson = check resp.getJsonPayload();

    string? decisionText = extractFirstOutputText(respJson);
    if decisionText is () {
        return error("OpenAI response missing output_text");
    }

    json decisionJson = check decisionText.fromJsonString();
    AiDecision decision = check decisionJson.cloneWithType(AiDecision);

    // Final guardrails (defensive)
    if !(decision.risk == "LOW" || decision.risk == "MEDIUM" || decision.risk == "HIGH") {
        return error("Invalid risk from OpenAI");
    }
    if !(decision.recommendedAction == "ALLOW" ||
         decision.recommendedAction == "ALLOW_BUT_MONITOR" ||
         decision.recommendedAction == "TRIGGER_MI_REVIEW") {
        return error("Invalid recommendedAction from OpenAI");
    }
    if decision.rationale.trim().length() == 0 {
        return error("Empty rationale from OpenAI");
    }

    return decision;
}