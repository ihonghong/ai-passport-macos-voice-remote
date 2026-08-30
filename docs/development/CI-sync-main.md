<p align="right">
  <a href="CI-sync-main.zh_CN.md">简体中文</a> · <strong>English</strong>
</p>

# Manual Upstream Review

Automatic upstream synchronization is intentionally disabled because `main` is
the supported product branch. The FoloToy repository remains available as the
read-only `upstream` remote.

```bash
git fetch upstream
git log --oneline --left-right main...upstream/main
git diff --stat main...upstream/main
```

Review upstream changes before cherry-picking or merging them. Pay particular
attention to partition addresses, Recovery compatibility, BLE identity and
security, BSP pins, display orientation, audio clocks, and dependency versions.
Do not use a force-sync workflow against product `main`.
