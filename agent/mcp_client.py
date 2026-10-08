import asyncio
import os
from contextlib import asynccontextmanager

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

MCP_URL = os.environ.get("MCP_URL", "http://mcp-tools:8000/mcp")


@asynccontextmanager
async def _session():
    # The server is stateless, so a short-lived session per operation is fine.
    async with streamablehttp_client(MCP_URL) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            yield session


def list_tools() -> list[dict]:
    """Tools from the MCP server, in the shape the Anthropic Messages API expects."""

    async def go():
        async with _session() as s:
            result = await s.list_tools()
            return [
                {"name": t.name, "description": t.description or "", "input_schema": t.inputSchema}
                for t in result.tools
            ]

    return asyncio.run(go())


def call_tool(name: str, args: dict) -> str:
    async def go():
        async with _session() as s:
            result = await s.call_tool(name, args)
            text = "\n".join(c.text for c in result.content if c.type == "text")
            return f"Tool error: {text}" if result.isError else text

    try:
        return asyncio.run(go())
    except Exception as e:
        return f"Tool error: {e}"
