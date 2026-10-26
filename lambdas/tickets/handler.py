"""Support-ticket tools, exposed through AgentCore Gateway as Lambda target "tickets".

Gateway calls this function with the tool arguments as `event` and the tool
name in the client context as "<target>___<tool>". The `requester` argument is
always overwritten by the gateway interceptor (lambdas/interceptor) with the
signed-in user, so a model cannot act as someone else.
"""

from __future__ import annotations

import os
import uuid
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.conditions import Key

TABLE = boto3.resource("dynamodb").Table(os.environ["TICKETS_TABLE"])
PRIORITIES = {"low", "normal", "high"}


def _tool_name(context) -> str:
    custom = getattr(getattr(context, "client_context", None), "custom", None) or {}
    full = custom.get("bedrockAgentCoreToolName", "")
    return full.split("___", 1)[-1]


def _requester(event: dict) -> str:
    requester = event.get("requester")
    if not requester:
        raise PermissionError("missing requester; the gateway interceptor must set it")
    return requester


def create_ticket(event: dict) -> dict:
    summary = (event.get("summary") or "").strip()
    if not summary:
        return {"error": "summary is required"}
    priority = event.get("priority", "normal")
    if priority not in PRIORITIES:
        return {"error": f"priority must be one of {sorted(PRIORITIES)}"}
    item = {
        "ticket_id": "TCK-" + uuid.uuid4().hex[:8].upper(),
        "requester": _requester(event),
        "summary": summary[:200],
        "details": (event.get("details") or "")[:4000],
        "priority": priority,
        "status": "open",
        "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    TABLE.put_item(Item=item)
    return item


def get_ticket(event: dict) -> dict:
    item = TABLE.get_item(Key={"ticket_id": event.get("ticket_id", "")}).get("Item")
    if not item or item["requester"] != _requester(event):
        return {"error": f"ticket {event.get('ticket_id')!r} not found for this user"}
    return item


def list_my_tickets(event: dict) -> dict:
    resp = TABLE.query(
        IndexName="by_requester",
        KeyConditionExpression=Key("requester").eq(_requester(event)),
        ScanIndexForward=False,
        Limit=20,
    )
    return {"tickets": [
        {k: t[k] for k in ("ticket_id", "summary", "priority", "status", "created_at")}
        for t in resp.get("Items", [])
    ]}


def close_ticket(event: dict) -> dict:
    # Who may call this is decided by Cedar policy at the gateway, not here.
    ticket_id = event.get("ticket_id", "")
    try:
        TABLE.update_item(
            Key={"ticket_id": ticket_id},
            UpdateExpression="SET #s = :closed, resolution = :r",
            ConditionExpression="attribute_exists(ticket_id)",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":closed": "closed", ":r": (event.get("resolution") or "")[:2000]},
        )
    except TABLE.meta.client.exceptions.ConditionalCheckFailedException:
        return {"error": f"ticket {ticket_id!r} not found"}
    return {"ticket_id": ticket_id, "status": "closed"}


TOOLS = {f.__name__: f for f in (create_ticket, get_ticket, list_my_tickets, close_ticket)}


def handler(event, context):
    name = _tool_name(context)
    if name not in TOOLS:
        return {"error": f"unknown tool {name!r}"}
    try:
        return TOOLS[name](event or {})
    except PermissionError as e:
        return {"error": str(e)}
