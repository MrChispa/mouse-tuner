import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Mouse Tuner bar widget: a bar icon that opens a small panel to set the
// acceleration profile and sensitivity of one pointing device, plus the
// trackpad-specific options Hyprland accepts per device (natural scrolling,
// clickfinger, disable-while-typing, scroll factor). The heavy lifting
// (validating, writing the managed block in ~/.config/hypr/input.lua,
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
  property bool desiredNaturalScroll: false
  property bool desiredClickfinger: false
  property bool desiredDisableWhileTyping: true
  property real desiredScrollFactor: 1.0
  property string statusText: "Loading..."
  property bool statusOk: true
  property bool applyQueued: false
  // Which group of fields the next debounced apply should write. Each control
  // only sends its own fields, so the helper's upsert never adds a setting the
  // user did not touch.
  property bool pendingMotion: false
  property bool pendingTrackpad: false

  readonly property bool selectedIsTrackpad: {
    for (var i = 0; i < devices.length; i++)
      if (devices[i].name === selectedDevice) return devices[i].touchpad === true
    return false
  }

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
    desiredProfile = (e && e.accel_profile !== undefined) ? String(e.accel_profile) : "adaptive"
    desiredSensitivity = (e && e.sensitivity !== undefined) ? Number(e.sensitivity) : 0.0
    desiredNaturalScroll = (e && e.natural_scroll !== undefined) ? e.natural_scroll === true : false
    desiredClickfinger = (e && e.clickfinger_behavior !== undefined) ? e.clickfinger_behavior === true : false
    desiredDisableWhileTyping = (e && e.disable_while_typing !== undefined) ? e.disable_while_typing === true : true
    desiredScrollFactor = (e && e.scroll_factor !== undefined) ? Number(e.scroll_factor) : 1.0
  }

  function updateStatusLine() {
    var e = entryFor(selectedDevice)
    if (!e) {
      statusText = "No override · device defaults"
      return
    }
    var parts = []
    if (e.accel_profile !== undefined)
      parts.push(String(e.accel_profile) + " · " + Number(e.sensitivity).toFixed(2))
    if (e.natural_scroll !== undefined) parts.push("natural " + (e.natural_scroll ? "on" : "off"))
    if (e.clickfinger_behavior !== undefined) parts.push("clickfinger " + (e.clickfinger_behavior ? "on" : "off"))
    if (e.scroll_factor !== undefined) parts.push("scroll ×" + Number(e.scroll_factor).toFixed(2))
    statusText = parts.length > 0
      ? parts.join(" · ") + " (override active)"
      : "Override active"
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

  function requestMotionApply() {
    if (selectedDevice === "") {
      statusOk = false
      statusText = "No device selected"
      return
    }
    pendingMotion = true
    applyTimer.restart()
  }

  function requestTrackpadApply() {
    if (selectedDevice === "") {
      statusOk = false
      statusText = "No device selected"
      return
    }
    pendingTrackpad = true
    applyTimer.restart()
  }

  function applyNow() {
    if (selectedDevice === "") return
    if (applyProc.running) {
      applyQueued = true
      return
    }
    if (!pendingMotion && !pendingTrackpad) return

    var args = ["bash", helperScript, "set", "--device", selectedDevice]
    if (pendingMotion) {
      args.push("--profile", desiredProfile)
      args.push("--sensitivity", desiredSensitivity.toFixed(2))
    }
    if (pendingTrackpad && selectedIsTrackpad) {
      args.push("--natural-scroll", desiredNaturalScroll ? "true" : "false")
      args.push("--clickfinger", desiredClickfinger ? "true" : "false")
      args.push("--disable-while-typing", desiredDisableWhileTyping ? "true" : "false")
      args.push("--scroll-factor", desiredScrollFactor.toFixed(2))
    }

    // The selection can change inside the debounce window (a trackpad control
    // touched, then a mouse picked). With no flags left the helper would reject
    // the call, so drop it instead of surfacing a pointless error.
    if (args.length <= 5) {
      pendingMotion = false
      pendingTrackpad = false
      applyQueued = false
      return
    }

    pendingMotion = false
    pendingTrackpad = false
    applyQueued = false
    applyProc.command = args
    applyProc.running = true
  }

  function applyPreset(profile, sensitivity) {
    desiredProfile = profile
    desiredSensitivity = sensitivity
    requestMotionApply()
  }

  function applyTrackpadPreset(natural, clickfinger, factor) {
    desiredNaturalScroll = natural
    desiredClickfinger = clickfinger
    desiredScrollFactor = factor
    requestTrackpadApply()
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
    // No fixed height cap: with a trackpad selected the panel carries three
    // toggles, a scroll slider and two presets on top of the device list and
    // the motion controls. `fittedContentHeight` already clamps to the card
    // space actually available on screen, so sizing to the content here keeps
    // every row visible the way the same panel does for a mouse.
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

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
            root.requestMotionApply()
          }
        }

        // Trackpad-only options. Hyprland accepts these per device, unlike
        // tap-to-click / tap-and-drag, which only exist globally.
        Column {
          id: trackpadSection
          width: parent.width
          visible: root.selectedIsTrackpad
          height: visible ? implicitHeight : 0
          spacing: Style.space(6)

          PanelSeparator { foreground: root.contentForeground }

          PanelSectionHeader {
            text: "TRACKPAD"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Toggle {
            width: parent.width
            label: "Natural scrolling"
            checked: root.desiredNaturalScroll
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: {
              root.desiredNaturalScroll = !root.desiredNaturalScroll
              root.requestTrackpadApply()
            }
          }

          Toggle {
            width: parent.width
            label: "Clickfinger (2-finger right click)"
            checked: root.desiredClickfinger
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: {
              root.desiredClickfinger = !root.desiredClickfinger
              root.requestTrackpadApply()
            }
          }

          Toggle {
            width: parent.width
            label: "Disable while typing"
            checked: root.desiredDisableWhileTyping
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: {
              root.desiredDisableWhileTyping = !root.desiredDisableWhileTyping
              root.requestTrackpadApply()
            }
          }

          Item {
            width: parent.width
            implicitHeight: Math.max(scrollHeader.implicitHeight, scrollValue.implicitHeight)

            PanelSectionHeader {
              id: scrollHeader
              text: "SCROLL SPEED"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: scrollValue
              text: Number(root.desiredScrollFactor).toFixed(2)
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          PanelSlider {
            id: scrollFactorSlider
            width: parent.width
            bar: root.bar
            minimum: 0.1
            maximum: 2.0
            step: 0.05
            value: root.desiredScrollFactor
            onMoved: function(v) {
              root.desiredScrollFactor = v
              root.requestTrackpadApply()
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            Button {
              width: (parent.width - Style.space(6)) / 2
              text: "Apple-like"
              selected: root.desiredNaturalScroll === true
                && root.desiredClickfinger === true
                && Math.abs(root.desiredScrollFactor - 0.8) < 0.001
              bordered: true
              foreground: root.contentForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              fontSize: Style.font.caption
              onClicked: root.applyTrackpadPreset(true, true, 0.8)
            }

            Button {
              width: (parent.width - Style.space(6)) / 2
              text: "Traditional"
              selected: root.desiredNaturalScroll === false
                && root.desiredClickfinger === true
                && Math.abs(root.desiredScrollFactor - 1.0) < 0.001
              bordered: true
              foreground: root.contentForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              fontSize: Style.font.caption
              onClicked: root.applyTrackpadPreset(false, true, 1.0)
            }
          }

          Text {
            width: parent.width
            text: "Tap-to-click is a global touchpad setting in Hyprland, so it is not per-device."
            color: root.dimForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
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
