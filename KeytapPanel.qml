import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Keytap — on-screen keypress visualizer.
//
// A floating theme-aware pill near the bottom of the screen that renders the
// live key combo as styled keycaps. Key events come from the bundled Python
// collector (`keytap-collector`), which reads evdev devices directly and
// emits one JSON line per state change:
//
//   {"seq": 3, "combo": ["Ctrl", "Shift", "T"]}
//
// An empty combo array means every key was released -> hide the pill.
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
  property int duration: 1600
  property int marginBottom: 110

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
    if (isFinite(Number(obj.duration))) root.duration = Math.max(400, Number(obj.duration))
    if (isFinite(Number(obj.marginBottom))) root.marginBottom = Math.max(24, Number(obj.marginBottom))
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

  // Shell summon contract (omarchy-shell shell summon batman.keytap '{...}').
  function open(payloadJson) {
    try {
      var p = JSON.parse(payloadJson || "{}")
      if (p && typeof p === "object") {
        if (isFinite(Number(p.duration))) root.duration = Math.max(400, Number(p.duration))
        if (isFinite(Number(p.marginBottom))) root.marginBottom = Math.max(24, Number(p.marginBottom))
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
      root.showing = false
      shrinkOut.restart()
      return
    }

    var wasShowing = root.showing
    root.combo = next
    root.showing = true
    hideTimer.interval = Math.max(400, root.duration)
    hideTimer.restart()
    if (wasShowing) pulseAnim.restart()
    else popIn.restart()
  }

  Timer {
    id: hideTimer
    interval: root.duration
    onTriggered: {
      root.showing = false
      shrinkOut.restart()
    }
  }

  Timer {
    id: respawnTimer
    interval: 2000
    onTriggered: if (root.opened && !collector.running) collector.running = true
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
        marginBottom: root.marginBottom
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

    function state(): string {
      return JSON.stringify({
        enabled: root.opened,
        duration: root.duration,
        marginBottom: root.marginBottom
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
    // Visual-only surface: keep the input region empty so the pill never
    // blocks clicks to whatever is underneath.
    mask: Region {}

    BorderSurface {
      id: pill
      visible: root.showing && root.combo.length > 0
      opacity: root.showing ? 1 : 0
      transformOrigin: Item.Bottom

      readonly property int padX: Style.space(14)
      readonly property int padY: Style.space(12)

      width: borderLeft + padX + row.implicitWidth + padX + borderRight
      height: borderTop + padY + row.implicitHeight + padY + borderBottom
      radius: Math.max(Style.cornerRadius, Style.space(14))
      color: Util.alpha(Color.popups.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: root.marginBottom

      Behavior on opacity {
        NumberAnimation { duration: 140; easing.type: Easing.OutQuad }
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

      SequentialAnimation {
        id: shrinkOut
        NumberAnimation {
          target: pill; property: "scale"; from: 1; to: 0.9
          duration: 140; easing.type: Easing.InQuad
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
                text: modelData.label
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
  }
}
