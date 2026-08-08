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
# SHAPE — ASK EVERYTHING, THEN DO EVERYTHING (issue #104). The operator complaint was
# sequencing: questions used to be interleaved with work (the `apt-get install sshpass`
# sat between the port prompt and the password prompt, and the needle asked for the admin
# identity minutes later, after probing the box), so you could never walk away. This file
# now has one INTERVIEW block up front and a DO block after it, and NOTHING below the
# interview prompts. Same rule holds in needle.sh.
#
# NO apt, NO sshpass (issue #104). The password-only helper used to force
# `apt-get install sshpass` as the very first act of the bootstrap — a working apt +
# outbound internet on a bare Proxmox box whose repos may not be configured. It timed out
# live on iapetus 2026-08-07 and blocked the run at step one. OpenSSH supplies the password
# itself via SSH_ASKPASS + SSH_ASKPASS_REQUIRE=force (>= 8.4), with no tty and no DISPLAY —
# see the long note in helper-lib.sh. sshpass is now only an optional fallback if present.
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
# Durable helper-AUTH fact, written by helper-lib on the FIRST successful detection (issue
# #87; needle points the lib's cache here). hook.sh is pre-lib, but reading the fact lets us
# SKIP the doomed pubkey attempt against a known password-only helper — every such attempt is
# a real failed login and the seedbox provider bans the estate's egress IP after enough of
# them (issue #87/#90). Absent (first ever run) ⇒ unknown ⇒ behave as before.
HELPER_AUTH_CACHE="/root/helper-auth"

log() { printf '\n[hook] %s\n' "$*" >&2; }
die() { printf '\n[hook] ERROR: %s\n' "$*" >&2; exit 1; }

# Detect a controlling terminal ONCE, before anything asks (issue: iapetus wedge / #58).
# The documented entrypoint is a console `curl|bash`, but the chain is also re-invoked with
# NO tty, where `read </dev/tty` fails instantly (ENXIO — which `[ -r /dev/tty ]`, a mode
# check, would NOT catch) and any prompt loop BUSY-SPINS forever. With no tty every question
# below must therefore be answerable from the environment, or we die loudly naming the var.
have_tty=0; { : </dev/tty; } 2>/dev/null && have_tty=1

# ══════════════════════════════════════════════════════════════════════════════
# INTERVIEW — every question hook.sh will ever ask (issue #104). Nothing below
# the "END OF INTERVIEW" marker prompts.
# ══════════════════════════════════════════════════════════════════════════════

# ── Q1/Q2: helper (user@host) + port, cached across runs ──────────────────────
# The loop re-asks on a bad or unreachable answer instead of forcing a one-liner restart.
# The two operations inside it (the /dev/tcp probe and ssh-keyscan) are read-only
# VALIDATION of the answer just given, not provisioning work — they stay in the interview
# on purpose so a typo is caught while the operator is still typing, and so that the
# password question is never asked against an address that cannot possibly answer.
#
# LOOP-PROGRESS RULE (this file has now produced three busy-spins — #58, the iapetus wedge,
# and one I introduced in the first cut of #104): EVERY iteration must CONSUME or CLEAR the
# source it read from, so the next iteration reads something different. A prompt consumes
# itself (the operator types again); env and cache do NOT — re-reading a malformed
# PROVISIONER_HELPER_PORT or a corrupt /root/helper-port yields the same bad value forever,
# with no prompt and no sleep. So each non-interactive source is SINGLE-USE (the *_used
# flags below), a rejected env value DIES naming the variable, and the whole loop is capped.
# The cap is the backstop that holds even if a `rm -f` fails on a read-only /root.
helper=""; helper_server=""; port=""; helper_src=""; port_src=""
helper_env_used=0; helper_cache_used=0; port_env_used=0; port_cache_used=0
helper_ok=0      # an already-validated address is not re-asked just because the port was bad
interview_round=0
INTERVIEW_MAX_ROUNDS="${PROVISIONER_HOOK_INTERVIEW_MAX_ROUNDS:-12}"
# A garbage cap must not become a cap of zero (which would abort a perfectly good first
# round) — an unusable value falls back to the default rather than changing behaviour.
[[ $INTERVIEW_MAX_ROUNDS =~ ^[0-9]+$ ]] && (( INTERVIEW_MAX_ROUNDS >= 1 )) || INTERVIEW_MAX_ROUNDS=12
while :; do
  interview_round=$((interview_round + 1))
  if (( interview_round > INTERVIEW_MAX_ROUNDS )); then
    die "gave up after ${INTERVIEW_MAX_ROUNDS} attempts to get a usable helper address/port.
This is a guard against an unanswerable loop — the last values tried were helper='${helper}' port='${port}'.
Re-run the hook, or set PROVISIONER_HELPER=user@host and PROVISIONER_HELPER_PORT=<port>."
  fi

  # ── the helper address ──────────────────────────────────────────────────────
  if [[ $helper_ok == 1 ]]; then
    :   # already validated this round-set; only the port still needs an answer
  elif [[ -n ${PROVISIONER_HELPER:-} && $helper_env_used == 0 ]]; then
    helper="${PROVISIONER_HELPER}"; helper_src="env"; helper_env_used=1
    log "using PROVISIONER_HELPER from the environment"
  elif [[ -f $HELPER_CACHE && $helper_cache_used == 0 ]]; then
    helper=$(cat "$HELPER_CACHE"); helper_src="cache"; helper_cache_used=1
    log "using cached helper ($helper)"
  elif [[ $have_tty == 1 ]]; then
    # /dev/tty explicitly: the documented entrypoint is `curl … | bash`, so stdin is the
    # pipe, not the console — a plain `read` gets EOF and spins the loop. A FAILED read
    # (the tty went away mid-run) is fatal, never a silent empty answer to loop on.
    helper=""
    read -r -p "helper (user@host): " helper </dev/tty \
      || die "lost the controlling terminal while asking for the helper address — set PROVISIONER_HELPER=user@host and re-run."
    helper_src="prompt"
  else
    die "no helper address, and no controlling terminal to ask on.
Set it in the environment before invoking the hook:
  • PROVISIONER_HELPER=user@host        (required)
  • PROVISIONER_HELPER_PORT=<port>      (optional, default 22)
Nothing has been changed on this host."
  fi
  if [[ -z $helper || $helper != *@* ]]; then
    case "$helper_src" in
      env)   die "PROVISIONER_HELPER='${helper}' is not user@host — fix it and re-run. Nothing has been changed.";;
      cache) log "cached helper '${helper}' is not user@host — discarding it and asking"; rm -f "$HELPER_CACHE";;
      *)     log "expected user@host, try again";;
    esac
    continue     # the bad source is now marked used (and the cache file removed) — progress
  fi
  helper_server="${helper#*@}"; helper_ok=1

  # ── the port ────────────────────────────────────────────────────────────────
  # env wins, else cache, else prompt (default 22 — the OpenSSH case; a seedbox helper is a
  # high port like 14236). Threaded to needle so the whole chain agrees. Same single-use
  # rule as the address: a malformed env/cache value is consumed, never re-read.
  port=""; port_src=""
  if [[ -n ${PROVISIONER_HELPER_PORT:-} && $port_env_used == 0 ]]; then
    port="${PROVISIONER_HELPER_PORT}"; port_src="env"; port_env_used=1
  elif [[ -f $PORT_CACHE && $port_cache_used == 0 ]]; then
    port="$(cat "$PORT_CACHE")"; port_src="cache"; port_cache_used=1
  elif [[ $have_tty == 1 ]]; then
    read -r -p "helper SSH/SFTP port [22]: " port </dev/tty \
      || die "lost the controlling terminal while asking for the helper port — set PROVISIONER_HELPER_PORT and re-run."
    port="${port:-22}"; port_src="prompt"
  else
    port=22; port_src="default"   # safe default; PROVISIONER_HELPER_PORT overrides it
  fi
  if [[ ! $port =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    case "$port_src" in
      env)   die "PROVISIONER_HELPER_PORT='${port}' is not a valid port number (1-65535) — fix it and re-run. Nothing has been changed.";;
      cache) log "cached helper port '${port}' (${PORT_CACHE}) is not a valid port number — discarding it and asking"; rm -f "$PORT_CACHE";;
      *)     log "port must be a number between 1 and 65535, try again";;
    esac
    continue     # the bad source is marked used — the next round reaches the prompt
  fi

  # Reachability pre-check on the ACTUAL port → fast, clear failure. bash's built-in
  # /dev/tcp needs no external tool (`nc` is not on a fresh PVE host).
  if ! timeout 5 bash -c "exec 3<>/dev/tcp/${helper_server}/${port}" 2>/dev/null; then
    # An env-supplied value is an explicit operator decision — re-asking would silently
    # override it, so say which one is wrong and stop. Anything else can be re-asked, and
    # the cached values are dropped so the next round genuinely asks.
    [[ $helper_src == env ]] && die "helper '${helper}' is unreachable on :${port} (TCP connect failed) and it came from PROVISIONER_HELPER — check the address/port/DNS and re-run. Nothing has been changed."
    [[ $port_src == env ]] && die "helper is unreachable on :${port} (TCP connect failed) and that port came from PROVISIONER_HELPER_PORT — check the address/port/DNS and re-run. Nothing has been changed."
    if [[ $have_tty == 1 ]]; then
      log "helper unreachable on :${port} — re-enter"
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

# ── Q3: the helper password ───────────────────────────────────────────────────
# Asked HERE, up front, instead of lazily inside the fetch (issue #104) — that is what
# used to make the last question arrive after minutes of work. We do not yet know whether
# the helper takes keys, so we use the durable auth fact when we have one and otherwise
# offer an explicit "leave empty" for the key case.
mkdir -p /etc/provisioner
auth_hint="${PROVISIONER_HELPER_AUTH:-}"
[[ -z $auth_hint && -f $HELPER_AUTH_CACHE ]] && auth_hint="$(tr -d '[:space:]' < "$HELPER_AUTH_CACHE" 2>/dev/null)"
case "$auth_hint" in key|password) ;; *) auth_hint="" ;; esac
[[ -n $auth_hint ]] && log "helper auth known from a previous run: ${auth_hint}"

# hook_collected_pass records whether the credential is OURS to discard on a failure:
# an operator-pre-staged /etc/provisioner/helper-pass is NEVER ours to delete.
hook_collected_pass=0
if [[ -s $HELPER_PASS_FILE ]]; then
  log "using the helper password already staged at ${HELPER_PASS_FILE}"
elif [[ $auth_hint == key ]]; then
  log "helper auth is 'key' — no password needed"
elif [[ $have_tty == 1 ]]; then
  if [[ $auth_hint == password ]]; then
    pw_prompt="helper password: "
  else
    pw_prompt="helper password (leave EMPTY if the helper takes this host's SSH key): "
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

# ══════════════════════════════════════════════════════════════════════════════
# END OF INTERVIEW — nothing below this line prompts.
# ══════════════════════════════════════════════════════════════════════════════

# ── One irreducible inline fetch: pull helper-lib.sh, then hand the rest to it ─
# The bootstrap trust root. Try KEY auth first (scp — the OpenSSH-helper case, unchanged
# from the historical hook, and SKIPPED when the durable auth fact says the helper is
# password-only so we never burn a failed login on it); otherwise fetch over SFTP with the
# password collected above, supplied to OpenSSH via SSH_ASKPASS — no sshpass, no apt.
# This is the ONLY hand-rolled transport in the chain — everything after sources the lib.
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

# The hook is PRE-LIB, so it carries the smallest possible copy of helper-lib's password
# transport (issue #104): SSH_ASKPASS + SSH_ASKPASS_REQUIRE=force, which OpenSSH >= 8.4 uses
# for password input regardless of tty or DISPLAY. The generated askpass program holds NO
# credential — it prints the first line of $PROVISIONER_ASKPASS_FILE (same semantics as
# `sshpass -f`) — is born 0600 under umask 077, and is removed the moment sftp returns.
# BatchMode stays OFF here: `-b`/BatchMode disables the password prompt outright, so nothing
# could answer it (the password-sftp invariant documented in helper-lib.sh).
hook_askpass_ok() {
  local maj min
  maj="$(ssh -V 2>&1 | sed -n 's/^OpenSSH_\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1/p')"
  min="$(ssh -V 2>&1 | sed -n 's/^OpenSSH_\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\2/p')"
  [[ -n $maj && -n $min ]] || return 1
  (( maj > 8 || (maj == 8 && min >= 4) ))
}

# WHERE the askpass program may live. ssh EXECs it, so a `noexec` mount breaks it — and ssh
# reports that as "ssh_askpass: exec(…): Permission denied", which reads exactly like a
# rejected password. So PROBE: write a throwaway script into each candidate and actually run
# it; the first that returns our sentinel wins. Mirrors helper-lib's _helper_askpass_dir.
# /etc/provisioner first — the boot chain's own dir, on the root fs, already created above.
hook_askpass_dir=""
hook_find_askpass_dir() {
  [[ -n $hook_askpass_dir ]] && { printf '%s' "$hook_askpass_dir"; return 0; }
  local d probe
  # Unquoted on purpose: PROVISIONER_ASKPASS_DIR, when set, REPLACES the built-in list and
  # may name several space-separated candidates (an explicit operator choice is authoritative).
  # shellcheck disable=SC2086
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

# Run `sftp` against the helper with the collected password. Commands arrive on STDIN
# (never -b). Prints combined stdout+stderr; returns sftp's rc (255 when no transport).
hook_sftp_pass() {
  local ap rc
  # NB: hook_find_askpass_dir is called WITHOUT a command substitution — it memoises into the
  # global $hook_askpass_dir, and a $( ) subshell could not write that back, leaving the
  # failure message unable to name the directory it actually tried.
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
  # Optional fallback for a host that already has sshpass (never installed by us any more).
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

# Classify an ssh/sftp failure so we never RETRY a rejected credential (issue #104).
# WHY: every attempt is a real login against the helper, and the seedbox provider bans the
# estate's egress IP after repeated failures — a fumbled password could lock the estate out
# of the one component the whole chain depends on (issues #87/#90). ssh's exit code alone
# cannot tell us (almost everything is 255), so we read the stderr text, which OpenSSH's
# wording for these cases has been stable on for many releases.
#
# ORDER MATTERS — the first two classes both contain the substring "permission denied" and
# MUST be tested before the auth class:
#   envfault : `ssh_askpass: exec(/tmp/…): Permission denied` — a LOCAL fault (noexec mount,
#              lost askpass file), not a rejected credential. Misfiling this as `auth` made
#              the hook delete a perfectly good password and told the operator to retype it,
#              unrecoverably (found in review of the first #104 cut).
#   hostkey  : `Host key verification failed` — this estate's helper/host keys churn (#28)
#              and hook.sh only ever APPENDS keyscan output to known_hosts, never prunes,
#              so a stale entry is a live possibility. Name the remedy.
#   auth     : a REJECTED CREDENTIAL. Tested BEFORE `banned` — see the next entry for why.
#   banned   : `Connection closed by …` / `kex_exchange_identification` — the server hung up
#              before auth. That is precisely what proftpd mod_ban / MaxLoginAttempts looks
#              like, so despite being a plausible transient it does NOT get the full transport
#              retry budget (see the fetch loop: one retry, then stop).
#              MUST be tested AFTER `auth`, not before: a REJECTED PASSWORD also ends in a
#              server-side disconnect, so the transcript is `Permission denied (password).`
#              FOLLOWED BY `Connection closed by <ip> port <p>`. Matching `connection closed
#              by` first classified that as a ban — which RETRIED (a second real failed login
#              against a MaxLoginAttempts-hardened seedbox), KEPT the known-bad credential so
#              the next run repeated it, and told the operator to wait out a block that had
#              not happened. Exactly the ban risk this function exists to prevent, arrived at
#              from the opposite direction. A genuine mod_ban drop is PRE-auth and therefore
#              carries no auth text, so it still lands here correctly.
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

fetch_fail_reason=""    # human-readable "why" for the last fetch_lib failure
banner_closes=0         # how many times the helper hung up on us (see the 'banned' class)
fetch_lib() {
  # rc 0 = fetched
  #    1 = RETRYABLE (transport)
  #    2 = FATAL, and the credential is SUSPECT — discard one we collected so a re-run asks
  #    3 = FATAL, and the credential is FINE — keep it (local fault, stale host key, or a
  #        successful login that simply could not read the file). Deleting it here would
  #        make the operator retype a correct password and watch it fail identically.
  fetch_fail_reason=""
  local out rc key_fail=""
  # (a) KEY path: scp uses the default identity + the sftp subsystem (works on both helper
  #     kinds when a key is authorized). Success ⇒ key helper, no password needed. SKIPPED
  #     when the durable auth fact says the helper is password-only — that attempt would be
  #     a guaranteed failed login accruing toward the provider's ban (issue #87/#90).
  #     WRAPPED IN `timeout` (mirrors helper-lib's HELPER_PROBE_TIMEOUT): a seedbox mod_sftp
  #     helper ACCEPTS an RSA /root/.ssh/id_rsa then HANGS verifying the signature, and
  #     ConnectTimeout does NOT bound that post-auth hang — without this the WHOLE cold-start
  #     wedges here (confirmed rc=124) instead of falling through to the password path (b).
  if [[ $auth_hint != password ]]; then
    out="$(timeout "${PROVISIONER_HELPER_PROBE_TIMEOUT:-25}" \
      scp -P "$port" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o BatchMode=yes "${cm_opts[@]}" \
        "${helper}:${LIB_REMOTE}" ./helper-lib.sh 2>&1)"; rc=$?
    [[ $rc -eq 0 && -s ./helper-lib.sh ]] && return 0
    rm -f ./helper-lib.sh
    # A key rejection here is EXPECTED on a password-only helper — never fatal on its own;
    # it just means we fall through to (b). Remember it only for the error message.
    key_fail="$(classify_ssh_failure "$out" "$rc")"
  fi

  # (b) PASSWORD path — the password was collected during the interview, never here.
  if [[ ! -s $HELPER_PASS_FILE ]]; then
    fetch_fail_reason="key auth did not work (${key_fail:-no key attempt}) and no helper password is available at ${HELPER_PASS_FILE}"
    return 2
  fi
  out="$(printf 'get %s ./helper-lib.sh\n' "$LIB_REMOTE" | hook_sftp_pass)"; rc=$?
  [[ $rc -eq 0 && -s ./helper-lib.sh ]] && return 0
  rm -f ./helper-lib.sh
  # rc 0 with no file means the SESSION worked and the `get` failed (sftp without -b always
  # exits 0 — the invariant in helper-lib.sh), so it can never be an auth problem.
  local class; class="$(classify_ssh_failure "$out" "$rc")"
  [[ $rc -eq 0 && $class == auth ]] && class=missing
  case "$class" in
    envfault)
      # LOCAL fault (noexec mount under the askpass program, or it vanished). Nothing to do
      # with the credential — say which directory and how to check it. KEEP the password.
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
      # The server hung up at/near the banner. Could be transient, but it is also exactly how
      # proftpd mod_ban / MaxLoginAttempts drops a client — so ONE retry, then stop, rather
      # than the full transport budget. Never a reason to discard the credential.
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
      # Auth SUCCEEDED — the file simply is not there. The credential is proven good, so it
      # must survive (deleting it here was a bug of the same family as the envfault one).
      fetch_fail_reason="authenticated fine, but ${LIB_REMOTE} could not be read from the helper — re-run genesis.sh's deploy to stage the boot scripts. Your helper password has been KEPT." ; return 3;;
    transport)
      fetch_fail_reason="transport error reaching the helper: $(printf '%s' "$out" | tr '\n' ';')" ; return 1;;
    *)
      # Could not tell auth from transport. The SAFE default is to stop: a retry of a
      # rejected credential is what triggers the ban, and a stopped bootstrap costs one
      # re-run of the one-liner. PROVISIONER_HOOK_RETRY_UNKNOWN=1 opts back into retrying.
      fetch_fail_reason="unrecognised failure (could not tell auth from transport): $(printf '%s' "$out" | tr '\n' ';')"
      [[ ${PROVISIONER_HOOK_RETRY_UNKNOWN:-0} == 1 ]] && return 1
      return 2;;
  esac
}

# Resolve the askpass location ONCE, HERE, in the main shell. hook_sftp_pass runs inside a
# command substitution (`out="$(… | hook_sftp_pass)"`) and a $( ) subshell cannot write the
# memo back — without this the failure message could not name the directory it actually
# tried, which is the single most useful fact when a `noexec` mount is the cause.
hook_find_askpass_dir >/dev/null || true

# Fetch, with retries ONLY for transport errors (issue #104). No prompting happens here —
# the interview is over. An auth failure stops immediately: retrying it is what risks the
# seedbox ban that would lock the estate out of its own helper.
attempts=0
max_attempts="${PROVISIONER_HOOK_FETCH_MAX_ATTEMPTS:-5}"
# Same guard as INTERVIEW_MAX_ROUNDS above, and for a sharper reason: a value that makes the
# `(( attempts >= max_attempts ))` test a syntax error (e.g. '1 2', '2x', '1+') never trips the
# cap, so the loop retries FOREVER — and every iteration here is a real login against the
# helper, i.e. the exact ban this whole classifier exists to avoid. An unusable value falls
# back to the default rather than changing behaviour.
[[ $max_attempts =~ ^[0-9]+$ ]] && (( max_attempts >= 1 )) || max_attempts=5
while :; do
  fetch_lib; fetch_rc=$?
  [[ $fetch_rc -eq 0 ]] && break
  if [[ $fetch_rc -eq 3 ]]; then
    # Fatal, but the credential is NOT implicated — leave it exactly where it is.
    die "could not fetch helper-lib.sh — ${fetch_fail_reason}"
  fi
  if [[ $fetch_rc -eq 2 ]]; then
    # Discard ONLY a password THIS run collected — NEVER an operator-pre-staged one — so a
    # re-run of the one-liner asks again instead of re-using a credential we know is wrong.
    if [[ $hook_collected_pass == 1 ]]; then rm -f "$HELPER_PASS_FILE"; hook_collected_pass=0; fi
    die "could not fetch helper-lib.sh — ${fetch_fail_reason}.
NOT retrying: each attempt is a real login against the helper and repeated failures can get
this estate's IP banned by the helper's provider. Fix the cause and re-run the one-liner."
  fi
  attempts=$((attempts + 1))
  if (( attempts >= max_attempts )); then
    die "could not fetch helper-lib.sh after ${attempts} attempts — ${fetch_fail_reason}"
  fi
  log "retrying in 3s (attempt ${attempts}/${max_attempts}) — ${fetch_fail_reason}"
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
# Thread the durable auth fact both ways (issue #87/#90): PRELOAD it so the lib probes only
# the auth we already know works (no doomed pubkey login on a password-only seedbox), and
# point the lib's capture at the same PVE-host file so a first-ever run RECORDS it for the
# next one. needle re-reads both from the environment / the cache file.
[[ -n $auth_hint ]] && export PROVISIONER_HELPER_AUTH="$auth_hint"
export PROVISIONER_HELPER_AUTH_CACHE="${PROVISIONER_HELPER_AUTH_CACHE:-$HELPER_AUTH_CACHE}"
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
