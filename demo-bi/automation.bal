import ballerina/time;
import ballerina/io;
import ballerina/uuid;
import ballerina/task;

final time:Utc reconStartUtc = time:utcAddSeconds(time:utcNow(), <decimal>10);
final time:Civil reconStart = time:utcToCivil(reconStartUtc);

listener task:Listener reconListener = new (
    trigger = {
        interval: <decimal>RECON_INTERVAL_SECONDS,
        startTime: reconStart
    }
);

service "bi-reconciliation" on reconListener {
    isolated function execute() returns error? {
        _ = start reconciliationWorker();
        return ();
    }
}

isolated function reconciliationWorker() {
    error? e = generateReportTick();
    if e is error {
        io:println("[BI] reconciliation tick failed: ", e.message());
    }
}

isolated function generateReportTick() returns error? {
    check ensureReportDir();

    string rid = uuid:createType1AsString();
    string now = nowIso();

    json backendState = check getJson(mockClient, "/admin/state", rid);
    json miReady = check getJson(miRuntimeClient, "/healthz", rid);
    json miLive = check getJson(miRuntimeClient, "/liveness", rid);

    AnomalyStats globalStats = anomalyStore.recentStats("*", "*", 15);
    json topCustomers = anomalyStore.topCustomers(15);

    Report report = {
        reportId: rid,
        generatedAt: now,
        anomalyBufferSize: anomalyStore.size(),
        anomaliesLast15m: globalStats.total,
        highRiskAnomaliesLast15m: globalStats.highRisk,
        backendState: backendState,
        miReadiness: miReady,
        miLiveness: miLive,
        topCustomers: topCustomers
    };

    string jsonOut = report.toJsonString();
    string csvOut = reportToCsv(report);

    string stamp = safeStamp();
    string fileJson = REPORT_DIR + "/report-" + stamp + ".json";

    check io:fileWriteString(fileJson, jsonOut);
    check io:fileWriteString(REPORT_DIR + "/latest.json", jsonOut);
    check io:fileWriteString(REPORT_DIR + "/latest.csv", csvOut);

    return ();
}