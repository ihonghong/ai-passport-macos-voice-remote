<p align="right">
  <a href="fork-guide.zh_CN.md">简体中文</a> · <strong>English</strong>
</p>

# Upstream Maintenance

This repository started from `FoloToy/ai-passport` and keeps its Git history and
MIT attribution. Its `main` branch now represents the supported Mac voice-remote
product; it is not automatically synchronized with FoloToy upstream.

Use these remote roles:

```text
origin    git@github.com:ihonghong/ai-passport-macos-voice-remote.git # product repository
upstream  https://github.com/FoloToy/ai-passport.git                  # read-only baseline
```

Develop changes on short-lived `feature/*` branches and merge them into this
repository's `main` after review. To adopt an upstream change, fetch `upstream`,
inspect the commits and hardware contracts, then cherry-pick or merge only the
reviewed change. Never force-sync upstream `main` over the product branch.

Keep upstream attribution and the repository license intact. Reusable fixes may
still be proposed to FoloToy separately, but product-specific firmware, the Mac
Bridge, Provider configuration, and private or unlicensed assets stay here.
