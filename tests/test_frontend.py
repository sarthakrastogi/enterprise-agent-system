"""Drive the Streamlit chat UI with a fake signed-in user and a fake agent stream."""

import json
from pathlib import Path

import pytest
import streamlit
from streamlit.testing.v1 import AppTest

APP = str(Path(__file__).resolve().parents[1] / "frontend" / "app.py")
SECRETS = {
    "region": "us-west-2",
    "feedback_log_group": "/eap/feedback",
    "agents": [
        {"name": "it_helpdesk", "display_name": "IT Helpdesk", "description": "IT help", "arn": "arn:aws:bedrock-agentcore:us-west-2:1:runtime/eap_it_helpdesk-abc"},
        {"name": "data_analyst", "display_name": "Data Analyst", "description": "Numbers", "arn": "arn:aws:bedrock-agentcore:us-west-2:1:runtime/eap_data_analyst-def"},
    ],
}


class FakeUser(dict):
    tokens = {"access": "user-access-token"}


class FakeResponse:
    def __init__(self, status, events):
        self.status_code, self._events, self.text = status, events, "denied"

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def raise_for_status(self):
        pass

    def iter_lines(self, decode_unicode=True):
        for e in self._events:
            yield "data: " + json.dumps(e)


def app(monkeypatch, logged_in=True):
    user = FakeUser(is_logged_in=logged_in, email="alice@example.com", sub="u-1")
    monkeypatch.setattr(streamlit, "user", user)
    at = AppTest.from_file(APP, default_timeout=10)
    at.secrets["platform"] = SECRETS
    return at


def test_logged_out_shows_sign_in(monkeypatch):
    at = app(monkeypatch, logged_in=False)
    at.run()
    assert not at.exception
    assert [b.label for b in at.button] == ["Sign in"]


def test_chat_streams_answer_with_user_token(monkeypatch):
    calls = []

    def fake_post(url, headers, data, stream, timeout):
        calls.append((url, headers, json.loads(data)))
        return FakeResponse(200, [
            {"type": "tool_call", "name": "knowledge___search_policies"},
            {"type": "tool_result", "name": "knowledge___search_policies", "ok": True},
            {"type": "text", "data": "Passwords need "},
            {"type": "text", "data": "14 characters."},
            {"type": "done"},
        ])

    import requests
    monkeypatch.setattr(requests, "post", fake_post)
    at = app(monkeypatch)
    at.run()
    assert not at.exception
    at.chat_input[0].set_value("How long must passwords be?").run()
    assert not at.exception

    url, headers, payload = calls[0]
    assert "runtimes/arn%3Aaws%3Abedrock-agentcore%3Aus-west-2%3A1%3Aruntime%2Feap_it_helpdesk-abc/invocations" in url
    assert headers["Authorization"] == "Bearer user-access-token"
    assert len(headers["X-Amzn-Bedrock-AgentCore-Runtime-Session-Id"]) >= 33
    assert payload == {"prompt": "How long must passwords be?"}
    texts = [m.value for m in at.markdown]
    assert "Passwords need 14 characters." in texts


def test_expired_token_asks_to_sign_in_again(monkeypatch):
    import requests
    monkeypatch.setattr(requests, "post", lambda *a, **k: FakeResponse(401, []))
    at = app(monkeypatch)
    at.run()
    at.chat_input[0].set_value("hi").run()
    assert not at.exception
    assert any("expired" in w.value for w in at.warning)
