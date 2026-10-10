#!/usr/bin/env bash
# debian-to-pve.sh — turn a fresh Debian 13 (trixie) box into Proxmox VE 9, unattended (#1237,
# parent #1224). Run ON the box, as root, started by cloud-init user-data (the provider's panel,
# or the nested slot's user-data). Carries NO secret: the helper password never goes through a
# provider panel; the console one-liner (hook.sh) stays a separate, manual step afterwards.
#
# CONTRACT (env, or the same names as flags: --hostname FQDN --address IP[/PREFIX] --check)
#   DEBIAN_TO_PVE_HOSTNAME  the box's FQDN (required on first run; e.g. pve1.example.org)
#   DEBIAN_TO_PVE_ADDRESS   the public address for /etc/hosts (optional; default: the address
#                           already on the uplink card, found by the default route)
#   DEBIAN_TO_PVE_KEYRING_SHA256  override of the pinned keyring hash below (tests / rotation)
#   DEBIAN_TO_PVE_PROBE_DIR a fake root for file probes (tests only); commands come from PATH
#   --check                 run only the phase-1 assertions and exit (0 ok, 2 refused)
#
# TWO PHASES, joined by a transient resume unit (the pve-upgrade pattern: an ENABLED oneshot that
# fires every boot until the script disables it; the phase is derived from the machine, so a
# re-fire is always safe):
#   1  assert Debian 13 + no Proxmox; name + /etc/hosts; cloud-init network off; Proxmox keyring
#      + no-subscription source; full-upgrade; proxmox-default-kernel; arm resume; reboot.
#   2  (booted on the pve kernel) proxmox-ve postfix open-iscsi chrony; drop the Debian kernel
#      and os-prober; vmbr0 over the uplink; verify pveversion + :8006; disarm; marker; reboot
#      once so the bridge takes effect.
# A box that comes up wrong has nothing on it: reinstall from the panel and run again.
set -uo pipefail

ROOT="${DEBIAN_TO_PVE_PROBE_DIR:-}"
SELF_DST="${ROOT}/usr/local/sbin/provisioner-debian-to-pve"
UNIT="provisioner-debian-to-pve.service"
UNIT_FILE="${ROOT}/etc/systemd/system/${UNIT}"
STATE_DIR="${ROOT}/var/lib/provisioner/debian-to-pve"
STATE_ENV="${STATE_DIR}/env"
STATE_PHASE="${STATE_DIR}/phase"
DONE_MARK="${STATE_DIR}/done"
LOG_FILE="${ROOT}/var/log/provisioner-debian-to-pve.log"
KEYRING="${ROOT}/usr/share/keyrings/proxmox-archive-keyring.gpg"
KEYRING_URL="https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg"
# Pin of the keyring above (sha256). Empty = not yet pinned: the script refuses to trust the
# download rather than fetching unverified. Fill from a trusted fetch, as other pins here.
# Published on the Proxmox wiki (Install Proxmox VE on Debian 13 Trixie) and matched against the download, 2026-10-10 (#1237).
KEYRING_SHA256="${DEBIAN_TO_PVE_KEYRING_SHA256-136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45}"
PVE_SOURCE="${ROOT}/etc/apt/sources.list.d/proxmox-pve.sources"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
( umask 077; : >>"$LOG_FILE" ) 2>/dev/null   # log is 0600: it names the address (#1237)
log()  {   # file + console when writable, always stderr; never dies on a missing console (#1237)
  local m; m="$(printf '%s debian-to-pve: %s' "$(date -u +%FT%TZ)" "$*")"
  printf '%s\n' "$m" >>"$LOG_FILE" 2>/dev/null || true
  if [ -z "$ROOT" ] && [ -w /dev/console ]; then printf '%s\n' "$m" >/dev/console 2>/dev/null || true; fi
  printf '%s\n' "$m" >&2
}
warn() { log "WARN: $*"; }
die()  { log "REFUSED: $*"; exit "${DIE_RC:-2}"; }

# ── probes: small, stubbable ───────────────────────────────────────────────────────────────
probe_os_field() { ( . "${ROOT}/etc/os-release" 2>/dev/null && printf '%s' "${!1:-}" ); }
probe_pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed'; }
probe_running_kernel() { uname -r; }
probe_uplink() { ip -o -4 route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1; }
probe_gateway() { ip -o -4 route show default 2>/dev/null | sed -n 's/.* via \([^ ]*\).*/\1/p' | head -n1; }
probe_cidr() { ip -o -4 addr show dev "$1" scope global 2>/dev/null | awk '{print $4}' | head -n1; }
probe_addr_count() { ip -o -4 addr show dev "$1" scope global 2>/dev/null | wc -l; }
probe_dns() {  # IPv4 upstream resolvers: resolvectl if present, else resolv.conf minus loopback
  local d=""
  command -v resolvectl >/dev/null 2>&1 && d="$(resolvectl dns 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')"
  [[ -n "$d" ]] || d="$(sed -n 's/^nameserver[[:space:]]\+\([0-9.]\+\).*/\1/p' "${ROOT}/etc/resolv.conf" 2>/dev/null)"
  printf '%s\n' "$d" | grep -vE '^127\.' | awk 'NF && !s[$0]++' | tr '\n' ' ' | sed 's/ $//'
}
probe_web() { curl -ksf -o /dev/null --max-time 5 https://127.0.0.1:8006/; }

# ── phase 1 assertions (also --check) ──────────────────────────────────────────────────────
assert_debian13() {
  local id ver codename
  id="$(probe_os_field ID)"; ver="$(probe_os_field VERSION_ID)"; codename="$(probe_os_field VERSION_CODENAME)"
  [[ "$id" == debian && "$ver" == 13 && "$codename" == trixie ]] \
    || die "this is not Debian 13 (trixie): found ID='${id:-none}' VERSION_ID='${ver:-none}' VERSION_CODENAME='${codename:-none}'"
}
proxmox_found() {  # prints what it found, rc 0 if Proxmox is present
  local f=() p
  for p in proxmox-ve pve-manager; do probe_pkg_installed "$p" && f+=("package $p"); done
  [[ -e "${ROOT}/etc/pve" ]] && f+=("/etc/pve")
  ((${#f[@]})) || return 1
  printf '%s' "${f[*]}"
}
assert_no_proxmox() {
  local found; found="$(proxmox_found)" && die "Proxmox is already on this box (found: ${found}) and no phase state from this script exists"
  return 0
}

# ── interfaces file for the uplink (#1237) ─────────────────────────────────────────────────
ip2int() { local IFS=.; set -- $1; echo $(( ($1<<24)+($2<<16)+($3<<8)+$4 )); }
in_cidr() {  # <ip> <addr/prefix>
  local p=${2#*/} m; m=$(( p == 0 ? 0 : (0xFFFFFFFF << (32-p)) & 0xFFFFFFFF ))
  (( ($(ip2int "$1") & m) == ($(ip2int "${2%/*}") & m) ))
}
render_interfaces() {  # <uplink> <cidr> <gateway> <dns, space separated>
  cat <<IFACES
# written by provisioner debian-to-pve (#1237): the uplink card is enslaved to vmbr0
auto lo
iface lo inet loopback

iface $1 inet manual

auto vmbr0
iface vmbr0 inet static
	address $2
IFACES
  if in_cidr "$3" "$2"; then printf '\tgateway %s\n' "$3"
  else   # gateway outside the subnet (some providers): on-link routes instead of `gateway`
    printf '\tpost-up ip route add %s dev vmbr0\n\tpost-up ip route add default via %s dev vmbr0\n' "$3" "$3"
  fi
  cat <<IFACES
	dns-nameservers $4
	bridge-ports $1
	bridge-stp off
	bridge-fd 0

source /etc/network/interfaces.d/*
IFACES
}

render_unit() {
  cat <<UNITF
# provisioner-debian-to-pve.service (#1237): resume the Debian->Proxmox conversion after reboot.
# ENABLED, fires every boot until the script disables it; the phase is derived from the machine.
[Unit]
Description=provisioner Debian to Proxmox conversion (resume)
After=network-online.target
Wants=network-online.target
ConditionPathExists=${SELF_DST#"$ROOT"}

[Service]
Type=oneshot
RemainAfterExit=no
ExecStart=${SELF_DST#"$ROOT"}
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
UNITF
}

arm_resume() {
  mkdir -p "$(dirname "$SELF_DST")" "$(dirname "$UNIT_FILE")" || die "cannot create the resume unit's directories"
  # on a resume we ARE the installed copy: install onto itself fails, so skip (#1237)
  [[ "$SCRIPT_PATH" -ef "$SELF_DST" ]] || install -m 0755 "$SCRIPT_PATH" "$SELF_DST" || die "cannot install ${SELF_DST} from ${SCRIPT_PATH}"
  [[ -e "$UNIT_FILE" ]] || render_unit > "$UNIT_FILE" || die "cannot write ${UNIT_FILE}"
  [[ -n "$ROOT" ]] && return 0
  systemctl daemon-reload && systemctl enable "$UNIT" >/dev/null 2>&1 || die "systemctl refused to enable ${UNIT}"
}
disarm_resume() {
  [[ -z "$ROOT" ]] && { systemctl disable "$UNIT" >/dev/null 2>&1 || warn "could not disable ${UNIT}"; }
  rm -f "$UNIT_FILE" "$SELF_DST"
  [[ -z "$ROOT" ]] && systemctl daemon-reload
  return 0
}

do_reboot() { log "rebooting ($1)"; [[ -n "$ROOT" ]] || sync; [[ -n "$ROOT" ]] && return 0; systemctl reboot; sleep 60; }

real() { if [[ -n "$ROOT" ]]; then log "probe root: skipping $1"; return 0; fi; "$@"; }   # fake-root guard
apt_q() { [[ -n "$ROOT" ]] && { log "probe root: skipping apt-get $1"; return 0; }; DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef "$@" >>"$LOG_FILE" 2>&1; }

# -- grub-pc preseed (#1237) --------------------------------------------------------------
# Proxmox's grub-pc replaces the cloud image's grub-cloud-amd64 and its postinst fails with an
# empty install_devices. Preseed the disk holding /boot before any apt step that can pull it in.
probe_boot_disk() {  # parent disk of the filesystem holding /boot (or /), by-id path if one exists
  local src par dev l
  src="$(findmnt -no SOURCE --target /boot 2>/dev/null | head -n1)"
  [[ -n "$src" ]] || return 1
  par="$(lsblk -ndo PKNAME "$src" 2>/dev/null | head -n1)"
  dev="/dev/${par:-${src#/dev/}}"
  for l in /dev/disk/by-id/*; do
    [[ "$l" == *-part* || ! -e "$l" ]] && continue
    [[ "$(readlink -f "$l")" == "$(readlink -f "$dev")" ]] && { printf '%s' "$l"; return 0; }
  done
  printf '%s' "$dev"
}
render_grub_preseed() {  # <disk>
  printf 'grub-pc grub-pc/install_devices multiselect %s\ngrub-pc grub-pc/install_devices_empty boolean false\ngrub-pc grub-pc/install_devices_failed boolean false\n' "$1"
}
preseed_grub() {
  if [[ -e "${ROOT}/sys/firmware/efi" ]]; then log "EFI boot: no grub-pc preseed needed"; return 0; fi
  local d; d="$(probe_boot_disk)" || { warn "cannot find the disk holding /boot; grub-pc preseed skipped"; return 0; }
  [[ -n "$d" ]] || { warn "empty boot disk; grub-pc preseed skipped"; return 0; }
  log "grub-pc install device: ${d}"
  render_grub_preseed "$d" | real debconf-set-selections || die "debconf preseed for grub-pc failed"
}
heal_dpkg() {  # a cut or failed run leaves half-configured packages: finish them before apt
  [[ -n "$ROOT" ]] && { log "probe root: skipping dpkg --configure -a"; return 0; }
  DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold --force-confdef >>"$LOG_FILE" 2>&1 \
    || die "dpkg --configure -a failed (see ${LOG_FILE})"
}

# ── phase 1 ────────────────────────────────────────────────────────────────────────────────
phase1() {
  local host addr up
  host="${DEBIAN_TO_PVE_HOSTNAME:-}"; addr="${DEBIAN_TO_PVE_ADDRESS:-}"
  [[ "$host" == *.* && "$host" =~ ^[A-Za-z0-9.-]+$ ]] || die "DEBIAN_TO_PVE_HOSTNAME must be an FQDN of letters, digits, dots, dashes: found '${host:-unset}'"
  up="$(probe_uplink)"; [[ -n "$up" ]] || die "no default route, so no uplink card found"
  [[ -n "$addr" ]] || addr="$(probe_cidr "$up")"
  addr="${addr%%/*}"; [[ -n "$addr" ]] || die "no address given and none on uplink '${up}'"
  [[ "$addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "address is not a dotted IPv4: found '${addr}'"
  log "phase 1: ${host} / ${addr} on ${up}"

  mkdir -p "$STATE_DIR" && chmod 0700 "$STATE_DIR"
  ( umask 077; printf 'DEBIAN_TO_PVE_HOSTNAME=%q\nDEBIAN_TO_PVE_ADDRESS=%q\n' "$host" "$addr" > "$STATE_ENV" )

  # name + hosts: Proxmox needs the node name to resolve to the public address, not 127.0.1.1
  if [[ -z "$ROOT" ]]; then hostnamectl set-hostname "${host%%.*}" || die "hostnamectl failed"
  else printf '%s\n' "${host%%.*}" > "${ROOT}/etc/hostname"; fi
  sed -i '/^127\.0\.1\.1[[:space:]]/d' "${ROOT}/etc/hosts" 2>/dev/null
  sed -i "/[[:space:]]${host%%.*}\([[:space:]]\|\$\)/d" "${ROOT}/etc/hosts" 2>/dev/null
  printf '%s %s %s\n' "$addr" "$host" "${host%%.*}" >> "${ROOT}/etc/hosts"

  # cloud-init must not rewrite the network once the card is a bridge (next boot would undo it)
  mkdir -p "${ROOT}/etc/cloud/cloud.cfg.d"
  printf 'network: {config: disabled}\n' > "${ROOT}/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg"

  # keyring, pinned
  [[ -n "$KEYRING_SHA256" ]] || die "the Proxmox keyring hash is not pinned in this script (KEYRING_SHA256 empty): refusing to trust an unverified download"
  local tmp; tmp="$(mktemp)" || die "mktemp failed"
  curl -fsSL --retry 3 -o "$tmp" "$KEYRING_URL" || { rm -f "$tmp"; die "cannot download ${KEYRING_URL}"; }
  local got; got="$(sha256sum "$tmp" | cut -d' ' -f1)"
  [[ "$got" == "$KEYRING_SHA256" ]] || { rm -f "$tmp"; die "keyring sha256 mismatch: found ${got}, pinned ${KEYRING_SHA256}"; }
  mkdir -p "$(dirname "$KEYRING")"; install -m 0644 "$tmp" "$KEYRING"; rm -f "$tmp"

  mkdir -p "$(dirname "$PVE_SOURCE")"
  cat > "$PVE_SOURCE" <<SRC
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
SRC

  arm_resume
  printf 'phase2\n' > "$STATE_PHASE"   # armed BEFORE the long steps: a cut mid-apt resumes here

  [[ -z "$ROOT" ]] || { log "probe root: stopping before apt"; return 0; }
  preseed_grub
  heal_dpkg
  apt_q update || die "apt-get update failed (see ${LOG_FILE})"
  apt_q full-upgrade || die "apt-get full-upgrade failed (see ${LOG_FILE})"
  apt_q install proxmox-default-kernel || die "installing proxmox-default-kernel failed (see ${LOG_FILE})"
  do_reboot "into the Proxmox kernel"
}

# ── network (phase 2) ──────────────────────────────────────────────────────────────────────
write_network() {  # bridge over the uplink; detect from the default route, keep address + gateway
  local up cidr gw dns k tmp aside
  up="$(probe_uplink)"; [[ -n "$up" ]] || die "no default route in phase 2, cannot find the uplink card"
  [[ "$up" == vmbr0 ]] && { log "uplink is already vmbr0; leaving the network file"; return 0; }
  local n; n="$(probe_addr_count "$up")"
  (( n == 1 )) || die "uplink '${up}' has ${n} global IPv4 addresses, expected exactly 1: will not guess which one vmbr0 keeps"
  cidr="$(probe_cidr "$up")"; gw="$(probe_gateway)"
  [[ -n "$cidr" && -n "$gw" ]] || die "uplink '${up}' has address '${cidr:-none}' and gateway '${gw:-none}': cannot write vmbr0"
  dns="$(probe_dns)"; [[ -n "$dns" ]] || die "no upstream nameserver found (resolvectl, /etc/resolv.conf): vmbr0 would come up without DNS"
  aside="${STATE_DIR}/network-pre-proxmox"; mkdir -p "$aside" || die "cannot create ${aside}"
  tmp="${ROOT}/etc/network/.interfaces.provisioner.$$"
  render_interfaces "$up" "$cidr" "$gw" "$dns" > "$tmp" || { rm -f "$tmp"; die "cannot render the interfaces file"; }
  if [[ -z "$ROOT" ]] && command -v ifup >/dev/null 2>&1; then
    ifup --no-act -i "$tmp" vmbr0 >>"$LOG_FILE" 2>&1 || { rm -f "$tmp"; die "ifup --no-act rejects the generated vmbr0 file (see ${LOG_FILE})"; }
  fi
  cp -n "${ROOT}/etc/network/interfaces" "${aside}/interfaces" 2>/dev/null
  mv -f "$tmp" "${ROOT}/etc/network/interfaces" || die "cannot replace /etc/network/interfaces"
  # cloud-init's / netplan's own network files fight the bridge: move them OUT of the
  # interfaces.d glob (a renamed copy there would still be sourced)
  for k in "${ROOT}/etc/network/interfaces.d/50-cloud-init" "${ROOT}"/etc/netplan/*.yaml; do
    [[ -e "$k" ]] && mv -f "$k" "${aside}/$(basename "$k")"
  done
  if [[ -z "$ROOT" ]]; then   # best effort, no --now: the reboot applies it, a live stop could cut us off
    systemctl disable systemd-networkd systemd-networkd.socket systemd-networkd-wait-online >>"$LOG_FILE" 2>&1 || true
  fi
}

# ── phase 2 ────────────────────────────────────────────────────────────────────────────────
phase2() {
  local host addr up cidr gw k
  # shellcheck disable=SC1090
  . "$STATE_ENV" 2>/dev/null || die "phase state ${STATE_ENV} is missing or unreadable"
  host="$DEBIAN_TO_PVE_HOSTNAME"; addr="$DEBIAN_TO_PVE_ADDRESS"
  log "phase 2: kernel $(probe_running_kernel)"

  preseed_grub
  heal_dpkg
  if ! probe_pkg_installed proxmox-ve; then
    printf 'postfix postfix/main_mailer_type select Local only\npostfix postfix/mailname string %s\n' "$host" | real debconf-set-selections \
      || die "debconf preseed for postfix failed"
    apt_q update || die "apt-get update failed (see ${LOG_FILE})"
    apt_q install proxmox-ve postfix open-iscsi chrony || die "installing proxmox-ve postfix open-iscsi chrony failed (see ${LOG_FILE})"
  fi
  # the Debian kernel and os-prober (os-prober adds the other kernel to grub for nothing)
  apt_q remove linux-image-amd64 'linux-image-6.*' os-prober || warn "removing the Debian kernel / os-prober returned non-zero"
  real update-grub >>"$LOG_FILE" 2>&1 || die "update-grub failed (see ${LOG_FILE})"

  write_network || exit $?

  command -v pveversion >/dev/null 2>&1 || die "pveversion is not on PATH after installing proxmox-ve"
  log "$(pveversion 2>&1)"
  local _; for _ in $(seq 1 30); do probe_web && break; sleep 2; done
  probe_web || die "port 8006 does not answer locally after 60 s"

  disarm_resume
  : > "$DONE_MARK"
  log "DONE: Proxmox VE is installed on ${host}; rebooting once so vmbr0 takes effect, then run the console one-liner"
  do_reboot "bridge takes effect"
}

# ── dispatch ───────────────────────────────────────────────────────────────────────────────
main() {
  local check=0
  while (($#)); do case "$1" in
    --hostname) DEBIAN_TO_PVE_HOSTNAME="$2"; shift 2;;
    --address)  DEBIAN_TO_PVE_ADDRESS="$2"; shift 2;;
    --check)    check=1; shift;;
    *) die "unknown argument '$1'";;
  esac; done
  [[ -n "$ROOT" || $EUID -eq 0 ]] || die "must run as root: found uid $EUID"

  [[ -e "$DONE_MARK" ]] && { log "already converted (${DONE_MARK}); nothing to do"; exit 0; }
  assert_debian13
  if [[ -s "$STATE_PHASE" ]]; then   # we started: resume, whatever half-installed state we are in
    ((check)) && { log "check: phase state present, would resume"; exit 0; }
    case "$(probe_running_kernel)" in
      *-pve) phase2;;
      *) local tries=0 cf="${STATE_DIR}/attempts"
         [[ -s "$cf" ]] && tries="$(cat "$cf")"; tries=$((tries+1)); echo "$tries" > "$cf"
         if (( tries > 3 )); then
           local kp; kp="$(dpkg-query -W -f='${Package} ' 'proxmox-kernel-*' 2>/dev/null)"
           disarm_resume
           die "still not on the Proxmox kernel after 3 re-runs: running '$(probe_running_kernel)', installed proxmox kernels: ${kp:-none}; resume disarmed, check grub"
         fi
         log "armed but not on the Proxmox kernel yet (re-run ${tries}/3); re-running phase 1"
         # shellcheck disable=SC1090
         . "$STATE_ENV" 2>/dev/null; phase1;;
    esac
  else
    assert_no_proxmox
    ((check)) && { log "check: Debian 13, no Proxmox - ok"; exit 0; }
    phase1
  fi
}

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
