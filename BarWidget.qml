import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Keytap bar widget — reflects and toggles the keypress visualizer.
//
// The panel (KeytapPanel.qml) owns the enabled state; this widget only reads
// the shared state file for its highlight and flips it via IPC, so every bar
// instance stays in sync without extra plumbing.
BarWidget {
  id: root
  moduleName: "batman.keytap"

  property bool enabled: true

  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/batman.keytap/state.json"

  function applyState(raw) {
    try {
      var obj = JSON.parse(String(raw || ""))
      if (obj && typeof obj.enabled === "boolean") root.enabled = obj.enabled
    } catch (e) {}
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyState(text())
    onFileChanged: reload()
    onLoadFailed: root.enabled = true
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uF11C"
    active: root.enabled
    tooltipText: root.enabled
      ? "Keytap: showing keystrokes — click to hide"
      : "Keytap: hidden — click to show"
    onPressed: function(b) {
      root.bar.run("omarchy-shell -q keytap toggle")
    }
  }
}
