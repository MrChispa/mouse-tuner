import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Mouse Tuner bar widget: a bar icon that opens a small panel to set the
// acceleration profile and sensitivity of one pointing device. The heavy
// lifting (validating, writing the managed block in ~/.config/hypr/input.lua,
// reloading Hyprland) lives in bin/mouse-tuner.sh, which prints JSON.
Panel {
  id: root
  moduleName: "io.github.mrchispa.mouse-tuner"
  ipcTarget: "io.github.mrchispa.mouse-tuner"

  // Resolve the helper next to this QML file so the plugin is self-contained
  // wherever the shell loads it from.
  readonly property string helperScript: {
    var url = String(Qt.resolvedUrl("bin/mouse-tuner.sh"))
    return decodeURIComponent(url.replace(/^file:\/\//, ""))
  }

  readonly property color contentForeground: bar ? bar.barForeground : Color.foreground
  readonly property color dimForeground: Qt.darker(contentForeground, 1.5)
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  property var devices: []
  property string primary: ""
  property var entries: []
  property string selectedDevice: ""
  property string desiredProfile: "adaptive"
  property real desiredSensitivity: 0.0
  property string statusText: "Loading..."
  property bool statusOk: true
  property bool applyQueued: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function deviceExists(name) {
    for (var i = 0; i < devices.length; i++) if (devices[i].name === name) return true
    return false
  }

  function entryFor(name) {
    for (var i = 0; i < entries.length; i++) if (entries[i].device === name) return entries[i]
    return null
  }

  function syncFromEntry() {
    var e = entryFor(selectedDevice)
    desiredProfile = e ? String(e.accel_profile) : "adaptive"
    desiredSensitivity = e ? Number(e.sensitivity) : 0.0
  }

  function updateStatusLine() {
    var e = entryFor(selectedDevice)
    if (e) statusText = String(e.accel_profile) + " · " + Number(e.sensitivity).toFixed(2) + " (override active)"
    else statusText = "No override · device defaults"
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function handleStatus(output) {
    var data
    try { data = JSON.parse(String(output)) } catch (e) {
      statusOk = false
      statusText = "Invalid response from helper"
      return
    }
    if (!data || data.ok !== true) {
      statusOk = false
      statusText = (data && data.error) ? String(data.error) : "Helper reported an error"
      return
    }

    devices = Array.isArray(data.devices) ? data.devices : []
    primary = data.primary ? String(data.primary) : ""
    entries = Array.isArray(data.entries) ? data.entries : []

    var preferred = root.setting("deviceName", "")
    if (selectedDevice === "" || !deviceExists(selectedDevice)) {
      if (preferred !== "" && deviceExists(preferred)) selectedDevice = preferred
      else if (primary !== "" && deviceExists(primary)) selectedDevice = primary
      else if (devices.length > 0) selectedDevice = devices[0].name
      else selectedDevice = ""
    }

    syncFromEntry()
    if (selectedDevice === "") {
      statusOk = false
      statusText = "No pointing device found"
    } else {
      statusOk = true
      updateStatusLine()
    }
  }

  function selectDevice(name) {
    selectedDevice = String(name)
    syncFromEntry()
    statusOk = true
    updateStatusLine()
    if (typeof Util !== "undefined" && Util && Util.execDetached)
      Util.execDetached("omarchy bar set io.github.mrchispa.mouse-tuner deviceName " + Util.shellQuote(String(name)))
  }

  function requestApply() {
    if (selectedDevice === "") {
      statusOk = false
      statusText = "No device selected"
      return
    }
    applyTimer.restart()
  }

  function applyNow() {
    if (selectedDevice === "") return
    if (applyProc.running) {
      applyQueued = true
      return
    }
    applyQueued = false
    applyProc.command = [
      "bash", helperScript, "set",
      "--device", selectedDevice,
      "--profile", desiredProfile,
      "--sensitivity", desiredSensitivity.toFixed(2)
    ]
    applyProc.running = true
  }

  function applyPreset(profile, sensitivity) {
    desiredProfile = profile
    desiredSensitivity = sensitivity
    requestApply()
  }

  function resetDevice() {
    if (selectedDevice === "" || removeProc.running) return
    removeProc.command = ["bash", helperScript, "remove", "--device", selectedDevice]
    removeProc.running = true
  }

  function handleApply(output) {
    var data
    try { data = JSON.parse(String(output)) } catch (e) {
      statusOk = false
      statusText = "Invalid response from helper"
      return
    }
    if (!data || data.ok !== true) {
      statusOk = false
      statusText = (data && data.error) ? String(data.error) : "Failed to apply"
      return
    }

    if (Array.isArray(data.entries)) entries = data.entries
    else if (data.applied) {
      var list = entries.slice()
      var found = false
      for (var i = 0; i < list.length; i++)
        if (list[i].device === data.applied.device) { list[i] = data.applied; found = true }
      if (!found) list.push(data.applied)
      entries = list
    }

    var reloadOk = String(data.reload || "").replace(/\s+$/, "") === "ok"
    syncFromEntry()
    statusOk = reloadOk
    updateStatusLine()
    if (!reloadOk) statusText = "Applied, but the Hyprland reload failed"
  }

  function handleRemove(output) {
    var data
    try { data = JSON.parse(String(output)) } catch (e) {
      statusOk = false
      statusText = "Invalid response from helper"
      return
    }
    if (!data || data.ok !== true) {
      statusOk = false
      statusText = (data && data.error) ? String(data.error) : "Failed to reset the device"
      return
    }
    if (Array.isArray(data.entries)) entries = data.entries
    syncFromEntry()
    statusOk = true
    statusText = "Override removed · device defaults"
  }

  onOpenedChanged: if (opened) refresh()
  Component.onCompleted: refresh()

  Process {
    id: statusProc
    command: ["bash", root.helperScript, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleStatus(text)
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  Process {
    id: applyProc
    onExited: function() {
      if (root.applyQueued) {
        root.applyQueued = false
        root.applyNow()
      }
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleApply(text)
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  Process {
    id: removeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleRemove(text)
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  Timer {
    id: applyTimer
    interval: 250
    repeat: false
    onTriggered: root.applyNow()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\udb80\udf7d"
    tooltipText: "Mouse Tuner"
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      Column {
        id: contentColumn
        width: parent.width
        spacing: Style.space(10)

        Text {
          text: "Mouse Tuner"
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Text {
          width: parent.width
          text: "Acceleration and sensitivity are applied only to the selected device."
          color: root.dimForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        PanelSeparator { foreground: root.contentForeground }

        PanelSectionHeader {
          text: "DEVICE"
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
        }

        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.devices.length > 0

          Repeater {
            model: root.devices

            Button {
              required property var modelData
              required property int index
              width: contentColumn.width
              text: modelData.label + (modelData.touchpad ? " (touchpad)" : "")
              selected: modelData.name === root.selectedDevice
              bordered: true
              leftAlign: true
              foreground: root.contentForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              fontSize: Style.font.caption
              onClicked: root.selectDevice(modelData.name)
            }
          }
        }

        Text {
          width: parent.width
          visible: root.devices.length === 0
          text: "No pointing device found."
          color: root.dimForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }

        PanelSeparator { foreground: root.contentForeground }

        PanelSectionHeader {
          text: "PRESETS"
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
        }

        Row {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: [
              { label: "Precise", profile: "flat", sensitivity: -0.35 },
              { label: "Balanced", profile: "flat", sensitivity: -0.15 },
              { label: "Default", profile: "adaptive", sensitivity: 0.0 }
            ]

            Button {
              required property var modelData
              width: (contentColumn.width - Style.space(12)) / 3
              text: modelData.label
              selected: root.desiredProfile === modelData.profile
                && Math.abs(root.desiredSensitivity - modelData.sensitivity) < 0.001
              bordered: true
              foreground: root.contentForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              fontSize: Style.font.caption
              onClicked: root.applyPreset(modelData.profile, modelData.sensitivity)
            }
          }
        }

        PanelSeparator { foreground: root.contentForeground }

        Item {
          width: parent.width
          implicitHeight: Math.max(sensitivityHeader.implicitHeight, sensitivityValue.implicitHeight)

          PanelSectionHeader {
            id: sensitivityHeader
            text: "SENSITIVITY"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: sensitivityValue
            text: Number(root.desiredSensitivity).toFixed(2)
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        PanelSlider {
          id: sensitivitySlider
          width: parent.width
          bar: root.bar
          minimum: -1
          maximum: 1
          step: 0.05
          value: root.desiredSensitivity
          enabled: root.selectedDevice !== ""
          onMoved: function(v) {
            root.desiredSensitivity = v
            root.requestApply()
          }
        }

        Item {
          width: parent.width
          implicitHeight: resetButton.implicitHeight

          Button {
            id: resetButton
            width: parent.width * 0.4
            text: "Reset device"
            bordered: true
            foreground: root.dimForeground
            accent: Color.urgent
            fontFamily: root.contentFontFamily
            fontSize: Style.font.caption
            enabled: root.selectedDevice !== "" && root.entryFor(root.selectedDevice) !== null
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.resetDevice()
          }

          Text {
            text: "Remove this device's override and return it to system defaults."
            color: root.dimForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            anchors.left: resetButton.right
            anchors.leftMargin: Style.space(8)
            anchors.right: parent.right
            anchors.verticalCenter: resetButton.verticalCenter
          }
        }

        Text {
          width: parent.width
          text: root.statusText
          color: root.statusOk ? root.dimForeground : Color.urgent
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
