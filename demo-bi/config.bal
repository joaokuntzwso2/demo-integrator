// ---------------------------
// Config (set via env vars in docker-compose)
// ---------------------------
configurable string MOCK_BASE_URL = "http://mock-backend:8081";
configurable string MI_RUNTIME_URL = "http://mi:9201";   // /healthz, /liveness
configurable string MI_API_URL = "http://mi:8290";       // /review
configurable int BI_PORT = 9090;

configurable int RECON_INTERVAL_SECONDS = 300;           // 5 minutes
configurable int ANOMALY_BUFFER_MAX = 500;
configurable string REPORT_DIR = "/data/reports";

// ---------------------------
// OpenAI (Responses API)
// ---------------------------
configurable string OPENAI_BASE_URL = "https://api.openai.com/v1";
public configurable string OPENAI_API_KEY = "";
configurable string OPENAI_MODEL = "gpt-4o";
configurable decimal OPENAI_TEMPERATURE = 0.2;