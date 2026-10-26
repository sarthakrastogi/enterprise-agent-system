import json

import pytest

from eap import AgentSpec
from eap.manifest import build_manifest
from eap.registry import load_agents


def make(**kw):
    base = dict(name="demo_agent", description="Does demo things.", system_prompt="Be helpful.")
    base.update(kw)
    return AgentSpec(**base)


def test_defaults_and_display_name():
    spec = make()
    assert spec.display_name == "Demo Agent"
    assert spec.tools == ()
    assert spec.manifest()["memory"] is False


@pytest.mark.parametrize("name", ["Demo", "1agent", "has-hyphen", "a", "x" * 33])
def test_rejects_bad_names(name):
    with pytest.raises(ValueError):
        make(name=name)


def test_rejects_unknown_builtin_tool():
    with pytest.raises(ValueError, match="builtin_tools"):
        make(builtin_tools=["browser"])


def test_rejects_self_delegation():
    with pytest.raises(ValueError, match="itself"):
        make(sub_agents=["demo_agent"])


def test_lists_become_tuples():
    spec = make(tools=["a___b"], allowed_groups=["g"])
    assert spec.tools == ("a___b",) and spec.allowed_groups == ("g",)


def test_repo_agents_load_and_manifest_is_json():
    specs = load_agents()
    assert {"it_helpdesk", "data_analyst"} <= set(specs)
    manifest = build_manifest()
    assert manifest["data_analyst"]["code_interpreter"] is True
    assert manifest["it_helpdesk"]["memory"] is True
    # it_helpdesk delegates to data_analyst in-process, so it needs its sandbox permission
    assert manifest["it_helpdesk"]["code_interpreter"] is True
    assert manifest["data_analyst"]["memory"] is False
    json.dumps(manifest)  # Terraform reads this
