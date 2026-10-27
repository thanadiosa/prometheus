# shellcheck shell=bash

: "${HELPER:=${PROVISIONER_HELPER:-}}"
HELPER_PORT="${PROVISIONER_HELPER_PORT:-22}"
if [ -n "${PROVISIONER_HELPER_PORT:-}" ]; then HELPER_PORT_SRC="PROVISIONER_HELPER_PORT"; else HELPER_PORT_SRC="default"; fi
HELPER_KEY="${PROVISIONER_HELPER_ID:-${HELPER_ID:-/root/.ssh/id_ed25519}}"
HELPER_PASS_FILE="${PROVISIONER_HELPER_PASS_FILE:-/etc/provisioner/helper-pass}"
HELPER_CONNECT_TIMEOUT="${PROVISIONER_HELPER_CONNECT_TIMEOUT:-15}"
HELPER_AUTH="${PROVISIONER_HELPER_AUTH:-auto}"
HELPER_AUTH_CACHE="${PROVISIONER_HELPER_AUTH_CACHE:-}"
HELPER_PROBE_TIMEOUT="${PROVISIONER_HELPER_PROBE_TIMEOUT:-25}"

HELPER_PUT_VERIFY_MAX="${PROVISIONER_HELPER_PUT_VERIFY_MAX:-65536}"

HELPER_CIPHERS="${PROVISIONER_HELPER_CIPHERS-aes128-ctr}"
HELPER_MACS="${PROVISIONER_HELPER_MACS-hmac-sha2-256}"

_HELPER_SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout="${HELPER_CONNECT_TIMEOUT}")
[ -n "$HELPER_CIPHERS" ] && _HELPER_SSH_OPTS+=(-o Ciphers="$HELPER_CIPHERS")
[ -n "$HELPER_MACS" ] && _HELPER_SSH_OPTS+=(-o MACs="$HELPER_MACS")

_HELPER_DETECTED=""
_HELPER_AUTH=""          # key | password
_HELPER_EXEC=""          # 1 (exec channel usable) | 0 (SFTP-only)

_helper_log() { printf '[helper-lib] %s\n' "$*" >&2; }

_helper_log_quiet() {
  if declare -F _prov_quiet_sink >/dev/null 2>&1; then
    _prov_quiet_sink "[helper-lib] $*"
  else
    _helper_log "$@"
  fi
}

HELPER_PASS_MODE="${PROVISIONER_HELPER_PASS_MODE:-auto}"
_HELPER_ASKPASS_OK=""     # memo: 1 = this ssh honours SSH_ASKPASS_REQUIRE=force
_HELPER_ASKPASS_DIR=""    # memo: a directory where a generated script actually EXECUTES
_HELPER_ASKPASS_DIR_TRIED=""   # the memo KEY the line above was resolved for (see below)
_HELPER_ASKPASS_WHY=""         # per-candidate verdicts from the last probe (for the failure text)

_helper_askpass_candidates() {
  if [ -n "${PROVISIONER_ASKPASS_DIR:-}" ]; then printf '%s' "$PROVISIONER_ASKPASS_DIR"; return 0; fi
  local creddir=""
  case "${HELPER_PASS_FILE:-}" in */*) creddir="${HELPER_PASS_FILE%/*}" ;; esac
  printf '%s' "${creddir} /etc/provisioner /run/provisioner /run ${TMPDIR:-/tmp} /tmp /var/tmp /dev/shm ${HOME:-}"
}

_helper_askpass_dir() {
  local key="${PROVISIONER_ASKPASS_DIR:-}|${HELPER_PASS_FILE:-}|${TMPDIR:-}|${HOME:-}"
  if [ "$_HELPER_ASKPASS_DIR_TRIED" = "$key" ]; then
    [ -n "$_HELPER_ASKPASS_DIR" ] && { printf '%s' "$_HELPER_ASKPASS_DIR"; return 0; }
    return 1
  fi
  _HELPER_ASKPASS_DIR_TRIED="$key"; _HELPER_ASKPASS_DIR=""; _HELPER_ASKPASS_WHY=""
  local d probe rc seen="" why="" override=""
  [ -n "${PROVISIONER_ASKPASS_DIR:-}" ] && override=1
  for d in $(_helper_askpass_candidates); do
    [ -n "$d" ] || continue
    case "$seen" in *"|${d}|"*) continue ;; esac      # the creddir is usually /etc/provisioner
    seen="${seen}|${d}|"
    if [ ! -d "$d" ]; then
      if [ -n "$override" ]; then
        why="${why}${d}: named by PROVISIONER_ASKPASS_DIR but does not exist; "; continue
      fi
      ( umask 077; mkdir -p "$d" ) 2>/dev/null || { why="${why}${d}: absent and could not be created; "; continue; }
    fi
    [ -w "$d" ] || { why="${why}${d}: not writable by uid ${EUID:-?}; "; continue; }
    probe="$(umask 077; mktemp "${d}/.prov-askpass-probe.XXXXXX" 2>/dev/null)" || {
      why="${why}${d}: mktemp failed (full or read-only filesystem?); "; continue; }
    if ! printf '#!/bin/sh\nexit 7\n' > "$probe" 2>/dev/null; then
      rm -f "$probe"; why="${why}${d}: the probe file could not be WRITTEN (full disk, or a read-only mount); "; continue; fi
    if ! chmod 700 "$probe" 2>/dev/null; then
      rm -f "$probe"; why="${why}${d}: the probe file could not be made executable (chmod refused); "; continue; fi
    "$probe" >/dev/null 2>&1; rc=$?
    rm -f "$probe"
    if [ "$rc" -eq 7 ]; then _HELPER_ASKPASS_DIR="$d"; _HELPER_ASKPASS_WHY="$why"; printf '%s' "$d"; return 0; fi
    case "$rc" in
      126) why="${why}${d}: exec DENIED (rc 126) — this mount is noexec; " ;;
      127) why="${why}${d}: exec failed, rc 127 — no /bin/sh to interpret it?; " ;;
      *)   why="${why}${d}: the probe ran but exited ${rc}, not 7; " ;;
    esac
  done
  _HELPER_ASKPASS_WHY="$why"
  return 1
}

_helper_askpass_audit() {
  [ -n "$_HELPER_ASKPASS_WHY" ] || return 0
  printf ' Every candidate directory was tried and rejected — %s' "${_HELPER_ASKPASS_WHY%; }"
}

_helper_askpass_supported() {
  case "$_HELPER_ASKPASS_OK" in 1) return 0;; 0) return 1;; esac
  local maj min
  maj="$(ssh -V 2>&1 | sed -n 's/^OpenSSH_\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1/p')"
  min="$(ssh -V 2>&1 | sed -n 's/^OpenSSH_\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\2/p')"
  if [ -n "$maj" ] && [ -n "$min" ] && { [ "$maj" -gt 8 ] || { [ "$maj" -eq 8 ] && [ "$min" -ge 4 ]; }; }; then
    _HELPER_ASKPASS_OK=1
  else
    _HELPER_ASKPASS_OK=0
  fi
  [ "$_HELPER_ASKPASS_OK" = 1 ]
}
_helper_askpass_supported >/dev/null 2>&1 || :
[ -n "$HELPER_PASS_FILE" ] && [ -f "$HELPER_PASS_FILE" ] && _helper_askpass_dir >/dev/null 2>&1
: # keep the source-time status clean for `set -e` callers

_helper_askpass_usable() { _helper_askpass_supported && _helper_askpass_dir >/dev/null && [ -n "$_HELPER_ASKPASS_DIR" ]; }

_helper_pass_transport() {
  case "$HELPER_PASS_MODE" in
    askpass) _helper_askpass_usable && printf 'askpass'; return ;;
    sshpass) command -v sshpass >/dev/null 2>&1 && printf 'sshpass'; return ;;
  esac
  if _helper_askpass_usable; then printf 'askpass'
  elif command -v sshpass >/dev/null 2>&1; then printf 'sshpass'
  fi
}

_helper_askpass_new() {
  local f
  _helper_askpass_dir >/dev/null || return 1
  [ -n "$_HELPER_ASKPASS_DIR" ] || return 1
  f="$(umask 077; mktemp "${_HELPER_ASKPASS_DIR}/.prov-askpass.XXXXXX" 2>/dev/null)" || return 1
  {
    printf '#!/bin/sh\n'
    printf '# GENERATED by helper-lib.sh (issue #104) — carries NO credential.\n'
    printf 'IFS= read -r p < "$PROVISIONER_ASKPASS_FILE"\n'
    printf '[ -n "$p" ] || exit 1\n'
    printf 'printf %%s "$p"\n'
  } > "$f" 2>/dev/null || { rm -f "$f"; return 1; }
  chmod 700 "$f" 2>/dev/null || { rm -f "$f"; return 1; }
  printf '%s' "$f"
}

_helper_pass_run() {
  local ap rc to=()
  [ -n "${_HELPER_OP_TIMEOUT:-}" ] && to=(timeout -k 5 "$_HELPER_OP_TIMEOUT")
  case "$(_helper_pass_transport)" in
    askpass)
      ap="$(_helper_askpass_new)" || {
        _helper_log "could not create an EXECUTABLE askpass helper — set PROVISIONER_ASKPASS_DIR=<an exec-capable dir>, or install sshpass.$(_helper_askpass_audit)"
        return 255; }
      PROVISIONER_ASKPASS_FILE="$HELPER_PASS_FILE" SSH_ASKPASS="$ap" \
      SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-}" "${to[@]}" "$@"
      rc=$?
      rm -f "$ap"
      return $rc
      ;;
    sshpass)
      "${to[@]}" sshpass -f "$HELPER_PASS_FILE" "$@"
      return $?
      ;;
    *)
      if _helper_askpass_supported; then
        _helper_askpass_dir >/dev/null 2>&1 || :
        _helper_log "no password transport: askpass has nowhere EXECUTABLE to live and sshpass is not installed — set PROVISIONER_ASKPASS_DIR, or check 'findmnt -no OPTIONS /tmp'.$(_helper_askpass_audit)"
      else
        _helper_log "no password transport available (this ssh predates SSH_ASKPASS_REQUIRE=force and sshpass is not installed)"
      fi
      return 255
      ;;
  esac
}

_helper_sftp_run() {
  local to=(); [ -n "${_HELPER_OP_TIMEOUT:-}" ] && to=(timeout -k 5 "$_HELPER_OP_TIMEOUT")
  if [ "$_HELPER_AUTH" = password ]; then
    _helper_pass_run sftp \
      -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
      -P "$HELPER_PORT" "${_HELPER_SSH_OPTS[@]}" "$HELPER"
  else
    "${to[@]}" sftp -i "$HELPER_KEY" -o IdentitiesOnly=yes -o PreferredAuthentications=publickey -o BatchMode=yes \
      -P "$HELPER_PORT" "${_HELPER_SSH_OPTS[@]}" "$HELPER"
  fi
}

_SFTP_RC=0
_SFTP_ERR=""
_SFTP_OUT=""
_helper_sftp_session() {
  local errf=""
  _SFTP_OUT=""; _SFTP_ERR=""; _SFTP_RC=0
  errf="$(mktemp "${TMPDIR:-/tmp}/prov-sftp-err.XXXXXX" 2>/dev/null)" || errf=""
  if [ -z "$errf" ]; then
    _SFTP_OUT="$(printf '%s\n' "$1" | _helper_sftp_run 2>/dev/null)"; _SFTP_RC=$?
    _helper_log "could not create a temp file to keep the helper's replies apart from its own echo — this session is judged on its EXIT STATUS alone"
    return 0
  fi
  _SFTP_OUT="$(printf '%s\n' "$1" | _helper_sftp_run 2>"$errf")"; _SFTP_RC=$?
  _SFTP_ERR="$(cat "$errf" 2>/dev/null)"
  rm -f "$errf"
  return 0
}

_helper_sftp_said() {
  local replies rest text
  replies="$(printf '%s' "$_SFTP_ERR" | tr '\n' ';')"
  rest="$(printf '%s' "$_SFTP_OUT" \
          | grep -vE '^(sftp>|Connected to |Warning: Permanently added |Fetching |Uploading |Retrieving |Changing |Remote working directory)' \
          | tr '\n' ';')" || true
  if [ -n "${replies//[[:space:];]/}" ] && [ -n "${rest//[[:space:];]/}" ]; then
    text="$(printf '%s (session output: %s)' "$replies" "$rest")"
  elif [ -n "${replies//[[:space:];]/}" ]; then
    text="$replies"
  elif [ -n "${rest//[[:space:];]/}" ]; then
    text="$(printf '(the far end said nothing; the session printed: %s)' "$rest")"
  else
    text="$(printf '(the transfer printed nothing at all; sftp exited %s)' "$_SFTP_RC")"
  fi
  _helper_scrub_target "$text"
}

_helper_scrub_target() {
  local text="$1" host="${HELPER#*@}" collapsed
  [ -n "$HELPER" ] && [ "${#HELPER}" -ge 4 ] && text="${text//"$HELPER"/HELPER}"
  [ -n "$host" ] && [ "${#host}" -ge 4 ] && text="${text//"$host"/HELPER}"
  collapsed="$(printf '%s' "$text" | sed -E 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/REDACTED-ADDRESS/g' 2>/dev/null)"
  [ -n "$collapsed" ] && text="$collapsed"
  printf '%s' "$text"
}

_helper_ssh_raw() {
  local to=(); [ -n "${_HELPER_OP_TIMEOUT:-}" ] && to=(timeout -k 5 "$_HELPER_OP_TIMEOUT")
  if [ "$_HELPER_AUTH" = password ]; then
    _helper_pass_run ssh -n \
      -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
      -p "$HELPER_PORT" "${_HELPER_SSH_OPTS[@]}" "$HELPER" "$@"
  else
    "${to[@]}" ssh -n -i "$HELPER_KEY" -o IdentitiesOnly=yes -o PreferredAuthentications=publickey -o BatchMode=yes \
      -p "$HELPER_PORT" "${_HELPER_SSH_OPTS[@]}" "$HELPER" "$@"
  fi
}

_shq()   { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
_sftpq() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

_HELPER_ERR_RE='permission denied|no such file|not found|couldn.?t|cannot|can.?t|not a regular file|no space left|quota exceeded|disk quota|(^|[^[:alnum:]])(failure|failed)([^[:alnum:]]|$)|fail$|^(remote|local|download|upload|stat|lstat|open|read|write|rename|mkdir|rmdir|remove|readdir|setstat|symlink|realpath)[a-z_]* .*: '

_HELPER_AUTH_RE='permission denied ?\(|permission denied, please|authentication failed|no more authentication methods|too many authentication failures|access denied|unable to authenticate'

_HELPER_XPORT_RE='connection (timed out|closed|reset)|lost connection|broken pipe|connection to .* closed|no route to host|network is unreachable|banner exchange|kex_exchange|client_loop|write failed|message authentication code'

_helper_auth_pin_origin() {
  [ -n "$HELPER_AUTH_CACHE" ] || return 0
  printf ". NB nobody necessarily TYPED that: the boot chain preloads it from the durable auth fact at '%s', so unsetting the environment variable alone does NOT lift the pin — delete that file too when you are deliberately re-deriving the auth (docs/handbook/HELPER-HARDENING.md §4)" "$HELPER_AUTH_CACHE"
}

_helper_auth_skip_reason() {
  case "$1" in
    key)
      [ "$HELPER_AUTH" = password ] && { printf "key auth was NOT attempted, so the key '%s' is not implicated — PROVISIONER_HELPER_AUTH=password pins this estate to password auth (a pubkey attempt against a password-only helper is a wasted failed login and accrues toward the provider's ban)%s" "$HELPER_KEY" "$(_helper_auth_pin_origin)"; return 0; }
      [ -n "$HELPER_KEY" ] || { printf 'key auth was NOT attempted — no key path is configured (PROVISIONER_HELPER_ID/HELPER_ID are empty)'; return 0; }
      [ -f "$HELPER_KEY" ] || { printf "key auth was NOT attempted — the key file '%s' does not exist on this host" "$HELPER_KEY"; return 0; }
      ;;
    password)
      [ "$HELPER_AUTH" = key ] && { printf "password auth was NOT attempted, so the password file '%s' is not implicated — PROVISIONER_HELPER_AUTH=key pins this estate to key auth%s" "$HELPER_PASS_FILE" "$(_helper_auth_pin_origin)"; return 0; }
      [ -n "$HELPER_PASS_FILE" ] || { printf 'password auth was NOT attempted — no password file is configured (PROVISIONER_HELPER_PASS_FILE is empty)'; return 0; }
      [ -f "$HELPER_PASS_FILE" ] || { printf "password auth was NOT attempted — the password file '%s' does not exist on this host" "$HELPER_PASS_FILE"; return 0; }
      [ -n "$(_helper_pass_transport)" ] || { _helper_askpass_dir >/dev/null 2>&1 || :
        printf 'password auth was NOT attempted — this host has no usable way to SUPPLY a password: no exec-capable SSH_ASKPASS directory and no sshpass. Set PROVISIONER_ASKPASS_DIR to an exec-capable dir, or install sshpass.%s' "$(_helper_askpass_audit)"; return 0; }
      ;;
  esac
  return 0    # printed nothing ⇒ this auth WILL be attempted
}

_helper_auth_probe() {
  if [ -z "$(_helper_auth_skip_reason key)" ]; then
    if printf 'quit\n' | timeout -k 5 "$HELPER_PROBE_TIMEOUT" sftp -i "$HELPER_KEY" -o IdentitiesOnly=yes \
         -o PreferredAuthentications=publickey -o BatchMode=yes \
         -P "$HELPER_PORT" "${_HELPER_SSH_OPTS[@]}" "$HELPER" >/dev/null 2>"${_HELPER_PROBE_ERRF:-/dev/null}"; then
      printf 'key'; return 0
    fi
  fi
  if [ -z "$(_helper_auth_skip_reason password)" ]; then
    [ -z "${_HELPER_PROBE_ERRF:-}" ] || : > "$_HELPER_PROBE_ERRF"
    if printf 'quit\n' | _HELPER_OP_TIMEOUT="$HELPER_PROBE_TIMEOUT" _helper_pass_run sftp \
         -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
         -P "$HELPER_PORT" "${_HELPER_SSH_OPTS[@]}" "$HELPER" >/dev/null 2>"${_HELPER_PROBE_ERRF:-/dev/null}"; then
      printf 'password'; return 0
    fi
  fi
  return 1
}

_helper_reach() {
  local host out rc
  host="${HELPER#*@}"
  [ -n "$host" ] || { printf 'untestable'; return 0; }
  out="$(timeout 5 bash -c 'exec 3<>/dev/tcp/"$0"/"$1"' "$host" "$HELPER_PORT" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && { printf 'open'; return 0; }
  out="$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')"
  case "$out" in
    *"no such file or directory"*) printf 'untestable'; return 0;;
  esac
  case "$out" in
    *"name or service not known"*|*"temporary failure in name resolution"*|\
    *"nodename nor servname"*|*"unknown host"*) printf 'dns'; return 0;;
  esac
  case "$out" in
    *"connection refused"*) printf 'refused'; return 0;;
  esac
  case "$out" in
    *"no route to host"*|*"network is unreachable"*|*"host is unreachable"*|\
    *"connection timed out"*|*"timed out"*) printf 'unreachable'; return 0;;
  esac
  [ "$rc" = 124 ] && { printf 'unreachable'; return 0; }   # `timeout` killed the connect
  printf 'untestable'
}

_helper_log_no_auth() {
  local reach port_note key_skip pw_skip tried lead
  if [ "$HELPER_PORT_SRC" = default ]; then
    port_note="port ${HELPER_PORT} is this lib's DEFAULT — nothing set PROVISIONER_HELPER_PORT for this run, so a helper listening anywhere else fails here with the credentials untouched"
  else
    port_note="port ${HELPER_PORT} came from PROVISIONER_HELPER_PORT"
  fi
  key_skip="$(_helper_auth_skip_reason key)"
  pw_skip="$(_helper_auth_skip_reason password)"
  if [ -n "$key_skip" ] && [ -n "$pw_skip" ]; then
    tried="NO credential was offered: not one byte was sent, so nothing here is an authentication failure, it is a LOCAL CONFIGURATION fault on this host. ${key_skip}; ${pw_skip}"
    lead="could not USE HELPER:${HELPER_PORT}"
  elif [ -z "$key_skip" ] && [ -z "$pw_skip" ]; then
    tried="key '${HELPER_KEY}' and password '${HELPER_PASS_FILE}' were BOTH offered and neither completed an SFTP session"
  elif [ -z "$key_skip" ]; then
    tried="the ONLY credential offered was the key '${HELPER_KEY}', and it did not complete an SFTP session; ${pw_skip}"
  else
    tried="the ONLY credential offered was the password from '${HELPER_PASS_FILE}', and it did not complete an SFTP session; ${key_skip}"
  fi
  [ -n "${lead:-}" ] || lead="could not authenticate to HELPER:${HELPER_PORT}"

  reach="$(_helper_reach)"
  case "$reach" in
    refused)
      _helper_log "nothing is listening on HELPER:${HELPER_PORT} — the TCP connection was REFUSED, so no SSH session started and NO credential was tried. CONNECTIVITY fault, not an auth failure: ${port_note}." ;;
    unreachable)
      _helper_log "nothing answered on HELPER:${HELPER_PORT} — the TCP connection timed out or had no route, so no SSH session started and NO credential was tried. CONNECTIVITY fault, not an auth failure: ${port_note}." ;;
    dns)
      _helper_log "the helper's host name does not RESOLVE — nothing was connected to on HELPER:${HELPER_PORT} and NO credential was tried. DNS fault, not an auth failure: ${port_note}. (The helper needs an A record — the SFTP path is IPv4-only.)" ;;
    open)
      _helper_log "${lead} — ${tried}. Something IS listening there, but that it is the helper's SFTP service is NOT established — ${port_note}." ;;
    *)
      _helper_log "${lead} — ${tried}. This host could not test whether anything is listening on that port, so a WRONG PORT is not ruled out: ${port_note}." ;;
  esac
}

_helper_alias_probe() {
  local pick=""
  if [ "$HELPER_AUTH" != key ] && [ -s "$HELPER_PASS_FILE" ]; then pick=password
  elif [ "$HELPER_AUTH" != password ] && [ -n "$HELPER_KEY" ] && [ -f "$HELPER_KEY" ]; then pick=key; fi
  [ -n "$pick" ] || { _helper_log_no_auth; return 1; }
  _HELPER_AUTH="$pick"
  _helper_crypt_ready && return 0
  _HELPER_AUTH=""
  case "$(_helper_crypt_failure_kind)" in
    auth) _HELPER_DETECT_REFUSED=1
          _helper_log "access path: the seedbox REFUSED the login on HELPER:${HELPER_PORT} - one attempt, not retried; a repeat can lock it: ${_CRY_ERR}" ;;
    xport) _helper_log_no_auth ;;
  esac
  return 1
}

helper_detect() {
  [ -n "$_HELPER_DETECTED" ] && return 0
  [ -n "$HELPER" ] || { _helper_log "HELPER (user@host) not set — cannot reach helper"; return 2; }
  local auth errf; _HELPER_DETECT_REFUSED=0
  errf="$(umask 077; mktemp "${TMPDIR:-/tmp}/prov-probe.XXXXXX" 2>/dev/null)" || errf=""
  _HELPER_PROBE_ERRF="$errf"
  if _helper_crypt_alias; then   # #1203: the access path signs in once, through rclone - no raw sftp/ssh probe
    [ -z "$errf" ] || rm -f "$errf"; _HELPER_PROBE_ERRF=""
    _helper_alias_probe || return 1
    auth="$_HELPER_AUTH"
  else
  auth="$(_helper_auth_probe)" || {
    [ -z "$errf" ] || { grep -qiE "$_HELPER_AUTH_RE" "$errf" 2>/dev/null && _HELPER_DETECT_REFUSED=1; rm -f "$errf"; }
    _HELPER_PROBE_ERRF=""; _helper_log_no_auth; return 1; }
  [ -z "$errf" ] || rm -f "$errf"
  _HELPER_PROBE_ERRF=""
  fi
  _HELPER_AUTH="$auth"
  if [ -n "$HELPER_AUTH_CACHE" ]; then
    if [ ! -f "$HELPER_AUTH_CACHE" ] || [ "$(cat "$HELPER_AUTH_CACHE" 2>/dev/null)" != "$_HELPER_AUTH" ]; then
      if ( umask 077; printf '%s\n' "$_HELPER_AUTH" > "$HELPER_AUTH_CACHE" ) 2>/dev/null; then
        _helper_log_quiet "recorded helper auth '${_HELPER_AUTH}' → ${HELPER_AUTH_CACHE}"
      else
        _helper_log_quiet "could not persist helper auth to ${HELPER_AUTH_CACHE} (non-fatal)"
      fi
    fi
  fi
  if _helper_crypt_alias; then _HELPER_EXEC=0   # #1203: no exec probe; the access path is file transfer only
  elif _HELPER_OP_TIMEOUT="$HELPER_PROBE_TIMEOUT" _helper_ssh_raw true >/dev/null 2>&1; then _HELPER_EXEC=1; else _HELPER_EXEC=0; fi
  _HELPER_DETECTED=1
  _helper_log_quiet "HELPER → port=${HELPER_PORT} auth=${_HELPER_AUTH} channel=$([ "$_HELPER_EXEC" = 1 ] && echo exec || echo sftp-only)"
  return 0
}

helper_auth()    { helper_detect >/dev/null 2>&1; printf '%s' "$_HELPER_AUTH"; }
helper_channel() { helper_detect >/dev/null 2>&1; [ "$_HELPER_EXEC" = 1 ] && printf 'exec' || printf 'sftp-only'; }
helper_reset_detection() { _HELPER_DETECTED=""; _HELPER_AUTH=""; _HELPER_EXEC=""; }

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
_HELPER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
_helper_crypt_khfile() { printf '%s' "${HOME:-/root}/.ssh/known_hosts"; }
_helper_hostspec_inline() {
  [ -n "${1-}" ] || return 2
  case "${2-}" in
    ""|22) printf '%s\n' "$1" ;;
    *)     printf '[%s]:%s\n' "$1" "$2" ;;
  esac
}
_helper_crypt_hostkey() {
  local kh host spec; kh="$(_helper_crypt_khfile)"; host="${HELPER#*@}"
  spec="$(sh "${_HELPER_LIB_DIR}/known_hosts_hostspec.sh" "$host" "$HELPER_PORT" 2>/dev/null)" && [ -n "$spec" ] \
    || spec="$(_helper_hostspec_inline "$host" "$HELPER_PORT")" && [ -n "$spec" ] \
    || { _helper_log "crypt mode: cannot compute the known_hosts name (bootstrap/known_hosts_hostspec.sh unreadable) — refusing"; return 2; }
  ssh-keygen -F "$spec" -f "$kh" >/dev/null 2>&1 && return 0
  mkdir -p "$(dirname "$kh")" 2>/dev/null
  ssh -n -o BatchMode=yes -o PreferredAuthentications=none -o PubkeyAuthentication=no \
      -o UserKnownHostsFile="$kh" -p "$HELPER_PORT" "${_HELPER_SSH_OPTS[@]}" "$HELPER" true >/dev/null 2>&1
  ssh-keygen -F "$spec" -f "$kh" >/dev/null 2>&1 && return 0
  _helper_log "crypt mode: no host key on record for HELPER in '${kh}' and first contact did not record one — refusing to talk to an unverified host"
  return 2
}
_CRY_ALIAS_OK=""
_helper_crypt_alias_plain_folder() {
  [ "$_CRY_ALIAS_OK" = 1 ] && return 0
  local xk="$_CRY_X_KEY" o r; _CRY_X_KEY=""; _CRY_ALIAS_OK=1
  _helper_crypt_session lsf "prov-crypt:"
  o="$_CRY_OUT"; r="$_CRY_RC"; _CRY_X_KEY="$xk"
  if [ "$r" -ne 0 ]; then
    case "$r" in 3|4) _CRY_RC="$r"; return 0 ;; esac   # no root listing = nothing encrypted to read as empty
    _CRY_ALIAS_OK=""; _helper_log "access path: could not list the folder to check it is not encrypted (rclone rc ${r}) - refusing"; return 2
  fi
  if _helper_crypt_looks_encrypted <<<"$o"; then
    _CRY_ALIAS_OK=""; _helper_log "access path: this folder is encrypted; the access path without a key would read it as empty - refusing"; return 2
  fi
  return 0
}
_helper_crypt_ready() {
  local kf; kf="$(_helper_crypt_keyfile)"
  if _helper_crypt_alias; then   # #1202: no key to check, only the tool, the host key and that the folder is not encrypted
    command -v rclone >/dev/null 2>&1 || { _helper_log "access path: rclone is not installed - install it"; return 2; }
    _helper_crypt_hostkey || return $?
    _helper_crypt_alias_plain_folder; return $?
  fi
  [ -s "$kf" ] || { _helper_log "crypt mode: key file '${kf}' is missing or empty — refusing to fall back to PLAINTEXT"; return 2; }
  command -v rclone >/dev/null 2>&1 || { _helper_log "crypt mode: a helper crypt key is configured but rclone is not installed — install rclone"; return 2; }
  [ -z "$(find "$kf" -maxdepth 0 -perm /077 2>/dev/null)" ] || { _helper_log "crypt mode: key file '${kf}' is group/other accessible — refusing; chmod 600"; return 2; }
  _helper_crypt_hostkey
}
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
_helper_crypt_base() {   # rc 1 = a base that cannot be trusted (a '..' segment, a newline or a CR)
  local b="${HELPER_PRESENCE_BASE-${REMOTE_DIR-${PROVISIONER_REMOTE_DIR-}}}"
  case "$b" in *$'\n'*|*$'\r'*) return 1 ;; esac
  while :; do case "$b" in /*) b="${b#/}" ;; ./*) b="${b#./}" ;; *) break ;; esac; done
  case "$b" in .) b="" ;; esac
  case "/${b}/" in */../*) return 1 ;; esac
  printf '%s' "${b%/}"
}
_helper_crypt_remote_stanza() {   # <obscured password> [<obscured salt>]
  local b; b="$(_helper_crypt_base)" || return 1
  printf '[prov-crypt]\ntype = crypt\nremote = prov-sftp:%s\nfilename_encryption = standard\ndirectory_name_encryption = true\npassword = %s\n' "$b" "$1"
  [ -z "${2:-}" ] || printf 'password2 = %s\n' "$2"
}
_helper_crypt_looks_encrypted() {
  local t; t="$(cat)"
  grep -qxE '(scripts|secrets|images|state|restic|version|version-built|downloads)/?' <<<"$t" && return 1
  grep -qE '^[0-9a-v]{26,}/?$' <<<"$t"
}
_helper_crypt_alias_stanza() { local b; b="$(_helper_crypt_base)" || return 1; printf '[prov-crypt]\ntype = alias\nremote = prov-sftp:%s\n' "$b"; }
_CRY_DIR=""
_helper_crypt_conf_dir() {
  local d o
  while IFS= read -r d; do
    o="$(cat "$d/owner" 2>/dev/null)"
    { [ -n "$o" ] && kill -0 "$o" 2>/dev/null; } && continue
    rm -rf "$d"
  done < <(find "$1" -maxdepth 1 -name 'prov-rclone.*' -user "$(id -u)" -mmin +"${PROVISIONER_HELPER_CRYPT_STALE_MIN:-120}" 2>/dev/null)
  _CRY_DIR="$(umask 077; mktemp -d "$1/prov-rclone.XXXXXX" 2>/dev/null)" || { _CRY_DIR=""; return 1; }
  printf '%s' "$BASHPID" > "${_CRY_DIR}/owner" 2>/dev/null
}
_helper_crypt_conf_new() {
  local kf pw salt want; kf="$(_helper_crypt_keyfile)"
  _helper_crypt_conf_dir "${TMPDIR:-/tmp}" || return 1
  if _helper_crypt_alias; then   # #1202: the same remote name over plain files, no key read
    ( umask 077
      { _helper_crypt_sftp_stanza || exit 1
        _helper_crypt_alias_stanza
      } > "${_CRY_DIR}/rclone.conf" ) 2>/dev/null || { rm -rf "$_CRY_DIR"; _CRY_DIR=""; return 1; }
    chmod 600 "${_CRY_DIR}/rclone.conf"; return
  fi
  pw="$(_helper_crypt_obscure "$kf" 1)"; [ -n "$pw" ] || { rm -rf "$_CRY_DIR"; _CRY_DIR=""; return 1; }
  salt="$(_helper_crypt_obscure "$kf" 2)"
  want="$(sed -n 2p "$kf" | tr -d '\r')"
  if [ -n "$want" ] && [ -z "$salt" ]; then   # never silently drop password2
    _helper_log "crypt mode: the key file's salt (line 2) could not be obscured — refusing"
    rm -rf "$_CRY_DIR"; _CRY_DIR=""; return 1
  fi
  ( umask 077
    { _helper_crypt_sftp_stanza || exit 1
      _helper_crypt_remote_stanza "$pw" "$salt"
    } > "${_CRY_DIR}/rclone.conf" ) 2>/dev/null || { rm -rf "$_CRY_DIR"; _CRY_DIR=""; return 1; }
  chmod 600 "${_CRY_DIR}/rclone.conf"
}
_CRY_RC=0; _CRY_OUT=""; _CRY_ERR=""; _CRY_PID=""; _CRY_OLDTRAPS=""; _CRY_SIGRC=""; _CRY_X_KEY=""; _CRY_X_BASE=""
_helper_crypt_untrap() { trap - INT TERM HUP; [ -z "$_CRY_OLDTRAPS" ] || eval "$_CRY_OLDTRAPS"; _CRY_OLDTRAPS=""; }
_helper_crypt_abort() {
  [ -z "$_CRY_PID" ] || kill "$_CRY_PID" 2>/dev/null
  [ -z "$_CRY_DIR" ] || rm -rf "$_CRY_DIR"
  _CRY_DIR=""; _helper_crypt_untrap
  case "$1" in INT) _CRY_SIGRC=130 ;; HUP) _CRY_SIGRC=129 ;; *) _CRY_SIGRC=143 ;; esac
  kill -s "$1" "$BASHPID"   # the caller's own trap runs; if it does not exit, the session returns _CRY_SIGRC
}
_helper_crypt_session() {
  local to=(); [ -n "${_HELPER_OP_TIMEOUT:-}" ] && to=(timeout -k 5 "$_HELPER_OP_TIMEOUT")
  _CRY_OUT=""; _CRY_ERR=""; _CRY_RC=255
  if [ -n "$_CRY_X_KEY" ]; then _helper_crypt_x_ready || return 0; else _helper_crypt_ready || return 0; fi
  _CRY_OLDTRAPS="$(trap -p INT TERM HUP)"
  trap '_helper_crypt_abort INT' INT; trap '_helper_crypt_abort TERM' TERM; trap '_helper_crypt_abort HUP' HUP
  local mk=_helper_crypt_conf_new; [ -z "$_CRY_X_KEY" ] || mk=_helper_crypt_x_conf_new
  "$mk" || { _CRY_ERR="could not build the rclone config"; _helper_log "crypt mode: $_CRY_ERR"; _helper_crypt_untrap; return 0; }
  ( umask 077; exec "${to[@]}" rclone --config "${_CRY_DIR}/rclone.conf" --contimeout "${HELPER_CONNECT_TIMEOUT}s" --retries 1 --low-level-retries 1 "$@" >"${_CRY_DIR}/out" 2>"${_CRY_DIR}/err" </dev/null ) &   # 0600 downloads (#1075)
  _CRY_PID=$!
  wait "$_CRY_PID" && _CRY_RC=0 || _CRY_RC=$?   # never a bare `wait`: it would abort a set -e caller mid-session
  _CRY_PID=""
  if [ -n "$_CRY_SIGRC" ]; then _CRY_RC="$_CRY_SIGRC"; _CRY_SIGRC=""; return 0; fi   # aborted; dir already gone
  _CRY_OUT="$(cat "${_CRY_DIR}/out" 2>/dev/null)"
  _CRY_ERR="$(_helper_scrub_target "$(cat "${_CRY_DIR}/err" 2>/dev/null)")"
  rm -rf "$_CRY_DIR"; _CRY_DIR=""
  _helper_crypt_untrap
  return 0
}
_helper_crypt_local() { case "$1" in /*|./*) printf '%s' "$1" ;; *) printf './%s' "$1" ;; esac; }
_helper_crypt_p() {
  local p="$1"
  while :; do case "$p" in /*) p="${p#/}" ;; ./*) p="${p#./}" ;; *) break ;; esac; done
  case "$p" in .) p="" ;; esac
  case "/${p}/" in */../*) return 1 ;; esac
  p="${p%/}"
  local b; b="$(_helper_crypt_base)" || return 1
  if [ -n "$b" ] && [ -n "$p" ]; then   # #1228: spelled relative to the estate folder (empty = its root); a path outside it is refused
    case "$p" in "$b") p="" ;; "$b"/*) p="${p#"$b"/}" ;; *) return 1 ;; esac
  fi
  printf 'prov-crypt:%s' "$p"
}
_helper_crypt_failure_kind() {   # auth | xport | other, off _CRY_ERR + _CRY_RC
  if grep -qiE "$_HELPER_AUTH_RE" <<<"$_CRY_ERR"; then echo auth
  elif grep -qiE "$_HELPER_XPORT_RE" <<<"$_CRY_ERR"; then echo xport
  else case "$_CRY_RC" in 124|137|255|129|130|143) echo xport ;; *) echo other ;; esac; fi
}
_helper_crypt_missing() {   # the far end positively said "not there" (rclone exit 3/4)
  case "$_CRY_RC" in 3|4) [ "$(_helper_crypt_failure_kind)" = other ] ;; *) return 1 ;; esac
}

_HELPER_CRYPT_CANARY='.provisioner-crypt-canary'
_CRY_CANARY_OK=""
_helper_crypt_canary_put() {
  local f; f="$(umask 077; mktemp "${TMPDIR:-/tmp}/prov-canary.XXXXXX" 2>/dev/null)" || return 1
  printf 'provisioner crypt canary (#1075)\n' > "$f"
  _helper_crypt_session copyto -- "$f" "prov-crypt:${_HELPER_CRYPT_CANARY}"
  rm -f "$f"; [ "$_CRY_RC" -eq 0 ]
}
_helper_crypt_canary() {   # rc 0 the key is proven · 2 an absence/empty answer is NOT to be trusted
  [ "$_CRY_CANARY_OK" = 1 ] && return 0
  _helper_crypt_alias && return 0   # #1202: plain files, nothing to prove - so an rclone exit 3 is a real absence
  local out
  _helper_crypt_session lsf "prov-crypt:"
  if [ "$_CRY_RC" -ne 0 ]; then
    _helper_crypt_missing || return 2
    if [ "${PROVISIONER_HELPER_CRYPT_INIT:-}" = 1 ]; then
      _helper_crypt_canary_put || { _helper_log "crypt mode: could not write the key marker - refusing to trust an empty answer"; return 2; }
    fi
    _CRY_CANARY_OK=1; return 0
  fi
  out="$_CRY_OUT"
  if grep -qxF "$_HELPER_CRYPT_CANARY" <<<"$out"; then _CRY_CANARY_OK=1; return 0; fi
  if [ -n "$(tr -d '[:space:]' <<<"$out")" ]; then   # real names decrypt: the key is right; heal the marker
    _helper_crypt_canary_put >/dev/null 2>&1; _CRY_CANARY_OK=1; return 0
  fi
  _helper_crypt_session lsf "prov-sftp:$(_helper_crypt_base)"   # the estate folder's raw listing (#1228)
  if [ "$_CRY_RC" -ne 0 ]; then _helper_crypt_missing || return 2; _CRY_OUT=""; fi
  if [ -z "$(tr -d '[:space:]' <<<"$_CRY_OUT")" ] || [ "${PROVISIONER_HELPER_CRYPT_INIT:-}" = 1 ]; then
    _helper_crypt_canary_put || { _helper_log "crypt mode: could not write the key marker - refusing to trust an empty answer"; return 2; }
    _CRY_CANARY_OK=1; return 0
  fi
  _helper_log "crypt mode: the helper folder holds files but none decrypt with this key - a wrong key, or an existing plain folder not yet migrated; an empty or missing answer is NOT trusted"
  return 2
}
helper_crypt_marker_init() {
  helper_detect || return 2
  _helper_crypt_on || return 2
  _helper_crypt_alias && return 0   # #1202: no key, no marker
  local HELPER_PRESENCE_BASE="$1"   # #1228: the crypt remote is rooted at THIS folder for every call below
  local d; d="$(_helper_crypt_base)" || return 2
  _CRY_CANARY_OK=""
  _helper_crypt_session lsf "prov-crypt:"
  if [ "$_CRY_RC" -ne 0 ]; then _helper_crypt_missing || return 2; _CRY_OUT=""; fi   # a folder not made yet is empty (#1228)
  grep -qxF "$_HELPER_CRYPT_CANARY" <<<"$_CRY_OUT" && return 0   # already this key's folder
  if [ -n "$d" ]; then
    _helper_crypt_session lsf "prov-sftp:${d}"
    if [ "$_CRY_RC" -eq 0 ]; then
      if [ -n "$(tr -d '[:space:]' <<<"$_CRY_OUT")" ]; then
        _helper_log "crypt mode: '${1}' already holds plain files that this key cannot read - refusing to start an encrypted layout beside them"
        return 1
      fi
    elif ! { [ "$_CRY_RC" -eq 3 ] || [ "$_CRY_RC" -eq 4 ]; } || [ "$(_helper_crypt_failure_kind)" != other ]; then
      return 2
    fi
  fi
  _CRY_CANARY_OK=""
  PROVISIONER_HELPER_CRYPT_INIT=1 _helper_crypt_canary
}
_helper_crypt_skipped() { grep -qiE 'undecryptable|not decrypt|illegal base32' <<<"$_CRY_ERR"; }
_helper_crypt_absent() {   # rc 1 absent (trusted) · 2 could not tell
  _HELPER_CRYPT_UNNAMEABLE=""; _HELPER_CRYPT_UNNAMEABLE_NAME=""   # no stale cause from an earlier call (#1287)
  local sk=0; _helper_crypt_skipped && sk=1
  _helper_crypt_canary || return 2
  if [ "$sk" = 1 ] && [ "${HELPER_ABSENT_TOLERATE_PLAIN:-}" = 1 ] && [ -n "${1:-}" ]; then
    local skl="" nm ln okp=1 nskip=0
    while IFS= read -r ln; do
      nm="$(sed -nE 's#^([0-9]{4}/[0-9/]+ [0-9:]+ )?[A-Z]+ *: *##; s#^([^ /:]+)/?: Skipping undecryptable (file|dir) name.*$#\1#p' <<<"$ln")"
      if [ -z "$nm" ] || [ "$nm" = "$1" ]; then okp=0; break; fi
      skl="${skl:+$skl, }'$nm'"; nskip=$((nskip+1))
    done < <(printf '%s\n' "$_CRY_ERR" | grep -iE 'undecryptable|not decrypt|illegal base32')
    if [ "$okp" = 1 ] && [ -n "$skl" ]; then
      _helper_log "crypt mode: absence of '${1}' established; plain entries this key cannot name were skipped, by name: ${skl} [${nskip} skipped]"
      return 1
    fi
  fi
  if [ "$sk" = 1 ]; then
    _HELPER_CRYPT_UNNAMEABLE=1
    _HELPER_CRYPT_UNNAMEABLE_NAME="$(grep -iE 'undecryptable|not decrypt|illegal base32' <<<"$_CRY_ERR" | head -n 1 | sed -E 's#^([0-9]{4}/[0-9/]+ [0-9:]+ )?[A-Z]+ *: *##; s#: .*##')"
    _helper_log "crypt mode: names that could not be decrypted were skipped, so absence is not established"; return 2
  fi
  return 1
}

_helper_crypt_stat() {
  local rp parent base n s
  rp="$(_helper_crypt_p "$1")" || return 2
  base="${rp#prov-crypt:}"; parent="${base%/*}"; [ "$parent" = "$base" ] && parent=""; base="${base##*/}"
  [ -n "$base" ] || { printf '%s' -1; return 0; }
  _helper_crypt_session lsf --format ps --separator "$(printf '\t')" "prov-crypt:${parent}"
  if [ "$_CRY_RC" -ne 0 ]; then
    _helper_crypt_missing && { _helper_crypt_absent "$base"; return $?; }
    return 2
  fi
  while IFS=$'\t' read -r n s; do
    [ "${n%/}" = "$base" ] || continue
    case "$n" in */) printf '%s' -1 ;; *) printf '%s' "$s" ;; esac
    return 0
  done <<<"$_CRY_OUT"
  _helper_crypt_absent "$base"; return $?
}

_helper_crypt_presence() {
  local v
  _HELPER_CRYPT_UNNAMEABLE=""; _HELPER_CRYPT_UNNAMEABLE_NAME=""   # set by _helper_crypt_absent (#1287)
  _helper_crypt_ready || return 2
  _helper_crypt_stat "$1" >/dev/null; v=$?
  case "$v" in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}
_helper_crypt_put_verify() {
  local path="$1" src="${2:-}" want="" got rc
  [ -n "$src" ] && [ -f "$src" ] && want="$(wc -c < "$src" 2>/dev/null | tr -d '[:space:]')"
  case "$want" in *[!0-9]*) want="" ;; esac
  got="$(_helper_crypt_stat "$path")"; rc=$?
  case "$rc" in 0) ;; 1) return 1 ;; *) return 3 ;; esac
  [ -n "$want" ] || return 0
  if [ "$got" = "$want" ]; then _helper_put_verify_matched "$path" "$src" "$want"; return $?; fi
  _helper_log "verify: '${path}' is ${got} bytes on the helper, but the file we sent is ${want} bytes"
  return 4
}

_helper_crypt_get() {
  local src="$1" dst="$2" rp
  rp="$(_helper_crypt_p "$src")" || { _helper_log "get: refused path ($src)"; return 1; }
  _helper_crypt_session copyto -- "$rp" "$(_helper_crypt_local "$dst")"
  if [ "$_CRY_RC" -ne 0 ]; then
    if [ "$(_helper_crypt_failure_kind)" = auth ]; then _helper_log "get failed ($src → $dst): the helper REFUSED the login - not retried, a repeat can lock it: ${_CRY_ERR}"; return 2; fi
    _helper_log "get failed ($src → $dst): rclone exited ${_CRY_RC} — ${_CRY_ERR}"; return 1
  fi
  [ -f "$dst" ] || { _helper_log "get: $dst not present after download"; return 1; }
}

_helper_crypt_put() {
  local src="$1" dst="$2" rp why v n=1 back="${PROVISIONER_HELPER_PUT_BACKOFF:-2}"
  local tries="${PROVISIONER_HELPER_PUT_ATTEMPTS:-3}" budget="${PROVISIONER_HELPER_PUT_BUDGET:-}" t0=$SECONDS
  [ -f "$src" ] || { _helper_log "put: local source missing: $src"; return 2; }
  rp="$(_helper_crypt_p "$dst")" || { _helper_log "put: refused path ($dst)"; return 2; }
  if [ -z "$budget" ]; then if [ -n "${_HELPER_OP_TIMEOUT:-}" ]; then budget=$(( _HELPER_OP_TIMEOUT * 3 )); else budget=180; fi; fi
  while :; do
    _helper_crypt_session copyto -- "$(_helper_crypt_local "$src")" "$rp"
    if [ "$_CRY_RC" -ne 0 ]; then
      if [ "$(_helper_crypt_failure_kind)" = auth ]; then _helper_log "put failed ($src → $dst): the helper REFUSED the login - not retried, a repeat can lock it: ${_CRY_ERR}"; return 1; fi
      why="rclone exited ${_CRY_RC} — whether '${dst}' landed is NOT established: ${_CRY_ERR}"
    else
      _helper_crypt_put_verify "$dst" "$src"; v=$?
      case "$v" in
        0) [ "$n" -gt 1 ] && _helper_log "put SUCCEEDED on attempt ${n} ($src → $dst)"; return 0 ;;
        1) why="rclone exited 0 but '${dst}' is NOT there afterwards" ;;
        4) why="'${dst}' IS on the helper but it is NOT the file we just sent" ;;
        *) why="the upload exited 0, but the VERIFICATION listing did not complete — whether '${dst}' landed is NOT established" ;;
      esac
    fi
    if [ "$n" -ge "$tries" ]; then _helper_log "put FAILED after ${n} attempt(s) ($src → $dst): ${why}"; return 1; fi
    if [ $(( SECONDS - t0 )) -ge "$budget" ]; then _helper_log "put FAILED after ${n} attempt(s) ($src → $dst) — retry budget ${budget}s exhausted: ${why}"; return 1; fi
    _helper_log "put attempt ${n}/${tries} did not land ($src → $dst): ${why} — retrying in ${back}s"
    sleep "$back"; back=$(( back * 2 )); n=$(( n + 1 ))
  done
}

_helper_crypt_foreign() {
  grep -qiE 'undecryptable|not decrypt|illegal base32' <<<"$_CRY_ERR" || return 0
  printf 'ssh: rclone skipped names it could not decrypt in %s — the listing is incomplete\n' "$1" >&2
  return 2
}
_helper_crypt_ls() {
  local rp; rp="$(_helper_crypt_p "${1:-.}")" || return 2
  _helper_crypt_session lsf "$rp"
  if [ "$_CRY_RC" -ne 0 ]; then
    if _helper_crypt_missing; then
      _helper_crypt_absent; [ $? = 1 ] || { printf 'ssh: rclone found nothing at %s but an absence is not established (key/folder check)\n' "${1:-.}" >&2; return 2; }
      printf "ls: cannot access '%s': No such file or directory\n" "${1:-.}" >&2; return 2
    fi
    printf 'ssh: rclone listing of %s failed (rc %s): %s\n' "${1:-.}" "$_CRY_RC" "$_CRY_ERR" >&2; return 2
  fi
  if [ -z "$(tr -d '[:space:]' <<<"$_CRY_OUT")" ]; then   # an EMPTY listing is only an empty directory under a proven key
    _helper_crypt_foreign "${1:-.}" || return 2
    _helper_crypt_canary || { printf 'ssh: rclone listed %s as empty but the key is not proven (key/folder check)\n' "${1:-.}" >&2; return 2; }
    return 0
  fi
  printf '%s\n' "$_CRY_OUT" | sed -e 's#/$##' -e '/^\./d' -e '/^$/d'
  _helper_crypt_foreign "${1:-.}"
}
_helper_crypt_ls_l() {
  local rp t s n mode mt; rp="$(_helper_crypt_p "${1:-.}")" || return 2
  _helper_crypt_session lsf --format tsp --separator "$(printf '\t')" "$rp"
  if [ "$_CRY_RC" -ne 0 ]; then
    if _helper_crypt_missing; then
      _helper_crypt_absent; [ $? = 1 ] || { printf 'ssh: rclone found nothing at %s but an absence is not established (key/folder check)\n' "${1:-.}" >&2; return 2; }
      printf "Can't ls: '%s' not found\n" "${1:-.}" >&2; return 2
    fi
    printf 'ssh: rclone listing of %s failed (rc %s): %s\n' "${1:-.}" "$_CRY_RC" "$_CRY_ERR" >&2; return 2
  fi
  if [ -z "$(tr -d '[:space:]' <<<"$_CRY_OUT")" ]; then
    _helper_crypt_foreign "${1:-.}" || return 2
    _helper_crypt_canary || { printf 'ssh: rclone listed %s as empty but the key is not proven (key/folder check)\n' "${1:-.}" >&2; return 2; }
    return 0
  fi
  while IFS=$'\t' read -r t s n; do
    [ -n "$n" ] || continue
    mt="$(date -d "$t" '+%b %e %H:%M' 2>/dev/null)" || mt="Jan  1 00:00"
    case "$n" in */) mode="drwxr-xr-x"; n="${n%/}"; s=0 ;; *) mode="-rw-r--r--" ;; esac
    printf '%s 1 0 0 %s %s %s\n' "$mode" "${s:-0}" "$mt" "$n"
  done <<<"$_CRY_OUT"
  _helper_crypt_foreign "${1:-.}"
}

_helper_crypt_mkdir_p() {
  local rp; rp="$(_helper_crypt_p "$1")" || return 2
  _helper_crypt_session mkdir "$rp"; [ "$_CRY_RC" -eq 0 ]
}
_helper_crypt_mkdir_plain() {
  local rc; _helper_mkdir_exclusive_raw "$1"; rc=$?
  if [ "$rc" = 2 ] && grep -qiE "$_HELPER_AUTH_RE" <<<"${_SFTP_ERR:-}"; then
    _helper_log "lock: the seedbox REFUSED the login - one attempt, not retried"
  fi
  return "$rc"
}
_helper_crypt_mkdir_exclusive() {
  local rp path parent enc
  rp="$(_helper_crypt_p "$1")" || return 2
  path="${rp#prov-crypt:}"; [ -n "$path" ] || return 2
  _helper_crypt_canary || return 2
  parent="${path%/*}"; [ "$parent" = "$path" ] && parent=""
  if [ -n "$parent" ]; then
    _helper_crypt_session mkdir "prov-crypt:${parent}"; [ "$_CRY_RC" -eq 0 ] || return 2
  fi
  local fb; fb="$(_helper_crypt_base)" || return 2; fb="${fb:+${fb}/}"   # the lock is a raw mkdir: login-relative, so the folder goes back on (#1228)
  _helper_crypt_alias && { _helper_crypt_mkdir_plain "${fb}${path}"; return $?; }   # #1203: plain name, one raw sftp mkdir (see above)
  _helper_crypt_session cryptdecode --reverse "prov-crypt:" "$path"
  [ "$_CRY_RC" -eq 0 ] || return 2
  enc="$(awk -F'\t' 'NR==1{ v=$NF; sub(/^[ ]+/, "", v); sub(/[ ]+$/, "", v); print v }' <<<"$_CRY_OUT")"
  case "$enc" in
    ''|-*|/*|*/|*//*|"$path"|*[!A-Za-z0-9_=/-]*) _helper_log "crypt mode: could not derive the encrypted lock name"; return 2 ;;
  esac
  _helper_mkdir_exclusive_raw "${fb}${enc}"
}
_helper_crypt_copy() {
  local a b; a="$(_helper_crypt_p "$1")" && b="$(_helper_crypt_p "$2")" || return 2
  _HELPER_OP_TIMEOUT="${PROVISIONER_HELPER_COPY_TIMEOUT:-1800}" _helper_crypt_session copyto -- "$a" "$b"
  [ "$_CRY_RC" -eq 0 ]    # rclone writes a temp name and renames: never a half <dst>
}
_helper_crypt_rename() {
  local a b; a="$(_helper_crypt_p "$1")" && b="$(_helper_crypt_p "$2")" || return 2
  _helper_crypt_session moveto "$a" "$b"
  [ "$_CRY_RC" -eq 0 ] && return 0
  _helper_log "rename failed ($1 → $2): rclone exited ${_CRY_RC} — ${_CRY_ERR}"; return 1
}
_helper_crypt_remove() {
  local rp; rp="$(_helper_crypt_p "$1")" || return 2
  _helper_crypt_session deletefile "$rp"
  _helper_gone "$1" "remove"
}
_helper_crypt_rmdir() {
  local rp; rp="$(_helper_crypt_p "$1")" || return 2
  _helper_crypt_session rmdir "$rp"
  _helper_gone "$1" "rmdir"
}
_helper_crypt_clear_tree() {
  local nfiles="${1:-}" i=0 p rc=0 rp cmd _nl='
' _cr; _cr="$(printf '\r')"
  shift 2>/dev/null || return 2
  case "$nfiles" in ''|*[!0-9]*) return 2 ;; esac
  [ "$#" -ge "$nfiles" ] || return 2
  for p in "$@"; do
    i=$((i+1))
    case "$p" in
      ""|-*|/*|.|..|./*|../*|*/.|*/..|*/./*|*/../*|*//*|*"$_nl"*|*"$_cr"*) continue ;;
    esac
    rp="$(_helper_crypt_p "$p")" || continue
    if [ "$i" -le "$nfiles" ]; then cmd="deletefile"; else cmd="rmdir"; fi
    _helper_crypt_session "$cmd" "$rp"
    [ "$_CRY_RC" -eq 0 ] && continue
    if [ "$cmd" = rmdir ]; then   # real rclone: rmdir is rc 1 for BOTH missing and non-empty — ask, don't infer
      _helper_crypt_presence "$p"
      case $? in 1) continue ;; 0) rc=1; continue ;; *) return 2 ;; esac
    fi
    _helper_crypt_missing && continue
    if [ "$(_helper_crypt_failure_kind)" = other ]; then rc=1; else return 2; fi
  done
  return "$rc"
}

_helper_verify_small_content() {
  local path="$1" src="$2" dir back rc
  dir="$(mktemp -d "${TMPDIR:-/tmp}/prov-putverify.XXXXXX" 2>/dev/null)" || return 3
  back="${dir}/rt"
  if helper_get "$path" "$back" >/dev/null 2>&1 && [ -f "$back" ]; then
    if cmp -s "$src" "$back"; then rc=0; else rc=4; fi
  else
    rc=3
  fi
  rm -rf "$dir" 2>/dev/null || true
  return "$rc"
}

_helper_put_verify_matched() {
  local path="$1" src="$2" size="$3" rc
  [ -n "$src" ] && [ -f "$src" ] || return 0
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -lt "$HELPER_PUT_VERIFY_MAX" ] || return 0    # large upload: size-only (no seed round-trip)
  _helper_verify_small_content "$path" "$src"; rc=$?
  case "$rc" in
    0) return 0 ;;
    4) _helper_log "verify: '${path}' is the right SIZE (${size} bytes) on the helper but the BYTES DIFFER from what we sent — either a same-length corruption, or this upload never overwrote an OLDER copy sitting at that path"; return 4 ;;
    *) # Could not fetch it back to compare. The size DID match, so the rc 0 contract ("there and
       _helper_log "verify: '${path}' matched on size (${size} bytes) but the readback to confirm its CONTENT could not be done — treating the size match as the verdict"; return 0 ;;
  esac
}

_helper_put_verify() {
  local path="$1" src="${2:-}" want="" got="" out rc
  if [ -n "$src" ] && [ -f "$src" ]; then
    want="$(wc -c < "$src" 2>/dev/null | tr -d '[:space:]')"
    case "$want" in ''|*[!0-9]*) want="" ;; esac   # unreadable local size ⇒ existence-only
  fi
  if [ "$_HELPER_EXEC" = 1 ]; then
    if [ -z "$want" ]; then
      _helper_ssh_raw "test -e $(_shq "$path")" >/dev/null 2>&1; rc=$?
      case "$rc" in 0) return 0 ;; 1) return 1 ;; *) return 3 ;; esac
    fi
    got="$(_helper_ssh_raw "if [ -f $(_shq "$path") ]; then wc -c < $(_shq "$path"); elif [ -e $(_shq "$path") ]; then echo NOTAFILE; else echo ABSENT; fi" 2>/dev/null)"; rc=$?
    [ "$rc" -ne 0 ] && return 3
    got="$(printf '%s' "$got" | tr -d '[:space:]')"
    case "$got" in
      ABSENT)   return 1 ;;
      NOTAFILE) _helper_log "verify: '${path}' exists on the helper but is NOT a regular file — the ${want}-byte upload did not land on it"; return 4 ;;
      ''|*[!0-9]*) return 3 ;;                     # an answer we cannot read a size out of
    esac
    if [ "$got" = "$want" ]; then _helper_put_verify_matched "$path" "$src" "$want"; return $?; fi
    _helper_log "verify: '${path}' is ${got} bytes on the helper, but the file we sent is ${want} bytes"
    return 4
  fi
  local replies
  _helper_sftp_session "$(printf 'ls -la %s\n' "$(_sftpq "$path")")"
  rc=$_SFTP_RC; out="$_SFTP_OUT"; replies="$_SFTP_ERR"
  [ "$rc" -ne 0 ] && return 3
  grep -qiE "$_HELPER_XPORT_RE" <<<"$replies" && return 3
  grep -qiE 'not found|no such file|can.?t ls' <<<"$replies" && return 1
  grep -qiE "$_HELPER_ERR_RE" <<<"$replies" && return 3
  [ -z "$want" ] && return 0                        # existence-only (a directory, or no source)
  got="$(printf '%s\n' "$out" | awk '
      $1 ~ /^[-dlbcps]/ && length($1) >= 10 && $5 ~ /^[0-9]+$/ { s = $5 }
      END { if (s != "") print s }')"
  if [ -z "$got" ]; then
    _helper_log "verify: could not read a size for '${path}' out of the helper's listing: $(_helper_sftp_said)"
    return 3
  fi
  if [ "$got" = "$want" ]; then _helper_put_verify_matched "$path" "$src" "$want"; return $?; fi
  _helper_log "verify: '${path}' is ${got} bytes on the helper, but the file we sent is ${want} bytes"
  return 4
}

helper_put() {
  helper_detect || return 2
  _helper_crypt_on && { _helper_crypt_put "$@"; return $?; }   # crypt mode (#1075)
  local src="$1" dst="$2" replies rc why n=1 back="${PROVISIONER_HELPER_PUT_BACKOFF:-2}"
  [ -f "$src" ] || { _helper_log "put: local source missing: $src"; return 2; }
  local tries="${PROVISIONER_HELPER_PUT_ATTEMPTS:-3}" budget="${PROVISIONER_HELPER_PUT_BUDGET:-}"
  if [ -z "$budget" ]; then
    if [ -n "${_HELPER_OP_TIMEOUT:-}" ]; then budget=$(( _HELPER_OP_TIMEOUT * 3 )); else budget=180; fi
  fi
  local t0=$SECONDS v
  while :; do
    _helper_sftp_session "$(printf 'put %s %s\n' "$(_sftpq "$src")" "$(_sftpq "$dst")")"
    rc=$_SFTP_RC; replies="$_SFTP_ERR"
    if grep -qiE "$_HELPER_AUTH_RE" <<<"$replies"; then
      _helper_log "put failed ($src → $dst): $(_helper_sftp_said)"; return 1
    elif grep -qiE "$_HELPER_XPORT_RE" <<<"$replies"; then
      why="the sftp SESSION did not complete (transport fault) — whether '${dst}' exists on the helper is NOT established: $(_helper_sftp_said)"
    elif grep -qiE "$_HELPER_ERR_RE" <<<"$replies"; then
      _helper_log "put failed ($src → $dst): $(_helper_sftp_said)"; return 1
    else
      case "$rc" in
        124|137) why="the upload was KILLED by the per-op cap (_HELPER_OP_TIMEOUT=${_HELPER_OP_TIMEOUT:-unset}s, rc ${rc}) before it finished — nothing about '${dst}' on the helper is established; raise that cap if this file is not small" ;;
        255)     why="the sftp session failed at the transport/auth layer (rc 255) — nothing about '${dst}' on the helper is established" ;;
        *)
          _helper_put_verify "$dst" "$src"; v=$?
          case "$v" in
            0) [ "$n" -gt 1 ] && _helper_log "put SUCCEEDED on attempt ${n} ($src → $dst)"
               return 0 ;;
            1) if [ "$rc" -eq 0 ]; then
                 why="the upload printed no error and exited 0, but '${dst}' is NOT there afterwards"
               else
                 why="the sftp session exited ${rc} and '${dst}' is not there afterwards"
               fi ;;
            4) why="'${dst}' IS on the helper but it is NOT the file we just sent (size mismatch, reported above) — either the transfer was truncated, or this upload never overwrote an OLDER copy sitting at that path" ;;
            *) why="the upload session exited ${rc}, and the VERIFICATION session did not complete either — whether '${dst}' landed is NOT established" ;;
          esac ;;
      esac
    fi
    if [ "$n" -ge "$tries" ]; then
      _helper_log "put FAILED after ${n} attempt(s) ($src → $dst): ${why}"; return 1
    fi
    if [ $(( SECONDS - t0 )) -ge "$budget" ]; then
      _helper_log "put FAILED after ${n} attempt(s) and $(( SECONDS - t0 ))s ($src → $dst) — retry budget ${budget}s exhausted: ${why}"; return 1
    fi
    _helper_log "put attempt ${n}/${tries} did not land ($src → $dst): ${why} — retrying in ${back}s"
    sleep "$back"; back=$(( back * 2 )); n=$(( n + 1 ))
  done
}

helper_get() {
  if ! helper_detect; then
    [ "${_HELPER_DETECT_REFUSED:-0}" = 1 ] && { _helper_log "get ($1): the helper REFUSED the login - not retried"; return 2; }
    return 1
  fi
  _helper_crypt_on && { _helper_crypt_get "$@"; return $?; }   # crypt mode (#1075)
  local src="$1" dst="$2" rc replies
  _helper_sftp_session "$(printf 'get %s %s\n' "$(_sftpq "$src")" "$(_sftpq "$dst")")"
  rc=$_SFTP_RC; replies="$_SFTP_ERR"
  if [ "$rc" -ne 0 ] && grep -qiE "$_HELPER_AUTH_RE" <<<"$replies"; then
    _helper_log "get failed ($src → $dst): the helper REFUSED the login - not retried: $(_helper_sftp_said)"; return 2
  fi
  if [ "$rc" -ne 0 ]; then
    _helper_log "get failed ($src → $dst): the sftp session exited ${rc} — $(_helper_sftp_said)"; return 1
  fi
  if grep -qiE "$_HELPER_ERR_RE" <<<"$replies"; then
    _helper_log "get failed ($src → $dst): $(_helper_sftp_said)"; return 1
  fi
  [ -f "$dst" ] || { _helper_log "get: $dst not present after download"; return 1; }
  return 0
}


HELPER_PRESENCE_WALK_MAX=4

_helper_presence_base() {
  printf '%s' "${HELPER_PRESENCE_BASE-${REMOTE_DIR-${PROVISIONER_REMOTE_DIR-}}}"
}

_helper_under() {
  if [ -z "$2" ]; then
    case "$1" in /*) return 1 ;; *) return 0 ;; esac   # no layout ⇒ the login dir is ours
  fi
  case "$1" in "$2"|"$2"/*) return 0 ;; *) return 1 ;; esac
}

_helper_presence_dirs() {
  local path="${1%/}" base parent n=0
  base="${2-$(_helper_presence_base)}"; base="${base%/}"
  while [ "$n" -lt "$HELPER_PRESENCE_WALK_MAX" ]; do
    case "$path" in
      ''|'/'|'.') break ;;
      */*) parent="${path%/*}"; [ -n "$parent" ] || parent="/" ;;
      *)   parent="." ;;
    esac
    [ "$parent" != "$path" ] || break
    _helper_under "$parent" "$base" || break
    printf '%s\n' "$parent"
    path="$parent"; n=$(( n + 1 ))
  done
}

_helper_said_about() {
  local text="$2" plain="${2//\\/}"      # a glob metacharacter comes back backslash-escaped
  case "$text" in
    *"\"${1}\""*|*"\"${1}/\""*|*"/${1}\""*|*"/${1}/\""*) return 0 ;;
  esac
  case "$plain" in
    *"\"${1}\""*|*"\"${1}/\""*|*"/${1}\""*|*"/${1}/\""*) return 0 ;;
  esac
  return 1
}

helper_presence() {
  helper_detect || return 2
  _helper_crypt_on && { _helper_crypt_presence "$@"; return $?; }   # crypt mode (#1075)
  local path="$1"
  if [ "$_HELPER_EXEC" = 1 ]; then _helper_presence_exec "$path"; return $?; fi
  _helper_presence_sftp "$path"
}

_helper_presence_exec() {
  local path="$1" q got
  q="$(_shq "$path")"
  got="$(_helper_ssh_raw "if [ -e $q ]; then echo PRESENT; else d=\$(dirname $q); while :; do if [ -d \"\$d\" ] && [ -r \"\$d\" ] && [ -x \"\$d\" ]; then echo ABSENT; break; fi; if [ -e \"\$d\" ]; then echo UNESTABLISHED; break; fi; n=\$(dirname \"\$d\"); if [ \"\$n\" = \"\$d\" ]; then echo UNESTABLISHED; break; fi; d=\$n; done; fi" 2>/dev/null)"
  [ $? -eq 0 ] || return 2
  case "$(printf '%s' "$got" | tr -d '[:space:]')" in
    PRESENT) return 0 ;;
    ABSENT)  return 1 ;;
    *)       return 2 ;;
  esac
}

_helper_presence_sftp() {
  local path="$1" dirs cmds d line rest want prefix here residue keep out err rc
  dirs="$(_helper_presence_dirs "$path")"
  cmds="ls -la $(_sftpq "$path")
"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    cmds="${cmds}ls -1a $(_sftpq "$d")
"
  done <<<"$dirs"
  _helper_sftp_session "$cmds"
  rc=$_SFTP_RC; out="$_SFTP_OUT"; err="$_SFTP_ERR"
  [ "$rc" -ne 0 ] && return 2
  residue=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    keep=1
    _helper_said_about "$path" "$line" && keep=0
    if [ "$keep" = 1 ]; then
      while IFS= read -r d; do
        [ -n "$d" ] || continue
        _helper_said_about "$d" "$line" && { keep=0; break; }
      done <<<"$dirs"
    fi
    [ "$keep" = 1 ] && residue="${residue}${line}
"
  done <<<"$err"
  residue="${residue//\\/}"
  grep -qiE "$_HELPER_AUTH_RE" <<<"$residue" && return 2
  grep -qiE "$_HELPER_XPORT_RE" <<<"$residue" && return 2
  grep -qiE "$_HELPER_ERR_RE" <<<"$residue" && return 2
  _helper_said_about "$path" "$err" || return 0
  local depth=-1 found
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    depth=$(( depth + 1 ))
    _helper_said_about "$d" "$err" && continue
    prefix="${d%/}/"
    here="$path"
    if [ "$d" = "." ]; then case "$here" in ./*) ;; *) here="./$here" ;; esac; fi
    case "$here" in
      "$prefix"*) want="${here#"$prefix"}"; want="${want%%/*}" ;;
      *) want="" ;;
    esac
    [ -n "$want" ] || return 2
    found=0
    while IFS= read -r line; do
      case "$line" in
        "$prefix"*)
          rest="${line#"$prefix"}"
          case "$rest" in
            ''|*/*) ;;
            "$want") found=1; break ;;
          esac ;;
      esac
    done <<<"$out"
    [ "$found" = 0 ] && return 1
    [ "$depth" = 0 ] && return 0
    return 2
  done <<<"$dirs"
  return 2
}

helper_exists() {
  helper_detect || return 2
  local v
  helper_presence "$1"; v=$?
  case "$v" in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

_helper_gone() {
  local v
  helper_exists "$1"; v=$?
  case "$v" in
    1) return 0 ;;
    0) _helper_log "$2: $1 still present"; return 1 ;;
    *) _helper_log "$2: could not confirm $1 is gone (presence not established)"; return 1 ;;
  esac
}

helper_mkdir_p() {
  helper_detect || return 2
  _helper_crypt_on && { _helper_crypt_mkdir_p "$@"; return $?; }   # crypt mode (#1075)
  local dir="$1"
  if [ "$_HELPER_EXEC" = 1 ]; then
    _helper_ssh_raw "mkdir -p $(_shq "$dir")" >/dev/null 2>&1; return $?
  fi
  local cmds="" acc="" part oldIFS="$IFS"
  case "$dir" in /*) acc="" ;; esac       # leading slash handled by the empty first field
  IFS='/'
  for part in $dir; do
    [ -n "$part" ] || continue
    if [ -z "$acc" ]; then
      case "$dir" in /*) acc="/$part" ;; *) acc="$part" ;; esac
    else
      acc="$acc/$part"
    fi
    cmds="${cmds}mkdir $(_sftpq "$acc")
"
  done
  IFS="$oldIFS"
  printf '%s' "$cmds" | _helper_sftp_run >/dev/null 2>&1
  helper_exists "$dir"; local _mk=$?
  if [ "$_mk" = 2 ]; then sleep "${PROVISIONER_HELPER_MKDIR_RETRY_PAUSE:-1}"; helper_exists "$dir"; _mk=$?; fi
  return "$_mk"
}

helper_mkdir_exclusive() {
  helper_detect || return 2
  _helper_crypt_on && { _helper_crypt_mkdir_exclusive "$@"; return $?; }   # crypt mode (#1075)
  _helper_mkdir_exclusive_raw "$1"
}
_helper_mkdir_exclusive_raw() {
  local dir="$1" out rc v
  if [ "$_HELPER_EXEC" = 1 ]; then
    _helper_ssh_raw "mkdir $(_shq "$dir")" >/dev/null 2>&1; rc=$?
    case "$rc" in
      0)   return 0 ;;
      255) return 2 ;;                       # ssh transport/channel failure, not a remote rc
      *)   # The remote mkdir refused. EEXIST is the expected reason, but a missing parent or a
           _helper_put_verify "$dir"; v=$?
           case "$v" in 0) return 1 ;; *) return 2 ;; esac ;;
    esac
  fi
  _helper_sftp_session "$(printf 'mkdir %s\n' "$(_sftpq "$dir")")"
  rc=$_SFTP_RC; out="$_SFTP_ERR"
  if grep -qiE "$_HELPER_AUTH_RE" <<<"$out"; then return 2; fi
  if grep -qiE "$_HELPER_XPORT_RE" <<<"$out"; then return 2; fi
  case "$rc" in 124|137|255) return 2 ;; esac  # killed by _HELPER_OP_TIMEOUT / session failure
  if grep -qiE "$_HELPER_ERR_RE" <<<"$out"; then
    _helper_put_verify "$dir"; v=$?
    case "$v" in 0) return 1 ;; *) return 2 ;; esac
  fi
  _helper_put_verify "$dir"; v=$?
  case "$v" in 0) return 0 ;; *) return 2 ;; esac
}

helper_copy() {
  helper_detect || return 2
  _helper_crypt_on && { _helper_crypt_copy "$@"; return $?; }   # crypt mode (#1075)
  local a="$1" b="$2"
  [ "$_HELPER_EXEC" = 1 ] || return 3
  _HELPER_OP_TIMEOUT="${PROVISIONER_HELPER_COPY_TIMEOUT:-1800}" \
    _helper_ssh_raw "cp -- $(_shq "$a") $(_shq "${b}.part") && mv -f $(_shq "${b}.part") $(_shq "$b") || { rm -f $(_shq "${b}.part"); false; }" >/dev/null 2>&1
}

helper_copy_recrypt() {
  helper_detect || return 2
  local a b
  [ $# -ge 4 ] || return 2
  if _helper_crypt_on; then a="$(_helper_crypt_p "$1")" || return 2
  else a="$(HELPER_PRESENCE_BASE="" _helper_crypt_p "$1")" || return 2; a="prov-sftp:${a#prov-crypt:}"; fi
  b="$(HELPER_PRESENCE_BASE="$4" _helper_crypt_p "$2")" || return 2
  _CRY_X_KEY="$3"; _CRY_X_BASE="$4"
  _HELPER_OP_TIMEOUT="${PROVISIONER_HELPER_COPY_TIMEOUT:-1800}" \
    _helper_crypt_session copyto --disable copy -- "$a" "prov-crypt-child:${b#prov-crypt:}"
  _CRY_X_KEY=""; _CRY_X_BASE=""
  [ "$_CRY_RC" -eq 0 ]
}
_helper_crypt_x_base() {
  local d t
  for d in "${XDG_RUNTIME_DIR:-}" /dev/shm; do
    [ -n "$d" ] && [ -d "$d" ] && [ -w "$d" ] || continue
    t="$(stat -f -c %T "$d" 2>/dev/null)"
    case "$t" in tmpfs|ramfs) printf '%s' "$d"; return 0 ;; esac
  done
  return 1
}
_helper_crypt_x_ready() {
  local ck="$_CRY_X_KEY"
  [ -s "$ck" ] || { _helper_log "crypt mode: the child's key file '${ck}' is missing or empty - refusing"; return 2; }
  [ -z "$(find "$ck" -maxdepth 0 -perm /077 2>/dev/null)" ] || { _helper_log "crypt mode: the child's key file '${ck}' is group/other accessible - refusing; chmod 600"; return 2; }
  if _helper_crypt_on; then _helper_crypt_ready || return 2
  else
    command -v rclone >/dev/null 2>&1 || { _helper_log "crypt mode: rclone is not installed"; return 2; }
    _helper_crypt_hostkey || return 2
  fi
}
_helper_crypt_x_conf_new() {
  local base kf pw salt cpw csalt
  base="$(_helper_crypt_x_base)" || { _helper_log "crypt mode: no tmpfs (XDG_RUNTIME_DIR or /dev/shm) for a config holding two keys - refusing"; return 1; }
  _helper_crypt_conf_dir "$base" || return 1
  cpw="$(_helper_crypt_obscure "$_CRY_X_KEY" 1)"; csalt="$(_helper_crypt_obscure "$_CRY_X_KEY" 2)"
  if [ -z "$cpw" ] || { [ -n "$(sed -n 2p "$_CRY_X_KEY" | tr -d '\r')" ] && [ -z "$csalt" ]; }; then
    rm -rf "$_CRY_DIR"; _CRY_DIR=""; return 1
  fi
  if _helper_crypt_on && ! _helper_crypt_alias; then
    kf="$(_helper_crypt_keyfile)"
    pw="$(_helper_crypt_obscure "$kf" 1)"; salt="$(_helper_crypt_obscure "$kf" 2)"
    if [ -z "$pw" ] || { [ -n "$(sed -n 2p "$kf" | tr -d '\r')" ] && [ -z "$salt" ]; }; then
      rm -rf "$_CRY_DIR"; _CRY_DIR=""; return 1
    fi
  fi
  ( umask 077
    { _helper_crypt_sftp_stanza || exit 1
      if _helper_crypt_alias; then _helper_crypt_alias_stanza   # #1202
      else [ -z "${pw:-}" ] || _helper_crypt_remote_stanza "$pw" "$salt"; fi
      HELPER_PRESENCE_BASE="$_CRY_X_BASE" _helper_crypt_remote_stanza "$cpw" "$csalt" | sed 's/^\[prov-crypt\]$/[prov-crypt-child]/'
    } > "${_CRY_DIR}/rclone.conf" ) 2>/dev/null || { rm -rf "$_CRY_DIR"; _CRY_DIR=""; return 1; }
  chmod 600 "${_CRY_DIR}/rclone.conf"
}

helper_rename() {
  helper_detect || return 2
  _helper_crypt_on && { _helper_crypt_rename "$@"; return $?; }   # crypt mode (#1075)
  local a="$1" b="$2" replies rc refused established
  if [ "$_HELPER_EXEC" = 1 ]; then
    _helper_ssh_raw "mv -f $(_shq "$a") $(_shq "$b")" >/dev/null 2>&1; return $?
  fi
  _helper_sftp_session "$(printf 'rename %s %s\n' "$(_sftpq "$a")" "$(_sftpq "$b")")"
  rc=$_SFTP_RC; replies="$_SFTP_ERR"
  refused=0; grep -qiE "$_HELPER_ERR_RE" <<<"$replies" && refused=1
  [ "$rc" -eq 0 ] && [ "$refused" -eq 0 ] && return 0          # it went

  established=1
  grep -qiE "$_HELPER_AUTH_RE" <<<"$replies" && established=0
  grep -qiE "$_HELPER_XPORT_RE" <<<"$replies" && established=0
  case "$rc" in 124|137|255) established=0 ;; esac
  [ "$refused" -eq 1 ] || established=0        # no refusal to act on ⇒ nothing to clear
  if [ "$established" -eq 0 ]; then
    _helper_log "rename ($a → $b) did not complete and NOTHING was removed — whether '${b}' exists on the helper is NOT established: $(_helper_sftp_said)"
    return 1
  fi

  helper_remove "$b" >/dev/null 2>&1
  _helper_sftp_session "$(printf 'rename %s %s\n' "$(_sftpq "$a")" "$(_sftpq "$b")")"
  rc=$_SFTP_RC; replies="$_SFTP_ERR"
  if [ "$rc" -ne 0 ] || grep -qiE "$_HELPER_ERR_RE" <<<"$replies"; then
    _helper_log "rename failed ($a → $b): $(_helper_sftp_said)"; return 1
  fi
  return 0
}

helper_remove() {
  helper_detect || return 2
  _helper_crypt_on && { _helper_crypt_remove "$@"; return $?; }   # crypt mode (#1075)
  local path="$1"
  if [ "$_HELPER_EXEC" = 1 ]; then
    _helper_ssh_raw "rm -f $(_shq "$path")" >/dev/null 2>&1; return $?
  fi
  printf 'rm %s\n' "$(_sftpq "$path")" | _helper_sftp_run >/dev/null 2>&1
  _helper_gone "$path" "remove"
}

helper_rmdir() {
  helper_detect || return 2
  _helper_crypt_on && { _helper_crypt_rmdir "$@"; return $?; }   # crypt mode (#1075)
  local path="$1"
  if [ "$_HELPER_EXEC" = 1 ]; then
    _helper_ssh_raw "rmdir -- $(_shq "$path")" >/dev/null 2>&1
  else
    printf 'rmdir %s\n' "$(_sftpq "$path")" | _helper_sftp_run >/dev/null 2>&1
  fi
  _helper_gone "$path" "rmdir"
}

helper_clear_tree() {
  helper_detect || return 2
  _helper_crypt_on && { _helper_crypt_clear_tree "$@"; return $?; }   # crypt mode (#1075)
  local nfiles="${1:-}"
  shift 2>/dev/null || return 2
  case "$nfiles" in ''|*[!0-9]*) return 2 ;; esac
  [ "$#" -ge "$nfiles" ] || return 2
  local p out rc=0 i=0 nf=0 nd=0 cmds="" rmargs="" rmdirargs=""
  local _nl='
'
  local _cr; _cr="$(printf '\r')"
  for p in "$@"; do
    i=$((i+1))
    case "$p" in
      ""|-*|/*)                                       continue ;;
      .|..|./*|../*|*/.|*/..|*/./*|*/../*|*//*)       continue ;;
      *"$_nl"*|*"$_cr"*)                              continue ;;
    esac
    if [ "$i" -le "$nfiles" ]; then
      nf=$((nf+1))
      if [ "$_HELPER_EXEC" = 1 ]; then rmargs="${rmargs} $(_shq "$p")"
      else cmds="${cmds}rm $(_sftpq "$p")
"
      fi
    else
      nd=$((nd+1))
      if [ "$_HELPER_EXEC" = 1 ]; then rmdirargs="${rmdirargs} $(_shq "$p")"
      else cmds="${cmds}rmdir $(_sftpq "$p")
"
      fi
    fi
  done
  [ $((nf + nd)) -gt 0 ] || return 0
  if [ "$_HELPER_EXEC" = 1 ]; then
    [ "$nf" -gt 0 ] && cmds="rm -f --${rmargs}
"
    [ "$nd" -gt 0 ] && cmds="${cmds}rmdir --${rmdirargs}"
    _helper_ssh_raw "$cmds" >/dev/null 2>&1; rc=$?
    case "$rc" in 0) return 0 ;; 255) return 2 ;; *) return 1 ;; esac
  fi
  _helper_sftp_session "$cmds"
  rc=$_SFTP_RC; out="$_SFTP_ERR"
  if grep -qiE "$_HELPER_AUTH_RE" <<<"$out"; then return 2; fi
  if grep -qiE "$_HELPER_XPORT_RE" <<<"$out"; then return 2; fi
  case "$rc" in 124|137|255) return 2 ;; esac   # killed by _HELPER_OP_TIMEOUT / session failure
  if grep -qiE "$_HELPER_ERR_RE" <<<"$out"; then return 1; fi
  return 0
}

helper_ls_l() {
  helper_detect || return 2
  _helper_crypt_on && { _helper_crypt_ls_l "$@"; return $?; }   # crypt mode (#1075)
  local path="${1:-.}"
  if [ "$_HELPER_EXEC" = 1 ]; then
    _helper_ssh_raw "ls -la -- $(_shq "$path")"; return $?
  fi
  printf 'ls -la %s\n' "$(_sftpq "$path")" | _helper_sftp_run \
    | grep -vE '^sftp>|^Connected to|^Remote working directory|^Changing|^Fetching|^Uploading'
}

helper_ls() {
  helper_detect || return 2
  _helper_crypt_on && { _helper_crypt_ls "$@"; return $?; }   # crypt mode (#1075)
  local path="${1:-.}"
  if [ "$_HELPER_EXEC" = 1 ]; then
    _helper_ssh_raw "ls -1 $(_shq "$path")"; return $?
  fi
  printf 'ls -1 %s\n' "$(_sftpq "$path")" | _helper_sftp_run \
    | grep -vE '^sftp>|^Connected to|^Remote working directory|^Changing|^Fetching|^Uploading'
}

helper_run_python() {
  local _HELPER_OP_TIMEOUT="${PROVISIONER_HELPER_RUN_TIMEOUT:-120}"
  helper_detect || return 2
  _helper_crypt_alias && { _helper_log "run_python: the access path reaches the seedbox for file transfer only and never opens a shell on it, so a program cannot run there"; return 3; }
  _helper_crypt_on && { _helper_log "run_python: not available in crypt mode"; return 3; }
  [ "$_HELPER_EXEC" = 1 ] || return 3
  local prog="$1"; shift
  [ -r "$prog" ] || return 4
  local argb64 b64
  argb64="$(printf '%s\0' "$(basename -- "$prog")" "$@" | base64 -w0)" || return 5
  b64="$( { printf 'import sys\nsys.argv=__import__("base64").b64decode("%s").decode("utf-8").split("\\0")[:-1]\n' \
                   "$argb64"
           cat -- "$prog"; } | base64 -w0 )" || return 5
  _helper_ssh_raw "printf %s $(_shq "$b64") | base64 -d | python3 -; echo \"rc=\$?\""
}
