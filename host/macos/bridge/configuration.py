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
    "buttons": {
        "up": {"modifiers": ["left_command"], "key": "delete"},
        "mid": {"modifiers": [], "key": "return"},
        "down": {
            "modifiers": ["left_control", "left_command"],
            "key": None,
        },
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
    buttons = custom.get("buttons")
    if buttons is None and "shortcuts" in custom:
        legacy = custom["shortcuts"]
        if not isinstance(legacy, dict):
            raise ValueError("legacy shortcuts must be a JSON object")
        buttons = {
            "up": legacy.get("clear"),
            "mid": legacy.get("send"),
            "down": legacy.get("voice"),
        }
    if buttons is not None:
        if not isinstance(buttons, dict):
            raise ValueError("buttons must be a JSON object")
        if "mid" not in buttons and "ok" in buttons:
            buttons = {**buttons, "mid": buttons["ok"]}
        for button in ("up", "mid", "down"):
            if button not in buttons or buttons[button] is None:
                continue
            chord = buttons[button]
            if not isinstance(chord, dict):
                raise ValueError(f"buttons.{button} must be a JSON object")
            config["buttons"][button].update(chord)
    return config, selected
