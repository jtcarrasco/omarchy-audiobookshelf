import QtQuick
import Quickshell.Io

Item {
  id: poller

  // Quickshell.pluginDir does not exist (confirmed against the installed
  // quickshell-core.qmltypes — real properties are shellDir/configDir/dataDir/
  // stateDir/cacheDir/shellPath, no pluginDir). Qt.resolvedUrl(".") resolves
  // relative to this file's own location instead, which is this plugin's root
  // since every *.qml file here lives flat at the top level.
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")

  property int pollMinutes: 20  // bound to the manifest's pollMinutes setting
  property int unreadCount: 0

  signal newEpisodesFound(int count)
  signal fetchFailed()
  signal fetchSucceeded()

  function jitteredIntervalMs() {
    // +/- 20% jitter so multiple installs never all poll in lockstep
    var base = poller.pollMinutes * 60 * 1000
    var jitter = base * 0.2 * (Math.random() * 2 - 1)
    return Math.round(base + jitter)
  }

  Timer {
    id: pollTimer
    interval: poller.jitteredIntervalMs()
    running: true
    repeat: true
    onTriggered: {
      pollProcess.running = true
      // Fire-and-forget: drains any progress writes that failed mid-playback
      // (network blip) and got queued locally, mirroring the fire-and-forget
      // syncProcess pattern in NowPlayingPopup.qml. Nothing here reacts to the
      // result — a failed flush just stays queued for the next cycle.
      flushProcess.command = ["python3", poller.pluginDir + "/scripts/abs_backend.py",
        "flush-pending"]
      flushProcess.running = true
      interval = poller.jitteredIntervalMs()  // re-jitter each cycle
    }
  }

  Process {
    id: pollProcess
    command: ["python3", poller.pluginDir + "/scripts/abs_backend.py", "poll"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          if (parsed && parsed.error) {
            console.warn("poll failed:", parsed.error)
            poller.fetchFailed()
            return
          }
          var newEpisodes = parsed
          poller.fetchSucceeded()
          if (newEpisodes.length > 0) {
            poller.unreadCount += newEpisodes.length
            poller.newEpisodesFound(newEpisodes.length)
            // A single notify-send call per poll cycle rather than one per
            // episode: notifyProcess is one Process id, and Quickshell's
            // Process.command changes / running = true are no-ops on an
            // already-running process, so looping notifyProcess.running = true
            // per episode silently dropped all but one notification. A summary
            // notification is simpler and more robust than juggling N transient
            // Process objects for what's normally a 0-1 episode event anyway.
            var body = newEpisodes.length === 1
              ? newEpisodes[0].media.metadata.title
              : newEpisodes.length + " new episodes"
            notifyProcess.command = ["notify-send",
              newEpisodes.length === 1 ? "New episode" : "New episodes", body]
            notifyProcess.running = true
          }
        } catch (e) {
          console.warn("poll parse failed:", e)
          poller.fetchFailed()
        }
      }
    }
  }

  Process {
    id: notifyProcess
  }

  Process {
    id: flushProcess
    // fire-and-forget — see onTriggered above
  }
}
