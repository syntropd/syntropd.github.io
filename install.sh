#!/usr/bin/env bash
# ==============================================================================
# syntropd - Authoritative Master Universal Linux Installer
# "Native AI Subsystem for systemd — keeping PID 1 inviolable."
#
# Supported:
#   Distributions: Fedora, RHEL, CentOS, Debian, Ubuntu, Arch, openSUSE, Generic Linux
#   Architectures: x86_64, aarch64
#   Init System:   systemd v252+ (with cgroups v2 & PSI)
#
# Usage:
#   curl -fsSL https://syntropd.github.io/install.sh | sudo bash
#   sudo ./install.sh [OPTIONS]
#
# Options:
#   --prefix <PATH>     Installation prefix for binaries (default: /usr/local)
#   --dry-run           Perform pre-flight checks without modifying the system
#   --uninstall         Disable and remove syntropd daemons, units, and binaries
#   --purge             Used with --uninstall to also purge configs, caches, user/group
#   --no-start          Install units but do not enable or start sockets
#   --user <USER>       Enroll specific user into 'syntrop' group (defaults to SUDO_USER)
#   --local <PATH>      Install from local project directories / checkout
#   -h, --help          Show this help message
# ==============================================================================

set -euo pipefail

VERSION="0.1.0"
PREFIX="/usr/local"
BIN_DIR="${PREFIX}/bin"
UNIT_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/syntrop"
RUN_DIR="/run/syntrop"
RUN_SENTRY_DIR="/run/systemd-sentry"
MODEL_DIR="/var/lib/models"
ROLLBACK_DIR="/var/lib/syntrop/rollbacks"
TOOLD_DIR="/var/lib/toold"
START_SOCKETS=true
DRY_RUN=false
UNINSTALL=false
PURGE=false
LOCAL_SRC=""
TARGET_USER="${SUDO_USER:-}"

# Colors
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

# ----------------- CLI Argument Parsing -----------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      PREFIX="$2"
      BIN_DIR="${PREFIX}/bin"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --uninstall)
      UNINSTALL=true
      shift
      ;;
    --purge)
      PURGE=true
      shift
      ;;
    --no-start)
      START_SOCKETS=false
      shift
      ;;
    --user)
      TARGET_USER="$2"
      shift 2
      ;;
    --local)
      LOCAL_SRC="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,24p' "$0" | sed 's/^# //'
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      echo "Use --help for usage instructions."
      exit 1
      ;;
  esac
done

echo -e "${BOLD}============================================================${RESET}"
echo -e "${BOLD} syntropd - Native AI Subsystem for systemd${RESET}"
echo -e " Version: ${VERSION} • Apache-2.0 License"
echo -e "${BOLD}============================================================${RESET}"

# ----------------- Pre-flight Checks -----------------
check_euid() {
  if [[ $(id -u) -ne 0 ]]; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_warn "Dry-run invoked as non-root user (EUID: $(id -u)). Real installation requires root."
    else
      log_error "This script must be executed with root privileges."
      echo "Please run: sudo bash $0"
      exit 1
    fi
  else
    log_ok "Root privileges confirmed (EUID: 0)."
  fi
}

check_system() {
  log_info "Verifying system compatibility & kernel capabilities..."

  # 1. OS check
  local os_type
  os_type="$(uname -s)"
  if [[ "${os_type}" != "Linux" ]]; then
    log_error "syntropd requires Linux (detected: ${os_type})."
    exit 1
  fi
  log_ok "Operating System: Linux"

  # 2. Architecture check
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

  # 3. PID 1 systemd check
  if [[ ! -d /run/systemd/system ]]; then
    log_error "systemd is not running as PID 1 on this system."
    log_error "syntropd relies on systemd socket activation, cgroups, and sd_notify."
    exit 1
  fi

  local systemd_ver
  systemd_ver="$(systemctl --version 2>/dev/null | head -n1 | awk '{print $2}')"
  log_ok "systemd PID 1 detected (version: ${systemd_ver})"

  # 4. cgroups v2 check
  if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
    local controllers
    controllers="$(cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null || echo "")"
    log_ok "cgroups v2 unified hierarchy verified (controllers: ${controllers})"
  else
    log_warn "cgroups v2 not detected in unified mode. Memory throttling will run in degraded mode."
  fi

  # 5. PSI check
  if [[ -f /proc/pressure/memory ]]; then
    log_ok "Kernel Pressure Stall Information (PSI) available."
  else
    log_warn "Kernel PSI (/proc/pressure/memory) not available. Load shedding will fall back to loadavg."
  fi

  # 6. Linux distribution detection
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-linux}"
    DISTRO_NAME="${NAME:-Linux}"
    log_ok "Distribution: ${DISTRO_NAME} (${DISTRO_ID})"
  else
    log_warn "/etc/os-release not found. Treating as generic Linux."
    DISTRO_ID="generic"
    DISTRO_NAME="Linux"
  fi

  # 7. Hardware acceleration check
  if compgen -G "/dev/dri/renderD*" > /dev/null; then
    log_ok "DRM GPU render nodes detected: $(echo /dev/dri/renderD*)"
  else
    log_info "No DRM render nodes found; CPU execution fallback will be active."
  fi

  if compgen -G "/dev/accel/*" > /dev/null; then
    log_ok "Dedicated NPU/AI accelerators detected: $(echo /dev/accel/*)"
  fi
}

# ----------------- Uninstallation -----------------
do_uninstall() {
  log_bold "\nUninstalling syntropd suite..."

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Would disable syntrop-sockets.target, stop daemons, and remove unit files and binaries."
    exit 0
  fi

  if [[ -f "${UNIT_DIR}/syntrop-sockets.target" ]]; then
    log_info "Stopping and disabling syntrop-sockets.target..."
    systemctl disable --now syntrop-sockets.target 2>/dev/null || true
  fi

  local daemons=("inferenced" "modeld" "contextd" "toold" "runtimed" "systemd-sentry" "sentry")
  for d in "${daemons[@]}"; do
    systemctl disable --now "${d}.socket" 2>/dev/null || true
    systemctl disable --now "${d}.service" 2>/dev/null || true
    rm -f "${UNIT_DIR}/${d}.socket" "${UNIT_DIR}/${d}.service"
  done

  rm -f "${UNIT_DIR}/syntrop-sockets.target"
  rm -f "${UNIT_DIR}/syntrop-triage@.service"
  rm -rf "${RUN_DIR}" "${RUN_SENTRY_DIR}"

  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed 2>/dev/null || true

  log_info "Removing binaries from ${BIN_DIR}..."
  rm -f "${BIN_DIR}/syntropctl" \
        "${BIN_DIR}/inferenced" \
        "${BIN_DIR}/modeld" \
        "${BIN_DIR}/contextd" \
        "${BIN_DIR}/toold" \
        "${BIN_DIR}/runtimed" \
        "${BIN_DIR}/sentry" \
        "${BIN_DIR}/systemd-sentry" \
        "${BIN_DIR}/syntropd"

  if [[ "${PURGE}" == "true" ]]; then
    log_info "--purge specified: removing configuration, caches, and system user/group..."
    rm -rf "${CONFIG_DIR}"
    rm -rf "${MODEL_DIR}"
    rm -rf "${ROLLBACK_DIR}"
    rm -rf "${TOOLD_DIR}"
    userdel sentry 2>/dev/null || true
    groupdel syntrop 2>/dev/null || true
    log_ok "Purged configurations, data directories, and system user/group."
  else
    log_ok "Uninstallation complete. (Model cache in ${MODEL_DIR} and configs in ${CONFIG_DIR} preserved)."
  fi
  exit 0
}

# ----------------- System Provisioning -----------------
provision_system() {
  log_info "Provisioning system users, groups, and directories..."

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Would create system group 'syntrop' and system user 'sentry'."
    log_info "[DRY-RUN] Would provision: ${BIN_DIR}, ${CONFIG_DIR}, ${RUN_DIR}, ${RUN_SENTRY_DIR}, ${MODEL_DIR}, ${ROLLBACK_DIR}."
    return 0
  fi

  # 1. System group: syntrop
  if ! getent group syntrop >/dev/null 2>&1; then
    groupadd -r syntrop
    log_ok "Created system group: syntrop"
  fi

  # 2. System user: sentry
  if ! id -u sentry >/dev/null 2>&1; then
    useradd -r -s /usr/sbin/nologin -g syntrop -G systemd-journal -d /var/lib/systemd-sentry -c "syntropd Sentry Supervisor" sentry 2>/dev/null || \
    useradd -r -s /bin/false -g syntrop -d /var/lib/systemd-sentry -c "syntropd Sentry Supervisor" sentry
    log_ok "Created system user: sentry"
  fi

  # 3. User enrollment for unprivileged IPC socket access
  if [[ -n "${TARGET_USER}" && "${TARGET_USER}" != "root" ]]; then
    if id "${TARGET_USER}" >/dev/null 2>&1; then
      usermod -aG syntrop "${TARGET_USER}"
      log_ok "Added user '${TARGET_USER}' to group 'syntrop' for unprivileged IPC access."
    fi
  fi

  # 4. System directories
  mkdir -p "${BIN_DIR}"
  mkdir -p "${CONFIG_DIR}"
  mkdir -p "${RUN_DIR}"
  mkdir -p "${RUN_SENTRY_DIR}"
  mkdir -p "${MODEL_DIR}"
  mkdir -p "${ROLLBACK_DIR}"
  mkdir -p "${TOOLD_DIR}"
  mkdir -p "${UNIT_DIR}"

  chown root:syntrop "${RUN_DIR}"
  chmod 0775 "${RUN_DIR}"

  chown sentry:syntrop "${RUN_SENTRY_DIR}" 2>/dev/null || chown root:syntrop "${RUN_SENTRY_DIR}"
  chmod 0775 "${RUN_SENTRY_DIR}"

  chown root:syntrop "${MODEL_DIR}"
  chmod 0775 "${MODEL_DIR}"

  chown root:syntrop "${TOOLD_DIR}"
  chmod 0775 "${TOOLD_DIR}"

  chown root:root "${ROLLBACK_DIR}"
  chmod 0700 "${ROLLBACK_DIR}"

  chown root:root "${CONFIG_DIR}"
  chmod 0755 "${CONFIG_DIR}"

  log_ok "System directories and ownership provisioned."
}

# ----------------- Binary Installation -----------------
install_binaries() {
  log_info "Installing suite binaries to ${BIN_DIR}..."

  local binaries=("syntropctl" "inferenced" "modeld" "contextd" "toold" "runtimed" "sentry" "systemd-sentry" "syntropd")

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Would install binaries: ${binaries[*]} into ${BIN_DIR}."
    return 0
  fi

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local sudo_home=""
  if [[ -n "${TARGET_USER}" ]]; then
    sudo_home="$(eval echo "~${TARGET_USER}" 2>/dev/null || echo "")"
  fi

  local search_roots=(
    "${LOCAL_SRC}"
    "${script_dir}/.."
    "${script_dir}"
    "${PWD}"
    "${sudo_home}/Projects/syntropd"
    "${sudo_home}/Projects/UberMetroid"
  )

  # Phase 1: Local workspace builds
  local missing=()
  for bin in "${binaries[@]}"; do
    local installed=false

    for root in "${search_roots[@]}"; do
      if [[ -z "${root}" || ! -d "${root}" ]]; then
        continue
      fi

      local candidate
      for candidate in \
        "${root}/target/release/${bin}" \
        "${root}/target/debug/${bin}" \
        "${root}/${bin}/target/release/${bin}" \
        "${root}/${bin}/target/debug/${bin}" \
        "${root}"/*/target/release/"${bin}" \
        "${root}"/*/target/debug/"${bin}" \
        "${root}/crates/*-daemon/target/release/${bin}" \
        "${root}/crates/*-cli/target/release/${bin}"; do
        if [[ -f "${candidate}" && -x "${candidate}" ]]; then
          install -D -p -m 0755 "${candidate}" "${BIN_DIR}/${bin}"
          log_ok "Installed ${bin} from local build (${candidate})"
          installed=true
          break 2
        fi
      done
    done

    if [[ "${installed}" == "false" ]]; then
      # If binary already exists in PATH or current install
      if command -v "${bin}" >/dev/null 2>&1; then
        local src_bin
        src_bin="$(command -v "${bin}")"
        if [[ "${src_bin}" != "${BIN_DIR}/${bin}" ]]; then
          install -D -p -m 0755 "${src_bin}" "${BIN_DIR}/${bin}"
          log_ok "Installed ${bin} from system PATH (${src_bin})"
          installed=true
        fi
      fi
    fi

    if [[ "${installed}" == "false" ]]; then
      missing+=("${bin}")
    fi
  done

  # Phase 2: Download precompiled binaries from GitHub Releases
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_info "Fetching precompiled binaries for ${ARCH} from GitHub Releases (v${VERSION})..."
    local release_url="https://github.com/syntropd/syntropd/releases/download/v${VERSION}/syntropd-v${VERSION}-${ARCH}-unknown-linux-gnu.tar.gz"
    local tmp_dir
    tmp_dir="$(mktemp -d /tmp/syntropd-download.XXXXXX)"

    if curl -fsSL "${release_url}" -o "${tmp_dir}/bundle.tar.gz" 2>/dev/null; then
      tar -xzf "${tmp_dir}/bundle.tar.gz" -C "${tmp_dir}"
      for bin in "${missing[@]}"; do
        if [[ -f "${tmp_dir}/${bin}" && -x "${tmp_dir}/${bin}" ]]; then
          install -D -p -m 0755 "${tmp_dir}/${bin}" "${BIN_DIR}/${bin}"
          log_ok "Installed ${bin} from GitHub Release v${VERSION}"
        fi
      done
    else
      log_warn "GitHub Release asset not available for ${ARCH} or network unreachable."
    fi
    rm -rf "${tmp_dir}"
  fi

  # Phase 3: Cargo crates.io compilation fallback
  local still_missing=()
  for bin in "${binaries[@]}"; do
    if [[ ! -x "${BIN_DIR}/${bin}" ]]; then
      still_missing+=("${bin}")
    fi
  done

  if [[ ${#still_missing[@]} -gt 0 ]] && command -v cargo >/dev/null 2>&1; then
    log_info "Compiling and installing remaining binaries (${still_missing[*]}) via Cargo from crates.io..."
    local cargo_packages=()
    for bin in "${still_missing[@]}"; do
      case "${bin}" in
        syntropctl) cargo_packages+=("syntropctl") ;;
        syntropd) cargo_packages+=("syntropd") ;;
        sentry|systemd-sentry) cargo_packages+=("syntrop-sentry") ;;
        inferenced) cargo_packages+=("syntrop-inferenced") ;;
        modeld) cargo_packages+=("syntrop-modeld") ;;
        contextd) cargo_packages+=("syntrop-contextd") ;;
        toold) cargo_packages+=("syntrop-toold") ;;
        runtimed) cargo_packages+=("syntrop-runtimed") ;;
      esac
    done
    local unique_pkgs=($(echo "${cargo_packages[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
    cargo install --root "${PREFIX}" "${unique_pkgs[@]}" || true
  fi

  # Final Verification & Gate
  local final_missing=()
  local verified_count=0
  for bin in "${binaries[@]}"; do
    if [[ -x "${BIN_DIR}/${bin}" ]]; then
      verified_count=$((verified_count + 1))
    else
      final_missing+=("${bin}")
    fi
  done

  if [[ ${#final_missing[@]} -gt 0 ]]; then
    log_error "Failed to install the following required binaries: ${final_missing[*]}"
    log_error "Please build locally or run: cargo install syntropd"
    exit 1
  fi
  log_ok "Verified all ${verified_count}/${#binaries[@]} binaries installed and executable in ${BIN_DIR}."
}

# ----------------- Systemd Unit Registration -----------------
register_units() {
  log_info "Registering systemd units into ${UNIT_DIR}..."

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Would register syntrop-sockets.target, syntrop-triage@.service, and all 6 daemon socket/service units."
    return 0
  fi

  # 1. syntrop-sockets.target
  cat <<'EOF' > "${UNIT_DIR}/syntrop-sockets.target"
[Unit]
Description=syntropd Unified Socket Activation Umbrella
Documentation=https://syntropd.github.io/architecture.html#socket
Wants=inferenced.socket modeld.socket contextd.socket toold.socket runtimed.socket systemd-sentry.socket
After=network.target

[Install]
WantedBy=sockets.target multi-user.target
EOF

  # 2. syntrop-triage@.service
  cat <<'EOF' > "${UNIT_DIR}/syntrop-triage@.service"
[Unit]
Description=syntropd Autonomous Triage for Failed Unit %I
Documentation=https://syntropd.github.io/manual.html
After=syntrop-sockets.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/syntropctl explain %I
StandardOutput=journal
StandardError=journal
EOF

  # 3. toold.socket & toold.service
  cat <<'EOF' > "${UNIT_DIR}/toold.socket"
[Unit]
Description=Syntropd Sandboxed Action and Diagnostic Execution Varlink Socket
Documentation=https://github.com/syntropd/toold
PartOf=toold.service

[Socket]
ListenStream=/run/syntrop/io.syntrop.Tool1
SocketMode=0660
SocketUser=root
SocketGroup=syntrop
DirectoryMode=0755
PassCredentials=yes
PassSecurity=yes

[Install]
WantedBy=sockets.target
EOF

  cat <<EOF > "${UNIT_DIR}/toold.service"
[Unit]
Description=Syntropd Sandboxed Action and Diagnostic Execution Daemon
Documentation=https://github.com/syntropd/toold
Requires=toold.socket
After=toold.socket

[Service]
Type=notify
ExecStart=${BIN_DIR}/toold
ProtectSystem=strict
ReadWritePaths=/var/lib/toold /var/lib/syntrop/rollbacks /run/syntrop
Restart=on-failure
RestartSec=2s
EOF

  # 4. runtimed.socket & runtimed.service
  cat <<'EOF' > "${UNIT_DIR}/runtimed.socket"
[Unit]
Description=Syntropd Headless Model Execution and Tensor Generation Varlink Socket
Documentation=https://github.com/syntropd/runtimed
PartOf=runtimed.service

[Socket]
ListenStream=/run/syntrop/io.syntrop.Runtime1
SocketMode=0660
SocketUser=root
SocketGroup=syntrop
DirectoryMode=0755
PassCredentials=yes
PassSecurity=yes

[Install]
WantedBy=sockets.target
EOF

  cat <<EOF > "${UNIT_DIR}/runtimed.service"
[Unit]
Description=Syntropd Headless Model Execution and Tensor Generation Daemon
Documentation=https://github.com/syntropd/runtimed
Requires=runtimed.socket
After=runtimed.socket

[Service]
Type=notify
ExecStart=${BIN_DIR}/runtimed
ReadWritePaths=/var/lib/models /run/syntrop
Restart=on-failure
RestartSec=2s
EOF

  # 5. inferenced.socket & inferenced.service
  cat <<'EOF' > "${UNIT_DIR}/inferenced.socket"
[Unit]
Description=inferenced Activation Sockets
Documentation=https://github.com/syntropd/inferenced

[Socket]
ListenStream=/run/syntrop/io.syntrop.Inference1
SocketMode=0666
ListenStream=/run/syntrop/sentry.sock
SocketMode=0660
SocketGroup=syntrop
ListenStream=127.0.0.1:11434
ListenStream=/run/syntrop/fd.sock
SocketMode=0660
SocketGroup=syntrop
RuntimeDirectory=syntrop
RuntimeDirectoryMode=0755
DirectoryMode=0755

[Install]
WantedBy=sockets.target
EOF

  cat <<EOF > "${UNIT_DIR}/inferenced.service"
[Unit]
Description=inferenced Hardware Arbiter and Demand Paging Daemon
Documentation=https://github.com/syntropd/inferenced
Requires=inferenced.socket
After=inferenced.socket

[Service]
Type=notify
ExecStart=${BIN_DIR}/inferenced
ReadWritePaths=/var/lib/models /run/syntrop
Restart=on-failure
RestartSec=2s
EOF

  # 6. contextd.socket & contextd.service
  cat <<'EOF' > "${UNIT_DIR}/contextd.socket"
[Unit]
Description=Syntropd System Chronology and Causality Graph Varlink Socket
Documentation=https://github.com/syntropd/contextd
PartOf=contextd.service

[Socket]
ListenStream=/run/syntrop/io.syntrop.Context1
SocketMode=0660
SocketUser=root
SocketGroup=syntrop
DirectoryMode=0755
PassCredentials=yes
PassSecurity=yes

[Install]
WantedBy=sockets.target
EOF

  cat <<EOF > "${UNIT_DIR}/contextd.service"
[Unit]
Description=Syntropd System Chronology and Causality Graph Daemon
Documentation=https://github.com/syntropd/contextd
Requires=contextd.socket
After=contextd.socket

[Service]
Type=notify
ExecStart=${BIN_DIR}/contextd
ReadWritePaths=/run/syntrop
Restart=on-failure
RestartSec=2s
EOF

  # 7. modeld.socket & modeld.service
  cat <<'EOF' > "${UNIT_DIR}/modeld.socket"
[Unit]
Description=Syntropd modeld IPC Activation Sockets
Documentation=https://github.com/syntropd/modeld
PartOf=modeld.service

[Socket]
ListenStream=/run/syntrop/io.syntrop.Model1
SocketMode=0660
SocketUser=root
SocketGroup=syntrop
ListenStream=/run/syntrop/modeld-fd.sock
SocketMode=0660
SocketUser=root
SocketGroup=syntrop

[Install]
WantedBy=sockets.target
EOF

  cat <<EOF > "${UNIT_DIR}/modeld.service"
[Unit]
Description=Syntropd Content-Addressable Model Store Daemon
Documentation=https://github.com/syntropd/modeld
Requires=modeld.socket
After=modeld.socket

[Service]
Type=notify
ExecStart=${BIN_DIR}/modeld
ReadWritePaths=/var/lib/models /run/syntrop
Restart=on-failure
RestartSec=2s
EOF

  # 8. systemd-sentry.socket & systemd-sentry.service
  cat <<'EOF' > "${UNIT_DIR}/systemd-sentry.socket"
[Unit]
Description=systemd-sentry IPC and Varlink Activation Sockets
Documentation=https://github.com/syntropd/sentry
PartOf=systemd-sentry.service

[Socket]
ListenStream=/run/systemd-sentry/sentry.sock
Symlinks=/run/syntrop/io.syntrop.Sentry1
SocketUser=sentry
SocketGroup=syntrop
SocketMode=0660
DirectoryMode=0755
PassCredentials=yes
PassSecurity=yes

[Install]
WantedBy=sockets.target
EOF

  cat <<EOF > "${UNIT_DIR}/systemd-sentry.service"
[Unit]
Description=systemd-sentry Autonomous Supervisor and Crash Watchdog
Documentation=https://github.com/syntropd/sentry
Requires=systemd-sentry.socket
After=systemd-sentry.socket

[Service]
Type=notify
User=sentry
Group=syntrop
ExecStart=${BIN_DIR}/systemd-sentry
ReadWritePaths=/run/syntrop /run/systemd-sentry
Restart=on-failure
RestartSec=2s
EOF

  # 9. Create sentry unit symlink aliases
  ln -sf "${UNIT_DIR}/systemd-sentry.service" "${UNIT_DIR}/sentry.service"
  ln -sf "${UNIT_DIR}/systemd-sentry.socket" "${UNIT_DIR}/sentry.socket"

  systemctl daemon-reload
  log_ok "Systemd units and aliases successfully registered and daemon reloaded."
}

# ----------------- Start & Activate -----------------
activate_subsystem() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Pre-flight verification completed successfully."
    log_ok "[DRY-RUN] System is fully compatible with syntropd."
    return 0
  fi

  if [[ "${START_SOCKETS}" == "true" ]]; then
    log_info "Enabling and starting syntrop-sockets.target..."
    systemctl enable syntrop-sockets.target
    systemctl restart syntrop-sockets.target
    log_ok "syntrop-sockets.target enabled and started."

    # Reset any failed units and ensure all sockets are actively listening
    local daemons=("toold" "runtimed" "modeld" "inferenced" "contextd")
    for d in "${daemons[@]}"; do
      systemctl reset-failed "${d}.service" 2>/dev/null || true
      if systemctl is-active --quiet "${d}.service" 2>/dev/null; then
        systemctl stop "${d}.service" 2>/dev/null || true
      fi
      systemctl start "${d}.socket" 2>/dev/null || true
    done
    if systemctl is-active --quiet "systemd-sentry.service" 2>/dev/null || systemctl is-active --quiet "systemd-sentry.socket" 2>/dev/null; then
      systemctl restart "systemd-sentry.service" 2>/dev/null || true
    fi
    systemctl start "systemd-sentry.socket" 2>/dev/null || true

    mkdir -p /run/syntrop
    ln -sf /run/systemd-sentry/sentry.sock /run/syntrop/io.syntrop.Sentry1 2>/dev/null || true

    echo ""
    log_bold "Active Varlink and IPC Sockets:"
    systemctl list-sockets "inferenced*" "modeld*" "contextd*" "toold*" "runtimed*" "*sentry*" --no-pager 2>/dev/null || true
  else
    log_info "--no-start specified: skipping socket activation."
  fi

  echo ""
  log_bold "============================================================"
  log_bold " Installation Successful!"
  log_bold "============================================================"
  echo "Verify system status anytime with:"
  echo "  syntropctl status"
  echo "  syntropd status"
  echo ""
  if [[ -n "${TARGET_USER}" && "${TARGET_USER}" != "root" ]]; then
    echo -e "${YELLOW}[NOTE]${RESET} User '${TARGET_USER}' was enrolled in group 'syntrop'."
    echo "       To apply the new group to your current terminal session, run:"
    echo -e "         ${BOLD}newgrp syntrop${RESET}"
    echo "       or log out and back in."
    echo ""
  fi
  echo "To diagnose a failed unit root-cause:"
  echo "  syntropctl explain <unit>"
  echo ""
}

# ----------------- Main Execution -----------------
main() {
  if [[ "${UNINSTALL}" == "true" ]]; then
    check_euid
    do_uninstall
  fi

  check_euid
  check_system
  provision_system
  install_binaries
  register_units
  activate_subsystem
}

main "$@"
