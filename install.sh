#!/bin/bash
# tun0 VPN (OpenVPN profiles in NetworkManager, kill switch, watchdog, bar icon, menu) - setup.
#
#   sudo ./install.sh [NAME FILE.ovpn ...]   NAME = <provider>-<country>, one dash, e.g. proton-de ~/Downloads/de.protonvpn.udp.ovpn
#
# After this, everything works without a terminal: add and remove profiles from the menu (right-click the
# shield icon) or with `vpn add` / `vpn remove`. Idempotent - run it again after an update.
set -euo pipefail
trap 'echo "install.sh: failed at line $LINENO (see the message above, if any)" >&2' ERR   # never die silently
[[ $EUID -eq 0 ]] || { echo "Run this with sudo." >&2; exit 1; }
[[ $(( $# % 2 )) -eq 0 ]] || { echo "Arguments come in pairs: NAME FILE.ovpn ..." >&2; exit 1; }
SRC=$(cd "$(dirname "$0")" && pwd)
USER_NAME=${SUDO_USER:-}
[[ -n "$USER_NAME" && "$USER_NAME" != root ]] || { echo "Run this with sudo from your own account, not as root - the bar module and the menu are written into your home directory." >&2; exit 1; }
HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)
[[ -d "$HOME_DIR" ]] || { echo "No home directory for '$USER_NAME'." >&2; exit 1; }
ETC=/etc/vpn; CONF=$ETC/configs; AUTHD=$ETC/auth
USER_UID=$(id -u "$USER_NAME")
# hyprctl finds the compositor only through HYPRLAND_INSTANCE_SIGNATURE; sudo strips it, so take the newest instance dir.
HYPR_SIG=$(ls -t "/run/user/$USER_UID/hypr" 2>/dev/null | head -1 || true)
as_session() { sudo -u "$USER_NAME" -H env XDG_RUNTIME_DIR="/run/user/$USER_UID" HYPRLAND_INSTANCE_SIGNATURE="$HYPR_SIG" "$@"; }
# Writing into ~/.config/omarchy/plugins/ makes omarchy-shell hot-reload. Under an active screen lock that reload
# recreates the shell's lock service, which mistakes the lock it already holds for a stranded one and takes it
# again - quickshell aborts ("Tried to show lockscreen surfaces without active lock"; Omarchy 4.0.2, seen twice
# on 2026-09-08). Refuse to start rather than leave a locked machine without a lock screen.
if as_session omarchy-hyprland-session-locked 2>/dev/null; then
  echo "The screen is locked. Unlock it first: installing the widget reloads the shell, and Omarchy 4.0.2 crashes its shell when that happens under a lock." >&2
  exit 1
fi
ROOT=/usr/local/bin/vpn-root
as_user() { sudo -u "$USER_NAME" -H "$@"; }

echo "== 1/6 Packages"
pacman -S --needed --noconfirm networkmanager-openvpn

echo "== 2/6 Scripts, dispatcher, sudoers, kill switch unit"
install -d -m755 "$ETC" "$CONF"; install -d -m700 "$AUTHD"
install -Dm755 "$SRC/vpn-root"          "$ROOT"
install -Dm755 "$SRC/90-vpn-killswitch" /etc/NetworkManager/dispatcher.d/90-vpn-killswitch
# pre-up and pre-down are the events NetworkManager waits for: the same script, linked there, shuts an untrusted
# network before its first packet and shuts an interface again before it can carry the next network
install -d -m755 /etc/NetworkManager/dispatcher.d/pre-up.d /etc/NetworkManager/dispatcher.d/pre-down.d
ln -sfn ../90-vpn-killswitch /etc/NetworkManager/dispatcher.d/pre-up.d/90-vpn-killswitch
ln -sfn ../90-vpn-killswitch /etc/NetworkManager/dispatcher.d/pre-down.d/90-vpn-killswitch
install -Dm644 "$SRC/killswitch.nft.in" "$ETC/killswitch.nft.in"
install -Dm644 "$SRC/vpn-killswitch.service" /etc/systemd/system/vpn-killswitch.service
systemctl daemon-reload
sed "s|@USER@|$USER_NAME|g" "$SRC/sudoers-vpn.in" > /etc/sudoers.d/vpn; chmod 440 /etc/sudoers.d/vpn
visudo -cf /etc/sudoers.d/vpn
install -o "$USER_NAME" -g "$USER_NAME" -Dm755 "$SRC/vpn" "$HOME_DIR/.local/bin/vpn"
# A copy of the uninstaller outside the plugin folder: `omarchy plugin remove` deletes that folder, uninstall.sh included
install -Dm755 "$SRC/uninstall.sh" /usr/local/bin/vpn-uninstall

echo "== 3/6 Settings"
# Trusted networks, the two automation switches and the default profile live in /etc/vpn: the dispatcher decides
# as root, before login, and must not read a home directory. Older installs kept them in ~/.config/vpn - move them once.
OLD_CFG="$HOME_DIR/.config/vpn"
if [[ -s "$OLD_CFG/trusted" && ! -s "$ETC/trusted" ]]; then
  "$ROOT" trust set < "$OLD_CFG/trusted" >/dev/null && echo "  trusted networks moved to $ETC/trusted: $(paste -sd, "$ETC/trusted" | sed 's/,/, /g')"
fi
for k in autoconnect autodisconnect; do
  v=$(grep -s "^$k=" "$OLD_CFG/settings" 2>/dev/null | tail -1 | cut -d= -f2- || true)   # the file is gone after the first run: no match is not an error
  if [[ -n "$v" && -z "$("$ROOT" get "$k")" ]]; then "$ROOT" set "$k" "$v" >/dev/null && echo "  $k=$v moved to $ETC/settings"; fi
done
if [[ -s "$OLD_CFG/default" && -z "$("$ROOT" get default)" ]]; then
  d=$(<"$OLD_CFG/default"); "$ROOT" set default "$d" >/dev/null 2>&1 && echo "  default moved: $d" || true
fi
for f in trusted settings default; do   # kept, not deleted: a failed migration must not cost the list
  [[ -f "$OLD_CFG/$f" ]] && as_user mv "$OLD_CFG/$f" "$OLD_CFG/$f.migrated.$(date +%s)"
done
echo "  $(paste -sd' ' "$ETC/settings" 2>/dev/null || echo 'no settings yet') · trusted: $(paste -sd, "$ETC/trusted" 2>/dev/null | sed 's/,/, /g' || echo none)"

echo "== 4/6 Profiles"
while [[ $# -ge 2 ]]; do
  name=${1,,}; f=$2; shift 2; prov=${name%%-*}
  if ! "$ROOT" has-auth "$prov"; then
    [[ -t 0 ]] || { echo "No credentials for '$prov' and no terminal to ask on." >&2; exit 1; }
    echo "  Credentials for '$prov' (Proton: the OpenVPN/IKEv2 username from account.protonvpn.com, NOT your account password; Mullvad: account number, password 'm'):"
    read -rp "  Username: " u; read -rsp "  Password: " p; echo
    printf '%s\n%s\n' "$u" "$p" | "$ROOT" add "$name" "$f"
  else
    "$ROOT" add "$name" "$f" </dev/null
  fi
done
echo "== 5/6 Kill switch rules and all profiles (a connected profile is left alone)"
rebuild_rc=0; "$ROOT" rebuild || rebuild_rc=$?
# The table is loaded now and at every boot, before NetworkManager. `boot` also opens whatever is open by policy
# right now (the trusted Wi-Fi you are on, a cable), so this install never cuts the machine off.
# enable for the next boot, start now so systemd owns it (status, ExecStop), then boot once more directly:
# both loads are atomic and render the open set first, so there is no moment without the table in between
systemctl enable vpn-killswitch.service >/dev/null 2>&1 || true
systemctl start vpn-killswitch.service 2>/dev/null || true
"$ROOT" boot || true
if [[ -e /run/vpn-killswitch.open ]]; then echo "  kill switch loaded; open now: $(paste -sd' ' /run/vpn-killswitch.open | sed 's/^$/nothing/')"
else echo "  kill switch not loaded (setting off, or no profile yet)"; fi

echo "== 6/6 Bar widget, default"
# The widget is an Omarchy shell plugin: manifest.json + QML under ~/.config/omarchy/plugins/<id>/. When this
# script runs from a git clone, the plugin files are copied there; when it runs from the plugin folder itself
# (after `omarchy plugin add`), they are already in place. Enabling goes through Omarchy's own tooling, which
# edits shell.json the way the user's other plugins are managed - and asks nothing else of the config.
PLUGIN_ID=rogertobler.tun0-vpn
PLUGIN_DIR="$HOME_DIR/.config/omarchy/plugins/$PLUGIN_ID"
if [[ "$(readlink -f "$SRC")" != "$(readlink -f "$PLUGIN_DIR" 2>/dev/null || echo /nonexistent)" ]]; then
  as_user install -d "$PLUGIN_DIR"
  for f in manifest.json BarWidget.qml Service.qml Model.js preview.png; do
    [[ -f "$SRC/$f" ]] && as_user install -m644 "$SRC/$f" "$PLUGIN_DIR/$f"
  done
  echo "  plugin files -> $PLUGIN_DIR"
fi
as_session omarchy-shell -q shell rescanPlugins || true
if as_session omarchy plugin enable "$PLUGIN_ID" right >/dev/null 2>&1; then echo "  plugin enabled: $PLUGIN_ID"
else echo "  could not enable the plugin now (shell not running?) - later: omarchy plugin enable $PLUGIN_ID"; fi
# Earlier versions (before the widget) put a command module and a menu block into the user's config. Take them out.
SHELL_JSON="$HOME_DIR/.config/omarchy/shell.json"
[[ -s "$SHELL_JSON" ]] && as_user cp "$SHELL_JSON" "$SHELL_JSON.bak.$(date +%s)"
as_user python3 - "$SHELL_JSON" <<'PY' || true
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
if p.exists():
    d = json.loads(p.read_text()); n = 0
    for sec in d.get("bar", {}).get("layout", {}).values():
        if isinstance(sec, list):
            keep = [e for e in sec if not (isinstance(e, dict) and e.get("id") in ("vpn", "protonvpn"))]
            n += len(sec) - len(keep); sec[:] = keep
    if n: p.write_text(json.dumps(d, indent=2) + "\n"); print("  old command module removed from shell.json")
PY
MENU="$HOME_DIR/.config/omarchy/extensions/omarchy-menu.jsonc"
[[ -f "$MENU" ]] && as_user python3 - "$MENU" <<'PY' || true
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s2 = re.sub(r"[ \t]*// >>> (vpn|protonvpn).*?// <<< \1[ \t]*\n?", "", s, count=2, flags=re.S)
if s2 != s: p.write_text(s2); print("  old menu block removed (the panel replaces it; `vpn menu-write` brings it back on request)")
PY
if [[ -z "$("$ROOT" get default)" ]]; then
  first=$(as_user "$HOME_DIR/.local/bin/vpn" list | awk 'NR==1{print $1}' | tr -d '*=')
  [[ -n "$first" ]] && "$ROOT" set default "$first" >/dev/null && echo "  default: $first"
fi
echo
echo "Done. Profiles: $(as_user "$HOME_DIR/.local/bin/vpn" list | paste -sd' ')"
echo "Try it as $USER_NAME:  vpn on   /   vpn status   /   vpn off   - or click the shield icon"
(( rebuild_rc == 0 )) || echo "WARNING: at least one profile could not be imported (see above) - wrong credentials? vpn remove <name>?" >&2
exit $rebuild_rc
