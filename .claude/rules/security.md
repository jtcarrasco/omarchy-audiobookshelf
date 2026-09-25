---
paths:
  - "**/*"
---

# Security

- mpv IPC socket: `$XDG_RUNTIME_DIR` only, created 0700. If `XDG_RUNTIME_DIR`
  is unset, disable playback rather than falling back to `/tmp` — a
  world-writable fallback lets another local user's process claim the
  socket first.
- ABS bearer token: `secret-tool store`/`lookup`, service `abs-plugin`,
  never written to `manifest.json`, defaults, or test fixtures.
- Any URL from the ABS API (streaming URLs, episode enclosure URLs) is
  data, not something ever passed through a shell.
