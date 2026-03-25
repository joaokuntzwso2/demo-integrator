import ballerina/http;

// Shared listeners/clients
listener http:Listener biListener = new (BI_PORT);

final http:Client mockClient = check new (MOCK_BASE_URL, {timeout: 5});
final http:Client miRuntimeClient = check new (MI_RUNTIME_URL, {timeout: 3});
final http:Client miApiClient = check new (MI_API_URL, {timeout: 5});
final http:Client openaiClient = check new (OPENAI_BASE_URL, {timeout: 20});

final AnomalyStore anomalyStore = new;