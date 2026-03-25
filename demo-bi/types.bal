type OrderRequest record {|
    string orderId;
    float amount;
    string? customerId;
    string? channel;
|};

type AnomalyEvent record {|
    string anomalyType;
    string orderId;
    float amount;
    string customerId;
    string channel;
    string correlationId;
    int eventCount;
    int windowStartTime;
    int receivedAt;
|};

type AnomalyStats record {|
    int total;
    int highRisk;
|};

type Report record {|
    string reportId;
    string generatedAt;
    int anomalyBufferSize;
    int anomaliesLast15m;
    int highRiskAnomaliesLast15m;
    json backendState;
    json miReadiness;
    json miLiveness;
    json topCustomers;
|};

type AiDecision record {|
    string risk;
    string recommendedAction;
    string rationale;
|};