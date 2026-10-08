[← How it works](../HOW_IT_WORKS.md)

# Document search

## Why the agent needs it

A model knows what it was trained on, up to a cutoff date. It has never seen your private documents,
or anything published since. The obvious fix, pasting the documents into the prompt, does not scale:
the four demo reports are about 650 passages of text, far more than fits in a model's context window,
and sending it all on every question would be slow and expensive.

The standard answer is **retrieval-augmented generation (RAG)**: keep the documents in a searchable
index, and for each question fetch only the few passages that look relevant and hand those to the
model. Here that is a tool like any other ([the MCP server](mcp-server.md)): the model calls
`search_documents`, the passages come back as the tool result ([the agent](agent.md#tools)), and the
model answers from them.

It has two halves. **Indexing** prepares the documents once, ahead of time. **Searching** runs on every
question.

```
 INDEXING (make ingest)                                 SEARCHING (each question)

 corpus/*.pdf, .txt, .html                              model calls search_documents("NSW prices Q4 2025")
        │ read the text                                          │
        ▼                                                        ▼
   split into chunks                                    embed the question ──▶ Ollama
        │                                                        │ a vector (768 numbers)
        ▼                                                        ▼
   embed each chunk ──▶ Ollama                          find the nearest chunks ──▶ Qdrant
        │ a vector per chunk                                     │
        ▼                                                        ▼
   store vector + text ──▶ Qdrant                       return the passages, with source and page
```

## Embeddings: search by meaning

An **embedding model** turns a piece of text into a list of numbers (a vector) so that texts with similar
meaning get vectors that are close together. That lets the search match *"price spikes"* with a passage
about *"high-priced intervals"*, even though they share no words, which a plain keyword search would miss.

[Ollama](https://ollama.com) runs in its own pod and serves the `nomic-embed-text` model, which
produces 768 numbers per text. The model expects a prefix saying what the text is for: chunks are
embedded as `search_document: ...` and questions as `search_query: ...`. The same prefixes have to be
used when indexing and when searching.

## Qdrant: finding the nearest vectors

[Qdrant](https://qdrant.tech) is a vector database. Each stored point is a chunk's vector plus a
payload: its text, the source file, the title and the page number. To search, Qdrant takes the
question's vector and returns the stored chunks whose vectors are closest (by cosine similarity), with
a score. It runs in its own pod, and its data sits on a persistent volume, so the index survives
restarts.

## Indexing: from files to chunks (`ingest/ingest.py`)

`make ingest` copies the `corpus/` folder into the cluster and runs a job that does this for each file:

1. **Read the text.** PDFs are read page by page (so a chunk can name its page), HTML is stripped to
   text, plain text is used as is.
2. **Split into chunks** of about 2,000 characters (roughly 500 tokens), with 200 characters of overlap
   between neighbours. Chunks end at paragraph and sentence boundaries where possible. Chunks matter:
   too large and the search is vague and wastes the model's context, too small and a passage loses
   its surroundings. The overlap means a sentence cut at a boundary still appears whole in one chunk.
3. **Embed** each chunk (with the document's title in front, so near-identical documents such as four
   quarterly reports can be told apart).
4. **Store** the vectors and payloads in Qdrant.

The job is safe to run as often as you like. It remembers a content hash for each file, so a new file is
added, an edited file is re-indexed (the new version is embedded before the old one is removed), a
deleted file's chunks are removed, and an unchanged file is skipped.

## Searching: the `search_documents` tool (`mcp-tools/search.py`)

The tool takes a query and returns the closest few passages (3 by default, at most 6):

```
[1] AEMO Quarterly Energy Dynamics Q4 2025 (October to December 2025) | source: aemo-qed-q4-2025.pdf, page 12 | score 0.77
<the passage text>

[2] ...
```

Each result carries its source and page, so the model can cite them. The `score` is the similarity.

Whether the model calls the tool at all depends on two pieces of text, both set in `corpus.toml`. The
tool's description says what the library covers and lists the document titles, and the system prompt
([the agent](agent.md)) tells the model to search first, to make specific queries, to answer only from
what comes back, and to say so when the passages do not contain the answer.

## What to know

- **Meaning, not exact words.** Dense search is good at paraphrase and weak at exact quotes and rare
  names. A question made mostly of words that appear everywhere, such as two character names that occur
  on every page of every book in the library, matches all of those documents about equally.
- **It always returns something.** The closest passages are returned even when none is relevant. A score
  is a similarity, not a verdict, and the scores for good and irrelevant matches overlap, so there is no
  reliable cutoff. The prompt's "say you do not know" rule is the guard.
- **Text, not layout.** Tables and charts in PDFs become plain text, and figures are lost.
- **Small models skip tools.** A small local model may answer from memory instead of searching. The
  forceful description and prompt help, but a stronger model is more reliable.

## Other solutions

Each piece here has alternatives:

- **RAG frameworks** such as LlamaIndex, LangChain and Haystack package reading, chunking, embedding
  and retrieval. This project uses none of them: it makes direct calls (a small chunker, one HTTP
  request to Ollama, and the Qdrant client), which keeps the pipeline short and easy to read.
- **Better retrieval.** Hybrid search combines keyword and meaning-based search (Qdrant supports it) and
  fixes many of the exact-name misses. A reranker re-scores the top results with a more careful model.
- **Other vector stores:** pgvector (inside Postgres), Chroma, Weaviate, Milvus, or hosted services such
  as Pinecone.
- **Other embedding models**, local or from hosted APIs. Changing the model means re-indexing everything,
  because vectors from different models are not comparable.
- **Managed RAG services** from the large cloud and AI providers, which hide all of the above.

---

← Previous: [Conversation history](conversation-history.md) · Next: [Deployment](deployment.md)
