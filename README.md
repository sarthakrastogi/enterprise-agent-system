# Enterprise Agent Platform

An open-source, batteries-included platform for running AI agents in a company, built on **AWS Bedrock AgentCore** and managed entirely with **Terraform**. No console clicks.

- **Define an agent in a few lines of Python.** Set a prompt, tools and a model in an `AgentSpec`. The platform handles hosting, auth, memory, tools, tracing and evaluation.
- **Write tools as Python MCP servers** (FastMCP) or Lambda functions. All of them sit behind one governed **AgentCore Gateway**.
- **Every call runs as the signed-in user.** A user's token flows from the chat UI to the agent, the gateway, the tool policy and the tool.
- **Observability on CloudWatch out of the box.** You get OTEL traces, the GenAI Observability console, a dashboard, alarms, user feedback and LLM-judged online evaluations.
- **A simple Python chat UI** (Streamlit) with SSO, an agent picker and streaming.

```
 Browser ──OIDC──▶ Cognito
    │
    ▼
 Streamlit chat UI ──Bearer user JWT──▶ AgentCore Runtime (one per agent, same image)
                                         │  LangGraph autonomous agent
                                         │  + Bedrock model with Guardrails
                                         │  + AgentCore Memory (per user)
                                         │  + Code Interpreter, sub-agents
                                         │
                                         └──user JWT──▶ AgentCore Gateway (MCP)
                                                         │  JWT authorizer
                                                         │  request interceptor (stamps real user)
                                                         │  Cedar policy (per-user tool access)
                                                         ├──SigV4──▶ knowledge MCP server (Runtime, FastMCP)
                                                         └──SigV4──▶ tickets Lambda (DynamoDB)

 Everything ──OTEL / vended logs / metrics──▶ CloudWatch ──▶ Online evaluations, dashboard, alarms
```

## What's in the box

| Need | How it's done | Where |
|---|---|---|
| Agents defined without boilerplate | `AgentSpec` in `agents/<name>.py`, prompt in markdown | [agents/](agents/), [eap/spec.py](eap/spec.py) |
| Agent hosting | One AgentCore Runtime per agent, all running the same LangGraph image; microVM per session, 8h sessions | [eap/runtime/](eap/runtime/), [infra/agents.tf](infra/agents.tf) |
| Free, autonomous agents | LangChain `create_agent` tool-calling loop (custom LangGraph graphs optional) | [eap/runtime/builder.py](eap/runtime/builder.py) |
| Multi-agent | `sub_agents=[...]`: agents call other agents as tools, with the same user identity | [agents/it_helpdesk.py](agents/it_helpdesk.py) |
| Python MCP servers | FastMCP on AgentCore Runtime (`server_protocol = "MCP"`), reachable only through the gateway | [mcp_servers/knowledge/](mcp_servers/knowledge/), [infra/mcp_servers.tf](infra/mcp_servers.tf) |
| Lambda tools | Gateway Lambda target with Terraform-declared tool schemas | [lambdas/tickets/](lambdas/tickets/), [infra/gateway.tf](infra/gateway.tf) |
| Tool gateway | AgentCore Gateway: JWT inbound, semantic tool search, request interceptor | [infra/gateway.tf](infra/gateway.tf), [lambdas/interceptor/](lambdas/interceptor/) |
| Per-user tool permissions | Cedar policies at the gateway (default deny; admin-only tools) | [infra/policy.tf](infra/policy.tf) |
| SSO and identity | Cognito user pool and groups; runtime JWT authorizer with group check | [infra/auth.tf](infra/auth.tf) |
| Memory | AgentCore Memory: conversation checkpoints plus long-term facts/preferences per user | [eap/runtime/memory.py](eap/runtime/memory.py), [infra/memory.tf](infra/memory.tf) |
| Safety | Bedrock Guardrail on every model call (prompt attacks, harmful content, secrets/PII) | [infra/guardrail.tf](infra/guardrail.tf) |
| Code execution | AgentCore Code Interpreter as a built-in tool | [eap/runtime/tools.py](eap/runtime/tools.py) |
| Observability | ADOT/OTEL traces, Transaction Search, vended gateway/memory logs, usage logs, dashboard, alarms | [infra/observability.tf](infra/observability.tf), [eap/runtime/metrics.py](eap/runtime/metrics.py) |
| Quality monitoring | AgentCore online evaluations (goal success, helpfulness, correctness, tool selection) | [infra/evals.tf](infra/evals.tf) |
| Chat UI | Streamlit with `st.login` (OIDC), agent picker, streaming, tool status, thumbs feedback | [frontend/app.py](frontend/app.py) |
| No clickops | Everything is Terraform; `scripts/deploy.sh` builds images and applies | [infra/](infra/), [scripts/](scripts/) |

## Quick start

**Prerequisites:**
- An AWS account where Bedrock AgentCore is available. The default region is `us-west-2`.
- Bedrock model access for your chosen model.
- Terraform 1.10 or later.
- Docker with buildx. AgentCore needs `linux/arm64` images; buildx cross-builds them on x86.
- AWS CLI v2 and Python 3.10 or later.

```bash
make install                 # local venv for tests, local runs and the UI
make test                    # 21 tests, no AWS needed

# deploy (uses the AWS credentials in your shell)
make deploy                  # validates agents, builds arm64 images, terraform apply, writes UI config

make user EMAIL=you@example.com ADMIN=1   # Cognito emails a temporary password
make ui                                    # http://localhost:8501
```

The first deploy takes about 10–15 minutes. Things to know:
- **`policy_mode` defaults to `LOG_ONLY`.** Gateway policy decisions are logged but not enforced. Check them in the gateway logs, then set `policy_mode = "ENFORCE"` in `infra/terraform.tfvars` and redeploy.
- **Transaction Search is switched on account-wide.** If your account already manages it, set `enable_transaction_search = false`.
- **The default model is set in [eap/spec.py](eap/spec.py) (`DEFAULT_MODEL_ID`).** Each agent can override it. Use a model or inference profile that is enabled in your account and region.

Run `make destroy` to tear everything down.

## Add an agent

```python
# agents/expenses.py
from eap import AgentSpec, prompt_from_file

agent = AgentSpec(
    name="expenses",
    description="Answers questions about the expenses policy and checks receipts.",
    system_prompt=prompt_from_file("prompts/expenses.md", relative_to=__file__),
    tools=["knowledge___search_policies", "knowledge___get_policy"],
    builtin_tools=["code_interpreter"],
    memory=True,
    allowed_groups=["employees"],
)
```

Then run `make deploy`. You get a new runtime, IAM role, alarms, online evaluation and an entry in the UI. See [docs/adding-an-agent.md](docs/adding-an-agent.md) for all the options, including custom LangGraph workflows.

## Add a tool

- **Python MCP server:** see [docs/adding-an-mcp-server.md](docs/adding-an-mcp-server.md). Copy `mcp_servers/knowledge`, then add a runtime and a gateway target in Terraform.
- **Lambda:** add a function and a `aws_bedrockagentcore_gateway_target` with its tool schema, as the `tickets` target does.
- **Permissions:** in both cases, permit the new tool in [infra/policy.tf](infra/policy.tf). It is denied until you do.

## Repository layout

```
agents/            agent definitions (AgentSpec) + prompts/*.md
eap/               the SDK (spec, registry, manifest) and the shared runtime
runtime/           Dockerfile for the shared agent image
mcp_servers/       Python MCP servers (one dir each, own Dockerfile)
lambdas/           Lambda tools and the gateway interceptor
frontend/          Streamlit chat UI
infra/             Terraform for everything
scripts/           deploy / destroy / create_user / configure_frontend
tests/             unit and integration tests (no AWS)
docs/              architecture and how-to guides
```

## How it works

[docs/architecture.md](docs/architecture.md) covers the request flow, the identity and trust model, design decisions and known limitations.

## Status

This is a deliberately small reference platform. Everything runs, and the code paths are covered by tests that need no AWS account. The Terraform validates against `hashicorp/aws` 6.70. It is not yet hardened for production. [docs/architecture.md#production-checklist](docs/architecture.md#production-checklist) lists what to change before production: VPC mode, a remote Terraform state, a custom domain for the UI, and others.

## License

Apache-2.0
