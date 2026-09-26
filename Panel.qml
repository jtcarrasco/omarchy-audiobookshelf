import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The dropdown: now-playing controls on top, the library below, and the
// connection form when the plugin isn't set up yet. Built from the shell's own
// qs.Ui kit (KeyboardPanel, TextField, Button, ButtonGroup, PanelSlider) and
// qs.Commons Color/Style, so colors, fonts and spacing follow the user's theme
// the same way the built-in panels and the Todoist plugin do.
Panel {
  id: root
  moduleName: "abs-player"
  ipcTarget: "abs-player"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")

  // Sized like a dropdown, not a window (user request 2026-09-24). The header's
  // expand button pops it out to half the screen width at full available height.
  property int panelWidth: 600
  property int panelHeight: 800
  property bool expanded: false

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color mutedFg: Qt.darker(fg, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property alias player: player

  property bool configured: false
  property string serverUrl: ""
  // Which ABS libraries the plugin reads. Either can be "" on servers with
  // only books or only podcasts; the UI then shows just the one type.
  property string bookLibId: ""
  property string podcastLibId: ""
  property var libraries: []  // [{id, name, mediaType}] for the settings picker
  readonly property bool hasBooks: root.bookLibId !== ""
  readonly property bool hasPodcasts: root.podcastLibId !== ""
  readonly property var typeOptions: {
    var opts = []
    if (root.hasBooks) opts.push({ value: "book", label: "Books", tooltip: "Books (2)" })
    if (root.hasPodcasts) opts.push({ value: "podcast", label: "Podcasts", tooltip: "Podcasts (3)" })
    return opts
  }
  readonly property string defaultType: root.hasBooks || !root.hasPodcasts ? "book" : "podcast"
  onDefaultTypeChanged: if (!root.browsing) root.filterType = root.defaultType
  property bool settingsView: false
  property var allItems: []
  property bool itemsLoading: false
  property string listError: ""
  property string filterText: ""
  property string filterType: "book"  // "book" | "podcast" | "" (search across both)
  property bool chaptersOpen: false
  // Keyboard selection in the library/episode list. The highlight only shows
  // once a key has moved it, so mouse users never see a stray selection.
  property int cursor: 0
  property bool keyNav: false
  // Playback speed as the speed buttons' value, shared by both player layouts.
  property string speed: "1"
  property bool notesOpen: false

  // Podcast drill-down: when set, the list shows this podcast's episodes.
  property var openPodcast: null
  property var episodes: []
  property bool episodesLoading: false

  property string setupError: ""
  property bool confirmDisconnect: false
  property bool setupBusy: false
  property string pendingPassword: ""

  readonly property var visibleItems: allItems.filter(function(it) {
    var matchesType = filterType === "" || it.mediaType === filterType
    var needle = filterText.toLowerCase()
    var title = (it.media.metadata.title || "").toLowerCase()
    var author = (it.media.metadata.authorName || "").toLowerCase()
    return matchesType && (needle === "" || title.indexOf(needle) !== -1 || author.indexOf(needle) !== -1)
  })

  function backend(args) {
    return ["python3", root.pluginDir + "/scripts/abs_backend.py"].concat(args)
  }

  // Pop-out: the same content moves into a real, resizable window (tiled by
  // Hyprland like any app window) instead of the bar dropdown.
  function setExpanded(on) {
    if (on) {
      root.controller.hide()
      root.expanded = true
      popWindow.visible = true
      keyCatcher.forceActiveFocus()
    } else {
      root.expanded = false
      popWindow.visible = false
      root.controller.show()
    }
  }

  function open() {
    if (root.expanded) { popWindow.visible = true; return }
    root.controller.show()
    if (root.configured && root.allItems.length === 0 && !root.itemsLoading) root.refresh()
  }
  function close() { root.controller.hide() }
  function toggle() {
    if (root.expanded) { root.expanded = false; popWindow.visible = false; return }
    root.opened ? root.close() : root.open()
  }

  function refresh() {
    if (!root.configured || fetchItems.running) return
    root.itemsLoading = true
    root.listError = ""
    fetchItems.running = true
  }

  function openItem(item) {
    if (item.mediaType === "podcast") {
      root.openPodcast = item
      root.episodes = []
      root.episodesLoading = true
      fetchEpisodes.command = root.backend(["list-episodes", item.id])
      fetchEpisodes.running = true
    } else {
      player.playItem(item, null)
    }
  }

  // Back to the top-level library: no podcast drill-down, no search or type
  // filter, list scrolled to the top. Now Playing is left alone.
  // Home = big player (or the logo when nothing is loaded) with search and the
  // Books/Podcasts buttons underneath. Picking a type or typing a search
  // switches to browsing the list.
  property bool browsing: false
  readonly property bool onHome: !root.settingsView && root.openPodcast === null && !root.browsing
  readonly property bool libraryView: !root.settingsView && root.openPodcast === null && root.browsing

  function goHome() {
    if (root.configured) root.settingsView = false
    root.openPodcast = null
    root.episodes = []
    root.filterType = root.defaultType
    root.browsing = false
    root.keyNav = false
    root.cursor = 0
    searchField.text = ""
    itemList.positionViewAtBeginning()
  }

  // Starting an episode marks it played-at-least-once right away, so the
  // unplayed markers update without waiting for the next library refresh.
  function markEpisodeStarted(podcast, episode) {
    if (episode.userProgress) return
    root.episodes = root.episodes.map(function(ep) {
      if (ep.id !== episode.id) return ep
      var copy = JSON.parse(JSON.stringify(ep))
      copy.userProgress = { progress: 0, isFinished: false }
      return copy
    })
    root.decrementUnplayed(podcast.id)
  }

  function decrementUnplayed(podcastId) {
    root.allItems = root.allItems.map(function(it) {
      if (it.id !== podcastId || !(it.unplayedCount > 0)) return it
      var copy = JSON.parse(JSON.stringify(it))
      copy.unplayedCount = it.unplayedCount - 1
      return copy
    })
  }

  // IPC entry points (see BarWidget.qml): jump straight to a view, e.g. from
  // a keybinding.
  function browseType(type) {
    root.settingsView = false
    root.openPodcast = null
    root.filterType = (type === "podcast" && root.hasPodcasts) ? "podcast"
      : (root.hasBooks ? "book" : "podcast")
    root.browsing = true
  }
  function searchFor(query) {
    root.settingsView = false
    root.openPodcast = null
    root.filterType = ""
    root.browsing = true
    searchField.text = query
  }
  function openPodcastNamed(query) {
    var needle = String(query).toLowerCase()
    for (var i = 0; i < root.allItems.length; i++) {
      var it = root.allItems[i]
      if (it.mediaType === "podcast" && (it.media.metadata.title || "").toLowerCase().indexOf(needle) !== -1) {
        root.settingsView = false
        root.browsing = true
        root.openItem(it)
        return
      }
    }
  }

  // Right-click on a book or episode flips its finished state on the server,
  // updating the list right away rather than waiting for a refresh.
  function toggleFinished(item, episode) {
    var prog = (episode ? episode.userProgress : item.userProgress) || null
    var finished = !(prog && prog.isFinished)
    var key = episode ? item.id + "/" + episode.id : item.id
    finishedProcess.command = root.backend(["set-finished", key, finished ? "true" : "false"])
    finishedProcess.running = true
    var patch = function(obj) {
      var copy = JSON.parse(JSON.stringify(obj))
      var p = copy.userProgress || { progress: 0 }
      p.isFinished = finished
      // ABS resets the position to 0 when an item is marked not finished.
      p.progress = finished ? 1 : 0
      copy.userProgress = p
      return copy
    }
    if (episode) {
      // A never-started episode counted toward the podcast's "N unplayed"
      // pill; once it has a progress record it no longer does.
      if (!episode.userProgress) root.decrementUnplayed(item.id)
      root.episodes = root.episodes.map(function(ep) { return ep.id === episode.id ? patch(ep) : ep })
    } else {
      root.allItems = root.allItems.map(function(it) { return it.id === item.id ? patch(it) : it })
    }
  }

  // ---- Keyboard (same keys as the FreshRSS plugin where they overlap) -------
  readonly property var listModel: root.openPodcast ? root.episodes : root.visibleItems
  readonly property bool listVisible: !root.settingsView && !root.onHome

  onOpenPodcastChanged: { root.cursor = 0; itemList.positionViewAtBeginning() }
  onFilterTypeChanged: root.cursor = 0
  onFilterTextChanged: root.cursor = 0

  function moveCursor(delta) {
    if (!root.listVisible || root.listModel.length === 0) return
    root.keyNav = true
    root.cursor = Math.max(0, Math.min(root.listModel.length - 1, root.cursor + delta))
    itemList.positionViewAtIndex(root.cursor, ListView.Contain)
  }
  function jumpTo(first) {
    if (!root.listVisible || root.listModel.length === 0) return
    root.keyNav = true
    root.cursor = first ? 0 : root.listModel.length - 1
    itemList.positionViewAtIndex(root.cursor, ListView.Contain)
  }
  // Enter: same as clicking the selected row.
  function activateSelected() {
    var it = root.listModel[root.cursor]
    if (!root.listVisible || !it) return false
    if (root.openPodcast) {
      root.markEpisodeStarted(root.openPodcast, it)
      player.playItem(root.openPodcast, it)
    } else {
      root.openItem(it)
    }
    return true
  }
  // r / f: same as right-clicking the selected row (r is FreshRSS's "mark
  // read"; f for "finished").
  function toggleFinishedSelected() {
    var it = root.listModel[root.cursor]
    if (!root.listVisible || !it) return
    if (root.openPodcast) root.toggleFinished(root.openPodcast, it)
    else if (it.mediaType !== "podcast") root.toggleFinished(it, null)
  }
  function skipChapter(direction) {
    var target = Model.chapterSeekTarget(player.chapters, player.position, direction)
    if (target >= 0) player.seekTo(target)
  }
  function setSpeed(value) {
    root.speed = value
    player.mpv.setSpeed(Number(value))
  }
  // Tab flips between Books and Podcasts while browsing.
  function cycleType() {
    if (!root.browsing || root.openPodcast || root.typeOptions.length < 2) return
    root.filterType = root.filterType === "book" ? "podcast" : "book"
  }
  function handleKey(t) {
    if (t === "/" || t === "a") searchField.forceActiveFocus()
    else if (t === "q" || t === "R") root.refresh()
    else if (t === "r" || t === "f") root.toggleFinishedSelected()
    else if (t === "n") root.skipChapter(1)
    else if (t === "p") root.skipChapter(-1)
    else if (t === "[") root.setSpeed(Model.stepSpeed(root.speed, -1))
    else if (t === "]") root.setSpeed(Model.stepSpeed(root.speed, 1))
    else if (t === "c" && player.chapters.length > 0) root.chaptersOpen = !root.chaptersOpen
    // , opens settings (the usual settings shortcut); again to go back.
    else if (t === "," && root.configured) root.settingsView = !root.settingsView
    // z: "zoom" between the dropdown and its own window (tmux's zoom key).
    else if (t === "z") root.setExpanded(!root.expanded)
    // 1-3 jump between the main views, like FreshRSS's view keys.
    else if (t === "1" && root.configured) root.goHome()
    else if (t === "2" && root.hasBooks) root.browseType("book")
    else if (t === "3" && root.hasPodcasts) root.browseType("podcast")
  }
  // Home/End aren't handled by PanelKeyCatcher, so they bubble up to the slot.
  function slotKey(event) {
    if (event.key === Qt.Key_Home) { root.jumpTo(true); event.accepted = true }
    else if (event.key === Qt.Key_End) { root.jumpTo(false); event.accepted = true }
  }

  readonly property var keyHelp: [
    { key: "j / k", action: "Move down / up the list" },
    { key: "Home / End", action: "First / last item" },
    { key: "Enter", action: "Play, or open a podcast" },
    { key: "r / f", action: "Toggle finished" },
    { key: "1 / 2 / 3", action: "Home / Books / Podcasts" },
    { key: "Tab", action: "Switch Books / Podcasts" },
    { key: "Space", action: "Play / pause" },
    { key: "h / l", action: "Back / forward 30s" },
    { key: "n / p", action: "Next / previous chapter" },
    { key: "[ / ]", action: "Slower / faster" },
    { key: "c", action: "Show chapters" },
    { key: "/ or a", action: "Search" },
    { key: "q / R", action: "Refresh library" },
    { key: "z", action: "Window / dropdown" },
    { key: ",", action: "Settings" },
    { key: "Esc", action: "Back, then close" },
    { key: "Right-click", action: "Toggle finished on a row" }
  ]
  // One width for every key chip so the action column lines up.
  readonly property real keyChipWidth: keyChipProbe.advanceWidth + Style.spacing.md * 2
  TextMetrics { id: keyChipProbe; text: "Home / End"; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }

  function goBack() {
    if (root.settingsView && root.configured) { root.settingsView = false; return true }
    if (root.openPodcast) { root.openPodcast = null; root.episodes = []; return true }
    return false
  }

  Component.onCompleted: checkConfigured.running = true

  Player { id: player }

  Process {
    id: disconnectProcess
    command: root.backend(["disconnect"])
    stdout: StdioCollector {
      onStreamFinished: {
        player.reset()
        root.configured = false
        root.serverUrl = ""
        root.bookLibId = ""
        root.podcastLibId = ""
        root.libraries = []
        root.allItems = []
        root.episodes = []
        root.openPodcast = null
        root.browsing = false
        root.confirmDisconnect = false
        root.settingsView = true
      }
    }
  }

  // Disconnect asks for a second click within a few seconds.
  Timer {
    id: confirmTimer
    interval: 4000
    onTriggered: root.confirmDisconnect = false
  }

  Process {
    id: listLibraries
    command: root.backend(["list-libraries"])
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var r = JSON.parse(text)
          if (!r.error) root.libraries = r.libraries || []
        } catch (e) {}
      }
    }
  }

  Process {
    id: setLibraries
    stdout: StdioCollector {
      onStreamFinished: {
        root.allItems = []
        root.refresh()
      }
    }
  }

  function chooseLibrary(mediaType, id) {
    if (mediaType === "book") root.bookLibId = id
    else root.podcastLibId = id
    setLibraries.command = root.backend(["set-libraries", root.bookLibId, root.podcastLibId])
    setLibraries.running = true
  }

  function librariesOfType(mediaType) {
    return root.libraries.filter(function(l) { return l.mediaType === mediaType })
      .map(function(l) { return { value: l.id, label: l.name } })
  }

  onSettingsViewChanged: if (root.settingsView && root.configured) listLibraries.running = true

  Process {
    id: finishedProcess
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var r = JSON.parse(text)
          if (r.error) root.listError = r.error
        } catch (e) {}
      }
    }
  }

  Process {
    id: checkConfigured
    command: root.backend(["check-configured"])
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var r = JSON.parse(text)
          root.configured = r.configured === true
          root.serverUrl = r.baseUrl || ""
          root.bookLibId = r.libraryId || ""
          root.podcastLibId = r.podcastLibraryId || ""
        } catch (e) {}
        if (!root.configured) root.settingsView = true
        else if (root.opened) root.refresh()
      }
    }
  }

  Process {
    id: fetchItems
    command: root.backend(["list-items"])
    stdout: StdioCollector {
      onStreamFinished: {
        root.itemsLoading = false
        try {
          var parsed = JSON.parse(text)
          if (parsed && parsed.error) { root.listError = parsed.error; return }
          root.allItems = parsed
        } catch (e) {
          root.listError = "Couldn't read the library from the backend"
        }
      }
    }
  }

  Process {
    id: fetchEpisodes
    stdout: StdioCollector {
      onStreamFinished: {
        root.episodesLoading = false
        try {
          var parsed = JSON.parse(text)
          if (parsed && parsed.error) { root.listError = parsed.error; return }
          root.episodes = parsed
        } catch (e) {
          root.listError = "Couldn't read the episode list"
        }
      }
    }
  }

  Process {
    id: mpvCheck
    command: root.backend(["check-mpv"])
    stdout: StdioCollector {
      onStreamFinished: {
        var installed = false
        try { installed = JSON.parse(text).installed === true } catch (e) {}
        if (!installed) {
          root.setupBusy = false
          root.pendingPassword = ""
          root.setupError = "mpv is required but not installed. Install the mpv package, then connect again."
          return
        }
        loginProcess.command = root.backend(["login", urlField.text.trim(), userField.text.trim()])
        loginProcess.running = true
      }
    }
  }

  Process {
    id: loginProcess
    // stdin stays enabled for the life of this Process: once disabled,
    // Quickshell never re-enables it, which would silently blank the
    // password on every retry. The backend reads one line per attempt.
    stdinEnabled: true
    onStarted: {
      write(root.pendingPassword + "\n")
      root.pendingPassword = ""
    }
    stdout: StdioCollector {
      onStreamFinished: {
        root.setupBusy = false
        try {
          var result = JSON.parse(text)
          if (result.ok) {
            passField.text = ""
            root.serverUrl = result.baseUrl || urlField.text.trim().replace(/\/+$/, "")
            root.libraries = result.libraries || []
            root.bookLibId = result.libraryId || ""
            root.podcastLibId = result.podcastLibraryId || ""
            root.configured = true
            root.settingsView = false
            root.allItems = []
            root.refresh()
          } else {
            root.setupError = result.error || "Connection failed"
          }
        } catch (e) {
          root.setupError = "Unexpected response from the backend"
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.panelWidth)
    // Home has no list, so the card shrinks to its content (plus a little
    // breathing room) instead of keeping the full list height.
    contentHeight: root.onHome
      ? panel.fittedContentHeight(Math.min(root.panelHeight, mainColumn.implicitHeight + Style.space(16)))
      : panel.fittedContentHeight(root.panelHeight)
    padding: Style.space(20)

    Item { id: dropdownSlot; anchors.fill: parent; Keys.onPressed: function(e) { root.slotKey(e) } }
  }

  FloatingWindow {
    id: popWindow
    visible: false
    title: "Audiobookshelf"
    color: Color.popups.background
    implicitWidth: Style.space(760)
    implicitHeight: Style.space(900)
    minimumSize: Qt.size(Style.space(420), Style.space(480))
    // Closing the window (e.g. SUPER+W) returns to the dropdown mode.
    onVisibleChanged: if (!visible && root.expanded) root.expanded = false

    Item {
      id: windowSlot
      anchors.fill: parent
      anchors.margins: Style.space(20)
      Keys.onPressed: function(e) { root.slotKey(e) }
    }
  }

  // The one copy of the panel content, parented into whichever container is
  // active so state (scroll, search, open podcast) carries across.
  PanelKeyCatcher {
    id: keyCatcher
    parent: root.expanded ? windowSlot : dropdownSlot
    anchors.fill: parent
    blocked: searchField.activeFocus || urlField.activeFocus || userField.activeFocus
      || passField.activeFocus
    onCloseRequested: { if (!root.goBack()) { if (root.expanded) root.setExpanded(false); else root.close() } }
    // j/k and the arrows move the list; h/l and left/right skip 30s.
    onMoveRequested: function(dx, dy) {
      if (dy !== 0) root.moveCursor(dy)
      else if (dx !== 0) player.skip(dx * 30)
    }
    // Enter emits return + activate; Space emits only activate. Enter plays the
    // selected row (when there is a list), Space always plays/pauses.
    property bool suppressActivate: false
    onReturnRequested: suppressActivate = root.activateSelected()
    onActivateRequested: {
      if (suppressActivate) { suppressActivate = false; return }
      player.togglePause()
    }
    onTabRequested: function(direction) { root.cycleType() }
    onTextKey: function(t) { root.handleKey(t) }

    ColumnLayout {
      id: mainColumn
      anchors.fill: parent
      spacing: Style.space(12)

      // ---- Header --------------------------------------------------
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.md

        PanelActionButton {
          visible: root.openPodcast !== null || (root.settingsView && root.configured)
          iconText: "󰁍"
          tooltipText: "Back (Esc)"
          foreground: root.fg
          onClicked: root.goBack()
        }

        // Library home: the server's own Audiobookshelf icon + name, with the
        // server URL underneath (click it to open the web app).
        Image {
          visible: root.libraryView && root.serverUrl !== ""
          source: visible ? root.serverUrl + "/icon.svg" : ""
          sourceSize.width: Style.space(36)
          sourceSize.height: Style.space(36)
          Layout.preferredWidth: Style.space(36)
          Layout.preferredHeight: Style.space(36)
          fillMode: Image.PreserveAspectFit
          asynchronous: true
        }

        Item { visible: root.onHome; Layout.fillWidth: true }

        Column {
          visible: root.libraryView
          Layout.fillWidth: true
          spacing: Style.spacing.xxs
          Text {
            text: "Audiobookshelf"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }
          Text {
            visible: root.serverUrl !== ""
            text: root.serverUrl
            color: urlMouse.containsMouse ? Color.accent : root.mutedFg
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            MouseArea {
              id: urlMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: Qt.openUrlExternally(root.serverUrl)
            }
          }
        }

        Text {
          visible: root.settingsView || root.openPodcast !== null
          Layout.fillWidth: true
          text: root.settingsView ? (root.configured ? "Settings" : "Connect to Audiobookshelf")
            : (root.openPodcast ? root.openPodcast.media.metadata.title : "Audiobookshelf")
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
          elide: Text.ElideRight

          // Clicking the title always returns to the library home.
          MouseArea {
            anchors.fill: parent
            enabled: root.configured
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.goHome()
          }
        }

        PanelActionButton {
          visible: root.configured
          iconText: "󰋜"
          tooltipText: "Library home (1)"
          foreground: root.fg
          onClicked: root.goHome()
        }

        PanelActionButton {
          visible: root.configured && !root.settingsView
          iconText: "󰑐"
          tooltipText: "Refresh library (q / R)"
          foreground: root.fg
          onClicked: root.refresh()
        }

        PanelActionButton {
          iconText: root.expanded ? "󰊔" : "󰊓"
          tooltipText: root.expanded ? "Back to the dropdown (z)" : "Open in its own window (z)"
          foreground: root.fg
          onClicked: root.setExpanded(!root.expanded)
        }

        PanelActionButton {
          visible: root.configured
          iconText: "󰒓"
          tooltipText: "Settings (,)"
          foreground: root.fg
          onClicked: root.settingsView = !root.settingsView
        }
      }

      // ---- Connection form ------------------------------------------
      // Scrolls: with libraries and the keyboard reference it can be taller
      // than the dropdown.
      Flickable {
        id: settingsFlick
        visible: root.settingsView
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        contentWidth: width
        contentHeight: settingsColumn.implicitHeight
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
          id: settingsColumn
          width: settingsFlick.width
          spacing: Style.spacing.lg

          Text {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: "Your password goes straight to the server to get a login token, which is stored in the system keyring. It's never saved to a file."
            color: root.mutedFg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          PanelSectionHeader { text: "SERVER"; foreground: root.fg; fontFamily: root.fontFamily }
          TextField { id: urlField; Layout.fillWidth: true; placeholderText: "http://localhost:13378"; foreground: root.fg; font.family: root.fontFamily }

          PanelSectionHeader { text: "ACCOUNT"; foreground: root.fg; fontFamily: root.fontFamily }
          TextField { id: userField; Layout.fillWidth: true; placeholderText: "Username"; foreground: root.fg; font.family: root.fontFamily }
          TextField { id: passField; Layout.fillWidth: true; placeholderText: "Password"; password: true; foreground: root.fg; font.family: root.fontFamily }

          // Libraries are detected from the server at login; a picker only
          // appears when there's more than one of a type to choose from.
          PanelSectionHeader {
            visible: root.configured && root.libraries.length > 0
            text: "LIBRARIES"; foreground: root.fg; fontFamily: root.fontFamily
          }
          Text {
            visible: root.configured && root.libraries.length > 0
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: "Using " + (root.hasBooks ? "a books library" : "no books library")
              + " and " + (root.hasPodcasts ? "a podcasts library" : "no podcasts library") + "."
            color: root.mutedFg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          ButtonGroup {
            visible: root.configured && root.librariesOfType("book").length > 1
            options: root.librariesOfType("book")
            value: root.bookLibId
            foreground: root.fg
            fontFamily: root.fontFamily
            focusable: false
            onChanged: function(v) { root.chooseLibrary("book", v) }
          }
          ButtonGroup {
            visible: root.configured && root.librariesOfType("podcast").length > 1
            options: root.librariesOfType("podcast")
            value: root.podcastLibId
            foreground: root.fg
            fontFamily: root.fontFamily
            focusable: false
            onChanged: function(v) { root.chooseLibrary("podcast", v) }
          }

          Text {
            Layout.fillWidth: true
            visible: root.setupError !== ""
            text: root.setupError
            wrapMode: Text.WordWrap
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            text: root.setupBusy ? "Connecting..." : "Connect"
            bordered: true
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: {
              if (root.setupBusy) return
              root.setupError = ""
              root.setupBusy = true
              root.pendingPassword = passField.text
              mpvCheck.running = true
            }
          }

          PanelSeparator { visible: root.configured; Layout.fillWidth: true; foreground: root.fg }

          Text {
            visible: root.configured
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: "Disconnect removes this server's login and settings from this computer. Your Audiobookshelf account and progress stay on the server."
            color: root.mutedFg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            visible: root.configured
            text: root.confirmDisconnect ? "Click again to disconnect" : "Disconnect"
            bordered: true
            foreground: root.confirmDisconnect ? Color.urgent : root.fg
            fontFamily: root.fontFamily
            onClicked: {
              if (!root.confirmDisconnect) {
                root.confirmDisconnect = true
                confirmTimer.restart()
                return
              }
              confirmTimer.stop()
              disconnectProcess.running = true
            }
          }

          // Keyboard reference: the same keys as the FreshRSS plugin where
          // they overlap.
          PanelSeparator { Layout.fillWidth: true; foreground: root.fg }
          PanelSectionHeader { text: "KEYBOARD"; foreground: root.fg; fontFamily: root.fontFamily }
          GridLayout {
            Layout.fillWidth: true
            columns: 4
            columnSpacing: Style.spacing.lg
            rowSpacing: Style.spacing.sm
            Repeater {
              model: root.keyHelp
              delegate: Item {
                required property var modelData
                // Each entry fills two grid cells: a key chip, then its action.
                Layout.columnSpan: 2
                Layout.fillWidth: true
                implicitHeight: Math.max(keyChip.height, actionText.implicitHeight)
                Rectangle {
                  id: keyChip
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: root.keyChipWidth
                  height: keyText.implicitHeight + Style.spacing.xs * 2
                  radius: Style.cornerRadius
                  color: "transparent"
                  border.width: 1
                  border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.25)
                  Text {
                    id: keyText
                    anchors.centerIn: parent
                    text: modelData.key
                    color: Color.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }
                Text {
                  id: actionText
                  anchors.left: keyChip.right
                  anchors.leftMargin: Style.spacing.md
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.action
                  elide: Text.ElideRight
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }
        }
      }

      // ---- Home: big player, or the logo when nothing is loaded --------
      NowPlaying {
        large: true
        visible: root.onHome && (player.hasItem || player.errorText !== "")
        Layout.fillWidth: true
      }

      Item {
        visible: root.onHome && !player.hasItem && player.errorText === ""
        Layout.fillWidth: true
        Layout.topMargin: Style.space(40)
        implicitHeight: homeLogo.implicitHeight

        Column {
          id: homeLogo
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.spacing.lg
          Image {
            anchors.horizontalCenter: parent.horizontalCenter
            source: root.serverUrl !== "" ? root.serverUrl + "/icon.svg" : ""
            sourceSize.width: Style.space(160)
            sourceSize.height: Style.space(160)
            width: Style.space(160)
            height: Style.space(160)
            fillMode: Image.PreserveAspectFit
            asynchronous: true
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Audiobookshelf"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            font.bold: true
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.serverUrl !== ""
            text: root.serverUrl
            color: homeUrlMouse.containsMouse ? Color.accent : root.mutedFg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            MouseArea {
              id: homeUrlMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: Qt.openUrlExternally(root.serverUrl)
            }
          }
        }
      }

      // ---- Now playing (compact, while browsing) ---------------------
      NowPlaying {
        large: false
        visible: !root.settingsView && !root.onHome && (player.hasItem || player.errorText !== "")
        Layout.fillWidth: true
      }

      // ---- Library ----------------------------------------------------
      RowLayout {
        visible: !root.settingsView && root.openPodcast === null
        Layout.fillWidth: true
        spacing: Style.spacing.lg

        TextField {
          id: searchField
          Layout.fillWidth: true
          placeholderText: "Search title or author  (/ or a)"
          foreground: root.fg
          font.family: root.fontFamily
          onTextChanged: {
            root.filterText = text
            // Searching from home looks across books and podcasts; the
            // Books/Podcasts buttons narrow it down afterwards.
            if (text !== "" && !root.browsing) {
              root.filterType = ""
              root.browsing = true
            }
          }
          Keys.onEscapePressed: { text = ""; keyCatcher.forceActiveFocus() }
        }

        ButtonGroup {
          options: root.typeOptions
          value: root.browsing ? root.filterType : ""
          foreground: root.fg
          fontFamily: root.fontFamily
          focusable: false
          onChanged: function(v) { root.filterType = v; root.browsing = true }
        }
      }

      Text {
        Layout.fillWidth: true
        visible: !root.settingsView && !root.onHome && (root.listError !== "" || root.itemsLoading || root.episodesLoading
          || (root.openPodcast === null && root.visibleItems.length === 0))
        text: root.listError !== "" ? root.listError
          : (root.itemsLoading || root.episodesLoading) ? "Loading..."
          : (root.allItems.length === 0 ? "Nothing in your libraries yet." : "No matches.")
        color: root.listError !== "" ? Color.urgent : root.mutedFg
        wrapMode: Text.WordWrap
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      ListView {
        id: itemList
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: !root.settingsView && !root.onHome
        clip: true
        spacing: Style.spacing.xs
        boundsBehavior: Flickable.StopAtBounds
        model: root.openPodcast ? root.episodes : root.visibleItems
        delegate: ListRow {
          width: itemList.width
          selected: root.keyNav && index === root.cursor
          cover: root.openPodcast ? "" : (modelData.coverUrl || "")
          glyph: root.openPodcast ? "󰎇" : (modelData.mediaType === "podcast" ? "󰦔" : "󰂺")
          primary: root.openPodcast ? modelData.title : (modelData.media.metadata.title || "")
          secondary: root.openPodcast
            ? Model.formatDate(modelData.publishedAt) + (modelData.duration ? "  ·  " + Model.formatTime(modelData.duration) : "")
              + (modelData.userProgress && modelData.userProgress.isFinished ? "  ·  Played"
                 : (modelData.userProgress && modelData.userProgress.progress > 0
                    ? "  ·  " + Math.round(modelData.userProgress.progress * 100) + "% played" : ""))
            : (modelData.media.metadata.authorName || (modelData.mediaType === "podcast" ? "Podcast" : ""))
              + (modelData.userProgress && modelData.userProgress.isFinished ? "  ·  Finished" : "")
          current: root.openPodcast
            ? (player.currentEpisode !== null && player.currentEpisode.id === modelData.id)
            : (player.currentItem !== null && player.currentItem.id === modelData.id)
          // Unplayed markers: an accent dot on never-started episodes, an
          // "N unplayed" pill on podcasts, a progress bar on anything
          // part-way through, and finished items dimmed.
          readonly property var prog: modelData.userProgress || null
          marker: root.openPodcast !== null && prog === null
          badge: (!root.openPodcast && modelData.mediaType === "podcast" && modelData.unplayedCount > 0)
            ? modelData.unplayedCount + " unplayed" : ""
          progressFraction: (prog && !prog.isFinished && prog.progress > 0) ? prog.progress : -1
          finished: prog !== null && prog.isFinished === true
          // Podcast shows have no finished state of their own; books and
          // episodes toggle on right-click.
          tooltip: (root.openPodcast || modelData.mediaType !== "podcast")
            ? (finished ? "Right-click or r / f to mark as not finished (restarts from 0:00)" : "Right-click or r / f to mark as finished")
            : ""
          onContextActivated: {
            if (root.openPodcast) root.toggleFinished(root.openPodcast, modelData)
            else if (modelData.mediaType !== "podcast") root.toggleFinished(modelData, null)
          }
          onActivated: {
            if (root.openPodcast) {
              root.markEpisodeStarted(root.openPodcast, modelData)
              player.playItem(root.openPodcast, modelData)
            } else {
              root.openItem(modelData)
            }
          }
        }
      }

      // Keeps the form and now-playing sections pinned to the top when the
      // list is hidden (settings view).
      Item { Layout.fillHeight: true; visible: root.onHome }
    }
  }

  component NowPlaying: ColumnLayout {
    id: np
    property bool large: false
    Layout.fillWidth: true
    spacing: Style.spacing.lg

    PanelSectionHeader { visible: !np.large; text: "NOW PLAYING"; foreground: root.fg; fontFamily: root.fontFamily }

    // Large (home) layout: big cover centered, title and author under it.
    ColumnLayout {
      visible: np.large && player.hasItem
      Layout.fillWidth: true
      spacing: Style.spacing.md
      Item {
        readonly property string src: player.currentItem ? (player.currentItem.coverUrl || "") : ""
        visible: src !== ""
        Layout.fillWidth: true
        implicitHeight: Style.space(240)
      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        width: Style.space(240)
        height: Style.space(240)
        readonly property string src: parent.src
        radius: Style.cornerRadius
        color: Style.hoverFillFor(root.fg, Color.accent)
        clip: true
        Image {
          anchors.fill: parent
          source: parent.src
          sourceSize.width: Style.space(240) * 2
          sourceSize.height: Style.space(240) * 2
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
        }
      }
      }
      Text {
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
        text: player.title
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        font.bold: true
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }
      Text {
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
        visible: player.subtitle !== ""
        text: player.subtitle
        color: root.mutedFg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
    }

    RowLayout {
      Layout.fillWidth: true
      visible: !np.large && player.hasItem
      spacing: Style.spacing.xl

      // Cover of what's playing (the podcast's cover for an episode).
      Rectangle {
        readonly property string src: player.currentItem ? (player.currentItem.coverUrl || "") : ""
        visible: src !== ""
        Layout.preferredWidth: Style.space(72)
        Layout.preferredHeight: Style.space(72)
        radius: Style.cornerRadius
        color: Style.hoverFillFor(root.fg, Color.accent)
        clip: true
        Image {
          anchors.fill: parent
          source: parent.src
          sourceSize.width: Style.space(72) * 2
          sourceSize.height: Style.space(72) * 2
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.xs
        Text {
          Layout.fillWidth: true
          text: player.title
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          elide: Text.ElideRight
        }
        Text {
          Layout.fillWidth: true
          visible: player.subtitle !== ""
          text: player.subtitle
          color: root.mutedFg
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }
    }

    PanelSlider {
      id: seekSlider
      Layout.fillWidth: true
      visible: player.hasItem
      bar: root.bar
      minimum: 0
      maximum: Math.max(1, player.duration)
      step: 1
      value: player.position
      onReleased: function(v) { player.seekTo(v) }
    }

    RowLayout {
      Layout.fillWidth: true
      visible: player.hasItem
      Text {
        text: Model.formatTime(seekSlider.dragging ? seekSlider.liveValue : player.position)
        color: root.mutedFg
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      Item { Layout.fillWidth: true }
      Text {
        text: player.loading ? "Loading..." : Model.formatTime(player.duration)
        color: root.mutedFg
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    RowLayout {
      Layout.fillWidth: true
      visible: player.hasItem
      spacing: Style.spacing.lg

      Item { visible: np.large; Layout.fillWidth: true }
      PanelActionButton { iconText: "󰑟"; tooltipText: "Back 30s (h)"; foreground: root.fg; fontSize: np.large ? Style.font.iconLarge * 1.4 : Style.font.icon; onClicked: player.skip(-30) }
      PanelActionButton {
        iconText: player.playing ? "󰏤" : "󰐊"
        tooltipText: player.playing ? "Pause (Space)" : "Play (Space)"
        foreground: root.fg
        fontSize: np.large ? Style.font.iconLarge * 2.2 : Style.font.iconLarge
        onClicked: player.togglePause()
      }
      PanelActionButton { iconText: "󰈑"; tooltipText: "Forward 30s (l)"; foreground: root.fg; fontSize: np.large ? Style.font.iconLarge * 1.4 : Style.font.icon; onClicked: player.skip(30) }

      Item { Layout.fillWidth: true }

      ButtonGroup {
        options: [
          { value: "0.8", label: "0.8x", tooltip: "Speed: [ slower, ] faster" },
          { value: "1", label: "1x", tooltip: "Speed: [ slower, ] faster" },
          { value: "1.25", label: "1.25x", tooltip: "Speed: [ slower, ] faster" },
          { value: "1.5", label: "1.5x", tooltip: "Speed: [ slower, ] faster" },
          { value: "2", label: "2x", tooltip: "Speed: [ slower, ] faster" }
        ]
        value: root.speed
        foreground: root.fg
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        focusable: false
        onChanged: function(v) { root.setSpeed(v) }
      }
    }

    Button {
      visible: player.chapters.length > 0
      tooltipText: "Show or hide chapters (c)"
      text: (root.chaptersOpen ? "Hide chapters" : "Chapters")
        + (player.currentChapterIndex >= 0
           ? "  ·  " + player.chapters[player.currentChapterIndex].title : "")
      foreground: root.fg
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      leftAlign: true
      Layout.fillWidth: true
      onClicked: root.chaptersOpen = !root.chaptersOpen
    }

    ListView {
      id: chapterList
      Layout.fillWidth: true
      Layout.preferredHeight: Math.min(contentHeight, Style.space(180))
      visible: root.chaptersOpen && player.chapters.length > 0
      clip: true
      model: player.chapters
      delegate: ListRow {
        width: chapterList.width
        primary: modelData.title
        secondary: Model.formatTime(modelData.start)
        current: index === player.currentChapterIndex
        onActivated: player.seekTo(modelData.start)
      }
    }

    Button {
      visible: player.currentEpisode !== null && (player.currentEpisode.description || "") !== ""
      text: root.notesOpen ? "Hide show notes" : "Show notes"
      foreground: root.fg
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      leftAlign: true
      Layout.fillWidth: true
      onClicked: root.notesOpen = !root.notesOpen
    }

    Flickable {
      id: notesView
      Layout.fillWidth: true
      Layout.preferredHeight: Math.min(notesText.implicitHeight, Style.space(200))
      visible: root.notesOpen && player.currentEpisode !== null
        && (player.currentEpisode.description || "") !== ""
      clip: true
      contentWidth: width
      contentHeight: notesText.implicitHeight
      boundsBehavior: Flickable.StopAtBounds
      Text {
        id: notesText
        width: notesView.width
        text: player.currentEpisode ? (player.currentEpisode.description || "") : ""
        wrapMode: Text.WordWrap
        color: root.mutedFg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    Text {
      Layout.fillWidth: true
      visible: player.errorText !== ""
      text: player.errorText
      wrapMode: Text.WordWrap
      color: Color.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    PanelSeparator { visible: !np.large; Layout.fillWidth: true; foreground: root.fg }
  }

  // One row style for library items, episodes and chapters: theme hover and
  // selected fills, the same shape Todoist's task rows use.
  component ListRow: Item {
    id: row
    property string glyph: ""
    property string primary: ""
    property string secondary: ""
    property bool current: false
    property bool marker: false
    property string badge: ""
    property real progressFraction: -1
    property bool finished: false
    property string cover: ""
    property string tooltip: ""
    property bool selected: false
    signal activated()
    signal contextActivated()

    readonly property real coverSize: Style.space(40)

    // Finished rows fade their cover and text but keep the check mark crisp.
    readonly property real contentOpacity: row.finished && !row.current ? 0.5 : 1

    implicitHeight: Math.max(Style.spacing.popupRowHeight,
      (row.cover !== "" ? row.coverSize : textColumn.implicitHeight) + Style.spacing.md * 2)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: row.current ? Style.selectedFillFor(root.fg, Color.accent)
        : ((mouse.containsMouse || row.selected) ? Style.hoverFillFor(root.fg, Color.accent) : "transparent")
    }

    // Keyboard selection: a thin accent bar on the left edge.
    Rectangle {
      visible: row.selected
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.topMargin: Style.spacing.xs
      anchors.bottomMargin: Style.spacing.xs
      width: Math.max(2, Style.space(3))
      radius: width / 2
      color: Color.accent
    }

    Rectangle {
      id: coverBox
      visible: row.cover !== ""
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      width: visible ? row.coverSize : 0
      height: row.coverSize
      radius: Style.cornerRadius
      color: Style.hoverFillFor(root.fg, Color.accent)
      clip: true
      opacity: row.contentOpacity
      Image {
        anchors.fill: parent
        source: row.cover
        sourceSize.width: row.coverSize * 2
        sourceSize.height: row.coverSize * 2
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
      }
    }

    Text {
      id: glyphText
      opacity: row.contentOpacity
      visible: row.glyph !== "" && row.cover === ""
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      width: visible ? Style.font.icon + Style.spacing.sm : 0
      text: row.glyph
      color: row.current ? Color.accent : root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
    }

    Rectangle {
      id: markerDot
      visible: row.marker
      anchors.left: glyphText.visible ? glyphText.right : parent.left
      anchors.leftMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(7)
      height: width
      radius: width / 2
      color: Color.accent
    }

    Text {
      id: finishedMark
      visible: row.finished
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      text: "󰗠"
      color: Color.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
    }

    Rectangle {
      id: badgePill
      visible: row.badge !== ""
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      width: badgeText.implicitWidth + Style.spacing.lg * 2
      height: badgeText.implicitHeight + Style.spacing.xs * 2
      radius: height / 2
      color: Style.selectedFillFor(root.fg, Color.accent)
      border.width: 1
      border.color: Color.accent

      Text {
        id: badgeText
        anchors.centerIn: parent
        text: row.badge
        color: Color.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    Column {
      id: textColumn
      opacity: row.contentOpacity
      anchors.left: markerDot.visible ? markerDot.right
        : (coverBox.visible ? coverBox.right : (glyphText.visible ? glyphText.right : parent.left))
      anchors.leftMargin: Style.spacing.lg
      anchors.right: badgePill.visible ? badgePill.left : (finishedMark.visible ? finishedMark.left : parent.right)
      anchors.rightMargin: Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xxs

      Text {
        width: parent.width
        text: row.primary
        color: row.current ? Color.accent : root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
      Text {
        width: parent.width
        visible: row.secondary !== ""
        text: row.secondary
        color: root.mutedFg
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    // Thin progress bar along the bottom edge for part-played items.
    Rectangle {
      visible: row.progressFraction > 0
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      anchors.leftMargin: Style.spacing.lg
      height: Math.max(2, Style.space(2))
      radius: height / 2
      width: (parent.width - Style.spacing.lg * 2) * Math.min(1, row.progressFraction)
      color: Color.accent
      opacity: 0.8
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) row.contextActivated()
        else row.activated()
      }
    }

    PanelToolTip {
      visible: mouse.containsMouse && row.tooltip !== ""
      text: row.tooltip
      fontFamily: root.fontFamily
    }
  }
}
