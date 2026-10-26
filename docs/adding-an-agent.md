# Adding an agent

1. **Write the prompt.** Create `agents/prompts/<name>.md`. Describe the job, how to use tools, when to stop or escalate, and the output format.
2. **Define the agent.** Create `agents/<name>.py` with a single `agent = AgentSpec(...)`.
3. **Validate.** Run `make manifest`. It imports every agent and fails on mistakes: bad names, unknown sub-agents, cycles.
4. **Deploy.** Run `make deploy`.

```python
from eap import AgentSpec, prompt_from_file

agent = AgentSpec(
    name="onboarding",                      # [a-z][a-z0-9_], max 32; becomes the runtime name
    display_name="Onboarding Buddy",        # shown in the UI
    description="Helps new starters with accounts, equipment and first-week tasks.",
    system_prompt=prompt_from_file("prompts/onboarding.md", relative_to=__file__),
    model_id="global.anthropic.claude-sonnet-4-5-20250929-v1:0",
    temperature=0.2,
    max_tokens=4096,
    tools=["knowledge___search_policies", "tickets___create_ticket"],  # gateway tools; ["*"] = all permitted
    builtin_tools=["code_interpreter"],     # AgentCore Code Interpreter
    sub_agents=["data_analyst"],            # delegate to other agents (in-process, same user)
    memory=True,                            # remember facts/preferences per user across sessions
    allowed_groups=["employees"],           # Cognito groups that may invoke it
    version="0.1.0",
)
```

## Field reference

| Field | Default | Notes |
|---|---|---|
| `name` | required | Renaming creates a new agent with new history. |
| `description` | required | Also used as the tool description when this agent is a sub-agent, so write it for a model. |
| `system_prompt` | required | The runtime appends the user's name and any recalled memories. |
| `model_id` | `DEFAULT_MODEL_ID` | Any Bedrock model or inference profile enabled in your account. |
| `tools` | `()` | Gateway tool names `<target>___<tool>`. Cedar policy still applies per user. |
| `builtin_tools` | `()` | `code_interpreter`. |
| `sub_agents` | `()` | Names of other agents. Cycles are rejected. |
| `local_tools` | `()` | LangChain tools defined in Python, for logic only this agent needs. |
| `memory` | `False` | Uses the shared AgentCore Memory (namespaces `/users/{actorId}/...`). |
| `allowed_groups` | `()` | Empty means any signed-in user. |
| `graph_factory` | `None` | Your own LangGraph; see below. |

## Local tools

```python
from langchain_core.tools import tool

@tool
def business_days_between(start: str, end: str) -> int:
    """Count business days between two ISO dates, inclusive."""
    ...

agent = AgentSpec(..., local_tools=[business_days_between])
```

Use local tools for pure logic. Anything that touches company systems belongs behind the gateway, where it gets policy, the interceptor and audit.

## A fixed workflow instead of the autonomous loop

```python
from langgraph.graph import StateGraph, MessagesState, START, END

def triage_graph(*, model, tools, system_prompt, checkpointer):
    def classify(state: MessagesState):
        reply = model.invoke([("system", system_prompt + "\nReply with one word: bug, access or other."), *state["messages"]])
        return {"messages": [reply]}

    g = StateGraph(MessagesState)
    g.add_node("classify", classify)
    g.add_edge(START, "classify")
    g.add_edge("classify", END)
    return g.compile(checkpointer=checkpointer)

agent = AgentSpec(..., graph_factory=triage_graph)
```

The graph must accept `{"messages": [...]}` and stream message chunks from a node named `model` so the UI sees text. Otherwise, emit the final message from your last node.

## Testing locally

```bash
make dev-agent AGENT=onboarding        # serves :8080 with LOCAL_DEV=1 (no JWT), real Bedrock via your AWS creds
curl -N localhost:8080/invocations -H 'Content-Type: application/json' -d '{"prompt":"hello"}'
```

Without `GATEWAY_URL` the agent runs with no gateway tools. Point `GATEWAY_URL` at a deployed gateway and send a real bearer token to test with tools.
