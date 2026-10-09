import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "goldbarth.arcula"
  ipcTarget: "goldbarth.arcula"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string collectScript: Qt.resolvedUrl("collect.py").toString().replace("file://", "")

  // Snapshot printed by collect.py. The last good one is kept when a refresh
  // fails, so a Toolbox update that moves a file degrades to stale data plus
  // a visible reason instead of an empty panel.
  property var tools: []
  property var projects: []
  property var toolbox: ({})
  property string errorText: ""
  property bool loaded: false

  // Tools whose installed build is behind the latest release. Only a hint:
  // updating stays with Toolbox itself.
  readonly property int updateCount: tools.filter(function(tool) { return !!tool.latestVersion }).length

  readonly property var tabs: [
    { value: "projects", label: "Projects" },
    { value: "tools", label: updateCount > 0 ? "Tools · " + updateCount : "Tools" }
  ]
  property string tab: "projects"
  property int cursorIndex: 0

  readonly property bool projectsTab: tab === "projects"
  readonly property string query: searchField.text.trim().toLowerCase()
  readonly property var filteredProjects: {
    if (query === "") return projects
    return projects.filter(function(project) {
      return String(project.name).toLowerCase().indexOf(root.query) >= 0
        || String(project.displayPath).toLowerCase().indexOf(root.query) >= 0
    })
  }
  readonly property var rows: projectsTab ? filteredProjects : tools

  readonly property string summary: count(projects.length, "project") + " · " + count(tools.length, "tool")
    + (updateCount > 0 ? " · " + count(updateCount, "update") : "")
  readonly property string emptyText: {
    if (!loaded || rows.length > 0) return ""
    if (!projectsTab) return "No JetBrains tools installed."
    return query !== "" ? "No projects match." : "No recent projects."
  }

  function count(n, noun) { return n + " " + noun + (n === 1 ? "" : "s") }
  function iconSource(path) { return path ? Util.fileUrl(String(path)) : "" }

  function refresh() {
    if (!collectProc.running) collectProc.running = true
  }

  // The release feed is the one thing that needs the network, so it runs
  // apart from the snapshot and only feeds it through a cache.
  function checkUpdates(force) {
    if (updateProc.running) return
    updateProc.command = ["python3", "-I", collectScript, "--check-updates"].concat(force ? ["--force"] : [])
    updateProc.running = true
  }

  function applySnapshot(raw) {
    var snapshot = null
    try { snapshot = JSON.parse(raw) } catch (e) { snapshot = null }
    if (!snapshot || typeof snapshot !== "object") {
      errorText = "Could not read JetBrains Toolbox data."
      return
    }
    tools = snapshot.tools || []
    projects = snapshot.projects || []
    toolbox = snapshot.toolbox || ({})
    errorText = (snapshot.errors || []).join("\n")
    loaded = true
  }

  // uwsm-app gives the IDE its own systemd scope, the way every other Omarchy
  // launcher does, instead of leaving it inside the shell's cgroup.
  function launch(argv) {
    Quickshell.execDetached(["uwsm-app", "--"].concat(argv))
    close()
  }

  function activate(index) {
    var row = rows[index]
    if (!row || !row.launchCommand) return
    launch(projectsTab ? [row.launchCommand, row.path] : [row.launchCommand])
  }

  function openToolbox() {
    if (toolbox.command) launch([toolbox.command])
  }

  // The search field owns the keyboard on Projects so typing filters right
  // away; Tools has nothing to type into, so the key catcher takes over there.
  function focusCurrent() {
    Qt.callLater(function() {
      if (!root.opened) return
      if (root.projectsTab) searchField.forceActiveFocus()
      else keyCatcher.forceActiveFocus()
    })
  }

  function selectTab(name) {
    tab = name
    pointerGate.reset()
    cursorIndex = 0
    panelFlick.contentY = 0
    focusCurrent()
  }

  function moveCursor(delta) {
    if (rows.length === 0) return
    pointerGate.reset()
    cursorIndex = Util.clamp(cursorIndex + delta, 0, rows.length - 1)
    var item = rowRepeater.itemAt(cursorIndex)
    if (!item) return
    var top = item.mapToItem(column, 0, 0).y
    var bottom = top + item.height
    if (top < panelFlick.contentY) panelFlick.contentY = top
    else if (bottom > panelFlick.contentY + panelFlick.height) panelFlick.contentY = bottom - panelFlick.height
  }

  onRowsChanged: {
    pointerGate.reset()
    if (cursorIndex >= rows.length) cursorIndex = Math.max(0, rows.length - 1)
  }
  onQueryChanged: {
    cursorIndex = 0
    panelFlick.contentY = 0
  }
  onOpenedChanged: if (opened) {
    searchField.clear()
    selectTab("projects")
    refresh()
  }

  Component.onCompleted: {
    refresh()
    checkUpdates(false)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: collectProc
    command: ["python3", "-I", root.collectScript]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applySnapshot(text) }
  }

  Process {
    id: updateProc
    onExited: root.refresh()
  }

  // The collector decides whether its cache is stale; this only gives it the
  // chance to, so the bar hint appears without the panel ever being opened.
  Timer {
    interval: 3600 * 1000
    running: true
    repeat: true
    onTriggered: root.checkUpdates(false)
  }

  // Rows appear, filter, and scroll under a pointer that is not moving. Only
  // real pointer travel may take the cursor from the keyboard, or Enter would
  // open whichever project happens to sit under a resting mouse.
  PointerMoveGate {
    id: pointerGate
    referenceItem: panelFlick
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // nf-md-toolbox
    text: String.fromCodePoint(0xF09AC)
    active: root.updateCount > 0
    activeColor: Color.accent
    tooltipText: root.updateCount > 0 ? root.count(root.updateCount, "update") + " available" : ""
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.openToolbox()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.projectsTab ? searchField : keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The catcher claims j/k/h/l/x before any descendant sees them, which
      // would make those letters untypeable in the search field.
      blocked: searchField.activeFocus

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.selectTab(dx > 0 ? "tools" : "projects")
        else root.moveCursor(dy)
      }
      onActivateRequested: root.activate(root.cursorIndex)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "/") root.selectTab("projects")
        else if (t === "r" || t === "R") root.checkUpdates(true)
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Hero ----------
          PanelHero {
            width: parent.width
            title: "Arcula"
            meta: root.loaded ? root.summary : ""
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: button.text
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // ---------- Tab switch ----------
          Row {
            id: tabSwitch
            width: parent.width
            spacing: Style.spacing.md

            readonly property real cellWidth: (width - spacing * (root.tabs.length - 1)) / root.tabs.length

            Repeater {
              model: root.tabs

              Button {
                required property var modelData

                width: tabSwitch.cellWidth
                text: modelData.label
                selected: root.tab === modelData.value
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.selectTab(modelData.value)
              }
            }
          }

          TextField {
            id: searchField
            visible: root.projectsTab
            width: parent.width
            foreground: root.foreground
            font.family: root.fontFamily
            placeholderText: "Search projects"

            Keys.onPressed: function(event) {
              var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
              if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_J)) {
                root.moveCursor(1)
              } else if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_K)) {
                root.moveCursor(-1)
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.activate(root.cursorIndex)
              } else if (event.key === Qt.Key_Escape) {
                if (text !== "") clear()
                else root.close()
              } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                root.switchPanel((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
              } else if (event.key === Qt.Key_Right && text === "") {
                // Nothing to move the text cursor through, so the arrow is
                // free to reach the Tools tab without leaving the keyboard.
                root.selectTab("tools")
              } else {
                return
              }
              event.accepted = true
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.errorText !== ""
            width: parent.width
            text: root.errorText
            color: root.bar ? root.bar.urgent : Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: root.emptyText !== ""
            width: parent.width
            topPadding: Style.space(12)
            bottomPadding: Style.space(12)
            text: root.emptyText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }

          // ---------- Projects / tools ----------
          Column {
            visible: root.rows.length > 0
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              id: rowRepeater
              model: root.rows

              EntryRow {}
            }
          }

          PanelSeparator {
            visible: toolboxButton.visible
            foreground: root.foreground
          }

          Button {
            id: toolboxButton
            visible: !!root.toolbox.command
            width: parent.width
            text: "Open Toolbox"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.openToolbox()
          }
        }
      }
    }
  }

  // One row for either list: a project (initials tile, IDE mark, path) or a
  // tool (IDE icon, version). The shape follows the record, not the selected
  // tab, so a row never reads fields its record does not have mid-switch.
  component EntryRow: Rectangle {
    id: entry

    required property var modelData
    required property int index

    readonly property bool isProject: modelData.path !== undefined
    readonly property string pendingVersion: modelData.latestVersion || ""
    readonly property real markSize: Style.space(32)
    readonly property real inset: Style.space(8)

    width: parent ? parent.width : 0
    implicitHeight: Math.max(markSize, labels.implicitHeight) + inset * 2
    radius: Style.cornerRadius
    color: rowMouse.pressed ? Style.pressedFillFor(root.foreground, Color.accent)
      : root.cursorIndex === index ? Style.hoverFillFor(root.foreground, Color.accent)
      : "transparent"

    Item {
      id: mark
      width: entry.markSize
      height: entry.markSize
      anchors.left: parent.left
      anchors.leftMargin: entry.inset
      anchors.verticalCenter: parent.verticalCenter

      Rectangle {
        anchors.fill: parent
        visible: entry.isProject
        radius: Math.min(Style.cornerRadius, Style.space(6))
        color: Util.alpha(root.foreground, 0.14)

        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          text: entry.modelData.initials || ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
      }

      Image {
        anchors.fill: parent
        visible: !entry.isProject
        source: entry.isProject ? "" : root.iconSource(entry.modelData.iconPath)
        sourceSize.width: entry.markSize * 2
        sourceSize.height: entry.markSize * 2
        fillMode: Image.PreserveAspectFit
      }
    }

    Column {
      id: labels
      anchors.left: mark.right
      anchors.leftMargin: Style.space(12)
      anchors.right: openMark.visible ? openMark.left : parent.right
      anchors.rightMargin: entry.inset
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: entry.modelData.name || ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }

      Row {
        width: parent.width
        spacing: Style.space(6)

        Image {
          id: ideMark
          visible: entry.isProject
          width: Style.font.body
          height: Style.font.body
          anchors.verticalCenter: parent.verticalCenter
          source: entry.isProject ? root.iconSource(entry.modelData.iconPath) : ""
          sourceSize.width: Style.font.body * 2
          sourceSize.height: Style.font.body * 2
          fillMode: Image.PreserveAspectFit
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width - (ideMark.visible ? ideMark.width + parent.spacing : 0)
          text: (entry.isProject ? entry.modelData.displayPath
            : entry.pendingVersion !== "" ? entry.modelData.version + " → " + entry.pendingVersion
            : entry.modelData.version) || ""
          color: entry.pendingVersion !== "" ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }
      }
    }

    // Marks a project its IDE currently has open.
    Rectangle {
      id: openMark
      visible: entry.modelData.opened === true
      width: Style.space(6)
      height: Style.space(6)
      radius: width / 2
      anchors.right: parent.right
      anchors.rightMargin: entry.inset
      anchors.verticalCenter: parent.verticalCenter
      color: root.foreground
      opacity: 0.6
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      onPositionChanged: function(mouse) {
        if (pointerGate.moved(entry, mouse)) root.cursorIndex = entry.index
      }
      onClicked: root.activate(entry.index)
    }
  }
}
