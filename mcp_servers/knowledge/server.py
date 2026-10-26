"""Company knowledge base, exposed as an MCP server on AgentCore Runtime.

Run locally:   python server.py          (serves http://localhost:8000/mcp)
Deployed:      AgentCore Runtime, protocol MCP, behind the Gateway as target "knowledge".

The policies are a tiny in-repo corpus so the platform works out of the box.
Replace `search_policies` with a call to your real search (Bedrock Knowledge
Bases, OpenSearch, SharePoint...) and keep the tool contract the same.
"""

from __future__ import annotations

import re
from pathlib import Path

from mcp.server.fastmcp import FastMCP

POLICY_DIR = Path(__file__).parent / "policies"

mcp = FastMCP("knowledge", host="0.0.0.0", port=8000, stateless_http=True)


def _policies() -> dict[str, str]:
    return {p.stem: p.read_text(encoding="utf-8") for p in sorted(POLICY_DIR.glob("*.md"))}


def _title(text: str) -> str:
    first = text.strip().splitlines()[0] if text.strip() else ""
    return first.lstrip("# ").strip()


@mcp.tool()
def search_policies(query: str, limit: int = 3) -> list[dict]:
    """Search company IT policies by keywords.

    Returns up to `limit` matches as {policy_id, title, snippet}, best first.
    Use get_policy with a policy_id to read the full text before quoting it.
    Returns an empty list when nothing matches; don't guess policy in that case.
    """
    terms = [t for t in re.findall(r"[a-z0-9]+", query.lower()) if len(t) > 2]
    scored = []
    for pid, text in _policies().items():
        lower = text.lower()
        score = sum(lower.count(t) for t in terms)
        if score:
            idx = min((lower.find(t) for t in terms if t in lower), default=0)
            snippet = " ".join(text[max(0, idx - 80): idx + 220].split())
            scored.append((score, {"policy_id": pid, "title": _title(text), "snippet": snippet}))
    scored.sort(key=lambda s: -s[0])
    return [item for _, item in scored[: max(1, min(limit, 10))]]


@mcp.tool()
def get_policy(policy_id: str) -> dict:
    """Return the full text of one policy by its policy_id (from search_policies)."""
    policies = _policies()
    if policy_id not in policies:
        return {"error": f"no policy {policy_id!r}", "available": sorted(policies)}
    text = policies[policy_id]
    return {"policy_id": policy_id, "title": _title(text), "text": text}


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
