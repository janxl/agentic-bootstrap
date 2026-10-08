import ast
import logging
import operator
import random
from datetime import datetime
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

import search as search_docs

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

# Stateless streamable-HTTP server on /mcp. DNS-rebinding protection is off because
# requests arrive with in-cluster Host headers (mcp-tools:8000), not localhost.
mcp = FastMCP(
    "test-tools",
    host="0.0.0.0",
    port=8000,
    stateless_http=True,
    transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
)


@mcp.tool()
def get_current_time(tz: str = "UTC") -> str:
    """Get the current date and time in an IANA timezone (e.g. 'UTC', 'Australia/Sydney')."""
    try:
        return datetime.now(ZoneInfo(tz)).isoformat()
    except ZoneInfoNotFoundError:
        return f"Unknown timezone: {tz}"


_OPS = {
    ast.Add: operator.add,
    ast.Sub: operator.sub,
    ast.Mult: operator.mul,
    ast.Div: operator.truediv,
    ast.Pow: operator.pow,
    ast.Mod: operator.mod,
    ast.USub: operator.neg,
}


def _eval(node):
    if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
        return node.value
    if isinstance(node, ast.BinOp) and type(node.op) in _OPS:
        return _OPS[type(node.op)](_eval(node.left), _eval(node.right))
    if isinstance(node, ast.UnaryOp) and type(node.op) in _OPS:
        return _OPS[type(node.op)](_eval(node.operand))
    raise ValueError("unsupported expression")


@mcp.tool()
def calculate(expression: str) -> str:
    """Evaluate an arithmetic expression using + - * / ** % and parentheses, e.g. '(3 + 4) * 2.5'."""
    try:
        return str(_eval(ast.parse(expression, mode="eval").body))
    except (ValueError, SyntaxError, ZeroDivisionError, OverflowError) as e:
        return f"Cannot evaluate: {e}"


@mcp.tool()
def random_number(minimum: int = 1, maximum: int = 100) -> int:
    """Return a random integer between minimum and maximum (inclusive)."""
    return random.randint(min(minimum, maximum), max(minimum, maximum))


@mcp.tool()
def word_count(text: str) -> dict:
    """Count the words, characters and lines in a piece of text."""
    return {"words": len(text.split()), "characters": len(text), "lines": len(text.splitlines())}


@mcp.tool()
def convert_temperature(value: float, from_unit: str, to_unit: str) -> str:
    """Convert a temperature between 'celsius', 'fahrenheit' and 'kelvin'."""
    to_c = {
        "celsius": lambda v: v,
        "fahrenheit": lambda v: (v - 32) * 5 / 9,
        "kelvin": lambda v: v - 273.15,
    }
    from_c = {
        "celsius": lambda c: c,
        "fahrenheit": lambda c: c * 9 / 5 + 32,
        "kelvin": lambda c: c + 273.15,
    }
    f, t = from_unit.lower(), to_unit.lower()
    if f not in to_c or t not in from_c:
        return "Units must be one of: celsius, fahrenheit, kelvin"
    return f"{from_c[t](to_c[f](value)):.2f} {t}"


@mcp.tool(description=search_docs.DESCRIPTION)
def search_documents(query: str, top_k: int = search_docs.DEFAULT_TOP_K) -> str:
    return search_docs.search(query, top_k)


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
