"""Enterprise Agent Platform SDK.

Define an agent:

    from eap import AgentSpec

    agent = AgentSpec(
        name="it_helpdesk",
        description="Answers IT questions and files tickets.",
        system_prompt="You are the IT helpdesk...",
        tools=["tickets___create_ticket"],
    )
"""

from eap.spec import DEFAULT_MODEL_ID, AgentSpec, prompt_from_file

__all__ = ["AgentSpec", "DEFAULT_MODEL_ID", "prompt_from_file"]
