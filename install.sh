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
#   --local <PATH>      Install from a local source checkout instead of the
#                       GitHub release bundle (default); PATH is the projects
#                       root containing each daemon directory
#   --with-gemma        Download the Gemma 4 E2B brain, Q4 (3.1 GB). This is
#                       the default on machines with 30+ GB RAM; smaller
#                       machines get Qwen automatically unless this flag is
#                       given explicitly (which always wins, with a warning).
#   --with-starter-model Download the tiny Qwen 0.5B starter model (~700 MB).
#   --with-vision       Download the Gemma vision file for picture
#                       questions (~1 GB).
#   --no-models         Skip all model downloads (engine only).
#   --quiet             Errors and final summary only
#   --verbose           Full step-by-step log (dry-run implies this)
#   -h, --help          Show this help message
# ==============================================================================

set -euo pipefail

VERSION="0.3.19"
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
WITH_GEMMA=true
WITH_STARTER=false
WITH_VISION=false
ROUTER_WIRED=false
EXPLICIT_GEMMA=false
DOWNGRADED_TO_QWEN=false

# Colors
BOLD="\033[1m"
GREEN="\033[0;32m"
CYAN="\033[0;36m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
DIM="\033[0;90m"
RESET="\033[0m"

# Verbosity: 0 errors+summary, 1 phases+results (default), 2 everything.
# Dry-run implies verbose (its whole point is showing what would happen)
# unless --quiet is given explicitly.
VERBOSITY=1
QUIET_FLAG=false
VERBOSE_FLAG=false

log_info()   { if [[ "${VERBOSITY}" -ge 2 ]]; then echo -e "${CYAN}[INFO]${RESET} $*"; fi; }
log_ok()     { if [[ "${VERBOSITY}" -ge 2 ]]; then echo -e "${GREEN}[OK]${RESET} $*"; fi; }
log_warn()   { if [[ "${VERBOSITY}" -ge 1 ]]; then echo -e "${YELLOW}[WARN]${RESET} $*"; fi; }
log_error()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_bold()   { echo -e "${BOLD}$*${RESET}"; }

# Receipt UI: one header per phase, one result line each. Bars carry the
# long phases. Warnings and errors always cut through (level >= 1 / always).
phase() {
  if [[ "${VERBOSITY}" -ge 1 ]]; then
    echo ""
    echo -e "${BOLD}── $* ${DIM}────────────────────────────────────────${RESET}"
  fi
}
result() {
  if [[ "${VERBOSITY}" -ge 1 ]]; then
    echo -e "   ${GREEN}✓${RESET} $*"
  fi
}

is_tty() { [[ -t 1 ]]; }

# Green progress bar: bar_draw <label> <done> <total> [shown_done] [shown_total].
# TTY only; elsewhere the phase result line covers it (no log spam).
bar_draw() {
  if [[ "${VERBOSITY}" -lt 1 ]] || ! is_tty; then return 0; fi
  local label="$1" done="$2" total="$3"
  local show_done="${4:-$done}" show_total="${5:-$total}"
  local width=24 filled i bar=""
  if [[ ${done} -gt ${total} ]]; then done=${total}; fi
  filled=$(( total > 0 ? width * done / total : 0 ))
  for (( i=0; i<width; i++ )); do
    if [[ $i -lt $filled ]]; then bar+="█"; else bar+="░"; fi
  done
  printf '\r   %s [%b%s%b] %s/%s' "${label}" "${GREEN}" "${bar}" "${RESET}" "${show_done}" "${show_total}"
}
bar_done() {
  if [[ "${VERBOSITY}" -ge 1 ]] && is_tty; then printf '\n'; fi
}

human_size() {
  local bytes="$1"
  if [[ "${bytes}" -ge 1073741824 ]]; then
    awk "BEGIN {printf \"%.1f GB\", ${bytes}/1073741824}"
  elif [[ "${bytes}" -ge 1048576 ]]; then
    awk "BEGIN {printf \"%d MB\", ${bytes}/1048576}"
  else
    awk "BEGIN {printf \"%d KB\", ${bytes}/1024}"
  fi
}

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
    --with-gemma)
      WITH_GEMMA=true
      EXPLICIT_GEMMA=true
      shift
      ;;
    --with-starter-model)
      WITH_STARTER=true
      shift
      ;;
    --with-vision)
      WITH_VISION=true
      shift
      ;;
    --no-models)
      WITH_GEMMA=false
      WITH_STARTER=false
      WITH_VISION=false
      shift
      ;;
    --quiet)
      QUIET_FLAG=true
      shift
      ;;
    --verbose)
      VERBOSE_FLAG=true
      shift
      ;;
    -h|--help)
      sed -n '2,36p' "$0" | sed 's/^# //'
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      echo "Use --help for usage instructions."
      exit 1
      ;;
  esac
done

if [[ "${QUIET_FLAG}" == "true" ]]; then
  VERBOSITY=0
elif [[ "${VERBOSE_FLAG}" == "true" || "${DRY_RUN}" == "true" ]]; then
  VERBOSITY=2
fi

echo -e "${BOLD}syntropd ${VERSION}${RESET} ${DIM}— Native AI Subsystem for systemd${RESET}"

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
  phase "System check"
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
    # os-release defines VERSION (the OS version); keep the installer version.
    local installer_version="${VERSION}"
    # shellcheck disable=SC1091
    . /etc/os-release
    VERSION="${installer_version}"
    DISTRO_ID="${ID:-linux}"
    DISTRO_NAME="${NAME:-Linux}"
    log_ok "Distribution: ${DISTRO_NAME} (${DISTRO_ID})"
  else
    log_warn "/etc/os-release not found. Treating as generic Linux."
    DISTRO_ID="generic"
    DISTRO_NAME="Linux"
  fi

  # 7. Hardware acceleration check
  local accel="CPU only"
  if compgen -G "/dev/dri/renderD*" > /dev/null; then
    log_ok "DRM GPU render nodes detected: $(echo /dev/dri/renderD*)"
    accel="GPU"
  else
    log_info "No DRM render nodes found; CPU execution fallback will be active."
  fi

  if compgen -G "/dev/accel/*" > /dev/null; then
    log_ok "Dedicated NPU/AI accelerators detected: $(echo /dev/accel/*)"
    accel="${accel} + NPU"
  fi

  result "Linux ${ARCH} · systemd ${systemd_ver} · ${accel}"
}

# ----------------- Uninstallation -----------------
do_uninstall() {
  phase "Uninstall"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Would disable syntrop-sockets.target, stop daemons, and remove unit files and binaries."
    exit 0
  fi

  if [[ -f "${UNIT_DIR}/syntrop-sockets.target" ]]; then
    log_info "Stopping and disabling syntrop-sockets.target..."
    systemctl disable --now syntrop-sockets.target 2>/dev/null || true
  fi

  local daemons=("inferenced" "modeld" "contextd" "toold" "runtimed" "systemd-sentry" "sentry" "routerd")
  for d in "${daemons[@]}"; do
    systemctl disable --now "${d}.socket" 2>/dev/null || true
    systemctl disable --now "${d}.service" 2>/dev/null || true
    rm -f "${UNIT_DIR}/${d}.socket" "${UNIT_DIR}/${d}.service"
  done

  rm -f "${UNIT_DIR}/syntrop-sockets.target"
  rm -f "${UNIT_DIR}/syntrop-triage@.service"
  rm -f /etc/polkit-1/rules.d/49-syntrop-tool.rules
  rm -rf "${RUN_DIR}" "${RUN_SENTRY_DIR}"

  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed 2>/dev/null || true

  log_info "Removing binaries from ${BIN_DIR}..."
  rm -f "${BIN_DIR}/syntropctl" \
        "${BIN_DIR}/inferenced" \
        "${BIN_DIR}/inferenctl" \
        "${BIN_DIR}/modeld" \
        "${BIN_DIR}/modelctl" \
        "${BIN_DIR}/contextd" \
        "${BIN_DIR}/contextctl" \
        "${BIN_DIR}/toold" \
        "${BIN_DIR}/toolctl" \
        "${BIN_DIR}/runtimed" \
        "${BIN_DIR}/runtimectl" \
        "${BIN_DIR}/sentry" \
        "${BIN_DIR}/systemd-sentry" \
        "${BIN_DIR}/routerd" \
        "${BIN_DIR}/routerctl" \
        "${BIN_DIR}/syntropd" \
        "${BIN_DIR}/syntrop" \
        "${BIN_DIR}/syn"

  if [[ -n "${TARGET_USER}" && "${TARGET_USER}" != "root" ]]; then
    local user_home
    user_home="$(eval echo "~${TARGET_USER}" 2>/dev/null || echo "")"
    if [[ -n "${user_home}" && -d "${user_home}/.local/bin" ]]; then
      log_info "Removing CLI symlinks from ${user_home}/.local/bin..."
      for cbin in syntropctl routerctl syntropd syntrop syn inferenctl modelctl contextctl toolctl runtimectl; do
        rm -f "${user_home}/.local/bin/${cbin}"
      done
    fi
  fi

  if [[ "${PURGE}" == "true" ]]; then
    log_info "--purge specified: removing configuration, caches, and system user/group..."
    rm -rf "${CONFIG_DIR}"
    rm -rf "${MODEL_DIR}"
    rm -rf "${ROLLBACK_DIR}"
    rm -rf "${TOOLD_DIR}"
    userdel sentry 2>/dev/null || true
    userdel -f syntrop 2>/dev/null || true
    groupdel syntrop 2>/dev/null || true
    log_ok "Purged configurations, data directories, and system user/group."
    result "Uninstalled and purged."
  else
    log_ok "Uninstallation complete. (Model cache in ${MODEL_DIR} and configs in ${CONFIG_DIR} preserved)."
    result "Uninstalled (brains and configs kept)."
  fi
  exit 0
}

# ----------------- System Provisioning -----------------
provision_system() {
  phase "Users and folders"
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

  # 2b. System user: syntrop (for routerd and unprivileged daemons)
  if ! id -u syntrop >/dev/null 2>&1; then
    useradd -r -s /usr/sbin/nologin -g syntrop -d /var/lib/syntrop -c "syntropd AI Subsystem" syntrop 2>/dev/null || \
    useradd -r -s /bin/false -g syntrop -d /var/lib/syntrop -c "syntropd AI Subsystem" syntrop
    log_ok "Created system user: syntrop"
  fi

  # 2c. System user: syntrop-runtime (for runtimed; video/render for GPUs)
  if ! id -u syntrop-runtime >/dev/null 2>&1; then
    useradd -r -s /usr/sbin/nologin -g syntrop -d /var/lib/models -c "Syntropd Runtime Daemon" syntrop-runtime 2>/dev/null || \
    useradd -r -s /bin/false -g syntrop -d /var/lib/models -c "Syntropd Runtime Daemon" syntrop-runtime
    log_ok "Created system user: syntrop-runtime"
  fi
  for g in video render; do
    if getent group "$g" >/dev/null 2>&1 && ! id -nG syntrop-runtime 2>/dev/null | grep -qw "$g"; then
      usermod -aG "$g" syntrop-runtime 2>/dev/null || true
    fi
  done

  # 2d. Unprivileged daemon users (least privilege: no daemon runs as root)
  if ! getent group sentry >/dev/null 2>&1; then
    groupadd -r sentry
    log_ok "Created system group: sentry"
  fi
  for u in inferenced modeld syntrop-tool syntrop-context; do
    if ! id -u "$u" >/dev/null 2>&1; then
      case "$u" in
        inferenced) home=/var/lib/inferenced; gecos="Syntropd Hardware Arbiter" ;;
        modeld) home=/var/lib/models; gecos="Syntropd Model Store" ;;
        syntrop-tool) home=/var/lib/toold; gecos="Syntropd Tool Daemon" ;;
        syntrop-context) home=/var/lib/contextd; gecos="Syntropd Context Daemon" ;;
      esac
      useradd -r -s /usr/sbin/nologin -g syntrop -d "$home" -c "$gecos" "$u" 2>/dev/null || \
      useradd -r -s /bin/false -g syntrop -d "$home" -c "$gecos" "$u"
      log_ok "Created system user: $u"
    fi
  done
  # toold reads the system journal for diagnostics (journal.slice tool)
  if getent group systemd-journal >/dev/null 2>&1 && ! id -nG syntrop-tool 2>/dev/null | grep -qw systemd-journal; then
    usermod -aG systemd-journal syntrop-tool 2>/dev/null || true
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

  mkdir -p "${MODEL_DIR}/gguf"
  chown root:syntrop "${MODEL_DIR}/gguf"
  chmod 0775 "${MODEL_DIR}/gguf"

  chown root:syntrop "${TOOLD_DIR}"
  chmod 0775 "${TOOLD_DIR}"

  mkdir -p /var/lib/contextd /var/lib/contextd/diffs
  chown root:syntrop /var/lib/contextd /var/lib/contextd/diffs
  chmod 0775 /var/lib/contextd /var/lib/contextd/diffs

  chown root:syntrop "${ROLLBACK_DIR}"
  chmod 0770 "${ROLLBACK_DIR}"

  mkdir -p /var/lib/syntrop
  chown syntrop:syntrop /var/lib/syntrop 2>/dev/null || true
  chmod 0775 /var/lib/syntrop

  chown root:root "${CONFIG_DIR}"
  chmod 0755 "${CONFIG_DIR}"

  # Provision systemd tmpfiles.d definition so /run/syntrop is permanently preserved
  cat <<'EOF' > /etc/tmpfiles.d/syntrop.conf
d /run/syntrop 0775 root syntrop -
d /run/systemd-sentry 0775 sentry syntrop -
d /var/lib/syntrop 0775 syntrop syntrop -
d /var/lib/models 0775 root syntrop -
d /var/lib/models/gguf 0775 root syntrop -
d /var/lib/toold 0775 root syntrop -
d /var/lib/contextd 0775 root syntrop -
d /var/lib/contextd/diffs 0775 root syntrop -
L+ /run/syntrop/io.syntrop.Sentry1 - - - - /run/systemd-sentry/sentry.sock
EOF
  systemd-tmpfiles --create /etc/tmpfiles.d/syntrop.conf 2>/dev/null || true

  # Deploy default routerd.toml if missing
  if [[ ! -f "${CONFIG_DIR}/routerd.toml" ]]; then
    cat <<'EOF' > "${CONFIG_DIR}/routerd.toml"
# /etc/syntrop/routerd.toml
# syntropd Router & Reverse Proxy Daemon Configuration

[daemon]
listen_tcp = "127.0.0.1:32768"
listen_unix = "/run/syntrop/router.sock"
varlink_socket = "/run/syntrop/io.syntrop.Router1"
inferenced_socket = "/run/syntrop/io.syntrop.Inference1"
log_level = "info"

[thresholds]
max_latency_ms = 15000
psi_memory_threshold = 25.0
max_retries = 2
rss_limit_mb = 15
min_tokens_per_second = 10.0

# Local-only: cloud providers were removed. Setup enables what it verifies.

# Local syntrop Varlink Bridge (Hardware Accelerated)
[[providers]]
enabled = false
id = "syntrop-local"
name = "Syntrop Local Inferenced Broker"
kind = "varlink"
base_url = "/run/syntrop/io.syntrop.Inference1"
tier = "fast"
weight = 1.3
timeout_ms = 600000
EOF
    chown root:syntrop "${CONFIG_DIR}/routerd.toml" 2>/dev/null || true
    chmod 0640 "${CONFIG_DIR}/routerd.toml" 2>/dev/null || true
    log_ok "Provisioned default router configuration at ${CONFIG_DIR}/routerd.toml"
  fi

  log_ok "System directories and ownership provisioned."
  result "Users, group and directories ready."
}

# ----------------- Binary Installation -----------------
install_binaries() {
  phase "Programs"
  log_info "Installing suite binaries to ${BIN_DIR}..."

  local binaries=("syntropctl" "inferenced" "inferenctl" "modeld" "modelctl" "contextd" "contextctl" "toold" "toolctl" "runtimed" "runtimectl" "sentry" "systemd-sentry" "routerd" "routerctl" "syntropd" "syntrop")

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Would install binaries: ${binaries[*]} into ${BIN_DIR}."
    return 0
  fi

  local pre_count=0
  local bin
  for bin in "${binaries[@]}"; do
    if [[ -x "${BIN_DIR}/${bin}" ]]; then pre_count=$((pre_count + 1)); fi
  done
  local fresh_count=0 from_bundle=0 from_local=0 from_cargo=0

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local sudo_home=""
  if [[ -n "${TARGET_USER}" ]]; then
    sudo_home="$(eval echo "~${TARGET_USER}" 2>/dev/null || echo "")"
  fi

  # Local checkouts are strictly opt-in (--local <PATH>). The default path
  # installs the versioned GitHub release bundle, so a curl-pipe install
  # always yields the blessed bits — never whatever stale target/ dirs
  # happen to exist on the machine.
  if [[ -z "${LOCAL_SRC}" ]]; then
    log_info "Using precompiled release bundle v${VERSION} (pass --local <PATH> to install from source checkouts)."
  fi

  local search_roots=(
    "${LOCAL_SRC}"
    "${script_dir}/.."
    "${script_dir}"
    "${PWD}"
    "${sudo_home}/Projects/syntropd"
    "${sudo_home}/Projects/UberMetroid"
  )

  # Phase 1: Local workspace builds (--local only)
  local missing=()
  for bin in "${binaries[@]}"; do
    local installed=false

    for root in "${search_roots[@]}"; do
      if [[ -z "${LOCAL_SRC}" || -z "${root}" || ! -d "${root}" ]]; then
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
          fresh_count=$((fresh_count + 1)); from_local=$((from_local + 1))
          installed=true
          break 2
        fi
      done
    done

    if [[ "${installed}" == "false" && -n "${LOCAL_SRC}" ]]; then
      # If binary already exists in PATH or current install (--local only:
      # the default path refreshes everything from the release bundle)
      if command -v "${bin}" >/dev/null 2>&1; then
        local src_bin
        src_bin="$(command -v "${bin}")"
        # Skip when PATH resolves to the install target itself, including via
        # a symlinked dir (e.g. /usr/local/sbin -> bin): copying a file onto
        # itself aborts the installer under set -e. Leaving it missing lets
        # Phase 2 refresh it from the release bundle instead.
        if [[ -f "${src_bin}" && "${src_bin}" != "${BIN_DIR}/${bin}" ]] && [[ ! "${src_bin}" -ef "${BIN_DIR}/${bin}" ]]; then
          install -D -p -m 0755 "${src_bin}" "${BIN_DIR}/${bin}"
          log_ok "Installed ${bin} from system PATH (${src_bin})"
          fresh_count=$((fresh_count + 1)); from_local=$((from_local + 1))
          installed=true
        fi
      fi
    fi

    if [[ "${installed}" == "false" ]]; then
      missing+=("${bin}")
    fi
  done

  # Phase 1.5: Compile missing binaries from local source checkouts.
  # --local only. Only what is missing, nothing more. Builds as the
  # invoking user so we reuse their cargo cache instead of re-downloading
  # the registry as root. Tries offline first; falls back to a networked
  # build when deps are absent.
  if [[ -n "${LOCAL_SRC}" && ${#missing[@]} -gt 0 ]] && command -v cargo >/dev/null 2>&1; then
    local build_user=""
    if [[ -n "${TARGET_USER}" && "${TARGET_USER}" != "root" && -n "${sudo_home}" && -d "${sudo_home}" ]] && command -v runuser >/dev/null 2>&1; then
      build_user="${TARGET_USER}"
    fi
    local need_build=()
    for bin in "${missing[@]}"; do
      local src="${bin}"
      case "${bin}" in
        systemd-sentry) src="sentry" ;;
        routerctl) src="routerd" ;;
        inferenctl) src="inferenced" ;;
        modelctl) src="modeld" ;;
        contextctl) src="contextd" ;;
        toolctl) src="toold" ;;
        runtimectl) src="runtimed" ;;
        syntrop) src="syntropd" ;;
      esac
      local built=false
      for root in "${search_roots[@]}"; do
        [[ -n "${root}" && -f "${root}/${src}/Cargo.toml" ]] || continue
        local out_bin="${root}/${src}/target/release/${bin}"
        if [[ ! -x "${out_bin}" ]]; then
          log_info "Compiling ${bin} from local source (${root}/${src})..."
          if [[ -n "${build_user}" ]]; then
            (cd "${root}/${src}" && { runuser -u "${build_user}" -- env "HOME=${sudo_home}" "CARGO_HOME=${sudo_home}/.cargo" cargo build --release --offline -q || runuser -u "${build_user}" -- env "HOME=${sudo_home}" "CARGO_HOME=${sudo_home}/.cargo" cargo build --release -q; }) >/dev/null 2>&1 || true
          else
            (cd "${root}/${src}" && { cargo build --release --offline -q || cargo build --release -q; }) >/dev/null 2>&1 || true
          fi
        fi
        if [[ -x "${out_bin}" ]]; then
          install -D -p -m 0755 "${out_bin}" "${BIN_DIR}/${bin}"
          log_ok "Installed ${bin} from local source build"
          fresh_count=$((fresh_count + 1)); from_local=$((from_local + 1))
          built=true
          break
        fi
      done
      if [[ "${built}" == "false" ]]; then
        need_build+=("${bin}")
      fi
    done
    if [[ ${#need_build[@]} -gt 0 ]]; then
      missing=("${need_build[@]}")
    else
      missing=()
    fi
  fi

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
          fresh_count=$((fresh_count + 1)); from_bundle=$((from_bundle + 1))
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
        syntrop) cargo_packages+=("syntropd") ;;
        sentry|systemd-sentry) cargo_packages+=("syntrop-sentry") ;;
        inferenced) cargo_packages+=("syntrop-inferenced") ;;
        modeld) cargo_packages+=("syntrop-modeld") ;;
        contextd) cargo_packages+=("syntrop-contextd") ;;
        toold) cargo_packages+=("syntrop-toold") ;;
        runtimed) cargo_packages+=("syntrop-runtimed") ;;
        routerd|routerctl) cargo_packages+=("syntrop-routerd" "routerctl") ;;
        inferenctl) cargo_packages+=("inferenctl") ;;
        modelctl) cargo_packages+=("modelctl") ;;
        contextctl) cargo_packages+=("contextctl") ;;
        toolctl) cargo_packages+=("toolctl") ;;
        runtimectl) cargo_packages+=("runtimectl") ;;
      esac
    done
    local unique_pkgs=($(echo "${cargo_packages[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
    cargo install --root "${PREFIX}" "${unique_pkgs[@]}" || true
    local now_present=0
    for bin in "${binaries[@]}"; do
      if [[ -x "${BIN_DIR}/${bin}" ]]; then now_present=$((now_present + 1)); fi
    done
    from_cargo=$((now_present - pre_count - fresh_count))
    if [[ ${from_cargo} -lt 0 ]]; then from_cargo=0; fi
    fresh_count=$((fresh_count + from_cargo))
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

  # Short alias for the front door (revocable; syntrop stays canonical).
  ln -sf "${BIN_DIR}/syntrop" "${BIN_DIR}/syn"
  log_ok "Linked ${BIN_DIR}/syn -> syntrop."

  if [[ ${fresh_count} -eq 0 ]]; then
    result "${verified_count}/${#binaries[@]} programs ready (already installed)."
  else
    local parts=()
    if [[ ${from_bundle} -gt 0 ]]; then parts+=("${from_bundle} bundle"); fi
    if [[ ${from_local} -gt 0 ]]; then parts+=("${from_local} local"); fi
    if [[ ${from_cargo} -gt 0 ]]; then parts+=("${from_cargo} built"); fi
    result "${verified_count}/${#binaries[@]} programs ready (${fresh_count} new: $(IFS=,; echo "${parts[*]}"))."
  fi

  # Purge daemon binaries from ~/.local/bin to prevent PATH shadowing, symlink client CLIs only
  if [[ -n "${sudo_home}" && -d "${sudo_home}/.local/bin" ]]; then
    local daemon_bins=("routerd" "systemd-sentry" "sentry" "inferenced" "modeld" "contextd" "toold" "runtimed")
    for dbin in "${daemon_bins[@]}"; do
      rm -f "${sudo_home}/.local/bin/${dbin}"
    done

    local cli_bins=("syntropctl" "routerctl" "syntropd" "syntrop" "syn" "inferenctl" "modelctl" "contextctl" "toolctl" "runtimectl")
    for cbin in "${cli_bins[@]}"; do
      if [[ -f "${BIN_DIR}/${cbin}" ]]; then
        ln -sf "${BIN_DIR}/${cbin}" "${sudo_home}/.local/bin/${cbin}"
        if [[ -n "${TARGET_USER}" ]]; then
          chown -h "${TARGET_USER}:${TARGET_USER}" "${sudo_home}/.local/bin/${cbin}" 2>/dev/null || true
        fi
      fi
    done
    log_ok "Purged daemon binaries and linked client CLIs in ${sudo_home}/.local/bin."
  fi
}

# ----------------- Model Provisioning -----------------
# The install ships a working brain, not an empty engine. All URLs below
# were verified live (HTTP 200) before release; the HuggingFace "resolve"
# links always serve the exact file bytes.
QWEN_GGUF_URL="https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q8_0.gguf"
QWEN_TOK_URL="https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct/resolve/main/tokenizer.json"
GEMMA_Q4_URL="https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf"
MMPROJ_URL="https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/mmproj-F16.gguf"

fetch_model() {
  local url="$1"
  local dest="$2"
  local name
  name="$(basename "${dest}")"
  if [[ -s "${dest}" ]]; then
    log_info "Model already present: ${name}"
    return 0
  fi
  local tmp="${dest}.part"
  rm -f "${tmp}"
  local total=""
  if [[ "${VERBOSITY}" -ge 1 ]] && is_tty; then
    total="$(curl -fsSIL --max-time 20 "${url}" 2>/dev/null | awk '/^[Cc]ontent-[Ll]ength:/ {len=$2} END {print len}' | tr -d '\r')"
  fi
  if [[ "${total}" =~ ^[0-9]+$ && "${total}" -gt 0 ]]; then
    log_info "Downloading ${name} ($(human_size "${total}"))..."
    curl -fsSL --retry 3 --retry-delay 2 -o "${tmp}" "${url}" 2>/dev/null &
    local curl_pid=$!
    local have=0
    while kill -0 "${curl_pid}" 2>/dev/null; do
      # kill -0 also succeeds on zombies; break once curl has exited.
      if [[ "$(cut -d' ' -f3 "/proc/${curl_pid}/stat" 2>/dev/null)" == "Z" ]]; then break; fi
      if [[ -f "${tmp}" ]]; then have=$(stat -c%s "${tmp}" 2>/dev/null || echo 0); fi
      bar_draw "${name}" "${have}" "${total}" "$(human_size "${have}")" "$(human_size "${total}")"
      sleep 0.5
    done
    if wait "${curl_pid}"; then
      bar_draw "${name}" "${total}" "${total}" "$(human_size "${total}")" "$(human_size "${total}")"
      bar_done
    else
      rm -f "${tmp}"
      bar_done
      log_error "Download failed: ${url}"
      log_error "Check your connection and re-run the installer to resume."
      exit 1
    fi
  else
    if [[ "${VERBOSITY}" -ge 1 ]]; then echo "   ↓ ${name}..."; fi
    log_info "Downloading ${name}..."
    if ! curl -fSL --retry 3 --retry-delay 2 -o "${tmp}" "${url}"; then
      rm -f "${tmp}"
      log_error "Download failed: ${url}"
      log_error "Check your connection and re-run the installer to resume."
      exit 1
    fi
  fi
  mv "${tmp}" "${dest}"
  chown root:syntrop "${dest}"
  chmod 0640 "${dest}"
  log_ok "Fetched ${name}"
}

install_models() {
  phase "AI brains"
  if [[ "${WITH_GEMMA}" != "true" && "${WITH_STARTER}" != "true" && "${WITH_VISION}" != "true" ]]; then
    log_info "--no-models: skipping model downloads (engine only)."
    result "Engine only, no brains."
    return 0
  fi

  # Brain fit: the CPU engine holds weights as F32, so the 5B Gemma needs
  # about 28 GB of RAM to load (fleet binaries are CPU-only). Small
  # machines get Qwen instead of a brain they could never run — unless the
  # operator explicitly insisted on Gemma, which is honored with a warning.
  if [[ "${WITH_GEMMA}" == "true" ]]; then
    # TEST_MEM_KB overrides reading for the installer test only.
    local mem_kb="${TEST_MEM_KB:-$(awk '/MemTotal/ {print $2}' /proc/meminfo)}"
    if [[ "${mem_kb}" -ge 31457280 ]]; then
      log_info "Brain fit: ${mem_kb} kB RAM — Gemma 4 E2B fits."
    elif [[ "${EXPLICIT_GEMMA}" == "true" ]]; then
      log_warn "Brain fit: only ${mem_kb} kB RAM; Gemma needs ~30 GB."
      log_warn "Proceeding because --with-gemma was explicit; expect load failure."
    else
      log_warn "Brain fit: ${mem_kb} kB RAM is short of Gemma's ~30 GB need."
      log_warn "Installing the Qwen starter brain instead (pass --with-gemma to override)."
      WITH_GEMMA=false
      WITH_STARTER=true
      DOWNGRADED_TO_QWEN=true
    fi
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Would download models into ${MODEL_DIR}/gguf:"
    if [[ "${WITH_GEMMA}" == "true" ]]; then log_info "[DRY-RUN]   gemma-4-E2B-it-Q4_K_M.gguf (3.1 GB)"; fi
    if [[ "${WITH_STARTER}" == "true" ]]; then log_info "[DRY-RUN]   qwen2.5-0.5b-instruct-q8_0.gguf + tokenizer (~700 MB)"; fi
    if [[ "${WITH_VISION}" == "true" ]]; then log_info "[DRY-RUN]   mmproj-F16.gguf (~1 GB)"; fi
    return 0
  fi

  command -v curl >/dev/null 2>&1 || {
    log_error "curl is missing, and models need downloading."
    log_error "Install curl or re-run with --no-models."
    exit 1
  }

  log_info "Fetching models into ${MODEL_DIR}/gguf..."
  mkdir -p "${MODEL_DIR}/gguf"
  if [[ "${WITH_STARTER}" == "true" ]]; then
    fetch_model "${QWEN_GGUF_URL}" "${MODEL_DIR}/gguf/qwen2.5-0.5b-instruct-q8_0.gguf"
    # Qwen needs its word-list file sitting next to it under this exact name.
    fetch_model "${QWEN_TOK_URL}" "${MODEL_DIR}/gguf/qwen2.5-0.5b-instruct-q8_0.tokenizer.json"
  fi
  if [[ "${WITH_GEMMA}" == "true" ]]; then
    fetch_model "${GEMMA_Q4_URL}" "${MODEL_DIR}/gguf/gemma-4-E2B-it-Q4_K_M.gguf"
  fi
  if [[ "${WITH_VISION}" == "true" ]]; then
    fetch_model "${MMPROJ_URL}" "${MODEL_DIR}/gguf/mmproj-F16.gguf"
  fi
  log_ok "Model provisioning complete."
  local brain_files brain_bytes
  brain_files=$(compgen -G "${MODEL_DIR}/gguf/*.gguf" | wc -l)
  brain_bytes=$(du -sb "${MODEL_DIR}/gguf" 2>/dev/null | awk '{print $1}')
  result "${brain_files} brains ready ($(human_size "${brain_bytes:-0}"))."
}

wire_router() {
  # Point the front door at the installed brain. Runs after sockets are
  # live so setup can verify the engine answers. Never fatal: on failure
  # the closing message falls back to the manual setup step.
  phase "Wiring"
  if ! compgen -G "${MODEL_DIR}/gguf/*.gguf" > /dev/null; then
    log_info "No model files in ${MODEL_DIR}/gguf; skipping router wiring."
    result "No brains yet, nothing to wire."
    return 0
  fi
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Would run: routerctl setup --auto (wire front door to runtimed)."
    return 0
  fi
  log_info "Wiring the front door to the installed brain..."
  if "${BIN_DIR}/routerctl" setup --auto </dev/null; then
    ROUTER_WIRED=true
    log_ok "Router wired to runtimed."
    result "Front door answers."
    if [[ "${DOWNGRADED_TO_QWEN}" == "true" && -s "${MODEL_DIR}/gguf/qwen2.5-0.5b-instruct-q8_0.gguf" ]]; then
      # Small machine: Gemma may sit on disk from an earlier run, but only
      # Qwen can load here — pin it so the front door answers.
      if "${BIN_DIR}/routerctl" default qwen2.5-0.5b-instruct-q8_0; then
        log_ok "Default brain pinned to Qwen (fits this machine)."
      else
        log_warn "Could not pin the Qwen default; run 'routerctl default qwen2.5-0.5b-instruct-q8_0'."
      fi
    fi
  else
    log_warn "Automatic router wiring failed; run 'sudo syn router setup' by hand."
  fi
}

# ----------------- Systemd Unit Registration -----------------
register_units() {
  phase "Services"
  log_info "Registering systemd units into ${UNIT_DIR}..."

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Would register syntrop-sockets.target, syntrop-triage@.service, and all 7 daemon socket/service units."
    return 0
  fi

  # 1. syntrop-sockets.target
  cat <<'EOF' > "${UNIT_DIR}/syntrop-sockets.target"
[Unit]
Description=syntropd Unified Socket Activation Umbrella
Documentation=https://syntropd.github.io/architecture.html#socket
Wants=inferenced.socket modeld.socket contextd.socket toold.socket runtimed.socket systemd-sentry.socket routerd.socket
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
PartOf=syntrop-sockets.target

[Socket]
ListenStream=/run/syntrop/io.syntrop.Tool1
SocketMode=0666
SocketUser=root
SocketGroup=syntrop
DirectoryMode=0755
PassCredentials=yes
PassSecurity=yes

[Install]
WantedBy=syntrop-sockets.target sockets.target
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
Restart=on-failure
RestartSec=2s

# No WatchdogSec: the daemon sends READY/STOPPING but no WATCHDOG=1
# pings, so a watchdog would kill it on a timer.

# Unprivileged execution (privileged remediation via polkit rule)
User=syntrop-tool
Group=syntrop
SupplementaryGroups=systemd-journal
NoNewPrivileges=yes

# Hardened sandboxing (children inherit mount + seccomp containment)
ProtectSystem=strict
ProtectHome=read-only
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
PrivateTmp=true
PrivateDevices=true
MemoryDenyWriteExecute=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

# Storage and runtime paths
ReadWritePaths=/var/lib/toold /var/lib/syntrop/rollbacks /run/syntrop
ReadOnlyPaths=/etc /var/log /usr/lib/systemd/system

# Resource containment
MemoryHigh=32M
MemoryMax=64M
TasksMax=32

[Install]
WantedBy=multi-user.target
EOF

  # 4. runtimed.socket & runtimed.service
  cat <<'EOF' > "${UNIT_DIR}/runtimed.socket"
[Unit]
Description=Syntropd Headless Model Execution and Tensor Generation Varlink Socket
Documentation=https://github.com/syntropd/runtimed
PartOf=syntrop-sockets.target

[Socket]
ListenStream=/run/syntrop/io.syntrop.Runtime1
SocketMode=0666
SocketUser=root
SocketGroup=syntrop
DirectoryMode=0755
PassCredentials=yes
PassSecurity=yes

[Install]
WantedBy=syntrop-sockets.target sockets.target
EOF

  cat <<EOF > "${UNIT_DIR}/runtimed.service"
[Unit]
Description=Syntropd Headless Model Execution and Tensor Generation Daemon
Documentation=https://github.com/syntropd/runtimed
Requires=runtimed.socket
After=network.target runtimed.socket

[Service]
Type=notify
User=syntrop-runtime
Group=syntrop
Environment="RUNTIMED_IDLE_UNLOAD_SECS=300"
ExecStart=${BIN_DIR}/runtimed
Restart=on-failure
RestartSec=2s
WatchdogSec=30s

# Sandboxing and device permissions (mirrors runtimed/systemd/runtimed.service).
# No RuntimeDirectory: /run/syntrop is owned by the socket unit and shared
# with the whole fleet; a service-level one would wipe every socket on restart.
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
PrivateTmp=true
MemoryDenyWriteExecute=false
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

ReadWritePaths=/var/lib/models /run/syntrop
# Any DeviceAllow flips DevicePolicy to allow-listed; path globs do NOT work,
# only char-<group>. Missing families surface as CUDA_ERROR_NO_DEVICE.
DeviceAllow=char-nvidia* rw
DeviceAllow=char-drm rw
DeviceAllow=char-accel rw

# Resource limits: the 5B engine holds ~21G F32 on CPU at load peak, so
# the ceiling must clear it (smaller brains never approach these).
MemoryHigh=24G
MemoryMax=32G
TasksMax=64
EOF

  # 5. inferenced.socket & inferenced.service
  cat <<'EOF' > "${UNIT_DIR}/inferenced.socket"
[Unit]
Description=inferenced Activation Sockets
Documentation=https://github.com/syntropd/inferenced
PartOf=syntrop-sockets.target

[Socket]
ListenStream=/run/syntrop/io.syntrop.Inference1
ListenStream=/run/syntrop/sentry.sock
ListenStream=/run/syntrop/gateway.sock
ListenStream=/run/syntrop/fd.sock
SocketMode=0666
SocketUser=root
SocketGroup=syntrop
DirectoryMode=0755

[Install]
WantedBy=syntrop-sockets.target sockets.target
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
Restart=on-failure
RestartSec=3s
WatchdogSec=30s
Slice=ai.slice

# Unprivileged execution (render/video for GPU telemetry)
User=inferenced
Group=syntrop
SupplementaryGroups=render video sentry
NoNewPrivileges=yes
AmbientCapabilities=CAP_KILL
CapabilityBoundingSet=CAP_KILL

# Security & Sandboxing
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
RestrictNamespaces=yes
MemoryDenyWriteExecute=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes

# Directories (/run/syntrop is fleet-shared via tmpfiles; state is private)
StateDirectory=inferenced

# Linux Device Permissions (DRM & Accel)
DeviceAllow=/dev/dri/renderD* rw
DeviceAllow=/dev/accel/* rw
DeviceAllow=/dev/hailo* rw
DeviceAllow=/dev/kfd rw

# cgroup v2 & systemd-oomd Protection
ManagedOOMPreference=avoid
OOMScoreAdjust=-900
OOMPolicy=stop

# Logging & systemd-journald
StandardOutput=journal
StandardError=journal
SyslogIdentifier=inferenced

LimitCORE=infinity
Environment=RUST_BACKTRACE=1

[Install]
WantedBy=multi-user.target
EOF

  # 6. contextd.socket & contextd.service
  cat <<'EOF' > "${UNIT_DIR}/contextd.socket"
[Unit]
Description=Syntropd System Chronology and Causality Graph Varlink Socket
Documentation=https://github.com/syntropd/contextd
PartOf=syntrop-sockets.target

[Socket]
ListenStream=/run/syntrop/io.syntrop.Context1
SocketMode=0666
SocketUser=root
SocketGroup=syntrop
DirectoryMode=0755
PassCredentials=yes
PassSecurity=yes

[Install]
WantedBy=syntrop-sockets.target sockets.target
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
Restart=on-failure
RestartSec=2s

# No WatchdogSec: the daemon sends READY/STOPPING but no WATCHDOG=1
# pings, so a watchdog would kill it on a timer.

# Unprivileged execution
User=syntrop-context
Group=syntrop
NoNewPrivileges=yes

# Hardened sandboxing
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
PrivateTmp=true
PrivateDevices=true
MemoryDenyWriteExecute=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

# Storage and runtime path access
ReadWritePaths=/var/lib/contextd /run/syntrop
ReadOnlyPaths=/etc /var/log /usr/lib/systemd/system

# Resource containment
MemoryHigh=32M
MemoryMax=64M
TasksMax=16

[Install]
WantedBy=multi-user.target
EOF

  # 7. modeld.socket & modeld.service
  cat <<'EOF' > "${UNIT_DIR}/modeld.socket"
[Unit]
Description=Syntropd modeld IPC Activation Sockets
Documentation=https://github.com/syntropd/modeld
PartOf=syntrop-sockets.target

[Socket]
ListenStream=/run/syntrop/io.syntrop.Model1
ListenStream=/run/syntrop/modeld-fd.sock
SocketMode=0666
SocketUser=root
SocketGroup=syntrop
DirectoryMode=0755

[Install]
WantedBy=syntrop-sockets.target sockets.target
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
WatchdogSec=15
Restart=on-failure
RestartSec=2s

# Unprivileged execution (Group=syntrop for shared model store writes)
User=modeld
Group=syntrop
Environment="MODELD_TRUSTED_GROUP=syntrop"
NoNewPrivileges=yes

# Sandboxing and security hardening
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
MemoryDenyWriteExecute=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes

# Allowed filesystem paths
ReadWritePaths=/var/lib/models /run/syntrop

[Install]
WantedBy=multi-user.target
EOF

  # 8. systemd-sentry.socket & systemd-sentry.service
  cat <<'EOF' > "${UNIT_DIR}/systemd-sentry.socket"
[Unit]
Description=systemd-sentry IPC and Varlink Activation Sockets
Documentation=https://github.com/syntropd/sentry
PartOf=syntrop-sockets.target

[Socket]
ListenStream=/run/systemd-sentry/sentry.sock
SocketUser=sentry
SocketGroup=syntrop
SocketMode=0666
DirectoryMode=0755
PassCredentials=yes
PassSecurity=yes

[Install]
WantedBy=syntrop-sockets.target sockets.target
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

  # 9. routerd.socket & routerd.service
  cat <<'EOF' > "${UNIT_DIR}/routerd.socket"
[Unit]
Description=routerd Socket Activation Descriptors
Documentation=https://github.com/syntropd/routerd
PartOf=syntrop-sockets.target

[Socket]
# File Descriptor 3: TCP dual-stack HTTP reverse proxy
ListenStream=127.0.0.1:32768
ListenStream=[::1]:32768
ReusePort=yes

# File Descriptor 4/5: Local Unix domain socket reverse proxy
ListenStream=/run/syntrop/router.sock
SocketMode=0666

# Native Varlink IPC socket
ListenStream=/run/syntrop/io.syntrop.Router1
SocketMode=0666

DirectoryMode=0755

[Install]
WantedBy=syntrop-sockets.target sockets.target
EOF

  cat <<EOF > "${UNIT_DIR}/routerd.service"
[Unit]
Description=Intelligent Model Router and Wire Protocol Gateway
Documentation=https://github.com/syntropd/routerd
After=network.target local-fs.target
Requires=routerd.socket

[Service]
Type=notify
ExecStart=${BIN_DIR}/routerd --config /etc/syntrop/routerd.toml
Restart=on-failure
RestartSec=3s
WatchdogSec=30s
Slice=ai.slice

# Memory constraints
MemoryHigh=24M
MemoryMax=32M

# Security & Sandboxing
User=syntrop
Group=syntrop
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=yes
MemoryDenyWriteExecute=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes

# Directories & Credentials
ConfigurationDirectory=syntrop
StateDirectory=routerd
LogsDirectory=routerd

# cgroup v2 & systemd-oomd Protection
ManagedOOMPreference=avoid
OOMScoreAdjust=-800
OOMPolicy=stop

# Logging & systemd-journald
StandardOutput=journal
StandardError=journal
SyslogIdentifier=routerd

LimitCORE=infinity
Environment=RUST_BACKTRACE=1

[Install]
WantedBy=multi-user.target
EOF

  # 10. Create sentry unit symlink aliases
  ln -sf "${UNIT_DIR}/systemd-sentry.service" "${UNIT_DIR}/sentry.service"
  ln -sf "${UNIT_DIR}/systemd-sentry.socket" "${UNIT_DIR}/sentry.socket"

  # 11. Polkit rule: unprivileged toold may restart fleet units only
  # (mirrors toold/polkit/49-syntrop-tool.rules; meta stays self-contained)
  mkdir -p /etc/polkit-1/rules.d
  cat <<'EOF' > /etc/polkit-1/rules.d/49-syntrop-tool.rules
// toold self-healing: let the unprivileged daemon user restart fleet
// units (the unit.restart tool). Narrow by verb AND unit name —
// anything else falls through to the default policy (deny).
polkit.addRule(function(action, subject) {
    if (action.id != "org.freedesktop.systemd1.manage-units") return;
    if (subject.user != "syntrop-tool") return;
    if (action.lookup("verb") != "restart") return;
    var unit = action.lookup("unit");
    var units = (typeof unit == "string") ? [unit] : unit;
    if (!units || !units.length) return;
    var fleet = /^(syntrop-|routerd|runtimed|inferenced|modeld|contextd|toold|sentry|systemd-sentry|syntropd)[\w@.:-]*$/;
    for (var i = 0; i < units.length; i++) {
        if (!fleet.test(units[i])) return;
    }
    return polkit.Result.YES;
});
EOF
  chmod 0644 /etc/polkit-1/rules.d/49-syntrop-tool.rules

  systemctl daemon-reload
  log_ok "Systemd units and aliases successfully registered and daemon reloaded."
  result "16 units registered."
}

# ----------------- Start & Activate -----------------
activate_subsystem() {
  phase "Startup"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Pre-flight verification completed successfully."
    log_ok "[DRY-RUN] System is fully compatible with syntropd."
    if [[ "${START_SOCKETS}" == "true" ]]; then
      wire_router
    fi
    return 0
  fi

  if [[ "${START_SOCKETS}" == "true" ]]; then
    log_info "Stopping running services to prevent directory cleanup races..."
    local services=("systemd-sentry" "routerd" "toold" "runtimed" "modeld" "inferenced" "contextd")
    for s in "${services[@]}"; do
      systemctl reset-failed "${s}.service" 2>/dev/null || true
    done
    systemctl stop "${services[@]/%/.service}" 2>/dev/null || true

    log_info "Applying tmpfiles.d configuration..."
    systemd-tmpfiles --create /etc/tmpfiles.d/syntrop.conf 2>/dev/null || true

    log_info "Enabling syntrop-sockets.target and socket units..."
    local sockets=("routerd.socket" "toold.socket" "runtimed.socket" "contextd.socket" "modeld.socket" "systemd-sentry.socket" "inferenced.socket")
    systemctl enable syntrop-sockets.target "${sockets[@]}"

    log_info "Restarting socket units and syntrop-sockets.target..."
    systemctl reset-failed "${sockets[@]}" syntrop-sockets.target 2>/dev/null || true
    systemctl restart "${sockets[@]}" syntrop-sockets.target
    log_ok "syntrop-sockets.target and activation sockets restarted."
    result "Sockets live."

    if [[ "${VERBOSITY}" -ge 2 ]]; then
      echo ""
      log_bold "Active Varlink and IPC Sockets:"
      systemctl list-sockets "inferenced*" "modeld*" "contextd*" "toold*" "runtimed*" "*sentry*" "routerd*" --no-pager 2>/dev/null || true
    fi

    echo ""
    log_bold "Verifying Subsystem Status:"
    "${BIN_DIR}/syntropctl" status || true

    echo ""
    wire_router
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
  if [[ "${ROUTER_WIRED}" == "true" ]]; then
    echo "System ready. Ask anything:"
    echo "  syn \"Say hello in one sentence.\""
    echo "  runtimectl generate -m gemma-4-E2B-it-Q4_K_M \"Say hello in one sentence.\""
    echo ""
  elif [[ -s "${MODEL_DIR}/gguf/gemma-4-E2B-it-Q4_K_M.gguf" ]]; then
    echo "A ready brain is installed (Gemma 4 E2B). Try it:"
    echo "  runtimectl generate -m gemma-4-E2B-it-Q4_K_M \"Say hello in one sentence.\""
    echo ""
  fi
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
  echo ""
  if [[ "${ROUTER_WIRED}" != "true" ]]; then
    log_bold "------------------------------------------------------------"
    log_bold " NEXT STEP (required): connect your local models"
    log_bold "------------------------------------------------------------"
    echo -e "  Run this command now: ${BOLD}sudo syn router setup${RESET}"
    echo "  It finds your model files and connects them to the front door."
    echo ""
  fi
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
  install_models
  register_units
  activate_subsystem
}

main "$@"
