# FortiVPN

Fortinet SSL VPN status in the Omarchy bar: connection state, assigned IP,
uptime and traffic, with connect and disconnect from the panel.

Two backends, one widget. Which one you get decides whether connecting is one
click or a handoff to a GUI.

| | FortiClient | openfortivpn |
|---|---|---|
| Status | `fortivpn status` | systemd unit + ppp interface |
| Connect | opens the FortiClient GUI | starts the unit, opens the login page |
| Disconnect | `fortivpn disconnect` | stops the unit |
| Needs root | no | yes, via a scoped polkit rule |

## Why FortiClient cannot connect from the bar

When the VPN authenticates through SAML/SSO — an Entra ID login in a browser,
confirmed in an authenticator app — that flow belongs to the FortiClient GUI
and tray. `fortitray` holds the `xdg-open` call and the daemon owns the
`/remote/saml/login` endpoints.

The `fortivpn` CLI has no part in it. Its only auth flags are `--username`,
`--password` and `--save-password`, and an SSO profile is not even visible to
`fortivpn list` — the profile lives in the GUI's store. FortiClient's internal
IPC is nanomsg over sockets with hashed names, which is not something to build
on.

So with this backend, **Connect hands off to the GUI**, and the widget starts
polling briskly so the icon turns the moment the login lands.

openfortivpn reimplements the same protocol and exposes that login as
`--saml-login`, which is why it can do the whole thing from the bar.

## One parser, two backends

Both backends report through `Model.js`, because
[`scripts/openfortivpn-status`](scripts/openfortivpn-status) prints the same
`Key: value` shape that `fortivpn status` does:

```
Status: Connected
VPN name: work
IP: 10.0.0.42
Sent bytes: 8111
Recv bytes: 147
Duration: 00:02:23
```

Adding a third backend means writing one more script, not touching the parser.

## The four states

FortiClient's naming is not self-evident, and `Model.js` maps it:

| Reported | Widget shows | Notes |
|---|---|---|
| `Connected` | Connesso | Filled shield |
| `Connecting` | Connessione… | Shield breathes |
| `Not Running` | Disconnesso | The normal idle state |
| `Disconnected` | Disconnesso | Only flashes by during teardown |

## Profiles

A profile is one `/etc/openfortivpn/<name>.conf` and the systemd instance that
reads it. The widget **discovers** them instead of being told about them, so a
profile created with `setup-openfortivpn` shows up in the panel on its own.

The active profile is the panel's headline, and the chevron beside it opens the
list: the current one is marked, the others are one click away. Switching while
a tunnel is up tears the old one down first — one ppp route table, one gateway
at a time — and then connects the new profile, so a switch is one click. The
choice is written back to `shell.json`, which is what makes it survive a
restart; it is read from `activeProfile`.

**Add profile…** at the end of that list opens a form for a name, a gateway and
a port. Each row also carries a pencil and a bin: changing a profile is the same
form with the name fixed, and removing one asks first.

None of the three can be done by the widget itself — they write to `/etc` and
install or delete a polkit rule, which is root work a bar widget has no business
doing. So the panel hands the prepared command to a terminal and the script runs
there: your password stays in the terminal, and the output stays on screen when
something goes wrong.

Editing works because [`setup-openfortivpn`](scripts/setup-openfortivpn)
overwrites its own files, so saving a profile is just creating it again with the
name kept. Gateway and port come back from the login URL in the drop-in, since
the config that holds them is root-only; a profile set up before that line was
written opens with those fields blank. Renaming is not an edit — it would leave
the old profile in place — so the name is fixed once a profile exists.

[`scripts/remove-openfortivpn`](scripts/remove-openfortivpn) stops the unit and
deletes the four files the setup wrote. A drop-in directory that holds anything
else is left in place rather than emptied.

Each profile needs its own login URL, and the config it would come from is mode
600 root-only. So `setup-openfortivpn` records it in the systemd drop-in, which
is world readable:

```ini
Environment=FORTIVPN_SAML_URL=https://vpn.example.com:10443/remote/saml/start?redirect=1
```

A profile without that line still connects; it just cannot open the login page
by itself, unless `samlUrl` in the settings covers it. Re-running the setup
script adds the line.

## Installing on a machine

A profile can also be created, changed and removed from the panel itself; see
**Profiles** below.

```bash
# 1. The widget itself. Omarchy follows the symlink, so the checkout stays
#    wherever you keep your work and edits apply live.
git clone https://github.com/zangetsu02/omarchy-fortivpn ~/Workspaces/omarchy-fortivpn
ln -s ~/Workspaces/omarchy-fortivpn ~/.config/omarchy/plugins/zangetsu.fortivpn

# 2. Add {"id": "zangetsu.fortivpn"} to bar.layout in ~/.config/omarchy/shell.json

# 3. For the openfortivpn backend, the system side in one step per profile:
sudo pacman -S openfortivpn
sudo ~/Workspaces/omarchy-fortivpn/scripts/setup-openfortivpn work vpn.example.com 10443
```

Nothing else to configure: the widget finds the profile by itself.

[`scripts/setup-openfortivpn`](scripts/setup-openfortivpn) writes the profile,
the systemd drop-in and a polkit rule scoped to that one unit, then prints the
`shell.json` snippet to paste. It is safe to re-run.

It also decides for itself whether a CA bundle is needed: if the gateway
serves a complete chain it writes none, and if it does not, it fetches the
intermediate the certificate itself names, refuses to proceed unless that
completes the chain against the system roots, and only then installs a bundle.
This matters because openfortivpn's own suggestion in that situation is to pin
the fingerprint with `trusted-cert`, which breaks at every renewal.

Skipping the script and doing it by hand means the four steps below.

## The openfortivpn backend by hand

Everything here is machine-specific and lives outside this repo.

**1. A profile.** `/etc/openfortivpn/<name>.conf`, mode 600:

```ini
host = vpn.example.com
port = 10443
saml-login = 8020
```

If the gateway does not serve its intermediate certificates — openssl says
`unable to verify the first certificate` — do not pin the fingerprint with
`trusted-cert`, because that breaks on every renewal. Fetch the intermediate
named in the leaf's *CA Issuers* field, concatenate it with the system CA
bundle, and point `ca-file` at the result.

**2. A longer start timeout.** A drop-in at
`/etc/systemd/system/openfortivpn@<name>.service.d/override.conf`, because a
person has to complete an SSO login inside systemd's default 90 seconds:

```ini
[Service]
TimeoutStartSec=300
Restart=no
```

`Restart=no` matters: an automatic restart would silently demand a fresh
interactive login.

**3. A polkit rule**, so connecting does not ask for a password every time.
Scope it to the one unit and the three verbs:

```javascript
polkit.addRule(function(action, subject) {
    if (action.id !== "org.freedesktop.systemd1.manage-units") return;
    if (!subject.isInGroup("wheel") || !subject.local || !subject.active) return;
    if (action.lookup("unit") !== "openfortivpn@<name>.service") return;
    var verb = action.lookup("verb");
    if (verb === "start" || verb === "stop" || verb === "restart" || verb === "reset-failed") {
        return polkit.Result.YES;
    }
});
```

This grants no general root access, and connecting still requires completing
the SSO login in a browser. `reset-failed` belongs in the list because a unit
that hit its start limit refuses every further start until the failure is
cleared, which would otherwise leave the connect button dead.

**4. Nothing**, as long as the profile sits in `/etc/openfortivpn` and its unit
follows the `openfortivpn@<name>` convention: the widget discovers it. Add the
`Environment=FORTIVPN_SAML_URL=…` line from the section above to the drop-in
and it can open the login page too.

A unit named outside that convention still works, named explicitly in
`~/.config/omarchy/shell.json`:

```json
{
  "id": "zangetsu.fortivpn",
  "openfortivpnUnit": "my-vpn@<name>",
  "samlUrl": "https://vpn.example.com:10443/remote/saml/start?redirect=1"
}
```

With `backend: "auto"` the widget uses openfortivpn once that unit exists, and
falls back to FortiClient when it does not.

## Controls

| Action | Mouse | Keyboard (panel open) |
|---|---|---|
| Open the panel | Left click | — |
| Connect / disconnect | Right click | `Enter`, or `c` / `d` |
| Refresh now | Middle click | `r` |
| Show the profile list | Chevron in the panel | `p` |
| Switch profile | Click a profile | `1`–`9` |
| Add a profile | "Add profile…" | `a` |
| Change a profile | Pencil on its row | `e` (the active one) |
| Remove a profile | Bin on its row | `x` (the active one) |

## Settings

| Key | Default | Meaning |
|---|---|---|
| `backend` | `auto` | `auto`, `forticlient`, or `openfortivpn`. |
| `activeProfile` | `""` | Which discovered profile to drive. Written for you when you pick one. |
| `openfortivpnUnit` | `""` | Only for a unit outside the `openfortivpn@<name>` convention. |
| `samlUrl` | `""` | Fallback login URL for profiles whose drop-in records none. |
| `browserCommand` | `omarchy-launch-browser` | Opens the login page. |
| `refreshIntervalSec` | `5` | Poll interval; the duration ticks locally between polls. |
| `hideWhenDisconnected` | `false` | Hide the icon while the tunnel is down. |
| `notifyOnDrop` | `true` | Notify on an unrequested drop; a disconnect you asked for stays silent. |
| `notifyOnConnect` | `false` | Notify when the tunnel comes up. |
| `cliPath` | `""` | FortiClient backend only. Empty means look on `PATH`. |
| `guiCommand` | `/opt/forticlient/gui/FortiClient` | FortiClient backend only. |

## IPC

```bash
omarchy-shell fortivpn status      # current state label
omarchy-shell fortivpn backend     # which backend is active
omarchy-shell fortivpn refresh     # poll now
omarchy-shell fortivpn connect     # connect, or open the GUI
omarchy-shell fortivpn disconnect  # tear the tunnel down
omarchy-shell fortivpn toggle      # open/close the panel
omarchy-shell fortivpn profiles    # discovered profiles, one per line
omarchy-shell fortivpn profile work  # switch to a profile, disconnecting first
```

Changing the set of IPC functions a plugin exposes needs `omarchy restart
shell`; a hot reload keeps serving the old registration.

## Files

| File | Role |
|---|---|
| `manifest.json` | Plugin metadata and settings schema |
| `Model.js` | Parses the shared status format; formats bytes and durations |
| `Service.qml` | Backend selection, polling, connect and disconnect, notifications |
| `Panel.qml` | Bar icon and panel |
| `FortiVpnIcon.qml` | Shield glyph, filled when protected |
| `scripts/openfortivpn-status` | Reports an openfortivpn unit in the shared format; `--list` discovers profiles |
| `scripts/setup-openfortivpn` | Provisions a profile: config, drop-in, polkit rule |
| `scripts/remove-openfortivpn` | Tears one back down, unit first |
| `scripts/selftest` | Checks discovery, parsing, form validation and the removal guards |

## Requirements

Either `forticlient-vpn` (AUR), with `forticlient.service` running, or
`openfortivpn` 1.21+ for `--saml-login`.
