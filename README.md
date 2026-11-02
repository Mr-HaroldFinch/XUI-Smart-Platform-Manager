![X-UI Smart Platform Manager](assets/banner.png)
# 🚀 Universal X-UI Panel Manager (X-UI Smart Platform Manager)

[![License: GPL v3](https://shields.io)](https://gnu.org)
[![Bash Version](https://shields.io)](https://gnu.org)
[![Version](https://shields.io)](#)

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

### Method 1: Execute Instantly via Curl (Recommended)
Run the orchestration utility immediately with a single line of code:
```bash
bash <(curl -Ls https://raw.githubusercontent.com/Mr-HaroldFinch/XUI-Smart-Platform-Manager/X-UI-smart-manager.sh)"
```

### Method 2: Execute Instantly via Wget (Alternative)
If `curl` is missing on your minimal Linux template, use `wget`:
```bash
bash <(curl -Ls https://raw.githubusercontent.com/Mr-HaroldFinch/XUI-Smart-Platform-Manager/X-UI-smart-manager.sh)"
```

### Method 3: Download and Run Separately
If you prefer to persist the script locally before invocation:
```bash
# Download the script file
curl -O https://raw.githubusercontent.com/Mr-HaroldFinch/XUI-Smart-Platform-Manager/X-UI-smart-manager.sh

# Grant execution permissions
chmod +x X-UI-smart-manager.sh

# Run with root privileges
sudo ./X-UI-smart-manager.sh
```
---

## 🚀 Usage

Run the utility interactively using standard execution:
```bash
sudo ./X-UI-smart-manager.sh
```
*Upon launch, a highly intuitive visual menu will assist you in selecting your preferred UI interface language (**English** or **فارسی**).*

### Terminal Arguments & Switches
Fine-tune the behavior of the manager using the following CLI arguments:

| Switch | Description |
| :--- | :--- |
| `--verify` | Skips main loops and forces a post-migration status re-check on local DNS and system health. |
| `--self-update` | Pulls down the latest verified version of the core script straight from GitHub. |
| `--check-update` | Run an isolated query check against GitHub to view version parity. |
| `--no-anim` | Disables character-typewriter visual layouts and shimmer effects (ideal for raw logs). |
| `--no-color` | Strips ANSI sequence tags out of output descriptors for strict plain text logging. |
| `-h`, `--help` | Prints standard execution flags and system documentation. |

#### Example Commands:
```bash
# Run isolated background health checks on current inbounds
sudo ./X-UI-smart-manager.sh --verify

# Force clean interface formatting for remote logging devices
sudo ./X-UI-smart-manager.sh --no-anim --no-color
```


---

## 📄 License

This project is licensed under the **GPL v3 (GNU General Public License v3)**. You are free to redistribute, modify, and utilize this orchestration engine under the condition that all derived downstream products remain entirely open-source. For detailed declarations, see the [LICENSE](LICENSE) file.

