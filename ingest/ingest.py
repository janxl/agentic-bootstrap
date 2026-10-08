"""Idempotent document ingestion: corpus/ -> chunks -> embeddings -> Qdrant.

Reconciles the folder against the index on every run, so it is safe to run as often as you like
(by hand, as a Job, or from a CronJob):
  new file        -> chunk, embed, insert
  changed file    -> embed the new version first, then replace the old chunks
  unchanged file  -> skipped (content hash and title match)
  deleted file    -> its chunks are removed
Qdrant itself is the record of what is indexed (each chunk carries its file's `source`, `title`
and `doc_hash`), so there is no separate state to keep in sync.

No framework: pypdf and BeautifulSoup read the files, `chunk_text` below splits them, Ollama's
/api/embed makes the vectors, and qdrant-client stores them.
"""
import hashlib
import json
import logging
import os
import re
import sys
import time
import tomllib
import urllib.error
import urllib.request
import uuid
from pathlib import Path

from bs4 import BeautifulSoup
from pypdf import PdfReader
from qdrant_client import QdrantClient, models

CORPUS_DIR = Path(os.environ.get("CORPUS_DIR", "/corpus"))
QDRANT_URL = os.environ.get("QDRANT_URL", "http://qdrant:6333")
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://ollama:11434")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "nomic-embed-text")
# The collection is named after the embedding model: changing the model means a new collection
# (old vectors are incompatible), and the old one can be kept until the new one is verified.
COLLECTION = os.environ.get("COLLECTION", "documents_nomic_v1")
CHUNK_CHARS, CHUNK_OVERLAP = 2000, 200  # about 500 and 50 tokens of English text
EMBED_BATCH = 16
SUPPORTED = {".txt", ".html", ".htm", ".pdf"}

# Anything that changes the vectors must change this string, so every file is re-indexed.
# (nomic-embed-text wants task prefixes: documents are embedded as "search_document: ...", and
# search queries as "search_query: ...".)
PIPELINE_CONFIG = f"{EMBED_MODEL}|chunk={CHUNK_CHARS}/{CHUNK_OVERLAP}chars|prefix=search_document|v2"

log = logging.getLogger("ingest")


def load_titles() -> dict[str, str]:
    """file name -> title, from [[documents]] in corpus.toml (the corpus-config ConfigMap).
    Files that are not listed there fall back to their file name."""
    try:
        with open(os.environ.get("CORPUS_CONFIG", "/config/corpus.toml"), "rb") as f:
            docs = tomllib.load(f).get("documents", [])
    except FileNotFoundError:
        return {}
    return {d["file"]: d["title"] for d in docs if d.get("file") and d.get("title")}


TITLES = load_titles()


# ---------------------------------------------------------------- reading files

_GUTENBERG = re.compile(r"\*\*\* ?START OF .*?\*\*\*(.*?)\*\*\* ?END OF ", re.S)


def clean_text(raw: str) -> str:
    m = _GUTENBERG.search(raw)  # drop a Project Gutenberg licence header/footer, keep the book
    text = m.group(1) if m else raw
    return re.sub(r"\n{3,}", "\n\n", text.replace("\r\n", "\n")).strip()


def html_to_text(raw: str) -> str:
    soup = BeautifulSoup(raw, "html.parser")
    for tag in soup(["script", "style", "noscript"]):
        tag.decompose()
    return re.sub(r"\n{3,}", "\n\n", soup.get_text("\n")).strip()


def read_sections(path: Path) -> list[tuple[int | None, str]]:
    """(page number or None, text) for each non-empty page of a PDF, or the whole of a text file."""
    suffix = path.suffix.lower()
    if suffix == ".pdf":
        pages = [(i + 1, (p.extract_text() or "").strip()) for i, p in enumerate(PdfReader(path).pages)]
        return [(n, text) for n, text in pages if text]
    raw = path.read_text(encoding="utf-8", errors="replace")
    text = html_to_text(raw) if suffix in {".html", ".htm"} else clean_text(raw)
    return [(None, text)] if text else []


# ---------------------------------------------------------------- chunking

_SENTENCE_END = re.compile(r"(?<=[.!?])\s+")


def _pieces(text: str, size: int) -> list[tuple[str, str]]:
    """Split text into (separator, piece) units no longer than `size`: paragraphs when they fit,
    otherwise sentences, otherwise runs of words. The separator is what joined it to the previous
    unit in the original, so chunks read naturally."""
    units: list[tuple[str, str]] = []
    for para in re.split(r"\n\s*\n", text):
        para = para.strip()
        if not para:
            continue
        sep = "\n\n"
        if len(para) <= size:
            units.append((sep, para))
            continue
        for sentence in _SENTENCE_END.split(para):
            while len(sentence) > size:  # no sentence break to use (a table, a transcript line): cut at a space
                cut = sentence.rfind(" ", 0, size)
                cut = cut if cut > size // 2 else size
                units.append((sep, sentence[:cut].strip()))
                sentence, sep = sentence[cut:].strip(), " "
            if sentence:
                units.append((sep, sentence))
                sep = " "
    return units


def _tail(chunk: str, overlap: int) -> str:
    """The end of a chunk, starting at a word boundary, to open the next chunk with."""
    tail = chunk[-overlap:] if overlap else ""
    if len(tail) == len(chunk) or not tail:
        return tail
    space = tail.find(" ")
    return tail[space + 1:] if space != -1 else ""


def chunk_text(text: str, size: int = CHUNK_CHARS, overlap: int = CHUNK_OVERLAP) -> list[str]:
    """Pack paragraphs/sentences into chunks of at most `size` characters. Each chunk starts with
    the last `overlap` characters of the one before, so a passage cut at a boundary is still
    found whole in one of the two."""
    chunks: list[str] = []
    current = ""
    for sep, piece in _pieces(text, size):
        if current and len(current) + len(sep) + len(piece) > size:
            chunks.append(current)
            carry = _tail(current, overlap)
            current = carry if carry and len(carry) + 1 + len(piece) <= size else ""
            sep = " "
        current = f"{current}{sep}{piece}" if current else piece
    if current.strip():
        chunks.append(current)
    return chunks


# ---------------------------------------------------------------- embedding

def _embed_batch(batch: list[str]) -> list[list[float]]:
    body = json.dumps({"model": EMBED_MODEL, "input": batch}).encode()
    for attempt in range(3):
        try:
            req = urllib.request.Request(f"{OLLAMA_URL}/api/embed", data=body, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=600) as resp:
                vectors = json.loads(resp.read())["embeddings"]
            if len(vectors) != len(batch):
                raise ValueError(f"asked for {len(batch)} embeddings, got {len(vectors)}")
            return vectors
        except (urllib.error.URLError, TimeoutError, ValueError) as e:
            if attempt == 2:
                raise
            log.warning("embedding failed (%s); retrying", e)
            time.sleep(2 ** attempt)
    raise AssertionError("unreachable")


def embed(texts: list[str]) -> list[list[float]]:
    vectors: list[list[float]] = []
    for i in range(0, len(texts), EMBED_BATCH):
        vectors += _embed_batch(texts[i:i + EMBED_BATCH])
    return vectors


# ---------------------------------------------------------------- the index

def file_hash(path: Path) -> str:
    h = hashlib.sha256(PIPELINE_CONFIG.encode())
    h.update(path.read_bytes())
    return h.hexdigest()


def source_filter(name: str) -> models.Filter:
    return models.Filter(must=[models.FieldCondition(key="source", match=models.MatchValue(value=name))])


def indexed_state(client: QdrantClient, name: str) -> tuple[str | None, str | None] | None:
    """(content hash, title) the file was indexed with, or None if it is not indexed."""
    points, _ = client.scroll(
        COLLECTION, scroll_filter=source_filter(name), limit=1, with_payload=["doc_hash", "title"]
    )
    return (points[0].payload.get("doc_hash"), points[0].payload.get("title")) if points else None


def indexed_sources(client: QdrantClient) -> list[str]:
    return [h.value for h in client.facet(COLLECTION, key="source", limit=1000).hits]


def ensure_collection(client: QdrantClient, dimension: int) -> None:
    if not client.collection_exists(COLLECTION):
        client.create_collection(
            COLLECTION, vectors_config=models.VectorParams(size=dimension, distance=models.Distance.COSINE)
        )
    # Keyword index on `source`: fast filters, and it enables listing the indexed documents.
    client.create_payload_index(COLLECTION, "source", models.PayloadSchemaType.KEYWORD)


def build_points(path: Path, digest: str, title: str) -> tuple[list[str], list[dict]]:
    """The texts to embed and the payloads to store, one per chunk."""
    texts, payloads = [], []
    for page, section in read_sections(path):
        for chunk in chunk_text(section):
            payload = {"source": path.name, "title": title, "doc_hash": digest, "chunk": len(payloads), "text": chunk}
            if page is not None:
                payload["page"] = page
            payloads.append(payload)
            # The title goes into the embedded text so chunks from near-identical documents
            # (four quarterly reports) are told apart; it is not part of the stored passage.
            texts.append(f"search_document: title: {title}\n\n{chunk}")
    return texts, payloads


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    started = time.time()
    if not CORPUS_DIR.is_dir():
        log.error("corpus folder not found: %s", CORPUS_DIR)
        return 2

    client = QdrantClient(url=QDRANT_URL)
    exists = client.collection_exists(COLLECTION)
    log.info("corpus=%s collection=%s (%s) model=%s", CORPUS_DIR, COLLECTION, "exists" if exists else "new", EMBED_MODEL)

    counts = {"added": 0, "updated": 0, "unchanged": 0, "removed": 0, "failed": 0}
    on_disk = []
    for path in sorted(CORPUS_DIR.iterdir()):
        if not path.is_file() or path.name.startswith(".") or path.suffix == ".part":
            continue
        if path.suffix.lower() not in SUPPORTED:
            log.info("skip       %s (unsupported type; supported: %s)", path.name, ", ".join(sorted(SUPPORTED)))
            continue
        on_disk.append(path.name)
        try:
            digest = file_hash(path)
            title = TITLES.get(path.name, path.stem)
            current = indexed_state(client, path.name) if exists else None
            if current == (digest, title):
                counts["unchanged"] += 1
                log.info("unchanged  %s", path.name)
                continue
            t0 = time.time()
            texts, payloads = build_points(path, digest, title)
            if not texts:
                raise ValueError("no text could be extracted")
            vectors = embed(texts)  # embed first ...
            ensure_collection(client, len(vectors[0]))
            exists = True
            if current is not None:  # ... then swap, so a failed embed never leaves the file unindexed
                client.delete(COLLECTION, points_selector=models.FilterSelector(filter=source_filter(path.name)))
            points = [
                models.PointStruct(id=str(uuid.uuid5(uuid.NAMESPACE_URL, f"{path.name}|{digest}|{p['chunk']}")), vector=v, payload=p)
                for v, p in zip(vectors, payloads)
            ]
            for i in range(0, len(points), 64):
                client.upsert(COLLECTION, points=points[i:i + 64], wait=True)
            counts["updated" if current is not None else "added"] += 1
            log.info(
                "%-10s %s: %d chunks in %.0fs",
                "updated" if current is not None else "added", path.name, len(points), time.time() - t0,
            )
        except Exception:
            counts["failed"] += 1
            log.exception("FAILED     %s", path.name)

    if exists:
        for name in indexed_sources(client):
            if name not in on_disk:
                client.delete(COLLECTION, points_selector=models.FilterSelector(filter=source_filter(name)))
                counts["removed"] += 1
                log.info("removed    %s (no longer in the corpus)", name)

    total = client.count(COLLECTION).count if exists else 0
    log.info("done in %.0fs: %s; %d chunks in collection", time.time() - started, counts, total)
    return 1 if counts["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
