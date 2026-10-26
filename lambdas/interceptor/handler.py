"""AgentCore Gateway REQUEST interceptor: stamp the real user onto tool calls.

For every `tools/call` to a target listed in IDENTITY_TARGETS, the `requester`
argument is replaced with the `sub` of the caller's access token. The gateway's
CUSTOM_JWT authorizer validated that token before this runs, so decoding
without verifying the signature is safe here. Anything the model put in
`requester` is discarded, which stops one user acting as another.
"""

from __future__ import annotations

import base64
import json
import os

IDENTITY_TARGETS = tuple(t for t in os.environ.get("IDENTITY_TARGETS", "tickets").split(",") if t)


def _claims(headers: dict) -> dict:
    auth = next((v for k, v in (headers or {}).items() if k.lower() == "authorization"), "")
    token = auth.split(" ", 1)[1] if auth.lower().startswith("bearer ") else ""
    try:
        payload = token.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except (IndexError, ValueError):
        return {}


def _passthrough(body):
    return {"interceptorOutputVersion": "1.0", "mcp": {"transformedGatewayRequest": {"body": body}}}


def handler(event, context):
    request = (event.get("mcp") or {}).get("gatewayRequest") or {}
    body = request.get("body") or {}
    if body.get("method") != "tools/call":
        return _passthrough(body)

    params = body.get("params") or {}
    if not str(params.get("name", "")).startswith(tuple(f"{t}___" for t in IDENTITY_TARGETS)):
        return _passthrough(body)

    sub = _claims(request.get("headers") or {}).get("sub")
    if not sub:
        # Fail closed: answer the call ourselves instead of forwarding it.
        return {
            "interceptorOutputVersion": "1.0",
            "mcp": {"transformedGatewayResponse": {"statusCode": 200, "body": {
                "jsonrpc": "2.0", "id": body.get("id"),
                "error": {"code": -32001, "message": "caller identity unavailable"},
            }}},
        }

    arguments = dict(params.get("arguments") or {})
    arguments["requester"] = sub
    new_body = {**body, "params": {**params, "arguments": arguments}}
    return _passthrough(new_body)
