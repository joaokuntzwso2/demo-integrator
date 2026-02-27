import ballerina/http;
import ballerinax/wso2.controlplane as _;

// HTTP clients (shared by services + automation)
final http:Client mockClient = check new (MOCK_BASE_URL, { timeout: 5 });
final http:Client miRuntimeClient = check new (MI_RUNTIME_URL, { timeout: 3 });
final http:Client miApiClient = check new (MI_API_URL, { timeout: 5 });

final http:Client openaiClient = check new (OPENAI_BASE_URL, { timeout: 20 });

// Shared isolated store
final AnomalyStore anomalyStore = new;