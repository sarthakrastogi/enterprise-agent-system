# Adding a Python MCP server

MCP servers are plain [FastMCP](https://github.com/modelcontextprotocol/python-sdk) apps. Each one runs on its own AgentCore Runtime with `server_protocol = "MCP"` and is reachable only through the gateway.

## 1. Write the server

Copy `mcp_servers/knowledge/` to `mcp_servers/hr/` and edit `server.py`:

```python
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("hr", host="0.0.0.0", port=8000, stateless_http=True)

@mcp.tool()
def leave_balance(employee_email: str) -> dict:
    """Return annual and sick leave balances in days for one employee."""
    ...

if __name__ == "__main__":
    mcp.run(transport="streamable-http")   # :8000/mcp, as AgentCore expects
```

**AgentCore requirements:**
- The container is `linux/arm64`.
- It listens on `0.0.0.0:8000`, path `/mcp`.
- It uses streamable HTTP.
- `stateless_http=True` is recommended.

**Tool design:**
- Write descriptions for the model: say what the tool returns and when to use it.
- Keep results small.
- Return errors as data, not exceptions.

**Identity:** if a tool must know the user, add a `requester` parameter and add the target name to the interceptor's `IDENTITY_TARGETS`. Never trust a user id the model supplies.

Run it locally with `python mcp_servers/hr/server.py`, then point any MCP client at `http://localhost:8000/mcp`.

## 2. Terraform

These changes go in `infra/`:

1. **ECR repository.** Add one like `aws_ecr_repository.mcp_knowledge`.
2. **Runtime.** Add an IAM role and an `aws_bedrockagentcore_agent_runtime` with `protocol_configuration { server_protocol = "MCP" }`.
3. **Resource policy.** Add an `aws_bedrockagentcore_resource_policy` that allows only the gateway role.
4. **Gateway target.** Add `aws_bedrockagentcore_gateway_target` with `mcp_server { endpoint = <runtime invocation URL> }` and `gateway_iam_role { service = "bedrock-agentcore" }`.
5. **Gateway role.** Add the new runtime ARN to its `InvokeMcpServers` statement.
6. **Policy.** Permit the new tools in `infra/policy.tf`, for example `hr___leave_balance`.
7. **Build.** Add a `build_push` line and a tag variable for the image in `scripts/deploy.sh`.

Then list the tools in an agent's `tools=[...]` and run `make deploy`.

## Lambda instead?

For a few stateless functions over an existing API, a Lambda target is cheaper and needs no container. See `lambdas/tickets` and `aws_bedrockagentcore_gateway_target.tickets`. The tool name arrives in `context.client_context.custom["bedrockAgentCoreToolName"]` as `<target>___<tool>`, and the arguments arrive as `event`.
