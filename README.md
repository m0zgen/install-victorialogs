# VictoriaLogs Automated Installer Script

A lightweight, robust Bash script designed to automatically fetch, install, update, and manage the **VictoriaLogs** Community Open Source release on Linux systems (`systemd`-based).

## Features

- **Automated Latest Release Detection**: Queries the GitHub REST API to fetch the newest stable Community release directly from [`VictoriaMetrics/VictoriaLogs`](https://github.com/VictoriaMetrics/VictoriaLogs).
- **Enterprise Asset Exclusion**: Automatically filters out Enterprise builds to prevent license check errors (`VictoriaMetrics Enterprise license is required`).
- **Architecture Auto-Detection**: Supports `x86_64` (`amd64`), `aarch64` (`arm64`), and `armv7l`.
- **Systemd Integration**: Configures a dedicated system user (`victorialogs`), sets up storage paths, and generates an auto-restarting `systemd` service unit.
- **Full Life-cycle Management**: Supports clean uninstallation with optional data purging (`--purge`).

---

## Prerequisites

Ensure the required dependencies are installed on your Linux system.

### Debian / Ubuntu
```bash
sudo apt update && sudo apt install -y curl jq tar
```

### RHEL / CentOS / Rocky Linux / Fedora
```bash
sudo dnf install -y curl jq tar
```

---

## Quick Start

1. **Make the script executable:**
   ```bash
   chmod +x install-victorialogs.sh
   ```

2. **Run the installer as root (or via sudo):**
   ```bash
   sudo ./install-victorialogs.sh
   ```

### Default Layout
- **Binary path:** `/opt/victorialogs/victoria-logs-prod`
- **Global symlink:** `/usr/local/bin/victoria-logs-prod`
- **Data directory:** `/var/lib/victoria-logs-data`
- **Systemd unit:** `/etc/systemd/system/victorialogs.service`
- **HTTP Port:** `9428`

---

## Usage & Verification

### Check Service Status
```bash
systemctl status victorialogs
```

### Endpoints
- **LogsQL Web UI (`vmui`):** `http://<SERVER_IP>:9428/select/vmui`
- **JSON Lines Ingestion:** `http://<SERVER_IP>:9428/insert/jsonline`

### Test Ingestion via `curl`
```bash
curl -X POST -H 'Content-Type: application/stream+json' \
  --data-binary '{"account_id":0,"project_id":0,"msg":"Test log line","level":"info"}' \
  'http://localhost:9428/insert/jsonline'
```

---

## Service Management

- **View Live Logs:**
  ```bash
  journalctl -u victorialogs -f
  ```
- **Restart Service:**
  ```bash
  sudo systemctl restart victorialogs
  ```

---

## Uninstallation

### Standard Removal (Preserves Stored Log Data)
Stops the service, removes binaries, systemd units, and system user, but keeps `/var/lib/victoria-logs-data` untouched:
```bash
sudo ./install-victorialogs.sh --uninstall
```

### Complete Removal (Purges All Logs)
Completely removes VictoriaLogs and **deletes all stored log data**:
```bash
sudo ./install-victorialogs.sh --uninstall --purge
```
