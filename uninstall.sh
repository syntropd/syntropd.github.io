#!/usr/bin/env bash
# ==============================================================================
# syntropd: Native AI Subsystem for systemd — Production Uninstaller
#
# Removes all syntropd subsystem daemons, systemd services/sockets, shims,
# declarative sysusers/tmpfiles/polkit/udev policies, and client CLI binaries.
#
# Usage:
#   sudo ./uninstall.sh [OPTIONS]
#   curl -fsSL https://syntropd.github.io/uninstall.sh | sudo bash [OPTIONS]
#
# Options:
#   -p, --purge         Completely remove models (/var/lib/models), configs
#                       (/etc/syntrop), state data, system users, and groups.
#   --dry-run           Simulate uninstallation without modifying the system.
#   -y, --yes, -f       Proceed without interactive confirmation.
#   --prefix <PATH>     Installation prefix for binaries (default: /usr/local).
#   -q, --quiet         Suppress non-essential output.
#   -v, --verbose       Show detailed step-by-step actions.
#   -h, --help          Show this help message.
# ==============================================================================

set -euo pipefail

VERSION="0.6.2"
PREFIX="/usr/local"
BIN_DIR="${PREFIX}/bin"
UNIT_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/syntrop"
RUN_DIR="/run/syntrop"
RUN_SENTRY_DIR="/run/systemd-sentry"
RUN_INFERENCED_DIR="/run/systemd-inferenced"
MODEL_DIR="/var/lib/models"
ROLLBACK_DIR="/var/lib/syntrop/rollbacks"
TOOLD_DIR="/var/lib/toold"
COMPLETIONS_DIR="/usr/share/bash-completion/completions"

DRY_RUN=false
PURGE=false
ASSUME_YES=false
VERBOSITY=1
TARGET_USER="${SUDO_USER:-}"

# Colors
BOLD="\033[1m"
GREEN="\033[0;32m"
CYAN="\033[0;36m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
DIM="\033[0;90m"
RESET="\033[0m"

log_info()   { if [[ "${VERBOSITY}" -ge 2 ]]; then echo -e "${CYAN}[INFO]${RESET} $*"; fi; }
log_ok()     { if [[ "${VERBOSITY}" -ge 2 ]]; then echo -e "${GREEN}[OK]${RESET} $*"; fi; }
log_warn()   { if [[ "${VERBOSITY}" -ge 1 ]]; then echo -e "${YELLOW}[WARN]${RESET} $*"; fi; }
log_error()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_bold()   { echo -e "${BOLD}$*${RESET}"; }

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

is_tty() { [[ -t 0 && -t 1 ]]; }

show_help() {
  cat <<EOF
syntropd ${VERSION} — Production Uninstaller

Usage:
  sudo ./uninstall.sh [OPTIONS]

Options:
  -p, --purge         Completely remove models (/var/lib/models), configs
                      (/etc/syntrop), state data, system users, and groups
  --dry-run           Simulate uninstallation without modifying the system
  -y, --yes, -f       Proceed without interactive confirmation
  --prefix <PATH>     Installation prefix for binaries (default: /usr/local)
  -q, --quiet         Suppress non-essential output
  -v, --verbose       Show detailed step-by-step actions
  -h, --help          Show this help message

Examples:
  sudo ./uninstall.sh                      # Keep model brains and configs
  sudo ./uninstall.sh --purge              # Full purge of all data and users
  sudo ./uninstall.sh --dry-run            # Preview actions
EOF
  exit 0
}

# Parse command line options
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--purge)
      PURGE=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -y|--yes|-f|--force)
      ASSUME_YES=true
      shift
      ;;
    --prefix)
      PREFIX="$2"
      BIN_DIR="${PREFIX}/bin"
      shift 2
      ;;
    -q|--quiet)
      VERBOSITY=0
      shift
      ;;
    -v|--verbose)
      VERBOSITY=2
      shift
      ;;
    -h|--help)
      show_help
      ;;
    *)
      log_error "Unknown option: $1"
      echo "Run './uninstall.sh --help' for usage."
      exit 1
      ;;
  esac
done

if [[ "${DRY_RUN}" == "true" ]]; then
  if [[ "${VERBOSITY}" -lt 2 ]]; then VERBOSITY=2; fi
fi

check_euid() {
  if [[ "${DRY_RUN}" == "true" ]]; then return 0; fi
  if [[ "${EUID}" -ne 0 ]]; then
    log_error "Uninstallation requires root privileges. Please re-run with sudo:"
    echo "  sudo $0 $*"
    exit 1
  fi
}

confirm_uninstall() {
  if [[ "${DRY_RUN}" == "true" || "${ASSUME_YES}" == "true" ]] || ! is_tty; then
    return 0
  fi

  echo ""
  log_bold "syntropd ${VERSION} — Production Uninstaller"
  if [[ "${PURGE}" == "true" ]]; then
    echo -e "${RED}${BOLD}WARNING:${RESET} --purge specified. This will permanently delete:"
    echo "  - All systemd units, services, and sockets"
    echo "  - All client binaries, shims, and shell completions"
    echo "  - All downloaded models and weights (${MODEL_DIR})"
    echo "  - All configuration files (${CONFIG_DIR})"
    echo "  - All persistent state, rolls, and caches"
    echo "  - All dedicated syntrop system service accounts and groups"
  else
    echo "This will stop and remove syntropd systemd services, daemons, and binaries."
    echo "Downloaded model brains (${MODEL_DIR}) and configurations (${CONFIG_DIR}) will be preserved."
  fi
  echo ""
  read -r -p "Proceed with uninstallation? [y/N] " response
  case "${response}" in
    [yY][eE][sS]|[yY])
      ;;
    *)
      echo "Uninstallation aborted."
      exit 0
      ;;
  esac
}

# ----------------- Stop & Disable Units -----------------
stop_units() {
  phase "Stopping System Services"
  log_info "Stopping and disabling systemd units..."

  local daemon_units=(
    "syntrop-sockets.target"
    "routerd.socket" "routerd.service"
    "runtimed.socket" "runtimed.service"
    "toold.socket" "toold.service"
    "contextd.socket" "contextd.service"
    "modeld.socket" "modeld.service"
    "inferenced.socket" "inferenced.service"
    "systemd-sentry.socket" "systemd-sentry.service"
    "sentry.socket" "sentry.service"
    "syntrop-tuning.service"
  )

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Would disable and stop units: ${daemon_units[*]}"
    log_info "[DRY-RUN] Would disable user unit: syntrop-companion.service"
    return 0
  fi

  # 1. Disable umbrella target and sockets first to prevent restart loops
  systemctl disable --now syntrop-sockets.target 2>/dev/null || true

  # 2. Stop all daemon sockets and services
  for u in "${daemon_units[@]}"; do
    systemctl disable --now "${u}" 2>/dev/null || true
    systemctl stop "${u}" 2>/dev/null || true
  done

  # 3. Stop instantiated template services
  for t in "syntrop-admin@" "syntrop-triage@"; do
    local active_templates
    active_templates=$(systemctl list-units "${t}*.service" --no-legend 2>/dev/null | awk '{print $1}' || true)
    if [[ -n "${active_templates}" ]]; then
      # shellcheck disable=SC2086
      systemctl stop ${active_templates} 2>/dev/null || true
    fi
  done

  # 4. Stop and disable companion user unit across active user sessions
  systemctl --global disable syntrop-companion.service 2>/dev/null || true
  if command -v loginctl >/dev/null 2>&1; then
    while read -r uid _; do
      if [[ -n "${uid}" && "${uid}" =~ ^[0-9]+$ ]]; then
        systemctl --user -M "${uid}@" disable --now syntrop-companion.service 2>/dev/null || true
      fi
    done < <(loginctl list-users --no-legend 2>/dev/null || true)
  fi

  result "All syntrop services and socket listeners stopped."
}

# ----------------- Remove Unit Files & Drop-ins -----------------
remove_unit_files() {
  phase "Systemd Unit Files"
  log_info "Removing unit definitions and drop-in overrides..."

  local unit_files=(
    "${UNIT_DIR}/syntrop-sockets.target"
    "${UNIT_DIR}/syntrop-triage@.service"
    "${UNIT_DIR}/syntrop-admin@.service"
    "${UNIT_DIR}/syntrop-tuning.service"
    "${UNIT_DIR}/routerd.service" "${UNIT_DIR}/routerd.socket"
    "${UNIT_DIR}/runtimed.service" "${UNIT_DIR}/runtimed.socket"
    "${UNIT_DIR}/toold.service" "${UNIT_DIR}/toold.socket"
    "${UNIT_DIR}/contextd.service" "${UNIT_DIR}/contextd.socket"
    "${UNIT_DIR}/modeld.service" "${UNIT_DIR}/modeld.socket"
    "${UNIT_DIR}/inferenced.service" "${UNIT_DIR}/inferenced.socket"
    "${UNIT_DIR}/systemd-sentry.service" "${UNIT_DIR}/systemd-sentry.socket"
    "${UNIT_DIR}/sentry.service" "${UNIT_DIR}/sentry.socket"
    "/usr/lib/systemd/system/syntrop-sockets.target"
    "/usr/lib/systemd/system/syntrop-triage@.service"
    "/usr/lib/systemd/system/syntrop-admin@.service"
    "/usr/lib/systemd/system/syntrop-tuning.service"
    "/usr/lib/systemd/system/runtimed.service"
  )

  local user_unit_files=(
    "/usr/lib/systemd/user/syntrop-companion.service"
    "/etc/systemd/user/syntrop-companion.service"
  )

  local dropin_dirs=(
    "/etc/systemd/system/inferenced.service.d"
    "/etc/systemd/system/runtimed.service.d"
    "/etc/systemd/system/toold.service.d"
    "/etc/systemd/system/routerd.service.d"
    "/usr/lib/systemd/system/inferenced.service.d"
  )

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Would remove unit files from ${UNIT_DIR} and user units."
    log_info "[DRY-RUN] Would remove service drop-in directories: ${dropin_dirs[*]}."
    return 0
  fi

  for uf in "${unit_files[@]}"; do
    rm -f "${uf}"
  done

  for uuf in "${user_unit_files[@]}"; do
    rm -f "${uuf}"
  done

  for dd in "${dropin_dirs[@]}"; do
    rm -rf "${dd}"
  done

  systemctl daemon-reload 2>/dev/null || true
  systemctl --global daemon-reload 2>/dev/null || true
  systemctl reset-failed 2>/dev/null || true

  result "Unit definitions, drop-in overrides, and targets purged."
}

# ----------------- Remove Declarative Policies -----------------
remove_declarative_policies() {
  phase "System Policies"
  log_info "Removing declarative sysusers, tmpfiles, polkit, and udev rules..."

  local policy_files=(
    "/etc/polkit-1/rules.d/49-syntrop-tool.rules"
    "/etc/polkit-1/rules.d/50-syntrop-inhibit.rules"
    "/usr/share/polkit-1/rules.d/49-syntrop-tool.rules"
    "/usr/share/polkit-1/rules.d/50-syntrop-inhibit.rules"
    "/etc/sysusers.d/syntrop.conf"
    "/usr/lib/sysusers.d/syntrop.conf"
    "/etc/tmpfiles.d/syntrop.conf"
    "/usr/lib/tmpfiles.d/syntrop.conf"
    "/etc/udev/rules.d/70-syntrop-uinput.rules"
    "/usr/lib/udev/rules.d/70-syntrop-uinput.rules"
  )

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Would remove policy files: ${policy_files[*]}"
    return 0
  fi

  for pf in "${policy_files[@]}"; do
    rm -f "${pf}"
  done

  if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules 2>/dev/null || true
  fi

  result "Sysusers, tmpfiles, polkit, and udev rules removed."
}

# ----------------- Remove Binaries & Shims -----------------
remove_binaries() {
  phase "Programs and Shims"
  log_info "Removing binaries, shims, and shell completions..."

  local suite_bins=(
    "syntropctl" "inferenced" "inferenctl" "modeld" "modelctl"
    "contextd" "contextctl" "toold" "toolctl" "runtimed" "runtimectl"
    "sentry" "systemd-sentry" "routerd" "routerctl" "syntropd" "syntrop" "syn"
    "syntrop-uninstall" "syn-uninstall"
  )

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Would remove binaries from ${BIN_DIR} and /usr/bin: ${suite_bins[*]}"
    log_info "[DRY-RUN] Would remove inhibitor shims: /usr/lib/syntrop/bin/systemd-inhibit, ${PREFIX}/lib/syntrop"
    log_info "[DRY-RUN] Would remove shell completions from ${COMPLETIONS_DIR}"
    return 0
  fi

  # 1. Remove from primary BIN_DIR
  for b in "${suite_bins[@]}"; do
    rm -f "${BIN_DIR}/${b}"
    if [[ "${BIN_DIR}" != "/usr/bin" ]]; then
      rm -f "/usr/bin/${b}"
    fi
  done

  # 2. Remove shims and library directories
  rm -f "/usr/lib/syntrop/bin/systemd-inhibit"
  rm -rf "/usr/lib/syntrop"
  if [[ "${PREFIX}" != "/usr" ]]; then
    rm -f "${PREFIX}/lib/syntrop/bin/systemd-inhibit"
    rm -rf "${PREFIX}/lib/syntrop"
  fi

  # 3. Remove shell completions
  rm -f "${COMPLETIONS_DIR}/syn" "${COMPLETIONS_DIR}/syntrop" "${COMPLETIONS_DIR}/syntropctl"
  rm -f "/usr/share/zsh/site-functions/_syn" "/usr/share/zsh/site-functions/_syntrop"
  rm -f "/usr/share/fish/vendor_completions.d/syn.fish" "/usr/share/fish/vendor_completions.d/syntrop.fish"

  # 4. Remove CLI symlinks in user homes
  local check_users=()
  if [[ -n "${TARGET_USER}" && "${TARGET_USER}" != "root" ]]; then
    check_users+=("${TARGET_USER}")
  fi
  if command -v loginctl >/dev/null 2>&1; then
    while read -r _ uname; do
      if [[ -n "${uname}" && "${uname}" != "root" ]]; then
        check_users+=("${uname}")
      fi
    done < <(loginctl list-users --no-legend 2>/dev/null || true)
  fi

  for u in "${check_users[@]}"; do
    local uhome
    uhome="$(eval echo "~${u}" 2>/dev/null || echo "")"
    if [[ -n "${uhome}" && -d "${uhome}/.local/bin" ]]; then
      for b in "${suite_bins[@]}"; do
        rm -f "${uhome}/.local/bin/${b}"
      done
    fi
  done

  # 5. Clean runtime and ephemeral sockets
  rm -rf "${RUN_DIR}" "${RUN_SENTRY_DIR}" "${RUN_INFERENCED_DIR}"

  result "Suite binaries, shims, completions, and runtime sockets removed."
}

# ----------------- Purge Data & Accounts (Optional) -----------------
purge_data_and_accounts() {
  if [[ "${PURGE}" != "true" ]]; then
    echo ""
    log_bold "Preserved Assets:"
    echo "   • Models & Brains: ${MODEL_DIR}"
    echo "   • Configuration:   ${CONFIG_DIR}"
    echo ""
    echo "To completely erase model brains, configuration, and accounts, run:"
    echo "  sudo $0 --purge"
    return 0
  fi

  phase "Purging Data and Accounts"
  log_info "Purging configurations, model weights, and system accounts..."

  local persistent_dirs=(
    "${CONFIG_DIR}"
    "${MODEL_DIR}"
    "${ROLLBACK_DIR}"
    "${TOOLD_DIR}"
    "/var/lib/syntrop"
    "/var/lib/contextd"
    "/var/lib/inferenced"
    "/var/lib/systemd-sentry"
    "/var/log/inferenced"
  )

  local system_users=(
    "syntrop-admin"
    "syntrop-context"
    "syntrop-tool"
    "syntrop-runtime"
    "modeld"
    "inferenced"
    "sentry"
    "syntrop"
  )

  local system_groups=(
    "syntrop"
    "syntropd"
  )

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Would remove directories: ${persistent_dirs[*]}"
    log_info "[DRY-RUN] Would delete system accounts: ${system_users[*]}"
    log_info "[DRY-RUN] Would delete system groups: ${system_groups[*]}"
    return 0
  fi

  # 1. Remove persistent storage and configuration
  for pd in "${persistent_dirs[@]}"; do
    if [[ -d "${pd}" || -f "${pd}" ]]; then
      rm -rf "${pd}"
      log_ok "Removed ${pd}"
    fi
  done

  # 2. Dis-enroll users from syntrop and syntropd groups
  if [[ -n "${TARGET_USER}" && "${TARGET_USER}" != "root" ]]; then
    if command -v gpasswd >/dev/null 2>&1; then
      gpasswd -d "${TARGET_USER}" syntrop 2>/dev/null || true
      gpasswd -d "${TARGET_USER}" syntropd 2>/dev/null || true
    fi
  fi

  # 3. Delete system users
  for su in "${system_users[@]}"; do
    if id -u "${su}" >/dev/null 2>&1; then
      userdel -f "${su}" 2>/dev/null || true
      log_ok "Deleted system user ${su}"
    fi
  done

  # 4. Delete system groups
  for sg in "${system_groups[@]}"; do
    if getent group "${sg}" >/dev/null 2>&1; then
      groupdel "${sg}" 2>/dev/null || true
      log_ok "Deleted system group ${sg}"
    fi
  done

  result "Persistent caches, model weights, and system accounts deleted."
}

# ----------------- Main Execution -----------------
main() {
  check_euid
  confirm_uninstall
  stop_units
  remove_unit_files
  remove_declarative_policies
  remove_binaries
  purge_data_and_accounts

  echo ""
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_bold "Uninstallation dry-run complete. No changes were made."
  elif [[ "${PURGE}" == "true" ]]; then
    log_bold "syntropd has been completely uninstalled and purged from this system."
  else
    log_bold "syntropd has been uninstalled. Model brains and configuration were preserved."
  fi
}

main "$@"
