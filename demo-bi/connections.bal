import ballerina/ai;
import ballerinax/ai.openai;

final ai:ModelProvider agenteModel = check new openai:ModelProvider(
    OPENAI_API_KEY,
    modelType = openai:GPT_4O
);