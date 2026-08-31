<p align="right">
  <a href="CHANGELOG.zh_CN.md">简体中文</a> · <strong>English</strong>
</p>

# Changelog

## Unreleased

- Prevented a transient macOS BLE HID Output Report failure from latching the
  Bridge into an offline error state: writes now receive bounded retries, while
  a missed periodic status update keeps the connected audio/input path active.
- Added first-launch BlackHole detection, a one-time dependency explanation,
  and a persistent official installation link while the device is missing.
- Fixed native Codex daily-token totals staying at zero because session
  timestamps with fractional seconds were rejected.
- Prepared the `v0.1.0` Unsigned Beta release path: semantic tags inject the
  App version and publish verified firmware, a precompiled ad-hoc-signed
  universal native App, SHA-256 checksums, and paired English/Chinese notes as
  a GitHub prerelease. No Apple Developer account is required.
- Renamed the menu action to **Apply latest configuration (restart audio
  bridge)** and documented that saving `config.json` alone does not update the
  running App or device button map.
- Fixed native macOS discovery for the board's composite HID device: macOS
  reports the keyboard collection as the primary usage and the wireless-audio
  channel in its usage-pair list, so the App now checks both representations.
- Fixed native macOS HID Output Report framing by including Report ID 3 in the
  transmitted buffer, restoring runtime button maps, time, and usage metrics.
- Kept the connected dashboard state stable when Up or Mid is tapped; only
  Ready and Listening are shown during normal use.
- Moved the BLE HID audio Bridge, PCM conversion, Core Audio output, input
  switching, runtime shortcuts, and Codex metrics into one native Swift menu-bar
  App. Added universal Apple-silicon/Intel packaging, login-item control, and a
  release artifact; Python remains only as a migration and diagnostic reference,
  while BlackHole remains the required system audio driver.
- Replaced semantic voice/send/clear shortcut settings with direct bindings for
  the physical Up, Mid, and Down buttons. Existing configurations migrate in
  memory, while the unchanged wire/storage order preserves NVS data and avoids
  Bluetooth re-pairing.
- Renamed the public repository target to
  `ai-passport-macos-voice-remote` and unified release installation guidance:
  provisioned devices use permanent Recovery and the official mini-program,
  development uses segmented flashing, and raw `0x0` USB writes are explicitly
  treated as bond-resetting recovery operations.
- Added connection-aware macOS input protection: Passport mode keeps BlackHole
  only while the bridge is connected, temporarily restores the previous physical
  microphone while waiting, stopped, or failed, resumes after reconnection, and
  preserves an explicit meeting-mode choice.
- Rebalanced the shortcut dashboard typography so operational state is the
  primary visual signal, while time, battery, quota, and daily-token values
  share a quieter secondary scale. READY and LISTENING now share one 20px
  center anchor, so recording transitions change context without shifting the
  status text.
- Prepared the product repository for independent open-source release: changed
  public defaults to generic labels with metrics and pets disabled, pinned Mac
  dependencies, hardened installer deletion paths and BLE pairing logs, added a
  macOS host CI job, and replaced automatic upstream synchronization with manual
  review.
- Fixed automatic Codex Provider detection in the minimal PATH used by macOS
  LaunchAgents by resolving the supported `~/.local/bin/codex` fallback before
  deciding to disable metrics.
- Documented that each user must bind their chosen dictation or input method to
  Left Control + Left Command, and removed the remaining Doubao-specific runtime
  wording.
- Added a direct-launch Mac voice-shortcut remote with time, battery, Codex
  quota, daily-token progress, and an animated pet listening display;
  BLE HID push-to-talk/Return/Command-Delete mappings; wireless 8 kHz microphone
  transport over a vendor HID report; and a macOS BlackHole bridge with
  automatic wireless reconnection plus USB fallback.
- Moved the complete macOS bridge and status application into `host/macos`,
  added reproducible install, uninstall, and diagnostic scripts, and documented
  the clone-to-working flow for people and installation agents.
- Extracted optional model metrics into host Provider plugins with bundled
  `auto`, `codex`, and `none` choices, plus matching compile-time firmware label
  profiles.
- Added compile-time pet plugins and kept the owner's pet artwork as
  an ignored local fallback because it has no confirmed redistribution license.
- Reduced wireless idle power without changing shortcut semantics: enabled BLE
  modem sleep and automatic dynamic frequency scaling, requested conservative
  idle/streaming connection profiles with non-fatal fallback, backed disconnected
  advertising off from 30-50 ms to 500-1000 ms after 30 seconds, restored fast
  advertising on a physical press, and blocked the audio task instead of polling
  every 10 ms while idle. Automatic Light-sleep remains disabled pending device
  latency and display/audio validation.
- Replaced the prototype's fixed BLE passkey with a fresh random six-digit code
  for each new pairing attempt and added a temporary on-device pairing overlay
  that clears after encryption or disconnection.
- Added a wireless display deep-idle stage: after one minute without local
  activity, the backlight drops from 15% to 5%, UI animation pauses, and battery
  polling slows until a physical button or active use restores the display.
- Made mini-program BLE install compatibility a template-level invariant: fixed
  protected `cardid`/Recovery partitions, retained the five-second UP-key
  Recovery boot hook, and added CI validation for merged-image structure,
  partition MD5/ranges, the 3 MB app limit, and protected payload exclusion.
- Documented a release-title convention for multi-app releases: name tags as `v<version>-<app-name>` (e.g. `v0.1.0-voice-keychain`) so the release title carries the version and the app, and confirm the title after the release is published so a release list is scannable by app.
- Added a post-release follow-up workflow: an `issue-suggestions` skill for filing user feedback as issues against the upstream project, an `experience-pr` skill for submitting reusable development experience as a documentation PR, a `docs/experiences/` directory for per-entry experience files, and supporting `project-completion`, `file-issues`, and experience-index documents.
- Simplified the tracked repository root: moved GitHub-recognized community documents into `.github/`, moved the changelog into `docs/`, updated every reference, and added a root-document allowlist to repository checks.
- Repository-wide language policy: every maintained Markdown default `.md` file is English, Simplified Chinese uses a paired `.zh_CN.md`, and both provide language switches. Static checks reject missing peers, missing switches, and Chinese prose in English defaults.
- Phase one of the AI development workflow: streamlined task-based context routing, unified local/CI validation, added PR checks and a template, and committed the dependency lock for reproducible builds.
- PR review fixes: pinned GitHub Actions to full commit SHAs, split build/release jobs by least privilege, disabled persisted sync checkout credentials, added Feature Request and Usage Question forms, clarified private security-report fallback, and corrected stale README, CI-trigger, and branch descriptions.
- Changed commit titles, PR titles, and PR bodies from Chinese-default to English; updated the Chinese punctuation rule so it no longer applies to PR descriptions.
- Reworked `build-firmware.yml` to pass `SDKCONFIG_DEFAULTS=sdkconfig.defaults`, enable `partitions.csv`, preserve the 8 MB image header, merge a flashable `FoloToy-AI-Passport-full.bin`, publish only that artifact, and use Actions cache v5.
- Integrated upstream PR #6 to resolve PR #4 conflicts: Wi-Fi, Bluetooth LE, radio lifecycle, and low-power demos; a 3 MB factory partition; build/menu/configuration updates; hardware-guide coverage; and bilingual capability tables.
- Defined English imperative Conventional Commit formatting for both commits and PR titles.
- Removed stale sync-workflow template comments and generalized an irrelevant Redis TTL rule to cache components.
- Added Chinese punctuation, credential safety, and recoverable file-deletion conventions.
- Expanded source-comment requirements for functions, state, ownership, concurrency, timing, registers, and magic values.
- Removed AI execution instructions from product READMEs so they remain human-facing product and repository overviews.
- Added `docs/development/agent-guide.md` as the focused AI workflow guide.
- Updated `AGENTS.md`, `docs/INDEX.md`, and the development index for the agent guide.
- Documented why the root README path is reserved for fork owners and how GitHub README precedence supports it.
- Created `main-update` from the upstream-aligned baseline and combined the repository-structure, firmware-CI, and upstream-sync work.
- Corrected the merged documentation index, workflow path, project tree, and CI references.
- Moved CI documentation from software design to `docs/development/`.
- Moved fork-only documentation assets from `assets/docs/` to `docs/assets/`.
- Moved the upstream English/Chinese project READMEs under `docs/` and renamed the documentation catalog to `docs/INDEX.md`.
- Initialized `AGENTS.md`, `CLAUDE.md`, and `CHANGELOG.md`.
- Standardized the initial project README language filenames.
- Added the `docs/`, `assets/`, and `skills/` directory structure.
- Moved the upstream hardware guide into `docs/hardware-design/`.
- Standardized subdirectory README capitalization and introduced fork conventions.
- Allowed fork-owned root README and supplemental documentation content on fork `main`.
- Added and documented the fork-only supplemental-document directory.
- Moved the build CI document to its dedicated CI branch before consolidation.
- Documented clean-`main` reasons, the direct-development exception, and Actions enablement for forks.
- Split the original agent rules into contribution, development, and fork documents with a compact root index.
- Updated software-design and project README references for the new documentation structure.
- Added the documentation catalog and task-triggered routing based on the earlier repository model.
- Added bilingual contribution, code-of-conduct, security, and support documents tailored to this ESP-IDF and fork workflow.
