import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// State and processes for the tun0 VPN widget. Everything comes from the `vpn` script:
// `vpn json` is the one poll, `vpn public` the slow geo lookup, and every action is a
// `vpn <verb>` run through actionProc. The widget never talks to nmcli or nft itself.
//
// Every process runs by absolute path, under /usr/bin/timeout, with a cleared environment that carries only what
// `vpn` needs (its tools come from PATH=/usr/bin, notifications need the session bus), and its output is read in
// pieces and kept only up to a fixed size: a process that talks too much is stopped and counts as failed.
Item {
  id: root
  visible: false

  property var settings: ({})
  property bool opened: false

  // ---- what `vpn json` says --------------------------------------------------------------------
  property var stateData: null
  // True when the last poll failed: the panel then says it does not know, instead of showing the last good state.
  property bool failed: false
  // What the panel reads: the last good state, or only "unknown" while the poll fails. Nothing of the last good state
  // is shown or acted on meanwhile: every action waits until the state can be read again.
  readonly property var view: failed ? ({ state: "unknown" }) : stateData
  readonly property string vpnState: failed ? "unknown" : (stateData ? Model.str(stateData.state || "off", 16) : "off")
  readonly property string active: stateData && !failed ? Model.str(stateData.active, 64) : ""
  readonly property string want: stateData && !failed ? Model.str(stateData.want, 64) : ""
  readonly property string label: stateData && !failed ? Model.str(stateData.label, 128) : ""
  readonly property string killswitch: failed ? "unknown" : (stateData ? Model.str(stateData.killswitch || "off", 16) : "off")
  readonly property bool watchdog: stateData && !failed ? stateData.watchdog === true : false
  readonly property string defaultName: stateData && !failed ? Model.str(stateData["default"], 64) : ""
  readonly property string ssid: stateData && !failed ? Model.str(stateData.ssid, 128) : ""
  readonly property bool trusted: stateData && !failed ? stateData.trusted === true : false
  readonly property bool autoconnect: stateData && !failed ? stateData.autoconnect === true : false
  readonly property bool autodisconnect: stateData && !failed ? stateData.autodisconnect === true : false
  readonly property var trustedList: stateData && !failed ? Model.list(stateData.trustedList, 1024) : []
  readonly property var knownWifi: stateData && !failed ? Model.list(stateData.knownWifi, 256) : []
  readonly property var profiles: stateData && !failed ? Model.list(stateData.profiles, 64) : []
  readonly property bool up: vpnState === "connected"
  readonly property bool stalled: vpnState === "stalled"
  readonly property bool wanted: vpnState === "connected" || vpnState === "connecting" || vpnState === "down" || vpnState === "stalled"

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

  // What a `vpn` process gets to see, and nothing else.
  readonly property int outputCap: 262144
  function processEnv(extra) {
    var e = { PATH: "/usr/bin", HOME: String(Quickshell.env("HOME") || ""), LANG: String(Quickshell.env("LANG") || "C.UTF-8") }
    var keep = ["XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE"]
    for (var i = 0; i < keep.length; i++) {
      var v = Quickshell.env(keep[i])
      if (v) e[keep[i]] = String(v)
    }
    for (var k in (extra || {})) e[k] = extra[k]
    return e
  }
  // collect(buffer, chunk, process): keep up to outputCap characters; past that, stop the process and mark the buffer
  // as overflowed. Output already read when the kill lands still arrives, so the cap holds here, not at the kill.
  property string _stateText: ""
  property string _publicText: ""
  property string _actOut: ""
  property string _actErr: ""
  property var _overflow: ({})
  function collect(name, chunk, proc) {
    if (_overflow[name]) return
    if (root[name].length + chunk.length > outputCap) {
      _overflow[name] = true
      proc.signal(9)
      return
    }
    root[name] += chunk
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // ---- reading -------------------------------------------------------------------------------------
  function refresh() {
    if (stateProc.running) return
    stateProc.running = true
  }

  function stateFailed(message) {
    loading = false
    failed = true
    errorText = message
  }

  function applyState(raw) {
    var d = Model.parseState(raw)
    loading = false
    if (!d) {
      stateFailed("`vpn json` did not return a state. Is tun0 VPN installed? See Install in the README")
      return
    }
    failed = false
    if (errorText.indexOf("`vpn json`") === 0) errorText = ""
    stateData = d
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
    if (failed) { refresh(); return false }   // no action on a state nobody can read
    busyLabel = label || ""
    notice = noticeText || ""
    errorText = ""
    // With the panel open the result is visible right there; a toast would only cover it. Right-click
    // and keyboard shortcuts with the panel shut keep the toast. Critical toasts ignore the flag.
    actionProc.environment = processEnv(opened ? { VPN_QUIET: "1" } : {})
    // an action waits for NetworkManager (a connect up to 40 s, the watchdog's own attempt on top)
    actionProc.command = ["/usr/bin/timeout", "-k", "5", "180", vpnBin].concat(args)
    actionProc.running = true
    return true
  }

  function connectTo(name) {
    if (!name) return
    run(["on", name], "Connecting…")
  }
  function disconnect() { run(["off"], "Disconnecting…") }
  function toggleTunnel() {
    if (failed) { refresh(); return }
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

  // The wizards and the status page live in a floating terminal of their own (the `vpn present` wrapper), which
  // needs the full session to open a window; `vpn` sets its own PATH there.
  function openWizard(kind) { Quickshell.execDetached([vpnBin, "present", kind]) }
  function copyPublicIp() {
    if (!publicInfo || !publicInfo.ip) return
    Quickshell.execDetached(["/usr/bin/wl-copy", "--", String(publicInfo.ip)])
    notice = "Copied " + publicInfo.ip
  }

  // ---- processes -----------------------------------------------------------------------------------
  Process {
    id: stateProc
    running: false
    clearEnvironment: true
    environment: root.processEnv({})
    command: ["/usr/bin/timeout", "-k", "5", "20", root.vpnBin, "json"]
    stdout: SplitParser { splitMarker: ""; onRead: function(chunk) { root.collect("_stateText", chunk, stateProc) } }
    onStarted: { root._stateText = ""; root._overflow._stateText = false }
    onExited: function(exitCode) {
      if (root._overflow._stateText) root.stateFailed("`vpn json` said more than " + root.outputCap + " characters and was stopped")
      else if (exitCode !== 0) root.stateFailed("`vpn json` failed (exit " + exitCode + (exitCode === 124 ? ", timed out" : "") + "). Is tun0 VPN installed? See Install in the README")
      else root.applyState(root._stateText)
      root._stateText = ""
    }
  }

  Process {
    id: publicProc
    running: false
    clearEnvironment: true
    environment: root.processEnv({})
    command: ["/usr/bin/timeout", "-k", "5", "15", root.vpnBin, "public"]
    stdout: SplitParser { splitMarker: ""; onRead: function(chunk) { root.collect("_publicText", chunk, publicProc) } }
    onStarted: { root._publicText = ""; root._overflow._publicText = false }
    onExited: function(exitCode) {
      var p = exitCode === 0 && !root._overflow._publicText ? Model.parseState(root._publicText) : null
      root.publicInfo = p && (p.ip || p.lookup === false) ? p : null
      root.publicLoading = false
      root._publicText = ""
    }
  }

  Process {
    id: actionProc
    running: false
    clearEnvironment: true
    command: []
    stdout: SplitParser { splitMarker: ""; onRead: function(chunk) { root.collect("_actOut", chunk, actionProc) } }
    stderr: SplitParser { splitMarker: ""; onRead: function(chunk) { root.collect("_actErr", chunk, actionProc) } }
    onStarted: { root._actOut = ""; root._actErr = ""; root._overflow._actOut = false; root._overflow._actErr = false }
    onExited: function(exitCode) {
      if (root._overflow._actOut || root._overflow._actErr) {
        root.errorText = "vpn said more than " + root.outputCap + " characters and was stopped"
        root.busyLabel = ""
      } else if (exitCode !== 0) {
        var msg = String(root._actErr || root._actOut || "").trim().split("\n")[0].slice(0, 300)
        root.errorText = msg || ("vpn exited with " + exitCode + (exitCode === 124 ? " (timed out)" : ""))
        root.busyLabel = ""
      }
      root._actOut = ""; root._actErr = ""
      root.refresh()
      settleTimer.restart()
    }
  }

  // ---- timers --------------------------------------------------------------------------------------
  // Brisk while the panel is open or something is in flight; the bar alone only needs the idle rate.
  Timer {
    interval: (root.opened || root.vpnState === "connecting" || root.busy ? 1 : root.refreshIntervalSec) * 1000
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
