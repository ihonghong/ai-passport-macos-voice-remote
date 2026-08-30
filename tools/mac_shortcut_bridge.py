#!/usr/bin/env python3
"""Compatibility entry point for the repository macOS bridge."""

from pathlib import Path
import runpy
import sys


BRIDGE_ENTRY = (
    Path(__file__).resolve().parents[1]
    / "host"
    / "macos"
    / "bridge"
    / "mac_shortcut_bridge.py"
)


if __name__ == "__main__":
    sys.path.insert(0, str(BRIDGE_ENTRY.parent))
    runpy.run_path(str(BRIDGE_ENTRY), run_name="__main__")
