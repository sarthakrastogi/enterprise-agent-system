"""Runs the real entrypoint with a scripted fake model (no AWS calls)."""

import asyncio
import base64
import json
from types import SimpleNamespace
from typing import Any

import pytest
from langchain_core.language_models.fake_chat_models import GenericFakeChatModel
from langchain_core.messages import AIMessage

from eap.runtime import builder, config
from eap.runtime import app as runtime_app
from eap.runtime.identity import Unauthenticated, caller_from_headers


class ScriptedModel(GenericFakeChatModel):
    """Fake chat model that supports bind_tools and replays scripted messages."""

    def bind_tools(self, tools: Any, **kwargs: Any):
        return self


def fake_jwt(claims: dict) -> str:
    enc = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()
    return f"{enc({'alg': 'none'})}.{enc(claims)}.sig"


@pytest.fixture(autouse=True)
def env(monkeypatch):
    monkeypatch.setenv("AGENT_NAME", "it_helpdesk")
    monkeypatch.setenv("AWS_REGION", "us-west-2")
    monkeypatch.setenv("LOCAL_DEV", "1")  # skips CloudWatch metrics; tokens still parsed when present
    monkeypatch.delenv("MEMORY_ID", raising=False)
    monkeypatch.delenv("GATEWAY_URL", raising=False)
    config.settings.cache_clear()
    yield
    config.settings.cache_clear()


def run(payload, headers):
    ctx = SimpleNamespace(request_headers=headers, session_id="s" * 40)

    async def collect():
        return [e async for e in runtime_app.invoke(payload, ctx)]

    return asyncio.run(collect())


def test_identity_comes_from_token_not_payload():
    tok = fake_jwt({"sub": "abc-123", "username": "alice", "cognito:groups": ["employees"]})
    caller = caller_from_headers({"Authorization": f"Bearer {tok}"})
    assert caller.user_id == "abc-123" and caller.groups == ("employees",)
    with pytest.raises(Unauthenticated):
        caller_from_headers({})


def test_rejects_bad_payload():
    events = run({"prompt": 123}, {})
    assert events[0]["type"] == "error"


def test_streams_parent_text_and_hides_sub_agent_tokens(monkeypatch):
    parent_script = iter([
        AIMessage(content="", tool_calls=[{"name": "ask_data_analyst", "args": {"task": "2+2"}, "id": "c1"}]),
        AIMessage(content="The analyst says 4."),
    ])
    child_script = iter([AIMessage(content="SUB-AGENT SECRET 4")])

    def fake_model(spec, s):
        script = child_script if spec.name == "data_analyst" else parent_script
        return ScriptedModel(messages=script)

    monkeypatch.setattr(builder, "make_model", fake_model)
    tok = fake_jwt({"sub": "user-1", "username": "alice"})
    events = run({"prompt": "what is 2+2?"}, {"Authorization": f"Bearer {tok}"})

    text = "".join(e["data"] for e in events if e["type"] == "text")
    assert "The analyst says 4." in text
    assert "SUB-AGENT SECRET" not in text
    assert {"type": "tool_result", "name": "ask_data_analyst", "ok": True} in events
    assert events[-1] == {"type": "done"}
