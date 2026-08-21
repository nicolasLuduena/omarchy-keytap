import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Keytap — on-screen keypress visualizer.
//
// Every chord you press leaves a themed bubble in a small rolling cluster:
// the newest sits at the right end, each bubble lingers for `duration`,
// then slowly dissolves individually. While a chord is still held, its
// bubble updates live (Super -> Super+Shift -> Super+Shift+T).
//
// Key events come from the bundled Python collector (`keytap-collector`),
// which reads evdev devices directly and emits one JSON line per state
// change:
//
//   {"seq": 3, "combo": ["Ctrl", "Shift", "T"]}
//
// An empty combo array means every key was released -> the active bubble
// finalizes into the history row and starts its linger timer.
//
// The cluster can be repositioned: enter drag mode via the bar widget's
// right click or `omarchy-shell keytap drag`, drag it anywhere, and the
// position persists to the shared state file.
Item {
  id: root

  // Injected by the shell's panel loader when present.
  property var shell: null
  property var manifest: null

  // Panel contract: opened == visualizer enabled.
  property bool opened: true

  // Settings, persisted to the shared state file.
  property int duration: 3200
  property int marginBottom: 110
  property int maxEntries: 5

  // Free position of the cluster center in window coordinates. -1 = unset,
  // fall back to the bottom-center default until first drag.
  property real posX: -1
  property real posY: -1
  readonly property bool hasStoredPosition: posX >= 0 && posY >= 0
  property bool dragMode: false

  // Finalized bubbles: [{id, cells}]. The active (still-held) chord renders
  // separately so history delegates never mutate after creation.
  property var history: []
  property var activeCells: []
  readonly property bool hasActive: activeCells.length > 0
  property int nextEntryId: 1

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: home + "/.local/state/batman.keytap"
  readonly property string statePath: stateDir + "/state.json"

  readonly property string sourceDir: manifest && manifest.__sourceDir ? String(manifest.__sourceDir) : ""
  readonly property string collectorPath: {
    if (root.sourceDir !== "") return root.sourceDir + "/keytap-collector"
    var url = Qt.resolvedUrl("keytap-collector").toString()
    return url.replace(/^file:\/\//, "")
  }

  readonly property var modifierNames: ["Ctrl", "Super", "Alt", "AltGr", "Shift"]

  function applyState(raw) {
    var obj
    try { obj = JSON.parse(String(raw || "")) } catch (e) { return }
    if (!obj || typeof obj !== "object") return
    if (typeof obj.enabled === "boolean" && obj.enabled !== root.opened) root.opened = obj.enabled
    if (typeof obj.duration === "number" && isFinite(obj.duration)) root.duration = Math.max(400, obj.duration)
    if (typeof obj.marginBottom === "number" && isFinite(obj.marginBottom)) root.marginBottom = Math.max(24, obj.marginBottom)
    if (typeof obj.maxEntries === "number" && isFinite(obj.maxEntries)) root.maxEntries = Math.min(12, Math.max(1, Math.round(obj.maxEntries)))
    if (typeof obj.posX === "number" && isFinite(obj.posX) && obj.posX >= 0) root.posX = obj.posX
    if (typeof obj.posY === "number" && isFinite(obj.posY) && obj.posY >= 0) root.posY = obj.posY
  }

  function persist() {
    stateMkdir.command = ["mkdir", "-p", root.stateDir]
    stateMkdir.running = true
  }

  function setEnabled(value) {
    if (root.opened === value) return
    root.opened = value
    root.persist()
  }

  function setDragMode(value) {
    if (root.dragMode === value) return
    root.dragMode = value
    if (value) dragIdle.restart()
    else dragIdle.stop()
  }

  // Shell summon contract (omarchy-shell shell summon batman.keytap '{...}').
  function open(payloadJson) {
    try {
      var p = JSON.parse(payloadJson || "{}")
      if (p && typeof p === "object") {
        if (typeof p.duration === "number" && isFinite(p.duration)) root.duration = Math.max(400, p.duration)
        if (typeof p.marginBottom === "number" && isFinite(p.marginBottom)) root.marginBottom = Math.max(24, p.marginBottom)
        if (typeof p.maxEntries === "number" && isFinite(p.maxEntries)) root.maxEntries = Math.min(12, Math.max(1, Math.round(p.maxEntries)))
        if (typeof p.posX === "number" && isFinite(p.posX) && p.posX >= 0) root.posX = p.posX
        if (typeof p.posY === "number" && isFinite(p.posY) && p.posY >= 0) root.posY = p.posY
      }
    } catch (e) {}
    root.setEnabled(true)
  }

  function close() { root.setEnabled(false) }

  function syncCollector() {
    if (root.opened) {
      if (!collector.running) collector.running = true
    } else {
      collector.running = false
      root.history = []
      root.activeCells = []
    }
  }

  onOpenedChanged: syncCollector()
  Component.onCompleted: syncCollector()

  // Alternating [{sep:true},{label,mod}] cells so Rows can interleave "+".
  function cellsFor(combo) {
    var out = []
    for (var i = 0; i < combo.length; i++) {
      if (i > 0) out.push({ sep: true })
      var label = String(combo[i])
      out.push({ label: label, mod: root.modifierNames.indexOf(label) !== -1 })
    }
    return out
  }

  function removeEntry(id) {
    root.history = root.history.filter(function(e) { return e.id !== id })
  }

  function handleLine(line) {
    line = String(line || "").trim()
    if (line === "") return
    var payload
    try { payload = JSON.parse(line) } catch (e) { return }
    var combo = Array.isArray(payload.combo) ? payload.combo.map(String) : []

    if (combo.length === 0) {
      // All keys released: finalize the active chord into history.
      if (root.hasActive) {
        var withNew = root.history.concat([{ id: root.nextEntryId++, cells: root.activeCells }])
        root.history = withNew.slice(-root.maxEntries)
        root.activeCells = []
      }
      return
    }

    // Chord in progress: the active bubble updates live until release.
    root.activeCells = root.cellsFor(combo)
  }

  Timer {
    id: respawnTimer
    interval: 2000
    onTriggered: if (root.opened && !collector.running) collector.running = true
  }

  // Drag mode self-dismisses after a few seconds of inactivity.
  Timer {
    id: dragIdle
    interval: 6000
    onTriggered: root.setDragMode(false)
  }

  Process {
    id: collector
    command: [root.collectorPath]
    stdout: SplitParser {
      onRead: function(line) { root.handleLine(line) }
    }
    onExited: respawnTimer.restart()
  }

  Process {
    id: stateMkdir
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      stateFile.setText(JSON.stringify({
        enabled: root.opened,
        duration: root.duration,
        marginBottom: root.marginBottom,
        maxEntries: root.maxEntries,
        posX: Math.round(root.posX),
        posY: Math.round(root.posY)
      }, null, 2) + "\n")
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyState(text())
    onFileChanged: reload()
    onLoadFailed: root.persist()
  }

  IpcHandler {
    target: "keytap"

    function toggle(): string {
      root.setEnabled(!root.opened)
      return root.opened ? "on" : "off"
    }

    function show(): string {
      root.setEnabled(true)
      return "on"
    }

    function hide(): string {
      root.setEnabled(false)
      return "off"
    }

    function drag(): string {
      root.setDragMode(!root.dragMode)
      return root.dragMode ? "drag-on" : "drag-off"
    }

    function state(): string {
      return JSON.stringify({
        enabled: root.opened,
        duration: root.duration,
        marginBottom: root.marginBottom,
        maxEntries: root.maxEntries,
        posX: Math.round(root.posX),
        posY: Math.round(root.posY),
        dragMode: root.dragMode
      })
    }

    function ping(): string { return "ok" }
  }

  // One keycap chip. `label`/`mod` are set by the owning Repeater delegate.
  component KeyCap: Rectangle {
    property string label: ""
    property bool mod: false

    implicitWidth: capLabel.implicitWidth + 2 * Style.space(10)
    implicitHeight: capLabel.implicitHeight + 2 * Style.space(7)
    radius: Style.space(7)
    color: Util.alpha(Color.popups.text, mod ? 0.06 : 0.10)
    border.width: 1
    border.color: mod ? Util.alpha(Color.popups.text, 0.18) : Util.alpha(Color.accent, 0.55)

    // Keycap depth: a subtle darker lip along the bottom edge.
    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: Math.max(1, Style.space(2))
      radius: height / 2
      color: Util.alpha("#000000", 0.30)
    }

    Text {
      id: capLabel
      anchors.centerIn: parent
      text: parent.label
      font.family: Style.font.family
      font.pixelSize: Style.font.title
      font.bold: true
      color: parent.mod ? Util.alpha(Color.popups.text, 0.78) : Color.popups.text
    }
  }

  // A chord rendered as chips with "+" separators.
  component ChipRow: Row {
    property var cells: []
    spacing: Style.space(8)

    Repeater {
      model: parent.cells

      delegate: Item {
        id: slot
        required property var modelData
        readonly property bool isSep: !!modelData.sep
        readonly property string label: modelData.label || ""

        width: isSep ? plus.implicitWidth : cap.implicitWidth
        height: Math.max(plus.implicitHeight, cap.implicitHeight)

        Text {
          id: plus
          visible: slot.isSep
          anchors.centerIn: parent
          text: "+"
          font.family: Style.font.family
          font.pixelSize: Style.font.subtitle
          color: Color.muted
        }

        KeyCap {
          id: cap
          visible: !slot.isSep
          anchors.centerIn: parent
          label: slot.label
          mod: !!modelData.mod
        }
      }
    }
  }

  // A finished chord: pops in, lingers, slowly dissolves, removes itself.
  // Content never mutates after creation, so the plain-array model is safe.
  component ComboBubble: BorderSurface {
    id: bubble
    property var cells: []
    property int entryId: 0
    property bool isLive: false

    readonly property int padX: Style.space(14)
    readonly property int padY: Style.space(12)

    width: borderLeft + padX + innerRow.implicitWidth + padX + borderRight
    height: borderTop + padY + innerRow.implicitHeight + padY + borderBottom
    radius: Math.max(Style.cornerRadius, Style.space(14))
    color: Util.alpha(Color.popups.background, 0.97)
    borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
    transformOrigin: Item.Center

    Component.onCompleted: {
      if (!isLive) {
        popIn.restart()
        lifeTimer.restart()
      }
    }

    Timer {
      id: lifeTimer
      interval: root.duration
      running: false
      onTriggered: dissolve.start()
    }

    SequentialAnimation {
      id: popIn
      NumberAnimation {
        target: bubble; property: "scale"; from: 0.7; to: 1
        duration: 240; easing.type: Easing.OutBack
      }
    }

    SequentialAnimation {
      id: dissolve
      ParallelAnimation {
        NumberAnimation {
          target: bubble; property: "opacity"; from: 1; to: 0
          duration: 1100; easing.type: Easing.InQuad
        }
        NumberAnimation {
          target: bubble; property: "scale"; from: 1; to: 0.92
          duration: 1100; easing.type: Easing.InQuad
        }
      }
      ScriptAction { script: if (bubble.entryId > 0) root.removeEntry(bubble.entryId) }
    }

    ChipRow {
      id: innerRow
      anchors.centerIn: parent
      cells: bubble.cells
    }
  }

  PanelWindow {
    id: panelWindow
    visible: root.opened && (root.history.length > 0 || root.hasActive || root.dragMode)
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    WlrLayershell.namespace: "batman-keytap"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // Click-through everywhere except the cluster while dragging: a
    // zero-sized region receives no input, so the desktop below stays
    // fully interactive.
    mask: Region {
      x: root.dragMode ? cluster.x : 0
      y: root.dragMode ? cluster.y : 0
      width: root.dragMode ? cluster.width : 0
      height: root.dragMode ? cluster.height : 0
    }

    ComboBubble {
      id: ghost
      visible: root.dragMode && !root.hasActive && root.history.length === 0
      cells: [{ label: "Keytap", mod: false }]

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.bottom
        anchors.topMargin: Style.space(6)
        text: "drag me — position saves on release"
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        color: Color.muted
      }
    }

    // The rolling cluster: finalized bubbles, then the live chord, all
    // centered on the stored position point.
    Item {
      id: cluster
      width: contentRow.implicitWidth
      height: contentRow.implicitHeight
      visible: root.history.length > 0 || root.hasActive

      x: {
        var cx = root.hasStoredPosition ? root.posX : panelWindow.width / 2
        var half = width / 2
        return Math.min(Math.max(cx - half, 0), Math.max(0, panelWindow.width - width))
      }
      y: {
        var cy = root.hasStoredPosition ? root.posY : panelWindow.height - root.marginBottom - height / 2
        var halfY = height / 2
        return Math.min(Math.max(cy - halfY, 0), Math.max(0, panelWindow.height - height))
      }

      Behavior on x { enabled: !root.dragMode; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      Behavior on y { enabled: !root.dragMode; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

      Row {
        id: contentRow
        spacing: Style.space(8)

        Repeater {
          model: root.history

          delegate: ComboBubble {
            required property var modelData
            cells: modelData.cells
            entryId: modelData.id
          }
        }

        ComboBubble {
          visible: root.hasActive
          isLive: true
          cells: root.activeCells
          borderSpec: Border.surfaceSpec("popups", "border", Color.accent, Math.max(1, Style.space(2)))
        }
      }

      MouseArea {
        id: dragArea
        anchors.fill: parent
        enabled: root.dragMode
        cursorShape: Qt.SizeAllCursor

        property real grabX: 0
        property real grabY: 0
        property real originX: 0
        property real originY: 0

        onPressed: function(mouse) {
          grabX = mouse.x; grabY = mouse.y
          originX = root.posX; originY = root.posY
          dragIdle.restart()
        }

        onPositionChanged: function(mouse) {
          if (!pressed) return
          root.posX = originX + (mouse.x - grabX)
          root.posY = originY + (mouse.y - grabY)
          dragIdle.restart()
        }

        onReleased: {
          root.persist()
          dragIdle.restart()
        }
      }
    }

    Text {
      id: dragHint
      visible: root.dragMode && cluster.visible
      text: "drag me — position saves on release"
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      color: Color.muted
      x: cluster.x + cluster.width / 2 - width / 2
      y: cluster.y + cluster.height + Style.space(6)
    }
  }
}
