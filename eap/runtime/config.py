"""Runtime settings, read once from environment variables set by Terraform."""

from __future__ import annotations

import os
from dataclasses import dataclass
from functools import lru_cache


@dataclass(frozen=True)
class Settings:
    agent_name: str
    region: str
    gateway_url: str
    memory_id: str
    guardrail_id: str
    guardrail_version: str
    code_interpreter_id: str
    local_dev: bool

    @property
    def gateway_mcp_url(self) -> str:
        url = self.gateway_url.rstrip("/")
        if not url:
            return ""
        return url if url.endswith("/mcp") else f"{url}/mcp"


@lru_cache(maxsize=1)
def settings() -> Settings:
    env = os.environ
    return Settings(
        agent_name=env["AGENT_NAME"],
        region=env.get("AWS_REGION") or env.get("AWS_DEFAULT_REGION", "us-west-2"),
        gateway_url=env.get("GATEWAY_URL", ""),
        memory_id=env.get("MEMORY_ID", ""),
        guardrail_id=env.get("GUARDRAIL_ID", ""),
        guardrail_version=env.get("GUARDRAIL_VERSION", ""),
        code_interpreter_id=env.get("CODE_INTERPRETER_ID", "aws.codeinterpreter.v1"),
        # LOCAL_DEV=1 lets you run the container on a laptop without a JWT.
        local_dev=env.get("LOCAL_DEV", "") == "1",
    )
