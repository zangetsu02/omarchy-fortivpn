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
  // Connecting sits between the two: lit like a live tunnel, but hollow,
  // because nothing is protected yet.
  readonly property color barIconColor: up || vpn.connecting ? barForeground : Qt.darker(barForeground, 1.55)

  // The profile is the headline: on a machine with several VPNs, which one the
  // bar is watching matters more than the name of the widget.
  readonly property string title: {
    if (vpn.activeProfile !== "") return vpn.activeProfile
    return vpn.vpnName !== "" ? vpn.vpnName : "FortiVPN"
  }
  readonly property string heroMeta: {
    if (!vpn.installed) return "No backend"
    if (vpn.connected) return vpn.liveDurationSec >= 0
      ? "Connected · " + Model.secondsToDuration(vpn.liveDurationSec)
      : "Connected"
    return vpn.stateLabel
  }
  readonly property string actionLabel: vpn.connected ? "Disconnect" : "Connect"
  readonly property string actionHint: {
    if (vpn.connected) return "Closes the tunnel"
    return vpn.canConnectDirectly
      ? "Starts the tunnel and opens the login in your browser"
      : "Opens FortiClient for the login"
  }

  // One line, and only the one that applies: an action being carried out wins
  // over a failure, a failure wins over advice nobody needs twice.
  readonly property string notice: {
    // While the form is up it is the only thing being talked about; the
    // tunnel's last failure is not what you are reading right now.
    if (formOpen) return formError
    if (vpn.actionStatus !== "") return vpn.actionStatus
    if (formError !== "") return formError
    if (vpn.lastError !== "") return vpn.lastError
    if (!vpn.installed && vpn.checkedInstall)
      return "No backend reachable: neither the fortivpn CLI nor an openfortivpn unit."
    if (vpn.connecting) return "Finish the login in your browser."
    if (!vpn.connected) return vpn.canConnectDirectly
      ? "Connect opens the login in your browser."
      : "Connect opens FortiClient for the login."
    return ""
  }
  readonly property bool noticeIsBad: formOpen
    ? formError !== ""
    : vpn.actionStatus === ""
      && (formError !== "" || vpn.lastError !== "" || (!vpn.installed && vpn.checkedInstall))

  // Ships next to this file, so the path follows the plugin wherever it lives.
  readonly property string setupScript: String(Qt.resolvedUrl("scripts/setup-openfortivpn")).replace(/^file:\/\//, "")

  property bool profilesExpanded: false
  // The form is the same whether a profile is being created or changed, because
  // setup-openfortivpn overwrites its own files: editing is creating again with
  // the name kept. Empty formProfile means a new one.
  property bool formOpen: false
  property string formProfile: ""
  property string formError: ""
  readonly property bool editing: formOpen && formProfile !== ""

  property string removeTarget: ""

  // Ships next to this file, so the path follows the plugin wherever it lives.
  readonly property string removeScript: String(Qt.resolvedUrl("scripts/remove-openfortivpn")).replace(/^file:\/\//, "")

  visible: !hideWhenDisconnected || vpn.connected || vpn.connecting
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // A profile added after the shell started would otherwise stay invisible, and
  // opening the panel is exactly when the list gets looked at. Closing resets
  // the disclosures so the panel always reopens on the state that matters.
  onOpenedChanged: {
    if (opened) {
      vpn.listProfiles()
    } else {
      profilesExpanded = false
      formOpen = false
      formError = ""
    }
  }

  Service {
    id: vpn
    settings: root.settings
    onProfileSelected: function (name) { root.persistProfile(name) }
  }

  // The live choice belongs to the service, so this write only decides whether
  // it outlives the session. With no writable entry — the widget is not in the
  // layout — the profile stays selected until the shell restarts.
  function persistProfile(name) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.activeProfile = name
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function closeForm() {
    formOpen = false
    formProfile = ""
    formError = ""
    keyCatcher.forceActiveFocus()
  }

  function pickProfile(name) {
    vpn.selectProfile(name)
    profilesExpanded = false
  }

  // Creating a profile writes to /etc and installs a polkit rule, so it is root
  // work the widget cannot do itself. Handing the prepared command to a terminal
  // keeps the password where it belongs and leaves the script's output on screen.
  function submitProfile() {
    var name = editing ? formProfile : String(nameField.text).trim()
    var gateway = String(gatewayField.text).trim()
    var port = String(portField.text).trim() === "" ? "10443" : String(portField.text).trim()

    // Validated before it reaches a shell: the launcher joins its arguments and
    // runs them through bash, so a loose value here would be an injection.
    formError = Model.profileFormError(name, gateway, port)
    if (formError !== "") return

    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
                             "sudo '" + root.setupScript + "' " + name + " " + gateway + " " + port])
    vpn.setActionStatus((editing ? "Updating " : "Creating ") + name + " in a terminal")
    closeForm()
    root.close()
  }

  // Removing writes nothing the widget could undo, so it asks first and then
  // hands the job to the same kind of terminal the setup uses.
  function askRemoveProfile(name) {
    removeTarget = String(name || "")
  }

  function removeProfile() {
    var name = removeTarget
    removeTarget = ""
    if (name === "") return
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
                             "sudo '" + root.removeScript + "' " + name])
    vpn.setActionStatus("Removing " + name + " in a terminal")
    root.close()
  }

  function startAddingProfile() {
    openForm("", "", "10443")
  }

  // Gateway and port are read back from the profile's recorded login URL; a
  // profile set up before that was written opens with them blank, which the
  // form says rather than guessing.
  function startEditingProfile(name) {
    var profile = vpn.profileFor(name)
    var gateway = Model.gatewayFromSamlUrl(profile ? profile.samlUrl : "")
    openForm(name, gateway.host, gateway.port === "" ? "10443" : gateway.port)
  }

  function openForm(profile, gateway, port) {
    formProfile = profile
    nameField.text = profile
    gatewayField.text = gateway
    portField.text = port
    formError = ""
    formOpen = true
    profilesExpanded = false
    // Focus lands only once the field is really there, which is after this
    // function returns — the same deferral the clock panel's form uses.
    Qt.callLater(function () {
      if (!root.formOpen) return
      // The name is fixed while editing, so the first thing worth typing is
      // the gateway.
      if (root.editing) gatewayField.focusInput()
      else nameField.focusInput()
    })
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
    function profiles(): string { return vpn.profileNames.join("\n") }
    function profile(name: string): string { vpn.selectProfile(name); return vpn.activeProfile }
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
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    ConfirmDialog {
      id: removeConfirm
      anchors.fill: parent
      z: 10
      opened: root.removeTarget !== ""
      message: "Remove the " + root.removeTarget + " profile? Its config, systemd drop-in and polkit rule are deleted."
      confirmText: "Remove"
      background: root.bar ? root.bar.background : Color.background
      foreground: root.foreground
      fontFamily: root.fontFamily
      onConfirmed: root.removeProfile()
      onCanceled: root.removeTarget = ""
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The form owns the keyboard while it is up: without this the shortcuts
      // would eat the typing, and Return would toggle the tunnel instead of
      // submitting. The fields handle Escape themselves.
      blocked: root.formOpen
      onCloseRequested: {
        if (root.removeTarget !== "") root.removeTarget = ""
        else root.close()
      }
      onTabRequested: function (direction) { root.switchPanel(direction) }
      // The dialog owns Enter, Escape and the arrows while it is up; answering
      // it with the panel's ordinary keys would toggle the tunnel behind it.
      onActivateRequested: {
        if (root.removeTarget === "") vpn.toggle()
        else if (removeConfirm.selectedIndex === 1) root.removeProfile()
        else root.removeTarget = ""
      }
      onMoveRequested: function (dx, dy) {
        if (root.removeTarget !== "" && dy !== 0)
          removeConfirm.selectedIndex = removeConfirm.selectedIndex === 1 ? 0 : 1
      }
      onDeleteRequested: if (vpn.activeProfile !== "") root.askRemoveProfile(vpn.activeProfile)
      onTextKey: function (t) {
        if (t === "d" || t === "D") vpn.disconnect()
        else if (t === "c" || t === "C") vpn.connect()
        else if (t === "r" || t === "R") vpn.refresh()
        else if (t === "p" || t === "P") root.profilesExpanded = !root.profilesExpanded
        else if (t === "a" || t === "A") root.startAddingProfile()
        else if ((t === "e" || t === "E") && vpn.activeProfile !== "") root.startEditingProfile(vpn.activeProfile)
        else if (t >= "1" && t <= "9") {
          var index = parseInt(t, 10) - 1
          if (index < vpn.profileNames.length) root.pickProfile(vpn.profileNames[index])
        }
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
          // The profile list hangs off the headline it belongs to, rather than
          // sitting as one more control competing with the connect button.
          trailingControl: Component {
            PanelActionButton {
              visible: vpn.usesOpenfortivpn
              iconText: root.profilesExpanded ? "󰅃" : "󰅀"
              tooltipText: root.profilesExpanded ? "Hide profiles" : "Switch profile"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.profilesExpanded = !root.profilesExpanded
            }
          }
        }

        // --- Profiles -----------------------------------------------------

        Column {
          width: parent.width
          spacing: Style.space(1)
          visible: root.profilesExpanded && !root.formOpen

          Repeater {
            model: vpn.profiles
            ProfileRow {
              name: modelData.name
              current: modelData.name === vpn.activeProfile
              actionable: true
              onPicked: root.pickProfile(modelData.name)
              onEditRequested: root.startEditingProfile(modelData.name)
              onRemoveRequested: root.askRemoveProfile(modelData.name)
            }
          }

          Item { width: 1; height: Style.space(4) }

          PanelSeparator { foreground: root.foreground }

          Item { width: 1; height: Style.space(4) }

          ProfileRow {
            name: "Add profile…"
            glyph: "+"
            onPicked: root.startAddingProfile()
          }
        }

        // --- New profile form ---------------------------------------------

        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.formOpen

          FormField {
            id: nameField
            label: "Name"
            placeholderText: "work"
            // Renaming would create a second profile beside the first, not move
            // it, so an edit keeps the name it was opened with.
            enabled: !root.editing
          }

          FormField {
            id: gatewayField
            label: "Gateway"
            placeholderText: "vpn.example.com"
          }

          FormField {
            id: portField
            label: "Port"
            placeholderText: "10443"
          }

          Item { width: 1; height: Style.space(2) }

          Row {
            width: parent.width
            spacing: Style.space(8)

            Button {
              width: (parent.width - Style.space(8)) / 2
              text: "Cancel"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.closeForm()
            }

            Button {
              width: (parent.width - Style.space(8)) / 2
              text: root.editing ? "Save" : "Create"
              tooltipText: "Runs the setup script in a terminal, which will ask for your password"
              bordered: true
              foreground: root.foreground
              accent: Color.accent
              fontFamily: root.fontFamily
              onClicked: root.submitProfile()
            }
          }
        }

        PanelSeparator {
          foreground: root.foreground
          visible: root.notice !== "" || detailRows.visible
        }

        Text {
          textFormat: Text.PlainText
          visible: root.notice !== ""
          width: parent.width
          text: root.notice
          color: root.noticeIsBad ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // Details exist only while a tunnel does; an empty table would be noise.
        Column {
          id: detailRows
          width: parent.width
          spacing: Style.space(2)
          visible: vpn.connected && !root.formOpen

          InfoRow { label: "IP"; value: vpn.ip }
          InfoRow { label: "User"; value: vpn.username }
          InfoRow {
            label: "Traffic"
            value: "↑ " + Model.formatBytes(vpn.sentBytes) + "   ↓ " + Model.formatBytes(vpn.recvBytes)
          }
        }

        Button {
          width: parent.width
          visible: vpn.installed && !root.formOpen
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

  // A profile in the list: the active one is marked, the rest are one click
  // away. Doubles as the "Add profile…" entry, which behaves the same way.
  component ProfileRow: Item {
    id: profileRow
    property string name: ""
    property bool current: false
    property bool actionable: false
    property string glyph: current ? "●" : "○"
    signal picked()
    signal editRequested()
    signal removeRequested()

    width: parent ? parent.width : 0
    implicitHeight: rowLabel.implicitHeight + Style.space(9)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: rowHover.containsMouse
        ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
        : "transparent"
    }

    Text {
      id: rowGlyph
      anchors.left: parent.left
      anchors.leftMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      text: profileRow.glyph
      color: profileRow.current ? Color.accent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: rowLabel
      anchors.left: rowGlyph.right
      anchors.leftMargin: Style.space(8)
      anchors.right: rowActions.visible ? rowActions.left : parent.right
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: profileRow.name
      color: profileRow.current ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    MouseArea {
      id: rowHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: profileRow.picked()
    }

    // Kept on the row rather than behind a hover, so nothing moves under the
    // pointer and both actions stay findable without hunting for them.
    Row {
      id: rowActions
      visible: profileRow.actionable
      anchors.right: parent.right
      anchors.rightMargin: Style.space(2)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      PanelActionButton {
        iconText: "󰏫"
        tooltipText: "Change the gateway of " + profileRow.name
        fontSize: Style.font.bodySmall
        foreground: rowHover.containsMouse ? root.foreground : root.dim
        fontFamily: root.fontFamily
        onClicked: profileRow.editRequested()
      }

      PanelActionButton {
        iconText: "󰩹"
        tooltipText: "Remove " + profileRow.name
        fontSize: Style.font.bodySmall
        foreground: rowHover.containsMouse ? root.foreground : root.dim
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        onClicked: profileRow.removeRequested()
      }
    }
  }

  // Label above the input, the shape the kit's own forms use.
  component FormField: Column {
    id: formField
    property alias text: input.text
    property alias placeholderText: input.placeholderText
    property string label: ""

    width: parent ? parent.width : 0
    spacing: Style.space(3)

    function focusInput() { input.forceActiveFocus() }

    Text {
      textFormat: Text.PlainText
      text: formField.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    TextField {
      id: input
      width: parent.width
      foreground: root.foreground
      onAccepted: root.submitProfile()
      Keys.onEscapePressed: root.closeForm()
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
