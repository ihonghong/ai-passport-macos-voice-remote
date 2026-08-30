"""Small stable contract implemented by host metric-provider plugins."""

from __future__ import annotations

from dataclasses import dataclass
import threading
from typing import Protocol


@dataclass(frozen=True)
class MetricSnapshot:
    """Two compact dashboard values supported by the current BLE protocol."""

    provider: str
    remaining_percent: int | None = None
    daily_total: int | None = None


class MetricProvider(Protocol):
    name: str
    refresh_seconds: float

    def read(self) -> MetricSnapshot:
        """Return the latest quota and daily-usage values."""


class MetricMonitor:
    """Poll one provider without blocking BLE audio handling."""

    def __init__(self, provider: MetricProvider) -> None:
        self.provider = provider
        self.snapshot = MetricSnapshot(provider=provider.name)
        self._stop = threading.Event()
        self._thread = threading.Thread(
            target=self._run,
            name=f"metrics-{provider.name}",
            daemon=True,
        )

    def start(self) -> None:
        self._thread.start()

    def close(self) -> None:
        self._stop.set()
        self._thread.join(timeout=1.0)

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                snapshot = self.provider.read()
                if snapshot != self.snapshot:
                    remaining = snapshot.remaining_percent
                    daily = snapshot.daily_total
                    print(
                        f"Provider {snapshot.provider}: remaining="
                        f"{remaining if remaining is not None else 'unknown'}%, "
                        f"daily={daily if daily is not None else 'unknown'}",
                        flush=True,
                    )
                self.snapshot = snapshot
            except Exception as exc:
                print(f"WARN provider {self.provider.name} unavailable: {exc}", flush=True)
            self._stop.wait(max(5.0, float(self.provider.refresh_seconds)))
