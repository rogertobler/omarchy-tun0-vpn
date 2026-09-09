#!/bin/bash
# Removes everything install.sh put on the system. Profiles, configs and credentials are removed too
# unless you pass --keep-profiles (then /etc/vpn and the NetworkManager profiles stay).
#
#   sudo ./uninstall.sh [--keep-profiles]
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Please run with sudo." >&2; exit 1; }
USER_NAME=${SUDO_USER:-}
[[ -n "$USER_NAME" && "$USER_NAME" != root ]] || { echo "Run this with sudo from your own account, not as root - the bar module and the menu live in your home directory." >&2; exit 1; }
HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)
keep=0; [[ "${1:-}" == "--keep-profiles" ]] && keep=1
as_user() { sudo -u "$USER_NAME" -H "$@"; }

echo "== disconnect, kill switch off, watchdog stopped, unit disabled"
[[ -x /usr/local/bin/vpn-root ]] && /usr/local/bin/vpn-root off || true
systemctl disable --now vpn-killswitch.service >/dev/null 2>&1 || true   # ExecStop deletes the table ...
systemctl stop vpn-reconnect.service >/dev/null 2>&1 || true; nft delete table inet vpn_ks 2>/dev/null || true   # ... and this makes sure, before the tools that know the table are gone
rm -f /etc/systemd/system/vpn-killswitch.service; systemctl daemon-reload
nmcli -t -f NAME,TYPE con show --active 2>/dev/null | awk -F: '$2=="vpn"{print $1}' | while read -r n; do nmcli con down "$n" >/dev/null 2>&1 || true; done

if (( ! keep )); then
  echo "== profiles, configs, credentials"
  for f in /etc/vpn/configs/*.ovpn; do [[ -f "$f" ]] || continue; n=$(basename "$f" .ovpn); nmcli con delete "$n" >/dev/null 2>&1 && echo "  profile removed: $n" || true; done
  rm -rf /etc/vpn
  rm -rf "$HOME_DIR/.config/vpn"
fi

echo "== root helper, dispatcher, sudoers"
rm -f /usr/local/bin/vpn-root /etc/NetworkManager/dispatcher.d/90-vpn-killswitch /etc/NetworkManager/dispatcher.d/pre-up.d/90-vpn-killswitch /etc/NetworkManager/dispatcher.d/pre-down.d/90-vpn-killswitch \
      /etc/sudoers.d/vpn /run/vpn-killswitch.*

echo "== bar widget (plugin), old bar module and menu block"
PLUGIN_ID=rogertobler.tun0-vpn
PLUGIN_DIR="$HOME_DIR/.config/omarchy/plugins/$PLUGIN_ID"
USER_UID=$(id -u "$USER_NAME")
as_session() { sudo -u "$USER_NAME" -H env XDG_RUNTIME_DIR="/run/user/$USER_UID" "$@"; }
as_session omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1 || true
SRC=$(cd "$(dirname "$0")" && pwd)
if [[ -d "$PLUGIN_DIR" && "$(readlink -f "$SRC")" != "$(readlink -f "$PLUGIN_DIR")" ]]; then
  rm -rf "$PLUGIN_DIR"; echo "  plugin folder removed"
elif [[ -d "$PLUGIN_DIR" ]]; then
  echo "  this script runs from the plugin folder itself - finish with: omarchy plugin remove $PLUGIN_ID --yes"
fi
as_session omarchy-shell -q shell rescanPlugins || true
as_user python3 - "$HOME_DIR/.config/omarchy/shell.json" <<'PY' || true
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
if p.exists():
    d = json.loads(p.read_text())
    for sec in d.get("bar", {}).get("layout", {}).values():
        sec[:] = [e for e in sec if e.get("id") not in ("vpn", "protonvpn")]
    p.write_text(json.dumps(d, indent=2) + "\n"); print("  bar module removed from shell.json")
PY
as_user python3 - "$HOME_DIR/.config/omarchy/extensions/omarchy-menu.jsonc" <<'PY' || true
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
if p.exists():
    s = p.read_text()
    s = re.sub(r"[ \t]*// >>> (vpn|protonvpn).*?// <<< \1[ \t]*\n?", "", s, count=2, flags=re.S)
    p.write_text(s); print("  menu block removed")
PY
as_user omarchy-menu refresh >/dev/null 2>&1 || true
rm -f "$HOME_DIR/.local/bin/vpn" /usr/local/bin/vpn-uninstall   # this script's own copy goes last
echo
echo "Done. networkmanager-openvpn stays installed (pacman -Rns networkmanager-openvpn to remove it)."
(( keep )) && echo "Kept: /etc/vpn and the NetworkManager profiles."
exit 0
