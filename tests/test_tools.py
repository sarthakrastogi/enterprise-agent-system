import base64
import importlib.util
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(path: str, name: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


def token(claims):
    enc = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()
    return f"{enc({'alg': 'none'})}.{enc(claims)}.sig"


interceptor = load("lambdas/interceptor/handler.py", "interceptor_handler")
kb = load("mcp_servers/knowledge/server.py", "kb_server")


def event(name, args, claims):
    return {"interceptorInputVersion": "1.0", "mcp": {"gatewayRequest": {
        "headers": {"Authorization": f"Bearer {token(claims)}"},
        "body": {"jsonrpc": "2.0", "id": 7, "method": "tools/call",
                 "params": {"name": name, "arguments": args}},
    }}}


def test_interceptor_overwrites_spoofed_requester():
    out = interceptor.handler(event("tickets___create_ticket",
                                    {"summary": "x", "requester": "someone-else"}, {"sub": "real-user"}), None)
    args = out["mcp"]["transformedGatewayRequest"]["body"]["params"]["arguments"]
    assert args["requester"] == "real-user" and args["summary"] == "x"


def test_interceptor_ignores_other_targets_and_methods():
    out = interceptor.handler(event("knowledge___search_policies", {"query": "vpn"}, {"sub": "u"}), None)
    assert "requester" not in out["mcp"]["transformedGatewayRequest"]["body"]["params"]["arguments"]
    listing = {"mcp": {"gatewayRequest": {"body": {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}}}}
    assert interceptor.handler(listing, None)["mcp"]["transformedGatewayRequest"]["body"]["method"] == "tools/list"


def test_interceptor_fails_closed_without_identity():
    ev = event("tickets___list_my_tickets", {}, {})
    out = interceptor.handler(ev, None)
    assert out["mcp"]["transformedGatewayResponse"]["body"]["error"]["code"] == -32001


def test_knowledge_search_and_get():
    hits = kb.search_policies("mfa password length")
    assert hits and hits[0]["policy_id"] == "password-policy"
    assert "14 characters" in kb.get_policy("password-policy")["text"]
    assert "error" in kb.get_policy("nope")
    assert kb.search_policies("zzzz qqqq") == []
