#!/bin/bash
# tun0 VPN: removes everything install.sh put on the system, including the release in /usr/local/lib/tun0-vpn and the
# vpn-update an earlier release installed. Profiles, configs, credentials, the pinned release key and the installed-release record are removed too
# unless you pass --keep-profiles (then /etc/vpn, without the record of the installed release, and the NetworkManager
# profiles stay).
#
# It removes only what is tun0 VPN's: files that name themselves as tun0 VPN in their first lines, the dispatcher
# links that point at its script, NetworkManager VPN connections of the profiles it stored, and in /etc/vpn and
# ~/.config/vpn only the entries it writes. Anything else under those names stays, and is named.
#
#   sudo /usr/local/bin/vpn-uninstall [--keep-profiles]
#
# Like install.sh it runs as root only from a place only root can write to: the copy install.sh put into
# /usr/local/bin, or the release tree. Everything in your home directory is removed with your rights, not root's.
set -euo pipefail
export PATH=/usr/bin LC_ALL=C   # never a program from the caller's PATH, nor the caller's locale; on Arch every tool used here lives in /usr/bin
umask 022
TREE=/usr/local/lib/tun0-vpn
die() { echo "uninstall: $*" >&2; exit 1; }
root_only() {   # PATH: a directory or file (not a link) owned by root that neither its group nor others can write to
  local st
  [[ ! -L "$1" && -e "$1" ]] || return 1
  st=$(stat -c '%u %a' -- "$1") || return 1
  [[ "${st%% *}" == 0 ]] && (( (8#${st#* } & 8#022) == 0 ))
}

[[ $EUID -eq 0 ]] || die "run it with sudo"
self=$(readlink -f -- "$0")
[[ "$self" == /usr/local/bin/vpn-uninstall || "$self" == "$TREE/uninstall.sh" ]] \
  || die "this runs as root only from a place only root can write to: sudo /usr/local/bin/vpn-uninstall"
d=$self
while :; do
  root_only "$d" || die "$d must belong to root and be writable by root only"
  [[ "$d" == / ]] && break
  d=$(dirname "$d")
done
keep=0
case "${1:-}" in --keep-profiles) keep=1 ;; "") ;; *) die "usage: vpn-uninstall [--keep-profiles]" ;; esac
USER_NAME=${SUDO_USER:-}
[[ -n "$USER_NAME" && "$USER_NAME" != root ]] || die "run this with sudo from your own account, not as root: the vpn command and the widget live in your home directory"
[[ "$USER_NAME" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,31}$ ]] || die "the user name '$USER_NAME' has characters this uninstaller does not pass on to sudo -u"
HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)
[[ "$HOME_DIR" == /* && -d "$HOME_DIR" ]] || die "no home directory for '$USER_NAME'"
USER_UID=$(id -u "$USER_NAME")
as_user()    { /usr/bin/sudo -u "$USER_NAME" -H "$@"; }
# hyprctl finds the compositor only through HYPRLAND_INSTANCE_SIGNATURE; sudo strips it, so take the newest instance dir.
HYPR_SIG=$(ls -t "/run/user/$USER_UID/hypr" 2>/dev/null | head -1 || true)
# OMARCHY_PATH: `omarchy`, `omarchy-shell` and `omarchy-menu` refuse to run without it, and sudo -u starts from an empty
# environment. Without it the plugin was never disabled, and the rescan and the menu refresh did nothing.
as_session() { /usr/bin/sudo -u "$USER_NAME" -H /usr/bin/env XDG_RUNTIME_DIR="/run/user/$USER_UID" HYPRLAND_INSTANCE_SIGNATURE="$HYPR_SIG" OMARCHY_PATH=/usr/share/omarchy "$@"; }
# Removing the plugin folder, disabling the plugin and the rescan all reload omarchy-shell, and under an active screen
# lock that reload crashes it (Omarchy 4.0.2), as for install.sh. Refuse to start; asked again before the widget goes.
screen_locked() { as_session /usr/bin/omarchy-hyprland-session-locked 2>/dev/null; }
screen_locked && die "the screen is locked. Unlock it first: removing the widget reloads the shell, and Omarchy 4.0.2 crashes its shell when that happens under a lock."
OWN_MARKS=('tun0 VPN' 'Root side of `vpn`: kill switch, reconnect watchdog' 'Removes everything install.sh put on the system')
marked() { head -n 5 | grep -qF -e "${OWN_MARKS[0]}" -e "${OWN_MARKS[1]}" -e "${OWN_MARKS[2]}"; }
ours() { [[ -f "$1" && ! -L "$1" ]] && marked < "$1"; }   # PATH: a plain file of tun0 VPN
remove_ours() {   # PATH...: remove each that is tun0 VPN's; name what is not
  local f
  for f in "$@"; do
    [[ -e "$f" || -L "$f" ]] || continue
    if ours "$f"; then rm -f -- "$f"; else echo "  not tun0 VPN's, left in place: $f" >&2; fi
  done
}
remove_link() {   # PATH: remove the dispatcher link if it points at tun0 VPN's script
  [[ -e "$1" || -L "$1" ]] || return 0
  if [[ -L "$1" && "$(readlink -- "$1")" == ../90-vpn-killswitch ]]; then rm -f -- "$1"; else echo "  not tun0 VPN's, left in place: $1" >&2; fi
}
# vpn_uuids NAME [--active]: the NetworkManager VPN connections called NAME (never another type of the same name)
vpn_uuids() { { nmcli -t -f NAME,UUID,TYPE con show ${2:-} 2>/dev/null || true; } | awk -F: -v n="$1" '$1 == n && $3 == "vpn" {print $2}'; }

echo "== disconnect, kill switch off, watchdog stopped, unit disabled"
ours /usr/local/bin/vpn-root && { /usr/local/bin/vpn-root off || true; }
UNIT_FILE=/etc/systemd/system/vpn-killswitch.service
if ours "$UNIT_FILE"; then
  systemctl disable --now vpn-killswitch.service >/dev/null 2>&1 || true   # ExecStop deletes the table ...
fi
systemctl stop vpn-reconnect.service >/dev/null 2>&1 || true; nft delete table inet vpn_ks 2>/dev/null || true   # ... and this makes sure, before the tools that know the table are gone
remove_ours "$UNIT_FILE"; systemctl daemon-reload
# Only this plugin's tunnels; a VPN you set up by other means is none of its business. NetworkManager not running
# must not stop the removal of the root parts below.
PROFILES=()
for f in /etc/vpn/configs/*.ovpn; do
  n=${f##*/}; n=${n%.ovpn}
  [[ -f "$f" && "$n" =~ ^[a-z0-9]+-[a-z0-9]+$ ]] && PROFILES+=("$n")
done
for n in "${PROFILES[@]}"; do
  for u in $(vpn_uuids "$n" --active); do nmcli con down uuid "$u" >/dev/null 2>&1 || true; done
done

# The pinned release key stays with --keep-profiles (it is the anchor of a later reinstall); the record of the
# installed release does not, because nothing is installed any more.
(( keep )) && rm -f /etc/vpn/installed-release
if (( ! keep )); then
  echo "== profiles, configs, credentials"
  for n in "${PROFILES[@]}"; do
    for u in $(vpn_uuids "$n"); do nmcli con delete uuid "$u" >/dev/null 2>&1 && echo "  profile removed: $n" || true; done
  done
  # Only the entries tun0 VPN writes; /etc/vpn itself goes when nothing else is in it
  if [[ -d /etc/vpn && ! -L /etc/vpn ]]; then
    rm -rf /etc/vpn/auth /etc/vpn/configs /etc/vpn/killswitch.nft /etc/vpn/killswitch.nft.in /etc/vpn/settings \
           /etc/vpn/trusted /etc/vpn/release-signer /etc/vpn/installed-release /etc/vpn/.killswitch.* \
           /etc/vpn/settings.tmp /etc/vpn/trusted.tmp /etc/vpn/trusted.new
    rmdir /etc/vpn 2>/dev/null || echo "  /etc/vpn holds files that are not tun0 VPN's, left in place: $(ls -A /etc/vpn | paste -sd' ')" >&2
  fi
  # ~/.config/vpn: the recent profiles, the lookup setting, and what installers before 1.0.0 set aside
  as_user /usr/bin/bash -c 'cd "$1" 2>/dev/null || exit 0; rm -f recent ip-lookup trusted.migrated.* settings.migrated.* default.migrated.*; left=$(ls -A | paste -sd" "); cd / && rmdir "$1" 2>/dev/null || echo "  $1 holds files that are not tun0 VPN'"'"'s, left in place: $left" >&2' _ "$HOME_DIR/.config/vpn" \
    || echo "  could not clean $HOME_DIR/.config/vpn as $USER_NAME, left in place" >&2
fi

echo "== root helper, dispatcher, sudoers"
remove_ours /usr/local/bin/vpn-root /etc/NetworkManager/dispatcher.d/90-vpn-killswitch /etc/sudoers.d/vpn
remove_link /etc/NetworkManager/dispatcher.d/pre-up.d/90-vpn-killswitch
remove_link /etc/NetworkManager/dispatcher.d/pre-down.d/90-vpn-killswitch
rm -f /run/vpn-killswitch.*

echo "== bar widget (plugin), menu block, vpn command"
PLUGIN_ID=rogertobler.tun0-vpn
PLUGIN_DIR="$HOME_DIR/.config/omarchy/plugins/$PLUGIN_ID"
if screen_locked; then
  echo "  the screen was locked meanwhile: the widget stays (a reload under the lock crashes the shell). After unlocking:" >&2
  echo "    omarchy plugin disable $PLUGIN_ID; rm -rf $PLUGIN_DIR; omarchy-shell -q shell rescanPlugins" >&2
else
  as_session /usr/bin/omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1 || true
  # Home directory steps never stop the removal of the root parts: a folder the user cannot delete stays, with a note.
  if as_user test -d "$PLUGIN_DIR"; then
    if as_user rm -rf "$PLUGIN_DIR"; then echo "  plugin folder removed"; else echo "  could not remove $PLUGIN_DIR as $USER_NAME, left in place" >&2; fi
  fi
  as_session /usr/bin/omarchy-shell -q shell rescanPlugins || true
fi
as_user python3 - "$HOME_DIR/.config/omarchy/extensions/omarchy-menu.jsonc" <<'PY' || true
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
if p.exists():
    s = p.read_text()
    s2 = re.sub(r"[ \t]*// >>> (vpn|protonvpn).*?// <<< \1[ \t]*\n?", "", s, count=2, flags=re.S)
    if s2 != s: p.write_text(s2); print("  menu block removed")
PY
# The menu re-reads its files through the shell's IPC, which needs the session like the calls above; a quiet no-op
# before. Not under a lock either: it is a call into the same shell.
screen_locked || as_session /usr/bin/omarchy-menu refresh >/dev/null 2>&1 || true
VPN_CMD=$HOME_DIR/.local/bin/vpn
if as_user test -f "$VPN_CMD" -a ! -h "$VPN_CMD"; then
  if as_user head -n 5 -- "$VPN_CMD" | marked; then
    as_user rm -f "$VPN_CMD" || echo "  could not remove $VPN_CMD as $USER_NAME, left in place" >&2
  else echo "  not tun0 VPN's, left in place: $VPN_CMD" >&2; fi
elif as_user test -e "$VPN_CMD" -o -h "$VPN_CMD"; then echo "  not tun0 VPN's, left in place: $VPN_CMD" >&2; fi

echo "== the release in $TREE, the updater and this uninstaller"
rm -rf "$TREE"
remove_ours /usr/local/bin/vpn-update
remove_ours /usr/local/bin/vpn-uninstall   # this script's own copy goes last; bash has it open and finishes reading it
echo
echo "Done. Packages stay: tun0 VPN never installed any (networkmanager-openvpn and the rest are yours to keep or remove)."
(( keep )) && echo "Kept: /etc/vpn (without the record of the installed release) and the NetworkManager profiles."
exit 0
