"""Tools an agent can be given: Gateway MCP tools, built-ins, and sub-agents."""

from __future__ import annotations

import json
import logging
import threading
from typing import Awaitable, Callable

from langchain_core.tools import BaseTool, StructuredTool, tool

log = logging.getLogger(__name__)

SEARCH_TOOL = "x_amz_bedrock_agentcore_search"


async def gateway_tools(gateway_mcp_url: str, access_token: str, allowed: tuple[str, ...]) -> list[BaseTool]:
    """Load MCP tools from AgentCore Gateway as the signed-in user.

    Gateway's Cedar policy filters ``tools/list`` per user, so this only returns
    tools the user is permitted to call. ``allowed`` narrows further per agent.
    """
    if not allowed or not gateway_mcp_url or not access_token:
        return []
    from langchain_mcp_adapters.client import MultiServerMCPClient

    client = MultiServerMCPClient({
        "gateway": {
            "transport": "streamable_http",
            "url": gateway_mcp_url,
            "headers": {"Authorization": f"Bearer {access_token}"},
            "timeout": 60,
        }
    })
    tools = await client.get_tools()  # follows tools/list pagination
    if "*" in allowed:
        return tools
    wanted = set(allowed)
    selected = [t for t in tools if t.name in wanted]
    missing = wanted - {t.name for t in selected}
    if missing:
        # Usually means Cedar policy denies this user, or the target isn't deployed.
        log.warning("gateway tools not available to this user: %s", sorted(missing))
    return selected


_interpreter_lock = threading.Lock()
_interpreter = None


def code_interpreter_tool(region: str, identifier: str) -> BaseTool:
    """Sandboxed Python execution via AgentCore Code Interpreter.

    One interpreter session per microVM (i.e. per chat session), started lazily
    and reused so variables persist between calls within a conversation.
    """

    @tool
    def run_python(code: str) -> str:
        """Run Python code in a secure sandbox and return stdout, stderr and results.

        Use for calculations, data analysis and generating tables. Variables persist
        between calls in the same conversation. No network access to internal systems.
        """
        global _interpreter
        from bedrock_agentcore.tools.code_interpreter_client import CodeInterpreter

        with _interpreter_lock:
            if _interpreter is None:
                _interpreter = CodeInterpreter(region)
                _interpreter.start(identifier=identifier)
            result = _interpreter.execute_code(code)
        text = json.dumps(result, default=str)
        return text if len(text) <= 20_000 else text[:20_000] + "... [truncated]"

    return run_python


def sub_agent_tool(name: str, description: str, run: Callable[[str], Awaitable[str]]) -> BaseTool:
    """Expose another agent as a tool. ``run`` executes it with the same caller."""

    async def _call(task: str) -> str:
        return await run(task)

    return StructuredTool.from_function(
        coroutine=_call,
        name=f"ask_{name}",
        description=(
            f"Delegate a self-contained task to the {name} agent. {description} "
            "Pass the full task in `task`; it cannot see this conversation."
        ),
    )
