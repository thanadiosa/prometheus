#!/bin/bash
set -uo pipefail
reset

_RD="${PROVISIONER_REMOTE_DIR:-}"
_RD_FROM_ENV=0
[[ -n ${PROVISIONER_REMOTE_DIR+x} ]] && _RD_FROM_ENV=1
SCRIPTS_REMOTE="${_RD:+${_RD}/}scripts"
SECRETS_REMOTE="${_RD:+${_RD}/}secrets"
LIB_REMOTE="${SCRIPTS_REMOTE}/helper-lib.sh"        # the shared transport lib — the ONLY staged file we fetch
DEPLOY_KEY_REMOTE="${SECRETS_REMOTE}/github_deploy" # read-only GitHub credential (issue #10 shapes)
VERSION_REMOTE="${_RD:+${_RD}/}version"             # the per-estate version pointer (issue #232)
HELPER_CACHE="/root/helper"                         # caches user@host
PORT_CACHE="/root/helper-port"                      # caches the (non-22) helper port
STATE_DIR="/etc/provisioner"                        # the boot chain's own 0700 state/secret dir
HELPER_PASS_FILE="${STATE_DIR}/helper-pass"         # where the collected password lands (needle reads it)
DEPLOY_KEY="${STATE_DIR}/github_deploy"             # the deploy key, once pulled (0600)
GIT_ASKPASS_HELPER="${STATE_DIR}/git-askpass.sh"    # token mode only — keeps the PAT out of .git/config
REPO_DIR="${PROVISIONER_REPO_DIR:-/opt/provisioner}"
REPO_URL="git@github.com:parrhasia/prometheus.git"
NEEDLE_MAIN="${REPO_DIR}/bootstrap/needle.sh"       # what we hand off to
estate="${PROVISIONER_ESTATE:-$(hostname -s 2>/dev/null || true)}"
HELPER_AUTH_CACHE="/root/helper-auth"

case "${PROVISIONER_VERBOSE:-0}" in
  1|true|TRUE|True|yes|YES|on|ON) HOOK_VERBOSE=1; export PROVISIONER_VERBOSE=1 ;;
  *)                              HOOK_VERBOSE=0 ;;
esac
HOOK_LOG_DIR="${PROVISIONER_NEEDLE_LOG_DIR:-/var/log/provisioner}"
HOOK_LOG="${PROVISIONER_NEEDLE_LOG-${HOOK_LOG_DIR}/needle.log}"

_hook_log_file() {
  [[ -n ${HOOK_LOG:-} ]] || return 1
  [[ -d ${HOOK_LOG%/*} ]] || install -d -m 0700 "${HOOK_LOG%/*}" 2>/dev/null || return 1
  ( umask 077; printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$HOOK_LOG" ) 2>/dev/null || return 1
  chmod 0600 "$HOOK_LOG" 2>/dev/null || true
  return 0
}
_prov_quiet_sink() {
  local rc=$?
  if [[ $HOOK_VERBOSE == 1 ]]; then
    printf '%s\n' "$*" >&2; _hook_log_file "$*"     # recorded in BOTH modes
  else
    _hook_log_file "$*" || printf '%s\n' "$*" >&2
  fi
  return $rc
}

log() {
  if [[ $HOOK_VERBOSE == 1 ]]; then printf '\n[hook] %s\n' "$*" >&2; _hook_log_file "[hook] $*"
  else _hook_log_file "[hook] $*" || printf '\n[hook] %s\n' "$*" >&2; fi
  return 0
}
say()  { printf '\n[hook] %s\n' "$*" >&2; _hook_log_file "[hook] $*"; return 0; }
warn() { printf '\n[hook] WARNING: %s\n' "$*" >&2; _hook_log_file "[hook] WARNING: $*"; return 0; }
die()  { printf '\n[hook] ERROR: %s\n' "$*" >&2; _hook_log_file "[hook] ERROR: $*"; exit 1; }

HOOK_LAP_STAMP="${PROVISIONER_NEEDLE_LAP_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
export PROVISIONER_NEEDLE_LAP_STAMP="$HOOK_LAP_STAMP"
if [[ -z ${HOOK_LOG:-} ]]; then
  HOOK_FEED="${PROVISIONER_NEEDLE_FEED-}"
else
  HOOK_FEED="${PROVISIONER_NEEDLE_FEED-${HOOK_LOG_DIR}/${HOOK_LAP_STAMP}-needle.log}"
fi
export PROVISIONER_NEEDLE_FEED="$HOOK_FEED"

_hook_feed_line() {
  [[ -n ${HOOK_FEED:-} ]] || return 0
  [[ -d ${HOOK_FEED%/*} ]] || install -d -m 0700 "${HOOK_FEED%/*}" 2>/dev/null || return 0
  ( umask 077; printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$HOOK_FEED" ) 2>/dev/null || return 0
  chmod 0600 "$HOOK_FEED" 2>/dev/null || true
  return 0
}

milestone() {
  log "$*"
  _hook_feed_line "[hook] $*"
  return 0
}

have_tty=0; { : </dev/tty; } 2>/dev/null && have_tty=1

HELPER_DEFAULT_SSH_RD="downloads/helper"

parse_helper_target() {
  local raw="$1" authority
  HT_HELPER=""; HT_PORT=""; HT_PATH=""
  if [[ $raw == */* ]]; then
    authority="${raw%%/*}"
    HT_PATH="${raw#*/}"          # everything after the first slash
    HT_PATH="${HT_PATH%/}"       # a trailing slash is noise on a directory path
  else
    authority="$raw"
  fi
  if [[ $authority =~ ^(.+):([0-9]+)$ ]]; then
    HT_HELPER="${BASH_REMATCH[1]}"; HT_PORT="${BASH_REMATCH[2]}"
  else
    HT_HELPER="$authority"
  fi
}


helper=""; helper_server=""; port=""; helper_src=""; port_src=""
helper_env_used=0; helper_cache_used=0; port_env_used=0; port_cache_used=0
helper_ok=0      # an already-validated address is not re-asked just because the port was bad
embedded_port=""; embedded_rd=""
interview_round=0
INTERVIEW_MAX_ROUNDS="${PROVISIONER_HOOK_INTERVIEW_MAX_ROUNDS:-12}"
[[ $INTERVIEW_MAX_ROUNDS =~ ^[0-9]+$ ]] && (( INTERVIEW_MAX_ROUNDS >= 1 )) || INTERVIEW_MAX_ROUNDS=12
while :; do
  interview_round=$((interview_round + 1))
  if (( interview_round > INTERVIEW_MAX_ROUNDS )); then
    die "gave up after ${INTERVIEW_MAX_ROUNDS} attempts to get a usable helper address/port.
This is a guard against an unanswerable loop — the last values tried were helper='${helper}' port='${port}'.
Re-run the hook, or set PROVISIONER_HELPER=user@host and PROVISIONER_HELPER_PORT=<port>."
  fi

  if [[ $helper_ok == 1 ]]; then
    :   # already validated this round-set; only the port still needs an answer
  elif [[ -n ${PROVISIONER_HELPER:-} && $helper_env_used == 0 ]]; then
    helper="${PROVISIONER_HELPER}"; helper_src="env"; helper_env_used=1
    log "using PROVISIONER_HELPER from the environment"
  elif [[ -f $HELPER_CACHE && $helper_cache_used == 0 ]]; then
    helper=$(cat "$HELPER_CACHE"); helper_src="cache"; helper_cache_used=1
    log "using cached helper ($helper)"
  elif [[ $have_tty == 1 ]]; then
    helper=""
    read -r -p "helper address: " helper </dev/tty \
      || die "lost the controlling terminal while asking for the helper address — set PROVISIONER_HELPER=user@host and re-run."
    helper_src="prompt"
  else
    die "no helper address, and no controlling terminal to ask on.
Set it in the environment before invoking the hook:
  • PROVISIONER_HELPER=user@host        (required)
  • PROVISIONER_HELPER_PORT=<port>      (optional, default 22)
Nothing has been changed on this host."
  fi
  if [[ $helper_ok != 1 ]]; then
    parse_helper_target "$helper"
    helper="$HT_HELPER"; embedded_port="$HT_PORT"; embedded_rd="$HT_PATH"
    [[ -n $embedded_port || -n $embedded_rd ]] \
      && log "combined helper form: address='${helper}'${embedded_port:+ port='${embedded_port}'}${embedded_rd:+ remote-dir='${embedded_rd}'}"
  fi
  if [[ ! $helper =~ ^[A-Za-z0-9._@-]+@[A-Za-z0-9._-]+$ ]]; then
    case "$helper_src" in
      env)   die "PROVISIONER_HELPER='${helper}' is not user@host — fix it and re-run. Nothing has been changed.";;
      cache) say "cached helper '${helper}' is not user@host — discarding it and asking"; rm -f "$HELPER_CACHE";;
      *)     say "expected user@host, try again";;
    esac
    continue     # the bad source is now marked used (and the cache file removed) — progress
  fi
  helper_server="${helper#*@}"; helper_ok=1

  port=""; port_src=""
  if [[ -n $embedded_port ]]; then
    port="$embedded_port"; port_src="target"; embedded_port=""
  elif [[ -n ${PROVISIONER_HELPER_PORT:-} && $port_env_used == 0 ]]; then
    port="${PROVISIONER_HELPER_PORT}"; port_src="env"; port_env_used=1
  elif [[ -f $PORT_CACHE && $port_cache_used == 0 ]]; then
    port="$(cat "$PORT_CACHE")"; port_src="cache"; port_cache_used=1
  elif [[ $have_tty == 1 ]]; then
    read -r -p "helper port [22]: " port </dev/tty \
      || die "lost the controlling terminal while asking for the helper port — set PROVISIONER_HELPER_PORT and re-run."
    port="${port:-22}"; port_src="prompt"
  else
    port=22; port_src="default"   # safe default; PROVISIONER_HELPER_PORT overrides it
  fi
  if [[ ! $port =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    case "$port_src" in
      env)   die "PROVISIONER_HELPER_PORT='${port}' is not a valid port number (1-65535) — fix it and re-run. Nothing has been changed.";;
      cache) say "cached helper port '${port}' (${PORT_CACHE}) is not a valid port number — discarding it and asking"; rm -f "$PORT_CACHE";;
      *)     say "port must be a number between 1 and 65535, try again";;
    esac
    continue     # the bad source is marked used — the next round reaches the prompt
  fi

  [[ $helper_src != prompt ]] && log "using helper ${helper} on port ${port} (from ${helper_src})"

  if ! timeout 5 bash -c "exec 3<>/dev/tcp/${helper_server}/${port}" 2>/dev/null; then
    [[ $helper_src == env ]] && die "helper '${helper}' is unreachable on :${port} (TCP connect failed) and it came from PROVISIONER_HELPER — check the address/port/DNS and re-run. Nothing has been changed."
    [[ $port_src == env ]] && die "helper is unreachable on :${port} (TCP connect failed) and that port came from PROVISIONER_HELPER_PORT — check the address/port/DNS and re-run. Nothing has been changed."
    if [[ $have_tty == 1 ]]; then
      say "helper unreachable on :${port} — re-enter"
      rm -f "$HELPER_CACHE" "$PORT_CACHE"
      helper_cache_used=1; port_cache_used=1     # belt-and-braces if the rm could not happen
      helper_ok=0                                # the address itself may be what is wrong
      continue
    fi
    die "helper unreachable on :${port} (TCP connect failed) and no controlling terminal to re-ask on — check the address/port/DNS and re-run. Nothing has been changed."
  fi
  mkdir -p ~/.ssh
  ssh-keyscan -p "$port" "$helper_server" >> ~/.ssh/known_hosts 2>/dev/null || true
  break
done

install -d -m 0700 "$STATE_DIR" || die "could not create ${STATE_DIR}"
auth_hint="${PROVISIONER_HELPER_AUTH:-}"
auth_hint_src=""
[[ -n $auth_hint ]] && auth_hint_src='env'
if [[ -z $auth_hint && -f $HELPER_AUTH_CACHE ]]; then
  auth_hint="$(tr -d '[:space:]' < "$HELPER_AUTH_CACHE" 2>/dev/null)"
  auth_hint_src='cache'
fi
case "$auth_hint" in key|password) ;; *) auth_hint=""; auth_hint_src="" ;; esac
[[ -n $auth_hint ]] && log "helper auth known from a previous run: ${auth_hint}"

hook_collected_pass=0
if [[ -s $HELPER_PASS_FILE ]]; then
  log "using the helper password already staged at ${HELPER_PASS_FILE}"
elif [[ $auth_hint == key ]]; then
  log "helper auth is 'key' — no password needed"
elif [[ $have_tty == 1 ]]; then
  if [[ $auth_hint == password ]]; then
    pw_prompt="helper password: "
  else
    pw_prompt="helper password (empty for SSH key): "
  fi
  read -rsp "$pw_prompt" pw </dev/tty; printf '\n' >&2
  if [[ -n $pw ]]; then
    ( umask 077; printf '%s' "$pw" > "$HELPER_PASS_FILE" )
    chmod 600 "$HELPER_PASS_FILE"
    hook_collected_pass=1
  fi
  unset pw
elif [[ $auth_hint == password ]]; then
  die "the helper is password-only, no password is staged at ${HELPER_PASS_FILE}, and there is no controlling terminal to ask on.
Stage the password first (root-only, 0600):
  install -m 600 /dev/null ${HELPER_PASS_FILE} && printf '%s' '<password>' > ${HELPER_PASS_FILE}
Nothing has been PROVISIONED (no VM, no user, no sshd change). The interview did create the
empty dirs /etc/provisioner and ~/.ssh and appended the helper's host key to ~/.ssh/known_hosts."
else
  log "no controlling terminal and no staged helper password — KEY auth only (stage ${HELPER_PASS_FILE} 0600 if the helper is password-only)"
fi

HELPER_CRYPT_KEY="${STATE_DIR}/helper-crypt-key"
HELPER_CRYPT_NONE="${STATE_DIR}/helper-crypt-none"
HELPER_ACCESS="${STATE_DIR}/helper-access"   # #1202: the access path without encryption; a line "rclone"
hook_tty_dev=/dev/tty          # a variable, not an env knob: the tests point it at a pty
hook_crypt_minted=0; hook_crypt_new_estate=0
hook_crypt_store() {   # <password> <salt> -> the stored key, atomically, 0600
  local t="${HELPER_CRYPT_KEY}.new.$$"
  rm -f "${HELPER_CRYPT_KEY}".new.*   # stale temp files from a killed earlier run
  ( umask 077; printf '%s\n%s\n' "$1" "$2" > "$t" ) && chmod 600 "$t" && mv -f "$t" "$HELPER_CRYPT_KEY" \
    || { rm -f "$t"; return 1; }
}
hook_crypt_rand() { head -c 32 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n'; }
hook_crypt_from_file() {   # <file> -> copy an operator-supplied key file to the stored path
  local f="$1" pw salt
  [[ -f $f && -r $f ]] || return 1
  pw="$(sed -n 1p "$f" | tr -d '\r\n')"; [[ -n $pw ]] || return 1
  salt="$(sed -n 2p "$f" | tr -d '\r\n')"
  [[ -z $(find "$f" -maxdepth 0 -perm /077 2>/dev/null) ]] || warn "the key file ${f} is readable by others - tighten it (chmod 600) or remove it after this run"
  hook_crypt_store "$pw" "$salt"
}
hook_crypt_key_interview() {
  local src="${PROVISIONER_HELPER_CRYPT_KEY_FILE:-}" ans pw pw2 salt n
  if [[ -s $HELPER_CRYPT_KEY ]]; then
    log "using the seedbox encryption key already stored at ${HELPER_CRYPT_KEY}"
    if [[ -n $src && $src != "$HELPER_CRYPT_KEY" && -s $src ]] && ! cmp -s "$src" "$HELPER_CRYPT_KEY"; then
      warn "PROVISIONER_HELPER_CRYPT_KEY_FILE names a key that differs from the stored one - the STORED key is kept (replacing it would orphan what is already encrypted). Remove ${HELPER_CRYPT_KEY} first if you mean to replace it."
    fi
  elif [[ -n $src ]]; then
    hook_crypt_from_file "$src" || die "PROVISIONER_HELPER_CRYPT_KEY_FILE names ${src}, which is missing, unreadable or has an empty first line (line 1 = password, line 2 = salt)."
    log "the seedbox encryption key was read from the file you named and stored at ${HELPER_CRYPT_KEY}"
  elif [[ ${PROVISIONER_HELPER_ACCESS:-} == rclone ]] || { [[ -s $HELPER_ACCESS && ! -e $HELPER_CRYPT_NONE ]]; }; then   # #1202: third answer, no key
    [[ ${PROVISIONER_HELPER_ACCESS:-} != rclone ]] || rm -f "$HELPER_CRYPT_NONE"   # an explicit setting is newer than an old "none"
    [[ -s $HELPER_ACCESS ]] || ( umask 022; printf 'rclone\n' > "$HELPER_ACCESS" ) || die "could not record the access-path setting at ${HELPER_ACCESS}"
    log "seedbox reached through the access path without encryption (#1202; remove ${HELPER_ACCESS} to be asked again)"
  elif [[ -e $HELPER_CRYPT_NONE ]]; then
    log "no seedbox encryption (chosen on an earlier run; remove ${HELPER_CRYPT_NONE} to be asked again, or name a key file in PROVISIONER_HELPER_CRYPT_KEY_FILE)"
  elif [[ $have_tty == 1 ]]; then
    for n in 1 2 3; do
      read -rp "encrypt this estate's seedbox folder (only a new or already-encrypted one; an existing plain folder must be moved first)? n = no (default) / a = no encryption but reach it through the access path (an encrypted folder is refused at first use) / g = generate a key for me / t = type the key I already have: " ans <"$hook_tty_dev"
      case "${ans:-n}" in
        n|N|no) ( umask 077; : > "$HELPER_CRYPT_NONE" ) 2>/dev/null; log "no seedbox encryption chosen"; break ;;
        a|A) ( umask 022; printf 'rclone\n' > "$HELPER_ACCESS" ) || die "could not record the access-path setting at ${HELPER_ACCESS}"
             log "no seedbox encryption; the seedbox is reached through the access path (#1202)"; break ;;
        g|G)
          pw="$(hook_crypt_rand)"; salt="$(hook_crypt_rand)"
          [[ ${#pw} -ge 32 && ${#salt} -ge 32 ]] || die "could not read random bytes to make a key - nothing was stored"
          hook_crypt_store "$pw" "$salt" || die "could not store the new key at ${HELPER_CRYPT_KEY}"
          if ! { printf '\n  SEEDBOX ENCRYPTION KEY - shown once, never logged:\n    password: %s\n    salt:     %s\n  Copy BOTH somewhere safe NOW. If they are lost, the seedbox contents cannot be\n  read and this estate cannot be rebuilt from it. The copy stored on this hypervisor\n  is destroyed if it is reinstalled, so YOUR copy is the only one that survives.\n\n' "$pw" "$salt" >"$hook_tty_dev"; } 2>/dev/null; then
            rm -f "$HELPER_CRYPT_KEY"; die "could not show the new key on the terminal - it was discarded; run again from a terminal"
          fi
          read -rp "press Enter once you have copied it: " ans <"$hook_tty_dev" >"$hook_tty_dev"
          unset pw salt
          read -rp "is this estate's seedbox folder brand new, nothing stored in it yet? y / n (default n): " ans <"$hook_tty_dev"
          case "$ans" in y|Y|yes) hook_crypt_new_estate=1 ;; esac
          hook_crypt_minted=1; break ;;
        t|T)
          IFS= read -rsp "seedbox key password: " pw <"$hook_tty_dev"; printf '\n' >"$hook_tty_dev"
          IFS= read -rsp "again: " pw2 <"$hook_tty_dev"; printf '\n' >"$hook_tty_dev"
          if [[ -z $pw || $pw != "$pw2" ]]; then unset pw pw2; say "the two entries were empty or did not match, try again"; continue; fi
          IFS= read -rsp "seedbox key salt (empty for none): " salt <"$hook_tty_dev"; printf '\n' >"$hook_tty_dev"
          hook_crypt_store "$pw" "$salt" || die "could not store the key at ${HELPER_CRYPT_KEY}"
          unset pw pw2 salt; break ;;
        *) say "answer n, a, g or t" ;;
      esac
      (( n == 3 )) && die "no usable answer to the encryption question"
    done
    [[ -s $HELPER_CRYPT_KEY || -e $HELPER_CRYPT_NONE || -s $HELPER_ACCESS ]] \
      || die "no encryption key was stored and 'none' was not chosen - stopping rather than carrying on unencrypted by accident"
  fi
  [[ -s $HELPER_CRYPT_KEY ]] && unset PROVISIONER_HELPER_CRYPT_KEY_FILE
  if [[ -s $HELPER_CRYPT_KEY || -e $HELPER_CRYPT_NONE ]]; then rm -f "$HELPER_ACCESS"; fi   # (an explicit setting already cleared "none")
  [[ -s $HELPER_CRYPT_KEY || ${PROVISIONER_HELPER_CRYPT:-} != required ]] \
    || die "PROVISIONER_HELPER_CRYPT=required but no seedbox encryption key is stored at ${HELPER_CRYPT_KEY}"
  [[ $hook_crypt_minted == 1 && $hook_crypt_new_estate == 1 ]] && export PROVISIONER_HELPER_CRYPT_INIT=1
  return 0
}
hook_crypt_key_interview


RD_FACT_FILE="${STATE_DIR}/remote-dir"   # staged by needle.sh for this host (issue #734)
RD_FACT=""            # its value — "" is a REAL value (the chroot root), never a null
RD_FACT_HAVE=0        # 1 = the file is there AND readable, whatever it says
RD_FACT_UNREADABLE=0  # 1 = the file is there and we could not read it (0700 dir, odd mode)
if [[ -e $RD_FACT_FILE ]]; then
  if [[ -r $RD_FACT_FILE ]] && RD_FACT="$(tr -d '[:space:]' < "$RD_FACT_FILE" 2>/dev/null)"; then
    RD_FACT_HAVE=1
    while [[ $RD_FACT == */ ]]; do RD_FACT="${RD_FACT%/}"; done
  else
    RD_FACT_UNREADABLE=1
  fi
fi

RD_SRC=""
RD_PROBE=0            # 1 = nothing named the directory: probe the helper for it (issue #1081)
if [[ -n $embedded_rd ]]; then
  [[ -n $_RD && $_RD != "$embedded_rd" ]] \
    && say "helper remote dir: using '${embedded_rd}' from the combined address (overriding PROVISIONER_REMOTE_DIR='${_RD}')"
  _RD="$embedded_rd"
  RD_SRC="the path typed with the helper address"
  log "helper remote dir set from the combined address: ${_RD}"
elif [[ -n $_RD || $_RD_FROM_ENV == 1 ]]; then
  RD_SRC="PROVISIONER_REMOTE_DIR in the environment"
  log "helper remote dir '${_RD}' taken from PROVISIONER_REMOTE_DIR (an explicit value outranks this box's staged fact — issue #834)"
elif (( RD_FACT_HAVE )); then
  _RD="$RD_FACT"
  RD_SRC="${RD_FACT_FILE}, this box's own staged fact"
  log "helper remote dir '${_RD}' read from ${RD_FACT_FILE} — the layout a previous lap staged on this host, which beats guessing the well-known base (issue #834)"
else
  RD_PROBE=1
  RD_SRC="probing the helper — nothing was typed, no PROVISIONER_REMOTE_DIR, and this box carries no ${RD_FACT_FILE}"
fi
(( RD_FACT_UNREADABLE )) \
  && say "this box carries ${RD_FACT_FILE} but it could not be read — the layout it names was NOT used (issue #834). Check it with: ls -l ${RD_FACT_FILE}"
SCRIPTS_REMOTE="${_RD:+${_RD}/}scripts"
SECRETS_REMOTE="${_RD:+${_RD}/}secrets"
LIB_REMOTE="${SCRIPTS_REMOTE}/helper-lib.sh"
DEPLOY_KEY_REMOTE="${SECRETS_REMOTE}/github_deploy"
VERSION_REMOTE="${_RD:+${_RD}/}version"

foreign_estate_dir() {
  local est="${1:-}" rd="${2:-}" last parent
  [[ -n $est && -n $rd ]] || return 1
  while [[ $rd == */ ]]; do rd="${rd%/}"; done
  [[ $rd == */* ]] || return 1                 # no parent ⇒ nothing identifies it as a slot
  last="${rd##*/}"; parent="${rd%/*}"
  [[ ${parent##*/} == helper ]] || return 1    # not the estates parent ⇒ custom layout ⇒ NOT JUDGED
  [[ -n $last && $last != "$est" ]] || return 1
  printf '%s' "$last"
}
if wrong_estate_dir="$(foreign_estate_dir "$estate" "$_RD")"; then
  die "this box says it is ${estate} but the seedbox directory it was pointed at is ${wrong_estate_dir}'s — the hook was started for the wrong estate; re-run it for ${estate}.
The directory is '${_RD}', chosen from ${RD_SRC}.
Nothing has been fetched and nothing has been changed on this box: both facts above are known before the first byte leaves the helper.
If this box is really meant to build ${wrong_estate_dir}, the estate name is the PVE hostname (SPEC §14.6) — install it under that name, or re-run with PROVISIONER_ESTATE=${wrong_estate_dir} for a standalone run."
fi

[[ $EUID -eq 0 ]] || die "must run as root on the PVE host (the console one-liner runs as root; nothing has been changed)"
for _bin in pveversion qm pvesm; do
  command -v "$_bin" >/dev/null 2>&1 \
    || die "'${_bin}' not found — this does not look like a Proxmox VE host. The bootstrap chain provisions a PVE hypervisor and nothing here will work on anything else. Nothing has been changed."
done
unset _bin
log "raw-PVE gate OK — PVE $(pveversion 2>/dev/null | sed -n 's|^pve-manager/\([0-9.]*\).*|\1|p' || true), running as root (the FULL pre-flight runs from the checkout, below)"

cm_opts=()
[[ -n ${PROVISIONER_HELPER_CIPHERS-aes128-ctr} ]] && cm_opts+=(-o Ciphers="${PROVISIONER_HELPER_CIPHERS-aes128-ctr}")
[[ -n ${PROVISIONER_HELPER_MACS-hmac-sha2-256} ]] && cm_opts+=(-o MACs="${PROVISIONER_HELPER_MACS-hmac-sha2-256}")
sftp_opts=(-o PreferredAuthentications=password -o PubkeyAuthentication=no
           -o NumberOfPasswordPrompts=1 -o StrictHostKeyChecking=accept-new
           -o ConnectTimeout=15 "${cm_opts[@]}" -P "$port")

HOOK_DEFAULT_IDS=(id_rsa id_ecdsa id_ecdsa_sk id_ed25519 id_ed25519_sk id_xmss id_dsa)
key_id_opt=()
if [[ -n ${PROVISIONER_HELPER_ID:-} ]]; then
  if [[ ! -f ${PROVISIONER_HELPER_ID} || ! -r ${PROVISIONER_HELPER_ID} ]]; then
    say "PROVISIONER_HELPER_ID='${PROVISIONER_HELPER_ID}' does not exist (or is unreadable) on this host — it cannot be offered to the helper; falling back to the default SSH identities"
  else
    _declared_is_default=0
    for _n in "${HOOK_DEFAULT_IDS[@]}"; do
      [[ ${PROVISIONER_HELPER_ID} == "${HOME:-/root}/.ssh/${_n}" ]] && { _declared_is_default=1; break; }
    done
    (( _declared_is_default )) || key_id_opt=(-i "${PROVISIONER_HELPER_ID}")
    unset _n _declared_is_default
  fi
fi

hook_askpass_ok() {
  local maj min
  maj="$(ssh -V 2>&1 | sed -n 's/^OpenSSH_\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1/p')"
  min="$(ssh -V 2>&1 | sed -n 's/^OpenSSH_\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\2/p')"
  [[ -n $maj && -n $min ]] || return 1
  (( maj > 8 || (maj == 8 && min >= 4) ))
}

hook_askpass_dir=""
hook_find_askpass_dir() {
  [[ -n $hook_askpass_dir ]] && { printf '%s' "$hook_askpass_dir"; return 0; }
  local d probe
  for d in ${PROVISIONER_ASKPASS_DIR:-/etc/provisioner /run ${TMPDIR:-/tmp} /tmp}; do
    [[ -n $d && -d $d && -w $d ]] || continue
    probe="$(umask 077; mktemp "${d}/.prov-askpass-probe.XXXXXX" 2>/dev/null)" || continue
    printf '#!/bin/sh\nexit 7\n' > "$probe" 2>/dev/null && chmod 700 "$probe" 2>/dev/null
    "$probe" >/dev/null 2>&1
    if [[ $? -eq 7 ]]; then rm -f "$probe"; hook_askpass_dir="$d"; printf '%s' "$d"; return 0; fi
    rm -f "$probe"
  done
  return 1
}

hook_sftp_to=()   # optional `timeout N` prefix for the session (the #1081 probe sets it)
hook_sftp_pass() {
  local ap rc
  if [[ ${PROVISIONER_HELPER_PASS_MODE:-auto} != sshpass ]] && hook_askpass_ok \
     && hook_find_askpass_dir >/dev/null && [[ -n $hook_askpass_dir ]]; then
    ap="$(umask 077; mktemp "${hook_askpass_dir}/.prov-askpass.XXXXXX" 2>/dev/null)" || return 255
    { printf '#!/bin/sh\n'
      printf '# GENERATED by hook.sh (issue #104) — carries NO credential.\n'
      printf 'IFS= read -r p < "$PROVISIONER_ASKPASS_FILE"\n'
      printf '[ -n "$p" ] || exit 1\n'
      printf 'printf %%s "$p"\n'; } > "$ap" || { rm -f "$ap"; return 255; }
    chmod 700 "$ap" || { rm -f "$ap"; return 255; }
    PROVISIONER_ASKPASS_FILE="$HELPER_PASS_FILE" SSH_ASKPASS="$ap" \
    SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-}" \
      "${hook_sftp_to[@]}" sftp "${sftp_opts[@]}" "$helper" 2>&1
    rc=$?
    rm -f "$ap"
    return $rc
  fi
  if command -v sshpass >/dev/null 2>&1; then
    "${hook_sftp_to[@]}" sshpass -f "$HELPER_PASS_FILE" sftp "${sftp_opts[@]}" "$helper" 2>&1
    return $?
  fi
  if hook_askpass_ok; then
    printf 'ssh_askpass: no executable location — every candidate directory is unwritable or mounted noexec\n'
  else
    printf 'no password transport: this OpenSSH predates SSH_ASKPASS_REQUIRE=force and sshpass is absent\n'
  fi
  return 255
}

classify_ssh_failure() {   # <output> <rc> → envfault|hostkey|auth|banned|missing|transport|unknown
  local o; o="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$o" in
    *"ssh_askpass"*|*"exec("*) printf 'envfault'; return;;
  esac
  case "$o" in
    *"host key verification failed"*|*"remote host identification has changed"*|\
    *"key verification failed"*) printf 'hostkey'; return;;
  esac
  case "$o" in
    *"permission denied"*|*"authentication failed"*|*"no more authentication methods"*|\
    *"too many authentication failures"*|*"access denied"*) printf 'auth'; return;;
  esac
  case "$o" in
    *"connection closed by"*|*"kex_exchange_identification"*|*"banner exchange"*) printf 'banned'; return;;
  esac
  case "$o" in
    *"connection refused"*|*"connection timed out"*|*"operation timed out"*|*"timed out"*|\
    *"no route to host"*|*"could not resolve"*|*"name or service not known"*|\
    *"network is unreachable"*|*"connection reset"*|*"broken pipe"*) printf 'transport'; return;;
  esac
  case "$o" in
    *"no such file"*|*"not found"*|*"couldn't stat"*|*"can't ls"*) printf 'missing'; return;;
  esac
  [[ ${2:-} == 124 ]] && { printf 'transport'; return; }   # `timeout` killed it
  printf 'unknown'
}

hook_verified_id=""       # the identity the probe was OBSERVED to authenticate with
hook_verified_how=""      # observed | inferred  (empty ⇒ nothing established)

_hook_id_scan() {
  local line tok found=""
  while IFS= read -r line; do
    case "$line" in *"$2"*) ;; *) continue;; esac
    for tok in ${line#*"$2"}; do
      [[ $tok == /* && -f $tok && -r $tok ]] || continue
      found="$tok"
    done
  done <<<"$1"
  [[ -n $found ]] && printf '%s' "$found"
}

_hook_sole_local_identity() {
  local d="${HOME:-/root}/.ssh" n found="" count=0
  for n in "${HOOK_DEFAULT_IDS[@]}"; do
    [[ -f "${d}/${n}" && -r "${d}/${n}" ]] || continue
    found="${d}/${n}"; count=$((count + 1))
  done
  (( count == 1 )) && printf '%s' "$found"
}

hook_note_verified_id() {   # <scp -v transcript>
  hook_verified_id="$(_hook_id_scan "$1" 'Server accepts key: ')"
  [[ -z $hook_verified_id ]] && hook_verified_id="$(_hook_id_scan "$1" 'public key: ')"
  if [[ -n $hook_verified_id ]]; then hook_verified_how=observed; return 0; fi
  if (( ${#key_id_opt[@]} )); then return 0; fi
  hook_verified_id="$(_hook_sole_local_identity)"
  [[ -n $hook_verified_id ]] && hook_verified_how=inferred
  return 0
}

hook_crypt_fetch_main() {
set -uo pipefail

RCLONE_VERSION="1.74.3"
RCLONE_DEB_SHA256_AMD64="408cde598307dedc26b7108553cb2147a8d2d12853100447e802f47454582ecc"

: "${HELPER:=${PROVISIONER_HELPER:-}}"
HELPER_PORT="${PROVISIONER_HELPER_PORT:-22}"
HELPER_KEY="${PROVISIONER_HELPER_ID:-${HELPER_ID:-/root/.ssh/id_ed25519}}"
HELPER_PASS_FILE="${PROVISIONER_HELPER_PASS_FILE:-/etc/provisioner/helper-pass}"
HELPER_CONNECT_TIMEOUT="${PROVISIONER_HELPER_CONNECT_TIMEOUT:-15}"
HELPER_CIPHERS="${PROVISIONER_HELPER_CIPHERS-aes128-ctr}"
HELPER_MACS="${PROVISIONER_HELPER_MACS-hmac-sha2-256}"
_HELPER_SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout="${HELPER_CONNECT_TIMEOUT}")
[ -n "$HELPER_CIPHERS" ] && _HELPER_SSH_OPTS+=(-o Ciphers="$HELPER_CIPHERS")
[ -n "$HELPER_MACS" ] && _HELPER_SSH_OPTS+=(-o MACs="$HELPER_MACS")
_HELPER_AUTH=""
P=""
_HELPER_AUTH_RE='permission denied ?\(|permission denied, please|authentication failed|no more authentication methods|too many authentication failures|access denied|unable to authenticate'
_HELPER_XPORT_RE='connection (timed out|closed|reset)|lost connection|broken pipe|connection to .* closed|no route to host|network is unreachable|banner exchange|kex_exchange|client_loop|write failed|message authentication code'

say() { printf '[crypt-fetch] %s\n' "$*" >&2; }

_helper_crypt_keyfile() { printf '%s' "${PROVISIONER_HELPER_CRYPT_KEY_FILE:-/etc/provisioner/helper-crypt-key}"; }
_helper_crypt_keyed() {
  [ -n "${PROVISIONER_HELPER_CRYPT_KEY_FILE:-}" ] && return 0
  [ "${PROVISIONER_HELPER_CRYPT:-}" = required ] && return 0
  [ -s "$(_helper_crypt_keyfile)" ]
}
_helper_crypt_alias() {
  _helper_crypt_keyed && return 1
  [ "${PROVISIONER_HELPER_ACCESS:-}" = rclone ] && return 0
  [ "$(head -n 1 "${PROVISIONER_HELPER_ACCESS_FILE:-/etc/provisioner/helper-access}" 2>/dev/null | tr -d '[:space:]')" = rclone ]
}
_helper_crypt_on() {
  _helper_crypt_keyed && return 0
  _helper_crypt_alias
}
_helper_crypt_khfile() { printf '%s' "${HOME:-/root}/.ssh/known_hosts"; }
_helper_crypt_obscure() { sed -n "${2}p" "$1" | tr -d '\r' | rclone obscure - 2>/dev/null; }
_helper_crypt_hostkey_algs() {
  local kh h spec t out=""; kh="$(_helper_crypt_khfile)"; h="${HELPER#*@}"
  case "$HELPER_PORT" in ""|22) spec="$h" ;; *) spec="[$h]:$HELPER_PORT" ;; esac
  [ -f "$kh" ] || return 0
  while read -r t; do   # read, not word-splitting: no globbing of odd known_hosts text
    case "$t" in ''|*[!A-Za-z0-9@._-]*) continue ;; esac
    [ "$t" = ssh-rsa ] && t="rsa-sha2-512 rsa-sha2-256 ssh-rsa"
    case " $out " in *" $t "*) ;; *) out="${out:+$out }$t" ;; esac
  done < <(ssh-keygen -F "$spec" -f "$kh" 2>/dev/null | awk '$1 !~ /^[#@]/ {print $2}')
  [ -z "$out" ] || printf 'host_key_algorithms = %s\n' "$out"
  return 0
}
_helper_crypt_sftp_stanza() {
  local kh ob; kh="$(_helper_crypt_khfile)"
  printf '[prov-sftp]\ntype = sftp\nhost = %s\nuser = %s\nport = %s\n' "${HELPER#*@}" "${HELPER%%@*}" "$HELPER_PORT"
  if [ "$_HELPER_AUTH" = password ]; then
    ob="$(_helper_crypt_obscure "$HELPER_PASS_FILE" 1)"; [ -n "$ob" ] || return 1
    printf 'pass = %s\n' "$ob"
  else
    printf 'key_file = %s\n' "$HELPER_KEY"
  fi
  [ -n "$HELPER_CIPHERS" ] && printf 'ciphers = %s\n' "${HELPER_CIPHERS//,/ }"
  [ -n "$HELPER_MACS" ] && printf 'macs = %s\n' "${HELPER_MACS//,/ }"
  printf 'known_hosts_file = %s\n' "$kh"
  _helper_crypt_hostkey_algs
  printf 'set_modtime = false\ndisable_hashcheck = true\n'
  return 0
}
_helper_crypt_remote_stanza() {   # <obscured password> [<obscured salt>]
  printf '[prov-crypt]\ntype = crypt\nremote = prov-sftp:\nfilename_encryption = standard\ndirectory_name_encryption = true\npassword = %s\n' "$1"
  [ -z "${2:-}" ] || printf 'password2 = %s\n' "$2"
}
_helper_crypt_looks_encrypted() {
  local t; t="$(cat)"
  grep -qxE '(scripts|secrets|images|state|restic|version|version-built|downloads)/?' <<<"$t" && return 1
  grep -qE '^[0-9a-v]{26,}/?$' <<<"$t"
}
_helper_crypt_alias_stanza() { printf '[prov-crypt]\ntype = alias\nremote = prov-sftp:\n'; }
_helper_crypt_local() { case "$1" in /*|./*) printf '%s' "$1" ;; *) printf './%s' "$1" ;; esac; }
_helper_crypt_p() {
  local p="$1"
  while :; do case "$p" in /*) p="${p#/}" ;; ./*) p="${p#./}" ;; *) break ;; esac; done
  case "$p" in .) p="" ;; esac
  case "/${p}/" in */../*) return 1 ;; esac
  printf 'prov-crypt:%s' "${p%/}"
}

_crypt_hostspec() { case "${2-}" in ""|22) printf '%s\n' "$1" ;; *) printf '[%s]:%s\n' "$1" "$2" ;; esac; }

_crypt_hostkey() {
  local kh spec; kh="$(_helper_crypt_khfile)"; spec="$(_crypt_hostspec "${HELPER#*@}" "$HELPER_PORT")"
  ssh-keygen -F "$spec" -f "$kh" >/dev/null 2>&1 && return 0
  mkdir -p "$(dirname "$kh")" 2>/dev/null
  ssh -n -o BatchMode=yes -o PreferredAuthentications=none -o PubkeyAuthentication=no \
      -o UserKnownHostsFile="$kh" -p "$HELPER_PORT" "${_HELPER_SSH_OPTS[@]}" "$HELPER" true >/dev/null 2>&1
  ssh-keygen -F "$spec" -f "$kh" >/dev/null 2>&1
}

_scrub() { local t h="${HELPER#*@}" u="${HELPER%%@*}"; t="$(cat)"; t="${t//"$HELPER"/HELPER}"; t="${t//"$h"/HELPER}"; t="${t//"$u@"/HELPER@}"; printf '%s\n' "$t"; }

ensure_rclone() {
  command -v rclone >/dev/null 2>&1 && return 0     # any rclone speaks crypt; the role pins the fleet's
  [ "$(dpkg --print-architecture 2>/dev/null)" = amd64 ] \
    || { say "no rclone here and only the amd64 package is pinned (#1075) - install rclone by hand"; return 4; }
  local d deb url got
  d="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/prov-rclone-dl.XXXXXX")" || { say "cannot make a scratch dir"; return 4; }
  deb="${d}/rclone.deb"
  url="https://downloads.rclone.org/v${RCLONE_VERSION}/rclone-v${RCLONE_VERSION}-linux-amd64.deb"
  if command -v curl >/dev/null 2>&1; then curl -fsSL --connect-timeout 15 --max-time 300 -o "$deb" "$url"
  else wget -q -T 60 -O "$deb" "$url"; fi || { rm -rf "$d"; say "could not download the pinned rclone ${RCLONE_VERSION} (retryable)"; return 1; }
  got="$(sha256sum "$deb" 2>/dev/null | cut -d' ' -f1)"
  [ "$got" = "$RCLONE_DEB_SHA256_AMD64" ] || { rm -rf "$d"; say "the downloaded rclone ${RCLONE_VERSION} does not match its pinned sha256 - refusing it"; return 4; }
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout="${PROVISIONER_APT_LOCK_WAIT:-300}" -o Dpkg::Use-Pty=0 install -y -qq "$deb" >/dev/null 2>&1 \
    || dpkg -i "$deb" >/dev/null 2>&1
  rm -rf "$d"
  command -v rclone >/dev/null 2>&1 || { say "installing rclone ${RCLONE_VERSION} failed"; return 4; }
}

crypt_get() {
  local auth="$1" remote="$2" dst="$3" kf rp rc err kind
  [ -n "$HELPER" ] || { say "no helper address in the environment"; return 4; }
  _HELPER_AUTH="$auth"
  case "$auth" in
    password) [ -s "$HELPER_PASS_FILE" ] || { say "no helper password file"; return 4; } ;;
    key)      [ -s "$HELPER_KEY" ] || { say "no helper key file"; return 4; } ;;
    *) say "auth must be key or password"; return 4 ;;
  esac
  kf="$(_helper_crypt_keyfile)"
  if ! _helper_crypt_alias; then   # #1202: the plain access path has no key to check
    [ -s "$kf" ] || { say "crypt key file missing or empty - refusing to fall back to PLAINTEXT"; return 4; }
    [ -z "$(find "$kf" -maxdepth 0 -perm /077 2>/dev/null)" ] || { say "crypt key file is group/other accessible - chmod 600"; return 4; }
  fi
  command -v rclone >/dev/null 2>&1 || { say "rclone is not installed"; return 4; }
  rp="$(_helper_crypt_p "$remote")" || { say "refused path"; return 4; }
  _crypt_hostkey || { say "no host key on record for the helper and first contact did not record one - refusing an unverified host"; return 5; }
  umask 077
  local d o
  while IFS= read -r d; do
    o="$(cat "$d/owner" 2>/dev/null)"; { [ -n "$o" ] && kill -0 "$o" 2>/dev/null; } && continue
    rm -rf "$d"
  done < <(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'prov-rclone.*' -user "$(id -u)" -mmin +"${PROVISIONER_HELPER_CRYPT_STALE_MIN:-120}" 2>/dev/null)
  D="$(mktemp -d "${TMPDIR:-/tmp}/prov-rclone.XXXXXX")" || { say "cannot make a scratch dir"; return 4; }
  printf '%s' "$$" > "$D/owner"
  DST="$dst"; TMPDST="${dst}.prov-part.$$"
  trap 'rm -rf "$D"' EXIT
  trap 'kill "$P" 2>/dev/null; rm -rf "$D"; rm -f "$TMPDST" "$DST".prov-part.*; exit 130' INT; trap 'kill "$P" 2>/dev/null; rm -rf "$D"; rm -f "$TMPDST" "$DST".prov-part.*; exit 143' TERM; trap 'kill "$P" 2>/dev/null; rm -rf "$D"; rm -f "$TMPDST" "$DST".prov-part.*; exit 129' HUP
  local pw="" salt="" want=""
  if ! _helper_crypt_alias; then
    pw="$(_helper_crypt_obscure "$kf" 1)"; salt="$(_helper_crypt_obscure "$kf" 2)"; want="$(sed -n 2p "$kf" | tr -d '\r')"
    { [ -n "$pw" ] && { [ -z "$want" ] || [ -n "$salt" ]; }; } || { say "the crypt key file could not be obscured"; return 4; }
  fi
  ( umask 077
    { _helper_crypt_sftp_stanza || exit 1
      if _helper_crypt_alias; then _helper_crypt_alias_stanza; else _helper_crypt_remote_stanza "$pw" "$salt"; fi
    } > "${D}/rclone.conf" ) 2>/dev/null || { say "could not build the rclone config"; return 4; }
  chmod 600 "${D}/rclone.conf"
  if _helper_crypt_alias; then   # #1202: an encrypted folder read without its key looks empty - refuse, do not call it "not there"
    rclone --config "${D}/rclone.conf" --contimeout "${HELPER_CONNECT_TIMEOUT}s" --retries 1 --low-level-retries 1 lsf prov-crypt: 2>/dev/null </dev/null | _helper_crypt_looks_encrypted \
      && { say "this folder is encrypted; the access path without a key would read it as empty - refusing (#1202)"; return 4; }
  fi
  timeout -k 5 "${PROVISIONER_CRYPT_FETCH_TIMEOUT:-120}" rclone --config "${D}/rclone.conf" --contimeout "${HELPER_CONNECT_TIMEOUT}s" --retries 1 --low-level-retries 1 \
    copyto -- "$rp" "$(_helper_crypt_local "$TMPDST")" >/dev/null 2>"${D}/err" </dev/null &
  P=$!; wait "$P"; rc=$?
  [ "$rc" = 0 ] && { [ -s "$TMPDST" ] && mv -f "$TMPDST" "$dst" && return 0; rm -f "$TMPDST"; say "rclone exited 0 but ${dst} is empty or missing"; return 1; }
  err="$(_scrub < "${D}/err")"
  if grep -qiE "$_HELPER_AUTH_RE" <<<"$err"; then kind=auth
  elif grep -qiE 'knownhosts|host key|key mismatch' <<<"$err"; then kind=hostkey
  elif grep -qiE "$_HELPER_XPORT_RE" <<<"$err"; then kind=xport
  else case "$rc" in 124|137|255) kind=xport ;; 3|4) kind=missing ;; *) kind=other ;; esac; fi
  rm -f "$TMPDST" "$DST".prov-part.*
  case "$kind" in
    auth)    say "the helper refused the credential"; return 2 ;;
    hostkey) say "the helper's host key does not match the one on record"; return 5 ;;
    missing) say "not there on the helper"; return 3 ;;
    *)       say "transport failure (rclone rc ${rc}): $(tail -1 <<<"$err" | cut -c1-160)"; return 1 ;;
  esac
}

case "${1:-}" in
  on)            _helper_crypt_on ;;
  keyed)         _helper_crypt_keyed ;;   # #1202: told apart from the plain access path
  ensure-rclone) ensure_rclone ;;
  get)           [ "$#" = 4 ] || { say "usage: get <key|password> <remote> <local>"; exit 4; }; crypt_get "$2" "$3" "$4" ;;
  *)             say "usage: on | ensure-rclone | get <key|password> <remote> <local>"; exit 4 ;;
esac
}
hook_crypt() { bash -c "$(declare -f hook_crypt_fetch_main); hook_crypt_fetch_main \"\$@\"" helper-crypt-fetch "$@"; }
hook_crypt_on() { hook_crypt on; }
hook_access_path_only() { hook_crypt_on && ! hook_crypt keyed; }
hook_crypt_get() {
  HELPER="$helper" PROVISIONER_HELPER_PORT="$port" PROVISIONER_HELPER_PASS_FILE="$HELPER_PASS_FILE" \
    PROVISIONER_HELPER_ID="$hook_crypt_key" hook_crypt get "$@"
}
hook_crypt_key=""
hook_crypt_pick_key() {
  hook_crypt_key=""
  if [[ -n ${PROVISIONER_HELPER_ID:-} && -s ${PROVISIONER_HELPER_ID} ]]; then hook_crypt_key="$PROVISIONER_HELPER_ID"
  else hook_crypt_key="$(_hook_sole_local_identity)"; fi
}
hook_crypt_fetch_one() {   # <remote> <local>
  local rc=4
  hook_crypt_pick_key
  if [[ $auth_hint != password && -n $hook_crypt_key ]]; then
    hook_crypt_get key "$1" "$2"; rc=$?
    if (( rc == 0 )); then hook_verified_id="$hook_crypt_key"; hook_verified_how=observed; hook_probe_via=crypt-key; return 0; fi
    (( rc == 2 || rc == 4 )) || return "$rc"      # auth refused / no key usable: try the password
  fi
  [[ -s $HELPER_PASS_FILE ]] || return "$rc"
  hook_crypt_get password "$1" "$2"; rc=$?
  (( rc == 0 )) && hook_probe_via=crypt-password
  return "$rc"
}
hook_crypt_probe() {   # <workdir> <cand0> <cand1>
  local w="$1" i rc worst=0 c
  for i in 0 1; do
    c="${2}"; (( i )) && c="${3}"
    hook_crypt_fetch_one "${c:+${c}/}scripts/helper-lib.sh" "${w}/c${i}"; rc=$?
    case "$rc" in
      0) ;;
      3) printf 'remote open("%s"): No such file or directory\n' "$c" ;;
      2) printf 'Permission denied (password).\n'; worst=255   # a refused login ends the probe: a second candidate would be a second sign-in (#1203)
         log "the helper REFUSED the login - not retried on the second candidate (#1201, #1203)"; break ;;
      4) printf 'crypt mode could not run (see above)\n'; worst=255 ;;
      5) printf 'Host key verification failed.\n'; worst=255 ;;
      *) printf 'Connection timed out\n'; worst=255 ;;
    esac
  done
  return "$worst"
}
hook_crypt_ensure() { hook_crypt ensure-rclone; }

fetch_fail_reason=""    # human-readable "why" for the last fetch_lib failure
banner_closes=0         # how many times the helper hung up on us (see the 'banned' class)
hook_probe_knock=0      # 1 once the #877 probe has spent a failed login (see below)
fetch_lib() {
  fetch_fail_reason=""
  local out rc key_fail=""
  if hook_crypt_on; then
    if (( RD_PROBE )); then
      hook_probe_remote_dir "$estate"; rc=$?
      (( rc == 0 )) || return "$rc"
      (( hook_probe_have_lib )) && [[ -s ./helper-lib.sh ]] && return 0
    fi
    hook_crypt_fetch_one "$LIB_REMOTE" ./helper-lib.sh; rc=$?
    case "$rc" in
      0) return 0 ;;
      1) fetch_fail_reason="the encrypted helper fetch hit a transport fault"; return 1 ;;
      2) fetch_fail_reason="the helper refused every credential offered through the encrypted path"; return 2 ;;
      *) fetch_fail_reason="the encrypted helper fetch failed for a reason that is not the credential (rc ${rc}; see the [crypt-fetch] line above) - not there, a moved host key, or a local fault"; return 3 ;;
    esac
  fi
  if (( RD_PROBE )); then
    hook_probe_remote_dir "$estate"; rc=$?
    (( rc == 0 )) || return "$rc"
    (( hook_probe_have_lib )) && [[ -s ./helper-lib.sh ]] && return 0
  fi
  if [[ $auth_hint != password ]]; then
    out="$(timeout "${PROVISIONER_HELPER_PROBE_TIMEOUT:-25}" \
      scp -v -P "$port" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o BatchMode=yes \
        "${cm_opts[@]}" "${key_id_opt[@]}" \
        "${helper}:${LIB_REMOTE}" ./helper-lib.sh 2>&1)"; rc=$?
    if [[ $rc -eq 0 && -s ./helper-lib.sh ]]; then
      hook_note_verified_id "$out"     # read the winner off the conversation that just worked
      return 0
    fi
    rm -f ./helper-lib.sh
    key_fail="$(classify_ssh_failure "$out" "$rc")"
  fi

  if [[ ! -s $HELPER_PASS_FILE ]]; then
    fetch_fail_reason="key auth did not work (${key_fail:-no key attempt}) and no helper password is available at ${HELPER_PASS_FILE}"
    return 2
  fi
  out="$(printf 'get %s ./helper-lib.sh\n' "$LIB_REMOTE" | hook_sftp_pass)"; rc=$?
  [[ $rc -eq 0 && -s ./helper-lib.sh ]] && return 0
  rm -f ./helper-lib.sh
  local class; class="$(classify_ssh_failure "$out" "$rc")"
  [[ $rc -eq 0 && $class == auth ]] && class=missing
  case "$class" in
    envfault)
      fetch_fail_reason="a LOCAL environment fault, NOT a bad password: OpenSSH could not execute the askpass helper.
This normally means the directory it was written to is mounted 'noexec'.
  askpass directory tried : ${hook_askpass_dir:-<none found>}
  check it with           : findmnt -no OPTIONS ${hook_askpass_dir:-/tmp}
  fix                     : PROVISIONER_ASKPASS_DIR=<a dir on an exec-capable mount>, or install sshpass
Your helper password has been KEPT — it was never the problem.
  ssh said: $(printf '%s' "$out" | tr '\n' ';')"
      return 3;;
    hostkey)
      fetch_fail_reason="the helper's HOST KEY does not match ~/.ssh/known_hosts — not a password problem.
This host's known_hosts is only ever appended to (ssh-keyscan), never pruned, and this estate's
helper/host keys churn on reinstall (issue #28). Drop the stale entry and re-run:
  ssh-keygen -R '[${helper_server}]:${port}' ; ssh-keygen -R '${helper_server}'
Your helper password has been KEPT — it was never the problem."
      return 3;;
    banned)
      banner_closes=$((banner_closes + 1))
      fetch_fail_reason="the helper closed the connection at/near the SSH banner: $(printf '%s' "$out" | tr '\n' ';')"
      if (( banner_closes >= 2 )); then
        fetch_fail_reason="${fetch_fail_reason}
This repeated at/near the banner, which is what a helper-side BAN looks like (proftpd mod_ban /
MaxLoginAttempts drop the connection before auth). Stopping rather than knocking further — the
block is usually time-limited; wait it out and re-run. Your helper password has been KEPT."
        return 3
      fi
      return 1;;
    auth)
      fetch_fail_reason="the helper REJECTED the password (authentication failed)" ; return 2;;
    missing)
      local _rd_hint=""
      if (( RD_FACT_HAVE )) && [[ $RD_FACT != "$_RD" ]]; then
        _rd_hint="
  this box says : '${RD_FACT}'  (${RD_FACT_FILE} — staged by the lap that set this estate up)
THE TWO DISAGREE, and the box's own fact is the better bet. Re-run the one-liner with
  PROVISIONER_REMOTE_DIR='${RD_FACT}'
and do NOT re-stage anything until that has been tried."
      elif (( RD_FACT_UNREADABLE )); then
        _rd_hint="
  NOTE: this box carries ${RD_FACT_FILE} — which names the layout — and it could not be READ
  (check it with: ls -l ${RD_FACT_FILE}). Settle that before concluding the scripts are gone."
      fi
      fetch_fail_reason="authenticated fine, but the boot scripts could not be read from the helper. The LOGIN worked, so this is about WHERE this run looked, not who it logged in as.
  looked in     : '${_RD:-<the helper login/chroot root>}' — i.e. ${LIB_REMOTE}
  that came from: ${RD_SRC:-a remote dir resolved before this run}${_rd_hint}
Your helper password has been KEPT — it was never the problem.
BEFORE RE-STAGING ANYTHING, CHECK WHICH DIRECTORY IS ACTUALLY EMPTY. A deploy aimed at a wrongly
resolved remote dir writes this estate's boot scripts into the SHARED PARENT account, where it
reports success and every other estate can then read them (issue #313). Re-run genesis.sh's
deploy ONLY once the directory named above is confirmed to be this estate's own and confirmed
empty." ; return 3;;
    transport)
      fetch_fail_reason="transport error reaching the helper: $(printf '%s' "$out" | tr '\n' ';')" ; return 1;;
    *)
      fetch_fail_reason="unrecognised failure (could not tell auth from transport): $(printf '%s' "$out" | tr '\n' ';')"
      [[ ${PROVISIONER_HOOK_RETRY_UNKNOWN:-0} == 1 ]] && return 1
      return 2;;
  esac
}

hook_find_askpass_dir >/dev/null || true

_pw_probe_offered_password() {   # <transcript> → 1 ONLY when a method list proves otherwise
  local o list
  o="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$o" in *"permission denied ("*) ;; *) return 0;; esac   # no list ⇒ cannot tell ⇒ refusal
  list="${o##*permission denied (}"; list="${list%%)*}"
  case ",${list//[[:space:]]/}," in *,password,*) return 0;; esac
  return 1
}

pw_probe_out=""; pw_probe_rc=0; pw_probe_class=""; pw_probe_fate=""; pw_probe_why=""
if [[ -s $HELPER_PASS_FILE ]] && hook_access_path_only; then
  log "access path: the password is proven by the first fetch, not by a separate sign-in (#1203)"
elif [[ -s $HELPER_PASS_FILE ]]; then
  pw_probe_out="$(printf 'exit\n' | hook_sftp_pass)"; pw_probe_rc=$?
  pw_probe_class="$(classify_ssh_failure "$pw_probe_out" "$pw_probe_rc")"
  if [[ $pw_probe_class == auth ]] && ! _pw_probe_offered_password "$pw_probe_out"; then
    pw_probe_why="the helper turned the LOGIN down without offering a password method at all, so this password was never actually tried"
  elif [[ $pw_probe_class != auth ]]; then
    pw_probe_why="$pw_probe_class"
  fi
  if [[ $pw_probe_rc -eq 0 ]]; then
    log "the helper accepted the password"
  elif [[ -z $pw_probe_why ]]; then
    if [[ $hook_collected_pass == 1 ]]; then
      rm -f "$HELPER_PASS_FILE"; hook_collected_pass=0
      pw_probe_fate="The password you just typed has been DISCARDED — it was this run's own to discard. Re-run the one-liner and enter the current one."
    else
      pw_probe_fate="The password staged at ${HELPER_PASS_FILE} has been KEPT: a pre-staged credential is the operator's, never this script's to delete. Correct that file (root-only, 0600) and re-run the one-liner:
  install -m 600 /dev/null ${HELPER_PASS_FILE} && printf '%s' '<password>' > ${HELPER_PASS_FILE}"
    fi
    die "the helper REFUSED this password — nothing has been provisioned.
No VM, no user, no sshd change, and not one byte fetched: this was a password-only login against ${helper} on :${port}, made exactly once, before the bootstrap fetched anything.
${pw_probe_fate}
WHY THIS STOPS THE RUN RATHER THAN CARRYING ON (issue #877). The helper may well accept this box's KEY and let the whole bootstrap complete — that is precisely how a stale password reached a live estate on 2026-09-19. The password is a credential in its OWN right: rclone's sftp backend, which backs the players up, can authenticate with nothing else. Carried untested it fails ninety minutes later, inside the VMs, with nothing on the console pointing back here.
NOT retrying: each attempt is a real login against the helper and repeated failures can get this estate's IP banned by the helper's provider (issues #87/#90)."
  else
    warn "could not verify the password (${pw_probe_why}: $(printf '%s' "$pw_probe_out" | tr '\n' ';')) — continuing; the first password-only consumer is the players' backup tool"
    hook_probe_knock=1
    [[ $pw_probe_class == banned ]] && banner_closes=1
  fi
fi
unset pw_probe_out pw_probe_rc pw_probe_class pw_probe_fate pw_probe_why

hook_probe_have_lib=0   # 1 = the probe left a verified ./helper-lib.sh
hook_probe_via=""   # key | password: which session answered (set by hook_probe_transport)
hook_probe_transport() {   # stdin: sftp `get` lines -> transcript on stdout, the session's rc
  local cmds out="" rc=255 t="${PROVISIONER_HELPER_PROBE_TIMEOUT:-25}"
  cmds="$(cat)"; hook_probe_via=""
  if [[ $auth_hint != password ]]; then
    out="$(printf '%s\n' "$cmds" | sed 's/^/-/' | timeout "$t" \
      sftp -v -b - -P "$port" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o BatchMode=yes \
        "${cm_opts[@]}" "${key_id_opt[@]}" "$helper" 2>&1)"; rc=$?
    if [[ $rc -eq 0 ]]; then hook_probe_via=key; printf '%s\n' "$out"; return 0; fi
    case "$(classify_ssh_failure "$out" "$rc")" in transport|banned) printf '%s\n' "$out"; return "$rc";; esac
  fi
  if [[ -s $HELPER_PASS_FILE ]]; then
    hook_sftp_to=(timeout "$t")
    hook_sftp_pass <<<"$cmds"; rc=$?
    hook_sftp_to=()
    (( rc == 0 )) && hook_probe_via=password
    return $rc
  fi
  printf '%s\n' "$out"; return "$rc"
}
hook_crypt_folder_looks_encrypted() {   # <candidate dir> <login root listing too>
  local out names n
  out="$(hook_probe_transport <<<"ls -1 ${1:-.}"$'\n'"ls -1 .")" || return 1
  names="$(grep -E '^[A-Za-z0-9._=-]+/?$' <<<"$out")"
  [[ -n $names ]] || return 1
  for n in scripts secrets images state version downloads; do
    grep -qx "$n/\?" <<<"$names" && return 1
  done
  return 0
}
hook_probe_remote_dir() {   # <estate> — sets _RD, RD_SRC and the derived paths, or returns/dies
  local est="${1:-}" work out rc cmds="" i nf missing=0 cand
  local -a cands=("${HELPER_DEFAULT_SSH_RD}/${est}" "") verdict=()
  [[ $est =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $est != *..* ]] \
    || die "cannot look for this estate's folder on the helper: the estate name '${est}' is not a plain name. Re-run with PROVISIONER_REMOTE_DIR set (empty for a per-estate login root)."
  work="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/.prov-rdprobe.XXXXXX")" \
    || die "cannot create a scratch directory to probe the helper's layout in (${TMPDIR:-/tmp})"
  for i in 0 1; do
    cmds+="get ${cands[i]:+${cands[i]}/}scripts/helper-lib.sh ${work}/c${i}"$'\n'
  done
  if hook_crypt_on; then hook_crypt_probe "$work" "${cands[0]}" "${cands[1]}" > "${work}/out"; rc=$?   # crypt mode (#1075)
  else hook_probe_transport <<<"$cmds" > "${work}/out"; rc=$?; fi
  out="$(<"${work}/out")"
  nf="$(grep -c -i -e 'no such file' -e 'not found' <<<"$out")"
  for i in 0 1; do [[ -s ${work}/c${i} ]] || missing=$((missing + 1)); done
  for i in 0 1; do
    if [[ -s ${work}/c${i} ]]; then verdict[i]=present
    elif [[ $rc -eq 0 && ${nf:-0} -ge $missing ]]; then verdict[i]=absent
    else verdict[i]=unknown; fi
  done
  local keep="" both=0
  for i in 0 1; do [[ ${verdict[i]} == present ]] && keep="${work}/c${i}"; done
  if [[ ${verdict[0]} == present && ${verdict[1]} == present ]]; then both=1; keep="${work}/c0"; fi
  if [[ -n $keep && ( $both -eq 1 || ${verdict[0]} != "${verdict[1]}" ) ]]; then
    cp "$keep" ./helper-lib.sh 2>/dev/null && [[ -s ./helper-lib.sh ]] || { rm -f ./helper-lib.sh; keep=""; }
  else keep=""; fi
  rm -rf "$work"
  local where0="'${cands[0]}'" where1="the helper login root"
  if (( both )); then
    warn "the helper login root also holds boot scripts; ignored, this estate's own folder ${where0} wins (a leftover, issue #1081)"
    verdict[1]=absent
  fi
  if [[ ${verdict[0]} == unknown || ${verdict[1]} == unknown ]]; then
    fetch_fail_reason="could not tell where this estate's boot scripts are on the helper: ${where0} was '${verdict[0]}' and ${where1} '${verdict[1]}' ('could not list' is not 'absent', issue #1081).
  failure class: $([[ $rc -ne 0 ]] && classify_ssh_failure "$out" "$rc" || printf 'listing refused (session completed)') — the transcript is not printed: it names the helper's address.
Nothing has been fetched or changed. Fix the cause, or name the directory: re-run with PROVISIONER_REMOTE_DIR=<dir> (empty for a per-estate login root)."
    if [[ $rc -ne 0 ]]; then
      case "$(classify_ssh_failure "$out" "$rc")" in
        transport) return 1;;
        banned)
          banner_closes=$((banner_closes + 1))
          (( banner_closes >= 2 )) && return 3
          return 1;;
      esac
    fi
    return 3
  fi
  for i in 0 1; do
    [[ ${verdict[i]} == present ]] || continue
    _RD="${cands[i]}"
    cand="${_RD:-the helper login root}"
    RD_SRC="probing the helper — ${cand} holds scripts/helper-lib.sh and the other candidate does not (issue #1081)"
    say "helper remote dir: found this estate's boot scripts in ${cand} (nothing was typed or set; both layouts were checked)"
    SCRIPTS_REMOTE="${_RD:+${_RD}/}scripts"
    SECRETS_REMOTE="${_RD:+${_RD}/}secrets"
    LIB_REMOTE="${SCRIPTS_REMOTE}/helper-lib.sh"
    DEPLOY_KEY_REMOTE="${SECRETS_REMOTE}/github_deploy"
    VERSION_REMOTE="${_RD:+${_RD}/}version"
    RD_PROBE=0
    [[ $hook_probe_via == key && -n $keep ]] && hook_note_verified_id "$out"
    [[ -n $keep ]] && hook_probe_have_lib=1
    return 0
  done
  if ! hook_crypt keyed && hook_crypt_folder_looks_encrypted "${cands[0]}"; then
    die "this estate's boot scripts are not on the helper, and the folder holds only names this estate does not use. That is how an encrypted folder looks, but it can also be a folder that was never staged. This host has no encryption key. If the folder is encrypted: set PROVISIONER_HELPER_CRYPT_KEY_FILE to the key file, or run again from a terminal and choose 't' (first remove ${HELPER_CRYPT_NONE} if it exists, or you will not be asked, issue #1076). If it is not encrypted: stage the boot scripts there (issue #313). Nothing was written to the helper."
  fi
  die "this estate's boot scripts are on the helper in NEITHER place it looked: ${where0} (shared account, one folder per estate) nor ${where1} (per-estate account). The login worked; scripts/helper-lib.sh is in neither.
Nothing has been fetched or changed. Check what is staged where before re-staging anything (issue #313), or name the directory: PROVISIONER_REMOTE_DIR=<dir>."
}
attempts=$hook_probe_knock
if hook_crypt_on; then
  hook_crypt_ensure || die "this host has an estate crypt key but rclone could not be installed (see the [crypt-fetch] line above) - install rclone by hand and re-run the one-liner"
fi
max_attempts="${PROVISIONER_HOOK_FETCH_MAX_ATTEMPTS:-5}"
[[ $max_attempts =~ ^[0-9]+$ ]] && (( max_attempts >= 1 )) || max_attempts=5
while :; do
  fetch_lib; fetch_rc=$?
  [[ $fetch_rc -eq 0 ]] && break
  if [[ $fetch_rc -eq 3 ]]; then
    die "could not fetch helper-lib.sh — ${fetch_fail_reason}"
  fi
  if [[ $fetch_rc -eq 2 ]]; then
    if [[ $hook_collected_pass == 1 ]]; then rm -f "$HELPER_PASS_FILE"; hook_collected_pass=0; fi
    die "could not fetch helper-lib.sh — ${fetch_fail_reason}.
NOT retrying: each attempt is a real login against the helper and repeated failures can get
this estate's IP banned by the helper's provider. Fix the cause and re-run the one-liner."
  fi
  attempts=$((attempts + 1))
  if (( attempts >= max_attempts )); then
    die "could not fetch helper-lib.sh after ${attempts} attempts — ${fetch_fail_reason}"
  fi
  say "retrying in 3s (attempt ${attempts}/${max_attempts}) — ${fetch_fail_reason}"
  sleep 3
done

echo "$helper" > "$HELPER_CACHE"
[[ $port != 22 ]] && echo "$port" > "$PORT_CACHE"

export HELPER="$helper"
export PROVISIONER_HELPER_PORT="$port"
if [[ -n $hook_verified_id ]]; then
  if [[ $hook_verified_how == observed \
        && -n ${PROVISIONER_HELPER_ID:-} && ${PROVISIONER_HELPER_ID} != "$hook_verified_id" ]]; then
    say "the helper accepted '${hook_verified_id}', not the declared PROVISIONER_HELPER_ID='${PROVISIONER_HELPER_ID}' — threading the one that actually authenticated"
  fi
  export PROVISIONER_HELPER_ID="$hook_verified_id"
  log "helper key auth ${hook_verified_how} to use ${hook_verified_id} — threading it to the rest of the chain"
elif [[ -n ${PROVISIONER_HELPER_ID:-} ]]; then
  export PROVISIONER_HELPER_ID
  log "no helper key identity was established this run — passing the declared PROVISIONER_HELPER_ID='${PROVISIONER_HELPER_ID}' through unchanged (this file did not verify it)"
elif [[ -s /root/.ssh/id_provisioner_ed25519 ]]; then
  export PROVISIONER_HELPER_ID="/root/.ssh/id_provisioner_ed25519"
  log "no key identity was established this run, but the #61 per-install key exists — threading /root/.ssh/id_provisioner_ed25519 (this file did not verify it)"
elif [[ $auth_hint == password ]]; then
  log "helper auth is 'password' — no key was offered, so no key path is threaded (helper-lib will use its own default only if it ever needs one)"
elif [[ -s $HELPER_PASS_FILE ]]; then
  log "the helper answered the PASSWORD, not a key — no key path is threaded"
else
  say "key auth to the helper worked, but this host could not tell WHICH identity was accepted — not threading a key path. If a later stage cannot reach the helper, set PROVISIONER_HELPER_ID to the key that is authorized there and re-run."
fi
[[ -s $HELPER_PASS_FILE ]] && export PROVISIONER_HELPER_PASS_FILE="$HELPER_PASS_FILE"
[[ -n $auth_hint ]] && export PROVISIONER_HELPER_AUTH="$auth_hint" PROVISIONER_HELPER_AUTH_SRC="$auth_hint_src"
export PROVISIONER_HELPER_AUTH_CACHE="${PROVISIONER_HELPER_AUTH_CACHE:-$HELPER_AUTH_CACHE}"
export PROVISIONER_REMOTE_DIR="$_RD"
. ./helper-lib.sh


PREREPO_FINGERPRINTS=""
_log_prerepo_fingerprints() {
  local f h out=""
  if ! command -v sha256sum >/dev/null 2>&1; then
    log "pre-repo script fingerprints: no sha256sum on this host — skipping (issue #169)"
    return 0
  fi
  for f in helper-lib.sh; do
    if [[ -f "./${f}" ]]; then
      h="$(sha256sum "./${f}" 2>/dev/null)" && h="${h%% *}" || h=""
      out+=" ${f}=${h:0:12}"
      [[ -n $h ]] || out+="unhashable"
      [[ -n $h ]] && PREREPO_FINGERPRINTS+="${f} ${h}"$'\n'
    else
      out+=" ${f}=absent"
    fi
  done
  log "pre-repo script fingerprints (sha256/12, as staged on the helper — issue #169):${out} — compared against the checkout once it exists (issue #428)"
  return 0
}
_log_prerepo_fingerprints

_hd_err="$(mktemp 2>/dev/null)" || _hd_err=/dev/null
helper_detect 2>"$_hd_err"; _hd_rc=$?
_hd_last=""
if [[ -s $_hd_err ]]; then
  cat "$_hd_err" >&2
  while IFS= read -r _hd_line; do
    _hook_log_file "$_hd_line"
    [[ $_hd_line == "[helper-lib]"* ]] && _hd_last="$_hd_line"
  done < "$_hd_err"
fi
[[ $_hd_err == /dev/null ]] || rm -f "$_hd_err"
if (( _hd_rc == 0 )); then
  milestone "seedbox reachable (auth=$(helper_auth), channel=$(helper_channel)) — cold start begins for ${estate}"
else
  die "cannot reach helper '${helper}' on port ${port} — the deploy key and the seed images both live there, so nothing can proceed.
${_hd_last:+Last library line: ${_hd_last}
}Read the [helper-lib] line above for WHICH fault this is: a refused/unanswered port means nothing was listening and neither the key ('${PROVISIONER_HELPER_ID:-<none threaded>}') nor the password ('${HELPER_PASS_FILE}') was tried — check PROVISIONER_HELPER_PORT before either of them (issue #143).
Nothing has been changed on this host."
fi

ref_is_sane() {
  local r="${1:-}" t
  [[ -n $r ]] || return 1
  [[ $r == *..* ]] && return 1
  [[ $r =~ ^[A-Za-z0-9][A-Za-z0-9._/+-]{0,127}$ ]] || return 1
  t="${r#refs/tags/}"; t="${t#tags/}"
  [[ $t =~ ^[vV]?[0-9]+\.[0-9]+(\.[0-9]+)*([-+].*)?$ && ! $t =~ ^[0-9]{2}\.(0[1-9]|1[0-2])\.(00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})$ ]] && return 1
  return 0
}

PROVISIONER_VERSION="${PROVISIONER_VERSION:-}"
version_src=""
if [[ -n $PROVISIONER_VERSION ]]; then
  version_src="env"
else
  _ver_tmp="$(mktemp)" || _ver_tmp=""
  if [[ -n $_ver_tmp ]] && helper_get "$VERSION_REMOTE" "$_ver_tmp" 2>/dev/null && [[ -s $_ver_tmp ]]; then
    PROVISIONER_VERSION="$(head -n 1 "$_ver_tmp" | tr -d '[:space:]')"
    version_src="helper"
  fi
  [[ -n $_ver_tmp ]] && rm -f "$_ver_tmp"
  unset _ver_tmp
fi

case "$PROVISIONER_VERSION" in
  newest|NEWEST) log "version pointer says 'newest' (from ${version_src}) — building the repo's default branch (issue #232)"; PROVISIONER_VERSION=""; version_src="" ;;
esac

version_where="the environment (PROVISIONER_VERSION)"
[[ $version_src == helper ]] && version_where="the helper's version pointer (${VERSION_REMOTE})"
if [[ -n $PROVISIONER_VERSION ]] && ! ref_is_sane "$PROVISIONER_VERSION"; then
  die "$(printf 'the requested provisioner version %q is not a usable git ref (issue #232).' "$PROVISIONER_VERSION")
It came from ${version_where}.
A version is a YY.MM.NNN tag (expected like 26.10.001; old names such as 0.2.0 are gone, #1134), a branch,
or a full commit sha: letters, digits and . _ / + - only, no leading '-', no '..', at most 128 characters.
NOT falling back to the newest code: you asked for a specific version, and building a
different one under that label is the exact failure this check exists to prevent.
Fix the pointer (or set PROVISIONER_VERSION) and re-run. Nothing has been provisioned."
fi

PROVISIONER_RESTORE_LEGACY_AGAIN="${PROVISIONER_RESTORE_LEGACY_AGAIN:-}"
if [[ -n $PROVISIONER_RESTORE_LEGACY_AGAIN && $PROVISIONER_RESTORE_LEGACY_AGAIN != all \
      && ( ! $PROVISIONER_RESTORE_LEGACY_AGAIN =~ ^[A-Za-z0-9_][A-Za-z0-9_-]{0,63}(,[A-Za-z0-9_][A-Za-z0-9_-]{0,63})*$ || ,${PROVISIONER_RESTORE_LEGACY_AGAIN}, == *,all,* ) ]]; then
  die "$(printf 'PROVISIONER_RESTORE_LEGACY_AGAIN %q is not usable (#1127).' "$PROVISIONER_RESTORE_LEGACY_AGAIN")
Give item names (letters, digits, - and _, at most 64 characters, not starting with -) separated by commas, or the word all, or leave it empty.
Nothing has been provisioned."
fi

if [[ -n $PROVISIONER_VERSION ]]; then
  log "building provisioner version '${PROVISIONER_VERSION}' (from ${version_src})"
else
  log "no version pinned (${VERSION_REMOTE} absent or empty, and no PROVISIONER_VERSION) — building the newest code, as every lap before issue #232 did"
fi

HOOK_APT_LOCK_WAIT="${PROVISIONER_APT_LOCK_WAIT:-300}"

HOOK_APT_LOCK_RE='could not get lock|unable to acquire the dpkg frontend lock|dpkg frontend lock|is another process using it|waiting for cache lock|unable to lock the administration directory'

install_git() {
  local out rc aptlog
  [[ $HOOK_APT_LOCK_WAIT =~ ^[1-9][0-9]*$ ]] \
    || die "PROVISIONER_APT_LOCK_WAIT must be a whole number of seconds, 1 or more (got '${HOOK_APT_LOCK_WAIT}'). It bounds how long apt may wait for the package-manager lock. apt reads a negative value as 'wait forever' — the hang issue #303 exists to prevent — and 0 is apt-get's fail-immediately default, which is the #303 bug itself."
  log "installing git (absent on a stock PVE host — issue #169)"
  log "if this box's own first-boot updater is still running, apt will WAIT for the package-manager lock instead of failing — up to ${HOOK_APT_LOCK_WAIT}s per call (update, then install). A pause of a few minutes here is that wait, not a hang (issue #303)."
  aptlog="$(mktemp "${TMPDIR:-/tmp}/hook-apt.XXXXXX" 2>/dev/null || printf '%s/hook-apt.%s' "${TMPDIR:-/tmp}" "$$")"
  _apt_console() {   # stdin = apt's stream; console gets the ticker only, or all of it if verbose
    if [[ ${HOOK_VERBOSE:-0} == 1 ]]; then cat
    else grep --line-buffered -iE "$HOOK_APT_LOCK_RE" || true; fi
  }
  _apt_record() {    # full transcript → durable log ONLY, never the console (issue #392)
    [[ -n ${1:-} ]] || return 0
    declare -F _hook_log_file >/dev/null 2>&1 || return 0
    _hook_log_file "apt transcript (issue #392, kept out of the console, held for the record):
$1"
    return 0
  }
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout="$HOOK_APT_LOCK_WAIT" -o Dpkg::Use-Pty=0 update -qq 2>&1 | tee "$aptlog" | _apt_console >&2
  rc=${PIPESTATUS[0]}; out="$(cat "$aptlog" 2>/dev/null)"; _apt_record "$out"
  (( rc == 0 )) \
    || warn "apt-get update exited ${rc} — continuing to the install anyway (a subscription 401 is harmless here). First line back: $(printf '%s' "$out" | head -1)"
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout="$HOOK_APT_LOCK_WAIT" -o Dpkg::Use-Pty=0 install -y -qq git 2>&1 | tee "$aptlog" | _apt_console >&2
  rc=${PIPESTATUS[0]}; out="$(cat "$aptlog" 2>/dev/null)"; _apt_record "$out"; rm -f "$aptlog"
  if (( rc == 0 )) && command -v git >/dev/null 2>&1; then
    log "git installed ($(git --version 2>/dev/null || echo 'version unknown'))"
    return 0
  fi
  if grep -qiE "$HOOK_APT_LOCK_RE" <<<"$out"; then
    die "could not install git: something else on this box still holds the package manager, after apt waited ${HOOK_APT_LOCK_WAIT}s for it (issue #303).
This is NOT an apt misconfiguration and running apt by hand now will fail the same way. A
freshly installed Proxmox host runs its own first-boot updates; wait for them to finish:
  ps -eo pid,etime,cmd | grep -E '[a]pt|[d]pkg|[u]nattended'
When nothing is left, re-run this hook — nothing has been provisioned (no VM, no user), so a
re-run is clean. If NOTHING is running and the lock is still held, the package manager is
wedged rather than busy: 'dpkg --configure -a' (and 'rm /var/lib/dpkg/lock-frontend' only if
dpkg confirms no owner) then re-run. apt said: $(printf '%s' "$out" | grep -iE "$HOOK_APT_LOCK_RE" | head -1)"
  fi
  die "could not install git, so this box cannot fetch the provisioner code (issue #169).
The pre-repo phase needs exactly one package and this is it. Check apt on this host:
  apt-get update ; apt-get install -y git
A PVE host with no subscription 401s on the enterprise repo — that alone is harmless, git
comes from Debian's own repos. Nothing has been provisioned (no VM, no user).
apt said: $(printf '%s' "$out" | tail -3)"
}

if command -v git >/dev/null 2>&1; then
  log "git already present ($(git --version 2>/dev/null || echo 'version unknown'))"
else
  install_git
fi

log "pulling the GitHub deploy key from the helper (${DEPLOY_KEY_REMOTE})"
if ! helper_get "$DEPLOY_KEY_REMOTE" "$DEPLOY_KEY"; then
  rm -f "$DEPLOY_KEY"
  die "could not pull the GitHub deploy key from the helper (${DEPLOY_KEY_REMOTE}) — see the [helper-lib] line above for the transport's own words.
This box cannot clone the provisioner repo without it. Stage it on the helper (the same file control-boot.sh pulls for the control node) and re-run the hook. Nothing has been provisioned."
fi
[[ -s $DEPLOY_KEY ]] || { rm -f "$DEPLOY_KEY"; die "the deploy key fetched from ${DEPLOY_KEY_REMOTE} is EMPTY — re-stage it on the helper and re-run. Nothing has been provisioned."; }
chmod 0600 "$DEPLOY_KEY"
milestone "github deploy key pulled from the seedbox — cloning the provisioner repo next"

if head -c 64 "$DEPLOY_KEY" 2>/dev/null | grep -q -- '-----BEGIN'; then
  log "github credential is an SSH key — cloning over SSH"
  install -d -m 0700 /root/.ssh
  printf '%s\n' \
    'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' \
    'github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=' \
    'github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=' \
    > /root/.ssh/known_hosts_github
  chmod 0644 /root/.ssh/known_hosts_github
  export GIT_SSH_COMMAND="ssh -i ${DEPLOY_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/.ssh/known_hosts_github -o GlobalKnownHostsFile=/dev/null"
else
  log "github credential is a token — cloning over HTTPS"
  printf '%s' "$(tr -d '[:space:]' < "$DEPLOY_KEY")" > "$DEPLOY_KEY"
  REPO_URL="https://x-access-token@github.com/parrhasia/prometheus.git"
  printf '#!/usr/bin/env bash\nexec cat %q\n' "$DEPLOY_KEY" > "$GIT_ASKPASS_HELPER"
  chmod 0700 "$GIT_ASKPASS_HELPER"
  export GIT_ASKPASS="$GIT_ASKPASS_HELPER" GIT_TERMINAL_PROMPT=0
fi

resolve_ref() {   # <repo_dir> <ref> → prints a commit sha, rc 1 if the ref is not there
  local d="$1" r="$2" c sha
  for c in "refs/tags/${r}" "refs/remotes/origin/${r}" "$r"; do
    if sha="$(git -C "$d" rev-parse --verify --quiet "${c}^{commit}" 2>/dev/null)" && [[ -n $sha ]]; then
      printf '%s' "$sha"; return 0
    fi
  done
  return 1
}

default_ref() {   # <repo_dir> → prints e.g. origin/main — what "newest" means
  local d="$1" s
  s="$(git -C "$d" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)" \
    || { git -C "$d" remote set-head origin -a >/dev/null 2>&1 || true
         s="$(git -C "$d" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)" || s=""; }
  [[ -n $s ]] && { printf '%s' "${s#refs/remotes/}"; return 0; }
  printf 'origin/main'
}

run_git_step() {
  local okline="$1"; shift
  [[ ${1:-} == -- ]] && shift
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if (( rc == 0 )); then
    [[ -n $okline ]] && log "$okline"
  else
    [[ -n $out ]] && printf '%s\n' "$out" >&2
  fi
  return $rc
}

install -d -m 0755 "$(dirname "$REPO_DIR")" 2>/dev/null || true
if [[ -d "${REPO_DIR}/.git" ]]; then
  log "updating the provisioner checkout at ${REPO_DIR}"
  run_git_step "provisioner checkout fetched (${REPO_DIR})" \
    -- git -C "$REPO_DIR" fetch --prune --tags --force origin \
    || die "git fetch failed for the existing checkout at ${REPO_DIR} (issue #169/#232).
Check outbound network/DNS to github.com and that the deploy key at ${DEPLOY_KEY_REMOTE} still grants READ on parrhasia/prometheus. Or remove ${REPO_DIR} and re-run the hook to clone fresh."
  if [[ -z $PROVISIONER_VERSION ]] && git -C "$REPO_DIR" symbolic-ref --quiet HEAD >/dev/null 2>&1; then
    run_git_step "provisioner checkout fast-forwarded (${REPO_DIR})" \
      -- git -C "$REPO_DIR" pull --ff-only \
      || die "git pull failed for the existing checkout at ${REPO_DIR} (issue #169).
A local modification or a diverged branch stops a fast-forward. Inspect it, or remove ${REPO_DIR} and re-run the hook to clone fresh."
  fi
else
  log "cloning the provisioner repo into ${REPO_DIR}"
  run_git_step "provisioner repo cloned into ${REPO_DIR}" \
    -- git clone --quiet "$REPO_URL" "$REPO_DIR" \
    || die "git clone failed (issue #169) — this box could not fetch the provisioner code.
Since #169 the boot chain runs the REPO's code, so there is no staged copy to fall back to.
Check, in this order:
  • outbound network / DNS from this host to github.com
  • the deploy key staged at ${DEPLOY_KEY_REMOTE} on the helper — is it still valid, and does it grant READ on parrhasia/prometheus?
  • git's own words above
Nothing has been provisioned (no VM, no user, no sshd change)."
  [[ -n $PROVISIONER_VERSION ]] && { git -C "$REPO_DIR" fetch --tags --force origin >/dev/null 2>&1 || true; }
fi

if [[ -n $PROVISIONER_VERSION ]]; then
  pinned_sha="$(resolve_ref "$REPO_DIR" "$PROVISIONER_VERSION")" \
    || die "the provisioner version '${PROVISIONER_VERSION}' (from ${version_where}) does not exist in parrhasia/prometheus (issue #232).
It was looked for as a tag, as a branch on origin, and as a commit sha — none resolved, after a full fetch.
NOT falling back to the newest code: a box labelled '${PROVISIONER_VERSION}' that was built from something else is worse than a box that was not built.
Fix the pointer (or set PROVISIONER_VERSION) and re-run. Nothing has been provisioned (no VM, no user, no sshd change)."
  git -C "$REPO_DIR" checkout --detach "$pinned_sha" \
    || die "could not check out provisioner version '${PROVISIONER_VERSION}' (${pinned_sha}) in ${REPO_DIR} (issue #232).
git refuses a checkout that would overwrite a locally modified file — that is deliberate, so a debugging edit on this box is never silently discarded. Inspect ${REPO_DIR}, or remove it and re-run the hook to clone fresh."
  log "checkout pinned at version '${PROVISIONER_VERSION}' → ${pinned_sha} (issue #232)"
elif [[ -d "${REPO_DIR}/.git" ]] && ! git -C "$REPO_DIR" symbolic-ref --quiet HEAD >/dev/null 2>&1; then
  _newest="$(default_ref "$REPO_DIR")"
  say "this checkout is detached (a previous lap pinned a version) and nothing is pinned now — moving it back to ${_newest}"
  git -C "$REPO_DIR" checkout --detach "$_newest" \
    || die "could not move the detached checkout at ${REPO_DIR} back onto ${_newest} (issue #232).
A locally modified file stops it. Inspect ${REPO_DIR}, or remove it and re-run the hook to clone fresh."
  unset _newest
fi

if [[ -n $PROVISIONER_VERSION && -r $NEEDLE_MAIN ]] \
   && command -v grep >/dev/null 2>&1 \
   && ! grep -qs 'PROVISIONER_VERSION' "$NEEDLE_MAIN" "${NEEDLE_MAIN%/*}"/needle-*.sh; then   # needle is split into parts since #948 (#1086)
  say "WARNING: version '${PROVISIONER_VERSION}' PREDATES version pinning (issue #232).
This host will run it, but the needle at that commit cannot pass the version on, so the CONTROL
NODE it builds will clone the NEWEST code instead — one estate built from two versions.
If you need the whole estate on '${PROVISIONER_VERSION}', it is not reachable from here: pick a
ref that contains the version plumbing, or accept that only this host is pinned."
fi

[[ -r $NEEDLE_MAIN ]] || die "the checkout at ${REPO_DIR} has no ${NEEDLE_MAIN#$REPO_DIR/} — either the clone is incomplete or this commit predates the #169 split.
${PROVISIONER_VERSION:+A version is pinned ('${PROVISIONER_VERSION}'), so this is most likely a ref from BEFORE the boot chain was split — pick a newer version, or unpin the estate.
}Remove ${REPO_DIR} and re-run the hook."

REPO_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null)" || REPO_COMMIT=""
REPO_COMMIT_SHORT="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null)" || REPO_COMMIT_SHORT=""
REPO_COMMIT_DESC="$(git -C "$REPO_DIR" log -1 --format='%h %cI %s' 2>/dev/null)" || REPO_COMMIT_DESC=""
if [[ -n $REPO_COMMIT ]]; then
  log "running the provisioner repo at ${REPO_COMMIT_SHORT:-$REPO_COMMIT} (version=${PROVISIONER_VERSION:-newest})"
  log "…that checkout is ${REPO_COMMIT_DESC:-$REPO_COMMIT_SHORT} in ${REPO_DIR} — issue #169/#232: this is the code this lap executes, not a copy staged on the helper"
  _hook_feed_line "[hook] provisioner repo cloned at ${REPO_COMMIT_DESC:-$REPO_COMMIT_SHORT} (version=${PROVISIONER_VERSION:-newest})"
else
  warn "cloned/updated ${REPO_DIR} but could not read its commit (git rev-parse failed) — the lap continues UNIDENTIFIED (issue #169)"
fi

_compare_staged_to_checkout() {
  local drift_lib="${REPO_DIR}/bootstrap/staged-drift.sh"
  local name sha rc summary="" drift="" drift_detail="" short="" answer="" scope=""
  local n_checked=0 n_drift=0 n_local=0 n_differs=0
  local can_restage=1 restage_why="" restage_why_long="" forced="" pass_note="" read_rc=0
  local ask_timeout
  local genesis_main="${REPO_DIR}/bootstrap/genesis.sh"
  local hook_main="${REPO_DIR}/bootstrap/hook.sh"
  if [[ -z $PREREPO_FINGERPRINTS ]]; then
    log "staged-vs-checkout: UNKNOWN-not-compared — no pre-repo fingerprint was recorded on this host, so the staged code was NOT judged (issue #428)"
    return 0
  fi
  if [[ ! -r $drift_lib ]]; then
    log "staged-vs-checkout: UNKNOWN-not-compared — this checkout has no bootstrap/staged-drift.sh${PROVISIONER_VERSION:+ (version '${PROVISIONER_VERSION}' predates issue #428)}, so the fingerprints above go uncompared, exactly as they did on every lap before it"
    return 0
  fi
  . "$drift_lib" || { warn "could not source ${drift_lib} — the staged code was NOT judged this lap (issue #428)"; return 0; }
  while read -r name sha; do
    [[ -n $name ]] || continue
    n_checked=$((n_checked + 1))
    staged_verdict "$REPO_DIR" "$name" "$sha"; rc=$?
    summary+=" ${name}=${STAGED_VERDICT}"
    if [[ $rc -eq 1 ]]; then
      n_drift=$((n_drift + 1))
      case "$STAGED_VERDICT" in
        STALE-behind-checkout-by-*) short="${STAGED_VERDICT##*-by-} change(s) behind" ;;
        DIFFERS-from-checkout)
          if [[ $STAGED_DETAIL == *"modified locally"* ]]; then
            n_local=$((n_local + 1))
            short="this CHECKOUT is the modified side — the helper has the last committed version"
          else
            n_differs=$((n_differs + 1))
            short="not this checkout's version — hand-edited on the helper, or NEWER than this checkout"
          fi ;;
        *) short="$STAGED_VERDICT" ;;
      esac
      drift+="  • ${name} — ${short}"$'\n'
      drift_detail+="  • ${name}: the helper is serving ${STAGED_DETAIL}"$'\n'
    fi
  done <<< "$PREREPO_FINGERPRINTS"
  log "staged-vs-checkout:${summary} (issue #428 — the pre-repo fingerprints above, judged against ${REPO_COMMIT_SHORT:-this checkout})"
  [[ -n $drift ]] || return 0
  log "staged-vs-checkout DRIFT (issue #428):
${drift_detail%$'\n'}"

  if (( n_local == n_drift )); then
    if (( n_checked == 1 )); then
      scope="this boot fetched 1 script from the helper and it does not match this checkout — because this CHECKOUT is locally modified, not because the helper is behind:"
    else
      scope="this boot fetched ${n_checked} scripts from the helper and ${n_drift} of them do not match this checkout — because this CHECKOUT is locally modified, not because the helper is behind:"
    fi
  elif (( n_local > 0 )); then
    scope="this boot fetched ${n_checked} scripts from the helper; ${n_drift} of them do not match this checkout — read each line for which side is the modified one:"
  elif (( n_differs == n_drift )); then
    if (( n_checked == 1 )); then
      scope="this boot fetched 1 script from the helper and it does not match this checkout:"
    else
      scope="this boot fetched ${n_checked} scripts from the helper; ${n_drift} of them do not match this checkout:"
    fi
  elif (( n_checked == 1 )); then
    scope="this boot fetched 1 script from the helper and it is not up to date:"
  elif (( n_drift == n_checked )); then
    scope="this boot fetched ${n_checked} scripts from the helper and none of them are up to date:"
  elif (( n_drift == 1 )); then
    scope="this boot fetched ${n_checked} scripts from the helper; 1 of them is not up to date:"
  else
    scope="this boot fetched ${n_checked} scripts from the helper; ${n_drift} of them are not up to date:"
  fi

  if [[ -n ${PROVISIONER_HOOK_RESTAGED:-} ]]; then
    can_restage=0
    restage_why="a re-stage from this checkout already ran earlier in this boot (from ${PROVISIONER_HOOK_RESTAGED}) and the drift is STILL here — not offering it again"
    restage_why_long="${restage_why}. Something other than staleness is in play: check that ${genesis_main} actually reached this estate's helper, and that PROVISIONER_REMOTE_DIR ('${PROVISIONER_REMOTE_DIR-<unset>}') names the directory this boot fetched from (issue #313 — a re-stage into the wrong account reports success)."
  elif (( n_local > 0 )); then
    can_restage=0
    restage_why="not re-staging: the difference is this checkout's own local modification, and a re-stage would push it onto the helper"
    restage_why_long="${restage_why}. Commit or discard the local change and re-run the hook; the helper is serving the last committed version and needs nothing done to it."
  elif [[ -n ${PROVISIONER_VERSION:-} ]]; then
    can_restage=0
    restage_why="not re-staging: this checkout is PINNED at version '${PROVISIONER_VERSION}', so a re-stage would rewind the helper to the pin"
    restage_why_long="${restage_why} for every later lap of this estate (issue #232). If the pin really is what the helper should serve, run \`bootstrap/genesis.sh helper\` from it deliberately."
  elif [[ -z ${PROVISIONER_REMOTE_DIR+x} ]]; then
    can_restage=0
    restage_why="not re-staging: PROVISIONER_REMOTE_DIR is unset here, and genesis.sh never guesses a helper's layout"
    restage_why_long="${restage_why} (issue #313) — a re-stage from this environment would either die or stage this estate's boot scripts into the wrong account."
  elif [[ ! -r $genesis_main || ! -r $hook_main ]]; then
    can_restage=0
    restage_why="not re-staging: this checkout has no readable bootstrap/genesis.sh + bootstrap/hook.sh to re-stage and restart with"
    restage_why_long="${restage_why} (looked for ${genesis_main} and ${hook_main}) — an old pinned ref is the usual reason."
  fi

  printf '%s\n' "$scope" >&2
  printf '%s' "$drift" >&2
  if (( n_local == 0 )) && [[ -z ${PROVISIONER_VERSION:-} ]]; then
    printf '%s\n' "  fix with: bootstrap/genesis.sh helper" >&2
  fi
  if [[ -n ${PROVISIONER_VERSION:-} ]] && (( n_differs > 0 )); then
    printf '%s\n' "  (pinned to version '${PROVISIONER_VERSION}' — the helper may be NEWER than the pin, not older)" >&2
  fi
  if [[ -n $restage_why ]]; then
    printf '%s\n' "  ${restage_why}" >&2
    log "staged-vs-checkout: ${restage_why_long}"
  fi

  ask_timeout="${PROVISIONER_HOOK_DRIFT_TIMEOUT:-60}"
  [[ $ask_timeout =~ ^[0-9]+$ ]] && (( ask_timeout >= 1 )) || ask_timeout=60

  forced="${PROVISIONER_STAGED_DRIFT:-}"
  case "${forced,,}" in
    ""|continue|restage|stop) forced="${forced,,}" ;;
    *) warn "PROVISIONER_STAGED_DRIFT='${forced}' is not one of continue|restage|stop — ignoring it"; forced="" ;;
  esac

  if [[ -n $forced ]]; then
    answer="$forced"
    log "staged-vs-checkout: answering '${answer}' from PROVISIONER_STAGED_DRIFT (no question asked)"
  elif [[ ${have_tty:-0} == 1 ]]; then
    if (( can_restage == 1 )); then
      printf '%s\n' "  [R] re-stage the helper from this checkout and start over   (default)" >&2
      printf '%s\n' "  [c] continue with what already ran" >&2
      printf '%s\n' "  [n] stop" >&2
      read -r -t "$ask_timeout" -p "choice [R/c/n]: " answer </dev/tty; read_rc=$?
    else
      printf '%s\n' "  [C] continue with what already ran   (default)" >&2
      printf '%s\n' "  [n] stop" >&2
      read -r -t "$ask_timeout" -p "continue anyway? [Y/n]: " answer </dev/tty; read_rc=$?
    fi
    if (( read_rc > 128 )); then
      printf '\n%s\n' "continuing (no answer in ${ask_timeout}s)" >&2
      log "staged-vs-checkout: no answer in ${ask_timeout}s — continuing (issue #58: this question must never be able to wedge a walk-away lap)"
      return 0
    elif (( read_rc != 0 )); then
      printf '\n%s\n' "continuing (the console went away while asking)" >&2
      log "staged-vs-checkout: lost the controlling terminal while asking — continuing"
      return 0
    fi
  else
    log "staged-vs-checkout: no controlling terminal and no PROVISIONER_STAGED_DRIFT — continuing without asking, exactly as every lap before this question existed"
    return 0
  fi

  case "${answer,,}" in
    n|no|stop)
      pass_note=""
      [[ -s ${HELPER_PASS_FILE:-} ]] && pass_note=", the helper password at ${HELPER_PASS_FILE}"
      die "stopped at your request — the staged code does not match this checkout.
Re-stage from a current checkout: \`bootstrap/genesis.sh helper\` for this estate, then re-run the hook.
Nothing has been PROVISIONED (no VM, no user, no sshd change), but this host is no longer bare: git is installed, the GitHub read-only deploy key is at ${DEPLOY_KEY}${pass_note}, and the provisioner checkout is at ${REPO_DIR}."
      ;;
    r|re|restage|"")
      if (( can_restage != 1 )); then
        [[ -n $forced && -n $restage_why ]] && printf '%s\n' "  ${restage_why} — continuing" >&2
        return 0
      fi
      say "re-staging the helper from this checkout (${REPO_COMMIT_SHORT:-this checkout}) — a handful of helper logins, then the hook starts over"
      if GENESIS_HELPER="$helper" GENESIS_ESTATE="$estate" /bin/bash "$genesis_main" helper; then
        export PROVISIONER_HOOK_RESTAGED="${REPO_COMMIT_SHORT:-unknown}"
        say "re-staged — restarting the hook so this lap's PRE-repo phase runs the current code too"
        log "restarting the hook: exec /bin/bash ${hook_main} (PROVISIONER_HOOK_RESTAGED=${PROVISIONER_HOOK_RESTAGED} rides across the exec, so the second pass can never offer this again)"
        exec /bin/bash "$hook_main"
        warn "could not exec ${hook_main} to restart the hook — continuing this lap instead; everything from here on already comes from the checkout"
        return 0
      fi
      warn "the re-stage FAILED (${genesis_main} helper) — NOT restarting, because the helper still serves the same bytes and a restart would land back here. genesis said why, above. Continuing this lap on the code that already ran."
      return 0
      ;;
  esac
  return 0
}
_compare_staged_to_checkout

export PROVISIONER_REPO_DIR="$REPO_DIR"
export PROVISIONER_REPO_COMMIT="$REPO_COMMIT"
export PROVISIONER_VERSION
export PROVISIONER_RESTORE_LEGACY_AGAIN   # #1127: one run only, never stored

log "handing off to the checkout's needle: ${NEEDLE_MAIN}"
_hook_feed_line "[hook] pre-repo phase complete — handing off to the checkout's needle"
_hook_log_file "[hook] ── end of the pre-repo phase; everything below runs from ${REPO_DIR} ──"
exec /bin/bash "$NEEDLE_MAIN" "$helper" "$estate"

die "could not exec ${NEEDLE_MAIN} — the checkout is present but unrunnable"
