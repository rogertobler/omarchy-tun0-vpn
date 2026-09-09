# Changelog

All notable changes to tun0 VPN are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The version in `manifest.json` is the single source of truth. Every release is one commit on `main`, tagged
`vX.Y.Z`, with a GitHub release carrying the section below. Between releases `main` stands still, because the
Omarchy marketplace pins a listing to an exact commit.

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

[1.0.0]: https://github.com/rogertobler/omarchy-tun0-vpn/releases/tag/v1.0.0
