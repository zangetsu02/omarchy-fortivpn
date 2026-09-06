import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "zangetsu.fortivpn"
  ipcTarget: "fortivpn"
  manageIpc: false

  readonly property bool hideWhenDisconnected: setting("hideWhenDisconnected", false) === true
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool up: vpn.connected
  readonly property bool pending: vpn.connecting || vpn.busy
  // Connecting sits between the two: lit like a live tunnel, but hollow,
  // because nothing is protected yet.
  readonly property color barIconColor: up || vpn.connecting ? barForeground : Qt.darker(barForeground, 1.55)

  readonly property string title: vpn.vpnName !== "" ? vpn.vpnName : "FortiVPN"
  readonly property string heroMeta: {
    if (!vpn.installed) return "CLI non trovata"
    if (vpn.connected) return vpn.liveDurationSec >= 0
      ? "Connesso · " + Model.secondsToDuration(vpn.liveDurationSec)
      : "Connesso"
    return vpn.stateLabel
  }
  readonly property string actionLabel: vpn.connected ? "Disconnetti" : "Connetti"
  readonly property string actionHint: {
    if (vpn.connected) return "Chiude il tunnel"
    return vpn.canConnectDirectly
      ? "Avvia il tunnel e apre il login nel browser"
      : "Apre FortiClient per il login"
  }

  visible: !hideWhenDisconnected || vpn.connected || vpn.connecting
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Service {
    id: vpn
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { vpn.refresh(); return "ok" }
    function disconnect(): string { vpn.disconnect(); return "ok" }
    function connect(): string { vpn.connect(); return "ok" }
    function backend(): string { return vpn.backend }
    function status(): string { return vpn.stateLabel }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        FortiVpnIcon {
          anchors.centerIn: parent
          iconSize: Style.space(12)
          color: root.barIconColor
          filled: vpn.connected
          crossed: vpn.disconnected || vpn.state === Model.STATE_UNAVAILABLE

          // A slow breath while the tunnel is coming up, so "connecting" is
          // legible without a second glyph. The animation drives `pulse`
          // rather than `opacity`, so it never fights the steady-state value.
          property real pulse: 1.0
          opacity: vpn.connecting ? pulse : 1.0

          SequentialAnimation on pulse {
            running: vpn.connecting
            loops: Animation.Infinite
            NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
          }
        }
      }
    }
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) vpn.toggle()
      else if (buttonCode === Qt.MiddleButton) vpn.refresh()
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
    contentWidth: panel.fittedContentWidth(Style.space(300))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(460))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onActivateRequested: vpn.toggle()
      onTextKey: function (t) {
        if (t === "d" || t === "D") vpn.disconnect()
        else if (t === "c" || t === "C") vpn.connect()
        else if (t === "r" || t === "R") vpn.refresh()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        PanelHero {
          id: hero
          width: parent.width
          title: root.title
          meta: root.heroMeta
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.up ? 1.0 : 0.5
          iconComponent: Component {
            FortiVpnIcon {
              iconSize: Style.font.display
              color: root.up ? root.foreground : root.dim
              filled: vpn.connected
              crossed: vpn.disconnected || vpn.state === Model.STATE_UNAVAILABLE
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: vpn.actionStatus !== "" || vpn.lastError !== ""
          width: parent.width
          text: vpn.actionStatus !== "" ? vpn.actionStatus : vpn.lastError
          color: vpn.lastError !== "" && vpn.actionStatus === "" ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // Details exist only while a tunnel does; an empty table would be noise.
        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: vpn.connected

          InfoRow { label: "IP"; value: vpn.ip }
          InfoRow { label: "Utente"; value: vpn.username }
          InfoRow {
            label: "Traffico"
            value: "↑ " + Model.formatBytes(vpn.sentBytes) + "   ↓ " + Model.formatBytes(vpn.recvBytes)
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: !vpn.connected && vpn.installed
          width: parent.width
          text: {
            if (vpn.connecting) return "Tunnel in salita. Completa il login nel browser."
            return vpn.canConnectDirectly
              ? "Connetti apre il login nel browser: account Microsoft e conferma sull'app Authenticator."
              : "Il login passa da FortiClient: account Microsoft e conferma sull'app Authenticator."
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          textFormat: Text.PlainText
          visible: !vpn.installed && vpn.checkedInstall
          width: parent.width
          text: "Nessun backend raggiungibile: né la CLI fortivpn nel PATH, né un'unit openfortivpn. Controlla le impostazioni del widget."
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Button {
          width: parent.width
          visible: vpn.installed
          text: root.actionLabel
          tooltipText: root.actionHint
          enabled: !vpn.busy
          bordered: true
          foreground: root.foreground
          accent: vpn.connected ? root.urgent : Color.accent
          fontFamily: root.fontFamily
          onClicked: vpn.toggle()
        }
      }
    }
  }

  component InfoRow: Item {
    id: infoRow
    property string label: ""
    property string value: ""

    width: parent ? parent.width : 0
    implicitHeight: Math.max(labelText.implicitHeight, valueText.implicitHeight) + Style.space(5)
    visible: infoRow.value !== ""

    Text {
      id: labelText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: infoRow.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: valueText
      anchors.right: parent.right
      anchors.left: labelText.right
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: infoRow.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideMiddle
    }
  }
}
