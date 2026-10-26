"""Discover agent definitions in the ``agents`` package."""

from __future__ import annotations

import importlib
import pkgutil
from functools import lru_cache
from types import ModuleType

from eap.spec import AgentSpec


@lru_cache(maxsize=1)
def load_agents(package: str = "agents") -> dict[str, AgentSpec]:
    """Import every module in ``package`` and collect its ``agent`` attribute.

    Modules whose name starts with ``_`` are skipped, so helpers can live
    alongside agent files.
    """
    pkg: ModuleType = importlib.import_module(package)
    specs: dict[str, AgentSpec] = {}
    for info in pkgutil.iter_modules(pkg.__path__):
        if info.name.startswith("_"):
            continue
        module = importlib.import_module(f"{package}.{info.name}")
        spec = getattr(module, "agent", None)
        if not isinstance(spec, AgentSpec):
            raise TypeError(f"{package}/{info.name}.py must define `agent = AgentSpec(...)`")
        if spec.name in specs:
            raise ValueError(f"duplicate agent name {spec.name!r} in {package}/{info.name}.py")
        specs[spec.name] = spec

    for spec in specs.values():
        missing = [s for s in spec.sub_agents if s not in specs]
        if missing:
            raise ValueError(f"agent {spec.name!r} lists unknown sub_agents {missing}")
    _check_no_cycles(specs)
    return specs


def _check_no_cycles(specs: dict[str, AgentSpec]) -> None:
    visiting: set[str] = set()
    done: set[str] = set()

    def visit(name: str, path: list[str]) -> None:
        if name in done:
            return
        if name in visiting:
            raise ValueError("sub_agents cycle: " + " -> ".join(path + [name]))
        visiting.add(name)
        for child in specs[name].sub_agents:
            visit(child, path + [name])
        visiting.discard(name)
        done.add(name)

    for name in specs:
        visit(name, [])
