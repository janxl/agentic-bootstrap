import logging
import os

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

AGENT_URL = os.environ.get("AGENT_URL", "http://agent:8000")
ACCESS_LOG = os.environ.get("ACCESS_LOG", "true").strip().lower() in ("1", "true", "yes", "on")
TIMEOUT = float(os.environ.get("AGENT_TIMEOUT", "300"))  # seconds; local models can be slow

logging.getLogger("uvicorn.access").disabled = not ACCESS_LOG

app = FastAPI()


class ChatRequest(BaseModel):
    session_id: str
    message: str


@app.post("/chat")
async def chat(req: ChatRequest):
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            r = await client.post(f"{AGENT_URL}/chat", json=req.model_dump())
            r.raise_for_status()
            return r.json()
    except httpx.TimeoutException:
        raise HTTPException(504, f"Agent did not answer within {TIMEOUT:.0f}s")
    except httpx.HTTPError as e:
        raise HTTPException(502, f"Agent error: {e}")


@app.get("/history/{session_id}")
async def history(session_id: str):
    try:
        async with httpx.AsyncClient(timeout=30) as client:
            r = await client.get(f"{AGENT_URL}/sessions/{session_id}/messages")
            r.raise_for_status()
            return r.json()
    except httpx.HTTPError as e:
        raise HTTPException(502, f"Agent error: {e}")


@app.get("/")
def index():
    return FileResponse("static/index.html")


app.mount("/static", StaticFiles(directory="static"), name="static")
