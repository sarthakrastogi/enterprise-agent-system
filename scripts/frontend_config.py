"""Render frontend/.streamlit/secrets.toml from `terraform output -json` on stdin."""

import json
import os
import secrets
import sys


def s(value: str) -> str:
    return json.dumps(value)  # a JSON string is a valid TOML basic string


def render(outputs: dict, ui_url: str) -> str:
    o = {k: v["value"] for k, v in outputs.items()}
    ui = ui_url.rstrip("/")
    lines = [
        "[auth]",
        f"redirect_uri = {s(ui + '/oauth2callback')}",
        f"cookie_secret = {s(secrets.token_urlsafe(32))}",
        f"client_id = {s(o['cognito_ui_client_id'])}",
        f"client_secret = {s(o['cognito_ui_client_secret'])}",
        f"server_metadata_url = {s(o['cognito_discovery_url'])}",
        'expose_tokens = ["access"]',
        'client_kwargs = { scope = "openid email profile" }',
        "",
        "[platform]",
        f"region = {s(o['region'])}",
        f"feedback_log_group = {s(o['feedback_log_group'])}",
    ]
    for agent in o["agents"]:
        lines += ["", "[[platform.agents]]"]
        lines += [f"{k} = {s(agent[k])}" for k in ("name", "display_name", "description", "arn")]
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    sys.stdout.write(render(json.load(sys.stdin), os.environ.get("UI_URL", "http://localhost:8501")))
