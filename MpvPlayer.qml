import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: player

  property string socketPath: Model.mpvSocketPath(Quickshell.env("XDG_RUNTIME_DIR"))
  property bool playerStarted: false
  property bool socketReady: false
  property bool playing: false
  property real positionSeconds: 0
  property int nextRequestId: 1

  signal positionChanged(real seconds)
  signal playerError(string message)
  signal fileLoaded()
  signal loadFailed(string reason)

  // Commands sent before the IPC socket is connected are queued and flushed
  // once it connects, instead of being silently dropped (a dropped loadfile
  // left the UI stuck on "Loading..." with mpv still on the previous file).
  property var pendingCommands: []

  readonly property bool playerAvailable: socketPath !== ""

  function ensurePlayer() {
    if (!playerAvailable) {
      playerError("no XDG_RUNTIME_DIR, so there is nowhere safe to put the player's control socket")
      return false
    }
    playerStarted = true
    if (!mpvProc.running) mpvProc.running = true
    if (!mpvSock.connected && !socketRetry.running) socketRetry.restart()
    return true
  }

  function send(command) {
    if (!mpvSock.connected) {
      console.warn("audiobookshelf: mpv socket not connected, queueing", command[0])
      player.pendingCommands = player.pendingCommands.concat([command])
      if (player.playerStarted && !socketRetry.running) socketRetry.restart()
      return
    }
    var id = player.nextRequestId++
    mpvSock.write(Model.ipc(command, id))
    mpvSock.flush()
  }

  function load(url) {
    if (!ensurePlayer()) return
    send(["loadfile", url, "replace"])
  }

  function seek(seconds) {
    send(["seek", seconds, "absolute"])
  }

  function setPaused(paused) {
    send(["set_property", "pause", paused])
  }

  function setSpeed(rate) {
    send(["set_property", "speed", rate])
  }

  function handleIpc(line) {
    try {
      var msg = JSON.parse(line)
      if (msg.event === "pause") { player.playing = false }
      else if (msg.event === "unpause") { player.playing = true }
      else if (msg.event === "file-loaded") { player.fileLoaded() }
      else if (msg.event === "end-file" && msg.reason === "error") {
        player.loadFailed(msg.file_error || "unknown error")
      }
      else if (msg.event === "property-change" && msg.name === "time-pos") {
        player.positionSeconds = msg.data || 0
        player.positionChanged(player.positionSeconds)
      }
      else if (msg.event === "property-change" && msg.name === "pause") {
        // The "pause"/"unpause" events above are deprecated and removed in modern
        // mpv — observe_property on "pause" (subscribed alongside time-pos in
        // onConnectionStateChanged below) is the supported mechanism. mpv's
        // "pause" property is true when paused, so playing is its inverse.
        player.playing = !msg.data
      }
    } catch (e) {
      // malformed line from mpv — ignore rather than crash the socket handler
    }
  }

  Process {
    id: mpvProc
    command: Model.mpvCommand(player.socketPath)
    onExited: {
      player.playerStarted = false
      player.socketReady = false
      player.playing = false
      mpvSock.connected = false
      player.playerError("mpv stopped")
    }
  }

  Socket {
    id: mpvSock
    path: player.socketPath

    onConnectionStateChanged: {
      if (connected) {
        player.socketReady = true
        socketRetry.stop()
        // Subscribe to time-pos and pause updates once per connection. pause is
        // observed rather than relying on the "pause"/"unpause" IPC events, which
        // were deprecated and removed in modern mpv (mpv.io/manual/master's JSON
        // IPC docs) — observe_property is the supported mechanism.
        var id1 = player.nextRequestId++
        write(Model.ipc(["observe_property", 1, "time-pos"], id1))
        var id2 = player.nextRequestId++
        write(Model.ipc(["observe_property", 2, "pause"], id2))
        flush()
        var queued = player.pendingCommands
        player.pendingCommands = []
        for (var i = 0; i < queued.length; i++) player.send(queued[i])
      } else {
        player.socketReady = false
      }
    }

    onError: function(err) {
      // mpv creates its socket a beat after exec; keep knocking until it answers.
      if (player.playerStarted && !socketRetry.running) socketRetry.start()
    }

    parser: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { player.handleIpc(line) }
    }
  }

  Timer {
    id: socketRetry
    interval: 300
    repeat: true
    onTriggered: {
      if (mpvSock.connected || !player.playerStarted) { stop(); return }
      mpvSock.connected = false
      Qt.callLater(function() { mpvSock.connected = true })
    }
  }
}
