"""AgentSpec: the one object a platform user writes to define an agent.

An agent is a Python file in ``agents/`` that creates exactly one ``AgentSpec``
named ``agent``. Everything else (hosting, auth, memory, tools, observability,
evaluation) is supplied by the platform.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Any, Callable

if TYPE_CHECKING:
    from langchain_core.tools import BaseTool

# AgentCore runtime names allow [a-zA-Z][a-zA-Z0-9_]{0,47}; we keep a margin for
# the "<prefix>_" Terraform adds and stay lowercase for predictable resource names.
_NAME_RE = re.compile(r"^[a-z][a-z0-9_]{1,31}$")

BUILTIN_TOOLS = {"code_interpreter"}

DEFAULT_MODEL_ID = "global.anthropic.claude-sonnet-4-5-20250929-v1:0"


@dataclass(frozen=True)
class AgentSpec:
    """Declarative definition of an agent.

    Attributes:
        name: Unique id, lowercase ``[a-z][a-z0-9_]``, max 32 chars. Becomes the
            AgentCore runtime name, so renaming creates a new agent.
        description: One sentence shown in the chat UI and used when another
            agent calls this one as a tool. Write it for the model, not for humans.
        system_prompt: The instructions. Use ``prompt_from_file`` to keep long
            prompts in markdown next to the agent file.
        display_name: Label in the chat UI. Defaults to a title-cased ``name``.
        model_id: Bedrock model or inference profile id.
        temperature / max_tokens: Model settings.
        tools: Gateway tool names (``<target>___<tool>``) this agent may use.
            ``["*"]`` means every tool the signed-in user is allowed to see.
            Gateway Cedar policy still decides per user; this list only narrows.
        builtin_tools: Platform-provided tools, e.g. ``"code_interpreter"``.
        sub_agents: Names of other agents this agent can delegate to. They run
            in-process as tools, with the same user identity.
        local_tools: Extra LangChain tools defined in Python. Use for logic that
            is specific to this agent and not worth an MCP server.
        memory: Remember facts and preferences about each user across sessions.
        allowed_groups: Cognito groups allowed to invoke the agent. Empty means
            any signed-in user. Enforced by the runtime's JWT authorizer.
        graph_factory: Escape hatch. A callable ``(model, tools, system_prompt,
            checkpointer) -> compiled LangGraph`` for agents that need a fixed
            workflow instead of the default autonomous tool-calling loop.
        version: Free-form version string, surfaced as a runtime tag.
    """

    name: str
    description: str
    system_prompt: str
    display_name: str = ""
    model_id: str = DEFAULT_MODEL_ID
    temperature: float = 0.2
    max_tokens: int = 4096
    tools: tuple[str, ...] = ()
    builtin_tools: tuple[str, ...] = ()
    sub_agents: tuple[str, ...] = ()
    local_tools: tuple["BaseTool", ...] = field(default=(), compare=False)
    memory: bool = False
    allowed_groups: tuple[str, ...] = ()
    graph_factory: Callable[..., Any] | None = field(default=None, compare=False)
    version: str = "0.1.0"

    def __post_init__(self) -> None:
        # Accept lists from users, store tuples so specs stay hashable/immutable.
        for attr in ("tools", "builtin_tools", "sub_agents", "local_tools", "allowed_groups"):
            object.__setattr__(self, attr, tuple(getattr(self, attr)))
        if not self.display_name:
            object.__setattr__(self, "display_name", self.name.replace("_", " ").title())
        self.validate()

    def validate(self) -> None:
        if not _NAME_RE.match(self.name):
            raise ValueError(
                f"agent name {self.name!r} must match {_NAME_RE.pattern} "
                "(lowercase letters, digits, underscores; max 32 chars)"
            )
        if not self.description.strip():
            raise ValueError(f"agent {self.name!r}: description is required")
        if not self.system_prompt.strip():
            raise ValueError(f"agent {self.name!r}: system_prompt is required")
        unknown = set(self.builtin_tools) - BUILTIN_TOOLS
        if unknown:
            raise ValueError(f"agent {self.name!r}: unknown builtin_tools {sorted(unknown)}")
        if self.name in self.sub_agents:
            raise ValueError(f"agent {self.name!r} cannot list itself as a sub-agent")
        if not 0.0 <= self.temperature <= 1.0:
            raise ValueError(f"agent {self.name!r}: temperature must be between 0 and 1")

    def manifest(self) -> dict[str, Any]:
        """The subset of the spec Terraform needs to create infrastructure."""
        return {
            "name": self.name,
            "display_name": self.display_name,
            "description": self.description,
            "memory": self.memory,
            "code_interpreter": "code_interpreter" in self.builtin_tools,
            "allowed_groups": list(self.allowed_groups),
            "version": self.version,
        }


def prompt_from_file(path: str | Path, relative_to: str | None = None) -> str:
    """Read a prompt file. Pass ``__file__`` as ``relative_to`` to resolve next to the agent."""
    p = Path(path)
    if relative_to is not None and not p.is_absolute():
        p = Path(relative_to).parent / p
    return p.read_text(encoding="utf-8")
