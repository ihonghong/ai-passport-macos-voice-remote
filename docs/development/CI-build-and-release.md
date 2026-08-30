<p align="right">
  <a href="CI-build-and-release.zh_CN.md">简体中文</a> · <strong>English</strong>
</p>

# Automated Build and Release

`.github/workflows/build-firmware.yml` builds and publishes firmware for tags and supports manual dispatch. Ordinary branch pushes do not trigger it. Keep this page synchronized with the workflow.

The build job restores ccache, runs `./tools/validate.sh --firmware` with ESP-IDF 5.5.3 for ESP32-C3, verifies the bootloader at `0x0`, partition table at `0x8000`, application at `0x10000`, 8 MB Flash arguments, and the complete mini-program BLE compatibility contract, then uploads `FoloToy-AI-Passport-full.bin`. A separate least-privilege release job publishes that artifact only for a tag.

All Actions are pinned to full commit SHAs. The build job has `contents: read`; only the tag release job receives `contents: write`.

## Install the release safely

The merged `FoloToy-AI-Passport-full.bin` serves two different installation
mechanisms; do not treat them as interchangeable:

- **Normal installation on a provisioned AI Passport:** enter the permanent
  Recovery by holding UP while powering on for five seconds, then install the
  merged artifact with the official mini-program. Recovery parses the image and
  protects the per-device `cardid` and permanent Recovery partitions.
- **Local development:** use segmented `idf.py flash`. It writes the bootloader,
  partition table, and application at their explicit offsets without filling the
  runtime NVS gap.
- **Deliberate raw USB recovery:** a browser flasher or `esptool` write of the
  merged file at `0x0` erases every sector covered by the file, including the
  NVS gap filled with `0xFF`. It resets the Bluetooth bond and must not be the
  default update path. Use it only when the verified file ends before `cardid`
  and the user accepts re-pairing; never raw-write a merged artifact that spans
  a resource partition after `cardid`.

The browser performs local writing and verification and does not upload the
firmware file, but that does not give a raw write the protected semantics of
Recovery. For the exact partition contract, see [BLE and Recovery
compatibility](ble-recovery-compatibility.md).

## Release title

This repository ships one supported product. Use semantic tags such as `v0.1.0`
and let the workflow publish the release as
`v0.1.0 — AI Passport Mac Voice Remote`. Do not repeat the application name in
the tag; the repository and release title already carry it.

## Release notes

A tag-triggered release succeeds only when the merged firmware and its release
notes travel together. After the release is published, write release notes that
explain the build to a user who may not have read the repository. Cover three
things:

- **What's new**: the features, behaviors, or fixes this release adds or
  changes compared with the previous one. Keep it user-facing, not a commit log.
- **How to build**: how to produce and verify the merged firmware
  (`./tools/validate.sh --firmware`, not an unverified incremental build), and
  the resulting Recovery-compatible artifact `FoloToy-AI-Passport-full.bin`.
- **How to use**: recommend permanent Recovery and the official mini-program for
  normal installation, document segmented `idf.py flash` for development, and
  clearly label raw `0x0` USB writing as a bond-resetting recovery operation.

Write the release notes in English (and a Simplified Chinese version where the
project is bilingual) and link them from the GitHub/GitLab release. Keep them
consistent with `docs/CHANGELOG.md` for user-visible behavior.

## Related documents

- Firmware publishing to the community: [publish-to-community.md](publish-to-community.md)
- Post-release follow-up: [project-completion.md](project-completion.md)
