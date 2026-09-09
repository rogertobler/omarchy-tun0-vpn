.pragma library

// Pure helpers for the tun0 VPN widget. Nothing here touches the shell; it turns the JSON
// `vpn json` emits into strings and numbers the panel can bind to.

var GLYPH_LOCK = "\u{F099D}"      // nf-md-shield_lock: connected
var GLYPH_OFF = "\u{F099E}"       // nf-md-shield_off: tunnel down while wanted
var GLYPH_OUTLINE = "\u{F0484}"   // nf-md-shield_outline: off / connecting

function parseState(raw) {
  try {
    var d = JSON.parse(String(raw || "").trim())
    return d && typeof d === "object" ? d : null
  } catch (e) {
    return null
  }
}

function glyphFor(state) {
  if (state === "connected") return GLYPH_LOCK
  if (state === "down" || state === "stalled") return GLYPH_OFF
  return GLYPH_OUTLINE
}

function stateTitle(state, busyLabel) {
  if (busyLabel) return busyLabel
  switch (state) {
    case "connected": return "Connected"
    case "connecting": return "Connecting…"
    case "stalled": return "Reconnecting…"
    case "down": return "Tunnel down"
    default: return "Off"
  }
}

// One line under the title: which profile, and what the kill switch is doing.
function heroMeta(d) {
  if (!d) return "Checking…"
  var name = d.want || d.active || ""
  var label = d.label || ""
  switch (d.state) {
    case "connected":
      return label + " · kill switch " + ksWord(d)
    case "connecting":
      return label + " · kill switch " + (d.killswitch === "unloaded" ? "NOT LOADED" : d.killswitch === "disabled" ? "disabled" : "shut")
    case "stalled":
      return "link lost or server not answering · OpenVPN restarting · nothing flows"
    case "down":
      return (d.killswitch === "disabled" ? "kill switch DISABLED" : d.killswitch === "unloaded" ? "kill switch NOT LOADED" : "kill switch holding") + " · retrying " + name
    default:
      return (d["default"] ? "default: " + label : "no profile yet - add one below") + (d.killswitch === "disabled" ? " · kill switch disabled" : "")
  }
}
// "on" only when the uplink really is shut. "unloaded" is the state the docs promise to make visible: the
// setting says on, but no table exists (no profile yet, or the unit was stopped) - nothing is blocked.
function ksWord(d) {
  if (d.killswitch === "disabled") return "disabled"
  if (d.killswitch === "unloaded") return "NOT LOADED"
  if (d.killswitch === "off") return "open"
  return "on"
}

// Which Wi-Fi rows the panel shows. `known` arrives most recently used first. With a filter: every fuzzy
// match. Without: the network you are on, every trusted one, then the last `recent` untrusted networks you
// actually used - a laptop can know a hundred networks and the panel is not the place to scroll through
// them; "show all" lifts the cap.
function wifiRows(known, trusted, current, filter, recent, showAll) {
  var q = String(filter || "").toLowerCase().trim()
  var isT = function(s) { return trusted.indexOf(s) !== -1 }
  if (q) return known.filter(function(s) { return fuzzy(String(s).toLowerCase(), q) })
  if (showAll) return known.slice()
  var out = [], rest = 0
  for (var i = 0; i < known.length; i++) {
    var s = known[i]
    if (s === current || isT(s)) out.push(s)
    else if (rest < recent) { out.push(s); rest++ }
  }
  return out
}

function fuzzy(hay, needle) {
  var i = 0
  for (var j = 0; j < hay.length && i < needle.length; j++) if (hay[j] === needle[i]) i++
  return i === needle.length
}

// The full line under the hero: where the internet sees you. Empty while unknown so nothing wobbles.
function publicLine(p, loading) {
  if (loading && (!p || !p.ip)) return "Looking up where you come out…"
  if (!p || !p.ip) return ""
  var where = p.country || ""
  if (p.city) where += (where ? ", " : "") + p.city
  var line = "Seen as " + (where || "?") + " · " + p.ip
  if (p.org) line += " · " + p.org
  return line
}

function fmtRate(bytesPerSec) {
  var v = Math.max(0, Number(bytesPerSec) || 0)
  if (v < 1024) return Math.round(v) + " B/s"
  if (v < 1024 * 1024) return (v / 1024).toFixed(v < 10240 ? 1 : 0) + " kB/s"
  if (v < 1024 * 1024 * 1024) return (v / (1024 * 1024)).toFixed(1) + " MB/s"
  return (v / (1024 * 1024 * 1024)).toFixed(2) + " GB/s"
}

function fmtBytes(bytes) {
  var v = Math.max(0, Number(bytes) || 0)
  if (v < 1024) return Math.round(v) + " B"
  if (v < 1024 * 1024) return (v / 1024).toFixed(0) + " kB"
  if (v < 1024 * 1024 * 1024) return (v / (1024 * 1024)).toFixed(1) + " MB"
  return (v / (1024 * 1024 * 1024)).toFixed(2) + " GB"
}

// Scale a history of rates to bar heights in [0, maxHeight]; a quiet tunnel still shows a hairline.
function sparkHeights(history, maxHeight) {
  var out = []
  var peak = 0
  for (var i = 0; i < history.length; i++) peak = Math.max(peak, Number(history[i]) || 0)
  for (var j = 0; j < history.length; j++) {
    var v = Number(history[j]) || 0
    out.push(peak > 0 ? Math.max(1, Math.round(v / peak * maxHeight)) : 1)
  }
  return out
}

function profileDescription(p) {
  var bits = [p.name]
  if (p["default"]) bits.push("default")
  if (p.recent && !p["default"]) bits.push("recent")
  return bits.join(" · ")
}

function networkDescription(d) {
  if (!d || !d.ssid) return "not on Wi-Fi - wired and offline are left alone"
  var manual = d.manual ? " · automation paused here (you switched by hand)" : ""
  if (d.trusted) return "trusted" + (d.autodisconnect && !d.manual ? " · the tunnel drops here by itself" : "") + manual
  return "untrusted" + (d.autoconnect && !d.manual ? " · the tunnel comes up here by itself" : "") + manual
}

function killswitchDescription(d) {
  if (!d) return ""
  if (d.killswitch === "disabled") return "off: profiles, watchdog and icon work as usual, nothing is ever blocked"
  if (d.killswitch === "unloaded") return "NOT LOADED: no table, nothing is blocked - no profile yet, or the unit was stopped (sudo systemctl start vpn-killswitch)"
  if (d.state === "connected") return "on: only the tunnel and the handshake to the VPN servers may leave"
  if (d.state === "down" || d.state === "stalled") return "holding: no tunnel, nothing leaves until it is back or you say off"
  if (d.killswitch === "on") return "on: the uplink is shut, only the tunnel and the handshake may leave"
  return "open: this network is trusted or released, traffic flows outside the tunnel"
}

function barTooltip(d, rates) {
  if (!d) return "tun0 VPN"
  var lines = []
  switch (d.state) {
    case "connected":
      lines.push(d.label + " (" + d.active + "), kill switch " + ksWord(d))
      if (rates) lines.push("↓ " + fmtRate(rates.rx) + "  ↑ " + fmtRate(rates.tx))
      break
    case "connecting": lines.push("Connecting to " + d.label + " (" + d.want + ")"); break
    case "stalled": lines.push("Tunnel stalled - " + d.label + " (" + d.active + "): the uplink lost its link or the server is not answering, OpenVPN keeps restarting. Nothing flows until it is back."); break
    case "down": lines.push("VPN down - " + (d.killswitch === "disabled" ? "kill switch DISABLED" : d.killswitch === "unloaded" ? "kill switch NOT LOADED" : "kill switch is blocking") + ", watchdog retrying " + d.want); break
    default: lines.push("VPN off" + (d["default"] ? " (default: " + d["default"] + ")" : "") + (d.killswitch === "disabled" ? " · kill switch disabled" : ""))
  }
  if (d.ssid) lines.push("Wi-Fi " + d.ssid + " · " + (d.trusted ? "trusted" : "untrusted"))
  lines.push("Click: panel · Right-click: " + (d.state === "off" ? "connect" : "disconnect") + " · Middle: refresh")
  return lines.join("\n")
}
