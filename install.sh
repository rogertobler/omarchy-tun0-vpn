#!/bin/bash
# tun0 VPN (OpenVPN profiles in NetworkManager, kill switch, watchdog, bar icon, menu): the root side.
#
# Runs only as the last step of the verified bootstrap in the README (Install), which fetches exactly one release commit
# into a directory only root can write to and checks it before anything of it runs: that the commit is signed by the
# release key, and that its SHA256SUMS has the digest the README names (this file included). Only then does it start
#
#   /usr/local/lib/tun0-vpn/install.sh --commit <full commit> [NAME FILE.ovpn ...]
#
# An update is the same bootstrap with the commit of the newer release. NAME = <provider>-<country>, one dash, e.g.
# proton-de ~/Downloads/de.protonvpn.udp.ovpn (optional, `vpn add` does the same later). Idempotent.
#
# What the bootstrap checked, this script checks again before it changes anything, and more:
#   - it runs from exactly /usr/local/lib/tun0-vpn/install.sh, every directory from / down to that tree and
#     everything in the tree belongs to root and is writable by root only, and nothing in it is a link
#   - the checkout is exactly the commit given with --commit, unmodified, and that commit is signed by the release key
#     below, which must be the one pinned in /etc/vpn/release-signer if a key is pinned there; the release is not
#     older than the one recorded as installed
#   - each file to be installed is checked in the tree for its canonical path, owner and mode, then copied into a
#     staging directory only root can read, and the SHA-256 of that copy is checked against SHA256SUMS in the signed
#     commit; what is installed is that copy, never the tree again
#   - what it needs is there (networkmanager-openvpn, nftables, python-gobject, jq, curl, sudo 1.9.10 or newer): it
#     installs no packages itself and says what is missing
#   - every file it would replace was put there by tun0 VPN; a file of another package or of your own under one of
#     its names stops it
#   - the user can write where the vpn command and the widget go, the configs named on the command line are
#     readable, and their credentials have been asked for
# The sudoers rule is removed next and written last, once everything else is in place. The configs named on the
# command line are opened with your rights, not root's, and handed to the root helper as bytes.
set -Eeuo pipefail
unset XDG_CONFIG_HOME; for v in $(compgen -v GIT_); do unset "$v"; done
# Root's own environment: tools from /usr/bin only, git never reads the caller's HOME, config, hooks or fsmonitor,
# and the locale is not the caller's either (sudo passes LANG and LC_* through)
export PATH=/usr/bin HOME=/root GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 LC_ALL=C
umask 022
REVOKED=0; STAGE=""
on_exit() {
  local rc=$?
  [[ -n "$STAGE" ]] && rm -rf "$STAGE"
  if (( REVOKED )); then
    echo "install.sh: stopped before the end. The sudoers rule stays removed until install.sh runs through, so the panel and the vpn command cannot change the kill switch meanwhile; the kill switch itself keeps working. Paste the bootstrap from the README (Install) again." >&2
  fi
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM HUP
trap 'echo "install.sh: failed at line $LINENO (see the message above, if any)" >&2' ERR

TREE=/usr/local/lib/tun0-vpn
# The public half of the key that signs every release commit and tag. The same key is listed as a signing key of the GitHub
# account rogertobler (https://api.github.com/users/rogertobler/ssh_signing_keys), fingerprint
# SHA256:BP0m/tn2dfpS+7xOCWmG6ioYfUrbdSIqmNHNuRb/txQ.
RELEASE_SIGNER='git@rogertobler.com namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPRq/nVA2tJpshyb4X5oDKZ/3mkWeuk9HH3Dor3cHdua'
# Everything root installs from the tree, and the widget files the user side gets. Each is listed in SHA256SUMS, and so
# is this installer, which the bootstrap checks before it starts it.
PAYLOADS=(vpn-root 90-vpn-killswitch vpn-killswitch.service killswitch.nft.in sudoers-vpn.in uninstall.sh vpn)
WIDGET=(manifest.json BarWidget.qml Service.qml Model.js preview.png)
ETC=/etc/vpn; CONF=$ETC/configs; AUTHD=$ETC/auth
PINNED=$ETC/release-signer; RECORD=$ETC/installed-release
ROOT=/usr/local/bin/vpn-root
PLUGIN_ID=rogertobler.tun0-vpn

die() { echo "install.sh: $*" >&2; exit 1; }
root_only() {   # PATH: a directory or file (not a link) owned by root that neither its group nor others can write to
  local st
  [[ ! -L "$1" && -e "$1" ]] || return 1
  st=$(stat -c '%u %a' -- "$1") || return 1
  [[ "${st%% *}" == 0 ]] && (( (8#${st#* } & 8#022) == 0 ))
}
tgit() { git -C "$TREE" -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"; }
manifest_version() { sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1; }

[[ $EUID -eq 0 ]] || die "run it as root, as the last step of the bootstrap in the README (Install)"
COMMIT=""
if [[ "${1:-}" == --commit ]]; then COMMIT=${2:-}; shift 2 || true; fi
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "--commit <full commit> is required: paste the bootstrap from the README (Install), which verifies that commit before it starts this script. Profiles are added afterwards with  vpn add FILE.ovpn"
[[ $(( $# % 2 )) -eq 0 ]] || die "arguments come in pairs: NAME FILE.ovpn ..."

echo "== 1/6 Checks (nothing is changed before they have passed)"
# Where this runs from. Run from anywhere else (the plugin folder, a clone of your own), it refuses and says how.
self=$(readlink -f -- "$0")
if [[ "$self" != "$TREE/install.sh" ]]; then
  # Nothing is read from the folder it was started in, not even the version: root opens no file there.
  cat >&2 <<'EOF'
install.sh: this runs as root only from a release commit that root fetched and verified itself, never from a folder
you can write to (a program running as you could change this script, or a file it installs, while it runs). Install
with the bootstrap in the README (Install): it fetches the release commit named there into /usr/local/lib/tun0-vpn,
checks its signature and its SHA256SUMS, and only then starts this script from there.
EOF
  exit 1
fi
d=$TREE
while :; do
  root_only "$d" || die "$d must belong to root and be writable by root only"
  [[ "$d" == / ]] && break
  d=$(dirname "$d")
done
bad=$(find "$TREE" \( -type l -o ! -user 0 -o -perm /022 \) -print -quit)
[[ -z "$bad" ]] || die "$bad: everything in $TREE must belong to root, be writable by root only, and no link"

# What the release needs. No package manager runs here: what is missing is named, and you install it.
missing=()
[[ -f /usr/lib/NetworkManager/VPN/nm-openvpn-service.name ]] || missing+=(networkmanager-openvpn)
for need in nmcli:networkmanager nft:nftables ssh-keygen:openssh jq:jq curl:curl python3:python; do
  [[ -x "/usr/bin/${need%%:*}" ]] || missing+=("${need#*:}")
done
# The root helper stores credentials through libnm from Python, so the password never shows in a process list
[[ -x /usr/bin/python3 ]] && /usr/bin/python3 -I -c 'import gi; gi.require_version("NM", "1.0"); from gi.repository import NM' >/dev/null 2>&1 \
  || missing+=(python-gobject)
(( ${#missing[@]} == 0 )) || die "not installed: ${missing[*]}. Install with  sudo pacman -S --needed ${missing[*]}  and paste the bootstrap again. Nothing was changed."
# The sudoers rule limits the arguments with regular expressions, which sudo understands from 1.9.10 on; an older
# sudo would read them as plain words and refuse everything, or worse.
sudo_version=$(/usr/bin/sudo -V 2>/dev/null | sed -n '1s/^Sudo version \([0-9][0-9.]*\).*/\1/p')
[[ -n "$sudo_version" && "$(printf '1.9.10\n%s\n' "$sudo_version" | sort -V | head -1)" == 1.9.10 ]] \
  || die "sudo ${sudo_version:-of unknown version} is older than 1.9.10, which the sudoers rule needs (regular expressions in arguments). Update sudo and paste the bootstrap again. Nothing was changed."

# Which release: exactly the commit the bootstrap verified. The version comes from that commit, not the working tree.
head=$(tgit rev-parse --verify HEAD)
[[ "$head" == "$COMMIT" ]] || die "the checkout is $head, not the commit $COMMIT the bootstrap named. Run the bootstrap in the README again. Nothing was changed."
st=$(tgit status --porcelain --untracked-files=all --ignored) || die "git status failed in $TREE. Nothing was changed."
[[ -z "$st" ]] || die "$TREE differs from the commit $COMMIT (git -C $TREE status --ignored). Run the bootstrap in the README again. Nothing was changed."
version=$(tgit show HEAD:manifest.json | manifest_version)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "manifest.json in the checked out commit carries no release version"
if [[ -e "$PINNED" ]]; then
  root_only "$PINNED" || die "$PINNED must belong to root and be writable by root only"
  [[ "$(cat "$PINNED")" == "$RELEASE_SIGNER" ]] || die "release $version names a different release key than the one pinned on this machine ($PINNED). Nothing was changed. If the key really changed, compare both with the README and the account's signing keys, and remove $PINNED by hand."
fi
if [[ -e "$RECORD" ]]; then
  root_only "$RECORD" || die "$RECORD must belong to root and be writable by root only"
  installed=$(cut -d' ' -f1 "$RECORD")
  if [[ "$installed" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$(printf '%s\n%s\n' "$installed" "$version" | sort -V | head -1)" != "$installed" ]]; then
    die "release $version is older than the installed release $installed. Nothing was changed."
  fi
fi
STAGE=$(mktemp -d /run/tun0-vpn-install.XXXXXX)   # mode 700: nothing but root reads or writes what is checked in here
printf '%s\n' "$RELEASE_SIGNER" > "$STAGE/allowed_signers"
# gpg.format does not choose how a signature is checked, the signature does: an OpenPGP or X.509 signature would go
# to gpg or gpgsm and root's keyrings. Both are switched off, so only ssh-keygen and the release key can pass.
tgit -c gpg.format=ssh -c gpg.ssh.allowedSignersFile="$STAGE/allowed_signers" -c gpg.ssh.program=/usr/bin/ssh-keygen \
  -c gpg.openpgp.program=/usr/bin/false -c gpg.x509.program=/usr/bin/false verify-commit "$COMMIT" >/dev/null 2>&1 \
  || die "commit $COMMIT is not signed by the release key. Nothing was changed."
echo "  release $version at $COMMIT, signed by the release key"

# Every file: checked in the tree, one copy into the staging directory, and that copy is checked and installed.
tgit show HEAD:SHA256SUMS > "$STAGE/SHA256SUMS" || die "SHA256SUMS is missing from the release"
for name in "${PAYLOADS[@]}" "${WIDGET[@]}"; do
  src=$TREE/$name
  [[ "$(readlink -f -- "$src")" == "$src" && -f "$src" ]] && root_only "$src" || die "$src: not a plain root-only file at its canonical path"
  cp -- "$src" "$STAGE/$name"
  want=$(awk -v f="$name" '$2 == f || $2 == "*" f {print $1; exit}' "$STAGE/SHA256SUMS")
  got=$(sha256sum < "$STAGE/$name"); got=${got%% *}
  [[ "$want" =~ ^[0-9a-f]{64}$ && "$got" == "$want" ]] || die "$name: SHA-256 $got does not match the signed release (${want:-not listed})"
done
# and this installer is the one the release lists, as the bootstrap already checked
want=$(awk '$2 == "install.sh" || $2 == "*install.sh" {print $1; exit}' "$STAGE/SHA256SUMS"); got=$(sha256sum < "$TREE/install.sh"); got=${got%% *}
[[ "$want" =~ ^[0-9a-f]{64}$ && "$got" == "$want" ]] || die "install.sh: SHA-256 $got does not match the signed release (${want:-not listed})"
echo "  $(( ${#PAYLOADS[@]} + ${#WIDGET[@]} )) files staged and checked against SHA256SUMS"

USER_NAME=${SUDO_USER:-}
[[ -n "$USER_NAME" && "$USER_NAME" != root ]] || die "run this with sudo from your own account, not as root: the vpn command and the widget belong to your user"
[[ "$USER_NAME" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,31}$ ]] || die "the user name '$USER_NAME' has characters this installer does not pass on to sudo -u"
HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)
[[ "$HOME_DIR" == /* && -d "$HOME_DIR" ]] || die "no home directory for '$USER_NAME'"
USER_UID=$(id -u "$USER_NAME")
[[ "$USER_UID" =~ ^[1-9][0-9]*$ ]] || die "'$USER_NAME' has no ordinary user id"
# The rule names the user by number, so a later rename or a new account with the old name gets nothing, and the helper
# by the digest of the checked copy that is installed, so sudo refuses a vpn-root with other bytes.
VPN_ROOT_SHA256=$(sha256sum < "$STAGE/vpn-root"); VPN_ROOT_SHA256=${VPN_ROOT_SHA256%% *}
sed -e "s|@UID@|$USER_UID|g" -e "s|@VPN_ROOT_SHA256@|$VPN_ROOT_SHA256|g" "$STAGE/sudoers-vpn.in" > "$STAGE/sudoers"
! grep -q '@[A-Z0-9_]*@' "$STAGE/sudoers" || die "the rendered sudoers rule still holds a placeholder"
visudo -cf "$STAGE/sudoers" >/dev/null || die "the rendered sudoers rule does not parse"
# hyprctl finds the compositor only through HYPRLAND_INSTANCE_SIGNATURE; sudo strips it, so take the newest instance dir.
HYPR_SIG=$(ls -t "/run/user/$USER_UID/hypr" 2>/dev/null | head -1 || true)
as_user()    { /usr/bin/sudo -u "$USER_NAME" -H "$@"; }
# OMARCHY_PATH: `omarchy` and `omarchy-shell` refuse to run without it ("OMARCHY_PATH is not set"), and sudo -u starts
# from an empty environment. Without it `omarchy plugin enable` failed on every installation and the rescan quietly
# did nothing behind `-q`.
as_session() { /usr/bin/sudo -u "$USER_NAME" -H /usr/bin/env XDG_RUNTIME_DIR="/run/user/$USER_UID" HYPRLAND_INSTANCE_SIGNATURE="$HYPR_SIG" OMARCHY_PATH=/usr/share/omarchy "$@"; }
user_can_create() {   # PATH: the user can create PATH, or write into it if it is an existing directory
  local d=$1
  while ! as_user /usr/bin/test -e "$d"; do
    [[ "$d" == / ]] && return 1   # not even / exists for the user: sudo -u itself fails, and dirname / is / forever
    d=$(dirname "$d")
  done
  as_user /usr/bin/test -d "$d" -a -w "$d"
}
# Writing into ~/.config/omarchy/plugins/ makes omarchy-shell hot-reload. Under an active screen lock that reload
# recreates the shell's lock service, which mistakes the lock it already holds for a stranded one and takes it
# again, and quickshell aborts ("Tried to show lockscreen surfaces without active lock"; Omarchy 4.0.2). Refuse to
# start rather than leave a locked machine without a lock screen; asked again right before the widget is written.
screen_locked() { as_session /usr/bin/omarchy-hyprland-session-locked 2>/dev/null; }
as_user /usr/bin/true || die "cannot run commands as $USER_NAME through sudo -u. Nothing was changed."
screen_locked && die "the screen is locked. Unlock it first: installing the widget reloads the shell, and Omarchy 4.0.2 crashes its shell when that happens under a lock."

# Nothing is replaced that tun0 VPN did not put there. Its files name themselves in their first lines ("tun0 VPN";
# vpn-root and the uninstaller of 1.0.0 by their own first comment), the dispatcher links point at its script, and
# /etc/vpn holds only its own entries. Anything else under one of these names stops the installation here.
OWN_MARKS=('tun0 VPN' 'Root side of `vpn`: kill switch, reconnect watchdog' 'Removes everything install.sh put on the system')
ETC_NAMES=' auth configs killswitch.nft killswitch.nft.in settings trusted release-signer installed-release settings.tmp trusted.tmp trusted.new '   # the .tmp and .new files of an interrupted write by the helper are its own
marked() { head -n 5 | grep -qF -e "${OWN_MARKS[0]}" -e "${OWN_MARKS[1]}" -e "${OWN_MARKS[2]}"; }
absent() { [[ ! -e "$1" && ! -L "$1" ]]; }
foreign=()
for f in /etc/sudoers.d/vpn "$ROOT" /usr/local/bin/vpn-uninstall "$ETC/killswitch.nft.in" \
         /etc/NetworkManager/dispatcher.d/90-vpn-killswitch /etc/systemd/system/vpn-killswitch.service; do
  absent "$f" || { [[ -f "$f" && ! -L "$f" ]] && marked < "$f"; } || foreign+=("$f")
done
for f in /etc/NetworkManager/dispatcher.d/pre-up.d/90-vpn-killswitch /etc/NetworkManager/dispatcher.d/pre-down.d/90-vpn-killswitch; do
  absent "$f" || [[ -L "$f" && "$(readlink -- "$f")" == ../90-vpn-killswitch ]] || foreign+=("$f")
done
if ! absent "$ETC"; then
  if [[ -L "$ETC" || ! -d "$ETC" ]]; then foreign+=("$ETC")
  else
    for e in "$ETC"/* "$ETC"/.[!.]*; do
      absent "$e" && continue
      n=${e##*/}
      [[ "$ETC_NAMES" == *" $n "* || "$n" == .killswitch.* ]] || { foreign+=("$ETC (it holds $n)"); break; }
    done
  fi
fi
# ~/.local/bin/vpn is read as the user, like everything else in the home directory
VPN_CMD=$HOME_DIR/.local/bin/vpn
if ! as_user /usr/bin/test ! -e "$VPN_CMD" -a ! -h "$VPN_CMD"; then
  { as_user /usr/bin/test -f "$VPN_CMD" -a ! -h "$VPN_CMD" && as_user /usr/bin/head -n 5 -- "$VPN_CMD" | marked; } || foreign+=("$VPN_CMD")
fi
(( ${#foreign[@]} == 0 )) || die "not put there by tun0 VPN, so left alone: ${foreign[*]}. If it is yours to replace, move it out of the way and paste the bootstrap again. Nothing was changed."

# What would otherwise fail half way, after the sudoers rule is gone: the user's own folders, the configs, and
# the credentials, asked for now.
user_can_create "$HOME_DIR/.local/bin" || die "$USER_NAME cannot write $HOME_DIR/.local/bin (the vpn command goes there). Fix its owner, e.g. sudo chown $USER_NAME: $HOME_DIR/.local/bin, and paste the bootstrap again. Nothing was changed."
PLUGIN_DIR="$HOME_DIR/.config/omarchy/plugins/$PLUGIN_ID"
WIDGET_GIT=0; as_user /usr/bin/test -d "$PLUGIN_DIR/.git" && WIDGET_GIT=1
if (( ! WIDGET_GIT )); then
  user_can_create "$PLUGIN_DIR" || die "$USER_NAME cannot write $PLUGIN_DIR (the widget goes there). Fix its owner and paste the bootstrap again. Nothing was changed."
fi
declare -A CRED_U=() CRED_P=()
args=("$@"); i=0
while (( i < ${#args[@]} )); do
  name=${args[i],,}; f=${args[i+1]}; prov=${name%%-*}; i=$(( i + 2 ))
  [[ "$name" =~ ^[a-z0-9]+-[a-z0-9]+$ ]] || die "profile name must be <provider>-<country>, lowercase, one dash: '$name'. Nothing was changed."
  as_user /usr/bin/test -f "$f" -a -r "$f" || die "$f: not a file $USER_NAME can read. Nothing was changed."
  if [[ ! -f "$AUTHD/$prov" && -z "${CRED_U[$prov]:-}" ]]; then
    [[ -t 0 ]] || die "no credentials for '$prov' and no terminal to ask on. Nothing was changed."
    echo "  Credentials for '$prov' (Proton: the OpenVPN/IKEv2 username from account.protonvpn.com, NOT your account password; Mullvad: account number, password 'm'):"
    read -rp "  Username: " u; read -rsp "  Password: " p; echo
    [[ -n "$u" && -n "$p" ]] || die "username and password are both required. Nothing was changed."
    CRED_U[$prov]=$u; CRED_P[$prov]=$p
  fi
done

echo "== 2/6 Root helper, dispatcher, kill switch unit, uninstaller (from the checked copies); the sudoers rule is removed first"
REVOKED=1; rm -f /etc/sudoers.d/vpn
install -d -m755 "$ETC" "$CONF"; install -d -m700 "$AUTHD"
install -D -o root -g root -m755 "$STAGE/vpn-root" "$ROOT"
install -D -o root -g root -m755 "$STAGE/90-vpn-killswitch" /etc/NetworkManager/dispatcher.d/90-vpn-killswitch
# pre-up and pre-down are the events NetworkManager waits for: the same script, linked there, shuts an untrusted
# network before its first packet and shuts an interface again before it can carry the next network
install -d -m755 /etc/NetworkManager/dispatcher.d/pre-up.d /etc/NetworkManager/dispatcher.d/pre-down.d
ln -sfn ../90-vpn-killswitch /etc/NetworkManager/dispatcher.d/pre-up.d/90-vpn-killswitch
ln -sfn ../90-vpn-killswitch /etc/NetworkManager/dispatcher.d/pre-down.d/90-vpn-killswitch
install -o root -g root -m644 "$STAGE/killswitch.nft.in" "$ETC/killswitch.nft.in"
install -D -o root -g root -m644 "$STAGE/vpn-killswitch.service" /etc/systemd/system/vpn-killswitch.service
systemctl daemon-reload
# A copy of the uninstaller outside the plugin folder: `omarchy plugin remove` deletes that folder
install -D -o root -g root -m755 "$STAGE/uninstall.sh" /usr/local/bin/vpn-uninstall
# 1.1.0 installed an updater that accepted any release the key signed. Updates go through the bootstrap now, so we remove it.
if [[ -f /usr/local/bin/vpn-update && ! -L /usr/local/bin/vpn-update ]] && head -n 5 /usr/local/bin/vpn-update | marked; then
  rm -f /usr/local/bin/vpn-update; echo "  vpn-update of an earlier release removed (updates go through the bootstrap in the README)"
elif [[ -e /usr/local/bin/vpn-update || -L /usr/local/bin/vpn-update ]]; then
  echo "  left alone: /usr/local/bin/vpn-update is not tun0 VPN's"
fi

echo "== 3/6 The vpn command, written as $USER_NAME"
# Written by the user, not by root: a root process that writes into a home directory follows whatever links the
# user has put there. The bytes come from the checked copy on stdin.
as_user /usr/bin/bash -c 'umask 022; mkdir -p "$1" && cat > "$1/.vpn.new" && chmod 755 "$1/.vpn.new" && mv -f "$1/.vpn.new" "$1/vpn"' _ "$HOME_DIR/.local/bin" < "$STAGE/vpn"

echo "== 4/6 Profiles"
profile_rc=0; i=0
while (( i < ${#args[@]} )); do
  name=${args[i],,}; f=${args[i+1]}; prov=${name%%-*}; i=$(( i + 2 ))
  if [[ -n "${CRED_U[$prov]:-}" && ! -f "$AUTHD/$prov" ]]; then
    printf '%s\n%s\n' "${CRED_U[$prov]}" "${CRED_P[$prov]}" | "$ROOT" auth "$prov" || { profile_rc=1; continue; }
  fi
  # The file is opened with the user's rights; root gets its bytes and never the path.
  as_user /usr/bin/cat -- "$f" | "$ROOT" add "$name" || { echo "  $name was not added (see above)" >&2; profile_rc=1; }
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

echo "== 6/6 Bar widget, then the sudoers rule, the release key and the installed release, last"
# The widget is an Omarchy shell plugin. A folder `omarchy plugin add` cloned is Omarchy's: it is left alone, and
# updated with `omarchy plugin update`. A folder without git (copied by an earlier installer, or missing) gets the
# checked widget files of this release, written as the user, and only files that differ.
if (( WIDGET_GIT )); then
  pv=$(as_user /usr/bin/cat "$PLUGIN_DIR/manifest.json" 2>/dev/null | manifest_version || true)
  if [[ -z "$pv" || "$(printf '%s\n%s\n' "$pv" "$version" | sort -V | head -1)" != "$version" ]]; then
    echo "  widget is ${pv:-unknown}, this release is $version: update it with  omarchy plugin update $PLUGIN_ID"
  elif [[ "$pv" != "$version" ]]; then
    echo "  widget is $pv, newer than this release $version: update the root side with the bootstrap in the README of $pv"
  fi
elif screen_locked; then
  echo "  the screen was locked meanwhile: widget files not written (a hot reload under the lock crashes the shell). Paste the bootstrap again after unlocking." >&2
else
  as_user /usr/bin/install -d "$PLUGIN_DIR"
  changed=0
  for f in "${WIDGET[@]}"; do
    have=$(as_user /usr/bin/cat "$PLUGIN_DIR/$f" 2>/dev/null | sha256sum || true)
    [[ "${have%% *}" == "$(sha256sum < "$STAGE/$f" | cut -d' ' -f1)" ]] && continue
    as_user /usr/bin/bash -c 'umask 022; cat > "$1.new" && chmod 644 "$1.new" && mv -f "$1.new" "$1"' _ "$PLUGIN_DIR/$f" < "$STAGE/$f"
    changed=1
  done
  if (( changed )); then echo "  widget files $version -> $PLUGIN_DIR"; else echo "  widget files already $version"; fi
fi
# Asking the shell to rescan and enable reloads it just the same, so not under a lock either.
if screen_locked; then
  echo "  the screen is locked: the shell is not asked to load the widget now. After unlocking: omarchy plugin enable $PLUGIN_ID" >&2
else
  as_session /usr/bin/omarchy-shell -q shell rescanPlugins || true
  # No placement: a widget that is not on the bar yet goes to the manifest's defaultSection (right), and one the user
  # has placed stays where it is. With a section given, the shell moves a placed widget there on every installation.
  if as_session /usr/bin/omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1; then echo "  plugin enabled: $PLUGIN_ID"
  else echo "  could not enable the plugin now (shell not running?); later: omarchy plugin enable $PLUGIN_ID"; fi
fi
install -o root -g root -m440 "$STAGE/sudoers" /etc/sudoers.d/vpn; REVOKED=0
echo "  sudoers rule written: user id $USER_UID may run $ROOT (SHA-256 ${VPN_ROOT_SHA256:0:12}...) in the forms listed in /etc/sudoers.d/vpn"
if [[ ! -e "$PINNED" ]]; then
  install -o root -g root -m644 "$STAGE/allowed_signers" "$PINNED"
  # ssh-keygen reads a key, not an allowed_signers line: hand it the key part only
  fp=$(cut -d' ' -f3- "$STAGE/allowed_signers" | ssh-keygen -lf - 2>/dev/null | cut -d' ' -f2 || true)
  echo "  release key pinned in $PINNED: ${fp:-fingerprint unknown}. A later release with another key is refused."
  echo "  Compare that fingerprint with the README and with https://api.github.com/users/rogertobler/ssh_signing_keys."
fi
printf '%s %s\n' "$version" "$head" > "$STAGE/installed-release"
install -o root -g root -m644 "$STAGE/installed-release" "$RECORD"

echo
echo "Done: tun0 VPN $version. Profiles: $(as_user "$HOME_DIR/.local/bin/vpn" list 2>/dev/null | paste -sd' ')"
echo "Try it as $USER_NAME:  vpn add <file.ovpn>   /   vpn on   /   vpn status   /   vpn off   - or click the shield icon"
(( rebuild_rc == 0 )) || echo "WARNING: at least one profile could not be imported (see above). Wrong credentials? vpn remove <name>?" >&2
if (( rebuild_rc != 0 || profile_rc != 0 )); then exit 1; fi
exit 0
