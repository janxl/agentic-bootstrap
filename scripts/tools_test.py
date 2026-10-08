"""Exercise every MCP tool, plus bad inputs. Runs inside the agent pod (see test-tools.sh).

Uses the agent's own MCP client (mcp_client.py), so it tests the same path the agent uses.
Exit code is non-zero if any check fails.
"""
import json
import os
import re
import sys
import tomllib

from mcp_client import call_tool, list_tools

failures = 0


def load_config():
    """corpus.toml from the corpus-config ConfigMap: what the search checks are expected to find."""
    try:
        with open(os.environ.get("CORPUS_CONFIG", "/config/corpus.toml"), "rb") as f:
            return tomllib.load(f)
    except FileNotFoundError:
        return {}


def check(label, ok, got):
    global failures
    if ok:
        print(f"PASS  {label}")
    else:
        failures += 1
        print(f"FAIL  {label}\n        got: {got!r}")


def expect_eq(label, name, args, expected):
    got = call_tool(name, args)
    check(label, got == expected, got)


def expect_match(label, name, args, pattern):
    got = call_tool(name, args)
    check(label, re.search(pattern, got, re.S) is not None, got)


EXPECTED_TOOLS = {
    "get_current_time", "calculate", "random_number", "word_count", "convert_temperature", "search_documents",
}
tools = list_tools()
check("tool discovery returns the 6 tools", {t["name"] for t in tools} == EXPECTED_TOOLS, [t["name"] for t in tools])
check(
    "every tool has a description and an object input schema",
    all(t["description"] and t["input_schema"].get("type") == "object" for t in tools),
    tools,
)

print("\n-- get_current_time")
expect_match("default is UTC", "get_current_time", {}, r"^\d{4}-\d\d-\d\dT[\d:.]+\+00:00$")
expect_match("Australia/Sydney offset", "get_current_time", {"tz": "Australia/Sydney"}, r"\+1[01]:00$")
expect_match("unknown timezone", "get_current_time", {"tz": "Nope/Land"}, r"^Unknown timezone")
expect_match("wrong arg type", "get_current_time", {"tz": 5}, r"^Tool error")

print("\n-- calculate")
expect_eq("(3 + 4) * 2.5", "calculate", {"expression": "(3 + 4) * 2.5"}, "17.5")
expect_eq("2 ** 10", "calculate", {"expression": "2 ** 10"}, "1024")
expect_eq("negative and modulo", "calculate", {"expression": "-7 % 4"}, "1")
expect_match("division by zero", "calculate", {"expression": "1 / 0"}, r"^Cannot evaluate")
expect_match("syntax error", "calculate", {"expression": "2 +"}, r"^Cannot evaluate")
expect_match("code injection rejected", "calculate", {"expression": "__import__('os').system('id')"}, r"^Cannot evaluate")
expect_match("name lookup rejected", "calculate", {"expression": "abs(-1)"}, r"^Cannot evaluate")
expect_match("missing argument", "calculate", {}, r"^Tool error")
expect_match("wrong argument type", "calculate", {"expression": 123}, r"^Tool error")

print("\n-- random_number")
expect_eq("min == max", "random_number", {"minimum": 5, "maximum": 5}, "5")
got = call_tool("random_number", {})
check("defaults give 1..100", got.isdigit() and 1 <= int(got) <= 100, got)
got = call_tool("random_number", {"minimum": 10, "maximum": 1})
check("reversed bounds still 1..10", got.isdigit() and 1 <= int(got) <= 10, got)
expect_match("non-numeric argument", "random_number", {"minimum": "abc"}, r"^Tool error")

print("\n-- word_count")
got = call_tool("word_count", {"text": "hello big\nworld"})
try:
    check("counts words/chars/lines", json.loads(got) == {"words": 3, "characters": 15, "lines": 2}, got)
except ValueError:
    check("counts words/chars/lines", False, got)
got = call_tool("word_count", {"text": ""})
try:
    check("empty text", json.loads(got) == {"words": 0, "characters": 0, "lines": 0}, got)
except ValueError:
    check("empty text", False, got)
expect_match("missing argument", "word_count", {}, r"^Tool error")

print("\n-- convert_temperature")
expect_eq("100 C -> F", "convert_temperature", {"value": 100, "from_unit": "celsius", "to_unit": "fahrenheit"}, "212.00 fahrenheit")
expect_eq("0 C -> K", "convert_temperature", {"value": 0, "from_unit": "celsius", "to_unit": "kelvin"}, "273.15 kelvin")
expect_eq("units are case-insensitive", "convert_temperature", {"value": 32, "from_unit": "FAHRENHEIT", "to_unit": "Celsius"}, "0.00 celsius")
expect_match("unknown unit", "convert_temperature", {"value": 1, "from_unit": "x", "to_unit": "kelvin"}, r"^Units must be one of")
expect_match("missing arguments", "convert_temperature", {"value": 1}, r"^Tool error")
expect_match("non-numeric value", "convert_temperature", {"value": "hot", "from_unit": "celsius", "to_unit": "kelvin"}, r"^Tool error")

print("\n-- search_documents")
search_tool = next(t for t in tools if t["name"] == "search_documents")

# What to expect comes from corpus.toml, so these checks follow whatever corpus is configured.
CONFIG = load_config()
DOCS = [d for d in CONFIG.get("documents", []) if d.get("file")]
TESTS = CONFIG.get("tests", {})
FILES = {d["file"] for d in DOCS}
if not CONFIG:
    print("INFO  no corpus.toml in the cluster (run `make config`): document-specific checks skipped")


def sources_of(query, top_k=3):
    """Source files of the hits, best first."""
    out = call_tool("search_documents", {"query": query, "top_k": top_k})
    return re.findall(r"^\[\d+\] .*? source: (\S+?)(?:, page \d+)? \|", out, re.M), out


missing = [d["title"] for d in DOCS if d.get("title") and d["title"] not in search_tool["description"]]
if DOCS:
    check("description lists every configured document (else: make config)", not missing, missing)

# Each [[tests.find]]: the expected file must be within the top 3 hits (the exact rank is printed).
for case in TESTS.get("find", []):
    srcs, out = sources_of(case["query"])
    rank = srcs.index(case["expect"]) + 1 if case["expect"] in srcs else None
    check(f"finds {case['expect']} for: {case['query'][:50]}", rank is not None, (srcs, out[:200]))
    if rank:
        print(f"        rank {rank}")

topic = TESTS.get("topic_query", "overview")
srcs, out = sources_of(topic, top_k=3)
if FILES:
    check("topic query returns only configured documents", bool(srcs) and set(srcs) <= FILES, srcs)
if any(s.lower().endswith(".pdf") for s in srcs):
    check("PDF results carry a page number", re.search(r"source: \S+?\.pdf, page \d+", out, re.I) is not None, out[:300])
out = call_tool("search_documents", {"query": topic, "top_k": 2})
check("top_k=2 returns exactly 2 passages", len(re.findall(r"^\[\d+\] ", out, re.M)) == 2, out[:300])
out = call_tool("search_documents", {"query": "x", "top_k": 99})
check("top_k is capped at 6", len(re.findall(r"^\[\d+\] ", out, re.M)) <= 6, out[:200])
expect_match("empty query", "search_documents", {"query": "   "}, r"^Empty query")
expect_match("missing query", "search_documents", {}, r"^Tool error")
expect_match("wrong top_k type", "search_documents", {"query": "x", "top_k": "many"}, r"^Tool error")
if TESTS.get("compare_query"):
    srcs, _ = sources_of(TESTS["compare_query"], top_k=6)
    print(f"INFO  compare query ({TESTS['compare_query'][:40]}...): documents hit = {sorted(set(srcs))}")
_, out = sources_of("Who won the 2024 Melbourne Cup horse race?", top_k=3)
m = re.search(r"score (\d\.\d+)", out)
print(f"INFO  off-topic question: best score {m.group(1) if m else 'n/a'} (search always returns its closest passages)")

print("\n-- unknown tool")
expect_match("non-existent tool", "no_such_tool", {}, r"^Tool error")

total_note = f"{failures} failed" if failures else "all passed"
print(f"\n{total_note}")
sys.exit(1 if failures else 0)
