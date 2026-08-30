"""Metric-provider plugin loading for the AI Passport macOS bridge."""

from __future__ import annotations

import importlib
from typing import Any

from .base import MetricMonitor, MetricProvider, MetricSnapshot
from .codex import find_codex


def load_provider(name: str, settings: dict[str, Any]) -> MetricProvider:
    """Load a bundled provider name or a fully qualified Python module."""
    selected = name.strip() or "none"
    if selected == "auto":
        selected = "codex" if find_codex() else "none"
    module_name = selected if "." in selected else f"providers.{selected}"
    module = importlib.import_module(module_name)
    create = getattr(module, "create", None)
    if not callable(create):
        raise RuntimeError(f"Provider {module_name!r} does not export create(settings)")
    provider = create(settings)
    if not hasattr(provider, "read"):
        raise RuntimeError(f"Provider {module_name!r} does not implement read()")
    return provider


__all__ = [
    "MetricMonitor",
    "MetricProvider",
    "MetricSnapshot",
    "load_provider",
]
