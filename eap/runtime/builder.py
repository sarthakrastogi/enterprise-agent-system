"""Turn an AgentSpec into a runnable LangGraph agent for one caller."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from langchain_core.language_models import BaseChatModel
from langchain_core.tools import BaseTool

from eap.registry import load_agents
from eap.runtime import memory
from eap.runtime.config import Settings
from eap.runtime.identity import Caller
from eap.runtime.tools import code_interpreter_tool, gateway_tools, sub_agent_tool
from eap.spec import AgentSpec


@dataclass
class BuiltAgent:
    graph: Any            # compiled LangGraph
    config: dict          # RunnableConfig with thread/actor ids


def make_model(spec: AgentSpec, s: Settings) -> BaseChatModel:
    from langchain_aws import ChatBedrockConverse

    kwargs: dict[str, Any] = {}
    if s.guardrail_id:
        kwargs["guardrail_config"] = {
            "guardrailIdentifier": s.guardrail_id,
            "guardrailVersion": s.guardrail_version or "DRAFT",
            "trace": "enabled",
        }
    return ChatBedrockConverse(
        model_id=spec.model_id,
        region_name=s.region,
        temperature=spec.temperature,
        max_tokens=spec.max_tokens,
        **kwargs,
    )


def _system_prompt(spec: AgentSpec, caller: Caller, recalled: str) -> str:
    parts = [spec.system_prompt.strip()]
    parts.append(f"You are talking to {caller.username}.")
    if recalled:
        parts.append(
            "What you remember about this user from earlier conversations "
            "(may be out of date; prefer what they say now):\n" + recalled
        )
    return "\n\n".join(parts)


async def build_agent(
    spec: AgentSpec,
    caller: Caller,
    session_id: str,
    s: Settings,
    *,
    user_text: str = "",
    depth: int = 0,
) -> BuiltAgent:
    tools: list[BaseTool] = list(spec.local_tools)
    tools += await gateway_tools(s.gateway_mcp_url, caller.access_token, spec.tools)
    if "code_interpreter" in spec.builtin_tools:
        tools.append(code_interpreter_tool(s.region, s.code_interpreter_id))
    specs = load_agents()
    for child_name in spec.sub_agents:
        tools.append(_delegate(specs[child_name], caller, session_id, s, depth))

    recalled = ""
    if spec.memory and depth == 0:
        recalled = memory.recall(s.memory_id, s.region, caller.user_id, user_text)

    model = make_model(spec, s)
    prompt = _system_prompt(spec, caller, recalled)
    saver = memory.checkpointer(s.memory_id if spec.memory else "", s.region)

    if spec.graph_factory is not None:
        graph = spec.graph_factory(model=model, tools=tools, system_prompt=prompt, checkpointer=saver)
    else:
        from langchain.agents import create_agent

        # The default: an autonomous tool-calling loop. The model decides which
        # tools to call and when it is done.
        graph = create_agent(model, tools, system_prompt=prompt, checkpointer=saver, name=spec.name)

    thread = session_id if depth == 0 else f"{session_id}-{spec.name}"
    config = {
        "configurable": {"thread_id": thread, "actor_id": caller.user_id},
        "recursion_limit": 50,
        "metadata": {"agent": spec.name, "user": caller.user_id},
    }
    return BuiltAgent(graph=graph, config=config)


def _delegate(child: AgentSpec, caller: Caller, session_id: str, s: Settings, depth: int) -> BaseTool:
    async def run(task: str) -> str:
        built = await build_agent(child, caller, session_id, s, user_text=task, depth=depth + 1)
        result = await built.graph.ainvoke({"messages": [{"role": "user", "content": task}]}, built.config)
        return result["messages"][-1].text

    return sub_agent_tool(child.name, child.description, run)
