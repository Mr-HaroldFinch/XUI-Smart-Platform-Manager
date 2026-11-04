![X-UI Smart Platform Manager](assets/banner.png)
# 🚀 Universal X-UI Panel Manager (X-UI Smart Platform Manager)

An enterprise-grade, interactive Linux shell script powered by **MOC Networks Smart Solution** for seamless management, secure multi-mechanism backups, zero-downtime migrations, and performance optimization of X-UI family panels (`NX Panel`, `3x-ui`, `Alireza x-ui`, and `classic x-ui`).

---

## ✨ Key Features

- **🌐 Multi-Panel Hybrid Support:** Fully compatible with NX Panel, 3x-ui (MHSanaei), Alireza, and classic vaxilu x-ui environments.
- **📦 Smart & Consistent Backups:** Performs consistent online SQLite database snapshots (preventing WAL format data loss) combined with robust **AES-256-CBC (PBKDF2)** military-grade encryption.
- **🔄 Direct SSH Live Migration:** Generates secure handshakes to seamlessly push backups and transfer dependencies directly from an old server to a new destination over custom SSH ports.
- **🔍 Advanced Deep Inspection:** Inspects backup archives prior to restoration, auditing inbound protocols, configurations, dynamic traffic logs, and active users.
- **🛡️ Pre-Flight Infrastructure Report & Audits:** Analyzes public IPv4/IPv6 reputation against major global DNSBL blacklists, evaluates hardware health score benchmarks, and profiles latency metrics.
- **🚀 Automated Nginx & HTTPS Stack:** Automated Nginx reverse-proxy installation featuring seamless Let's Encrypt Certbot integration for immediate SSL provisioning.
- **🧹 System Optimizer & Cleaners:** Smart scanner to scrub expired or unused TLS certificates, safely flush redundant legacy backups, and clean rollback leftovers.

---

## 📋 Prerequisites

The script strictly requires **Bash 4.4 or newer** and must be executed with **root privileges** (`sudo`). 

### Required Tools
The manager features a **built-in adaptive package collector** that can automatically fetch missing components on Debian/Ubuntu systems. However, ensuring these core packages are present is highly recommended:
- `openssl` (for AES-256 encryption/decryption workflows)
- `sqlite3` (for transaction-safe database backups and audits)
- `curl` & `wget` (for fetching installers and API lookups)
- `tar` & `gzip` / `unzip` (for secure file archiving operations)
- `dnsutils` (`dig`) & `iputils-ping` (for DNS profiling and live network checks)
- `openssh-client` & `sshpass` (optional, for automated background network syncs)

---

## ⚙️ Quick Start (No Installation Required)

You do not need to install this script or clone the repository. It is designed to be fetched and executed instantly in-memory or directly on any Linux server.

English and Persian (Farsi) interface. Needs Linux (Debian/Ubuntu recommended), Bash 4.4+, `curl`, `python3`, `sqlite3`, `openssl`, run as root.

## Install (with checksum verification)

```bash
curl -fsSLO https://raw.githubusercontent.com/Mr-HaroldFinch/XUI-Smart-Platform-Manager/main/XUI-SPM.sh
curl -fsSLO https://raw.githubusercontent.com/Mr-HaroldFinch/XUI-Smart-Platform-Manager/main/XUI-SPM.sh.sha256
sha256sum -c XUI-SPM.sh.sha256      # must print: XUI-SPM.sh: OK
sudo bash XUI-SPM.sh
```

Compare the hash with the one on the [Releases](https://github.com/Mr-HaroldFinch/XUI-Smart-Platform-Manager/releases) page too: if the two sources disagree, do not run the file.

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
