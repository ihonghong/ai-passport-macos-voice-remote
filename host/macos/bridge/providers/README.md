<p align="right">
  <a href="README.zh_CN.md">简体中文</a> · <strong>English</strong>
</p>

# Metric Provider Plugins

A provider supplies the two optional dashboard metrics supported by the current
wire protocol: remaining quota as `0..100`, and today's token total as a
non-negative integer. Providers run only on the Mac and do not handle audio or
keyboard events.

Bundled providers:

- `codex`: reads Codex rate limits through the local Codex CLI and totals today's
  token-count events from local `~/.codex` session records. It runs only after
  explicit selection, does not upload the records, and refreshes every five minutes.
- `none`: disables metrics while keeping all remote and audio features working.
- `auto`: chooses `codex` when the Codex CLI is available, otherwise `none`.

The public default is `none`. Select `codex` or `auto` explicitly if you want the
optional usage dashboard.

To add a bundled provider, create `<name>.py` in this directory and export:

```python
from providers.base import MetricSnapshot

class ExampleProvider:
    name = "example"
    refresh_seconds = 300

    def read(self):
        return MetricSnapshot(
            provider=self.name,
            remaining_percent=75,
            daily_total=120_000_000,
        )

def create(settings):
    return ExampleProvider()
```

Then set `provider.name` to `example`. An external module can be used without
copying it here by setting a fully qualified module name and ensuring it is on
the installed Python environment's import path. Keep credentials outside the
repository and pass non-secret options through `provider.settings`.

The matching firmware text is selected at build time with:

```bash
idf.py -D AI_PASSPORT_PROVIDER_PROFILE=codex build
```

Use `generic` for a provider-neutral display, or add a small
`main/plugins/providers/<name>/provider_profile.h` defining the four label
macros. The numeric protocol intentionally remains stable.
