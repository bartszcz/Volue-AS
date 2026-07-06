#!/usr/bin/env bash
set -euo pipefail

OPTIONS:
--timezone <TZ>            Set timezone (e.g. Europe/Oslo)
--ntp "<servers>"          Set NTP servers (space-separated)
--fallback-ntp "<servers>" Set fallback NTP servers
--remove-lxc               Remove lxc-common and lxcfs
--remove-snapd             Remove snapd and hold it
--fix-floppy               Remove and blacklist floppy module
--reboot                   Reboot at end without prompt
--no-prompt                Do not prompt for reboot
-h | --help                Show help

LOG_FILE="/var/log/ubuntu-initial-setup.log"

TIMEZONE=""
NTP_SERVERS=""
FALLBACK_NTP_SERVERS=""
REMOVE_LXC="false"
REMOVE_SNAPD="false"
FIX_FLOPPY="false"
DO_REBOOT="false"
NO_PROMPT="false"

log() {
  echo "[$(date -Is)] $1" | tee -a "$LOG_FILE"
}

die() {
  log "ERROR: $1"
  exit 1
}

usage() {
  sed -n '3,14p' "$0"
}

require_root() {
  [[ "$EUID" -eq 0 ]] || die "Run as root or via sudo."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timezone) TIMEZONE="${2:-}"; shift 2 ;;
      --ntp) NTP_SERVERS="${2:-}"; shift 2 ;;
      --fallback-ntp) FALLBACK_NTP_SERVERS="${2:-}"; shift 2 ;;
      --remove-lxc) REMOVE_LXC="true"; shift ;;
      --remove-snapd) REMOVE_SNAPD="true"; shift ;;
      --fix-floppy) FIX_FLOPPY="true"; shift ;;
      --reboot) DO_REBOOT="true"; NO_PROMPT="true"; shift ;;
      --no-prompt) NO_PROMPT="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
}

apt_update_upgrade_clean() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y | tee -a "$LOG_FILE"
  apt list --upgradable 2>/dev/null | tee -a "$LOG_FILE" || true
  apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" | tee -a "$LOG_FILE"
  apt-get autoremove -y | tee -a "$LOG_FILE"
  apt-get clean -y || true
}

enable_ssh() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y openssh-server | tee -a "$LOG_FILE"
  systemctl enable --now ssh || true
  systemctl --no-pager --full status ssh | sed -n '1,25p' | tee -a "$LOG_FILE"
}

set_timezone_if_requested() {
  [[ -n "$TIMEZONE" ]] || return 0
  timedatectl set-timezone "$TIMEZONE"
  timedatectl | tee -a "$LOG_FILE"
}

configure_timesyncd_if_requested() {
  [[ -n "$NTP_SERVERS" || -n "$FALLBACK_NTP_SERVERS" ]] || return 0
  local conf="/etc/systemd/timesyncd.conf"
  cp -a "$conf" "${conf}.bak.$(date +%Y%m%d%H%M%S)"
  grep -q '^\[Time\]' "$conf" || echo "[Time]" >> "$conf"

  [[ -n "$NTP_SERVERS" ]] && \
    sed -i -E "s|^\s*#?\s*NTP=.*|NTP=$NTP_SERVERS|" "$conf" || \
    echo "NTP=$NTP_SERVERS" >> "$conf"

  [[ -n "$FALLBACK_NTP_SERVERS" ]] && \
    sed -i -E "s|^\s*#?\s*FallbackNTP=.*|FallbackNTP=$FALLBACK_NTP_SERVERS|" "$conf" || \
    echo "FallbackNTP=$FALLBACK_NTP_SERVERS" >> "$conf"

  systemctl restart systemd-timesyncd.service
  systemctl --no-pager --full status systemd-timesyncd.service | sed -n '1,25p' | tee -a "$LOG_FILE"
}

remove_unneeded_packages_if_requested() {
  export DEBIAN_FRONTEND=noninteractive
  [[ "$REMOVE_LXC" == "true" ]] && apt-get autoremove -y --purge lxc-common lxcfs || true
  if [[ "$REMOVE_SNAPD" == "true" ]]; then
    apt-get autoremove -y --purge snapd || true
    apt-mark hold snapd || true
  fi
}

fix_floppy_if_requested() {
  [[ "$FIX_FLOPPY" == "true" ]] || return 0
  rmmod floppy 2>/dev/null || true
  echo "blacklist floppy" > /etc/modprobe.d/blacklist-floppy.conf
  dpkg-reconfigure initramfs-tools | tee -a "$LOG_FILE"
}

reboot_if_needed() {
  [[ "$DO_REBOOT" == "true" ]] && shutdown -r now && return 0
  [[ "$NO_PROMPT" == "true" ]] && return 0
  [[ -f /var/run/reboot-required ]] && read -r -p "Reboot now? [y/N]: " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] && shutdown -r now
}

main() {
  require_root
  parse_args "$@"
  log "===== Ubuntu initial setup start ====="
  apt_update_upgrade_clean
  enable_ssh
  set_timezone_if_requested
  configure_timesyncd_if_requested
  remove_unneeded_packages_if_requested
  fix_floppy_if_requested
  log "===== Ubuntu initial setup complete ====="
  reboot_if_needed
}

main "$@"
