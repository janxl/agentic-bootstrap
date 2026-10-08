import json
import logging
import os
import threading
import tomllib
from collections import defaultdict

import anthropic
from fastapi import FastAPI
from pydantic import BaseModel

import history
from mcp_client import call_tool, list_tools

def load_corpus_config() -> dict:
    """corpus.toml, mounted from the corpus-config ConfigMap. Missing is fine: generic defaults."""
    try:
        with open(os.environ.get("CORPUS_CONFIG", "/config/corpus.toml"), "rb") as f:
            return tomllib.load(f)
    except FileNotFoundError:
        return {}


MODEL = os.environ.get("MODEL", "claude-sonnet-5-5")
SYSTEM = load_corpus_config().get("prompt", {}).get("system", "").strip() or "You are a helpful assistant."
MAX_STEPS = 10


def env_flag(name: str, default: bool) -> bool:
    return os.environ.get(name, str(default)).strip().lower() in ("1", "true", "yes", "on")


LOG_LLM = env_flag("LOG_LLM", True)  # full LLM request/response JSON
ACCESS_LOG = env_flag("ACCESS_LOG", True)  # uvicorn's per-request "POST /chat 200" lines

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("agent")
logging.getLogger("uvicorn.access").disabled = not ACCESS_LOG

# Default: Claude via ANTHROPIC_API_KEY. Set LLM_BASE_URL (+ LLM_API_KEY) to use another
# Anthropic-compatible endpoint, e.g. a local Ollama.
API_KEY = os.environ.get("LLM_API_KEY") or os.environ.get("ANTHROPIC_API_KEY")
if not API_KEY:
    # Start anyway (e.g. a fresh clone that will use the local model); calls to Claude then fail
    # with a clear 401 instead of the pod crash-looping.
    log.warning("no API key set: use `make use-local`, or create secret.yaml for Claude")
    API_KEY = "not-set"
client = anthropic.Anthropic(base_url=os.environ.get("LLM_BASE_URL") or None, api_key=API_KEY)
app = FastAPI()
session_locks: defaultdict[str, threading.Lock] = defaultdict(threading.Lock)


class ChatRequest(BaseModel):
    session_id: str
    message: str


def to_json(obj) -> str:
    return json.dumps(obj, indent=2, ensure_ascii=False)


def plain_blocks(content) -> list[dict]:
    """SDK content blocks -> plain dicts that can be stored and replayed.

    Only text and tool_use are kept: reasoning blocks are not replayed (saves tokens; unsigned
    ones can be rejected), and empty text blocks are invalid.
    """
    blocks = []
    for b in content:
        if b.type == "text" and b.text:
            blocks.append({"type": "text", "text": b.text})
        elif b.type == "tool_use":
            blocks.append({"type": "tool_use", "id": b.id, "name": b.name, "input": b.input})
    return blocks or [{"type": "text", "text": "(no response)"}]


def run_agent(session_id: str, messages: list) -> str:
    tools = list_tools()  # discovered from the MCP server each turn
    for step in range(MAX_STEPS):
        request = dict(
            model=MODEL, max_tokens=2048, system=SYSTEM, tools=tools, messages=history.for_llm(messages)
        )
        if LOG_LLM:
            log.info("LLM request [session=%s step=%d]\n%s", session_id, step, to_json(request))
        resp = client.messages.create(**request)
        if LOG_LLM:
            log.info(
                "LLM response [session=%s step=%d]\n%s",
                session_id, step, resp.model_dump_json(indent=2),
            )
        messages.append({"role": "assistant", "content": plain_blocks(resp.content)})
        if resp.stop_reason != "tool_use":
            return "".join(b.text for b in resp.content if b.type == "text")
        results = []
        for b in resp.content:
            if b.type != "tool_use":
                continue
            output = call_tool(b.name, b.input)
            log.info("tool call [session=%s] %s(%s) -> %s", session_id, b.name, b.input, output)
            results.append({"type": "tool_result", "tool_use_id": b.id, "content": output})
        messages.append({"role": "user", "content": results})
    return "(stopped: too many steps)"


@app.post("/chat")
def chat(req: ChatRequest):
    # One turn at a time per session. Work on a copy and only store it if the whole turn
    # succeeds, so a failed or timed-out call leaves no dangling user message in the history.
    with session_locks[req.session_id]:
        stored = history.load(req.session_id)
        messages = stored + [{"role": "user", "content": req.message}]
        reply = run_agent(req.session_id, messages)
        history.append(req.session_id, messages[len(stored):])  # one atomic write for the turn
    return {"reply": reply}


@app.get("/sessions/{session_id}/messages")
def session_messages(session_id: str):
    """The conversation as a person saw it (for the UI to restore after a reload or restart)."""
    return {"messages": history.visible(history.load(session_id))}


@app.get("/healthz")
def healthz():
    return {"ok": True}
