"""Who is calling: derived from the JWT the runtime authorizer already validated."""

from __future__ import annotations

import re
from dataclasses import dataclass

import jwt


class Unauthenticated(Exception):
    pass


@dataclass(frozen=True)
class Caller:
    user_id: str          # stable id used as the AgentCore Memory actor id
    username: str
    groups: tuple[str, ...]
    access_token: str     # forwarded to Gateway so tool policy sees the real user


_SAFE_ACTOR = re.compile(r"[^a-zA-Z0-9_-]")


def caller_from_headers(headers: dict[str, str] | None, *, local_dev: bool = False) -> Caller:
    """Build the caller from the Authorization header.

    The AgentCore runtime's CUSTOM_JWT authorizer has already verified the
    token's signature, issuer, client id and group claim before the request
    reaches this code, so we only decode it here. Never derive the user id from
    the request payload: the payload is controlled by the client.
    """
    headers = {k.lower(): v for k, v in (headers or {}).items()}
    auth = headers.get("authorization", "")
    if not auth.lower().startswith("bearer "):
        if local_dev:
            return Caller(user_id="local-dev", username="local-dev", groups=(), access_token="")
        raise Unauthenticated(
            "no bearer token reached the agent; check request_header_allowlist includes Authorization"
        )
    token = auth.split(" ", 1)[1].strip()
    claims = jwt.decode(token, options={"verify_signature": False})
    sub = claims.get("sub")
    if not sub:
        raise Unauthenticated("token has no sub claim")
    return Caller(
        user_id=_SAFE_ACTOR.sub("-", sub),
        username=claims.get("username") or claims.get("cognito:username") or sub,
        groups=tuple(claims.get("cognito:groups", []) or []),
        access_token=token,
    )
