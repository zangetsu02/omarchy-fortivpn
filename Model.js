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
    durationSec: -1
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
    }
  }
  return status
}

function stateLabel(state) {
  if (state === STATE_CONNECTED) return "Connesso"
  if (state === STATE_CONNECTING) return "Connessione…"
  if (state === STATE_DISCONNECTED) return "Disconnesso"
  if (state === STATE_UNAVAILABLE) return "Non disponibile"
  return "Sconosciuto"
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
