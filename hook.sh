#!/bin/bash
set -uo pipefail
reset

_RD="${PROVISIONER_REMOTE_DIR:-}"
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

  [[ $helper_src != prompt ]] && say "using helper ${helper} on port ${port} (from ${helper_src})"

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


if [[ -n $embedded_rd ]]; then
  [[ -n $_RD && $_RD != "$embedded_rd" ]] \
    && say "helper remote dir: using '${embedded_rd}' from the combined address (overriding PROVISIONER_REMOTE_DIR='${_RD}')"
  _RD="$embedded_rd"
  log "helper remote dir set from the combined address: ${_RD}"
elif [[ -z $_RD && $auth_hint == key ]]; then
  _RD="$HELPER_DEFAULT_SSH_RD"
  log "helper remote dir defaulted to '${_RD}' (issue #300: known key/ssh helper, no path given)"
fi
SCRIPTS_REMOTE="${_RD:+${_RD}/}scripts"
SECRETS_REMOTE="${_RD:+${_RD}/}secrets"
LIB_REMOTE="${SCRIPTS_REMOTE}/helper-lib.sh"
DEPLOY_KEY_REMOTE="${SECRETS_REMOTE}/github_deploy"
VERSION_REMOTE="${_RD:+${_RD}/}version"

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
      sftp "${sftp_opts[@]}" "$helper" 2>&1
    rc=$?
    rm -f "$ap"
    return $rc
  fi
  if command -v sshpass >/dev/null 2>&1; then
    sshpass -f "$HELPER_PASS_FILE" sftp "${sftp_opts[@]}" "$helper" 2>&1
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

fetch_fail_reason=""    # human-readable "why" for the last fetch_lib failure
banner_closes=0         # how many times the helper hung up on us (see the 'banned' class)
fetch_lib() {
  fetch_fail_reason=""
  local out rc key_fail=""
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
      fetch_fail_reason="authenticated fine, but ${LIB_REMOTE} could not be read from the helper — re-run genesis.sh's deploy to stage the boot scripts. Your helper password has been KEPT." ; return 3;;
    transport)
      fetch_fail_reason="transport error reaching the helper: $(printf '%s' "$out" | tr '\n' ';')" ; return 1;;
    *)
      fetch_fail_reason="unrecognised failure (could not tell auth from transport): $(printf '%s' "$out" | tr '\n' ';')"
      [[ ${PROVISIONER_HOOK_RETRY_UNKNOWN:-0} == 1 ]] && return 1
      return 2;;
  esac
}

hook_find_askpass_dir >/dev/null || true

attempts=0
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

if helper_detect; then
  milestone "seedbox reachable (auth=$(helper_auth), channel=$(helper_channel)) — cold start begins for ${estate}"
else
  die "cannot reach helper '${helper}' on port ${port} — the deploy key and the seed images both live there, so nothing can proceed.
Read the [helper-lib] line above for WHICH fault this is: a refused/unanswered port means nothing was listening and neither the key ('${PROVISIONER_HELPER_ID:-<none threaded>}') nor the password ('${HELPER_PASS_FILE}') was tried — check PROVISIONER_HELPER_PORT before either of them (issue #143).
Nothing has been changed on this host."
fi

ref_is_sane() {
  local r="${1:-}"
  [[ -n $r ]] || return 1
  [[ $r == *..* ]] && return 1
  [[ $r =~ ^[A-Za-z0-9][A-Za-z0-9._/+-]{0,127}$ ]]
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
A version is a tag, a branch, or a full commit sha: letters, digits and . _ / + - only, no
leading '-', no '..', at most 128 characters.
NOT falling back to the newest code: you asked for a specific version, and building a
different one under that label is the exact failure this check exists to prevent.
Fix the pointer (or set PROVISIONER_VERSION) and re-run. Nothing has been provisioned."
fi

if [[ -n $PROVISIONER_VERSION ]]; then
  say "building provisioner version '${PROVISIONER_VERSION}' (from ${version_src})"
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
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout="$HOOK_APT_LOCK_WAIT" update -qq 2>&1 | tee "$aptlog" >&2
  rc=${PIPESTATUS[0]}; out="$(cat "$aptlog" 2>/dev/null)"
  (( rc == 0 )) \
    || warn "apt-get update exited ${rc} — continuing to the install anyway (a subscription 401 is harmless here). First line back: $(printf '%s' "$out" | head -1)"
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout="$HOOK_APT_LOCK_WAIT" install -y -qq git 2>&1 | tee "$aptlog" >&2
  rc=${PIPESTATUS[0]}; out="$(cat "$aptlog" 2>/dev/null)"; rm -f "$aptlog"
  (( rc == 0 )) && command -v git >/dev/null 2>&1 && return 0
  if printf '%s' "$out" | grep -qiE "$HOOK_APT_LOCK_RE"; then
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
A PVE host with no subscription 401s on the enterprise repo — that alone is harmless, the
no-subscription repo carries git. Nothing has been provisioned (no VM, no user).
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
  ssh-keyscan github.com >> /root/.ssh/known_hosts 2>/dev/null || true
  export GIT_SSH_COMMAND="ssh -i ${DEPLOY_KEY} -o IdentitiesOnly=yes"
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
    -- git clone "$REPO_URL" "$REPO_DIR" \
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
   && ! grep -q 'PROVISIONER_VERSION' "$NEEDLE_MAIN" 2>/dev/null; then
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
  log "running the provisioner repo at ${REPO_COMMIT_DESC:-$REPO_COMMIT_SHORT} (${REPO_DIR}) — version=${PROVISIONER_VERSION:-newest} — issue #169/#232: this is the code this lap executes, not a copy staged on the helper"
  _hook_feed_line "[hook] provisioner repo cloned at ${REPO_COMMIT_DESC:-$REPO_COMMIT_SHORT} (version=${PROVISIONER_VERSION:-newest})"
else
  warn "cloned/updated ${REPO_DIR} but could not read its commit (git rev-parse failed) — the lap continues UNIDENTIFIED (issue #169)"
fi

_compare_staged_to_checkout() {
  local drift_lib="${REPO_DIR}/bootstrap/staged-drift.sh"
  local name sha rc summary="" drift=""
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
    staged_verdict "$REPO_DIR" "$name" "$sha"; rc=$?
    summary+=" ${name}=${STAGED_VERDICT}"
    [[ $rc -eq 1 ]] && drift+="  • ${name}: the helper is serving ${STAGED_DETAIL}"$'\n'
  done <<< "$PREREPO_FINGERPRINTS"
  log "staged-vs-checkout:${summary} (issue #428 — the pre-repo fingerprints above, judged against ${REPO_COMMIT_SHORT:-this checkout})"
  [[ -n $drift ]] || return 0
  warn "this cold start ran code STAGED ON THE HELPER that is not what the checkout says it should be (issue #428):
${drift}The lap CONTINUES — a stale staged script still builds a working estate, and stopping here would be worse than the drift.
To fix it, re-stage from a current checkout: \`bootstrap/genesis.sh helper\` for this estate, then re-run the hook.${PROVISIONER_VERSION:+
This checkout is PINNED at version '${PROVISIONER_VERSION}' (issue #232), so the helper may well be serving NEWER code than the pin rather than older — read the line above with that in mind.}"
  return 0
}
_compare_staged_to_checkout

export PROVISIONER_REPO_DIR="$REPO_DIR"
export PROVISIONER_REPO_COMMIT="$REPO_COMMIT"
export PROVISIONER_VERSION

log "handing off to the checkout's needle: ${NEEDLE_MAIN}"
_hook_feed_line "[hook] pre-repo phase complete — handing off to the checkout's needle"
_hook_log_file "[hook] ── end of the pre-repo phase; everything below runs from ${REPO_DIR} ──"
exec /bin/bash "$NEEDLE_MAIN" "$helper" "$estate"

die "could not exec ${NEEDLE_MAIN} — the checkout is present but unrunnable"
