# XUI-SPM - X-UI Smart Panel Manager

One Bash script to manage **NX Panel**, **3x-ui (MHSanaei)**, **Alireza x-ui** and classic **x-ui (vaxilu)**:

- **Smart backup** - consistent SQLite snapshot, optional AES-256 encryption, panel type auto-detected.
- **Migrate / restore** - exact database import into 3x-ui / Alireza / x-ui, or guided NX Panel migration. Test mode shows the same checks as a real migration (with a server score). Runs on this server or on a remote one over SSH.
- **Inspect a backup** - users, domains, inbounds, exposure, certificates.
- **Install / update a panel** - optional Nginx + HTTPS.
- **System optimization** - expired/unused certificates, old backups, leftovers, server check and scoring (hardware, network, NAT, GitHub access), VPN stealth check, full system update.
- **Self-update** from this repository, verified by SHA-256.

English and Persian (Farsi) interface. Needs Linux (Debian/Ubuntu recommended), Bash 4.4+, `curl`, `python3`, `sqlite3`, `openssl`, run as root.

## Install (with checksum verification)

```bash
curl -fsSLO https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/XUI-SPM.sh
curl -fsSLO https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/XUI-SPM.sh.sha256
sha256sum -c XUI-SPM.sh.sha256      # must print: XUI-SPM.sh: OK
sudo bash XUI-SPM.sh
```

Compare the hash with the one on the [Releases](https://github.com/YOUR_USER/YOUR_REPO/releases) page too: if the two sources disagree, do not run the file.

## Options

```
sudo bash XUI-SPM.sh [--no-color] [--no-anim] [--fancy | --safe-icons]
                               [--verify] [--check-update] [--self-update] [--help] [--version]
```

`NO_COLOR=1`, `MOC_NO_ANIM=1` and `MOC_UPDATE_URL=<raw url>` are also understood.

## Privacy and safety

- **No password is ever stored.** The optional saved-server list (`/etc/moc-networks/servers.dat`, encoded, mode 600) keeps only name, address, SSH port, status, score and location.
- Backups can be encrypted (AES-256-CBC, PBKDF2). Keep the password: there is no recovery.
- Updates and installers are downloaded over HTTPS only; the script checks syntax and, when a `.sha256` file is published next to it, the hash.
- Read the script before running it as root - that is good practice for any script you download.

## Updating

Main menu -> **Update this script**, or `sudo bash XUI-SPM.sh --self-update`. The previous version is kept as `*.bak-<version>`.

## License

MIT - see [LICENSE](LICENSE).
