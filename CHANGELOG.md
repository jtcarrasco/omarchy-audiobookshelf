# Changelog

## 0.2.0 (unreleased)

Rebuilt after the first hands-on test on Omarchy.

- Library and player now live in one dropdown hosted by the bar icon, built on
  the shell's own `qs.Ui` kit and `qs.Commons` theme (fonts, colors, controls
  follow the Omarchy theme). Replaces the separate library window and the
  cross-entry-point singleton, which never instantiated for plugins loaded
  outside Quickshell's shell directory, so clicking an item didn't play.
- Home view: a large player (cover, seek, ±30s, play/pause, speed, chapters,
  show notes), or the Audiobookshelf logo when nothing is loaded, with search
  and Books / Podcasts underneath. Search spans both types.
- Podcast episodes: open a show to list its episodes; unplayed dots, per-show
  "N unplayed" counts, progress bars, collapsible show notes.
- Cover thumbnails for books, podcasts and Now Playing.
- Right-click to mark a book or episode finished / not finished (with tooltip).
- Pop-out to half the screen; home button and clickable title.
- Setup inside the dropdown; libraries are auto-detected at login, so
  books-only and podcasts-only servers work.
- Bar icon is a theme glyph (headphones); lights up for new episodes, dims when
  the server is unreachable.
- Tested against a real Audiobookshelf server: session start, stream playback
  in mpv, podcast episodes and covers, in daily use on Omarchy.

## 0.1.0 — initial release

- Browse books and podcasts in a single, searchable, type-filterable library
  window
- mpv playback control via JSON-IPC (play/pause, ±30s, seek, speed, chapter
  seek) — no shell exec
- Selecting a book/podcast in the library window sets shared player state,
  starts a real ABS playback session (`POST /api/items/<id>/play`), loads the
  resulting stream URL into mpv, seeks to saved progress once mpv confirms
  the file loaded, populates the now-playing popup's chapters, and opens the
  popup. Cross-entry-point state sharing (library window is a separate
  `panel` entryPoint from the bar widget, per `manifest.json`) uses
  Quickshell's own `pragma Singleton` mechanism — see `PlayerState.qml`.
  **The streaming URL/auth approach (auth token as a `?token=` query
  parameter) is unverified against a real Audiobookshelf server** — see
  README's Known Limitations.
- Progress sync to the Audiobookshelf server during playback, with a local
  retry queue for network blips that now drains automatically on every poll
  cycle (`flush-pending`, wired into `PollTimer.qml`)
- Background polling for new podcast episodes with jittered scheduling and
  desktop notifications; bar badge shows new-episode count
- Setup wizard: server URL, credentials, library selection; checks for mpv
  before allowing connection; skipped on restart once `config.json` already
  exists
- Middle-click on the bar icon toggles play/pause without opening the popup
- Credentials stored in the system keyring via `secret-tool`, never in a
  config file

### Known limitations in this release

- **`Quickshell.pluginDir`, used for every backend call, may not be a real
  Quickshell API.** Quickshell's own docs don't list it; several real
  Omarchy plugins compute a plugin-local directory a different way instead
  (`manifest.__sourceDir`, `Qt.resolvedUrl(".")`, or an `$HOME`-based
  path). If it's undefined at runtime, the plugin does nothing at all with
  no on-screen error. Verify this first on live load — see README's Known
  Limitations for the full explanation and workarounds.
- **The streaming URL/auth approach is unverified against a real
  Audiobookshelf server** — no task in this build has had a live
  Audiobookshelf server or Quickshell desktop to test against; see README's
  Known Limitations.
- **No sleep timer**, despite being an original design goal.
- **Podcast "new episode" detection diffs shows, not episodes.**
  `check_new_episodes` compares `/api/libraries/<id>/items` results, whose
  elements are podcast library items (shows), not individual episodes. In
  practice this means the notification/badge fires when you subscribe to a
  brand-new podcast, not when an already-subscribed show releases a new
  episode — a real gap against the intended "notify on new episodes"
  feature.
- **No way to select a specific podcast episode to play.**
  `PlayerState.playItem()` always starts playback of the library item itself
  with no episode selected, even though the backend already supports
  episode-level playback (`start_playback(..., episode_id)`). Selecting a
  podcast in the library window doesn't let you choose which episode to
  play.
