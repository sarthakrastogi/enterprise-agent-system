"""The shared AgentCore Runtime entrypoint. Every agent runs this same image.

Request payload:  {"prompt": "..."}
Response (SSE):   data: {"type": "text", "data": "..."}
                  data: {"type": "tool_call", "name": "tickets___create_ticket"}
                  data: {"type": "tool_result", "name": "tickets___create_ticket", "ok": true}
                  data: {"type": "done"}
                  data: {"type": "error", "message": "..."}
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Any, AsyncIterator

from bedrock_agentcore.runtime import BedrockAgentCoreApp

from eap.registry import load_agents
from eap.runtime import memory, metrics
from eap.runtime.builder import build_agent
from eap.runtime.config import settings
from eap.runtime.identity import Unauthenticated, caller_from_headers

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("eap.runtime")

app = BedrockAgentCoreApp()

MAX_PROMPT_CHARS = 20_000


def _top_level_node(meta: dict[str, Any]) -> str | None:
    # Sub-agents run inside a tool call; their messages surface with a nested
    # checkpoint namespace ("tools:...|model:..."). Only stream the parent's.
    if "|" in meta.get("langgraph_checkpoint_ns", ""):
        return None
    return meta.get("langgraph_node")


@app.entrypoint
async def invoke(payload: dict, context) -> AsyncIterator[dict]:
    s = settings()
    prompt = payload.get("prompt") if isinstance(payload, dict) else None
    if not isinstance(prompt, str) or not prompt.strip():
        yield {"type": "error", "message": "payload must be {\"prompt\": \"<non-empty string>\"}"}
        return
    if len(prompt) > MAX_PROMPT_CHARS:
        yield {"type": "error", "message": f"prompt longer than {MAX_PROMPT_CHARS} characters"}
        return

    try:
        caller = caller_from_headers(context.request_headers, local_dev=s.local_dev)
    except Unauthenticated as e:
        yield {"type": "error", "message": str(e)}
        return

    spec = load_agents()[s.agent_name]
    session_id = context.session_id or "local-session-0000000000000000000000"
    started = time.monotonic()
    answer: list[str] = []
    tool_calls = 0

    async def record(ok: bool) -> None:
        await asyncio.to_thread(
            metrics.publish, s.region, spec.name, ok=ok, tool_calls=tool_calls,
            latency_ms=(time.monotonic() - started) * 1000, local_dev=s.local_dev,
        )

    try:
        built = await build_agent(spec, caller, session_id, s, user_text=prompt)
        async for chunk, meta in built.graph.astream(
            {"messages": [{"role": "user", "content": prompt}]},
            built.config,
            stream_mode="messages",
        ):
            node = _top_level_node(meta)
            if node == "tools" and chunk.type == "tool":
                tool_calls += 1
                yield {"type": "tool_result", "name": chunk.name, "ok": chunk.status != "error"}
                continue
            if node != "model":
                continue
            for call in getattr(chunk, "tool_call_chunks", None) or []:
                if call.get("name"):
                    yield {"type": "tool_call", "name": call["name"]}
            text = chunk.text
            if text:
                answer.append(text)
                yield {"type": "text", "data": text}
    except Exception as e:  # surface a clean error to the UI; full trace goes to CloudWatch
        log.exception("agent run failed")
        await record(ok=False)
        yield {"type": "error", "message": f"{type(e).__name__}: {e}"}
        return

    if spec.memory:
        await asyncio.to_thread(
            memory.remember, s.memory_id, s.region, caller.user_id, session_id, prompt, "".join(answer)
        )
    await record(ok=True)
    yield {"type": "done"}


def main() -> None:
    load_agents()  # fail fast on a bad agent definition
    app.run()      # 0.0.0.0:8080, POST /invocations, GET /ping


if __name__ == "__main__":
    main()
