import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Keytap — on-screen keypress visualizer.
//
// A floating theme-aware pill that renders the live key combo as styled
// keycaps, lingers, then slowly fades away. Key events come from the bundled
// Python collector (`keytap-collector`), which reads evdev devices directly
// and emits one JSON line per state change:
//
//   {"seq": 3, "combo": ["Ctrl", "Shift", "T"]}
//
// An empty combo array means every key was released -> begin the slow fade.
//
// The pill can be repositioned: enter drag mode via the bar widget's right
// click or `omarchy-shell keytap drag`, drag it anywhere, and the position
// persists to the shared state file.
Item {
  id: root

  // Injected by the shell's panel loader when present.
  property var shell: null
  property var manifest: null

  // Panel contract: opened == visualizer enabled.
  property bool opened: true
  property var combo: []
  property bool showing: false

  // Settings, persisted to the shared state file.
  property int duration: 3200
  property int marginBottom: 110

  // Free position of the pill center in window coordinates. -1 = unset,
  // fall back to the bottom-center default until first drag.
  property real posX: -1
  property real posY: -1
  readonly property bool hasStoredPosition: posX >= 0 && posY >= 0
  property bool dragMode: false

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

  // Alternating [{sep:true},{label,mod}] model so the Row can interleave "+".
  readonly property var displayCombo: {
    var out = []
    for (var i = 0; i < root.combo.length; i++) {
      if (i > 0) out.push({ sep: true })
      var label = String(root.combo[i])
      out.push({ label: label, mod: root.modifierNames.indexOf(label) !== -1 })
    }
    return out
  }

  function applyState(raw) {
    var obj
    try { obj = JSON.parse(String(raw || "")) } catch (e) { return }
    if (!obj || typeof obj !== "object") return
    if (typeof obj.enabled === "boolean" && obj.enabled !== root.opened) root.opened = obj.enabled
    if (typeof obj.duration === "number" && isFinite(obj.duration)) root.duration = Math.max(400, obj.duration)
    if (typeof obj.marginBottom === "number" && isFinite(obj.marginBottom)) root.marginBottom = Math.max(24, obj.marginBottom)
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
    if (value) {
      root.showing = true
      hideTimer.stop()
      dragIdle.restart()
      fadeIn.restart()
    } else {
      dragIdle.stop()
      hideTimer.interval = Math.max(400, root.duration)
      hideTimer.restart()
    }
  }

  // Shell summon contract (omarchy-shell shell summon batman.keytap '{...}').
  function open(payloadJson) {
    try {
      var p = JSON.parse(payloadJson || "{}")
      if (p && typeof p === "object") {
        if (typeof p.duration === "number" && isFinite(p.duration)) root.duration = Math.max(400, p.duration)
        if (typeof p.marginBottom === "number" && isFinite(p.marginBottom)) root.marginBottom = Math.max(24, p.marginBottom)
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
      root.combo = []
      root.showing = false
    }
  }

  onOpenedChanged: syncCollector()
  Component.onCompleted: syncCollector()

  function handleLine(line) {
    line = String(line || "").trim()
    if (line === "") return
    var payload
    try { payload = JSON.parse(line) } catch (e) { return }
    var next = Array.isArray(payload.combo) ? payload.combo.map(String) : []

    if (next.length === 0) {
      root.combo = []
      if (!root.dragMode) {
        root.showing = false
        fadeOut.restart()
      }
      return
    }

    var wasShowing = root.showing
    root.combo = next
    root.showing = true
    hideTimer.interval = Math.max(400, root.duration)
    hideTimer.restart()
    if (wasShowing) pulseAnim.restart()
    else popIn.restart()
    fadeIn.restart()
  }

  Timer {
    id: hideTimer
    interval: root.duration
    onTriggered: {
      if (root.dragMode) return
      root.showing = false
      fadeOut.restart()
    }
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
        posX: Math.round(root.posX),
        posY: Math.round(root.posY),
        dragMode: root.dragMode
      })
    }

    function ping(): string { return "ok" }
  }

  PanelWindow {
    id: panelWindow
    visible: root.opened
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    WlrLayershell.namespace: "batman-keytap"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // Click-through everywhere except the pill while dragging: a zero-sized
    // region receives no input, so the desktop below stays fully interactive.
    mask: Region {
      x: root.dragMode ? pill.x : 0
      y: root.dragMode ? pill.y : 0
      width: root.dragMode ? pill.width : 0
      height: root.dragMode ? pill.height : 0
    }

    BorderSurface {
      id: pill
      visible: root.showing && (root.combo.length > 0 || root.dragMode)
      opacity: root.showing ? 1 : 0
      transformOrigin: Item.Center

      readonly property int padX: Style.space(14)
      readonly property int padY: Style.space(12)

      width: borderLeft + padX + row.implicitWidth + padX + borderRight
      height: borderTop + padY + row.implicitHeight + padY + borderBottom
      radius: Math.max(Style.cornerRadius, Style.space(14))
      color: Util.alpha(Color.popups.background, 0.97)
      borderSpec: Border.surfaceSpec(
        "popups", "border",
        root.dragMode ? Color.accent : Color.popups.border,
        Math.max(1, Style.space(2))
      )

      // Stored position wins once dragged; otherwise stay bottom-center.
      // Pure bindings so a bogus or missing stored value self-corrects and
      // the pill tracks window resizes without imperative init races.
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

      SequentialAnimation {
        id: fadeIn
        NumberAnimation {
          target: pill; property: "opacity"; from: 0; to: 1
          duration: 160; easing.type: Easing.OutQuad
        }
      }

      SequentialAnimation {
        id: fadeOut
        ParallelAnimation {
          NumberAnimation {
            target: pill; property: "opacity"; from: 1; to: 0
            duration: 1100; easing.type: Easing.InQuad
          }
          NumberAnimation {
            target: pill; property: "scale"; from: 1; to: 0.96
            duration: 1100; easing.type: Easing.InQuad
          }
        }
      }

      SequentialAnimation {
        id: popIn
        NumberAnimation {
          target: pill; property: "scale"; from: 0.88; to: 1
          duration: 260; easing.type: Easing.OutBack
        }
      }

      SequentialAnimation {
        id: pulseAnim
        NumberAnimation {
          target: pill; property: "scale"; from: 1.05; to: 1
          duration: 140; easing.type: Easing.OutCubic
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

      Row {
        id: row
        anchors.fill: parent
        anchors.topMargin: pill.borderTop + pill.padY
        anchors.rightMargin: pill.borderRight + pill.padX
        anchors.bottomMargin: pill.borderBottom + pill.padY
        anchors.leftMargin: pill.borderLeft + pill.padX
        spacing: Style.space(8)

        Repeater {
          model: root.displayCombo

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

            Rectangle {
              id: cap
              visible: !slot.isSep
              anchors.centerIn: parent
              implicitWidth: capLabel.implicitWidth + 2 * Style.space(10)
              implicitHeight: capLabel.implicitHeight + 2 * Style.space(7)
              radius: Style.space(7)
              color: Util.alpha(Color.popups.text, modelData.mod ? 0.06 : 0.10)
              border.width: 1
              border.color: modelData.mod
                ? Util.alpha(Color.popups.text, 0.18)
                : Util.alpha(Color.accent, 0.55)

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
                text: slot.label
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
                color: modelData.mod ? Util.alpha(Color.popups.text, 0.78) : Color.popups.text
              }
            }
          }
        }
      }
    }

    Text {
      id: dragHint
      visible: root.dragMode
      text: "drag me — position saves on release"
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      color: Color.muted
      x: pill.x + pill.width / 2 - width / 2
      y: pill.y + pill.height + Style.space(6)
    }
  }
}
