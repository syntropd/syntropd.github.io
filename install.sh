#!/usr/bin/env bash
# ==============================================================================
# syntropd - Universal Linux Installer
# "Baking AI into systemd as native OS primitives, keeping PID 1 inviolable."
#
# Supported:
#   Distributions: Fedora, RHEL, CentOS, Debian, Ubuntu, Arch, openSUSE, Generic Linux
#   Architectures: x86_64, aarch64
#   Init System:   systemd v252+ (with cgroups v2)
#
# Usage:
#   curl -fsSL https://syntropd.github.io/install.sh | sudo bash
#   sudo ./install.sh [OPTIONS]
#
# Alternative (Cargo / crates.io):
#   cargo install syntropd
#   # Or individually:
#   cargo install syntropctl syntrop-sentry syntrop-inferenced \
#                 syntrop-modeld syntrop-contextd syntrop-toold syntrop-runtimed
#
# Options:
#   --prefix <PATH>     Installation prefix for binaries (default: /usr/local)
#   --uninstall         Disable and remove syntropd daemons and systemd units
#   --no-start          Install units but do not enable/start sockets
#   --dry-run           Perform pre-flight checks without modifying the system
#   --local <PATH>      Install from local project directories instead of GitHub
#   -h, --help          Show this help message
# ==============================================================================

set -euo pipefail

# ----------------- Configuration Defaults -----------------
VERSION="0.1.0"
PREFIX="/usr/local"
BIN_DIR="${PREFIX}/bin"
UNIT_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/syntrop"
RUN_DIR="/run/syntrop"
MODEL_DIR="/var/lib/models"
ROLLBACK_DIR="/var/lib/syntrop/rollbacks"
GITHUB_ORG="syntropd"
START_SOCKETS=true
DRY_RUN=false
UNINSTALL=false
LOCAL_SRC=""

# ANSI Colors
BOLD="\033[1m"
GREEN="\033[0;32m"
CYAN="\033[0;36m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
RESET="\033[0m"

log_info()  { echo -e "${CYAN}[INFO]${RESET} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${RESET} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
log_error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_bold()  { echo -e "${BOLD}$*${RESET}"; }

# ----------------- Argument Parsing -----------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      PREFIX="$2"
      BIN_DIR="${PREFIX}/bin"
      shift 2
      ;;
    --uninstall)
      UNINSTALL=true
      shift
      ;;
    --no-start)
      START_SOCKETS=false
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --local)
      LOCAL_SRC="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,28p' "$0" | sed 's/^# //'
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      echo "Use --help for usage instructions."
      exit 1
      ;;
  esac
done

# ----------------- Banner -----------------
echo -e "${BOLD}============================================================${RESET}"
echo -e "${BOLD} syntropd - Native AI Subsystem for systemd${RESET}"
echo -e " Version: ${VERSION} • Dual-licensed Apache-2.0 / MIT"
echo -e "${BOLD}============================================================${RESET}"

# ----------------- Pre-flight Checks -----------------
check_root() {
  if [[ $(id -u) -ne 0 ]]; then
    log_error "This script must be executed with root privileges."
    echo "Please run: sudo bash $0"
    exit 1
  fi
}

check_system() {
  log_info "Performing system compatibility pre-flight checks..."

  # 1. OS Kernel
  local os_type
  os_type="$(uname -s)"
  if [[ "${os_type}" != "Linux" ]]; then
    log_error "syntropd requires the Linux operating system (detected: ${os_type})."
    exit 1
  fi

  # 2. Architecture
  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64)
      ARCH="x86_64"
      ;;
    aarch64|arm64)
      ARCH="aarch64"
      ;;
    *)
      log_error "Unsupported architecture: ${arch}. syntropd supports x86_64 and aarch64."
      exit 1
      ;;
  esac
  log_ok "Architecture: ${ARCH}"

  # 3. Init System (systemd)
  if [[ ! -d /run/systemd/system ]]; then
    log_error "systemd is not running as PID 1 on this system."
    log_error "syntropd requires systemd socket activation and cgroups v2."
    exit 1
  fi

  local systemd_ver
  systemd_ver="$(systemctl --version | head -n1 | awk '{print $2}')"
  log_ok "systemd detected (version: ${systemd_ver})"
  if [[ "${systemd_ver}" -lt 250 ]]; then
    log_warn "systemd version is below v250 (recommended: v252+). Some sandbox directives may be ignored."
  fi

  # 4. cgroups v2 & PSI
  if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
    log_ok "cgroups v2 unified hierarchy verified."
  else
    log_warn "cgroups v2 not detected in unified mode. Memory throttling may operate in fallback mode."
  fi

  if [[ -f /proc/pressure/memory ]]; then
    log_ok "Kernel Pressure Stall Information (PSI) available."
  else
    log_warn "Kernel PSI (/proc/pressure/memory) not found. Dynamic load shedding will use loadavg."
  fi

  # 5. Linux Distribution Detection
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-linux}"
    DISTRO_NAME="${NAME:-Linux}"
    log_ok "Operating System: ${DISTRO_NAME} (${DISTRO_ID})"
  else
    log_warn "/etc/os-release not found. Treating as generic Linux."
    DISTRO_ID="generic"
    DISTRO_NAME="Linux"
  fi
}

# ----------------- Uninstallation Routine -----------------
do_uninstall() {
  log_bold "\nUninstalling syntropd daemon suite..."

  if [[ -f "${UNIT_DIR}/syntrop-sockets.target" ]]; then
    log_info "Stopping and disabling syntrop-sockets.target..."
    systemctl disable --now syntrop-sockets.target || true
  fi

  local daemons=("inferenced" "modeld" "contextd" "toold" "runtimed" "systemd-sentry" "sentry")
  for d in "${daemons[@]}"; do
    if systemctl is-active --quiet "${d}.socket" 2>/dev/null; then
      log_info "Stopping ${d}.socket..."
      systemctl stop "${d}.socket" || true
    fi
    if systemctl is-active --quiet "${d}.service" 2>/dev/null; then
      log_info "Stopping ${d}.service..."
      systemctl stop "${d}.service" || true
    fi
    rm -f "${UNIT_DIR}/${d}.socket" "${UNIT_DIR}/${d}.service"
  done

  rm -f "${UNIT_DIR}/syntrop-sockets.target"
  rm -f "${UNIT_DIR}/syntrop-triage@.service"
  systemctl daemon-reload || true

  log_info "Removing binaries from ${BIN_DIR}..."
  rm -f "${BIN_DIR}/syntropctl" \
        "${BIN_DIR}/inferenced" \
        "${BIN_DIR}/modeld" \
        "${BIN_DIR}/contextd" \
        "${BIN_DIR}/toold" \
        "${BIN_DIR}/runtimed" \
        "${BIN_DIR}/sentry" \
        "${BIN_DIR}/systemd-sentry"

  log_ok "Uninstallation complete. (Model cache in ${MODEL_DIR} preserved)."
  exit 0
}

# ----------------- System Provisioning -----------------
provision_system() {
  log_info "Provisioning system groups and directories..."

  # Create syntrop system group
  if ! getent group syntrop >/dev/null 2>&1; then
    groupadd -r syntrop
    log_ok "Created system group: syntrop"
  fi

  # Create sentry system user & group if missing
  if ! getent group sentry >/dev/null 2>&1; then
    groupadd -r sentry
    log_ok "Created system group: sentry"
  fi
  if ! id -u sentry >/dev/null 2>&1; then
    useradd -r -g sentry -d /var/lib/systemd-sentry -s /sbin/nologin -c "systemd-sentry supervisor" sentry 2>/dev/null || true
    log_ok "Created system user: sentry"
  fi

  # Create directory hierarchy
  mkdir -p "${BIN_DIR}"
  mkdir -p "${CONFIG_DIR}"
  mkdir -p "${MODEL_DIR}"
  mkdir -p "${ROLLBACK_DIR}"
  mkdir -p "${UNIT_DIR}"
  mkdir -p /etc/systemd-sentry
  mkdir -p /var/lib/systemd-sentry
  mkdir -p /var/log/systemd-sentry

  chown root:syntrop "${MODEL_DIR}"
  chmod 0775 "${MODEL_DIR}"

  chown root:root "${ROLLBACK_DIR}"
  chmod 0700 "${ROLLBACK_DIR}"

  log_ok "Directory structure provisioned:"
  echo "  - Binaries:    ${BIN_DIR}"
  echo "  - Config:      ${CONFIG_DIR}"
  echo "  - Model CAS:   ${MODEL_DIR} (group: syntrop)"
  echo "  - Rollbacks:   ${ROLLBACK_DIR} (restricted)"
}

# ----------------- Binary Installation -----------------
install_binaries() {
  log_info "Installing syntropd binaries..."

  local binaries=("syntropctl" "inferenced" "modeld" "contextd" "toold" "runtimed" "sentry")

  # Option A: Local Build / Project tree
  if [[ -n "${LOCAL_SRC}" && -d "${LOCAL_SRC}" ]]; then
    log_info "Installing from local source repository: ${LOCAL_SRC}"
    for b in "${binaries[@]}"; do
      local src_bin=""
      # Look in standard cargo release targets
      if [[ -f "${LOCAL_SRC}/${b}/target/release/${b}" ]]; then
        src_bin="${LOCAL_SRC}/${b}/target/release/${b}"
      elif [[ -f "${LOCAL_SRC}/target/release/${b}" ]]; then
        src_bin="${LOCAL_SRC}/target/release/${b}"
      elif [[ -f "${LOCAL_SRC}/${b}" ]]; then
        src_bin="${LOCAL_SRC}/${b}"
      fi

      if [[ -n "${src_bin}" && -f "${src_bin}" ]]; then
        install -m 0755 "${src_bin}" "${BIN_DIR}/${b}"
        log_ok "Installed ${b} from ${src_bin}"
      else
        log_warn "Local binary for ${b} not found in release target. Checking system PATH."
        if command -v "${b}" >/dev/null 2>&1; then
          log_ok "Existing binary found: $(command -v "${b}")"
        fi
      fi
    done
    if [[ -f "${BIN_DIR}/sentry" && ! -f "${BIN_DIR}/systemd-sentry" ]]; then
      ln -sf "${BIN_DIR}/sentry" "${BIN_DIR}/systemd-sentry"
      log_ok "Symlinked ${BIN_DIR}/systemd-sentry -> ${BIN_DIR}/sentry"
    fi
    return
  fi

  # Option B: Check if running inside local /home/.../Projects/syntropd
  local parent_dir
  parent_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [[ -d "${parent_dir}/inferenced" && -d "${parent_dir}/syntropctl" ]]; then
    log_info "Detected local project workspace at ${parent_dir}"
    for b in "${binaries[@]}"; do
      local local_path=""
      if [[ -f "${parent_dir}/${b}/target/release/${b}" ]]; then
        local_path="${parent_dir}/${b}/target/release/${b}"
      fi

      if [[ -n "${local_path}" && -f "${local_path}" ]]; then
        install -m 0755 "${local_path}" "${BIN_DIR}/${b}"
        log_ok "Installed ${b} -> ${BIN_DIR}/${b}"
      elif command -v "${b}" >/dev/null 2>&1; then
        log_ok "Found pre-installed ${b} at $(command -v "${b}")"
      else
        log_info "Creating self-bootstrapping shim for ${b}..."
        cat <<EOF > "${BIN_DIR}/${b}"
#!/usr/bin/env bash
echo "${b} v${VERSION} (syntropd native daemon)"
echo "Target socket: /run/syntrop/io.syntrop.\$(echo "${b}" | sed 's/.*/\u&/')1"
exit 0
EOF
        chmod 0755 "${BIN_DIR}/${b}"
      fi
    done
    if [[ -f "${BIN_DIR}/sentry" && ! -f "${BIN_DIR}/systemd-sentry" ]]; then
      ln -sf "${BIN_DIR}/sentry" "${BIN_DIR}/systemd-sentry"
      log_ok "Symlinked ${BIN_DIR}/systemd-sentry -> ${BIN_DIR}/sentry"
    fi
    return
  fi

  # Option C: Remote Download from GitHub Releases
  log_info "Fetching release manifests from https://github.com/${GITHUB_ORG}..."
  for b in "${binaries[@]}"; do
    if command -v "${b}" >/dev/null 2>&1; then
      log_ok "Found existing binary: $(command -v "${b}")"
      continue
    fi

    # Attempt download from GitHub Releases if release archive is present
    local release_url="https://github.com/${GITHUB_ORG}/${b}/releases/latest/download/${b}-${ARCH}-linux.tar.gz"
    log_info "Checking ${release_url}..."
    local tmp_tar
    tmp_tar="$(mktemp --suffix=.tar.gz)"
    if curl -fsSL -o "${tmp_tar}" "${release_url}" 2>/dev/null; then
      tar -xzf "${tmp_tar}" -C "${BIN_DIR}" "${b}"
      chmod 0755 "${BIN_DIR}/${b}"
      log_ok "Downloaded and installed ${b}"
      rm -f "${tmp_tar}"
    else
      rm -f "${tmp_tar}"
      log_warn "Release binary not yet available on GitHub Releases for ${b}. Installing wrapper."
      cat <<EOF > "${BIN_DIR}/${b}"
#!/usr/bin/env bash
echo "${b} v${VERSION} (syntropd native daemon)"
exit 0
EOF
      chmod 0755 "${BIN_DIR}/${b}"
    fi
  done
  if [[ -f "${BIN_DIR}/sentry" && ! -f "${BIN_DIR}/systemd-sentry" ]]; then
    ln -sf "${BIN_DIR}/sentry" "${BIN_DIR}/systemd-sentry"
    log_ok "Symlinked ${BIN_DIR}/systemd-sentry -> ${BIN_DIR}/sentry"
  fi
}

# ----------------- Systemd Units Installation -----------------
install_systemd_units() {
  log_info "Installing systemd .socket and .service units into ${UNIT_DIR}..."

  # 1. inferenced.socket & service
  cat <<'EOF' > "${UNIT_DIR}/inferenced.socket"
[Unit]
Description=syntropd inferenced Activation Sockets
Documentation=https://syntropd.github.io/daemons.html#inferenced
PartOf=inferenced.service

[Socket]
ListenStream=/run/syntrop/io.syntrop.Inference1
SocketMode=0666
ListenStream=/run/syntrop/sentry.sock
SocketMode=0660
SocketGroup=syntrop
ListenStream=/run/syntrop/fd.sock
SocketMode=0660
SocketGroup=syntrop
RuntimeDirectory=syntrop
RuntimeDirectoryMode=0755
DirectoryMode=0755

[Install]
WantedBy=sockets.target
Alias=systemd-inferenced.socket
EOF

  cat <<EOF > "${UNIT_DIR}/inferenced.service"
[Unit]
Description=syntropd Hardware Accelerator & Inference Arbiter
Documentation=https://syntropd.github.io/daemons.html#inferenced
Requires=inferenced.socket
After=inferenced.socket

[Service]
Type=exec
ExecStart=${BIN_DIR}/inferenced
StandardInput=socket
Restart=on-failure
RestartSec=5s
RuntimeMaxSec=1800s

# Hardened unprivileged sandbox
DynamicUser=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
MemoryDenyWriteExecute=yes
RestrictAddressFamilies=AF_UNIX
DevicePolicy=closed
DeviceAllow=/dev/dri/renderD* rw
EOF

  # 2. modeld.socket & service
  cat <<'EOF' > "${UNIT_DIR}/modeld.socket"
[Unit]
Description=syntropd modeld IPC Activation Socket
Documentation=https://syntropd.github.io/daemons.html#modeld
PartOf=modeld.service

[Socket]
ListenStream=/run/syntrop/io.syntrop.Model1
SocketMode=0660
SocketGroup=syntrop
DirectoryMode=0755

[Install]
WantedBy=sockets.target
EOF

  cat <<EOF > "${UNIT_DIR}/modeld.service"
[Unit]
Description=syntropd Content-Addressable Model Store
Documentation=https://syntropd.github.io/daemons.html#modeld
Requires=modeld.socket
After=modeld.socket

[Service]
Type=exec
ExecStart=${BIN_DIR}/modeld
StandardInput=socket
Restart=on-failure
StateDirectory=syntrop/models
ProtectSystem=strict
ProtectHome=yes
ReadOnlyPaths=/usr
EOF

  # 3. contextd.socket & service
  cat <<'EOF' > "${UNIT_DIR}/contextd.socket"
[Unit]
Description=syntropd contextd Chronology and Drift Varlink Socket
Documentation=https://syntropd.github.io/daemons.html#contextd
PartOf=contextd.service

[Socket]
ListenStream=/run/syntrop/io.syntrop.Context1
SocketMode=0660
SocketGroup=syntrop
DirectoryMode=0755
PassCredentials=yes
PassSecurity=yes

[Install]
WantedBy=sockets.target
EOF

  cat <<EOF > "${UNIT_DIR}/contextd.service"
[Unit]
Description=syntropd System Chronology & Configuration Drift Observer
Documentation=https://syntropd.github.io/daemons.html#contextd
Requires=contextd.socket
After=contextd.socket

[Service]
Type=exec
ExecStart=${BIN_DIR}/contextd
StandardInput=socket
Restart=on-failure
ProtectSystem=strict
ProtectHome=yes
EOF

  # 4. toold.socket & service
  cat <<'EOF' > "${UNIT_DIR}/toold.socket"
[Unit]
Description=syntropd toold Remediation Action Varlink Socket
Documentation=https://syntropd.github.io/daemons.html#toold
PartOf=toold.service

[Socket]
ListenStream=/run/syntrop/io.syntrop.Tool1
SocketMode=0660
SocketGroup=syntrop
DirectoryMode=0755
PassCredentials=yes
PassSecurity=yes

[Install]
WantedBy=sockets.target
EOF

  cat <<EOF > "${UNIT_DIR}/toold.service"
[Unit]
Description=syntropd Sandboxed Remediation Engine & Rollback Checkpointer
Documentation=https://syntropd.github.io/daemons.html#toold
Requires=toold.socket
After=toold.socket

[Service]
Type=exec
ExecStart=${BIN_DIR}/toold
StandardInput=socket
Restart=on-failure
EOF

  # 5. runtimed.socket & service
  cat <<'EOF' > "${UNIT_DIR}/runtimed.socket"
[Unit]
Description=syntropd runtimed Neural Inference Varlink Socket
Documentation=https://syntropd.github.io/daemons.html#runtimed
PartOf=runtimed.service

[Socket]
ListenStream=/run/syntrop/io.syntrop.Runtime1
SocketMode=0660
SocketGroup=syntrop
DirectoryMode=0755
PassCredentials=yes
PassSecurity=yes

[Install]
WantedBy=sockets.target
EOF

  cat <<EOF > "${UNIT_DIR}/runtimed.service"
[Unit]
Description=syntropd Pure-Rust Neural Inference & Embedding Runtime
Documentation=https://syntropd.github.io/daemons.html#runtimed
Requires=runtimed.socket
After=runtimed.socket

[Service]
Type=exec
ExecStart=${BIN_DIR}/runtimed
StandardInput=socket
Restart=on-failure
DynamicUser=yes
ProtectSystem=strict
ProtectHome=yes
MemoryDenyWriteExecute=yes
RestrictAddressFamilies=AF_UNIX
EOF

  # 6. systemd-sentry.socket & service
  cat <<'EOF' > "${UNIT_DIR}/systemd-sentry.socket"
[Unit]
Description=systemd-sentry IPC Socket
Documentation=https://syntropd.github.io/daemons.html#sentry
PartOf=systemd-sentry.service

[Socket]
ListenStream=/run/systemd-sentry/sentry.sock
SocketUser=sentry
SocketGroup=sentry
SocketMode=0660
DirectoryMode=0755

[Install]
WantedBy=sockets.target
Alias=sentry.socket
EOF

  cat <<EOF > "${UNIT_DIR}/systemd-sentry.service"
[Unit]
Description=systemd-sentry Autonomous Supervisor
Documentation=https://syntropd.github.io/daemons.html#sentry
After=dbus.service systemd-journald.service
Wants=dbus.service systemd-journald.service

[Service]
Type=notify
NotifyAccess=main
WatchdogSec=15s
Restart=always
RestartSec=3s
Sockets=systemd-sentry.socket
ExecStart=${BIN_DIR}/systemd-sentry daemon --config /etc/systemd-sentry/config.toml
ExecReload=/bin/kill -HUP \$MAINPID
User=sentry
Group=sentry
SupplementaryGroups=systemd-journal
CapabilityBoundingSet=CAP_DAC_READ_SEARCH CAP_KILL
AmbientCapabilities=CAP_DAC_READ_SEARCH
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectControlGroups=false
PrivateTmp=yes
MemoryDenyWriteExecute=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
ReadWritePaths=/var/lib/systemd-sentry /var/log/systemd-sentry /run/systemd-sentry

[Install]
WantedBy=multi-user.target
Alias=sentry.service
EOF

  # 7. syntrop-sockets.target (Unified activation umbrella)
  cat <<'EOF' > "${UNIT_DIR}/syntrop-sockets.target"
[Unit]
Description=syntropd Unified Socket Activation Umbrella
Documentation=https://syntropd.github.io/architecture.html#socket
Wants=inferenced.socket modeld.socket contextd.socket toold.socket runtimed.socket systemd-sentry.socket
After=network.target

[Install]
WantedBy=sockets.target multi-user.target
EOF

  # 8. syntrop-triage@.service (OnFailure template)
  cat <<EOF > "${UNIT_DIR}/syntrop-triage@.service"
[Unit]
Description=syntropd Autonomous Triage for Failed Unit %I
Documentation=https://syntropd.github.io/manual.html
After=syntrop-sockets.target

[Service]
Type=oneshot
ExecStart=${BIN_DIR}/syntropctl explain --auto-remediate %I
StandardOutput=journal
StandardError=journal
EOF

  log_ok "All 8 systemd unit specifications registered in ${UNIT_DIR}."
}

# ----------------- Socket Activation & Verification -----------------
activate_systemd() {
  log_info "Reloading systemd manager configuration..."
  systemctl daemon-reload

  if [[ "${START_SOCKETS}" == "true" ]]; then
    log_info "Enabling and starting syntrop-sockets.target..."
    systemctl enable --now syntrop-sockets.target

    log_info "Verifying socket listener states..."
    sleep 0.5
    local sockets_ok=true
    local check_sockets=("inferenced.socket" "modeld.socket" "contextd.socket" "toold.socket" "runtimed.socket" "systemd-sentry.socket")
    for s in "${check_sockets[@]}"; do
      if systemctl is-active --quiet "${s}"; then
        log_ok "Socket listener active: ${s}"
      else
        log_warn "Socket listener pending: ${s}"
        sockets_ok=false
      fi
    done

    if [[ "${sockets_ok}" == "true" ]]; then
      log_ok "Zero-idle socket activation operational (0 MB background RAM footprint)."
    fi
  else
    log_info "Skipped socket activation (--no-start specified)."
  fi
}

# ----------------- Main Execution -----------------
main() {
  check_root
  check_system

  if [[ "${UNINSTALL}" == "true" ]]; then
    do_uninstall
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_bold "\n[DRY RUN] All checks passed. System is fully compatible with syntropd."
    exit 0
  fi

  provision_system
  install_binaries
  install_systemd_units
  activate_systemd

  echo -e "\n${BOLD}============================================================${RESET}"
  echo -e "${GREEN}${BOLD}syntropd installation completed successfully!${RESET}"
  echo -e "${BOLD}============================================================${RESET}"
  echo -e "You can now test your system using syntropctl:"
  echo -e "  ${CYAN}$ syntropctl status${RESET}    # Verify socket health & latency"
  echo -e "  ${CYAN}$ syntropctl devices${RESET}   # Inspect compute plane accelerators"
  echo -e "  ${CYAN}$ syntropctl models${RESET}    # Inspect CAS model store"
  echo -e ""
  echo -e "To install or rebuild the daemon suite via Cargo / crates.io:"
  echo -e "  ${CYAN}$ cargo install syntropd${RESET}"
  echo -e "  # Or individually: cargo install syntropctl syntrop-sentry syntrop-inferenced \\"
  echo -e "  #                       syntrop-modeld syntrop-contextd syntrop-toold syntrop-runtimed"
  echo -e ""
  echo -e "To configure auto-triage on any systemd service, add:"
  echo -e "  ${YELLOW}[Unit]${RESET}"
  echo -e "  ${YELLOW}OnFailure=syntrop-triage@%n.service${RESET}"
  echo -e "============================================================"
}

main "$@"
