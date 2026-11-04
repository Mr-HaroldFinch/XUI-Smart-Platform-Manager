# Changelog

## 1.2026.11.4
- The script is now named **XUI-SPM** (X-UI Smart Panel Manager): file `XUI-SPM.sh`, banner, menus, help and documentation.

## 1.2026.11.3
- Fixed: "Download sources" always showed UNREACHABLE (HTTP 000) - the check now reports the real result.
- Public and internal IP addresses are shown together (internal only when no public address can be found).
- Remote work: SSH login happens once; "the system is working" messages while inspecting, copying and starting.
- Short terminals get a compact, fixed header so menus never push the logo away.
- Goodbye screen on exit; clearer "return to the original server" hint and Esc / 0 in the remote main menu.
- Backup list shows only readable, valid archives.
- New: full system update in System optimization (apt update / upgrade / dist-upgrade / autoremove / autoclean) with a readable report.
- VPN stealth check reworked: a remote server can act as the outside observer of this server; active-probe, open-proxy, SSTP, certificate and TLS checks; plain-language report.

## 1.2026.11.2
- Server check with scoring (hardware, network, NAT, GitHub access) for this server and for remote servers; saved server list (.dat, no passwords); restore on a remote server over SSH.
- Test mode of the migration shows the same checks as a real migration, with a server score.
- Simple characters for icons by default (--fancy for emoji).

## 1.2026.11.1
- Language menu, animated header, typing effect, certificate cleanup, merged install/update menu, self-update, remote-host banner, infrastructure report, Back in every menu.
