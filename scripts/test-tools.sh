#!/usr/bin/env bash
# Tests every MCP tool, bad inputs, a non-existent tool and document search. Takes no parameters.
# Runs scripts/tools_test.py inside the agent pod, through the agent's own MCP client. No LLM is
# involved, so results are deterministic. (The search checks expect the AEMO corpus to be ingested.)
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
in_agent < "$ROOT/scripts/tools_test.py"
