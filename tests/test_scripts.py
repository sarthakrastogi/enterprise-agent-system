import importlib.util
from pathlib import Path

import toml  # the parser Streamlit uses for secrets.toml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("frontend_config", ROOT / "scripts/frontend_config.py")
frontend_config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(frontend_config)


def test_frontend_config_is_valid_toml_with_agents():
    outputs = {k: {"value": v} for k, v in {
        "cognito_ui_client_id": "cid",
        "cognito_ui_client_secret": 'se"cr\\et',
        "cognito_discovery_url": "https://cognito-idp.us-west-2.amazonaws.com/pool/.well-known/openid-configuration",
        "region": "us-west-2",
        "feedback_log_group": "/eap/feedback",
        "agents": [{"name": "it_helpdesk", "display_name": "IT Helpdesk",
                    "description": 'Says "hi"', "arn": "arn:aws:bedrock-agentcore:us-west-2:1:runtime/x"}],
    }.items()}
    parsed = toml.loads(frontend_config.render(outputs, "http://localhost:8501/"))
    assert parsed["auth"]["redirect_uri"] == "http://localhost:8501/oauth2callback"
    assert parsed["auth"]["client_secret"] == 'se"cr\\et'
    assert parsed["auth"]["expose_tokens"] == ["access"]
    assert parsed["platform"]["agents"][0]["description"] == 'Says "hi"'
