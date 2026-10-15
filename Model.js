.pragma library

// FortiClient reports four distinct states, and the naming is not obvious:
// an idle tunnel is "Not Running", while "Disconnected" only flashes by while
// one is being torn down. Both mean the same thing to a user looking at a bar.
var STATE_UNKNOWN = 0
var STATE_UNAVAILABLE = 1
var STATE_DISCONNECTED = 2
var STATE_CONNECTING = 3
var STATE_CONNECTED = 4

function defaultStatus() {
  return {
    state: STATE_UNKNOWN,
    rawState: "",
    vpnName: "",
    username: "",
    ip: "",
    sentBytes: -1,
    recvBytes: -1,
    duration: "",
    durationSec: -1,
    // Why a tunnel cannot come up, when the backend knows. Empty means either
    // all is well or the backend has nothing to say.
    error: ""
  }
}

function normalizeState(raw) {
  var s = String(raw || "").trim().toLowerCase()
  if (s === "connected") return STATE_CONNECTED
  if (s === "connecting") return STATE_CONNECTING
  if (s === "not running" || s === "disconnected") return STATE_DISCONNECTED
  return STATE_UNKNOWN
}

function toNumber(value) {
  var n = parseInt(String(value || "").replace(/[^0-9-]/g, ""), 10)
  return isFinite(n) ? n : -1
}

// "00:01:25" -> 85. Returns -1 for anything that is not a duration, so the
// caller can tell "no value" from "zero seconds".
function durationToSeconds(text) {
  var parts = String(text || "").trim().split(":")
  if (parts.length !== 3) return -1
  var h = parseInt(parts[0], 10)
  var m = parseInt(parts[1], 10)
  var s = parseInt(parts[2], 10)
  if (!isFinite(h) || !isFinite(m) || !isFinite(s)) return -1
  return h * 3600 + m * 60 + s
}

function secondsToDuration(total) {
  var n = Math.max(0, Math.floor(Number(total) || 0))
  var h = Math.floor(n / 3600)
  var m = Math.floor((n % 3600) / 60)
  var s = n % 60
  return pad2(h) + ":" + pad2(m) + ":" + pad2(s)
}

function pad2(n) {
  return (n < 10 ? "0" : "") + n
}

// The CLI prints "Status: X" followed by indented "Key: value" lines, and
// omits every detail line while the tunnel is down.
function parseStatus(raw) {
  var status = defaultStatus()
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "") continue
    var sep = line.indexOf(":")
    if (sep < 0) continue
    var key = line.substring(0, sep).trim().toLowerCase()
    // Everything past the first colon, so an IPv6 address survives intact.
    var value = line.substring(sep + 1).trim()
    if (key === "status") {
      status.rawState = value
      status.state = normalizeState(value)
    } else if (key === "vpn name") {
      status.vpnName = value
    } else if (key === "username") {
      status.username = value
    } else if (key === "ip") {
      status.ip = value
    } else if (key === "sent bytes") {
      status.sentBytes = toNumber(value)
    } else if (key === "recv bytes") {
      status.recvBytes = toNumber(value)
    } else if (key === "duration") {
      status.duration = value
      status.durationSec = durationToSeconds(value)
    } else if (key === "error") {
      status.error = value
    }
  }
  return status
}

// Profile discovery prints "<name><TAB><saml-url>" per line, because a profile
// is no more than that: a systemd instance and the login page it belongs to.
// The URL is empty for a profile set up before the drop-in recorded one.
function parseProfiles(raw) {
  var profiles = []
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "") continue
    var tab = line.indexOf("\t")
    var name = (tab < 0 ? line : line.substring(0, tab)).trim()
    if (name === "") continue
    profiles.push({ name: name, samlUrl: tab < 0 ? "" : line.substring(tab + 1).trim() })
  }
  return profiles
}

// Checks a new profile before its values are handed to a shell. Returns the
// reason it cannot be used, or "" when it can. The shapes are deliberately
// narrow: setup-openfortivpn receives these as words in a command line, so
// anything looser than this would be an injection rather than a typo.
function profileFormError(name, gateway, port) {
  if (!/^[A-Za-z0-9_-]+$/.test(String(name || "")))
    return "Name: letters, digits, dash and underscore only."
  if (!/^[A-Za-z0-9.-]+$/.test(String(gateway || "")))
    return "Gateway: a host name, with no scheme and no path."
  var p = String(port || "")
  if (!/^[0-9]{1,5}$/.test(p) || parseInt(p, 10) < 1 || parseInt(p, 10) > 65535)
    return "Port: a number between 1 and 65535."
  return ""
}

// The gateway a profile points at, read back out of its recorded login URL.
// It is the only place the widget can get it from: the config that holds it is
// root-only, so a profile whose drop-in records no URL reports empty fields.
function gatewayFromSamlUrl(url) {
  var match = /^https?:\/\/([A-Za-z0-9.-]+)(?::([0-9]{1,5}))?/.exec(String(url || ""))
  if (!match) return { host: "", port: "" }
  return { host: match[1], port: match[2] || "" }
}

function stateLabel(state) {
  if (state === STATE_CONNECTED) return "Connected"
  if (state === STATE_CONNECTING) return "Connecting…"
  if (state === STATE_DISCONNECTED) return "Disconnected"
  if (state === STATE_UNAVAILABLE) return "Unavailable"
  return "Unknown"
}

function formatBytes(bytes) {
  var n = Number(bytes)
  if (!isFinite(n) || n < 0) return "—"
  if (n < 1024) return n + " B"
  var units = ["KB", "MB", "GB", "TB"]
  var value = n / 1024
  var unit = 0
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024
    unit++
  }
  // One decimal below 10 keeps the column narrow without losing resolution.
  return (value < 10 ? value.toFixed(1) : Math.round(value)) + " " + units[unit]
}
