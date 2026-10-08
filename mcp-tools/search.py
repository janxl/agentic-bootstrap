"""search_documents: semantic search over the ingested document library (Ollama embeddings + Qdrant)."""
import json
import os
import tomllib
import urllib.request

from qdrant_client import QdrantClient

QDRANT_URL = os.environ.get("QDRANT_URL", "http://qdrant:6333")
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://ollama:11434")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "nomic-embed-text")
COLLECTION = os.environ.get("COLLECTION", "documents_nomic_v1")  # must match the ingest job
DEFAULT_TOP_K, MAX_TOP_K = 3, 6  # each passage is ~500 tokens; the local model's context is 8192
MAX_PASSAGE_CHARS = 1800


def _load_config() -> dict:
    """corpus.toml, mounted from the corpus-config ConfigMap. Missing is fine: a generic description."""
    try:
        with open(os.environ.get("CORPUS_CONFIG", "/config/corpus.toml"), "rb") as f:
            return tomllib.load(f)
    except FileNotFoundError:
        return {}


def _description(config: dict) -> str:
    """What the model reads to decide whether to call this tool. It comes from corpus.toml: what the
    library is about ([search] topics) and which documents it holds ([[documents]] titles)."""
    topics = config.get("search", {}).get("topics", "").strip()
    titles = [d["title"] for d in config.get("documents", []) if d.get("title")]
    return (
        "ALWAYS call this tool to answer questions about the subject matter of the document library; "
        "never answer such questions from memory. Returns the most relevant passages, each with its "
        "source file and page. "
        + (topics + " " if topics else "")
        + "Make the query specific: include the region, the time period and the metric."
        + (" Documents in the library: " + "; ".join(titles) + "." if titles else "")
    )


DESCRIPTION = _description(_load_config())

_client = None


def client() -> QdrantClient:
    """Created on first use, so the server starts even if Qdrant is not up yet."""
    global _client
    if _client is None:
        _client = QdrantClient(url=QDRANT_URL)
    return _client


def embed_query(query: str) -> list[float]:
    # nomic-embed-text is trained with task prefixes: documents are embedded as "search_document: ..."
    # at ingestion (ingest/ingest.py), questions as "search_query: ..." here. Skipping them hurts quality.
    body = json.dumps({"model": EMBED_MODEL, "input": [f"search_query: {query}"]}).encode()
    req = urllib.request.Request(f"{OLLAMA_URL}/api/embed", data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read())["embeddings"][0]


def format_results(hits) -> str:
    """hits: Qdrant scored points (.payload, .score), best first."""
    if not hits:
        return "No passages found: the document library is empty or not yet indexed."
    blocks = []
    for i, h in enumerate(hits, 1):
        p = h.payload
        page = f", page {p['page']}" if p.get("page") else ""
        text = p["text"].strip()
        if len(text) > MAX_PASSAGE_CHARS:
            text = text[:MAX_PASSAGE_CHARS] + " ..."
        blocks.append(f"[{i}] {p.get('title', '?')} | source: {p.get('source', '?')}{page} | score {h.score:.2f}\n{text}")
    return "\n\n".join(blocks)


def search(query: str, top_k: int = DEFAULT_TOP_K) -> str:
    query = query.strip()
    if not query:
        return "Empty query: say what to search for."
    top_k = max(1, min(int(top_k), MAX_TOP_K))
    result = client().query_points(COLLECTION, query=embed_query(query), limit=top_k, with_payload=True)
    # a point without text would be left over from an index built by an older version: skip it
    return format_results([h for h in result.points if h.payload.get("text")])
