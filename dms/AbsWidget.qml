import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "Model.js" as Model

// DankMaterialShell version of the Audiobookshelf plugin. The shell-independent
// parts (Player/MpvPlayer/PollTimer/Model.js and the Python backend) are
// shared with the Omarchy plugin at the repo root (tools/sync-dms.sh).
//
// DMS rebuilds popoutContent every time the popout opens, so all state (the
// player, the library, the login) lives here on the PluginComponent root and
// the popout only renders it.
PluginComponent {
  id: root

  layerNamespacePlugin: "abs-player"
  popoutWidth: 560

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")
  function backend(args) {
    return ["python3", root.pluginDir + "/scripts/abs_backend.py"].concat(args)
  }

  // ---- State ---------------------------------------------------------------
  property bool configured: false
  property string serverUrl: ""
  property string bookLibId: ""
  property string podcastLibId: ""
  property var libraries: []
  readonly property bool hasBooks: bookLibId !== ""
  readonly property bool hasPodcasts: podcastLibId !== ""
  readonly property string defaultType: hasBooks || !hasPodcasts ? "book" : "podcast"

  property var allItems: []
  property bool itemsLoading: false
  property string listError: ""
  property string filterText: ""
  property string filterType: "book"  // "book" | "podcast" | "" (search across both)
  property bool browsing: false
  property bool settingsView: false
  property var openPodcast: null
  property var episodes: []
  property bool episodesLoading: false
  property bool chaptersOpen: false
  property bool notesOpen: false
  property real speed: 1

  property string setupError: ""
  property bool setupBusy: false
  property string pendingPassword: ""
  property bool confirmDisconnect: false

  readonly property bool onHome: !settingsView && openPodcast === null && !browsing
  readonly property var visibleItems: allItems.filter(function(it) {
    var matchesType = filterType === "" || it.mediaType === filterType
    var needle = filterText.toLowerCase()
    var title = (it.media.metadata.title || "").toLowerCase()
    var author = (it.media.metadata.authorName || "").toLowerCase()
    return matchesType && (needle === "" || title.indexOf(needle) !== -1 || author.indexOf(needle) !== -1)
  })
  readonly property var typeOptions: {
    var opts = []
    if (hasBooks) opts.push("book")
    if (hasPodcasts) opts.push("podcast")
    return opts
  }

  // ---- Actions -------------------------------------------------------------
  function refresh() {
    if (!configured || fetchItems.running) return
    itemsLoading = true
    listError = ""
    fetchItems.running = true
  }

  function goHome() {
    if (configured) settingsView = false
    openPodcast = null
    episodes = []
    filterType = defaultType
    filterText = ""
    browsing = false
  }

  function goBack() {
    if (settingsView && configured) { settingsView = false; return true }
    if (openPodcast) { openPodcast = null; episodes = []; return true }
    if (browsing) { goHome(); return true }
    return false
  }

  function browseType(type) {
    settingsView = false
    openPodcast = null
    filterType = type
    browsing = true
  }

  function setSearch(text) {
    filterText = text
    if (text !== "" && !browsing) {
      filterType = ""
      browsing = true
    }
  }

  function openItem(item) {
    if (item.mediaType === "podcast") {
      openPodcast = item
      episodes = []
      episodesLoading = true
      fetchEpisodes.command = backend(["list-episodes", item.id])
      fetchEpisodes.running = true
    } else {
      player.playItem(item, null)
    }
  }

  function decrementUnplayed(podcastId) {
    allItems = allItems.map(function(it) {
      if (it.id !== podcastId || !(it.unplayedCount > 0)) return it
      var copy = JSON.parse(JSON.stringify(it))
      copy.unplayedCount = it.unplayedCount - 1
      return copy
    })
  }

  function playEpisode(episode) {
    if (!episode.userProgress) {
      decrementUnplayed(openPodcast.id)
      episodes = episodes.map(function(ep) {
        if (ep.id !== episode.id) return ep
        var copy = JSON.parse(JSON.stringify(ep))
        copy.userProgress = { progress: 0, isFinished: false }
        return copy
      })
    }
    player.playItem(openPodcast, episode)
  }

  // Right-click a book or episode to flip its finished state. ABS resets the
  // position to 0 when an item is marked not finished.
  function toggleFinished(item, episode) {
    var prog = (episode ? episode.userProgress : item.userProgress) || null
    var finished = !(prog && prog.isFinished)
    var key = episode ? item.id + "/" + episode.id : item.id
    finishedProcess.command = backend(["set-finished", key, finished ? "true" : "false"])
    finishedProcess.running = true
    var patch = function(obj) {
      var copy = JSON.parse(JSON.stringify(obj))
      var p = copy.userProgress || { progress: 0 }
      p.isFinished = finished
      p.progress = finished ? 1 : 0
      copy.userProgress = p
      return copy
    }
    if (episode) {
      if (!episode.userProgress) decrementUnplayed(item.id)
      episodes = episodes.map(function(ep) { return ep.id === episode.id ? patch(ep) : ep })
    } else {
      allItems = allItems.map(function(it) { return it.id === item.id ? patch(it) : it })
    }
  }

  function chooseLibrary(mediaType, id) {
    if (mediaType === "book") bookLibId = id
    else podcastLibId = id
    setLibraries.command = backend(["set-libraries", bookLibId, podcastLibId])
    setLibraries.running = true
  }

  function librariesOfType(mediaType) {
    return libraries.filter(function(l) { return l.mediaType === mediaType })
  }

  onDefaultTypeChanged: if (!browsing) filterType = defaultType
  onSettingsViewChanged: if (settingsView && configured) listLibraries.running = true

  pillRightClickAction: () => player.togglePause()

  Component.onCompleted: checkConfigured.running = true

  // ---- Player + background work --------------------------------------------
  Player { id: player }

  PollTimer {
    id: poller
    pollMinutes: 20
  }

  IpcHandler {
    target: "absPlayer"
    function toggle(): void { root.triggerPopout() }
    function playPause(): void { player.togglePause() }
    function browse(type: string): void { root.browseType(type) }
    function search(query: string): void { root.setSearch(query) }
    function home(): void { root.goHome() }
  }

  // ---- Backend processes ---------------------------------------------------
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
        else root.refresh()
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
    id: finishedProcess
    stdout: StdioCollector {
      onStreamFinished: {
        try { var r = JSON.parse(text); if (r.error) root.listError = r.error } catch (e) {}
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
        loginProcess.running = true
      }
    }
  }

  property string loginUrl: ""
  // The popout clears its password field when this fires.
  signal loginSucceeded()
  property string loginUser: ""

  Process {
    id: loginProcess
    // stdin stays enabled for the life of this Process (Quickshell never
    // re-enables it once closed); the backend reads one line per attempt.
    stdinEnabled: true
    command: root.backend(["login", root.loginUrl, root.loginUser])
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
            root.serverUrl = result.baseUrl || root.loginUrl.replace(/\/+$/, "")
            root.libraries = result.libraries || []
            root.bookLibId = result.libraryId || ""
            root.podcastLibId = result.podcastLibraryId || ""
            root.configured = true
            root.settingsView = false
            root.allItems = []
            root.loginSucceeded()
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

  Process {
    id: listLibraries
    command: root.backend(["list-libraries"])
    stdout: StdioCollector {
      onStreamFinished: {
        try { var r = JSON.parse(text); if (!r.error) root.libraries = r.libraries || [] } catch (e) {}
      }
    }
  }

  Process {
    id: setLibraries
    stdout: StdioCollector {
      onStreamFinished: { root.allItems = []; root.refresh() }
    }
  }

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

  Timer {
    id: confirmTimer
    interval: 4000
    onTriggered: root.confirmDisconnect = false
  }

  // ---- Bar pill --------------------------------------------------------------
  // New episodes tint the icon with the theme's primary color.
  horizontalBarPill: Component {
    DankIcon {
      name: "headphones"
      size: root.iconSize
      color: poller.unreadCount > 0 ? Theme.primary : Theme.widgetIconColor
      opacity: player.playing ? 1 : 0.85
    }
  }

  verticalBarPill: Component {
    DankIcon {
      name: "headphones"
      size: root.iconSize
      color: poller.unreadCount > 0 ? Theme.primary : Theme.widgetIconColor
    }
  }

  // ---- Popout ----------------------------------------------------------------
  popoutContent: Component {
    PopoutComponent {
      id: pop

      Component.onCompleted: poller.unreadCount = 0

      Item {
        id: bodyHost
        width: parent.width
        // Home and settings size to their content; lists get a fixed height.
        readonly property bool compact: root.onHome || root.settingsView
        implicitHeight: compact ? body.implicitHeight + Theme.spacingM : 720

        ColumnLayout {
          id: body
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: bodyHost.compact ? implicitHeight : bodyHost.height
          spacing: Theme.spacingM

          // Header
          RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingS

            DankActionButton {
              visible: !root.onHome
              iconName: "arrow_back"
              tooltipText: "Back"
              onClicked: root.goBack()
            }

            StyledText {
              Layout.fillWidth: true
              text: root.settingsView ? "Connect to Audiobookshelf"
                : root.openPodcast ? root.openPodcast.media.metadata.title
                : root.browsing ? (root.filterType === "podcast" ? "Podcasts" : root.filterType === "book" ? "Books" : "Search")
                : ""
              font.pixelSize: Theme.fontSizeLarge
              font.weight: Font.Bold
              color: Theme.surfaceText
              elide: Text.ElideRight
            }

            DankActionButton {
              visible: root.configured
              iconName: "home"
              tooltipText: "Library home"
              onClicked: root.goHome()
            }
            DankActionButton {
              visible: root.configured && !root.settingsView
              iconName: "refresh"
              tooltipText: "Refresh library"
              onClicked: root.refresh()
            }
            DankActionButton {
              visible: root.configured
              iconName: "settings"
              tooltipText: "Connection settings"
              onClicked: root.settingsView = !root.settingsView
            }
            DankActionButton {
              iconName: "close"
              tooltipText: "Close"
              onClicked: pop.closePopout && pop.closePopout()
            }
          }

          // ---- Connection form ---------------------------------------------
          ColumnLayout {
            visible: root.settingsView
            Layout.fillWidth: true
            spacing: Theme.spacingS

            StyledText {
              Layout.fillWidth: true
              wrapMode: Text.WordWrap
              text: "Your password goes straight to the server to get a login token, which is stored in the system keyring. It's never saved to a file."
              color: Theme.surfaceVariantText
              font.pixelSize: Theme.fontSizeSmall
            }
            DankTextField { id: urlField; Layout.fillWidth: true; placeholderText: "Server URL, e.g. http://localhost:13378"; text: root.serverUrl }
            DankTextField { id: userField; Layout.fillWidth: true; placeholderText: "Username" }
            DankTextField { id: passField; Layout.fillWidth: true; placeholderText: "Password"; echoMode: TextInput.Password; showPasswordToggle: true }
            Connections { target: root; function onLoginSucceeded() { passField.text = "" } }

            StyledText {
              Layout.fillWidth: true
              visible: root.setupError !== ""
              text: root.setupError
              wrapMode: Text.WordWrap
              color: Theme.error
              font.pixelSize: Theme.fontSizeSmall
            }

            DankButton {
              text: root.setupBusy ? "Connecting..." : "Connect"
              iconName: "login"
              onClicked: {
                if (root.setupBusy) return
                root.setupError = ""
                root.setupBusy = true
                root.loginUrl = urlField.text.trim()
                root.loginUser = userField.text.trim()
                root.pendingPassword = passField.text
                mpvCheck.running = true
              }
            }

            // Library pickers only when there's a choice to make.
            Repeater {
              model: ["book", "podcast"]
              delegate: ColumnLayout {
                required property string modelData
                readonly property var libs: root.librariesOfType(modelData)
                visible: root.configured && libs.length > 1
                Layout.fillWidth: true
                StyledText {
                  text: modelData === "book" ? "Books library" : "Podcasts library"
                  color: Theme.surfaceVariantText
                  font.pixelSize: Theme.fontSizeSmall
                }
                DankButtonGroup {
                  model: libs.map(function(l) { return l.name })
                  currentIndex: libs.findIndex(function(l) { return l.id === (modelData === "book" ? root.bookLibId : root.podcastLibId) })
                  onSelectionChanged: function(index, selected) { if (selected) root.chooseLibrary(modelData, libs[index].id) }
                }
              }
            }

            StyledText {
              visible: root.configured
              Layout.fillWidth: true
              Layout.topMargin: Theme.spacingM
              wrapMode: Text.WordWrap
              text: "Disconnect removes this server's login and settings from this computer. Your Audiobookshelf account and progress stay on the server."
              color: Theme.surfaceVariantText
              font.pixelSize: Theme.fontSizeSmall
            }
            DankButton {
              visible: root.configured
              text: root.confirmDisconnect ? "Click again to disconnect" : "Disconnect"
              iconName: "logout"
              backgroundColor: root.confirmDisconnect ? Theme.error : Theme.surfaceContainerHigh
              textColor: root.confirmDisconnect ? Theme.primaryText : Theme.surfaceText
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
          }

          // ---- Home: big player, or the logo when nothing is loaded ---------
          NowPlaying {
            Layout.fillWidth: true
            large: true
            visible: root.onHome && (player.hasItem || player.errorText !== "")
          }

          Column {
            visible: root.onHome && !player.hasItem && player.errorText === ""
            Layout.fillWidth: true
            Layout.topMargin: Theme.spacingL
            spacing: Theme.spacingS
            Image {
              anchors.horizontalCenter: parent.horizontalCenter
              source: root.serverUrl !== "" ? root.serverUrl + "/icon.svg" : ""
              sourceSize.width: 128
              sourceSize.height: 128
              width: 128
              height: 128
              fillMode: Image.PreserveAspectFit
              asynchronous: true
            }
            StyledText {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "Audiobookshelf"
              font.pixelSize: Theme.fontSizeXLarge
              font.weight: Font.Bold
              color: Theme.surfaceText
            }
            StyledText {
              anchors.horizontalCenter: parent.horizontalCenter
              visible: root.serverUrl !== ""
              text: root.serverUrl
              font.pixelSize: Theme.fontSizeSmall
              color: urlMouse.containsMouse ? Theme.primary : Theme.surfaceVariantText
              MouseArea {
                id: urlMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Qt.openUrlExternally(root.serverUrl)
              }
            }
          }

          // ---- Compact player while browsing -------------------------------
          NowPlaying {
            Layout.fillWidth: true
            large: false
            visible: !root.settingsView && !root.onHome && (player.hasItem || player.errorText !== "")
          }

          // ---- Search + type buttons ---------------------------------------
          RowLayout {
            visible: root.configured && !root.settingsView && root.openPodcast === null
            Layout.fillWidth: true
            spacing: Theme.spacingS

            DankTextField {
              id: searchField
              Layout.fillWidth: true
              placeholderText: "Search title or author"
              leftIconName: "search"
              showClearButton: true
              text: root.filterText
              onTextEdited: root.setSearch(text)
            }

            Repeater {
              model: root.typeOptions
              delegate: DankButton {
                required property string modelData
                text: modelData === "book" ? "Books" : "Podcasts"
                iconName: modelData === "book" ? "book_2" : "podcasts"
                buttonHeight: 36
                backgroundColor: root.browsing && root.filterType === modelData ? Theme.primary : Theme.surfaceContainerHigh
                textColor: root.browsing && root.filterType === modelData ? Theme.primaryText : Theme.surfaceText
                onClicked: root.browseType(modelData)
              }
            }
          }

          StyledText {
            Layout.fillWidth: true
            visible: !root.settingsView && !root.onHome && (root.listError !== "" || root.itemsLoading || root.episodesLoading
              || (root.openPodcast === null && root.visibleItems.length === 0))
            text: root.listError !== "" ? root.listError
              : (root.itemsLoading || root.episodesLoading) ? "Loading..."
              : (root.allItems.length === 0 ? "Nothing in your libraries yet." : "No matches.")
            color: root.listError !== "" ? Theme.error : Theme.surfaceVariantText
            wrapMode: Text.WordWrap
            font.pixelSize: Theme.fontSizeSmall
          }

          // ---- Library / episode list ---------------------------------------
          DankListView {
            id: itemList
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !root.settingsView && !root.onHome
            clip: true
            spacing: Theme.spacingXS
            model: root.openPodcast ? root.episodes : root.visibleItems
            delegate: ListRow {
              width: itemList.width
              readonly property var prog: modelData.userProgress || null
              cover: root.openPodcast ? "" : (modelData.coverUrl || "")
              icon: root.openPodcast ? "graphic_eq" : (modelData.mediaType === "podcast" ? "podcasts" : "book_2")
              primary: root.openPodcast ? modelData.title : (modelData.media.metadata.title || "")
              secondary: root.openPodcast
                ? Model.formatDate(modelData.publishedAt) + (modelData.duration ? "  ·  " + Model.formatTime(modelData.duration) : "")
                  + (prog && prog.isFinished ? "  ·  Played" : (prog && prog.progress > 0 ? "  ·  " + Math.round(prog.progress * 100) + "% played" : ""))
                : (modelData.media.metadata.authorName || (modelData.mediaType === "podcast" ? "Podcast" : ""))
                  + (prog && prog.isFinished ? "  ·  Finished" : "")
              current: root.openPodcast
                ? (player.currentEpisode !== null && player.currentEpisode.id === modelData.id)
                : (player.currentItem !== null && player.currentItem.id === modelData.id)
              marker: root.openPodcast !== null && prog === null
              badge: (!root.openPodcast && modelData.mediaType === "podcast" && modelData.unplayedCount > 0)
                ? modelData.unplayedCount + " unplayed" : ""
              progressFraction: (prog && !prog.isFinished && prog.progress > 0) ? prog.progress : -1
              finished: prog !== null && prog.isFinished === true
              tooltip: (root.openPodcast || modelData.mediaType !== "podcast")
                ? (finished ? "Right-click to mark as not finished (restarts from 0:00)" : "Right-click to mark as finished")
                : ""
              onActivated: root.openPodcast ? root.playEpisode(modelData) : root.openItem(modelData)
              onContextActivated: {
                if (root.openPodcast) root.toggleFinished(root.openPodcast, modelData)
                else if (modelData.mediaType !== "podcast") root.toggleFinished(modelData, null)
              }
            }
          }
        }
      }
    }
  }

  // ---- Now playing card (large on home, compact while browsing) -----------
  component NowPlaying: ColumnLayout {
    id: np
    property bool large: false
    spacing: Theme.spacingS

    readonly property string coverSrc: player.currentItem ? (player.currentItem.coverUrl || "") : ""

    // Large: cover centered, title and author below.
    Item {
      visible: np.large && player.hasItem && np.coverSrc !== ""
      Layout.fillWidth: true
      implicitHeight: 220
      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        width: 220
        height: 220
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh
        clip: true
        Image {
          anchors.fill: parent
          source: np.coverSrc
          sourceSize.width: 440
          sourceSize.height: 440
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
        }
      }
    }

    RowLayout {
      visible: player.hasItem
      Layout.fillWidth: true
      spacing: Theme.spacingM
      Rectangle {
        visible: !np.large && np.coverSrc !== ""
        Layout.preferredWidth: 56
        Layout.preferredHeight: 56
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh
        clip: true
        Image {
          anchors.fill: parent
          source: np.coverSrc
          sourceSize.width: 112
          sourceSize.height: 112
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
        }
      }
      ColumnLayout {
        Layout.fillWidth: true
        spacing: 2
        StyledText {
          Layout.fillWidth: true
          horizontalAlignment: np.large ? Text.AlignHCenter : Text.AlignLeft
          text: player.title
          font.pixelSize: np.large ? Theme.fontSizeLarge : Theme.fontSizeMedium
          font.weight: Font.Bold
          color: Theme.surfaceText
          elide: Text.ElideRight
        }
        StyledText {
          Layout.fillWidth: true
          visible: player.subtitle !== ""
          horizontalAlignment: np.large ? Text.AlignHCenter : Text.AlignLeft
          text: player.subtitle
          font.pixelSize: Theme.fontSizeSmall
          color: Theme.surfaceVariantText
          elide: Text.ElideRight
        }
      }
    }

    DankSlider {
      id: seek
      visible: player.hasItem
      Layout.fillWidth: true
      minimum: 0
      maximum: Math.max(1, Math.round(player.duration))
      value: Math.round(player.position)
      showValue: false
      wheelEnabled: false
      onSliderDragFinished: function(v) { player.seekTo(v) }
    }

    RowLayout {
      visible: player.hasItem
      Layout.fillWidth: true
      StyledText {
        text: Model.formatTime(player.position)
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
      }
      Item { Layout.fillWidth: true }
      StyledText {
        text: player.loading ? "Loading..." : Model.formatTime(player.duration)
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
      }
    }

    RowLayout {
      visible: player.hasItem
      Layout.fillWidth: true
      spacing: Theme.spacingS
      Item { visible: np.large; Layout.fillWidth: true }
      DankActionButton { iconName: "replay_30"; buttonSize: np.large ? 44 : 32; iconSize: np.large ? 28 : 20; tooltipText: "Back 30s"; onClicked: player.skip(-30) }
      DankActionButton {
        iconName: player.playing ? "pause" : "play_arrow"
        buttonSize: np.large ? 60 : 40
        iconSize: np.large ? 40 : 26
        iconColor: Theme.primary
        tooltipText: player.playing ? "Pause" : "Play"
        onClicked: player.togglePause()
      }
      DankActionButton { iconName: "forward_30"; buttonSize: np.large ? 44 : 32; iconSize: np.large ? 28 : 20; tooltipText: "Forward 30s"; onClicked: player.skip(30) }
      Item { Layout.fillWidth: true }
      // The group doesn't move its own highlight, so currentIndex is bound to
      // root.speed (which also survives the popout being rebuilt).
      DankButtonGroup {
        readonly property var speeds: [0.8, 1, 1.25, 1.5, 2]
        size: "small"
        model: ["0.8x", "1x", "1.25x", "1.5x", "2x"]
        currentIndex: speeds.indexOf(root.speed)
        onSelectionChanged: function(index, selected) {
          if (!selected) return
          root.speed = speeds[index]
          player.mpv.setSpeed(root.speed)
        }
      }
    }

    DankButton {
      visible: player.chapters.length > 0
      Layout.fillWidth: true
      iconName: "list"
      buttonHeight: 32
      backgroundColor: Theme.surfaceContainerHigh
      textColor: Theme.surfaceText
      text: (root.chaptersOpen ? "Hide chapters" : "Chapters")
        + (player.currentChapterIndex >= 0 ? "  ·  " + player.chapters[player.currentChapterIndex].title : "")
      onClicked: root.chaptersOpen = !root.chaptersOpen
    }

    DankListView {
      id: chapterList
      visible: root.chaptersOpen && player.chapters.length > 0
      Layout.fillWidth: true
      Layout.preferredHeight: Math.min(contentHeight, 180)
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

    DankButton {
      visible: player.currentEpisode !== null && (player.currentEpisode.description || "") !== ""
      Layout.fillWidth: true
      iconName: "description"
      buttonHeight: 32
      backgroundColor: Theme.surfaceContainerHigh
      textColor: Theme.surfaceText
      text: root.notesOpen ? "Hide show notes" : "Show notes"
      onClicked: root.notesOpen = !root.notesOpen
    }

    Flickable {
      id: notesView
      visible: root.notesOpen && player.currentEpisode !== null && (player.currentEpisode.description || "") !== ""
      Layout.fillWidth: true
      Layout.preferredHeight: Math.min(notesText.implicitHeight, 200)
      clip: true
      contentWidth: width
      contentHeight: notesText.implicitHeight
      StyledText {
        id: notesText
        width: notesView.width
        text: player.currentEpisode ? (player.currentEpisode.description || "") : ""
        wrapMode: Text.WordWrap
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
      }
    }

    StyledText {
      Layout.fillWidth: true
      visible: player.errorText !== ""
      text: player.errorText
      wrapMode: Text.WordWrap
      font.pixelSize: Theme.fontSizeSmall
      color: Theme.error
    }
  }

  // ---- One row style for library items, episodes and chapters -------------
  component ListRow: Item {
    id: row
    property string cover: ""
    property string icon: ""
    property string primary: ""
    property string secondary: ""
    property string badge: ""
    property string tooltip: ""
    property bool current: false
    property bool marker: false
    property bool finished: false
    property real progressFraction: -1
    signal activated()
    signal contextActivated()

    readonly property real contentOpacity: finished && !current ? 0.5 : 1
    implicitHeight: Math.max(44, (cover !== "" ? 48 : textCol.implicitHeight) + Theme.spacingS * 2)

    StyledRect {
      anchors.fill: parent
      radius: Theme.cornerRadius
      color: row.current ? Theme.primarySelected
        : (mouse.containsMouse ? Theme.surfaceHover : "transparent")
    }

    Rectangle {
      id: coverBox
      visible: row.cover !== ""
      anchors.left: parent.left
      anchors.leftMargin: Theme.spacingS
      anchors.verticalCenter: parent.verticalCenter
      width: visible ? 48 : 0
      height: 48
      radius: Theme.cornerRadius
      color: Theme.surfaceContainerHigh
      clip: true
      opacity: row.contentOpacity
      Image {
        anchors.fill: parent
        source: row.cover
        sourceSize.width: 96
        sourceSize.height: 96
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
      }
    }

    DankIcon {
      id: glyph
      visible: row.cover === "" && row.icon !== ""
      anchors.left: parent.left
      anchors.leftMargin: Theme.spacingM
      anchors.verticalCenter: parent.verticalCenter
      name: row.icon
      size: Theme.iconSize
      color: row.current ? Theme.primary : Theme.surfaceText
      opacity: row.contentOpacity
    }

    Rectangle {
      id: markerDot
      visible: row.marker
      anchors.left: glyph.visible ? glyph.right : parent.left
      anchors.leftMargin: Theme.spacingS
      anchors.verticalCenter: parent.verticalCenter
      width: 8
      height: 8
      radius: 4
      color: Theme.primary
    }

    DankIcon {
      id: finishedMark
      visible: row.finished
      anchors.right: parent.right
      anchors.rightMargin: Theme.spacingM
      anchors.verticalCenter: parent.verticalCenter
      name: "check_circle"
      filled: true
      size: Theme.iconSize - 2
      color: Theme.primary
    }

    StyledRect {
      id: badgePill
      visible: row.badge !== ""
      anchors.right: parent.right
      anchors.rightMargin: Theme.spacingM
      anchors.verticalCenter: parent.verticalCenter
      width: badgeText.implicitWidth + Theme.spacingM * 2
      height: badgeText.implicitHeight + Theme.spacingXS * 2
      radius: height / 2
      color: Theme.primaryContainer
      StyledText {
        id: badgeText
        anchors.centerIn: parent
        text: row.badge
        font.pixelSize: Theme.fontSizeSmall
        font.weight: Font.Bold
        color: Theme.primary
      }
    }

    Column {
      id: textCol
      opacity: row.contentOpacity
      anchors.left: markerDot.visible ? markerDot.right
        : coverBox.visible ? coverBox.right : glyph.visible ? glyph.right : parent.left
      anchors.leftMargin: Theme.spacingM
      anchors.right: badgePill.visible ? badgePill.left : finishedMark.visible ? finishedMark.left : parent.right
      anchors.rightMargin: Theme.spacingM
      anchors.verticalCenter: parent.verticalCenter
      spacing: 2
      StyledText {
        width: parent.width
        text: row.primary
        font.pixelSize: Theme.fontSizeMedium
        color: row.current ? Theme.primary : Theme.surfaceText
        elide: Text.ElideRight
      }
      StyledText {
        width: parent.width
        visible: row.secondary !== ""
        text: row.secondary
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        elide: Text.ElideRight
      }
    }

    Rectangle {
      visible: row.progressFraction > 0
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      anchors.leftMargin: Theme.spacingS
      height: 3
      radius: 1.5
      width: (parent.width - Theme.spacingS * 2) * Math.min(1, row.progressFraction)
      color: Theme.primary
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: function(m) {
        if (m.button === Qt.RightButton) row.contextActivated()
        else row.activated()
      }
    }

    DankTooltipV2 {
      id: tip
    }
    Timer {
      interval: 600
      running: mouse.containsMouse && row.tooltip !== ""
      onTriggered: tip.show(row.tooltip, row, 0, 0, "top")
    }
    Connections {
      target: mouse
      function onContainsMouseChanged() { if (!mouse.containsMouse) tip.hide() }
    }
  }
}
