<p align="right">
  <a href="README.zh_CN.md">简体中文</a> · <strong>English</strong>
</p>

# Images

Store reusable source images and generated display assets here.

- Use descriptive names and document dimensions, pixel format, conversion steps, and destination.
- Prefer formats suitable for the 240 × 320 RGB565 display and account for Flash and internal RAM.
- Preserve editable sources where licensing permits, and record the source and license.
- Never commit device QR secrets, credentials, or personal data in images.

## README renders

- `voice-remote-ready.png`: 720 × 960 documentation render of the connected,
  ready state.
- `voice-remote-listening.png`: 720 × 960 documentation render of active
  microphone streaming, including the waveform and elapsed time.

Both renders are deterministic 3× representations of the firmware's 240 × 320
layout. Their generic pet mascot was generated specifically for this project;
they contain no owner-local pet artwork or names.

## Local optional assets

- `local-pet-idle-clean.gif`: six-frame, 192 × 208 idle animation adapted
  from the user's Codex pet artwork for the AI Passport dashboard. Firmware uses
  locally generated 68 × 74 RGB565 frames; no GIF decoder is enabled. The GIF
  and generated C files are intentionally ignored because a redistribution
  license was not supplied. The `auto` pet selection keeps them usable for the
  owner without including them in a public clone. See
  [`main/plugins/pets/README.md`](../../main/plugins/pets/README.md).
