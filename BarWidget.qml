import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar entry point: a themed headphones glyph (BarIconButton, same as the
// built-in widgets, so it takes the bar's own color and font) hosting the
// dropdown in Panel.qml. Panel owns the player and the library; this file
// only reads state back for the icon, tooltip and middle-click play/pause.
BarWidget {
  id: root
  moduleName: "abs-player"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  readonly property var player: panelLoader.item ? panelLoader.item.player : null
  readonly property bool playing: player ? player.playing : false

  property bool serverReachable: true

  // Opening the dropdown counts as having seen the new episodes.
  onOpenedChanged: if (opened) poller.unreadCount = 0

  readonly property string tooltipText: {
    if (player && player.hasItem)
      return (player.playing ? "Playing: " : "Paused: ") + player.title
    if (poller.unreadCount > 0)
      return "Audiobookshelf: " + poller.unreadCount + (poller.unreadCount === 1 ? " new episode" : " new episodes")
    return "Audiobookshelf"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "abs-player"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function playPause(): void { if (root.player) root.player.togglePause() }
    function browse(type: string): void { root.open(); if (panelLoader.item) panelLoader.item.browseType(type) }
    function search(query: string): void { root.open(); if (panelLoader.item) panelLoader.item.searchFor(query) }
    function openPodcast(title: string): void { root.open(); if (panelLoader.item) panelLoader.item.openPodcastNamed(title) }
    function home(): void { root.open(); if (panelLoader.item) panelLoader.item.goHome() }
    function popOut(): void { if (panelLoader.item) panelLoader.item.setExpanded(true) }
  }

  PollTimer {
    id: poller
    pollMinutes: root.setting("pollMinutes", 20)
    onFetchFailed: root.serverReachable = false
    onFetchSucceeded: root.serverReachable = true
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰋋"
    tooltipText: root.tooltipText
    // New episodes use the bar's own highlight color, like other widgets'
    // active state; a failed background fetch dims the icon.
    active: poller.unreadCount > 0
    dimmed: !root.serverReachable
    onPressed: function(b) {
      if (b === Qt.MiddleButton) { if (root.player) root.player.togglePause() }
      else root.togglePanel()
    }
  }
}
