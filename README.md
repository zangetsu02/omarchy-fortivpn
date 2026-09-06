# FortiVPN

FortiClient VPN status in the Omarchy bar: connection state, assigned IP,
uptime and traffic, with one-click disconnect and a shortcut into the login.

## Why Connect opens the GUI

The work VPN authenticates through SAML/SSO against Microsoft Entra ID: a
browser opens, you sign in, and Microsoft Authenticator confirms the number.
That flow belongs to the FortiClient GUI and tray — `fortitray` is the
component holding the `xdg-open` call, and the daemon owns the
`/remote/saml/login` endpoints.

The `fortivpn` CLI has no part in it. Its only auth flags are `--username`,
`--password` and `--save-password`, and an SSO profile is not even visible to
`fortivpn list` — the profile lives in the GUI's store. So a bar widget cannot
raise this tunnel by itself, and this one does not pretend to: **Connect hands
off to the GUI**, and the widget starts polling briskly so the icon turns the
moment the login lands.

Disconnect is different: `fortivpn disconnect` works fine against an SSO
tunnel, so it runs straight from the bar.

## The four states

FortiClient's naming is not self-evident, and `Model.js` maps it:

| CLI reports | Widget shows | Notes |
|---|---|---|
| `Connected` | Connesso | Filled shield |
| `Connecting` | Connessione… | Shield breathes |
| `Not Running` | Disconnesso | The normal idle state |
| `Disconnected` | Disconnesso | Only flashes by during teardown |

## Controls

| Action | Mouse | Keyboard (panel open) |
|---|---|---|
| Open the panel | Left click | — |
| Connect / disconnect | Right click | `Enter`, or `c` / `d` |
| Refresh now | Middle click | `r` |

## Settings

Configured per widget in `~/.config/omarchy/shell.json`, or through the bar's
widget settings UI.

| Key | Default | Meaning |
|---|---|---|
| `refreshIntervalSec` | `5` | Poll interval. The duration counter ticks locally between polls. |
| `hideWhenDisconnected` | `false` | Hide the icon while the tunnel is down. |
| `notifyOnDrop` | `true` | Notify on an unrequested drop. A disconnect you asked for stays silent. |
| `notifyOnConnect` | `false` | Notify when the tunnel comes up. |
| `cliPath` | `""` | Path to `fortivpn`; empty means look on `PATH`. |
| `guiCommand` | `/opt/forticlient/gui/FortiClient` | What Connect launches. |

## IPC

```bash
omarchy-shell fortivpn status      # current state label
omarchy-shell fortivpn refresh     # poll now
omarchy-shell fortivpn connect     # open the GUI for the SSO login
omarchy-shell fortivpn disconnect  # tear the tunnel down
omarchy-shell fortivpn toggle      # open/close the panel
```

## Files

| File | Role |
|---|---|
| `manifest.json` | Plugin metadata and settings schema |
| `Model.js` | Parses `fortivpn status`; formats bytes and durations |
| `Service.qml` | Polling, disconnect, GUI handoff, drop notifications |
| `Panel.qml` | Bar icon and panel |
| `FortiVpnIcon.qml` | Shield glyph, filled when protected |

## Requirements

`forticlient-vpn` (AUR). The `forticlient.service` system unit must be running
for `fortivpn` to answer at all.
