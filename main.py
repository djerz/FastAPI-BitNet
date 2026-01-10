from fastapi import FastAPI, Request
import httpx

app = FastAPI()

BITNET_COMPLETION_URL = "http://127.0.0.1:5000/completion"  # BitNet server port inside container

def messages_to_prompt(messages):
    parts = []
    for m in messages:
        role = m.get("role", "user")
        content = m.get("content", "")
        parts.append(f"{role}: {content}")
    return "\n".join(parts) + "\nassistant: "

@app.get("/health")
def health():
    return {"status": "ok"}

@app.get("/v1/models")
def models():
    return {"data": [{"id": "bitnet", "object": "model"}], "object": "list"}

@app.post("/v1/chat/completions")
async def chat_completions(req: Request):
    body = await req.json()
    prompt = messages_to_prompt(body.get("messages", []))

    async with httpx.AsyncClient(timeout=600) as client:
        r = await client.post(BITNET_COMPLETION_URL, json={"prompt": prompt})
        r.raise_for_status()
        upstream = r.json()

    # Adjust this field name if BitNet returns something else
    text = upstream.get("text") or upstream.get("completion") or upstream.get("output") or ""

    return {
        "id": "chatcmpl-local",
        "object": "chat.completion",
        "choices": [{
            "index": 0,
            "message": {"role": "assistant", "content": text},
            "finish_reason": "stop",
        }],
    }

