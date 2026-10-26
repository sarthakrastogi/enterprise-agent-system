"""AgentCore Memory wiring.

Short-term: the LangGraph checkpointer stores the conversation per session, so a
user can continue a chat even after the microVM is recycled.

Long-term: user and assistant turns are written as conversational events.
AgentCore's semantic and user-preference strategies extract durable records
asynchronously into ``/users/{actorId}/facts/`` and ``/users/{actorId}/preferences/``
(see infra/memory.tf). Before each turn we search those namespaces and give the
model what we find.
"""

from __future__ import annotations

import logging
import uuid
from functools import lru_cache

from langchain_core.messages import AIMessage, HumanMessage
from langgraph.checkpoint.memory import InMemorySaver

log = logging.getLogger(__name__)

# Must match namespace_templates in infra/memory.tf. The trailing "" makes the
# search path end with "/" so actor "bob" never matches actor "bob2".
FACTS_NS = ("users", "{actor}", "facts", "")
PREFS_NS = ("users", "{actor}", "preferences", "")


@lru_cache(maxsize=1)
def _in_memory_saver() -> InMemorySaver:
    # One per microVM; AgentCore pins a session to one microVM, so this is
    # enough for multi-turn chats when long-term memory is disabled.
    return InMemorySaver()


def checkpointer(memory_id: str, region: str):
    if not memory_id:
        return _in_memory_saver()
    from langgraph_checkpoint_aws import AgentCoreMemorySaver

    return AgentCoreMemorySaver(memory_id, region_name=region)


def _store(memory_id: str, region: str):
    from langgraph_checkpoint_aws import AgentCoreMemoryStore

    return AgentCoreMemoryStore(memory_id, region_name=region)


def _ns(template: tuple[str, ...], actor: str) -> tuple[str, ...]:
    return tuple(part.replace("{actor}", actor) for part in template)


def recall(memory_id: str, region: str, actor: str, query: str, limit: int = 5) -> str:
    """Return a short block of remembered facts/preferences, or "" if none."""
    if not memory_id:
        return ""
    try:
        store = _store(memory_id, region)
        lines: list[str] = []
        for label, template in (("Preference", PREFS_NS), ("Fact", FACTS_NS)):
            for item in store.search(_ns(template, actor), query=query, limit=limit):
                text = (item.value or {}).get("content") or (item.value or {}).get("text")
                if isinstance(text, dict):
                    text = text.get("text")
                if text:
                    lines.append(f"- {label}: {text}")
        return "\n".join(lines)
    except Exception:  # memory must never break a chat turn
        log.exception("memory recall failed")
        return ""


def remember(memory_id: str, region: str, actor: str, session_id: str, user_text: str, answer: str) -> None:
    """Write the turn as conversational events so long-term strategies can extract from it."""
    if not memory_id or not answer:
        return
    try:
        store = _store(memory_id, region)
        store.put((actor, session_id), str(uuid.uuid4()), {"message": HumanMessage(user_text)})
        store.put((actor, session_id), str(uuid.uuid4()), {"message": AIMessage(answer)})
    except Exception:
        log.exception("memory write failed")
