import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})

  property bool installed: false
  property bool checkedInstall: false
  property int state: Model.STATE_UNKNOWN
  property string rawState: ""
  property string vpnName: ""
  property string username: ""
  property string ip: ""
  property int sentBytes: -1
  property int recvBytes: -1
  property int durationSec: -1
  property string lastError: ""
  property string actionStatus: ""

  readonly property bool connected: state === Model.STATE_CONNECTED
  readonly property bool connecting: state === Model.STATE_CONNECTING
  readonly property bool disconnected: state === Model.STATE_DISCONNECTED
  readonly property bool busy: statusProcess.running || disconnectProcess.running
  readonly property string stateLabel: Model.stateLabel(state)

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 5, 2, 300)
  readonly property string cliPath: String(setting("cliPath", "") || "fortivpn")
  readonly property string guiCommand: String(setting("guiCommand", "") || "/opt/forticlient/gui/FortiClient")
  readonly property bool notifyOnDrop: setting("notifyOnDrop", true) === true
  readonly property bool notifyOnConnect: setting("notifyOnConnect", false) === true

  // The CLI reports whole seconds only at poll time, so the panel would show a
  // duration frozen between polls. Ticking locally keeps the counter alive and
  // every successful poll resnaps it to the truth.
  property int _tickOffset: 0
  readonly property int liveDurationSec: durationSec < 0 ? -1 : durationSec + _tickOffset

  property int _prevState: Model.STATE_UNKNOWN
  // A disconnect you asked for is not a dropped tunnel, so it must not notify.
  property bool _userDisconnecting: false
  // One failed poll is not a broken client: a reload can destroy a call in
  // flight, and the watchdog reaps a slow one. Only a run of failures means
  // the CLI is really gone, so the last known state survives a single blip.
  readonly property int failuresBeforeUnavailable: 3
  property int _consecutiveFailures: 0
  property string _statusOutput: ""
  property string _statusError: ""
  property string _disconnectError: ""

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function notify(title, body, urgency) {
    Quickshell.execDetached(["notify-send", "-a", "FortiVPN",
                             "-u", String(urgency || "normal"),
                             String(title), String(body || "")])
  }

  function checkInstalled() {
    if (whichProcess.running) return
    whichProcess.command = ["which", root.cliPath]
    whichProcess.running = true
  }

  function refresh() {
    if (!installed) {
      if (!checkedInstall) checkInstalled()
      return
    }
    if (statusProcess.running) return
    _statusOutput = ""
    _statusError = ""
    statusProcess.command = [root.cliPath, "status"]
    statusProcess.running = true
    // A status call that never returns would silently freeze every later poll,
    // because each one is skipped while the previous is still running.
    if (!pollWatchdog.running) pollWatchdog.restart()
  }

  function applyStatus(parsed) {
    state = parsed.state
    rawState = parsed.rawState
    vpnName = parsed.vpnName
    username = parsed.username
    ip = parsed.ip
    sentBytes = parsed.sentBytes
    recvBytes = parsed.recvBytes
    durationSec = parsed.durationSec
    _tickOffset = 0
    lastError = ""
    announceTransition(parsed.state)
  }

  function announceTransition(next) {
    var prev = _prevState
    _prevState = next
    if (prev === next) return
    if (next === Model.STATE_CONNECTED && prev !== Model.STATE_UNKNOWN && notifyOnConnect) {
      notify("VPN connessa", (vpnName || "FortiClient") + " — " + (ip || ""), "low")
      return
    }
    // Only a fall from a tunnel that was actually up counts as a drop, and only
    // when nobody asked for it.
    if (next === Model.STATE_DISCONNECTED && prev === Model.STATE_CONNECTED) {
      if (_userDisconnecting) {
        _userDisconnecting = false
        return
      }
      if (notifyOnDrop) notify("VPN caduta", (vpnName || "FortiClient") + " si è disconnessa.", "critical")
    }
  }

  function markUnavailable(message) {
    state = Model.STATE_UNAVAILABLE
    rawState = ""
    vpnName = ""
    username = ""
    ip = ""
    sentBytes = -1
    recvBytes = -1
    durationSec = -1
    _tickOffset = 0
    _prevState = Model.STATE_UNAVAILABLE
    lastError = String(message || "")
  }

  function setActionStatus(text) {
    actionStatus = String(text || "")
    if (actionStatus !== "") actionStatusTimer.restart()
  }

  // SAML/SSO login runs in the GUI's own browser flow; the CLI has no SSO path
  // and cannot even see an SSO profile in `fortivpn list`. So Connect hands off
  // to the GUI rather than pretending the tunnel can be raised from here.
  function connectViaGui() {
    if (guiCommand === "") {
      setActionStatus("Nessun comando GUI configurato")
      return
    }
    Quickshell.execDetached(["bash", "-c", guiCommand + " >/dev/null 2>&1 &"])
    setActionStatus("Apro FortiClient per il login")
    // The tunnel will not be up for a while, but poll sooner so the icon turns
    // the moment the login completes.
    loginRamp.ticks = 0
    loginRamp.running = true
  }

  function disconnect() {
    if (!installed || disconnectProcess.running) return
    _userDisconnecting = true
    _disconnectError = ""
    disconnectProcess.command = [root.cliPath, "disconnect"]
    disconnectProcess.running = true
    setActionStatus("Disconnessione…")
  }

  function toggle() {
    if (connected) disconnect()
    else connectViaGui()
  }

  Process {
    id: whichProcess
    running: false
    command: []
    onExited: function (exitCode) {
      root.checkedInstall = true
      root.installed = exitCode === 0
      if (root.installed) root.refresh()
      else root.markUnavailable("La CLI fortivpn non è installata o non è nel PATH.")
    }
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true; onStreamFinished: root._statusOutput = text }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true; onStreamFinished: root._statusError = text }
    onExited: function (exitCode) {
      pollWatchdog.stop()
      var out = String(statusStdout.text || root._statusOutput || "")
      var err = String(statusStderr.text || root._statusError || "")
      if (exitCode !== 0) {
        root._consecutiveFailures += 1
        root.lastError = err.trim() || "fortivpn status è uscito con codice " + exitCode
        if (root._consecutiveFailures >= root.failuresBeforeUnavailable) root.markUnavailable(root.lastError)
        return
      }
      root._consecutiveFailures = 0
      root.applyStatus(Model.parseStatus(out))
    }
  }

  Process {
    id: disconnectProcess
    running: false
    command: []
    stderr: StdioCollector { id: disconnectStderr; waitForEnd: true; onStreamFinished: root._disconnectError = text }
    onExited: function (exitCode) {
      if (exitCode === 0) {
        root.setActionStatus("Disconnessa")
      } else {
        // The flag would otherwise swallow the drop notification for a teardown
        // that never happened.
        root._userDisconnecting = false
        root.setActionStatus("Disconnessione fallita")
        root.lastError = String(disconnectStderr.text || root._disconnectError || "").trim()
      }
      root.refresh()
    }
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    // Keeps the duration counter moving between polls.
    id: secondTick
    interval: 1000
    repeat: true
    running: root.connected
    onTriggered: root._tickOffset += 1
  }

  Timer {
    // After the GUI login lands, poll briskly for a couple of minutes so the
    // bar reflects the new tunnel immediately instead of at the next slow tick.
    id: loginRamp
    property int ticks: 0
    interval: 3000
    repeat: true
    running: false
    onTriggered: {
      ticks += 1
      if (root.connected || ticks >= 40) loginRamp.running = false
      else root.refresh()
    }
  }

  Timer {
    id: pollWatchdog
    interval: 10000
    repeat: false
    onTriggered: if (statusProcess.running) statusProcess.running = false
  }

  Timer {
    id: actionStatusTimer
    interval: 2600
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Component.onCompleted: checkInstalled()
}
