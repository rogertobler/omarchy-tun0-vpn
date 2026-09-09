import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// State and processes for the tun0 VPN widget. Everything comes from the `vpn` script:
// `vpn json` is the one poll, `vpn public` the slow geo lookup, and every action is a
// `vpn <verb>` run through actionProc. The widget never talks to nmcli or nft itself.
Item {
  id: root
  visible: false

  property var settings: ({})
  property bool opened: false

  // ---- what `vpn json` says --------------------------------------------------------------------
  property var data: null
  readonly property string state: data ? String(data.state || "off") : "off"
  readonly property string active: data ? String(data.active || "") : ""
  readonly property string want: data ? String(data.want || "") : ""
  readonly property string label: data ? String(data.label || "") : ""
  readonly property string killswitch: data ? String(data.killswitch || "off") : "off"
  readonly property bool watchdog: data ? data.watchdog === true : false
  readonly property string defaultName: data ? String(data["default"] || "") : ""
  readonly property string ssid: data ? String(data.ssid || "") : ""
  readonly property bool trusted: data ? data.trusted === true : false
  readonly property bool autoconnect: data ? data.autoconnect === true : false
  readonly property bool autodisconnect: data ? data.autodisconnect === true : false
  readonly property var trustedList: data && data.trustedList instanceof Array ? data.trustedList : []
  readonly property var knownWifi: data && data.knownWifi instanceof Array ? data.knownWifi : []
  readonly property var profiles: data && data.profiles instanceof Array ? data.profiles : []
  readonly property bool up: state === "connected"
  readonly property bool stalled: state === "stalled"
  readonly property bool wanted: state === "connected" || state === "connecting" || state === "down" || state === "stalled"

  // ---- where the internet sees you ---------------------------------------------------------------
  property var publicInfo: null
  property bool publicLoading: false

  // ---- throughput, from the byte counters `vpn json` carries ---------------------------------------
  property real rxRate: 0
  property real txRate: 0
  property var rxHistory: []
  property var txHistory: []
  property double sessionRx: 0
  property double sessionTx: 0
  property double _lastRx: -1
  property double _lastTx: -1
  property double _lastAt: 0
  property string _lastIface: ""

  // ---- in flight ----------------------------------------------------------------------------------
  property bool loading: true
  property string busyLabel: ""
  property string notice: ""
  property string errorText: ""
  property string _lastState: ""
  readonly property bool busy: actionProc.running

  readonly property string vpnBin: (Quickshell.env("HOME") || "") + "/.local/bin/vpn"
  readonly property int refreshIntervalSec: Math.max(1, Math.min(300, parseInt(setting("refreshIntervalSec", 5)) || 5))

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // ---- reading -------------------------------------------------------------------------------------
  function refresh() {
    if (stateProc.running) return
    stateProc.running = true
  }

  function applyState(raw) {
    var d = Model.parseState(raw)
    loading = false
    if (!d) {
      errorText = "Could not read `vpn json` - is ~/.local/bin/vpn installed? (sudo ./install.sh)"
      return
    }
    errorText = ""
    data = d
    trackThroughput(d)
    if (d.state !== _lastState) {
      // The route out changes with the tunnel; ask again a beat later, once NetworkManager settled it.
      if (_lastState !== "" && (d.state === "connected" || d.state === "off")) publicTimer.restart()
      if (d.state === "connected" || d.state === "off") busyLabel = ""
      _lastState = d.state
    }
  }

  function trackThroughput(d) {
    var iface = String(d.iface || "")
    var now = Date.now()
    if (!iface) {
      rxRate = 0; txRate = 0; _lastRx = -1; _lastTx = -1; _lastIface = ""
      sessionRx = 0; sessionTx = 0
      if (rxHistory.length) { rxHistory = []; txHistory = [] }
      return
    }
    var rx = Number(d.rx) || 0, tx = Number(d.tx) || 0
    if (iface !== _lastIface || _lastRx < 0 || rx < _lastRx || tx < _lastTx) {
      // new tunnel, or the counters wrapped: start the window afresh
      _lastIface = iface; _lastRx = rx; _lastTx = tx; _lastAt = now
      sessionRx = 0; sessionTx = 0
      rxHistory = []; txHistory = []
      rxRate = 0; txRate = 0
      return
    }
    var dt = Math.max(0.2, (now - _lastAt) / 1000)
    rxRate = (rx - _lastRx) / dt
    txRate = (tx - _lastTx) / dt
    sessionRx += rx - _lastRx
    sessionTx += tx - _lastTx
    _lastRx = rx; _lastTx = tx; _lastAt = now
    rxHistory = rxHistory.concat([rxRate]).slice(-60)
    txHistory = txHistory.concat([txRate]).slice(-60)
  }

  function refreshPublic() {
    if (publicProc.running) return
    publicLoading = true
    publicProc.running = true
  }

  // ---- acting --------------------------------------------------------------------------------------
  function run(args, label, noticeText) {
    if (actionProc.running) return false
    busyLabel = label || ""
    notice = noticeText || ""
    errorText = ""
    // With the panel open the result is visible right there; a toast would only cover it. Right-click
    // and keyboard shortcuts with the panel shut keep the toast. Critical toasts ignore the flag.
    actionProc.environment = opened ? ({ VPN_QUIET: "1" }) : ({})
    actionProc.command = [vpnBin].concat(args)
    actionProc.running = true
    return true
  }

  function connectTo(name) {
    if (!name) return
    run(["on", name], "Connecting…")
  }
  function disconnect() { run(["off"], "Disconnecting…") }
  function toggleTunnel() {
    if (wanted) disconnect()
    else connectTo(defaultName || (profiles.length ? profiles[0].name : ""))
  }
  function setDefault(name) { if (name) run(["default", name], "", "Default: " + name) }
  function setKillswitch(on) { run(["killswitch", on ? "on" : "off"], "", "Kill switch " + (on ? "on" : "off")) }
  function trustToggle() { if (ssid) run(["trust", "toggle"], "", trusted ? "\"" + ssid + "\" is no longer trusted" : "\"" + ssid + "\" is now trusted") }
  function forgetNetwork(name) { if (name) run(["trust", "remove", name], "", "\"" + name + "\" forgotten") }
  function setTrusted(name, on) { if (name) run(["trust", on ? "add" : "remove", name], "", "\"" + name + "\" is " + (on ? "now trusted" : "no longer trusted")) }
  function setAutoconnect(on) { run(["autoconnect", on ? "on" : "off"], "", "Auto-connect " + (on ? "on" : "off")) }
  function setAutodisconnect(on) { run(["autodisconnect", on ? "on" : "off"], "", "Auto-disconnect " + (on ? "on" : "off")) }

  // The wizards and the status page live in a floating terminal of their own (the `vpn present` wrapper).
  function openWizard(kind) { Quickshell.execDetached([vpnBin, "present", kind]) }
  function copyPublicIp() {
    if (!publicInfo || !publicInfo.ip) return
    Quickshell.execDetached(["wl-copy", "--", String(publicInfo.ip)])
    notice = "Copied " + publicInfo.ip
  }

  // ---- processes -----------------------------------------------------------------------------------
  Process {
    id: stateProc
    running: false
    command: [root.vpnBin, "json"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyState(text) }
    onExited: function(exitCode) {
      if (exitCode !== 0 && !root.data) {
        root.loading = false
        root.errorText = "`vpn json` failed (exit " + exitCode + ") - run: sudo ./install.sh"
      }
    }
  }

  Process {
    id: publicProc
    running: false
    command: [root.vpnBin, "public"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var p = Model.parseState(text)
        root.publicInfo = p && p.ip ? p : null
      }
    }
    onExited: root.publicLoading = false
  }

  Process {
    id: actionProc
    running: false
    command: []
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        var msg = String(actionErr.text || actionOut.text || "").trim().split("\n")[0]
        root.errorText = msg || ("vpn exited with " + exitCode)
        root.busyLabel = ""
      }
      root.refresh()
      settleTimer.restart()
    }
  }

  // ---- timers --------------------------------------------------------------------------------------
  // Brisk while the panel is open or something is in flight; the bar alone only needs the idle rate.
  Timer {
    interval: (root.opened || root.state === "connecting" || root.busy ? 1 : root.refreshIntervalSec) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
  Timer { id: settleTimer; interval: 1500; repeat: false; onTriggered: root.refresh() }
  Timer { id: publicTimer; interval: 1500; repeat: false; onTriggered: root.refreshPublic() }
  // A notice is a toast, not a status line.
  Timer { interval: 6000; running: root.notice !== ""; repeat: false; onTriggered: root.notice = "" }
}
