"""Configuration loading shared by local runs and installed LaunchAgents."""

from __future__ import annotations

from copy import deepcopy
import json
import os
from pathlib import Path
from typing import Any


DEFAULT_CONFIG: dict[str, Any] = {
    "device_name": "AI Passport",
    "audio_device": "BlackHole 2ch",
    "provider": {"name": "none", "settings": {}},
    "shortcuts": {
        "voice": {
            "modifiers": ["left_control", "left_command"],
            "key": None,
        },
        "send": {"modifiers": [], "key": "return"},
        "clear": {"modifiers": ["left_command"], "key": "delete"},
    },
}

DEFAULT_CONFIG_PATH = Path(
    os.path.expanduser("~/Library/Application Support/AI Passport Bridge/config.json")
)


def load_config(path: str | None) -> tuple[dict[str, Any], Path | None]:
    selected = Path(os.path.expanduser(path)) if path else DEFAULT_CONFIG_PATH
    config = deepcopy(DEFAULT_CONFIG)
    if not selected.is_file():
        return config, None
    with selected.open("r", encoding="utf-8") as config_file:
        custom = json.load(config_file)
    if not isinstance(custom, dict):
        raise ValueError("Bridge configuration must be a JSON object")
    for key in ("device_name", "audio_device"):
        if key in custom:
            config[key] = custom[key]
    provider = custom.get("provider")
    if provider is not None:
        if not isinstance(provider, dict):
            raise ValueError("provider must be a JSON object")
        config["provider"].update(provider)
    shortcuts = custom.get("shortcuts")
    if shortcuts is not None:
        if not isinstance(shortcuts, dict):
            raise ValueError("shortcuts must be a JSON object")
        for action in ("voice", "send", "clear"):
            if action not in shortcuts:
                continue
            chord = shortcuts[action]
            if not isinstance(chord, dict):
                raise ValueError(f"shortcuts.{action} must be a JSON object")
            config["shortcuts"][action].update(chord)
    return config, selected
