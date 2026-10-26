"""Export agent definitions as JSON for Terraform.

    python -m eap.manifest > build/agents.json

Terraform reads this file to create one AgentCore runtime per agent. Only
infrastructure-relevant fields are exported; prompts and tool lists stay in the
image so a prompt change never needs a Terraform-visible secret or env var.
"""

from __future__ import annotations

import json
import sys

from eap.registry import load_agents


def build_manifest() -> dict[str, dict]:
    specs = load_agents()

    def closure(name: str) -> list[str]:
        names = [name]
        for child in specs[name].sub_agents:
            names += closure(child)
        return names

    manifest = {}
    for name, spec in sorted(specs.items()):
        entry = spec.manifest()
        # Sub-agents run inside the parent's runtime, so the parent's IAM role
        # needs their capabilities too.
        family = [specs[n] for n in closure(name)]
        entry["memory"] = any(s.memory for s in family)
        entry["code_interpreter"] = any("code_interpreter" in s.builtin_tools for s in family)
        manifest[name] = entry
    return manifest


def main() -> None:
    json.dump(build_manifest(), sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
