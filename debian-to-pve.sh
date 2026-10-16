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
#   --pin-hosts             re-apply the pinned /etc/hosts entry from the state dir and exit (the
#                           boot-time unit runs this before pve-cluster, #1283); skipped when the pinned
#                           address is no longer in /etc/network/interfaces (box moved, #1289)
#   --repin <fqdn> [addr]   rewrite the pin file (node rename; address defaults to the old one, #1289)
#                           (a pin from an explicit --address is never skipped as stale: it may be NAT'd)
#   --status                print DONE (exit 0) or the phase + attempt counters (exit 1)
#
# TWO PHASES, joined by a transient resume unit (the pve-upgrade pattern: an ENABLED oneshot that
# fires every boot until the script disables it; the phase is derived from the machine, so a
# re-fire is always safe):
#   1  assert Debian 13 + no Proxmox; name + /etc/hosts; cloud-init network off; Proxmox keyring
#      + no-subscription source; full-upgrade; proxmox-default-kernel; arm resume; reboot.
#   2  (booted on the pve kernel) proxmox-ve postfix open-iscsi chrony; drop the Debian kernel
#      and os-prober; vmbr0 over the uplink; verify pveversion + :8006; root keys outside
#      /etc/pve; cloud-init off; hosts-pin unit; reboot once so the bridge takes effect. The
#      resume unit STAYS armed.
#   3  (post-boot, same resume unit) pve-cluster active, /etc/pve/local, :8006, root's key file:
#      only then disarm + done marker (#1283). On failure: heal once (re-pin, restart), then
#      diagnostics to the log and ONE automatic restart; after a second failure the box stays up.
# A box that comes up wrong has nothing on it: reinstall from the panel and run again.
set -uo pipefail

ROOT="${DEBIAN_TO_PVE_PROBE_DIR:-}"
PORT_NAME=nic0   # our own name for the uplink card, pinned by MAC (#1237)
LINK_FILE="${ROOT}/etc/systemd/network/10-provisioner-uplink.link"
SELF_DST="${ROOT}/usr/local/sbin/provisioner-debian-to-pve"
UNIT="provisioner-debian-to-pve.service"
UNIT_FILE="${ROOT}/etc/systemd/system/${UNIT}"
STATE_DIR="${ROOT}/var/lib/provisioner/debian-to-pve"
STATE_ENV="${STATE_DIR}/env"
STATE_PHASE="${STATE_DIR}/phase"
DONE_MARK="${STATE_DIR}/done"
HOSTS_PIN="${STATE_DIR}/hosts-pin"   # "<address> <fqdn>", re-applied at every boot (#1283)
PIN_DST="${ROOT}/usr/local/sbin/provisioner-pin-hosts"
PIN_UNIT="provisioner-pin-hosts.service"
PIN_UNIT_FILE="${ROOT}/etc/systemd/system/${PIN_UNIT}"
SSHD_DROPIN="${ROOT}/etc/ssh/sshd_config.d/10-provisioner-root-keys.conf"
KEYS_OK="${STATE_DIR}/root-keys-verified"   # written only after sshd -T proved authorized_keys2 is read (#1283)
CI_HOSTS_CFG="${ROOT}/etc/cloud/cloud.cfg.d/zz-provisioner-hosts.cfg"   # zz-: sorts after any provider 99_x file (#1283)
CI_NET_CFG="${ROOT}/etc/cloud/cloud.cfg.d/zz-provisioner-disable-network-config.cfg"
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
probe_mac() { tr 'A-F' 'a-f' < "${ROOT}/sys/class/net/$1/address" 2>/dev/null; }
probe_cidr() { ip -o -4 addr show dev "$1" scope global 2>/dev/null | awk '{print $4}' | head -n1; }
probe_addr_count() { ip -o -4 addr show dev "$1" scope global 2>/dev/null | wc -l; }
probe_dns() {  # IPv4 upstream resolvers: resolvectl if present (never under a fake root: it answers for the REAL host), else resolv.conf minus loopback
  local d=""
  [[ -n "$ROOT" ]] || ! command -v resolvectl >/dev/null 2>&1 || d="$(resolvectl dns 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')"
  [[ -n "$d" ]] || d="$(sed -n 's/^nameserver[[:space:]]\+\([0-9.]\+\).*/\1/p' "${ROOT}/etc/resolv.conf" 2>/dev/null)"
  printf '%s\n' "$d" | grep -vE '^127\.' | awk 'NF && !s[$0]++' | tr '\n' ' ' | sed 's/ $//'
}
probe_web() { curl -ksf -o /dev/null --max-time 5 https://127.0.0.1:8006/; }
probe_cluster_active() { systemctl is-active --quiet pve-cluster; }
# Is pmxcfs mounted on /etc/pve? A bare directory is writable for root and proves nothing (#1283).
# Fake root: true, unless a test asks for the real check against the fake path.
pve_mounted() {
  [[ -n "$ROOT" && -z "${DEBIAN_TO_PVE_TEST_REAL_CHECKS:-}" ]] && return 0
  mountpoint -q "${ROOT}/etc/pve"
}

# The node name must resolve to the public address, and stay so: a provider's cloud-init with
# manage_etc_hosts rewrites /etc/hosts to 127.0.1.1 at every boot, and pve-cluster then refuses to
# start (seen live on the rented box, #1237). So the entry is written, cloud-init is told to leave
# the name and the file alone, and phase 2 writes it again in case a boot already undid it.
pin_hosts() {  # <fqdn> <address>
  local host="$1" addr="$2"
  sed -i '/^127\.0\.1\.1[[:space:]]/d' "${ROOT}/etc/hosts" 2>/dev/null
  sed -i "/[[:space:]]${host%%.*}\([[:space:]]\|\$\)/d" "${ROOT}/etc/hosts" 2>/dev/null
  printf '%s %s %s\n' "$addr" "$host" "${host%%.*}" >> "${ROOT}/etc/hosts"
  mkdir -p "${ROOT}/etc/cloud/cloud.cfg.d"
  printf 'manage_etc_hosts: false\npreserve_hostname: true\n' > "$CI_HOSTS_CFG"
}

# root's SSH keys survive Proxmox (#1237): the install points /root/.ssh/authorized_keys at
# /etc/pve/priv/authorized_keys, which starts empty, so the keys the provider put on the box were
# lost live (and with them every login). Phase 1 keeps a copy; phase 2 adds back any that is missing.
save_root_keys() {
  local f="${ROOT}/root/.ssh/authorized_keys" k="${STATE_DIR}/root-authorized_keys"
  # only usable keys: cloud-init's disabled-root stub (command="...") is non-empty but opens nothing (#1283)
  [[ -s "$f" && ! -s "$k" ]] || return 0
  ( umask 077; grep -vE '^[[:space:]]*(#|$)|(^|[ ,])command=' "$f" > "$k" ) 2>/dev/null
  [[ -s "$k" ]] || rm -f "$k"
  return 0
}
restore_root_keys() {
  local k="${STATE_DIR}/root-authorized_keys" dst="${ROOT}/root/.ssh/authorized_keys" line n=0
  [[ -s "$k" ]] || return 0
  # a write under an UNMOUNTED /etc/pve would block the mount later (#1283): rely on authorized_keys2
  pve_mounted || { warn "pmxcfs is not mounted on /etc/pve: keys not restored there; authorized_keys2 carries them (#1283)"; return 0; }
  [[ -d "${ROOT}/etc/pve/priv" ]] && dst="${ROOT}/etc/pve/priv/authorized_keys"
  mkdir -p "$(dirname "$dst")"; touch "$dst"
  while IFS= read -r line; do
    [[ -n "$line" && "$line" != \#* ]] || continue
    grep -qxF -- "$line" "$dst" 2>/dev/null || { printf '%s\n' "$line" >> "$dst"; n=$((n+1)); }
  done < "$k"
  log "root SSH keys: ${n} added back to ${dst#"$ROOT"}"
}

# A second copy of root's keys OUTSIDE /etc/pve (#1283): with pmxcfs down, /root/.ssh/authorized_keys
# dangles and root is locked out (seen live 10-12). sshd reads authorized_keys2 as well, but only
# because we say so in an explicit drop-in (it wins: first value of a keyword is kept).
keep_root_keys_outside_pve() {
  local k="${STATE_DIR}/root-authorized_keys" d="${ROOT}/root/.ssh"
  [[ -s "$k" ]] || { warn "no saved root keys: authorized_keys2 not written (#1283)"; return 0; }
  mkdir -p "$d" && chmod 0700 "$d"
  ( umask 077; cat "$k" > "${d}/authorized_keys2" ) || die "cannot write ${d}/authorized_keys2"
  mkdir -p "$(dirname "$SSHD_DROPIN")"
  printf '# provisioner debian-to-pve (#1283): root stays reachable if /etc/pve is empty\nAuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2\n' > "$SSHD_DROPIN" \
    || die "cannot write ${SSHD_DROPIN}"
  if ! real sshd -t >>"$LOG_FILE" 2>&1; then rm -f "$SSHD_DROPIN"; warn "sshd -t rejects the drop-in; removed it"; fi
  real systemctl reload ssh >>"$LOG_FILE" 2>&1 || warn "could not reload sshd"
  assert_sshd_reads_keys2
  log "root SSH keys: also in /root/.ssh/authorized_keys2, sshd drop-in written"
}
# We are still reachable here, so a drop-in sshd does not honour is refused, not trusted (#1283).
assert_sshd_reads_keys2() {
  [[ -n "$ROOT" && -z "${DEBIAN_TO_PVE_TEST_REAL_CHECKS:-}" ]] && return 0
  local t; t="$(sshd -T -C user=root,host=x,addr=127.0.0.1 2>>"$LOG_FILE")"
  log "sshd: $(grep -i '^permitrootlogin' <<<"$t" | head -n1)"
  grep -qi '^authorizedkeysfile.*authorized_keys2' <<<"$t" \
    || die "sshd does not read /root/.ssh/authorized_keys2 (sshd -T): an earlier-sorting drop-in probably out-votes ours; see $(ls "${ROOT}"/etc/ssh/sshd_config.d 2>&1 | tr '\n' ' ') in /etc/ssh/sshd_config.d (#1283)"
  grep -qiE '^permitrootlogin[[:space:]]+(yes|prohibit-pa[s]sword|without-pa[s]sword)[[:space:]]*$' <<<"$t" \
    || die "sshd does not let root in by key (permitrootlogin: $(grep -i '^permitrootlogin' <<<"$t" | head -n1)): authorized_keys2 would not help (#1283)"
  : > "$KEYS_OK"
}

# The hosts entry is re-applied at EVERY boot, before pmxcfs starts (#1283): the one-time pin was
# undone by a boot-time rewrite and pve-cluster then never came up. The unit runs a copy of this
# script (--pin-hosts) so it survives disarm_resume removing the resume copy.
render_pin_unit() {
  cat <<PUNIT
# ${PIN_UNIT} (#1283): put the node name back on its public address before pve-cluster starts.
[Unit]
Description=provisioner: pin the node name in /etc/hosts
DefaultDependencies=no
After=local-fs.target cloud-init.service
Before=pve-cluster.service
ConditionPathExists=${HOSTS_PIN#"$ROOT"}

[Service]
Type=oneshot
ExecStart=${PIN_DST#"$ROOT"} --pin-hosts

[Install]
WantedBy=multi-user.target pve-cluster.service
PUNIT
}
install_pin_unit() {  # <fqdn> <address>
  # third field = where the address came from; only a probed one may go stale on a move (#1289)
  printf '%s %s %s\n' "$2" "$1" "${DEBIAN_TO_PVE_ADDRESS_SRC:-probe}" > "$HOSTS_PIN" || die "cannot write ${HOSTS_PIN}"
  mkdir -p "$(dirname "$PIN_DST")" "$(dirname "$PIN_UNIT_FILE")"
  install -m 0755 "$SCRIPT_PATH" "$PIN_DST" || die "cannot install ${PIN_DST}"
  render_pin_unit > "$PIN_UNIT_FILE" || die "cannot write ${PIN_UNIT_FILE}"
  [[ -n "$ROOT" ]] && return 0
  systemctl daemon-reload && systemctl enable "$PIN_UNIT" >>"$LOG_FILE" 2>&1 || die "systemctl refused to enable ${PIN_UNIT}"
}

# Static `address` lines in /etc/network/interfaces (+ interfaces.d): none = DHCP/unknown, so the pin is
# honoured (#1289). Files named by `source-directory` elsewhere are not read; the conversion writes none.
pin_address_current() {  # <address>
  local lines
  lines="$(cat "${ROOT}/etc/network/interfaces" "${ROOT}"/etc/network/interfaces.d/* 2>/dev/null | awk '$1 == "address" { sub("/.*", "", $2); print $2 }')"
  [[ -z "$lines" ]] || grep -qxF "$1" <<<"$lines"
}

# `hostname` may be missing on a minimal image: fall back to /proc and uname (#1283).
cur_hostname() { if command -v hostname >/dev/null 2>&1; then hostname; else cat /proc/sys/kernel/hostname 2>/dev/null || uname -n; fi; }
set_running_hostname() {
  if command -v hostname >/dev/null 2>&1; then hostname "$1"; else printf '%s\n' "$1" > /proc/sys/kernel/hostname; fi
}
# Name and address, in the files and in the running kernel (pmxcfs reads gethostname(), #1283).
apply_name() {  # <fqdn> <address>
  pin_hosts "$1" "$2"
  printf '%s\n' "${1%%.*}" > "${ROOT}/etc/hostname"
  real set_running_hostname "${1%%.*}"
}
# Dies while the box is still up if the name would not survive the restart (#1283).
verify_name() {  # <fqdn> <address>
  local fq="$1" ad="$2" sh="${1%%.*}" h
  for h in "$fq" "$sh"; do
    # IPv4 answers only, the address anywhere among them: `getent hosts` lists the hostname
    # module's IPv6 addresses first on a real box and the old first-field read refused it (#1283)
    getent ahostsv4 "$h" 2>/dev/null | awk -v a="$ad" '$1 == a { f = 1 } END { exit !f }' \
      || die "NAME CHECK: '${h}' does not resolve to ${ad} (IPv4): pve-cluster would not start"
  done
  [[ "$(cur_hostname)" == "$sh" ]] || die "NAME CHECK: the running hostname is '$(cur_hostname)', expected '${sh}'"
  [[ "$(cat "${ROOT}/etc/hostname" 2>/dev/null)" == "$sh" ]] || die "NAME CHECK: /etc/hostname is not '${sh}'"
  ! grep -q '^127\.0\.1\.1[[:space:]]' "${ROOT}/etc/hosts" || die "NAME CHECK: /etc/hosts still has a 127.0.1.1 line"
}

# ── phase 1 assertions (also --check) ──────────────────────────────────────────────────────
assert_debian13() {
  local id ver codename
  id="$(probe_os_field ID)"; ver="$(probe_os_field VERSION_ID)"; codename="$(probe_os_field VERSION_CODENAME)"
  [[ "$id" == debian && "$ver" == 13 && "$codename" == trixie ]] \
    || die "this is not Debian 13 (trixie): found ID='${id:-none}' VERSION_ID='${ver:-none}' VERSION_CODENAME='${codename:-none}'"
}
proxmox_found() {  # prints what it found, rc 0 if Proxmox is present
  local seen=() p   # not "f": other functions use $f as a path string and newer shellcheck tracks the name script-wide (SC2128/SC2178)
  for p in proxmox-ve pve-manager; do probe_pkg_installed "$p" && seen+=("package $p"); done
  [[ -e "${ROOT}/etc/pve" ]] && seen+=("/etc/pve")
  ((${#seen[@]})) || return 1
  printf '%s' "${seen[*]}"
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
After=network-online.target pve-cluster.service pveproxy.service
Wants=network-online.target
ConditionPathExists=${SELF_DST#"$ROOT"}

[Service]
Type=oneshot
RemainAfterExit=no
ExecStart=${SELF_DST#"$ROOT"}
TimeoutStartSec=infinity

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
# No daemon-reload after the rm (#1237): we usually run INSIDE this unit's start job, and a reload
# that finds its file gone drops TimeoutStartSec=infinity, times the job out and kills us before
# the reboot is scheduled (seen live 10-10). The reboot that follows forgets the unit anyway.
disarm_resume() {
  [[ -z "$ROOT" ]] && { systemctl disable "$UNIT" >/dev/null 2>&1 || warn "could not disable ${UNIT}"; }
  rm -f "$UNIT_FILE" "$SELF_DST"
  return 0
}

# Reboot from a transient timer, detached from this process and from the resume unit (#1237): a
# `systemctl reboot` inside the unit's own start job was lost live (the start timeout killed the
# unit and the box stayed up). The timer is its own unit, so it survives ours stopping.
do_reboot() {
  log "rebooting ($1)"; [[ -n "$ROOT" ]] || sync; [[ -n "$ROOT" ]] && return 0
  systemd-run --no-block --on-active=10s --timer-property=AccuracySec=1s /bin/systemctl reboot \
    || die "could not schedule the reboot (systemd-run failed); reboot by hand"
}

real() { if [[ -n "$ROOT" ]]; then log "probe root: skipping $1"; return 0; fi; "$@"; }   # fake-root guard
apt_q() { [[ -n "$ROOT" ]] && { log "probe root: skipping apt-get $1"; return 0; }; DEBIAN_FRONTEND=noninteractive apt-get -y -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef "$@" >>"$LOG_FILE" 2>&1; }

# -- grub-pc preseed (#1237) --------------------------------------------------------------
# Proxmox's grub-pc replaces the cloud image's grub-cloud-amd64 and its postinst fails with an
# empty install_devices. Preseed the disk holding /boot before any apt step that can pull it in.
probe_boot_disk() {  # whole disk(s) under /boot (partition/LVM/md walked, #1260), by-id if one exists; ", " list
  local src disks d l out="" hit
  src="$(findmnt -no SOURCE --target "${ROOT}/boot" 2>/dev/null | head -n1)"   # fake root: its own /boot, never the host's
  [[ -n "$src" ]] || return 1
  # inverse tree, raw: every ancestor of the source, one "NAME TYPE" per line; keep the whole disks
  disks="$(lsblk -nrso NAME,TYPE "$src" 2>/dev/null | awk '$2=="disk"{print $1}' | sort -u)"
  [[ -n "$disks" ]] || disks="${src#/dev/}"
  for d in $disks; do
    hit="/dev/$d"
    for l in "${ROOT}"/dev/disk/by-id/*; do   # fake root: its own by-id tree, never the host's
      [[ "$l" == *-part* || ! -e "$l" ]] && continue
      [[ "$(readlink -f "$l")" == "$(readlink -f "${ROOT}/dev/$d")" ]] && { hit="${l#"$ROOT"}"; break; }
    done
    out+="${out:+, }${hit}"   # ", ": grub-pc's postinst splits on spaces (a bare comma failed live, #1237)
  done
  printf '%s' "$out"
}
render_grub_preseed() {  # <disk[, disk...]> (debconf's multiselect form, #1260)
  printf 'grub-pc grub-pc/install_devices multiselect %s\ngrub-pc grub-pc/install_devices_empty boolean false\ngrub-pc grub-pc/install_devices_failed boolean false\n' "$1"
}
bios_capable() {  # <disk> -> 0 if grub can embed there: an MBR disk, or a GPT disk with a BIOS boot partition (#1317)
  local j; j="$(sfdisk --json "$1" 2>/dev/null)" || return 0   # unreadable: keep it, let grub-install judge
  grep -qi '"label": *"gpt"' <<<"$j" || return 0
  grep -qi '21686148-6449-6E6F-744E-656564454649' <<<"$j"
}
limit_grub_disks() {  # <disk[, disk...]> -> the subset able to hold the loader; refuses if none (#1317)
  local d keep="" drop=""
  for d in ${1//,/ }; do
    if bios_capable "$d"; then keep+="${keep:+, }${d}"; else drop+="${drop:+, }${d}"; fi
  done
  [[ -n "$keep" ]] || die "no disk carries a BIOS boot partition (${drop}): grub-pc cannot install on a GPT disk without one; add the 1 MiB 'legacy' partition at the provider"
  [[ -z "$drop" ]] || log "grub-pc: dropping ${drop} from the install devices: GPT disk with no BIOS boot partition, grub-install would fail on it (#1317)"
  printf '%s' "$keep"
}
preseed_grub() {
  if [[ -e "${ROOT}/sys/firmware/efi" ]]; then log "EFI boot: no grub-pc preseed needed"; return 0; fi
  local d; d="$(probe_boot_disk)" || { warn "cannot find the disk holding /boot; grub-pc preseed skipped"; return 0; }
  [[ -n "$d" ]] || { warn "empty boot disk; grub-pc preseed skipped"; return 0; }
  d="$(limit_grub_disks "$d")" || exit $?   # a subshell's die must still stop us (#1317)
  log "grub-pc install device: ${d}"
  render_grub_preseed "$d" | real debconf-set-selections || die "debconf preseed for grub-pc failed"
}
# Background apt must not hold the dpkg lock under us (#1283; cf. quiesce_apt in the pve-upgrade unit).
quiesce_apt() {
  local u
  log "quiesce apt: timers and unattended-upgrades off"
  for u in apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service unattended-upgrades.service; do
    real systemctl disable --now "$u" >>"$LOG_FILE" 2>&1 || true
  done
}
heal_dpkg() {  # a cut or failed run leaves half-configured packages: finish them before apt
  [[ -n "$ROOT" ]] && { log "probe root: skipping dpkg --configure -a"; return 0; }
  DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold --force-confdef >>"$LOG_FILE" 2>&1 \
    || die "dpkg --configure -a failed (see ${LOG_FILE})"
}

# Prove the box can boot before each reboot (#1283): the pve kernel's initramfs must carry the md
# driver when / or /boot sit on an array, mdadm.conf must name it, grub must offer the kernel.
verify_bootable() {
  local kv img lst md=0
  kv="$(ls -1 "${ROOT}"/boot/vmlinuz-*-pve 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -n1)"
  [[ -n "$kv" ]] || die "BOOT CHECK: no Proxmox kernel (vmlinuz-*-pve) in /boot: will not reboot"
  grep -q '^md[0-9]' "${ROOT}/proc/mdstat" 2>/dev/null && md=1
  if ((md)); then
    img="${ROOT}/boot/initrd.img-${kv}"
    [[ -e "$img" ]] || die "BOOT CHECK: ${img#"$ROOT"} is missing"
    # listing to a file first: `lsinitramfs | grep -q` fails under pipefail once grep quits early (seen live)
    lst="$(mktemp)" || die "mktemp failed"
    lsinitramfs "$img" >"$lst" 2>/dev/null
    grep -Eq 'mdadm|raid1|md_mod' "$lst" \
      || { rm -f "$lst"; die "BOOT CHECK: the initramfs of ${kv} has no mdadm/raid driver but / sits on an md array: it would not boot"; }
    grep -q '^ARRAY' "${ROOT}/etc/mdadm/mdadm.conf" 2>/dev/null \
      || warn "BOOT CHECK: /etc/mdadm/mdadm.conf has no ARRAY line (initramfs carries etc/mdadm/mdadm.conf: $(grep -c 'etc/mdadm/mdadm.conf' "$lst")); the initramfs hook normally generates it"
    rm -f "$lst"
  fi
  grep -q 'vmlinuz-.*-pve' "${ROOT}/boot/grub/grub.cfg" 2>/dev/null \
    || die "BOOT CHECK: /boot/grub/grub.cfg does not mention the Proxmox kernel (vmlinuz-*-pve)"
  grep -q 'libata\.force=nolpm' "${ROOT}/boot/grub/grub.cfg" 2>/dev/null \
    || die "BOOT CHECK: /boot/grub/grub.cfg lacks libata.force=nolpm (the SATA link power pin of #1325 did not reach the boot entries)"
  log "boot check ok: ${kv}$( ((md)) && echo ', md array in initramfs + mdadm.conf')"
}
# Facts for a freeze we may not be able to read afterwards (#1283): into the 0600 log.
box_facts() {
  local f
  {
    for f in proc/mdstat proc/cmdline etc/fstab etc/default/grub; do echo "--- /$f"; cat "${ROOT}/$f" 2>&1; done
    echo "--- /etc/default/grub.d/*"; cat "${ROOT}"/etc/default/grub.d/* 2>&1
    echo "--- cloud-init hosts/hostname settings"
    grep -rn 'manage_etc_hosts\|preserve_hostname' "${ROOT}/etc/cloud" "${ROOT}/var/lib/cloud/instance" 2>/dev/null
    echo "--- ls udev rules, interfaces.d"; ls -la "${ROOT}/etc/udev/rules.d" "${ROOT}/etc/network/interfaces.d" 2>&1
    if [[ -z "$ROOT" ]]; then
      echo "--- lsblk -f"; lsblk -f 2>&1
      echo "--- mdadm --detail --scan"; mdadm --detail --scan 2>&1
      echo "--- scw/cloud units"; systemctl list-unit-files 2>&1 | grep -iE 'scw|scaleway|cloud'
    fi
  } >>"$LOG_FILE" 2>&1
  return 0
}

# The box recipe (#1310): the cloud-init user-data this box started from and its disk layout, kept
# in the state folder BEFORE anything changes (the provider never gives either back). The
# user-data can carry a hash or a token, so 0600 root. Never fails the conversion; a re-run that
# finds the files leaves them.
save_box_recipe() {
  local ci="${STATE_DIR}/cloud-init.user-data" dl="${STATE_DIR}/disk-layout.json" src="" f
  if [[ -s $ci ]]; then log "box recipe: cloud-init copy already kept"
  else
    for f in "${ROOT}/var/lib/cloud/instance/user-data.txt" $(ls -t "${ROOT}"/var/lib/cloud/instances/*/user-data.txt 2>/dev/null); do
      [[ -s $f ]] && { src="$f"; break; }
    done
    if [[ -n $src ]] && ( umask 077; cp "$src" "$ci" ) 2>/dev/null; then chmod 0600 "$ci"; log "box recipe: kept the cloud-init user-data"
    else rm -f "$ci"; warn "box recipe: no cloud-init user-data copy found, skipped"; fi
  fi
  if [[ -s $dl ]]; then log "box recipe: disk layout already kept"; return 0; fi
  if ! command -v python3 >/dev/null 2>&1; then warn "box recipe: no python3, disk layout skipped"; return 0; fi
  ( umask 077; ROOT="$ROOT" python3 - "$dl" <<'PY'
import json, os, subprocess, sys, datetime
root = os.environ.get("ROOT", "")
def run(*a):
    try:
        return subprocess.run(a, capture_output=True, text=True, timeout=60).stdout
    except Exception:
        return ""
def rd(p):
    try:
        return open(root + p, errors="replace").read()
    except Exception:
        return ""
try:
    lsblk = json.loads(run("lsblk", "-J", "-o", "NAME,KNAME,TYPE,SIZE,FSTYPE,LABEL,MOUNTPOINT,PARTTYPE,PARTLABEL,PARTUUID,MODEL,SERIAL") or "{}")
except Exception:
    lsblk = {}
sfdisk = {}
for d in lsblk.get("blockdevices", []):
    if d.get("type") == "disk":
        t = run("sfdisk", "-d", "/dev/" + d["name"])
        if t:
            sfdisk[d["name"]] = t
doc = {"lsblk": lsblk, "sfdisk": sfdisk, "mdadm": run("mdadm", "--detail", "--scan"),
       "mdstat": rd("/proc/mdstat"), "fstab": rd("/etc/fstab"),
       "taken_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
       "hostname": run("hostname").strip()}
with open(sys.argv[1] + ".tmp", "w") as fh:
    json.dump(doc, fh, indent=1)
os.replace(sys.argv[1] + ".tmp", sys.argv[1])
PY
  ) 2>>"$LOG_FILE" && log "box recipe: kept the disk layout" || { rm -f "$dl" "$dl.tmp"; warn "box recipe: disk layout could not be written, skipped"; }
  return 0
}

# The Proxmox kernel defaults SATA links to min_power_with_partial, which drops some SSDs (#1325).
# A udev rule applies only after the ports are up, too late: the kernel command line pins it from first boot.
SATA_LPM_GRUB="${ROOT}/etc/default/grub.d/98-provisioner-sata-lpm.cfg"
SATA_LPM_PARAMS="libata.force=nolpm ahci.mobile_lpm_policy=1"
SATA_LPM_RULE="${ROOT}/etc/udev/rules.d/99-provisioner-sata-lpm.rules"
pin_sata_lpm() {  # udev rule for every boot + the live write now; hosts without the attribute are skipped
  mkdir -p "$(dirname "$SATA_LPM_RULE")"
  printf '%s\n%s\n' '# SATA links stay at full power: the Proxmox kernel default drops some SSDs (#1325)' \
    'ACTION=="add", SUBSYSTEM=="scsi_host", KERNEL=="host*", ATTR{link_power_management_policy}="max_performance"' > "$SATA_LPM_RULE"
  local f set=""
  for f in "${ROOT}"/sys/class/scsi_host/host*/link_power_management_policy; do
    [[ -e "$f" ]] || continue
    if printf 'max_performance' > "$f" 2>/dev/null; then set+=" $(basename "$(dirname "$f")")"; fi
  done
  log "SATA link power policy: max_performance written for:${set:- no SATA host}"
  # GRUB_CMDLINE_LINUX, not _DEFAULT (cloud-init sets that wholesale); a rewritten file keeps one copy (#1325)
  mkdir -p "$(dirname "$SATA_LPM_GRUB")"
  printf '%s\n%s\n' '# SATA link power management off from the first boot of the Proxmox kernel (#1325)' \
    "GRUB_CMDLINE_LINUX=\"\$GRUB_CMDLINE_LINUX ${SATA_LPM_PARAMS}\"" > "$SATA_LPM_GRUB" \
    || die "cannot write ${SATA_LPM_GRUB}"
  log "SATA link power: kernel command line pinned (${SATA_LPM_PARAMS}) in ${SATA_LPM_GRUB#"$ROOT"}, applied by update-grub"
}
sata_lpm_failures() {  # one phrase per SATA host not on max_performance
  local f v
  for f in "${ROOT}"/sys/class/scsi_host/host*/link_power_management_policy; do
    [[ -e "$f" ]] || continue
    v="$(cat "$f" 2>/dev/null)"
    [[ "$v" == max_performance ]] || echo "SATA $(basename "$(dirname "$f")") link power policy is '${v}', not max_performance"
  done
  local p cl; cl="$(cat "${ROOT}/proc/cmdline" 2>/dev/null)"
  for p in $SATA_LPM_PARAMS; do
    [[ " $cl " == *" $p "* ]] || echo "the running kernel's command line lacks ${p} (SATA link power pin, #1325)"
  done
}
md_degraded_warn() {  # a mirror that lost a member shows an underscore inside [UU] (#1325); a warning, not a failure
  [[ -r "${ROOT}/proc/mdstat" ]] || return 0
  local a n
  a="$(awk '/^md[0-9]+ :/ {n=$1} /\[[0-9]+\/[0-9]+\] \[[U_]*_[U_]*\]/ {print n}' "${ROOT}/proc/mdstat")"
  for n in $a; do dwarn "md mirror ${n} is DEGRADED (a member is missing, see ${ROOT}/proc/mdstat): the box boots but is not redundant"; done
}

# ── disk record (#1325): what the box sees of its disks, so a lost disk leaves evidence ────────
# Written in phase 1 (Debian kernel) and again at the first Proxmox-kernel boot, appended with a
# UTC stamp. Warnings only, never a refusal: a worn but serving disk must not stop a conversion.
DISK_REC="${STATE_DIR}/disks.txt"
DISK_WARNS=0
SMARTCTL="${DEBIAN_TO_PVE_SMARTCTL:-smartctl}"
dwarn() { DISK_WARNS=$((DISK_WARNS+1)); warn "$*"; }
drec()  { printf '%s\n' "$*" >> "$DISK_REC"; log "disk: $*"; }
DISK_TMO="${DEBIAN_TO_PVE_DISK_TIMEOUT:-30}"   # a hung disk is the case this record exists for (#1325)
tmo() {  # <tool label> <disk> cmd... -> output in $TMO_OUT; a timeout is a WARN, never a stall
  local lbl="$1" d="$2"; shift 2
  TMO_OUT="$(timeout -k 2 "$DISK_TMO" "$@" 2>&1)"; local rc=$?
  (( rc != 124 )) || dwarn "${lbl} timed out on ${d}"
  return $rc
}
KLOG_LINES=20000   # an ATA error storm must not blow up memory or time (#1325)
kernel_log() {  # <file>: the last KLOG_LINES lines (and at most ~4 MB) of this boot's kernel log
  local f="$1" rc
  timeout -k 2 "$DISK_TMO" journalctl -k -b --no-pager -q 2>/dev/null | tail -n "$KLOG_LINES" | tail -c 4000000 > "$f"
  rc=${PIPESTATUS[0]}; (( rc != 124 )) || dwarn "journalctl timed out on the kernel log"
  [[ -s "$f" ]] && return 0
  timeout -k 2 "$DISK_TMO" dmesg 2>/dev/null | tail -n "$KLOG_LINES" | tail -c 4000000 > "$f"
  rc=${PIPESTATUS[0]}; (( rc != 124 )) || dwarn "dmesg timed out on the kernel log"
}
smart_raw() {  # <attribute name> <smartctl text> -> raw value (first word), empty if absent
  awk -v n="$1" '$2==n {print $10; exit}' <<<"$2"
}
smart_disk() {  # <disk>
  local d="$1" t a v
  tmo smartctl "$d" "$SMARTCTL" -H -A "/dev/$d"; t="$TMO_OUT"
  v="$(sed -n 's/^SMART overall-health self-assessment test result: *//p' <<<"$t" | head -n1)"
  drec "${d} smart health: ${v:-unknown}"
  [[ -z "$v" || "$v" == PASSED ]] || dwarn "disk ${d}: SMART overall health is ${v}, not PASSED"
  for a in Reallocated_Event_Count Reallocated_Sector_Ct Current_Pending_Sector Offline_Uncorrectable UDMA_CRC_Error_Count Percent_Lifetime_Remain Power_On_Hours Unexpect_Power_Loss_Ct; do
    v="$(smart_raw "$a" "$t")"; [[ -n "$v" ]] || continue
    if [[ $a == Percent_Lifetime_Remain ]]; then drec "${d} ${a} raw=${v} (on Micron drives the raw value is the percent USED)"
    else drec "${d} ${a} raw=${v}"; fi
    [[ "$v" =~ ^[0-9]+$ ]] || continue
    case "$a" in
      Reallocated_*|Current_Pending_Sector|Offline_Uncorrectable) (( v > 0 )) && dwarn "disk ${d}: ${a} is ${v}, the disk has bad sectors" ;;
      UDMA_CRC_Error_Count) (( v > 0 )) && dwarn "disk ${d}: ${a} is ${v}, the cable or link has dropped data" ;;
      Percent_Lifetime_Remain) (( v >= 90 )) && dwarn "disk ${d}: ${v} percent of its rated lifetime is used" ;;
    esac
  done
}
wcache_disk() {  # <disk> -> write cache on/off/unknown, warned when off
  local d="$1" o st=unknown
  tmo hdparm "$d" hdparm -W "/dev/$d"; o="$TMO_OUT"
  if grep -qiE 'write-caching *= *0|\(off\)' <<<"$o"; then st=off
  elif grep -qiE 'write-caching *= *1|\(on\)' <<<"$o"; then st=on
  elif command -v "$SMARTCTL" >/dev/null 2>&1; then
    tmo smartctl "$d" "$SMARTCTL" -g wcache "/dev/$d"; o="$TMO_OUT"
    if grep -qi 'write cache is: *disabled' <<<"$o"; then st=off; elif grep -qi 'write cache is: *enabled' <<<"$o"; then st=on; fi
  fi
  drec "${d} write cache: ${st}"
  [[ "$st" != off ]] || dwarn "disk ${d}: the write cache is off"
}
ata_trouble() {  # <whole-disk names...>: counts the kernel's ATA complaints since boot, per pattern and per disk
  local kl p n d dl list="" ata
  kl="$(mktemp)" || return 0; kernel_log "$kl"
  for p in 'failed command' 'SError' 'CommWake' 'failed to IDENTIFY' 'Disk failure on' 'kicking non-fresh'; do
    n="$(grep -c -- "$p" "$kl")"; [[ "$n" =~ ^[0-9]+$ ]] || n=0
    list=""
    if (( n > 0 )); then
      for d in "$@"; do
        ata="$(readlink -m "${ROOT}/sys/block/${d}" 2>/dev/null | grep -o '/ata[0-9]*/' | head -n1 | tr -d /)"
        dl="$(grep -- "$p" "$kl" | grep -cE "(^|[^a-z0-9])${d}[0-9]*([^a-z0-9]|$)${ata:+|(^|[^a-z0-9])${ata}[.:]}")"
        (( dl > 0 )) && list+=" ${d}=${dl}"
      done
    fi
    drec "kernel log since boot: '${p}' lines: ${n}${list:+ (by disk:${list})}"
    (( n == 0 )) || dwarn "the kernel log has ${n} '${p}' line(s) since boot${list:+ (by disk:${list})}"
  done
  rm -f "$kl"
}
disk_record() {  # <phase1|post-boot>
  local ph="$1" d rest list=""
  if [[ -n "$ROOT" && "${DEBIAN_TO_PVE_DISK_RECORD:-}" != 1 ]]; then log "probe root: skipping the disk record"; return 0; fi
  mkdir -p "$STATE_DIR"; ( umask 077; : >>"$DISK_REC" )
  DISK_WARNS=0
  drec "== $(date -u +%FT%TZ) ${ph} kernel $(probe_running_kernel) =="
  if [[ "$ph" == phase1 ]] && ! command -v "$SMARTCTL" >/dev/null 2>&1; then
    # the box has egress now; a failed install only costs the SMART half of the record
    apt_q update && apt_q install smartmontools || log "disk record: smartmontools could not be installed, SMART skipped"
  fi
  while read -r d rest; do
    [[ -n "$d" ]] || continue
    drec "disk ${d} size/model/serial/rota: ${rest}"; list+=" $d"
  done < <(lsblk -d -n -e 1,7,11 -o NAME,SIZE,MODEL,SERIAL,ROTA 2>/dev/null)
  [[ -n "$list" ]] || drec "no whole disk listed by lsblk"
  if command -v "$SMARTCTL" >/dev/null 2>&1; then
    for d in $list; do smart_disk "$d"; done
  else drec "smartctl not available: SMART attributes skipped"; fi
  if command -v hdparm >/dev/null 2>&1 || command -v "$SMARTCTL" >/dev/null 2>&1; then
    for d in $list; do wcache_disk "$d"; done
  else drec "neither hdparm nor smartctl available: write cache state skipped"; fi
  # shellcheck disable=SC2086
  ata_trouble $list
  md_degraded_warn
  drec "disk record (${ph}): ${DISK_WARNS} warnings"
}

# ── phase 1 ────────────────────────────────────────────────────────────────────────────────
phase1() {
  local host addr up
  host="${DEBIAN_TO_PVE_HOSTNAME:-}"; addr="${DEBIAN_TO_PVE_ADDRESS:-}"
  local src=override; [[ -n "$addr" ]] || src=probe   # an explicit address may be NAT'd, not on the NIC (#1289)
  [[ "$host" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9-]+)+$ ]] \
    || die "DEBIAN_TO_PVE_HOSTNAME must be a lowercase FQDN of letters, digits, dots, dashes, not starting with a dash or dot (Proxmox node names are lowercase): found '${host:-unset}'"
  up="$(probe_uplink)"; [[ -n "$up" ]] || die "no default route, so no uplink card found"
  [[ -n "$addr" ]] || addr="$(probe_cidr "$up")"
  addr="${addr%%/*}"; [[ -n "$addr" ]] || die "no address given and none on uplink '${up}'"
  [[ "$addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "address is not a dotted IPv4: found '${addr}'"
  log "phase 1: ${host} / ${addr} on ${up}"
  quiesce_apt
  box_facts
  # fail now what phase 2 would fail on after the upgrade (#1283)
  [[ "$up" == vmbr0 ]] || preflight_uplink "$up"

  mkdir -p "$STATE_DIR" && chmod 0700 "$STATE_DIR"
  save_box_recipe   # before anything changes (#1310)
  save_root_keys
  if [[ ! -s "${STATE_DIR}/root-authorized_keys" && "${DEBIAN_TO_PVE_ALLOW_NO_ROOT_KEY:-}" != 1 ]]; then
    die "no usable key in /root/.ssh/authorized_keys (blank, comments and command= lines do not count): root would have no way in after Proxmox replaces that file (#1283); add one, or set DEBIAN_TO_PVE_ALLOW_NO_ROOT_KEY=1 to go on anyway"
  fi
  keep_root_keys_outside_pve
  mkdir -p "${ROOT}/var/log/journal"; real systemd-tmpfiles --create --prefix /var/log/journal >>"$LOG_FILE" 2>&1 || true   # a freeze leaves a readable journal
  ( umask 077; printf 'DEBIAN_TO_PVE_HOSTNAME=%q\nDEBIAN_TO_PVE_ADDRESS=%q\nDEBIAN_TO_PVE_ADDRESS_SRC=%q\n' "$host" "$addr" "$src" > "$STATE_ENV"
    [[ -z "${DEBIAN_TO_PVE_ALLOW_NO_ROOT_KEY:-}" ]] || printf 'DEBIAN_TO_PVE_ALLOW_NO_ROOT_KEY=%q\n' "$DEBIAN_TO_PVE_ALLOW_NO_ROOT_KEY" >> "$STATE_ENV" )

  # name + hosts: Proxmox needs the node name to resolve to the public address, not 127.0.1.1
  # A minimal Debian has no D-Bus, so hostnamectl cannot work there (#1260): set the name directly.
  if [[ -z "$ROOT" ]]; then
    hostnamectl set-hostname "${host%%.*}" 2>/dev/null \
      || { printf '%s\n' "${host%%.*}" > /etc/hostname && set_running_hostname "${host%%.*}"; } || die "cannot set the hostname"
  else printf '%s\n' "${host%%.*}" > "${ROOT}/etc/hostname"; fi
  pin_hosts "$host" "$addr"

  # cloud-init must not rewrite the network once the card is a bridge (next boot would undo it)
  mkdir -p "${ROOT}/etc/cloud/cloud.cfg.d"
  printf 'network: {config: disabled}\n' > "$CI_NET_CFG"
  pin_sata_lpm   # before the Proxmox kernel is installed (#1325)
  disk_record phase1   # Debian kernel's view of the disks, before anything is installed (#1325)

  # keyring, pinned
  [[ -n "$KEYRING_SHA256" ]] || die "the Proxmox keyring hash is not pinned in this script (KEYRING_SHA256 empty): refusing to trust an unverified download"
  local tmp; tmp="$(mktemp)" || die "mktemp failed"
  command -v curl >/dev/null 2>&1 || { rm -f "$tmp"; die "curl is missing: cannot download ${KEYRING_URL}"; }
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
  verify_bootable
  do_reboot "into the Proxmox kernel"
}

# ── network (phase 2) ──────────────────────────────────────────────────────────────────────
# ifupdown2 keeps its lock in /run/network; the cloud image never ran networking.service,
# so the dir is missing and even `ifup --no-act` dies "Another instance ... running" (#1237)
ensure_run_network() { mkdir -p "${ROOT}/run/network" || die "cannot create /run/network"; }

# Everything write_network will need, checked up front: phase 1 runs it too, so a box that
# phase 2 would refuse is refused before the 30-minute upgrade (#1283). Sets PF_*.
preflight_uplink() {  # <uplink>
  local up="$1" n
  n="$(probe_addr_count "$up")"
  (( n == 1 )) || die "uplink '${up}' has ${n} global IPv4 addresses, expected exactly 1: will not guess which one vmbr0 keeps"
  PF_CIDR="$(probe_cidr "$up")"; PF_GW="$(probe_gateway)"
  [[ -n "$PF_CIDR" && -n "$PF_GW" ]] || die "uplink '${up}' has address '${PF_CIDR:-none}' and gateway '${PF_GW:-none}': cannot write vmbr0"
  PF_DNS="$(probe_dns)"; [[ -n "$PF_DNS" ]] || die "no upstream nameserver found (resolvectl, /etc/resolv.conf): vmbr0 would come up without DNS"
  # the card's name is not stable across the reboot (eth0 -> ens18 seen live): pin it by MAC
  # to a name of our own and bind the bridge to that (#1237)
  PF_MAC="$(probe_mac "$up")"; [[ "$PF_MAC" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || die "cannot read a MAC address for '${up}': found '${PF_MAC:-none}'"
}

write_network() {  # bridge over the uplink; detect from the default route, keep address + gateway
  local up cidr gw dns k tmp aside mac
  up="$(probe_uplink)"; [[ -n "$up" ]] || die "no default route in phase 2, cannot find the uplink card"
  [[ "$up" == vmbr0 ]] && { log "uplink is already vmbr0; leaving the network file"; return 0; }
  preflight_uplink "$up"; cidr="$PF_CIDR"; gw="$PF_GW"; dns="$PF_DNS"; mac="$PF_MAC"
  aside="${STATE_DIR}/network-pre-proxmox"; mkdir -p "$aside" || die "cannot create ${aside}"
  tmp="${ROOT}/etc/network/.interfaces.provisioner.$$"
  if [[ -z "$ROOT" ]] && command -v ifup >/dev/null 2>&1; then
    # dry run with the name that exists NOW; the pinned name only exists after the reboot
    render_interfaces "$up" "$cidr" "$gw" "$dns" > "$tmp" || { rm -f "$tmp"; die "cannot render the interfaces file"; }
    ensure_run_network
    ifup --no-act -i "$tmp" vmbr0 >>"$LOG_FILE" 2>&1 || { rm -f "$tmp"; die "ifup --no-act rejects the generated vmbr0 file (see ${LOG_FILE})"; }
  fi
  render_interfaces "$PORT_NAME" "$cidr" "$gw" "$dns" > "$tmp" || { rm -f "$tmp"; die "cannot render the interfaces file"; }
  mkdir -p "$(dirname "$LINK_FILE")"
  printf '[Match]\nMACAddress=%s\nType=ether\n\n[Link]\nName=%s\n' "$mac" "$PORT_NAME" > "$LINK_FILE" || die "cannot write ${LINK_FILE}"
  cp -n "${ROOT}/etc/network/interfaces" "${aside}/interfaces" 2>/dev/null
  mv -f "$tmp" "${ROOT}/etc/network/interfaces" || die "cannot replace /etc/network/interfaces"
  # a pending-changes file would be applied over ours by the Proxmox GUI / ifupdown2
  [[ -e "${ROOT}/etc/network/interfaces.new" ]] && mv -f "${ROOT}/etc/network/interfaces.new" "${aside}/interfaces.new"
  # cloud-init's / netplan's / networkd's own network files fight the bridge: move them OUT of
  # the interfaces.d glob (a renamed copy there would still be sourced)
  mkdir -p "${ROOT}/etc/cloud/cloud.cfg.d"
  printf 'network: {config: disabled}\n' > "$CI_NET_CFG"
  # Every interfaces.d file goes, and any udev rule naming our MAC (it could pre-empt the rename);
  # the .link above matches Type=ether so vmbr0, which has the same MAC, is not renamed (#1283).
  for k in "${ROOT}"/etc/network/interfaces.d/* "${ROOT}"/etc/netplan/*.yaml "${ROOT}"/etc/systemd/network/*.network; do
    [[ -f "$k" || -L "$k" ]] && mv -f "$k" "${aside}/$(basename "$k")"
  done
  for k in "${ROOT}"/etc/systemd/network/*.link; do   # a provider .link naming the MAC that sorts before ours would win
    [[ -f "$k" && "$k" != "$LINK_FILE" && "$(basename "$k")" < "$(basename "$LINK_FILE")" ]] && grep -qi -- "$mac" "$k" \
      && { mv -f "$k" "${aside}/$(basename "$k")" && log "link file naming the uplink MAC moved aside: $(basename "$k")"; }
  done
  for k in "${ROOT}"/etc/udev/rules.d/*.rules; do
    [[ -f "$k" ]] && grep -qi -- "$mac" "$k" && { mv -f "$k" "${aside}/$(basename "$k")" && log "udev rule naming the uplink MAC moved aside: $(basename "$k")"; }
  done
  if [[ -z "$ROOT" ]]; then   # best effort, no --now: the reboot applies it, a live stop could cut us off
    systemctl disable systemd-networkd systemd-networkd.socket systemd-networkd-wait-online >>"$LOG_FILE" 2>&1 || true
    systemctl enable networking >>"$LOG_FILE" 2>&1 || warn "could not enable networking.service (#1237): vmbr0 may not come up on reboot"
  fi
  write_resolv "$dns"
  verify_network "$cidr" "$gw" "$mac"
}

# ifupdown2's dns-nameservers needs resolvconf, which is absent, and networkd is off, so
# systemd-resolved would have no upstream: stub-only DNS, nothing resolves (#1237). Proxmox
# manages a plain /etc/resolv.conf: write it from the upstreams probed BEFORE this point.
write_resolv() {  # <dns, space separated>
  local f="${ROOT}/etc/resolv.conf" dom="" n tmp
  [[ -n "${DEBIAN_TO_PVE_HOSTNAME:-}" ]] && dom="${DEBIAN_TO_PVE_HOSTNAME#*.}"
  tmp="${f}.provisioner.$$"
  { [[ -n "$dom" ]] && printf 'search %s\n' "$dom"; for n in $1; do printf 'nameserver %s\n' "$n"; done; } > "$tmp" \
    || { rm -f "$tmp"; die "cannot write ${tmp}"; }
  chmod 0644 "$tmp"; rm -f "$f"; mv -f "$tmp" "$f" || die "cannot replace /etc/resolv.conf"
  if [[ -z "$ROOT" ]]; then   # best effort: with no upstream it only shadows the plain file
    systemctl disable --now systemd-resolved >>"$LOG_FILE" 2>&1 || true
    systemctl mask systemd-resolved >>"$LOG_FILE" 2>&1 || true
  fi
}

# proxmox-ve ships the enterprise sources enabled; with no subscription they 401 and every
# apt-get update fails (#1237). Move them aside (deb822 or legacy), keep our no-subscription one.
disable_enterprise_sources() {
  local d="${ROOT}/etc/apt/sources.list.d" aside="${STATE_DIR}/apt-pre-enterprise" k
  mkdir -p "$aside" || die "cannot create ${aside}"
  for k in "$d"/*.sources "$d"/*.list; do
    [[ -f "$k" ]] && grep -q 'enterprise\.proxmox\.com' "$k" && { mv -f "$k" "${aside}/$(basename "$k")" || die "cannot move ${k} aside"; log "enterprise source moved aside: $(basename "$k")"; }
  done
  [[ -f "${ROOT}/etc/apt/sources.list" ]] && sed -i '/enterprise\.proxmox\.com/s/^[^#]/#&/' "${ROOT}/etc/apt/sources.list"
  return 0
}

# apt must be clean before the reboot (#1237): no enterprise source left, update exits 0.
verify_apt() {
  local k
  for k in "${ROOT}"/etc/apt/sources.list.d/*.sources "${ROOT}"/etc/apt/sources.list.d/*.list "${ROOT}/etc/apt/sources.list"; do
    [[ -f "$k" ]] && grep -v '^[[:space:]]*#' "$k" | grep -q 'enterprise\.proxmox\.com' && die "APT CHECK: ${k} still names enterprise.proxmox.com"
  done
  apt_q update || die "APT CHECK: apt-get update fails after the enterprise sources were disabled (see ${LOG_FILE})"
}

# A Proxmox ISO install writes /etc/pve/storage.cfg; the apt install serves an implicit `local`
# in memory and writes nothing, so host-prep abstains and no data disk becomes vmdata (#1237).
# Write the ISO default for a dir-only root: pvesm first (goes through the cluster fs), else the file.
# It carries images: the cold start's pre-flight needs a VM-disk storage before host-prep builds vmdata.
ensure_storage_cfg() {
  local d="${ROOT}/etc/pve" f="${ROOT}/etc/pve/storage.cfg" _
  for _ in $(seq 1 30); do pve_mounted && [[ -w "$d" ]] && break; sleep 2; done
  pve_mounted && [[ -w "$d" ]] || die "/etc/pve is not mounted and writable after 60 s: pve-cluster is not up"
  [[ -e "$f" ]] && return 0
  real pvesm set local --content iso,vztmpl,backup,images,rootdir >>"$LOG_FILE" 2>&1
  if [[ ! -e "$f" ]]; then
    warn "pvesm did not write ${f}; writing the ISO default directly"
    printf 'dir: local\n\tpath /var/lib/vz\n\tcontent iso,vztmpl,backup,images,rootdir\n' > "$f" || die "cannot write ${f}"
  fi
  log "storage.cfg written: dir local, /var/lib/vz"
}

verify_storage_cfg() {
  grep -q '^dir: local[[:space:]]*$' "${ROOT}/etc/pve/storage.cfg" 2>/dev/null \
    || die "STORAGE CHECK: /etc/pve/storage.cfg is missing or does not name 'local': host-prep would find no storage"
}

# Last word before the reboot: the file we will boot into must carry vmbr0 with the address and
# gateway, bound to a port the .link file names for this MAC (#1237). Re-reads from disk.
verify_network() {  # <cidr> <gateway> <mac>
  local f="${ROOT}/etc/network/interfaces" st
  st="$(sed -n '/^iface vmbr0 inet static/,/^$/p' "$f" 2>/dev/null)"
  [[ -n "$st" ]] || die "BOOT FILE CHECK: ${f} has no vmbr0 stanza: will not reboot into a box with no network"
  grep -q "^auto vmbr0" "$f" || die "BOOT FILE CHECK: vmbr0 is not set to come up (no 'auto vmbr0')"
  grep -qxF "$(printf '\taddress %s' "$1")" <<<"$st" || die "BOOT FILE CHECK: vmbr0 lacks address $1"
  grep -qxF -e "$(printf '\tgateway %s' "$2")" -e "$(printf '\tpost-up ip route add default via %s dev vmbr0' "$2")" <<<"$st" \
    || die "BOOT FILE CHECK: vmbr0 lacks gateway $2"
  grep -q "^[[:space:]]*bridge-ports ${PORT_NAME}\$" <<<"$st" || die "BOOT FILE CHECK: vmbr0 bridge-ports is not ${PORT_NAME}"
  { grep -q "^MACAddress=$3\$" "$LINK_FILE" && grep -q "^Name=${PORT_NAME}\$" "$LINK_FILE"; } 2>/dev/null \
    || die "BOOT FILE CHECK: ${LINK_FILE} does not give MAC $3 the name ${PORT_NAME}: the port would not exist after reboot"
  local r="${ROOT}/etc/resolv.conf"   # (#1237) a symlink to the resolved stub, or loopback only, means no DNS
  [[ ! -L "$r" ]] || die "BOOT FILE CHECK: /etc/resolv.conf is still a symlink: the box would boot with no upstream DNS"
  grep -E '^nameserver[[:space:]]+[0-9]' "$r" 2>/dev/null | grep -qvE '^nameserver[[:space:]]+127\.' \
    || die "BOOT FILE CHECK: /etc/resolv.conf has no non-loopback nameserver: the box would boot with no DNS"
}

# ── phase 2 ────────────────────────────────────────────────────────────────────────────────
phase2() {
  local host addr up cidr gw k
  # shellcheck disable=SC1090
  . "$STATE_ENV" 2>/dev/null || die "phase state ${STATE_ENV} is missing or unreadable"
  host="$DEBIAN_TO_PVE_HOSTNAME"; addr="$DEBIAN_TO_PVE_ADDRESS"
  log "phase 2: kernel $(probe_running_kernel)"
  quiesce_apt
  pin_hosts "$host" "$addr"
  if [[ -z "$ROOT" ]] && systemctl is-failed --quiet pve-cluster 2>/dev/null; then   # a boot undid the entry
    systemctl reset-failed pve-cluster; systemctl restart pve-cluster pveproxy || warn "pve-cluster restart failed"
  fi

  preseed_grub
  heal_dpkg
  if ! probe_pkg_installed proxmox-ve; then
    printf 'postfix postfix/main_mailer_type select Local only\npostfix postfix/mailname string %s\n' "$host" | real debconf-set-selections \
      || die "debconf preseed for postfix failed"
    apt_q update || die "apt-get update failed (see ${LOG_FILE})"
    apt_q install proxmox-ve postfix open-iscsi chrony || die "installing proxmox-ve postfix open-iscsi chrony failed (see ${LOG_FILE})"
  fi
  # root's way in first, before any step below can die (#1283)
  restore_root_keys
  keep_root_keys_outside_pve
  disable_enterprise_sources
  # the Debian kernel and os-prober (os-prober adds the other kernel to grub for nothing)
  apt_q remove linux-image-amd64 linux-image-cloud-amd64 'linux-image-6.*' os-prober || warn "removing the Debian kernel / os-prober returned non-zero"
  real update-grub >>"$LOG_FILE" 2>&1 || die "update-grub failed (see ${LOG_FILE})"

  write_network || exit $?
  verify_apt

  command -v pveversion >/dev/null 2>&1 || die "pveversion is not on PATH after installing proxmox-ve"
  log "$(pveversion 2>&1)"
  local _; for _ in $(seq 1 30); do probe_web && break; sleep 2; done
  probe_web || die "port 8006 does not answer locally after 60 s"
  restore_root_keys
  keep_root_keys_outside_pve

  ensure_storage_cfg
  verify_storage_cfg

  install_pin_unit "$host" "$addr"
  # a hypervisor's network is ours: no cloud-init at boot, so nothing rewrites hosts/hostname (#1283)
  mkdir -p "${ROOT}/etc/cloud" && : > "${ROOT}/etc/cloud/cloud-init.disabled" || die "cannot write cloud-init.disabled"
  apply_name "$host" "$addr"; verify_name "$host" "$addr"
  verify_bootable

  # NOT done yet (#1283): the resume unit stays armed and proves this restart first
  printf 'verify\n' > "$STATE_PHASE"
  log "phase 2 finished on ${host}; rebooting once so vmbr0 takes effect, then the post-boot check decides DONE"
  do_reboot "bridge takes effect"
}

# ── phase 3: the restart is proven before DONE (#1283) ─────────────────────────────────────
post_boot_failures() {  # prints what is wrong, one phrase per line; empty = all good
  probe_cluster_active || echo "pve-cluster is not active"
  [[ -e "${ROOT}/etc/pve/local" ]] || echo "/etc/pve/local is missing"
  probe_web || echo "the web port 8006 is silent"
  [[ -s "${ROOT}/root/.ssh/authorized_keys" ]] || echo "root's authorized_keys is empty or dangling"
  [[ -e "${ROOT}/sys/class/net/vmbr0/brif/${PORT_NAME}" ]] || echo "vmbr0 has no port ${PORT_NAME}"
  [[ "$(probe_uplink)" == vmbr0 ]] || echo "the default route is not on vmbr0"
  [[ -s "${ROOT}/etc/pve/storage.cfg" ]] || echo "/etc/pve/storage.cfg is empty or missing"
  sata_lpm_failures
}
post_boot_diagnostics() {  # what the next person needs to read, in the 0600 conversion log
  {
    echo "--- journalctl --list-boots"; journalctl --list-boots --no-pager 2>&1
    echo "--- journalctl -b -1 -p warning -n 150"; journalctl -b -1 -p warning -n 150 --no-pager 2>&1
    echo "--- journalctl -b -u pve-cluster -u pveproxy -u pvedaemon -n 60"; journalctl -b -u pve-cluster -u pveproxy -u pvedaemon -n 60 --no-pager 2>&1
    echo "--- journalctl -b -u pve-cluster -n 80"; journalctl -b -u pve-cluster -n 80 --no-pager 2>&1
    echo "--- systemctl --failed"; systemctl --failed --no-pager 2>&1
    echo "--- systemctl status pve-cluster"; systemctl status pve-cluster --no-pager 2>&1
    echo "--- /proc/cmdline"; cat "${ROOT}/proc/cmdline" 2>&1
    echo "--- dmesg | tail -60"; dmesg 2>&1 | tail -60
    echo "--- mount | grep pve|fuse"; mount 2>&1 | grep -E 'pve|fuse'
    echo "--- ls -la /etc/pve /var/lib/pve-cluster"; ls -la "${ROOT}/etc/pve" "${ROOT}/var/lib/pve-cluster" 2>&1
    echo "--- /etc/hostname"; cat "${ROOT}/etc/hostname" 2>&1
    echo "--- /etc/hosts"; cat "${ROOT}/etc/hosts" 2>&1
    echo "--- hostname -f"; hostname -f 2>&1
    echo "--- getent hosts \$(hostname)"; getent hosts "$(cur_hostname)" 2>&1
    echo "--- date -u"; date -u 2>&1
    echo "--- ip -br a"; ip -br a 2>&1
    echo "--- ip r"; ip r 2>&1
    echo "--- /proc/mdstat"; cat "${ROOT}/proc/mdstat" 2>&1
  } >>"$LOG_FILE" 2>&1
}
# One round of the check: wait for the services, then heal an empty key file from the saved copy.
post_boot_round() {  # sets $bad
  local _
  for _ in $(seq 1 90); do bad="$(post_boot_failures)"; [[ -z "$bad" ]] && break; sleep 2; done
  if [[ -n "$bad" ]]; then
    probe_cluster_active && [[ -e "${ROOT}/etc/pve/local" ]] && restore_root_keys && bad="$(post_boot_failures)"
  fi
}
# A boot-time rewrite of the name is the known cause (#1283): put it back and restart the services.
post_boot_heal() {
  local pa="${DEBIAN_TO_PVE_ADDRESS:-}" ph="${DEBIAN_TO_PVE_HOSTNAME:-}"
  [[ -s "$HOSTS_PIN" ]] && read -r pa ph < "$HOSTS_PIN"
  if [[ -n "$pa" && -n "$ph" ]]; then apply_name "$ph" "$pa"; else warn "no name/address to re-pin"; fi
  systemctl reset-failed pve-cluster pveproxy pvedaemon >>"$LOG_FILE" 2>&1   # not `real`: stubbed in tests
  systemctl restart pve-cluster pveproxy pvedaemon >>"$LOG_FILE" 2>&1 || warn "restart of the Proxmox services failed"
}
post_boot() {
  local host bad="" cf="${STATE_DIR}/verify-attempts" tries=0
  # shellcheck disable=SC1090
  . "$STATE_ENV" 2>/dev/null; host="${DEBIAN_TO_PVE_HOSTNAME:-?}"
  log "post-boot check on kernel $(probe_running_kernel)"
  disk_record post-boot   # the first Proxmox-kernel view, kept even if the check then fails (#1325)
  if curl -fsI --max-time 10 "$KEYRING_URL" >/dev/null 2>&1; then log "off-box: ${KEYRING_URL%%/debian*} reachable"; else warn "off-box: cannot reach ${KEYRING_URL%%/debian*} (not a failure)"; fi
  post_boot_round
  if [[ -n "$bad" ]]; then
    warn "post-boot check failed: $(tr '\n' ';' <<<"$bad"); healing once"
    post_boot_heal; post_boot_round
    [[ -z "$bad" ]] && log "post-boot check passed after the heal: healed by re-pin"
  fi
  if [[ -n "$bad" ]]; then
    warn "post-boot check failed: $(tr '\n' ';' <<<"$bad")"
    post_boot_diagnostics
    [[ -s "$cf" ]] && tries="$(cat "$cf")"; tries=$((tries+1)); echo "$tries" > "$cf"
    if (( tries == 1 )); then
      do_reboot "post-boot retry"
      DIE_RC=1 die "post-boot check failed; one automatic restart to retry (diagnostics in ${LOG_FILE})"
    fi
    local reach="root has NO verified key outside /etc/pve: use the provider's rescue system"
    [[ -e $KEYS_OK && -s ${ROOT}/root/.ssh/authorized_keys2 && -e $SSHD_DROPIN ]] && reach="root access configured via authorized_keys2"
    DIE_RC=1 die "post-boot check failed again: no further automatic restart; the box stays up, ${reach}; the resume unit stays armed; read ${LOG_FILE}"
  fi
  disarm_resume
  : > "$DONE_MARK"
  log "DONE: Proxmox VE is installed and survived its restart on ${host}; run the console one-liner; disk record: ${DISK_WARNS} warnings"
}

# One conversion run at a time: the resume unit and a hand start must not overlap (#1283).
take_lock() {
  [[ -n "$ROOT" ]] && return 0
  mkdir -p "$STATE_DIR" && chmod 0700 "$STATE_DIR"
  exec 9>"${STATE_DIR}/lock"
  flock -n 9 || die "another conversion run is active"
}

# ── dispatch ───────────────────────────────────────────────────────────────────────────────
main() {
  local check=0 pin=0 status=0 repin_fq='' repin_ad=''
  while (($#)); do case "$1" in
    --hostname) [[ $# -ge 2 ]] || die "missing value for --hostname"; DEBIAN_TO_PVE_HOSTNAME="$2"; shift 2;;
    --address)  [[ $# -ge 2 ]] || die "missing value for --address"; DEBIAN_TO_PVE_ADDRESS="$2"; shift 2;;
    --status)   status=1; shift;;
    --check)    check=1; shift;;
    --pin-hosts) pin=1; shift;;
    --repin)    [[ $# -ge 2 ]] || die "missing fqdn for --repin"; repin_fq="$2"; shift 2
                if [[ $# -ge 1 && $1 != --* ]]; then repin_ad="$1"; shift; fi;;
    *) die "unknown argument '$1'";;
  esac; done
  if ((status)); then   # read-only: for the operator and for "done yet?" (#1283)
    [[ -n "$ROOT" || $EUID -eq 0 ]] || { echo "run as root (the state dir is root-only)"; exit 3; }
    [[ -e "$DONE_MARK" ]] && { echo DONE; exit 0; }
    echo "phase=$(cat "$STATE_PHASE" 2>/dev/null || echo none) phase1-reruns=$(cat "${STATE_DIR}/attempts" 2>/dev/null || echo 0) postboot-failures=$(cat "${STATE_DIR}/verify-attempts" 2>/dev/null || echo 0)"
    exit 1
  fi
  [[ -n "$ROOT" || $EUID -eq 0 ]] || die "must run as root: found uid $EUID"

  if [[ -n "$repin_fq" ]]; then   # rename procedure (#1289): the pin follows the new name
    local ra rs; ra="${repin_ad:-$(awk '{print $1; exit}' "$HOSTS_PIN" 2>/dev/null)}"
    rs="$(awk '{print $3; exit}' "$HOSTS_PIN" 2>/dev/null)"
    [[ -n "$ra" ]] || die "no address: pass one, or run on a converted box with ${HOSTS_PIN}"
    [[ "$repin_fq" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9-]+)+$ ]] || die "--repin: '${repin_fq}' is not a lowercase FQDN"
    [[ "$ra" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "--repin: '${ra}' is not a dotted IPv4"
    [[ -n "$repin_ad" ]] && rs=override   # an address typed by hand is never a probe
    printf '%s %s %s\n' "$ra" "$repin_fq" "${rs:-probe}" > "$HOSTS_PIN" || die "cannot write ${HOSTS_PIN}"
    log "pin rewritten: ${repin_fq} ${ra}"; exit 0
  fi
  if ((pin)); then   # boot-time unit (#1283): before pve-cluster, with or without the done marker
    local pa ph po; read -r pa ph po < "$HOSTS_PIN" 2>/dev/null; [[ -n "${pa:-}" && -n "${ph:-}" ]] || die "no pinned hosts entry in ${HOSTS_PIN}"
    # A moved box (#1289): the address is no longer configured, so the pin is stale; leave /etc/hosts alone.
    [[ "${po:-probe}" == override ]] || pin_address_current "$pa" || { log "pin ${pa} is not this box's configured address any more; not re-pinning"; exit 0; }
    apply_name "$ph" "$pa"; log "hosts pinned at boot: ${ph}"; exit 0
  fi
  [[ -e "$DONE_MARK" ]] && { log "already converted (${DONE_MARK}); nothing to do"; exit 0; }
  ((check)) || take_lock
  assert_debian13
  if [[ -s "$STATE_PHASE" ]]; then   # we started: resume, whatever half-installed state we are in
    ((check)) && { log "check: phase state present, would resume"; exit 0; }
    [[ "$(cat "$STATE_PHASE")" == verify ]] && { post_boot; exit $?; }
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
