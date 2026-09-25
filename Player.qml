import Quickshell
import Quickshell.Io
import QtQuick
import "Model.js" as Model

// Playback state for the plugin: the single mpv instance, what's loaded in it,
// resume-on-load, and periodic progress sync back to Audiobookshelf. One
// instance lives inside Panel.qml; BarWidget.qml reaches it through the panel
// Loader (the same host/panel split the Todoist plugin uses).
//
// This used to be a `pragma Singleton` shared between two manifest entry
// points. Quickshell only registers singletons for files inside its own shell
// directory; plugins load from ~/.config/omarchy/plugins/, so references to it
// resolved to the type rather than an instance and every property read came
// back undefined (shell log, 2026-09-24: "Cannot read property 'playing' of
// undefined"). Owning it as a plain child avoids cross-entry-point state.
Item {
  id: state

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")

  // The library item currently loaded into mpv (null until something is picked),
  // plus the podcast episode when the item is a podcast. currentItem is enriched
  // in place with the session's authoritative duration/chapters once it lands.
  property var currentItem: null
  property var currentEpisode: null
  property var chapters: []
  property real duration: 0
  property string errorText: ""
  property bool loading: false

  readonly property alias mpv: mpvInstance
  readonly property bool playing: mpvInstance.playing
  readonly property real position: mpvInstance.positionSeconds
  readonly property bool hasItem: currentItem !== null

  readonly property string title: {
    if (!currentItem) return ""
    if (currentEpisode) return currentEpisode.title
    return currentItem.media.metadata.title || ""
  }
  readonly property string subtitle: {
    if (!currentItem) return ""
    if (currentEpisode) return currentItem.media.metadata.title || ""
    return currentItem.media.metadata.authorName || ""
  }

  // ABS keys episode progress as <itemId>/<episodeId>; the backend passes the
  // key straight into /api/me/progress/<key>, so one string covers both cases.
  readonly property string progressKey: {
    if (!currentItem) return ""
    return currentEpisode ? currentItem.id + "/" + currentEpisode.id : currentItem.id
  }

  // Index of the chapter containing the playhead, or -1.
  readonly property int currentChapterIndex: {
    var pos = state.position
    for (var i = chapters.length - 1; i >= 0; i--) {
      if (pos >= chapters[i].start) return i
    }
    return -1
  }

  property real _pendingResumeSeconds: -1
  property bool _mpvFileLoaded: false
  property bool _progressReady: false

  function _maybeSeekToResume() {
    if (Model.shouldSeekOnResume(state._mpvFileLoaded, state._progressReady,
                                  state._pendingResumeSeconds)) {
      mpvInstance.seek(state._pendingResumeSeconds)
      state._pendingResumeSeconds = -1
    }
  }

  function playItem(item, episode) {
    // Save where the previous item stopped before switching away from it.
    if (state.hasItem) state.syncNow(false)

    state.currentItem = item
    state.currentEpisode = episode || null
    state.chapters = (item && item.media && item.media.chapters) || []
    state.duration = episode ? (episode.duration || 0) : ((item && item.media && item.media.duration) || 0)
    state.errorText = ""
    state.loading = true
    state._pendingResumeSeconds = -1
    state._mpvFileLoaded = false
    state._progressReady = false

    var args = ["python3", state.pluginDir + "/scripts/abs_backend.py", "start-playback", item.id]
    if (episode) args.push(episode.id)
    console.log("audiobookshelf: starting playback", item.id, episode ? episode.id : "")
    startPlaybackProcess.command = args
    startPlaybackProcess.running = true

    getProgressProcess.command = ["python3", state.pluginDir + "/scripts/abs_backend.py",
      "get-progress", state.progressKey]
    getProgressProcess.running = true
  }

  function togglePause() {
    if (!state.hasItem) return
    mpvInstance.setPaused(mpvInstance.playing)
  }

  function skip(seconds) {
    if (!state.hasItem) return
    var target = Math.max(0, state.position + seconds)
    if (state.duration > 0) target = Math.min(state.duration, target)
    mpvInstance.seek(target)
  }

  function seekTo(seconds) {
    if (state.hasItem) mpvInstance.seek(seconds)
  }

  function syncNow(finished) {
    if (!state.hasItem || state.duration <= 0) return
    syncProcess.command = ["python3", state.pluginDir + "/scripts/abs_backend.py",
      "sync-progress", state.progressKey, String(state.position),
      String(state.duration), finished ? "true" : "false"]
    syncProcess.running = true
  }

  MpvPlayer {
    id: mpvInstance
    onFileLoaded: {
      state.loading = false
      state._mpvFileLoaded = true
      state._maybeSeekToResume()
    }
    onPlayerError: function(message) {
      console.warn("audiobookshelf: mpv error:", message)
      state.loading = false
    }
    onLoadFailed: function(reason) {
      console.warn("audiobookshelf: mpv could not open the stream:", reason)
      state.loading = false
      state.errorText = "mpv couldn't play this item (" + reason + ")"
    }
  }

  // Never leave "Loading..." up forever: if mpv hasn't reported the file as
  // loaded after 30s, surface it instead of failing silently.
  Timer {
    interval: 30000
    running: state.loading
    onTriggered: {
      console.warn("audiobookshelf: playback didn't start within 30s")
      state.loading = false
      state.errorText = "Playback didn't start. Try again, or check the server."
    }
  }

  // Sync every 15s while playing so a crash loses at most a few seconds, and
  // once more whenever playback pauses.
  Timer {
    interval: 15000
    running: mpvInstance.playing
    repeat: true
    onTriggered: state.syncNow(false)
  }

  Connections {
    target: mpvInstance
    function onPlayingChanged() {
      if (!mpvInstance.playing) state.syncNow(false)
    }
  }

  Process {
    id: startPlaybackProcess
    stdout: StdioCollector {
      onStreamFinished: {
        var session
        try {
          session = JSON.parse(text)
        } catch (e) {
          console.warn("audiobookshelf: couldn't parse the playback session:", e)
          state.loading = false
          state.errorText = "Unexpected response from the backend"
          return
        }
        if (session.error || !session.streamUrl) {
          console.warn("audiobookshelf: playback session failed:", session.error || "no stream URL")
          state.loading = false
          state.errorText = session.error || "The server returned nothing to play"
          return
        }
        // A stale response can land after the user already picked something else.
        if (!state.currentItem || state.currentItem.id !== session.libraryItemId) {
          console.log("audiobookshelf: ignoring a stale playback session for", session.libraryItemId)
          return
        }
        if (session.duration) state.duration = session.duration
        state.chapters = session.chapters || []
        console.log("audiobookshelf: session ready, loading into mpv (socket connected:",
          mpvInstance.socketReady + ")")
        mpvInstance.load(session.streamUrl)
      }
    }
  }

  Process {
    id: getProgressProcess
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var response = JSON.parse(text)
          if (response.itemId !== state.progressKey) return
          var progress = response.progress
          if (progress && !progress.isFinished && typeof progress.currentTime === "number"
              && progress.currentTime > 0) {
            state._pendingResumeSeconds = progress.currentTime
          }
        } catch (e) {
          // Never played before (or not logged in): start from 0.
        }
        state._progressReady = true
        state._maybeSeekToResume()
      }
    }
  }

  Process {
    id: syncProcess
    // Fire-and-forget: sync_progress queues failures for the next poll's flush.
  }
}
