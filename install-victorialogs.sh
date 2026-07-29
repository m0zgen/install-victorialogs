#!/usr/bin/env bash
#
# VictoriaLogs Automated Installer & Uninstaller Script for Linux
# Fetches the latest Community Open Source release directly from VictoriaMetrics/VictoriaLogs.
#
# Usage:
#   sudo ./install-victorialogs.sh            # Install or Update
#   sudo ./install-victorialogs.sh --uninstall # Uninstall service & binary
#   sudo ./install-victorialogs.sh -u --purge  # Uninstall and remove all data logs
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

INSTALL_DIR="/opt/victorialogs"
DATA_DIR="/var/lib/victoria-logs-data"
BIN_DEST="${INSTALL_DIR}/victoria-logs-prod"
SERVICE_USER="victorialogs"
SERVICE_PATH="/etc/systemd/system/victorialogs.service"
SYMLINK_PATH="/usr/local/bin/victoria-logs-prod"

# Root check
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root (or with sudo)."
fi

# ==========================================
# UNINSTALL LOGIC
# ==========================================
uninstall_victorialogs() {
    local purge_data=false
    if [[ "${1:-}" == "--purge" || "${2:-}" == "--purge" ]]; then
        purge_data=true
    fi

    log_info "Starting VictoriaLogs uninstallation..."

    if systemctl is-active --quiet victorialogs 2>/dev/null; then
        log_info "Stopping victorialogs service..."
        systemctl stop victorialogs || true
    fi

    if systemctl is-enabled --quiet victorialogs 2>/dev/null; then
        log_info "Disabling victorialogs service..."
        systemctl disable victorialogs || true
    fi

    if [[ -f "${SERVICE_PATH}" ]]; then
        log_info "Removing systemd unit file..."
        rm -f "${SERVICE_PATH}"
        systemctl daemon-reload
    fi

    if [[ -L "${SYMLINK_PATH}" || -f "${SYMLINK_PATH}" ]]; then
        log_info "Removing symlink ${SYMLINK_PATH}..."
        rm -f "${SYMLINK_PATH}"
    fi

    if [[ -d "${INSTALL_DIR}" ]]; then
        log_info "Removing installation directory ${INSTALL_DIR}..."
        rm -rf "${INSTALL_DIR}"
    fi

    if id -u "${SERVICE_USER}" &>/dev/null; then
        log_info "Removing system user ${SERVICE_USER}..."
        userdel "${SERVICE_USER}" 2>/dev/null || true
    fi

    if [[ "${purge_data}" == true ]]; then
        log_warn "Purging all data from ${DATA_DIR}..."
        rm -rf "${DATA_DIR}"
    else
        if [[ -d "${DATA_DIR}" ]]; then
            log_info "Data directory ${DATA_DIR} preserved. Use '--purge' to delete it."
        fi
    fi

    log_success "VictoriaLogs has been successfully uninstalled!"
    exit 0
}

# Check for uninstall flag
if [[ "${1:-}" == "--uninstall" || "${1:-}" == "-u" ]]; then
    uninstall_victorialogs "$@"
fi

# ==========================================
# INSTALLATION / UPDATE LOGIC
# ==========================================

# Check required tools
for cmd in curl jq tar uname systemctl; do
    if ! command -v "$cmd" &> /dev/null; then
        log_error "Required utility '$cmd' is not installed. Please install it first."
    fi
done

# Architecture detection
ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64|amd64) VL_ARCH="amd64" ;;
    aarch64|arm64) VL_ARCH="arm64" ;;
    armv7l)       VL_ARCH="arm" ;;
    *)            log_error "Unsupported architecture: ${ARCH}" ;;
esac

log_info "Detected architecture: ${VL_ARCH}"

# Fetch latest Community (non-enterprise) release from GitHub API
GITHUB_REPO="VictoriaMetrics/VictoriaLogs"
API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"

log_info "Fetching latest release from GitHub (${GITHUB_REPO})..."

RELEASE_JSON=$(curl -sSL -H "Accept: application/vnd.github+json" "${API_URL}" || true)

if [[ -z "${RELEASE_JSON}" ]] || echo "${RELEASE_JSON}" | jq -e '.message' &>/dev/null; then
    log_error "Failed to retrieve release info from GitHub API."
fi

TAG_NAME=$(echo "${RELEASE_JSON}" | jq -r '.tag_name // empty')
log_info "Latest release version found: ${TAG_NAME}"

# ------------------------------------------
# CHECK EXISTING INSTALLATION & VERSION
# ------------------------------------------
CURRENT_VERSION=""
if [[ -f "${BIN_DEST}" ]]; then
    log_info "Existing installation detected at ${BIN_DEST}"
    CURRENT_VERSION=$("${BIN_DEST}" -version 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)
    
    if [[ -n "${CURRENT_VERSION}" ]]; then
        log_info "Currently installed version: ${CURRENT_VERSION}"
        if [[ "${CURRENT_VERSION}" == "${TAG_NAME}" ]]; then
            log_success "VictoriaLogs is already up-to-date (${CURRENT_VERSION}). Nothing to do."
            exit 0
        else
            log_warn "New version available! Upgrading from ${CURRENT_VERSION} to ${TAG_NAME}..."
        fi
    else
        log_warn "Could not determine current version. Proceeding with clean binary update..."
    fi
fi

# Filter OUT 'enterprise' assets to get Community Open Source build
DOWNLOAD_URL=$(echo "${RELEASE_JSON}" | jq -r ".assets[] | select(.name | test(\"victoria-logs-linux-${VL_ARCH}-.*\\\\.tar\\\\.gz$\") and (contains(\"enterprise\") | not)) | .browser_download_url" | head -n 1)

if [[ -z "${DOWNLOAD_URL}" || "${DOWNLOAD_URL}" == "null" ]]; then
    log_error "Could not find a valid Community VictoriaLogs asset for architecture ${VL_ARCH} in release ${TAG_NAME}."
fi

# Download and extract
TMP_DIR=$(mktemp -d -t victorialogs-install-XXXXXX)
trap 'rm -rf "${TMP_DIR}"' EXIT

log_info "Downloading Community binary from: ${DOWNLOAD_URL}..."
curl -sSL --fail "${DOWNLOAD_URL}" -o "${TMP_DIR}/victorialogs.tar.gz" || log_error "Failed to download archive."

log_info "Extracting package..."
tar -xzf "${TMP_DIR}/victorialogs.tar.gz" -C "${TMP_DIR}"

BIN_SRC=$(find "${TMP_DIR}" -type f -name "victoria-logs-prod" | head -n 1)
if [[ -z "${BIN_SRC}" ]]; then
    log_error "Binary 'victoria-logs-prod' was not found inside the downloaded archive."
fi

# Stop service gracefully if running before binary update
if systemctl is-active --quiet victorialogs 2>/dev/null; then
    log_info "Stopping active victorialogs service for binary update..."
    systemctl stop victorialogs
fi

# System user and directory layout
log_info "Setting up system user and storage paths..."

if ! id -u "${SERVICE_USER}" &>/dev/null; then
    useradd --system --no-create-home --shell /bin/false "${SERVICE_USER}"
    log_info "Created system user: ${SERVICE_USER}"
fi

mkdir -p "${INSTALL_DIR}" "${DATA_DIR}"

log_info "Installing binary to ${BIN_DEST}..."
cp -f "${BIN_SRC}" "${BIN_DEST}"
chmod 0755 "${BIN_DEST}"
chown -R "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}" "${DATA_DIR}"

ln -sf "${BIN_DEST}" "${SYMLINK_PATH}"

# Systemd unit creation
log_info "Ensuring systemd unit configuration..."

cat << EOF > "${SERVICE_PATH}"
[Unit]
Description=VictoriaLogs Service (Log Management and Aggregation)
Documentation=https://docs.victoriametrics.com/victorialogs/
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
ExecStart=${BIN_DEST} \\
    -storageDataPath=${DATA_DIR} \\
    -httpListenAddr=:9428 \\
    -retentionPeriod=30d
Restart=always
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "${SERVICE_PATH}"

# Start and enable service
log_info "Reloading systemd and starting victorialogs service..."
systemctl daemon-reload
systemctl enable victorialogs
systemctl restart victorialogs

# Verification
sleep 2
if systemctl is-active --quiet victorialogs; then
    log_success "=========================================================="
    log_success " VictoriaLogs ${TAG_NAME} (Community) operational!"
    log_success "=========================================================="
    log_info " Web UI / LogsQL interface: http://localhost:9428/select/vmui"
    log_info " Ingestion Endpoint: http://localhost:9428/insert/jsonline"
    log_info " Service status: systemctl status victorialogs"
else
    log_warn "Service installed/updated but failed to start cleanly. Check logs:"
    log_warn "journalctl -u victorialogs -n 50 --no-pager"
fi
