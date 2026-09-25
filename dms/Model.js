.pragma library

// -------------------------------------------------------------------- mpv
//
// Audio only, idle so the process outlives the end of a track, and no
// ytdl: a streaming URL from Audiobookshelf is still server-controlled
// data being handed to a media player, and without --no-ytdl mpv can
// hand a URL to yt-dlp, which is far more surface than playing an
// audio file needs.
function mpvCommand(socketPath) {
  return [
    "mpv",
    "--no-video",
    "--idle=yes",
    "--no-terminal",
    "--really-quiet",
    "--audio-display=no",
    "--force-window=no",
    "--keep-open=no",
    "--no-ytdl",
    "--cache=yes",
    "--input-ipc-server=" + socketPath
  ]
}

// XDG_RUNTIME_DIR is a 0700 tmpfs that dies with the session — the
// right home for a control socket. No /tmp fallback: a fixed path in
// a world-writable directory could be created by another account
// first. Returning "" disables playback instead, which is the honest
// outcome on a session with no runtime dir.
function mpvSocketPath(runtimeDir) {
  var dir = String(runtimeDir || "").replace(/\/+$/, "")
  if (dir === "") return ""
  return dir + "/audiobookshelf-mpv.sock"
}

// Every IPC message is JSON.stringify'd, so a title or URL containing
// quotes or newlines is data, not syntax.
function ipc(command, requestId) {
  var payload = { command: command }
  if (requestId !== undefined) payload.request_id = requestId
  return JSON.stringify(payload) + "\n"
}

// --------------------------------------------------------------- playback
//
// playItem() (PlayerState.qml) fires two independent, unordered async
// operations when an item is selected: mpv loading the stream (reports
// back via the file-loaded IPC event) and an ABS progress fetch (a full
// network round-trip). Either can finish first. A resume seek is only
// correct once BOTH have landed — seeking before the file is loaded is a
// no-op on mpv's side, and seeking is skipped entirely if this check only
// lived inside the file-loaded handler, silently dropping a late-arriving
// progress response. This predicate is order-independent: call it from
// both completion handlers and it gives the same answer regardless of
// which fired first.
function shouldSeekOnResume(fileLoaded, progressReady, pendingResumeSeconds) {
  return fileLoaded === true && progressReady === true && pendingResumeSeconds >= 0
}

// ---------------------------------------------------------------- display

// Seconds -> "m:ss" or "h:mm:ss".
function formatTime(seconds) {
  var s = Math.max(0, Math.floor(Number(seconds) || 0))
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  var sec = s % 60
  var pad = function(n) { return n < 10 ? "0" + n : String(n) }
  return h > 0 ? h + ":" + pad(m) + ":" + pad(sec) : m + ":" + pad(sec)
}

// ABS publishedAt (epoch ms) -> "Sep 24, 2026"; "" when missing.
function formatDate(epochMs) {
  if (!epochMs) return ""
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  var d = new Date(epochMs)
  return months[d.getMonth()] + " " + d.getDate() + ", " + d.getFullYear()
}
