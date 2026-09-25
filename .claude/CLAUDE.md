# Audiobookshelf Plugin — Project Rules

This is a Quickshell/QML Omarchy plugin. See `README.md` for what it does.

## Non-negotiables

- mpv is controlled ONLY via JSON-IPC over a Unix socket in `$XDG_RUNTIME_DIR`.
  Never shell exec, never a fixed `/tmp` socket path. See `security.md`.
- No credentials in `manifest.json`, config files, or committed test fixtures.
  Real ABS tokens live in gnome-keyring via `secret-tool`.
- Books and podcasts share one API code path (filter on `mediaType`), not
  parallel implementations.

## Structure

- `*.qml` — UI (bar widget, popup, library window)
- `Model.js` — pure functions: command builders, JSON shaping, no side effects
- `scripts/abs_backend.py` — the Python backend process (API calls, state,
  feed-poll cache) — mirrors `omarchy-podcasts`' `scripts/podcasts.py` role
- `tests/` — pytest, PySide6 QQmlEngine harness for QML logic (mirrors
  `blueferry`'s pattern), plain pytest for the Python backend
