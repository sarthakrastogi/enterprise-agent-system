# Architecture

## Request flow

1. **Sign-in.** The user signs in to the Streamlit UI with Cognito (OIDC authorization-code flow, through `st.login`). The UI keeps the user's **access token**.
2. **UI → agent.** The UI calls `POST /runtimes/<agent ARN>/invocations` on AgentCore Runtime with `Authorization: Bearer <access token>` and a session id of at least 33 characters.
3. **Runtime authorization.** The runtime's **CUSTOM_JWT authorizer** checks the token's signature, issuer, `client_id` and, when the agent declares `allowed_groups`, the `cognito:groups` claim. A request that fails these checks never reaches agent code.
4. **Agent setup.** AgentCore starts (or reuses) the session's **microVM** and runs the shared image with `AGENT_NAME=<agent>`. `eap.runtime.app`:
   - reads the caller from the already-validated token (`sub`, username, groups);
   - loads that user's long-term memories, if the agent has `memory=True`;
   - loads the user's tools from the **Gateway**, sending the same token;
   - builds a LangGraph agent: Bedrock model plus Guardrail, tools, and the AgentCore Memory checkpointer;
   - streams tokens back to the UI as SSE: `text`, `tool_call`, `tool_result`, `done` and `error` events.
5. **Tool calls go through the Gateway.** For each one:
   - The JWT authorizer validates the token again.
   - The **request interceptor** Lambda replaces the `requester` argument of identity-sensitive tools with the token's `sub`.
   - **Cedar policy** decides whether this user may call this tool. In `ENFORCE` mode, `tools/list` only shows permitted tools.
   - The gateway calls the target with its own IAM role (SigV4): the knowledge MCP server on Runtime, or the tickets Lambda.
6. **After the turn.** The runtime writes the user and assistant messages to Memory as conversational events. Memory strategies extract facts and preferences asynchronously. The runtime then publishes `EAP/Agents` metrics.
7. **Monitoring.** Spans and logs land in CloudWatch. Online evaluation samples sessions and scores them with LLM judges. Feedback from the UI goes to `/<project>/feedback`, keyed by session id.

## Trust model

| Boundary | Control | Why |
|---|---|---|
| Internet → agent | JWT authorizer on every runtime (issuer, client, group) | Agent code never runs for unauthenticated or unauthorized callers |
| Agent code → user identity | Identity is taken from the validated token, never from the payload | The payload is client-controlled |
| Agent → tools | All tools are behind the Gateway, called with the **user's** token | Policy and audit see the real user, not "the agent" |
| Model → tool arguments | Interceptor overwrites `requester` | A prompt-injected model can't act as another user |
| User → tool | Cedar policy, default deny | New tools are unavailable until explicitly permitted |
| Gateway → MCP server | SigV4 with the gateway role; resource policy denies all other principals | MCP servers can't be called around the gateway |
| Model I/O | Bedrock Guardrail | Blocks prompt attacks, harmful content, card numbers and secrets in model input/output |
| Code execution | AgentCore Code Interpreter sandbox | Model-written code never runs in the agent's microVM |
| Sessions | One microVM per session, sanitised afterwards | No cross-user state leakage in the runtime |

**Known gap:** model-level Guardrails do not inspect tool results. If you add tools that return untrusted content (web pages, emails, uploaded documents), add checks at the gateway (Guardrails-in-Policy or a RESPONSE interceptor), and keep write tools behind confirmation or policy.

## Design decisions

**Python `AgentSpec` instead of YAML.**
- A spec is typed, validated at import time and unit-testable.
- It can carry Python where you need it: local tools, or a custom graph.
- `python -m eap.manifest` exports only what Terraform needs (name, memory, code interpreter, groups), so infrastructure stays declarative.

**One image, one runtime per agent.**
- Every agent shares the same tested image.
- Each runtime still gets its own IAM role, JWT group rule, logs, alarms, evaluations and immutable versions.
- Changing a prompt rebuilds the image (tags are content hashes) and creates a new runtime version.

**LangGraph's `create_agent` by default.**
- It is the same autonomous tool-calling loop as Strands or the OpenAI Agents SDK, with a large ecosystem and first-party AgentCore Memory support (`langgraph-checkpoint-aws`).
- Set `graph_factory` to use a fixed workflow for a specific agent.

**Sub-agents run in-process.**
- A sub-agent runs as a tool inside the parent's runtime, with the parent's user identity and gateway access.
- This is simple and has no extra network hop.
- The trade-off is that the parent's IAM role needs the sub-agents' permissions; the manifest computes this.
- For independent scaling or separate ownership, host the sub-agent separately and call it over A2A instead.

**Cognito as the IdP.**
- It keeps the project self-contained.
- To use Entra ID or Okta, either federate them into the user pool, or point the authorizers' `discovery_url` at your IdP and adjust the group claim name.

**Gateway policy starts in `LOG_ONLY`.**
- A wrong policy in `ENFORCE` hides every tool.
- Check the decisions first, then flip the mode.

## Observability map

| Signal | Where |
|---|---|
| Agent traces (LLM calls, tool calls, tokens) | CloudWatch → GenAI Observability → Bedrock AgentCore; spans in `/aws/bedrock-agentcore/runtimes/<id>-DEFAULT` |
| Agent stdout/stderr | Same log group, `runtime-logs` stream |
| Gateway and memory logs | `/aws/vendedlogs/bedrock-agentcore/<project>/{gateway,memory}`; gateway/memory traces go to X-Ray |
| Per-session compute usage | `/aws/vendedlogs/bedrock-agentcore/<project>/agent-<name>` (USAGE_LOGS) |
| Platform metrics | `EAP/Agents`: Turns, FailedTurns, ToolCalls, TurnLatency per agent |
| AgentCore metrics | `AWS/Bedrock-AgentCore`: invocations, errors, throttles, vCPU-hours |
| Alarms | `<project>-<agent>-failed-turns`, `<project>-<agent>-slow-turns` → SNS (`alarm_email`) |
| Evaluations | `/aws/bedrock-agentcore/evaluations/...` and the AgentCore Evaluations console |
| User feedback | `/<project>/feedback` (JSON with agent, session_id, rating) |

## Production checklist

- **Remote Terraform state.** Use S3 with `use_lockfile` (see [infra/versions.tf](../infra/versions.tf)).
- **Network.** Use VPC mode for runtimes (`network_mode = "VPC"`), with PrivateLink endpoints for Bedrock and AgentCore.
- **Hosting the UI.** Run it on ECS Fargate behind an ALB with HTTPS and a real domain. Add that domain to `ui_callback_urls` and `ui_logout_urls`. Give the task role `logs:PutLogEvents` on the feedback log group.
- **Identity provider.** Federate your corporate IdP and turn off Cognito's local users.
- **Policy.** Switch `policy_mode` to `ENFORCE`.
- **Retention and protection.**
  - Set `deletion_protection = "ACTIVE"` on the user pool.
  - Remove `force_delete` from the ECR repositories.
  - Raise log retention to match your policy.
- **Encryption.** Use customer-managed KMS keys for memory (`encryption_key_arn`), the gateway (`kms_key_arn`) and log groups.
- **Quotas.** Request increases for active sessions and gateway TPS before launch.
- **Delivery.** Add an eval gate (dataset plus thresholds) before production deploys, and pin model versions.
- **Data residency.** Review `DEFAULT_MODEL_ID`: `global.` inference profiles may process data in other regions.

## Limitations

- **Cognito tokens expire after 60 minutes and the UI does not refresh them.** Users sign in again when this happens.
- **Feedback writes use the UI host's AWS credentials.**
- **Memory recall is a simple pre-turn search.** The agent cannot yet explicitly "remember" or "forget" something.
- **Code Interpreter uses one sandbox session per microVM.** Variables persist within a chat but are not shared across chats.
