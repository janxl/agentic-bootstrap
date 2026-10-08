"""Conversation storage: SQLite on a persistent volume, so chats survive pod restarts.

One row per message in the exact shape the Messages API wants (plain dicts: text, tool_use,
tool_result), appended in order. Standard library only.
"""
import json
import os
import sqlite3
import threading

DB_PATH = os.environ.get("DB_PATH", "/data/agent.db")
# Only this many of the most recent messages are SENT to the model; everything is still stored.
# Keeps long chats inside the (local) model's context window.
MAX_CONTEXT_MESSAGES = int(os.environ.get("MAX_CONTEXT_MESSAGES", "24"))

_lock = threading.Lock()
_conn = None


def _db() -> sqlite3.Connection:
    global _conn
    if _conn is None:
        os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
        conn = sqlite3.connect(DB_PATH, check_same_thread=False)
        conn.execute("PRAGMA journal_mode=WAL")  # readers don't block the writer, survives crashes
        conn.execute(
            "CREATE TABLE IF NOT EXISTS messages ("
            " id INTEGER PRIMARY KEY AUTOINCREMENT,"
            " session_id TEXT NOT NULL,"
            " role TEXT NOT NULL,"
            " content TEXT NOT NULL,"  # JSON: a string (user text) or a list of content blocks
            " created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)"
        )
        conn.execute("CREATE INDEX IF NOT EXISTS messages_session ON messages (session_id, id)")
        conn.commit()
        _conn = conn
    return _conn


def load(session_id: str) -> list[dict]:
    with _lock:
        rows = _db().execute(
            "SELECT role, content FROM messages WHERE session_id = ? ORDER BY id", (session_id,)
        ).fetchall()
    return [{"role": role, "content": json.loads(content)} for role, content in rows]


def append(session_id: str, messages: list[dict]) -> None:
    """Store a finished turn atomically: all of its messages, or none."""
    rows = [(session_id, m["role"], json.dumps(m["content"], ensure_ascii=False)) for m in messages]
    with _lock:
        db = _db()
        with db:
            db.executemany("INSERT INTO messages (session_id, role, content) VALUES (?, ?, ?)", rows)


def for_llm(messages: list[dict], limit: int = MAX_CONTEXT_MESSAGES) -> list[dict]:
    """The recent tail of the conversation, starting at a real user message.

    A tool_result must stay next to the tool_use that produced it, so the window never begins
    in the middle of a tool exchange: it moves forward to the next plain user message.
    """
    if len(messages) <= limit:
        return messages
    tail = messages[-limit:]
    for i, m in enumerate(tail):
        if m["role"] == "user" and isinstance(m["content"], str):
            return tail[i:]
    return messages[-1:]  # unreachable in practice: the newest message is the user's text


def visible(messages: list[dict]) -> list[dict]:
    """What a person saw: their own messages and the agent's final answers, no tool traffic."""
    shown = []
    for m in messages:
        if m["role"] == "user" and isinstance(m["content"], str):
            shown.append({"role": "user", "text": m["content"]})
        elif m["role"] == "assistant" and isinstance(m["content"], list):
            if any(b.get("type") == "tool_use" for b in m["content"]):
                continue  # an intermediate step; the answer comes in a later message
            text = "".join(b.get("text", "") for b in m["content"] if b.get("type") == "text")
            if text:
                shown.append({"role": "assistant", "text": text})
    return shown
