#!/bin/bash
#
# hook.sh — prometheus bootstrap, stage 1 (PUBLIC).
#
# Run on a bare Proxmox host console:
#   curl -fsSL https://raw.githubusercontent.com/thanadiosa/prometheus/main/hook.sh | bash
#
# Stage 1 is tiny and stable: establish access to the helper (SFTP) server, fetch
# the needle (stage 2), run it. All address-specific logic lives in the needle. No
# secret or private address is baked into this file — it is public.
#
# HELPER TRANSPORT (issue #75): the helper may be an OpenSSH sftp chroot (KEY auth +
# exec channel) OR a proftpd mod_sftp seedbox (PASSWORD auth, SFTP-only). hook.sh is
# PRE-REPO (public curl|bash), so it can't source the repo's bootstrap/helper-lib.sh —
# instead it does ONE irreducible inline fetch of helper-lib.sh from the helper (the
# bootstrap TRUST ROOT: whoever serves this file is trusted to serve the boot chain),
# then SOURCES it and drives every remaining helper op through the lib interface.
#
set -uo pipefail
reset

# Helper-side paths are CHROOT-RELATIVE (per-estate chroot — issue #75): PROVISIONER_REMOTE_DIR
# overrides the root (empty = the chroot root); scripts/ holds the boot scripts + the lib.
# Must match genesis.sh / needle.sh / control-boot.sh / run-pipeline.sh.
_RD="${PROVISIONER_REMOTE_DIR:-}"
SCRIPTS_REMOTE="${_RD:+${_RD}/}scripts"
NEEDLE_REMOTE="${SCRIPTS_REMOTE}/start.sh"          # needle.sh, deployed as start.sh
LIB_REMOTE="${SCRIPTS_REMOTE}/helper-lib.sh"        # the shared transport lib
STORAGE_LIB_REMOTE="${SCRIPTS_REMOTE}/pve-storage-detect.sh"  # shared VM-disk storage resolver (needle sources it)
HELPER_CACHE="/root/helper"                         # caches user@host
PORT_CACHE="/root/helper-port"                      # caches the (non-22) helper port
HELPER_PASS_FILE="/etc/provisioner/helper-pass"     # where the collected password lands (needle reads it)

log() { printf '\n[hook] %s\n' "$*" >&2; }

# ── Resolve helper (user@host) + port, cached across runs ─────────────────────
# Loop so a wrong/unreachable entry re-prompts instead of forcing a one-liner restart.
helper=""; helper_server=""; port=""
while :; do
  if [[ -f $HELPER_CACHE ]]; then
    helper=$(cat "$HELPER_CACHE"); log "using cached helper ($helper)"
  else
    # /dev/tty explicitly: the documented entrypoint is `curl … | bash`, so stdin is the
    # pipe, not the console — a plain `read` gets EOF and spins the loop.
    read -r -p "helper (user@host): " helper </dev/tty
  fi
  if [[ -z $helper || $helper != *@* ]]; then
    log "expected user@host, try again"; rm -f "$HELPER_CACHE"; continue
  fi
  helper_server="${helper#*@}"

  # Port: env wins, else cache, else prompt (default 22 — the OpenSSH case; a seedbox
  # helper is a high port like 14236). Threaded to needle so the whole chain agrees.
  port="${PROVISIONER_HELPER_PORT:-}"
  [[ -z $port && -f $PORT_CACHE ]] && port="$(cat "$PORT_CACHE")"
  if [[ -z $port ]]; then
    read -r -p "helper SSH/SFTP port [22]: " port </dev/tty; port="${port:-22}"
  fi

  # Reachability pre-check on the ACTUAL port → fast, clear failure. bash's built-in
  # /dev/tcp needs no external tool (`nc` is not on a fresh PVE host).
  if ! timeout 5 bash -c "exec 3<>/dev/tcp/${helper_server}/${port}" 2>/dev/null; then
    log "helper unreachable on :${port} — re-enter"; rm -f "$HELPER_CACHE"; continue
  fi
  mkdir -p ~/.ssh
  ssh-keyscan -p "$port" "$helper_server" >> ~/.ssh/known_hosts 2>/dev/null || true
  break
done

# ── One irreducible inline fetch: pull helper-lib.sh, then hand the rest to it ─
# The bootstrap trust root. Try KEY auth first (scp — the OpenSSH-helper case, unchanged
# from the historical hook); if that fails the helper is password-only, so collect the
# helper password ONCE (silent, to a 0600 file needle reuses) and fetch over SFTP with it.
# This is the ONLY hand-rolled transport in the chain — everything after sources the lib.
mkdir -p /etc/provisioner
# Cipher/MAC pin for BOTH helper paths below (issue: iapetus seedbox). A proftpd mod_sftp
# seedbox helper CORRUPTS transfers >~1KB under the default cipher/MAC negotiation
# ("message authentication code incorrect"); forcing aes128-ctr + hmac-sha2-256 (no AEAD
# on the seedbox) tested 6/6 clean. Env-OVERRIDABLE via `-` (not `:-`): an EMPTY value
# omits the flags so a clean key+exec OpenSSH helper keeps its default negotiation. Built
# as an array spliced into the password sftp AND the key-path scp; empty ⇒ zero tokens.
cm_opts=()
[[ -n ${PROVISIONER_HELPER_CIPHERS-aes128-ctr} ]] && cm_opts+=(-o Ciphers="${PROVISIONER_HELPER_CIPHERS-aes128-ctr}")
[[ -n ${PROVISIONER_HELPER_MACS-hmac-sha2-256} ]] && cm_opts+=(-o MACs="${PROVISIONER_HELPER_MACS-hmac-sha2-256}")
sftp_opts=(-o PreferredAuthentications=password -o PubkeyAuthentication=no
           -o NumberOfPasswordPrompts=1 -o StrictHostKeyChecking=accept-new
           -o ConnectTimeout=15 "${cm_opts[@]}" -P "$port")

fetch_lib() {
  # (a) KEY path: scp uses the default identity + the sftp subsystem (works on both helper
  #     kinds when a key is authorized). Success ⇒ key helper, no password needed.
  #     WRAPPED IN `timeout` (mirrors helper-lib's HELPER_PROBE_TIMEOUT): a seedbox mod_sftp
  #     helper ACCEPTS an RSA /root/.ssh/id_rsa then HANGS verifying the signature, and
  #     ConnectTimeout does NOT bound that post-auth hang — without this the WHOLE cold-start
  #     wedges here (confirmed rc=124) instead of falling through to the password path (b).
  timeout "${PROVISIONER_HELPER_PROBE_TIMEOUT:-25}" \
    scp -P "$port" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o BatchMode=yes "${cm_opts[@]}" \
      "${helper}:${LIB_REMOTE}" ./helper-lib.sh 2>/dev/null && return 0
  # (b) PASSWORD path: collect once (never echoed), stash 0600 for needle, fetch via sftp.
  # hook_collected_pass records whether the credential is OURS to discard on a retry (below):
  # an operator-pre-staged /etc/provisioner/helper-pass is NEVER ours to delete.
  if [[ ! -s $HELPER_PASS_FILE ]]; then
    local pw
    read -rsp "helper password: " pw </dev/tty; printf '\n' >&2
    ( umask 077; printf '%s' "$pw" > "$HELPER_PASS_FILE" ); unset pw
    chmod 600 "$HELPER_PASS_FILE"
    hook_collected_pass=1
  fi
  command -v sshpass >/dev/null 2>&1 || {
    log "installing sshpass (needed for the password-only helper)"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass >/dev/null 2>&1 \
      || { log "could not install sshpass — cannot reach a password-only helper"; return 1; }
  }
  printf 'get %s ./helper-lib.sh\n' "$LIB_REMOTE" \
    | sshpass -f "$HELPER_PASS_FILE" sftp "${sftp_opts[@]}" "$helper" >/dev/null 2>&1 \
    && [[ -s ./helper-lib.sh ]]
}

# TTY-aware, fail-fast retry (issue: iapetus wedge). Detect a controlling terminal ONCE:
# the documented entrypoint is a console `curl|bash`, but needle re-invokes the chain under
# setsid with NO tty, where a `read </dev/tty` returns EOF instantly and BUSY-SPINS forever.
hook_collected_pass=0
have_tty=0; { : </dev/tty; } 2>/dev/null && have_tty=1
attempts=0
max_attempts="${PROVISIONER_HOOK_FETCH_MAX_ATTEMPTS:-5}"
while :; do
  if fetch_lib; then break; fi
  attempts=$((attempts + 1))
  log "could not fetch helper-lib.sh — check access/password (attempt ${attempts})"
  # Discard ONLY a password THIS run collected — NEVER an operator-pre-staged one (deleting
  # it strips a no-tty run of its sole credential and wedges every retry).
  if [[ $hook_collected_pass == 1 ]]; then rm -f "$HELPER_PASS_FILE"; hook_collected_pass=0; fi
  rm -f ./helper-lib.sh
  if [[ $have_tty == 1 ]]; then
    # Console operator: human-gated, unbounded — enter re-prompts, Ctrl-C aborts.
    read -r -p "press enter to retry, or Ctrl-C to abort " _ </dev/tty || true
    continue
  fi
  # No controlling terminal: cannot re-prompt, so bound the retries and die loudly instead
  # of spinning (the original wedge). A brief sleep rides out a transient transport error.
  if (( attempts >= max_attempts )); then
    log "no controlling terminal to re-prompt; giving up after ${attempts} attempts fetching helper-lib.sh"
    exit 1
  fi
  sleep 3
done

# Persist the working coordinates only AFTER a proven fetch.
echo "$helper" > "$HELPER_CACHE"
[[ $port != 22 ]] && echo "$port" > "$PORT_CACHE"

# From here the lib owns every helper op. Point it at the port + (if collected) the password
# file; it auto-detects auth (key vs password) and channel (exec vs SFTP-only).
export HELPER="$helper"
export PROVISIONER_HELPER_PORT="$port"
# The PVE host's baked helper key (issue #61) for the lib's KEY probe; a password helper
# rejects it and the lib falls back to the password file collected above.
export PROVISIONER_HELPER_ID="${PROVISIONER_HELPER_ID:-/root/.ssh/id_rsa}"
[[ -s $HELPER_PASS_FILE ]] && export PROVISIONER_HELPER_PASS_FILE="$HELPER_PASS_FILE"
# shellcheck source=bootstrap/helper-lib.sh
. ./helper-lib.sh

log "fetching the needle via helper-lib"
helper_get "$NEEDLE_REMOTE" ./needle.sh || { log "could not fetch the needle — aborting"; exit 1; }

# needle sources the shared VM-disk storage resolver from its OWN dir (like helper-lib.sh),
# so fetch it next to needle. genesis.sh deploys it to the helper scripts dir.
log "fetching the storage resolver via helper-lib"
helper_get "$STORAGE_LIB_REMOTE" ./pve-storage-detect.sh \
  || { log "could not fetch pve-storage-detect.sh — aborting (re-run genesis deploy to stage it)"; exit 1; }

# ── Hand off ──────────────────────────────────────────────────────────────────
chmod +x ./needle.sh
log "running the needle"
# Thread the port (+ pass file) to needle so the whole chain reaches the same helper.
PROVISIONER_HELPER_PORT="$port" ./needle.sh "$helper"
