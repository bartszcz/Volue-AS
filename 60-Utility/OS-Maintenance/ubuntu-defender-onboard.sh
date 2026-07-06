#!/usr/bin/env bash
set -euo pipefail

OPTIONS:
--onboarding-script <path>   Path to Microsoft Defender onboarding python script (required)
--ubuntu-version <version>   Ubuntu repo version for Microsoft packages (default: 20.04)
--eicar-test                 Run EICAR test after onboarding
--log <path>                 Log file path
-h | --help                  Show help

LOG_FILE="/var/log/mde-onboard.log"

UBUNTU_REPO_VER="20.04"
ONBOARDING_SCRIPT=""
RUN_EICAR="false"

log() { echo "[$(date -Is)] $1" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $1"; exit 1; }

usage() {
  sed -n '3,9p' "$0"
}

require_root() {
  [[ "$EUID" -eq 0 ]] || die "Run as root."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --onboarding-script) ONBOARDING_SCRIPT="${2:-}"; shift 2 ;;
      --ubuntu-version) UBUNTU_REPO_VER="${2:-}"; shift 2 ;;
      --eicar-test) RUN_EICAR="true"; shift ;;
      --log) LOG_FILE="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  [[ -n "$ONBOARDING_SCRIPT" ]] || die "Missing --onboarding-script."
  [[ -f "$ONBOARDING_SCRIPT" ]] || die "Onboarding script not found."
}

prechecks() {
  [[ -f /etc/os-release ]] || die "Cannot detect OS."
  . /etc/os-release
  log "OS: ${PRETTY_NAME:-unknown}"
  log "Kernel: $(uname -r)"
  log "Hostname: $(hostname -f 2>/dev/null || hostname)"
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found."
  command -v python3 >/dev/null 2>&1 || die "python3 not found."
  command -v timedatectl >/dev/null 2>&1 && timedatectl | tee -a "$LOG_FILE" || true
}

install_prereqs() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y | tee -a "$LOG_FILE"
  apt-get install -y curl libplist-utils gpg gnupg apt-transport-https ca-certificates | tee -a "$LOG_FILE"
}

setup_microsoft_repo() {
  local keyring="/usr/share/keyrings/microsoft-prod.gpg"
  local list_file="/etc/apt/sources.list.d/microsoft-prod.list"

  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | tee "$keyring" > /dev/null
  chmod 644 "$keyring"

  local tmp_list="/tmp/microsoft-prod.list"
  curl -fsSL -o "$tmp_list" "https://packages.microsoft.com/config/ubuntu/${UBUNTU_REPO_VER}/prod.list"

  if grep -qE '^deb\s+\[arch=amd64\]' "$tmp_list"; then
    sed -E "s|^deb\s+\[arch=amd64\]\s+|deb [arch=amd64 signed-by=${keyring}] |" "$tmp_list" > "$list_file"
  else
    awk -v k="$keyring" '/^deb / && $0 !~ /signed-by=/ {sub(/^deb /,"deb [signed-by="k"] ");print;next}{print}' "$tmp_list" > "$list_file"
  fi

  rm -f "$tmp_list"
  apt-get update -y | tee -a "$LOG_FILE"
}

install_mdatp() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y mdatp | tee -a "$LOG_FILE"
  mdatp version | tee -a "$LOG_FILE" || true
  systemctl --no-pager --full status mdatp 2>/dev/null | sed -n '1,30p' | tee -a "$LOG_FILE" || true
}

run_onboarding() {
  chmod +x "$ONBOARDING_SCRIPT" || true
  python3 "$ONBOARDING_SCRIPT" | tee -a "$LOG_FILE"
}

health_checks() {
  mdatp health --field org_id | tee -a "$LOG_FILE" || true
  mdatp health --field healthy | tee -a "$LOG_FILE" || true
  mdatp health --field definitions_status | tee -a "$LOG_FILE" || true
  mdatp health --field real_time_protection_enabled | tee -a "$LOG_FILE" || true
  mdatp health | tee -a "$LOG_FILE" || true
}

eicar_test() {
  [[ "$RUN_EICAR" == "true" ]] || return 0
  curl -fsSL -o /tmp/eicar.com.txt https://www.eicar.org/download/eicar.com.txt || true
  mdatp threat list | tee -a "$LOG_FILE" || true
}

main() {
  require_root
  parse_args "$@"
  log "===== MDE onboarding START ====="
  prechecks
  install_prereqs
  setup_microsoft_repo
  install_mdatp
  run_onboarding
  health_checks
  eicar_test
  log "===== MDE onboarding COMPLETE ====="
}

main "$@"
