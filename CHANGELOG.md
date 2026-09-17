# Changelog

All notable changes to tun0 VPN are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The version in `manifest.json` is the single source of truth. Since 1.1.1 every release is two signed commits on `main`:
the release commit, tagged `vX.Y.Z`, and on top of it a commit that only writes that commit's hash and the digest of its
`SHA256SUMS` into the README. A GitHub release carries the section below. Between releases `main` stands still, because
the Omarchy marketplace pins a listing to an exact commit.

## [1.1.1] 2026-09-17

The root side is installed and updated by a bootstrap that checks a release before any of it runs. The installation
and update commands change; see Install and Update in the README.

### Security

* Installing no longer clones a tag and starts its `install.sh`, which checked the release only once it was already
  running as root. A bootstrap pasted from the README, running as root with an empty environment and full paths,
  fetches exactly one release commit by its full hash into an empty repository, checks that the commit is signed by
  the release key and that its `SHA256SUMS` has the digest the README names, and only then checks the files out,
  checks each against `SHA256SUMS` and starts `install.sh --commit` (marketplace security review).
* Before it touches anything the bootstrap refuses placeholder values, a directory above `/usr/local/lib/tun0-vpn`
  that anyone but root can write to, and, on an update, a key other than the pinned one. It and `install.sh` let only
  `ssh-keygen` check a signature: an OpenPGP or X.509 signature is refused instead of going to gpg.
* `SHA256SUMS` lists `install.sh` too.
* `install.sh` requires `--commit`, checks that the checkout is exactly that commit, unmodified, and that the commit is
  signed by the release key; it no longer depends on a tag or on how the clone was made.
* `vpn-update` is gone: it accepted any release the key signed. An update is the bootstrap with the values of the newer
  release. `install.sh` removes the `vpn-update` of 1.1.0.
* Each release is two commits: the signed release commit with its tag, and a signed commit that only writes that
  commit's hash and the digest of its `SHA256SUMS` into the README.

## [1.1.0] 2026-09-17

The root side no longer trusts anything from a folder you can write to. The installation and update commands
change; see Install and Update in the README.

### Security

* `install.sh` runs only from a release that root clones into `/usr/local/lib/tun0-vpn`, never from the plugin
  folder, which belongs to the user and to every program the user runs. Before it changes anything it checks that
  every directory from `/` down to that tree and everything in it belongs to root and is writable by root only,
  that the checkout is the unmodified commit of the release tag, and that the tag is signed by the release key.
  The key is pinned in `/etc/vpn/release-signer` at the first installation (marketplace security review).
* Updates go through `/usr/local/bin/vpn-update vX.Y.Z`, the updater of the release installed now: it checks the
  new tag against the pinned key, the version in the tagged commit, and that the release is not older than the
  installed one, before anything of the new release runs. It fetches the tag afresh into a ref of its own every
  time and checks that the signed tag names itself as the release asked for. `install.sh` refuses an older release,
  and a clone holding a tag under another name than its own. At the first installation it prints the fingerprint it
  pins.
* Each file `install.sh` installs, the widget files included, is checked in the tree for its canonical path, owner and
  mode, copied into a staging directory only root can read, and the SHA-256 of that copy is checked against
  `SHA256SUMS` in the signed commit. That copy is what is installed; a file changed in the tree after the check does
  not reach the system.
* `install.sh` checks what would otherwise fail after the sudoers rule is gone (the user's folders, the configs on
  its command line, their credentials) before it removes the rule, and says so if it stops half way. Git runs with
  root's own home and no global configuration.
* The sudoers rule admits `vpn-root` only in the argument forms the user side sends, names the user by id, and
  leaves out the verbs only the dispatcher and the units call as root. Every form carries the SHA-256 of the installed
  `vpn-root`, which sudo checks on each call right before it runs the helper, so a helper changed after the
  installation is refused. `install.sh` removes the rule first and writes it last.
* `install.sh` refuses a clone not made with `--branch v<version>`: a branch or an unsigned tag named like a newer
  release on the commit of an older one would have installed that older release. `vpn-update` records the tag it
  installs the same way, and removes the fetched candidate again whatever stops it; its fetch is bounded in time.
* `install.sh` and `vpn-uninstall` touch only what is tun0 VPN's: a file under one of its names that another package
  or the admin put there (`/etc/sudoers.d/vpn`, `~/.local/bin/vpn`, a dispatcher link, an entry in `/etc/vpn`) stops
  the installation and is left by the removal. A NetworkManager connection is brought up, taken down and deleted only
  by UUID and only if it is a VPN (`vpn on`, `vpn off`, the watchdog, removal), so a Wi-Fi named like a profile is never
  touched.
* Credentials reach NetworkManager through libnm instead of an `nmcli` argument, so the password no longer shows in
  the process list during an import.
* OpenVPN script and plugin hooks (`up`, `down`, `plugin`, `script-security` and the like) are removed from the copy of
  a config that is imported. NetworkManager's importer already ignored them; root no longer relies on that. The
  helper starts as `bash -p`.
* The kill switch lets each VPN server through only on the port and protocol its config names (address and port
  pairs per protocol); before, every listed server was reachable on every listed port.
* Inputs of the root helper have limits and are refused above them: credentials 4 KiB, a trusted name 128 bytes,
  1024 trusted names, 64 profiles, 4096 server endpoints.
* The widget runs `vpn` by absolute path under a timeout, with a cleared environment, keeps at most 256 KiB of its
  output, and shows everything as plain text. `vpn json` and `vpn public` build their JSON with `jq` and clean every
  string from the network or a config of control and direction characters.
* `vpn-root` checks every argument against a fixed form before using it. An interface name with a quote in it could
  have added commands of its own to the nft batch that fills the open set; a profile name with a path in it could
  have armed a config outside `/etc/vpn/configs`.
* `vpn-root add` takes the config on stdin and `vpn-root auth` the credentials, so root never opens a path its
  caller names. The installer opens the configs named on its command line with the user's rights.
* A config that names a file for a certificate, a key or proxy credentials is refused. NetworkManager's importer runs
  as root in `vpn-root add`; it read an `http-proxy` or `socks-proxy` credentials file right away and stored its first
  line where the user can read it, so the first line of any file root can read was one `vpn add` away. Since 1.0.0.
  A control character inside a line is refused as well (the importer splits a line there), `[inline]` is no
  exception, and the check runs again before every import, for configs stored by 1.0.0.
* A remote host token that starts with a dash is refused; `trust set` refuses a list over 64 KiB instead of cutting
  it, where a cut line would have become a trusted network.
* The helper, the installer, the updater and the uninstaller find their tools through `PATH=/usr/bin` only, never
  through the caller's `PATH`, and run with `LC_ALL=C`; `vpn` calls `/usr/bin/sudo` by its full path.
* Root no longer writes into the home directory: the `vpn` command, the widget files and their removal go through
  `sudo -u` with the user's rights, so a link placed there leads nowhere the user could not go.
* The migration of settings from versions before 1.0.0, which read files in the home directory as root, is gone.
* `uninstall.sh` runs only as `/usr/local/bin/vpn-uninstall` or from the release, and removes the release and
  `vpn-update` too. A step in the home directory that fails no longer stops the removal of the root parts, and it
  takes down only this plugin's tunnels, no longer every VPN. `--keep-profiles` keeps the pinned key and drops the
  record of the installed release.

### Changed

* `install.sh` no longer installs `networkmanager-openvpn` with pacman. It checks for it and for the other
  requirements before it changes anything and names what is missing; install it first
  (`sudo pacman -S --needed networkmanager-openvpn`).
* The public IP lookup (ipinfo.io) is one bounded HTTPS request without redirects, keeps only four checked fields,
  and can be turned off with `vpn lookup off`; the panel then says so.
* The panel says the state is unknown when `vpn json` fails, instead of showing the last good state, and acts on
  nothing until it can read the state again (right-click then refreshes).
* The fingerprint `install.sh` prints for the key it pins is the real one (it printed "fingerprint unknown").

* `install.sh` no longer removes the bar module and menu block that versions before 1.0.0 wrote into `shell.json`
  and `omarchy-menu.jsonc`, and no longer sets a default profile; `vpn-root add` does that for the first profile.
* A widget folder without git (the copy of an earlier installer) gets the widget files of the release; a folder
  `omarchy plugin add` cloned is left to `omarchy plugin update`, and `install.sh` says when it is older.
* `vpn version` also says when the root side is a different release than the widget.
* Certificates and keys in a config have to be inline (`<ca>...</ca>`); Windows line ends are converted.
* A `remote` line without a port is accepted and gets the config's `port` or `rport`, else OpenVPN's 1194, in the kill
  switch.
* User names with capitals or dots are accepted by the installer and the uninstaller.

### Fixed

* The installer never enabled the plugin, and the uninstaller never disabled it, rescanned the plugins or refreshed
  the menu. They call `omarchy`, `omarchy-shell` and `omarchy-menu` through `sudo -u`, which starts from an empty
  environment, and all three refuse to run without `OMARCHY_PATH`; `omarchy-shell -q` then ends with success and does
  nothing. Both now pass `OMARCHY_PATH=/usr/share/omarchy`. The installer enables the widget without a placement: a
  new one goes to the right of the bar, one you have placed stays where it is.
* The uninstaller removed the widget and rescanned the plugins without checking the screen lock, which crashes the
  shell under a lock, and the installer rescanned and enabled after its second check without asking again. Both check
  first now; a lock that comes while the uninstaller runs leaves the widget in place and names the commands for after.
* `trust add` kept to the limit of 1024 trusted names that `trust set` enforces; one add too many made `vpn trust edit`
  fail. A refused profile at the limit of 64 forgets the credentials of a new provider, like any other failed add.
* Trusting or forgetting a network from the panel or a toast acts on the network itself when its name holds control or
  direction characters, which the panel shows cleaned.
* `vpn status --ip` no longer shifts the fields when the city or the country is empty.
* Temporary files the helper leaves after an interrupted write no longer count as foreign for `install.sh`, and
  `vpn-uninstall` removes them; what it leaves in `/etc/vpn` or `~/.config/vpn` it names.

* A failed NetworkManager import during `vpn add` reported success and left the config behind; it now fails and
  rolls the config back.
* A failed `vpn add` left the credentials of a new provider stored with no profile, so the wizard never asked for
  them again; they are forgotten now when no profile of that provider is left.
* A connection UUID in the older 40-hex form NetworkManager still accepts is no longer treated as invalid.
* `install.sh` no longer hangs when `sudo -u` cannot run anything, and a hang-up of the terminal after the sudoers rule
  was removed is reported like any other stop.
* The clipboard copy of a config in the `vpn add` wizard is removed on every way out, "Cancelled." included.

## [1.0.0] 2026-09-09

First public release. Built and used daily on Omarchy 4.0.2 since 8 September 2026.

### Added

* OpenVPN profiles as NetworkManager connections named `<provider>-<country>`, so several providers and countries
  live side by side and switching country is one click. Nothing connects on its own unless you ask for it.
* A kill switch of its own: an nftables table `vpn_ks` that allows only the tunnel, the handshake to the VPN
  endpoints, DHCP, loopback and the interfaces in its `open` set. It is loaded at boot, before NetworkManager,
  with nothing open, and stays for good: an interface is opened by the NetworkManager dispatcher at `pre-up`
  when it is a cable or a trusted Wi-Fi, and kept shut when a VPN is wanted or the Wi-Fi is untrusted with
  auto-connect on. Shut is the default; events only open. It survives a dropped tunnel, which is the moment
  traffic would otherwise leak, and it is in place before the first packet of an untrusted network, also before login.
* A two stage reconnect: OpenVPN reconnects itself, and if NetworkManager gives up, a transient systemd watchdog
  retries every 10 seconds while the kill switch stays up.
* A bar widget for the Omarchy shell with a panel: profiles, trusted Wi-Fi networks, kill switch, throughput
  sparkline, the country and provider you are seen as, keyboard navigation and search.
* Trusted Wi-Fi networks with optional auto connect on foreign networks and auto disconnect at home, decided
  as root in the dispatcher before the interface is usable, with a manual override that survives until you
  change network, change the trust of that network or flip an automation switch. The list, both switches and the default profile live in `/etc/vpn`.
* An import wizard without the terminal: `vpn add` takes an `.ovpn` file, the clipboard or a path, asks for the
  credentials and writes them root only. `vpn remove` takes the credentials with the last profile of a provider.
* `vpn status` checks from the outside through ipinfo.io instead of trusting the tunnel state, and warns when the
  country you see is not the country you asked for.
* `install.sh` and `uninstall.sh` for the parts a plugin cannot install by itself, plus `vpn version`.

### Security

* The sudoers rule allows exactly one fixed helper script, with no wildcard, no shell and no interpreter.
* `vpn-root remove` only accepts profiles it manages, so the password free rule cannot be turned against an
  unrelated NetworkManager connection such as your Wi-Fi.
* The kill switch marker records intent, not the state of the table; the state is written by root to
  `/run/vpn-killswitch.open`, so the poll never has to ask. `vpn on` shuts the uplink before the handshake and
  supersedes a connect that is still negotiating instead of racing it: the first attempt steps back.
* The IPv6 exception in the kill switch is neighbour discovery, router advertisements, MLD and DHCPv6 only. The
  whole link-local range let mDNS and LLMNR out on a shut interface (found in review).
* A Wi-Fi name is compared as one exact line. An SSID may contain a line break, and `grep -F` reads a multi
  line pattern as a list, so "Hotel WiFi" followed by a trusted name on a second line would have counted as
  trusted; now such a name is no name at all and the interface stays shut, `vpn off` still releases it (found in review).
* `vpn-root remove` validates the profile name like `add`, so the password free helper cannot be pointed at a file
  outside its config directory.
* Trusted networks and settings are written only through the root helper: an SSID is data in a root owned
  file, never interpreted; a setting is one of four fixed keys with fixed values.
* The installer refuses to run while the screen is locked, because writing into the live plugin folder makes the
  shell hot reload and Omarchy 4.0.2 crashes when that happens under an active lock.

[1.1.1]: https://github.com/rogertobler/omarchy-tun0-vpn/releases/tag/v1.1.1
[1.1.0]: https://github.com/rogertobler/omarchy-tun0-vpn/releases/tag/v1.1.0
[1.0.0]: https://github.com/rogertobler/omarchy-tun0-vpn/releases/tag/v1.0.0
