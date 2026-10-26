"""Platform-level agent metrics in CloudWatch namespace EAP/Agents.

AgentCore already publishes vended runtime metrics (AWS/Bedrock-AgentCore). These
add what only the agent knows: failed runs, tool calls and turn latency per
agent, with a dimension we control so alarms are reliable.
"""

from __future__ import annotations

import logging
from functools import lru_cache

log = logging.getLogger(__name__)

NAMESPACE = "EAP/Agents"


@lru_cache(maxsize=1)
def _client(region: str):
    import boto3

    return boto3.client("cloudwatch", region_name=region)


def publish(region: str, agent: str, *, ok: bool, tool_calls: int, latency_ms: float, local_dev: bool = False) -> None:
    if local_dev:
        return
    dims = [{"Name": "Agent", "Value": agent}]
    try:
        _client(region).put_metric_data(
            Namespace=NAMESPACE,
            MetricData=[
                {"MetricName": "Turns", "Dimensions": dims, "Value": 1, "Unit": "Count"},
                {"MetricName": "FailedTurns", "Dimensions": dims, "Value": 0 if ok else 1, "Unit": "Count"},
                {"MetricName": "ToolCalls", "Dimensions": dims, "Value": tool_calls, "Unit": "Count"},
                {"MetricName": "TurnLatency", "Dimensions": dims, "Value": latency_ms, "Unit": "Milliseconds"},
            ],
        )
    except Exception:  # metrics must never fail a user's turn
        log.exception("failed to publish metrics")
