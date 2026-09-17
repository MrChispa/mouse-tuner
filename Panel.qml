import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
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
//
// The panel is organized as collapsible sections with a live summary in each
// header, so a collapsed section still reports its state. Collapsed by default
// (except DEVICE) keeps the card short enough to need no scrolling; a pinned
// footer holds Reset device and the status line. The whole UI is bilingual
// (EN/ES) and the language is a persisted widget setting.
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

  // Status is split into a transient notice (an action result or an error) and
  // a derived state line. The state line is a binding, so it re-renders on its
  // own when the language changes; only the notice is set imperatively.
  property bool loaded: false
  property string noticeKey: ""
  property var noticeArgs: ({})
  property bool noticeOk: true

  property bool applyQueued: false
  // Which group of fields the next debounced apply should write. Each control
  // only sends its own fields, so the helper's upsert never adds a setting the
  // user did not touch.
  property bool pendingMotion: false
  property bool pendingTrackpad: false

  // Collapsible section state. DEVICE starts open; the rest start collapsed so
  // the first read of the panel is short and scannable.
  property bool deviceExpanded: true
  property bool motionExpanded: false
  property bool trackpadExpanded: false
  property bool gesturesExpanded: false

  // Gestures are global (not per device). The panel exposes a curated set of
  // slots; clicking a row cycles its action and "off" removes the gesture.
  // Gestures added through the CLI still come back in the helper output and
  // are never touched by these rows.
  property var gestures: []
  property var gestureCatalog: ({})

  // Gestures the user wrote by hand outside Mouse Tuner's block. Hyprland keeps
  // the first definition in the file, so those lines shadow the panel's own
  // gestures: the controls look dead. Detection is reported by the helper as
  // `unmanaged` in both `gestures` and `status`.
  property var unmanaged: []
  readonly property int unmanagedCount: unmanaged.length
  // Surface the problem instead of hiding it behind a collapsed section: the
  // first time detection reports something, open GESTURES once. The user can
  // still collapse it afterwards (assigning a same-length array does not re-fire).
  onUnmanagedCountChanged: if (unmanagedCount > 0) gesturesExpanded = true

  readonly property var gestureSlots: [
    { fingers: 3, direction: "horizontal" },
    { fingers: 3, direction: "vertical" },
    { fingers: 3, direction: "pinch" },
    { fingers: 4, direction: "horizontal" },
    { fingers: 4, direction: "vertical" },
    { fingers: 4, direction: "pinch" }
  ]

  readonly property var gestureRing: {
    var ring = ["off"]
    if (gestureCatalog && Array.isArray(gestureCatalog.actions)) {
      for (var i = 0; i < gestureCatalog.actions.length; i++)
        ring.push(String(gestureCatalog.actions[i]))
    }
    return ring
  }

  readonly property bool selectedIsTrackpad: {
    for (var i = 0; i < devices.length; i++)
      if (devices[i].name === selectedDevice) return devices[i].touchpad === true
    return false
  }

  readonly property var selectedDeviceInfo: {
    for (var i = 0; i < devices.length; i++)
      if (devices[i].name === selectedDevice) return devices[i]
    return null
  }

  // ---------------------------------------------------------------- language
  //
  // The language is a persisted widget setting (`language`), read through a
  // reactive property. `t()` reads `uiLang`, so every binding that calls it is
  // dependency-tracked and re-renders the instant the user switches language.
  readonly property string uiLang: String(root.setting("language", "EN")).toUpperCase() === "ES" ? "ES" : "EN"

  readonly property var tr: ({
    EN: {
      loading: "Loading...",
      noDevice: "No pointing device found",
      pointerTuning: "Pointer tuning",
      deviceSection: "DEVICE",
      motionSection: "MOTION",
      trackpadSection: "TRACKPAD",
      gesturesSection: "GESTURES",
      sensitivity: "SENSITIVITY",
      scrollSpeed: "SCROLL SPEED",
      precise: "Precise",
      balanced: "Balanced",
      defaultProfile: "Default",
      naturalScroll: "Natural scrolling",
      clickfinger: "Clickfinger (2-finger right click)",
      disableWhileTyping: "Disable while typing",
      appleLike: "Apple-like",
      traditionalPreset: "Traditional",
      tapGlobalHint: "Tap-to-click is a global touchpad setting in Hyprland, so it is not per-device.",
      gesturesHint: "Global trackpad shortcuts. Click a row to cycle its action; \"off\" removes it. Gestures you add from the CLI stay untouched.",
      gesturesUnmanaged: "{n} gesture(s) are defined outside Mouse Tuner and would shadow the panel.",
      importGestures: "Import",
      importDone: "Gestures imported",
      failedImport: "Failed to import gestures",
      unmanagedShort: "{n} unmanaged",
      fingers: "fingers",
      dir_horizontal: "horizontal",
      dir_vertical: "vertical",
      dir_pinch: "pinch",
      touchpadTag: "(touchpad)",
      batteryCharging: "charging",
      batteryFull: "full",
      natural: "natural",
      natOn: "natural",
      natOff: "traditional",
      scroll: "scroll",
      stateOn: "on",
      stateOff: "off",
      gesturesActive: "{n} active",
      overrideActive: "(override active)",
      noOverride: "No override · device defaults",
      resetDevice: "Reset device",
      resetHint: "Remove this device's override and return it to system defaults.",
      noDeviceSelected: "No device selected",
      invalidResponse: "Invalid response from helper",
      helperError: "Helper reported an error",
      failedApply: "Failed to apply",
      reloadFailed: "Applied, but the Hyprland reload failed",
      failedReset: "Failed to reset the device",
      gestureUpdated: "Gesture updated",
      gestureReloadFailed: "Gesture applied, but the Hyprland reload failed",
      failedGesture: "Failed to change the gesture",
      raw: "{text}",
      languageTooltip: "Language: EN — click to switch"
    },
    ES: {
      loading: "Cargando...",
      noDevice: "No se encontró ningún dispositivo señalador",
      pointerTuning: "Ajuste del puntero",
      deviceSection: "DISPOSITIVO",
      motionSection: "MOVIMIENTO",
      trackpadSection: "TRACKPAD",
      gesturesSection: "GESTOS",
      sensitivity: "SENSIBILIDAD",
      scrollSpeed: "VELOCIDAD DE SCROLL",
      precise: "Preciso",
      balanced: "Equilibrado",
      defaultProfile: "Predeterminado",
      naturalScroll: "Desplazamiento natural",
      clickfinger: "Clickfinger (clic derecho con 2 dedos)",
      disableWhileTyping: "Desactivar al escribir",
      appleLike: "Estilo Apple",
      traditionalPreset: "Tradicional",
      tapGlobalHint: "El toque para hacer clic es un ajuste global de Hyprland, así que no se configura por dispositivo.",
      gesturesHint: "Atajos globales del trackpad. Haz clic en una fila para cambiar su acción; \"off\" la elimina. Los gestos añadidos desde la CLI no se modifican.",
      gesturesUnmanaged: "{n} gesto(s) están definidos fuera de Mouse Tuner y anularían el panel.",
      importGestures: "Importar",
      importDone: "Gestos importados",
      failedImport: "No se pudieron importar los gestos",
      unmanagedShort: "{n} sin gestionar",
      fingers: "dedos",
      dir_horizontal: "horizontal",
      dir_vertical: "vertical",
      dir_pinch: "pellizco",
      touchpadTag: "(trackpad)",
      batteryCharging: "cargando",
      batteryFull: "completa",
      natural: "natural",
      natOn: "natural",
      natOff: "tradicional",
      scroll: "scroll",
      stateOn: "sí",
      stateOff: "no",
      gesturesActive: "{n} activos",
      overrideActive: "(ajuste activo)",
      noOverride: "Sin ajuste · valores del sistema",
      resetDevice: "Restablecer dispositivo",
      resetHint: "Elimina el ajuste de este dispositivo y vuelve a los valores del sistema.",
      noDeviceSelected: "Ningún dispositivo seleccionado",
      invalidResponse: "Respuesta no válida del asistente",
      helperError: "El asistente reportó un error",
      failedApply: "No se pudo aplicar",
      reloadFailed: "Aplicado, pero falló la recarga de Hyprland",
      failedReset: "No se pudo restablecer el dispositivo",
      gestureUpdated: "Gesto actualizado",
      gestureReloadFailed: "Gesto aplicado, pero falló la recarga de Hyprland",
      failedGesture: "No se pudo cambiar el gesto",
      raw: "{text}",
      languageTooltip: "Idioma: ES — haz clic para cambiar"
    }
  })

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Look up a string in the active language table. Reads `uiLang`, which is
  // what makes bindings that call it re-evaluate on a language switch.
  function t(key) {
    var table = root.tr[root.uiLang] || root.tr.EN
    var value = table[key]
    if (value === undefined) value = root.tr.EN[key]
    return value === undefined ? String(key) : String(value)
  }

  // Tiny "{name}" substitution for strings that carry runtime values.
  function render(template, args) {
    var out = String(template)
    if (args) {
      for (var k in args) out = out.split("{" + k + "}").join(String(args[k]))
    }
    return out
  }

  function setNotice(key, ok, args) {
    noticeKey = String(key)
    noticeOk = ok === true
    noticeArgs = args || ({})
  }

  function clearNotice() {
    noticeKey = ""
    noticeArgs = ({})
    noticeOk = true
  }

  function cycleLanguage() {
    var next = root.uiLang === "ES" ? "EN" : "ES"
    var s = root.settings || {}
    var updated = {}
    for (var k in s) updated[k] = s[k]
    updated.language = next
    root.settings = updated
    Util.execDetached("omarchy bar set io.github.mrchispa.mouse-tuner language " + next)
  }

  function deviceExists(name) {
    for (var i = 0; i < devices.length; i++) if (devices[i].name === name) return true
    return false
  }

  function entryFor(name) {
    for (var i = 0; i < entries.length; i++) if (entries[i].device === name) return entries[i]
    return null
  }

  // Compact suffix for a device row: " · 100%", plus " · charging" or
  // " · full" when the kernel reports that state. Plain text on purpose: the
  // bar font has no reliable battery glyph, and a codepoint it lacks renders
  // as a literal dash. Devices without a battery expose nothing.
  function batterySuffix(info) {
    if (!info || !info.battery) return ""
    var percent = info.battery.percent
    if (percent === undefined || percent === null) return ""
    var value = Math.round(Number(percent))
    if (!isFinite(value)) return ""
    var suffix = " · " + value + "%"
    var state = String(info.battery.state || "").toLowerCase()
    if (state === "charging") suffix += " · " + root.t("batteryCharging")
    else if (state === "full") suffix += " · " + root.t("batteryFull")
    return suffix
  }

  function gestureFor(fingers, direction) {
    for (var i = 0; i < gestures.length; i++) {
      var g = gestures[i]
      if (Number(g.fingers) === Number(fingers)
          && String(g.direction) === String(direction)
          && !g.mods)
        return String(g.action || "")
    }
    return ""
  }

  function gestureRowLabel(fingers, direction) {
    var action = gestureFor(fingers, direction)
    return fingers + " " + root.t("fingers") + " · " + root.t("dir_" + direction)
      + "   " + (action === "" ? "off" : action)
  }

  // ------------------------------------------------------------- summaries
  //
  // Each summary feeds a collapsed section header so it still reports state.
  // They are plain functions called from bindings, so they track every value
  // they read (device, desired fields, gesture count, language).
  function deviceSummary() {
    var info = root.selectedDeviceInfo
    if (!info) return ""
    return String(info.label) + batterySuffix(info)
  }

  function motionSummary() {
    if (root.selectedDevice === "") return ""
    return String(root.desiredProfile) + " · " + Number(root.desiredSensitivity).toFixed(2)
  }

  function trackpadSummary() {
    if (!root.selectedIsTrackpad) return ""
    return (root.desiredNaturalScroll ? root.t("natOn") : root.t("natOff"))
      + " · clickfinger " + (root.desiredClickfinger ? root.t("stateOn") : root.t("stateOff"))
      + " · " + Number(root.desiredScrollFactor).toFixed(2)
  }

  function gesturesSummary() {
    var summary = root.render(root.t("gesturesActive"), { n: root.gestures.length })
    if (root.unmanagedCount > 0)
      summary += " · " + root.render(root.t("unmanagedShort"), { n: root.unmanagedCount })
    return summary
  }

  function heroDeviceLabel() {
    if (root.selectedDevice === "") return ""
    var info = root.selectedDeviceInfo
    var label = info ? String(info.label) : String(root.selectedDevice)
    return label.length > 22 ? label.substring(0, 21) + "…" : label
  }

  function heroMeta() {
    if (!root.loaded) return root.t("loading")
    if (root.devices.length === 0) return root.t("noDevice")
    return root.t("pointerTuning")
  }

  // The state line is a binding over the managed entries, so it localizes and
  // updates without an imperative refresh.
  readonly property string stateText: {
    if (!root.loaded) return root.t("loading")
    if (root.devices.length === 0) return root.t("noDevice")
    if (root.selectedDevice === "") return root.t("noDeviceSelected")
    var e = root.entryFor(root.selectedDevice)
    if (!e) return root.t("noOverride")
    var parts = []
    if (e.accel_profile !== undefined)
      parts.push(String(e.accel_profile) + " · " + Number(e.sensitivity).toFixed(2))
    if (e.natural_scroll !== undefined)
      parts.push(root.t("natural") + " " + (e.natural_scroll ? root.t("stateOn") : root.t("stateOff")))
    if (e.clickfinger_behavior !== undefined)
      parts.push("clickfinger " + (e.clickfinger_behavior ? root.t("stateOn") : root.t("stateOff")))
    if (e.scroll_factor !== undefined)
      parts.push(root.t("scroll") + " ×" + Number(e.scroll_factor).toFixed(2))
    return parts.length > 0
      ? parts.join(" · ") + " " + root.t("overrideActive")
      : root.t("overrideActive")
  }

  readonly property string noticeText: root.noticeKey === ""
    ? ""
    : root.render(root.t(root.noticeKey), root.noticeArgs)

  readonly property string statusLine: root.noticeText !== "" ? root.noticeText : root.stateText
  readonly property bool statusOk: root.noticeText === "" ? true : root.noticeOk

  // Cycle a slot through: off -> catalog actions -> off. "off" removes the
  // gesture line entirely, which is how Hyprland un-defines it.
  function cycleGesture(fingers, direction) {
    var ring = gestureRing
    var current = gestureFor(fingers, direction)
    var index = 0
    for (var i = 0; i < ring.length; i++) {
      if ((ring[i] === "off" && current === "") || (ring[i] !== "off" && ring[i] === current)) {
        index = i
        break
      }
    }
    var next = ring[(index + 1) % ring.length]
    if (gestureProc.running) return
    if (next === "off") {
      gestureProc.command = ["bash", helperScript, "gesture-unset",
                             "--fingers", String(fingers), "--direction", direction]
    } else {
      gestureProc.command = ["bash", helperScript, "gesture-set",
                             "--fingers", String(fingers), "--direction", direction,
                             "--action", next]
    }
    gestureProc.running = true
  }

  function handleGesture(output) {
    var data
    try { data = JSON.parse(String(output)) } catch (e) {
      setNotice("invalidResponse", false)
      return
    }
    if (!data || data.ok !== true) {
      setNotice(data && data.error ? "raw" : "failedGesture", false,
                data && data.error ? { text: String(data.error) } : ({}))
      return
    }
    if (Array.isArray(data.gestures)) gestures = data.gestures
    if (Array.isArray(data.unmanaged)) unmanaged = data.unmanaged
    var reloadOk = String(data.reload || "").replace(/\s+$/, "") === "ok"
    if (reloadOk) setNotice("gestureUpdated", true)
    else setNotice("gestureReloadFailed", false)
  }

  function importGestures() {
    if (importProc.running) return
    importProc.command = ["bash", helperScript, "gestures-import"]
    importProc.running = true
  }

  function handleImport(output) {
    var data
    try { data = JSON.parse(String(output)) } catch (e) {
      setNotice("invalidResponse", false)
      return
    }
    if (!data || data.ok !== true) {
      setNotice(data && data.error ? "raw" : "failedImport", false,
                data && data.error ? { text: String(data.error) } : ({}))
      return
    }
    if (Array.isArray(data.gestures)) gestures = data.gestures
    unmanaged = Array.isArray(data.unmanaged) ? data.unmanaged : []
    var reloadOk = String(data.reload || "").replace(/\s+$/, "") === "ok"
    if (reloadOk) setNotice("importDone", true)
    else setNotice("gestureReloadFailed", false)
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

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function handleStatus(output) {
    loaded = true
    var data
    try { data = JSON.parse(String(output)) } catch (e) {
      setNotice("invalidResponse", false)
      return
    }
    if (!data || data.ok !== true) {
      setNotice(data && data.error ? "raw" : "helperError", false,
                data && data.error ? { text: String(data.error) } : ({}))
      return
    }

    devices = Array.isArray(data.devices) ? data.devices : []
    primary = data.primary ? String(data.primary) : ""
    entries = Array.isArray(data.entries) ? data.entries : []
    gestures = Array.isArray(data.gestures) ? data.gestures : []
    gestureCatalog = (data.catalog && typeof data.catalog === "object") ? data.catalog : ({})
    unmanaged = Array.isArray(data.unmanaged) ? data.unmanaged : []

    var preferred = root.setting("deviceName", "")
    if (selectedDevice === "" || !deviceExists(selectedDevice)) {
      if (preferred !== "" && deviceExists(preferred)) selectedDevice = preferred
      else if (primary !== "" && deviceExists(primary)) selectedDevice = primary
      else if (devices.length > 0) selectedDevice = devices[0].name
      else selectedDevice = ""
    }

    syncFromEntry()
    clearNotice()
  }

  function selectDevice(name) {
    selectedDevice = String(name)
    syncFromEntry()
    clearNotice()
    if (typeof Util !== "undefined" && Util && Util.execDetached)
      Util.execDetached("omarchy bar set io.github.mrchispa.mouse-tuner deviceName " + Util.shellQuote(String(name)))
  }

  function requestMotionApply() {
    if (selectedDevice === "") {
      setNotice("noDeviceSelected", false)
      return
    }
    pendingMotion = true
    applyTimer.restart()
  }

  function requestTrackpadApply() {
    if (selectedDevice === "") {
      setNotice("noDeviceSelected", false)
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
      setNotice("invalidResponse", false)
      return
    }
    if (!data || data.ok !== true) {
      setNotice(data && data.error ? "raw" : "failedApply", false,
                data && data.error ? { text: String(data.error) } : ({}))
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
    if (reloadOk) clearNotice()
    else setNotice("reloadFailed", false)
  }

  function handleRemove(output) {
    var data
    try { data = JSON.parse(String(output)) } catch (e) {
      setNotice("invalidResponse", false)
      return
    }
    if (!data || data.ok !== true) {
      setNotice(data && data.error ? "raw" : "failedReset", false,
                data && data.error ? { text: String(data.error) } : ({}))
      return
    }
    if (Array.isArray(data.entries)) entries = data.entries
    syncFromEntry()
    clearNotice()
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

  Process {
    id: gestureProc
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleGesture(text)
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  Process {
    id: importProc
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleImport(text)
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  Timer {
    id: applyTimer
    interval: 250
    repeat: false
    onTriggered: root.applyNow()
  }

  // The battery is read when the panel opens (onOpenedChanged) and kept fresh
  // while it stays open. One batched `status` call refreshes it; the helper
  // reads the kernel power_supply every time, so no per-device calls are made.
  Timer {
    id: batteryRefreshTimer
    interval: 60000
    repeat: true
    running: root.opened
    onTriggered: root.refresh()
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
    // The scroll content plus the pinned footer. `fittedContentHeight` clamps
    // to the card space actually available; when several sections are expanded
    // the ScrollView above the footer takes care of the overflow, so nothing
    // gets clipped. Collapsed, the whole panel is shorter than the card and
    // scrolls not at all.
    contentHeight: panel.fittedContentHeight(
      contentColumn.implicitHeight + footerColumn.implicitHeight + Style.space(12))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      ScrollView {
        id: scrollArea
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footerColumn.top
        anchors.bottomMargin: Style.space(12)
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: contentColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: contentColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: contentColumn
          width: scrollArea.availableWidth
          spacing: Style.space(16)

          // ---------------------------------------------------------- hero
          PanelHero {
            id: hero
            width: parent.width
            title: "Mouse Tuner"
            detail: root.heroDeviceLabel()
            meta: root.heroMeta()
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "\udb80\udf7d"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              Button {
                text: root.uiLang === "ES" ? "EN" : "ES"
                tooltipText: root.t("languageTooltip")
                bordered: true
                foreground: root.dimForeground
                accent: Color.accent
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(3)
                onClicked: root.cycleLanguage()
              }
            }
          }

          // -------------------------------------------------------- device
          Section {
            title: root.t("deviceSection")
            summary: root.deviceSummary()
            expanded: root.deviceExpanded
            first: true
            onToggled: root.deviceExpanded = !root.deviceExpanded

            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: root.devices.length > 0

              Repeater {
                model: root.devices

                Button {
                  required property var modelData
                  required property int index
                  width: parent.width
                  text: modelData.label
                    + (modelData.touchpad ? " " + root.t("touchpadTag") : "")
                    + (modelData.name === root.selectedDevice ? root.batterySuffix(modelData) : "")
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
              text: root.loaded ? root.t("noDevice") : root.t("loading")
              color: root.dimForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // -------------------------------------------------------- motion
          Section {
            title: root.t("motionSection")
            summary: root.motionSummary()
            expanded: root.motionExpanded
            onToggled: root.motionExpanded = !root.motionExpanded

            Row {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: [
                  { label: root.t("precise"), profile: "flat", sensitivity: -0.35 },
                  { label: root.t("balanced"), profile: "flat", sensitivity: -0.15 },
                  { label: root.t("defaultProfile"), profile: "adaptive", sensitivity: 0.0 }
                ]

                Button {
                  required property var modelData
                  width: (parent.width - Style.space(12)) / 3
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

            Item {
              width: parent.width
              implicitHeight: Math.max(sensitivityHeader.implicitHeight, sensitivityValue.implicitHeight)

              PanelSectionHeader {
                id: sensitivityHeader
                text: root.t("sensitivity")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: sensitivityValue
                textFormat: Text.PlainText
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
          }

          // ------------------------------------------------------ trackpad
          // Trackpad-only options. Hyprland accepts these per device, unlike
          // tap-to-click / tap-and-drag, which only exist globally.
          Section {
            title: root.t("trackpadSection")
            summary: root.trackpadSummary()
            expanded: root.trackpadExpanded
            visible: root.selectedIsTrackpad
            onToggled: root.trackpadExpanded = !root.trackpadExpanded

            ToggleRow {
              label: root.t("naturalScroll")
              checked: root.desiredNaturalScroll
              onToggled: {
                root.desiredNaturalScroll = !root.desiredNaturalScroll
                root.requestTrackpadApply()
              }
            }

            ToggleRow {
              label: root.t("clickfinger")
              checked: root.desiredClickfinger
              onToggled: {
                root.desiredClickfinger = !root.desiredClickfinger
                root.requestTrackpadApply()
              }
            }

            ToggleRow {
              label: root.t("disableWhileTyping")
              checked: root.desiredDisableWhileTyping
              onToggled: {
                root.desiredDisableWhileTyping = !root.desiredDisableWhileTyping
                root.requestTrackpadApply()
              }
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(scrollHeader.implicitHeight, scrollValue.implicitHeight)

              PanelSectionHeader {
                id: scrollHeader
                text: root.t("scrollSpeed")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: scrollValue
                textFormat: Text.PlainText
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
                text: root.t("appleLike")
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
                text: root.t("traditionalPreset")
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
              text: root.t("tapGlobalHint")
              color: root.dimForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ------------------------------------------------------ gestures
          Section {
            title: root.t("gesturesSection")
            summary: root.gesturesSummary()
            expanded: root.gesturesExpanded
            onToggled: root.gesturesExpanded = !root.gesturesExpanded

            Text {
              width: parent.width
              text: root.t("gesturesHint")
              color: root.dimForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // Unmanaged gestures live outside the managed block and win over it
            // (Hyprland keeps the first definition), so the rows below would do
            // nothing. Warn and offer the one-click fix.
            Column {
              width: parent.width
              spacing: Style.space(6)
              visible: root.unmanagedCount > 0

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.render(root.t("gesturesUnmanaged"), { n: root.unmanagedCount })
                color: Color.urgent
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Button {
                width: parent.width
                text: root.t("importGestures")
                bordered: true
                leftAlign: true
                foreground: root.contentForeground
                accent: Color.accent
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
                enabled: !importProc.running
                onClicked: root.importGestures()
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: root.gestureSlots

                Button {
                  required property var modelData
                  width: parent.width
                  text: root.gestureRowLabel(modelData.fingers, modelData.direction)
                  selected: root.gestureFor(modelData.fingers, modelData.direction) !== ""
                  bordered: true
                  leftAlign: true
                  foreground: root.contentForeground
                  accent: Color.accent
                  fontFamily: root.contentFontFamily
                  fontSize: Style.font.caption
                  onClicked: root.cycleGesture(modelData.fingers, modelData.direction)
                }
              }
            }
          }
        }
      }

      // ------------------------------------------------------------ footer
      // Pinned below the scroll area: Reset device and the status line stay
      // visible no matter how many sections are expanded.
      Column {
        id: footerColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: Style.space(6)

        PanelSeparator { foreground: root.contentForeground }

        RowLayout {
          width: parent.width
          spacing: Style.space(8)

          Button {
            id: resetButton
            text: root.t("resetDevice")
            bordered: true
            leftAlign: true
            foreground: root.contentForeground
            accent: Color.urgent
            fontFamily: root.contentFontFamily
            fontSize: Style.font.caption
            enabled: root.selectedDevice !== "" && root.entryFor(root.selectedDevice) !== null
            onClicked: root.resetDevice()
          }

          Text {
            textFormat: Text.PlainText
            text: root.t("resetHint")
            color: root.dimForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
          }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.statusLine
          color: root.statusOk ? root.dimForeground : Color.urgent
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // ------------------------------------------------------------- components

  // Collapsible section: a hoverable header (chevron + title + live summary)
  // that toggles a body. Declared children go into the body column, so a
  // section reads like a container without introducing a nested card.
  component Section: Column {
    id: section

    property string title: ""
    property string summary: ""
    property bool expanded: false
    property bool first: false
    default property alias body: bodyColumn.data

    signal toggled()

    width: parent ? parent.width : implicitWidth
    spacing: Style.space(6)

    PanelSeparator {
      width: parent.width
      visible: !section.first
      foreground: root.contentForeground
    }

    BorderSurface {
      id: headerRow
      width: parent.width
      implicitHeight: headerLayout.implicitHeight + Style.space(10)
      color: headerMouse.containsMouse
        ? Style.hoverFillFor(root.contentForeground, Color.accent)
        : "transparent"
      radius: Style.cornerRadius
      borderSpec: Border.none()

      Behavior on color { ColorAnimation { duration: 100 } }

      RowLayout {
        id: headerLayout
        anchors.fill: parent
        anchors.leftMargin: Style.space(4)
        anchors.rightMargin: Style.space(4)
        spacing: Style.space(8)

        Text {
          textFormat: Text.PlainText
          text: section.expanded ? "\uf078" : "\uf054"
          color: root.dimForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          Layout.alignment: Qt.AlignVCenter
        }

        PanelSectionHeader {
          text: section.title
          fontSize: Style.font.body
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
          Layout.alignment: Qt.AlignVCenter
        }

        Text {
          textFormat: Text.PlainText
          text: section.summary
          visible: text !== ""
          color: root.dimForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          horizontalAlignment: Text.AlignRight
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignVCenter
        }
      }

      MouseArea {
        id: headerMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: section.toggled()
      }
    }

    Column {
      id: bodyColumn
      width: parent.width
      spacing: Style.space(8)
      visible: section.expanded
    }
  }

  // Labeled toggle row: body-weight label on the left, a bare ToggleSwitch on
  // the right. The row owns the click so the whole line is a target.
  component ToggleRow: BorderSurface {
    id: toggleRow

    property string label: ""
    property bool checked: false

    signal toggled()

    width: parent ? parent.width : implicitWidth
    implicitHeight: Math.max(labelText.implicitHeight, switchTrack.implicitHeight) + Style.space(10)
    color: rowMouse.containsMouse
      ? Style.hoverFillFor(root.contentForeground, Color.accent)
      : "transparent"
    radius: Style.cornerRadius
    borderSpec: Border.none()

    Behavior on color { ColorAnimation { duration: 100 } }

    Text {
      id: labelText
      textFormat: Text.PlainText
      text: toggleRow.label
      color: root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
      width: Math.max(0, parent.width - switchTrack.width - Style.space(20))
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }

    ToggleSwitch {
      id: switchTrack
      checked: toggleRow.checked
      interactive: false
      foreground: root.contentForeground
      accent: Color.accent
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: toggleRow.toggled()
    }
  }
}
