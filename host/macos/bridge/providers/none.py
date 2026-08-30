"""Disabled dashboard provider."""

from __future__ import annotations

from typing import Any

from .base import MetricSnapshot


class NoneProvider:
    name = "none"
    refresh_seconds = 3600.0

    def read(self) -> MetricSnapshot:
        return MetricSnapshot(provider=self.name)


def create(_settings: dict[str, Any]) -> NoneProvider:
    return NoneProvider()
