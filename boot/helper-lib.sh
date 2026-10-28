# shellcheck shell=bash
#
# helper-lib.sh — ONE shared file-ops interface to the SFTP helper, transport-agnostic.
#
# SOURCE this (never exec): `. "$(dirname "$0")/helper-lib.sh"`. It defines a small
# file-store interface — the helper is a pure file store (SPEC §6), so every helper
# interaction the whole boot chain needs is expressible as a file op:
#
#     helper_put <local> <remote>     helper_get <remote> <local>
#     helper_exists <remote>          helper_ls <remote>
#     helper_mkdir_p <remote>         helper_rename <old> <new>
#     helper_remove <remote>          helper_rmdir <remote>
#     helper_ls_l <remote>            helper_mkdir_exclusive <remote>   (the mutex — issue #79)
#     helper_clear_tree <nfiles> <file>... <dir>...  (empty + remove a whole two-level
#                                                     tree in ONE login — issue #307)
#
# WHY THIS EXISTS — the helper's transport is NOT fixed across estates:
#   • The reference helper (openssh sftp-server, chrooted) answers KEY auth AND the exec
#     channel — `ssh helper 'mkdir -p / test -f / mv / rm'` works, the efficient path the
#     boot chain historically hardcoded.
#   • A seedbox helper (proftpd mod_sftp — the iapetus helper) answers NEITHER: pubkey is
#     rejected (PASSWORD only) and the exec channel is refused ("exec request failed on
#     channel 0"). It is SFTP-ONLY.
# So instead of hardcoding one, this lib PROBES the live helper once per process and
# caches the result, then every interface function uses the richest transport available:
#   AUTH probe   → key first, else password (SSH_ASKPASS reading <passfile>; see below).
#   CHANNEL probe → with the working auth, try an exec `true`; refused ⇒ SFTP-only.
# Net effect: today's proftpd helper auto-detects as password + SFTP-only and works;
# swap it later for an openssh sftp chroot and it auto-detects as key + exec with ZERO
# code change. (Operator requirement: "consider it as openssh; if not, sftp-only.")
#
# ── PASSWORD-SFTP INVARIANT (read before touching the sftp calls) ──────────────────────
# Password SFTP must NEVER run under `sftp -b` / batch / background: BatchMode=yes (which
# `-b` forces) DISABLES the password prompt, so nothing can ever answer it → instant
# "Permission denied, no more authentication methods". So we feed sftp commands on STDIN
# (no -b) with -oPreferredAuthentications=password -oPubkeyAuthentication=no
# -oNumberOfPasswordPrompts=1. The trade: without -b, sftp does NOT return a per-command
# rc (it exits 0 even when a command failed), so the exit status alone cannot be the whole
# verdict — a text check has to cover that ONE gap, and covering that gap is its ONLY job.
# What the text check is allowed to read is fixed by the rule immediately below. The
# password is ALWAYS read from a FILE — never a literal on argv, never echoed, never logged.
#
# ── HOW A TRANSFER IS JUDGED (read this before touching any verdict — issue #897) ──────
# THE RULE. The verdict is sftp's EXIT STATUS, plus — only for the gap above — a text check
# applied ONLY to what the FAR END said (its stderr), never to a line that merely echoes a
# path this side supplied, and never to a listing full of filenames the far end chose.
#
# WHAT WAS WRONG. `_helper_sftp_run` merged the two streams with `2>&1`, and every function
# below then grepped the merged text against a vocabulary containing `failure`, `fail$`,
# `cannot` and `can't`. sftp ECHOES the command it was fed back on STDOUT (`sftp> get …`,
# `Fetching <remote> to <local>`, `Uploading <local> to <remote>`), so the verdict was read
# off a line assembled from the CALLER'S OWN PATH. A lap's artifact is named after failures,
# so `…-failures.log` — the one file a build ships to say why it died — reported its own
# transfer as failed. That is the same defect #889 fixed in the session tooling, and this
# copy runs ON THE BOX, EVERY LAP.
#
# THE OTHER DIRECTION IS WORSE, and on the upload path nothing caught it: a real failure
# whose wording matched none of those words read as SUCCESS, and the build carried on over
# a file that never arrived. An `ls -la` verification would likewise answer "it is there"
# for any reply it did not recognise.
#
# SO: `_helper_sftp_run` keeps the streams APART and `_helper_sftp_session` captures them
# separately. Every verdict below is read from `$_SFTP_RC` and `$_SFTP_ERR`. NOTHING reads
# `$_SFTP_OUT` for a verdict — that stream is DATA (an echo, a listing), never evidence,
# because it is precisely where the caller's paths and the far end's filenames live.
#
# AND NO VERDICT IS READ THROUGH `printf … | grep -q`. Under `pipefail` that pipeline
# returns 141 when grep matches EARLY and kills the producer, and 141 is non-zero — which
# an `if` reads as "nothing wrong here". A verdict may not have a failure mode that points
# at success (issues #410/#425/#889), so every check below uses a HERE-STRING.
#
# ── HOW THE PASSWORD IS SUPPLIED — SSH_ASKPASS, no external tool (issue #104) ──────────
# We used to shell out to `sshpass -f <passfile>`, which meant the FIRST thing a bare
# Proxmox box had to do was `apt-get install sshpass` — i.e. the whole boot chain hung off
# a working apt + outbound internet on a host whose repos may not even be configured. That
# timed out live on iapetus (2026-08-07) and blocked the run at step one, and it was load-
# bearing: no sshpass ⇒ no helper ⇒ no needle ⇒ nothing.
#
# OpenSSH already supplies a password with NO external tool: SSH_ASKPASS names a program,
# and SSH_ASKPASS_REQUIRE=force (OpenSSH >= 8.4) makes ssh use it for ALL passphrase input
# "regardless of whether $DISPLAY is set" — so it works with no controlling terminal and no
# X, which is exactly the `curl | bash` console case AND the detached systemd case. Proven
# against the real proftpd seedbox helper from a headless container (issue #104) and re-
# proven here against the same OpenSSH 9.2p1 the PVE host runs.
#
# The askpass program we generate carries NO credential: it is three lines of /bin/sh that
# print the FIRST line of $PROVISIONER_ASKPASS_FILE (same semantics as `sshpass -f`, which
# also stops at the first newline; OpenSSH truncates the answer at \r\n either way). It is
# born under `umask 077`, chmod 700, and REMOVED the instant the op returns — so it never
# outlives a single ssh/sftp invocation. The credential itself never touches argv: the
# askpass program is invoked by ssh as `askpass "<prompt>"`, and the pass-file PATH (not the
# password) travels in the environment.
#
# It is EXEC'd, so it must not land on a `noexec` mount — the one hazard sshpass (a packaged
# binary) never had. _helper_askpass_dir() PROBES candidate directories by actually running a
# throwaway script and uses the first that works; if none does we degrade to sshpass, and if
# that is absent too we say so in those words. A noexec failure must NEVER be mistaken for a
# rejected password (ssh's wording for it contains "Permission denied") — hook.sh's
# classify_ssh_failure() matches `ssh_askpass:`/`exec(` BEFORE any auth pattern for exactly
# this reason.
#
# `sshpass` remains an OPTIONAL fallback for hosts that already have it (the control image
# bakes it) — see PROVISIONER_HELPER_PASS_MODE. It is no longer a prerequisite anywhere.
#
# Config (env, all overridable; sensible boot-chain defaults):
#   HELPER / PROVISIONER_HELPER        user@host of the helper (REQUIRED)
#   PROVISIONER_HELPER_PORT            ssh/sftp port                (default 22)
#   PROVISIONER_HELPER_ID / HELPER_ID  key tried for KEY auth       (default /root/.ssh/id_ed25519)
#   PROVISIONER_HELPER_PASS_FILE       password file for FALLBACK   (default /etc/provisioner/helper-pass)
#   PROVISIONER_HELPER_CONNECT_TIMEOUT ssh/sftp ConnectTimeout secs (default 15)
#   PROVISIONER_HELPER_PASS_MODE       askpass | sshpass | auto     (default auto)

# ── Resolved config (evaluated at source time; callers may pre-set any of these) ──────
: "${HELPER:=${PROVISIONER_HELPER:-}}"
HELPER_PORT="${PROVISIONER_HELPER_PORT:-22}"
# WHERE that port came from — carried ONLY so a FAILURE can name it (issue #143). An
# unthreaded PROVISIONER_HELPER_PORT silently becomes 22, which is a perfectly plausible port
# for SOMETHING to answer on, so "nobody chose this port, it is the fallback" is the single
# most useful fact a failure message can carry, and this is the only place that knows it.
if [ -n "${PROVISIONER_HELPER_PORT:-}" ]; then HELPER_PORT_SRC="PROVISIONER_HELPER_PORT"; else HELPER_PORT_SRC="default"; fi
HELPER_KEY="${PROVISIONER_HELPER_ID:-${HELPER_ID:-/root/.ssh/id_ed25519}}"
HELPER_PASS_FILE="${PROVISIONER_HELPER_PASS_FILE:-/etc/provisioner/helper-pass}"
HELPER_CONNECT_TIMEOUT="${PROVISIONER_HELPER_CONNECT_TIMEOUT:-15}"
# Explicit helper AUTH type (issue #90): 'auto' (default — probe key THEN password) |
# 'password' | 'key'. When set to a concrete type, _helper_auth_probe attempts ONLY that
# auth, so a password-only helper never gets a doomed PUBKEY attempt. WHY THIS MATTERS: the
# seedbox provider bans the estate's egress IP after 10 failed SSH/SFTP logins in an hour,
# and every pubkey attempt against a password-only proftpd helper is one failed login — a
# few pipeline runs/probes per hour tripped the 2h block (issue #87). The auth type is a
# KNOWN per-estate fact (proftpd seedbox = password; openssh chroot = key), so we DECLARE it
# instead of guessing: declared ⇒ 0 failed logins ⇒ nothing to ban. Staged per-estate to
# /etc/provisioner/helper-auth and exported as PROVISIONER_HELPER_AUTH (run-pipeline/needle).
HELPER_AUTH="${PROVISIONER_HELPER_AUTH:-auto}"
# Opt-in PERSISTENCE of the RESOLVED auth (issue #87 durability). When
# PROVISIONER_HELPER_AUTH_CACHE names a path, helper_detect writes the auth it resolves
# ('key'|'password') there on the FIRST successful detection. WHY: a full estate REBUILD comes
# up with an empty control node, so unless the auth fact is re-derivable a rebuilt (or a fresh
# steady-state) process falls back to HELPER_AUTH=auto and fires a doomed PUBKEY login against a
# password-only seedbox — every such failed login accrues toward the provider's ban (issue #87,
# same root cause as #90). Capturing it here lets a later process / rebuild PRELOAD
# PROVISIONER_HELPER_AUTH and probe ONLY that auth. Empty (the default) = disabled, so minimal
# callers that don't set it (hook.sh) are unaffected. Best-effort: a write failure never fails
# detection, and a brand-new estate with no fact yet still degrades cleanly to 'auto'.
HELPER_AUTH_CACHE="${PROVISIONER_HELPER_AUTH_CACHE:-}"
# Hard wall-clock cap for the DETECTION PROBES ONLY (never the data transfers below —
# image pushes legitimately take minutes). A key-auth probe against proftpd mod_sftp can
# ACCEPT an RSA key then HANG verifying the signature, and ConnectTimeout does NOT bound
# that post-auth hang — so every probe (and any caller that opts in via _HELPER_OP_TIMEOUT)
# is wrapped in `timeout`; a hang counts as "this transport does not work" and detection
# falls through to the next.
HELPER_PROBE_TIMEOUT="${PROVISIONER_HELPER_PROBE_TIMEOUT:-25}"

# Size ceiling (BYTES) under which _helper_put_verify checks CONTENT and not merely size after
# an upload (issue #434) — see that function's header. A size-only check cannot see the one
# failure it was written for ("this put never overwrote an OLDER copy") whenever the old and
# new files are the SAME LENGTH, which several of the estate's fixed-width receipts are
# (version-built: short commit ids + ISO timestamps; version; the tofu state's small siblings).
# For a file under this ceiling we DOWNLOAD the remote copy and compare bytes locally (the
# seedbox helper is SFTP-only and offers no server-side checksum); AT or ABOVE it we keep the
# size-only check, so a multi-GB seed is never round-tripped. Env-overridable; default 64 KiB.
HELPER_PUT_VERIFY_MAX="${PROVISIONER_HELPER_PUT_VERIFY_MAX:-65536}"

# Cipher/MAC pin for EVERY helper ssh/sftp op. WHY: the iapetus seedbox helper (proftpd
# mod_sftp) CORRUPTS any transfer >~1KB under the default cipher/MAC negotiation — SFTP
# reads fail with "message authentication code incorrect" (the default encrypt-then-MAC
# combo is what corrupts; NIC offload/MTU ruled out on the box). Forcing aes128-ctr +
# hmac-sha2-256 (the seedbox offers no AEAD cipher) tested 6/6 clean on 14KB+58KB files.
# Env-OVERRIDABLE, and using `-` (not `:-`) so an EMPTY value means "omit the flags":
# a clean key+exec OpenSSH helper can set PROVISIONER_HELPER_CIPHERS=/PROVISIONER_HELPER_MACS=
# empty to fall back to that peer's default negotiation. Only appended when non-empty.
HELPER_CIPHERS="${PROVISIONER_HELPER_CIPHERS-aes128-ctr}"
HELPER_MACS="${PROVISIONER_HELPER_MACS-hmac-sha2-256}"

# Options common to every ssh/scp/sftp to the helper. accept-new HONOURS a host key
# already pinned in known_hosts (verifies against it, refuses on a mismatch) rather than
# re-trusting: genesis.sh bakes the pin into the first control image
# (bootstrap/genesis.sh:414-431) and bake-nextgen carries it into every later seed
# (ansible/roles/bake-nextgen/tasks/main.yml:104-169), so this option is a first-contact
# TOFU only for a seed that genuinely shipped without a baked pin (review S5, closed).
_HELPER_SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout="${HELPER_CONNECT_TIMEOUT}")
[ -n "$HELPER_CIPHERS" ] && _HELPER_SSH_OPTS+=(-o Ciphers="$HELPER_CIPHERS")
[ -n "$HELPER_MACS" ] && _HELPER_SSH_OPTS+=(-o MACs="$HELPER_MACS")

# Detection cache (per process). Populated by helper_detect; _HELPER_DETECTED gates it.
_HELPER_DETECTED=""
_HELPER_AUTH=""          # key | password
_HELPER_EXEC=""          # 1 (exec channel usable) | 0 (SFTP-only)

_helper_log() { printf '[helper-lib] %s\n' "$*" >&2; }

# ROUTING ONLY (issue #147) — same text, different surface. _helper_log_quiet is for the
# lib's ROUTINE, successful-path chatter (the resolved-transport line, the auth-cache
# receipt): true, worth keeping, but it was ~3 of the ~60 lines a normal cold start printed
# at the PVE console and none of it is something the operator acts on. FAILURE messages —
# everything in _helper_log_no_auth, and every "put/get/rename/remove failed" — keep using
# _helper_log and stay LOUD. Nothing about the wording or the logic of those changes here.
#
# The DECISION is not made in this file. When the sourcing process defines _prov_quiet_sink
# (hook.sh and needle.sh do), the line is handed to it and that process decides console vs
# durable log per its own verbosity. When it does NOT (run-pipeline.sh on the control node,
# control-boot.sh, a bare `. helper-lib.sh`), this falls straight through to _helper_log —
# so every other consumer's output is byte-for-byte unchanged and nothing stops being
# recorded anywhere.
_helper_log_quiet() {
  if declare -F _prov_quiet_sink >/dev/null 2>&1; then
    _prov_quiet_sink "[helper-lib] $*"
  else
    _helper_log "$@"
  fi
}

# ── Password supply: SSH_ASKPASS first, sshpass only as an optional fallback (#104) ───
# PROVISIONER_HELPER_PASS_MODE: 'auto' (default — askpass when this OpenSSH supports
# SSH_ASKPASS_REQUIRE, else sshpass), 'askpass' (force it), 'sshpass' (force the legacy
# path; the escape hatch if a live run ever misbehaves on the askpass path).
HELPER_PASS_MODE="${PROVISIONER_HELPER_PASS_MODE:-auto}"
_HELPER_ASKPASS_OK=""     # memo: 1 = this ssh honours SSH_ASKPASS_REQUIRE=force
_HELPER_ASKPASS_DIR=""    # memo: a directory where a generated script actually EXECUTES
_HELPER_ASKPASS_DIR_TRIED=""   # the memo KEY the line above was resolved for (see below)
_HELPER_ASKPASS_WHY=""         # per-candidate verdicts from the last probe (for the failure text)

# WHERE the askpass program may live — it is EXEC'd by ssh, so the directory must be on a
# mount without `noexec`. This is the one failure mode sshpass never had (it is a packaged
# binary on the root fs), and it is nasty: a hardened host with `noexec` on /tmp makes ssh
# print "ssh_askpass: exec(/tmp/…): Permission denied", which reads exactly like a rejected
# password. So we do NOT assume — we PROBE each candidate by writing a trivial script and
# running it, and use the first that really executes.
#
# ── WHY THE LIST GREW, AND WHY THE PROBE NOW KEEPS ITS EVIDENCE (issue #159) ───────────
# On the 2026-08-10 00:55Z lap the control node — which HELD the PVE admin password and needed
# it to land the pipeline log on the host (#131) — printed
#     "no password transport: askpass has nowhere EXECUTABLE to live (noexec/unwritable
#      candidates) and sshpass is not installed"
# and the lap's only account of itself died with the node. The design was supposed to degrade;
# on that box it had nowhere left to degrade TO. Two things were wrong with THIS function:
#
#   1. It threw away everything it learned. Four candidates were tried and the message could
#      say only "noexec/unwritable" — the two causes it happens to name, which are not even the
#      only ones (a read-only or FULL root fs, a failed chmod, a missing /bin/sh all land here
#      too, and all four candidates fail identically). The repo's rule is that an error asserts
#      only what it established (#143/#146/#152); this one asserted a cause it never tested.
#      So every candidate now records WHY it was rejected, and the failure text prints the list.
#      An `exec` that is DENIED is rc 126 — that, not a guess, is what says "noexec".
#   2. It only ever considered four directories, and SKIPPED any that did not already exist.
#      The list now also carries the directory the credential itself lives in — by construction
#      ours, on the root fs, already trusted with a 0600 secret, and (via the dynamic scoping in
#      run-pipeline's _pve_ssh) the state dir of whatever credential is in play — plus /var/tmp,
#      /dev/shm and $HOME, and it CREATES a missing candidate (0700) instead of skipping it.
#
# Candidates, in order: an explicit override; the credential's own directory; /etc/provisioner
# (the boot chain's own dir, root-owned, on the root fs, created by hook.sh/control-boot);
# /run/provisioner and /run (tmpfs — NB Debian mounts /run noexec, hence the probe); $TMPDIR
# and /tmp (the historical default); then /var/tmp, /dev/shm and $HOME as last resorts.
#
# PROVISIONER_ASKPASS_DIR, when set, REPLACES the built-in list (it may name several dirs,
# space-separated). An explicit operator choice is authoritative: silently falling back to
# /tmp after the operator pointed us at a hardened box's one exec-capable directory would
# defeat the point of the knob. Unset ⇒ the built-in list.
_helper_askpass_candidates() {
  if [ -n "${PROVISIONER_ASKPASS_DIR:-}" ]; then printf '%s' "$PROVISIONER_ASKPASS_DIR"; return 0; fi
  local creddir=""
  # The dir holding the password we are about to READ. run-pipeline's _pve_ssh re-points
  # HELPER_PASS_FILE by dynamic scope at the PVE admin credential, so this follows whichever
  # credential is actually in play rather than the helper's alone.
  case "${HELPER_PASS_FILE:-}" in */*) creddir="${HELPER_PASS_FILE%/*}" ;; esac
  printf '%s' "${creddir} /etc/provisioner /run/provisioner /run ${TMPDIR:-/tmp} /tmp /var/tmp /dev/shm ${HOME:-}"
}

# The memo is KEYED, not a bare flag. A FAILED probe used to be cached forever under
# _HELPER_ASKPASS_DIR_TRIED=1, so the source-time probe at the bottom of this block — which
# runs against the HELPER's password file, before any caller has re-pointed anything — could
# poison every later attempt in the process, including _pve_ssh's with a different credential
# and therefore a different candidate list. Keying on the inputs means a changed credential,
# TMPDIR, HOME or override re-probes; an unchanged one still costs nothing.
_helper_askpass_dir() {
  local key="${PROVISIONER_ASKPASS_DIR:-}|${HELPER_PASS_FILE:-}|${TMPDIR:-}|${HOME:-}"
  if [ "$_HELPER_ASKPASS_DIR_TRIED" = "$key" ]; then
    [ -n "$_HELPER_ASKPASS_DIR" ] && { printf '%s' "$_HELPER_ASKPASS_DIR"; return 0; }
    return 1
  fi
  _HELPER_ASKPASS_DIR_TRIED="$key"; _HELPER_ASKPASS_DIR=""; _HELPER_ASKPASS_WHY=""
  local d probe rc seen="" why="" override=""
  # An OVERRIDE is taken literally: a named directory that does not exist is reported, never
  # created. The operator pointed at a specific place on a specific box, so a path that is not
  # there is a typo worth surfacing — whereas a missing BUILT-IN candidate (/run/provisioner)
  # is just a directory nobody has made yet, and making it is the point.
  [ -n "${PROVISIONER_ASKPASS_DIR:-}" ] && override=1
  # Deliberately unquoted: the list is space-separated (and the override may carry several).
  # shellcheck disable=SC2046,SC2086
  for d in $(_helper_askpass_candidates); do
    [ -n "$d" ] || continue
    case "$seen" in *"|${d}|"*) continue ;; esac      # the creddir is usually /etc/provisioner
    seen="${seen}|${d}|"
    if [ ! -d "$d" ]; then
      if [ -n "$override" ]; then
        why="${why}${d}: named by PROVISIONER_ASKPASS_DIR but does not exist; "; continue
      fi
      # CREATE it rather than skip it: /run/provisioner never exists until someone makes it,
      # and on a box where /run is the only exec-capable mount that skip was the whole failure.
      ( umask 077; mkdir -p "$d" ) 2>/dev/null || { why="${why}${d}: absent and could not be created; "; continue; }
    fi
    # access(2), so this also catches a READ-ONLY mount (EROFS), not just the mode bits.
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

# The per-candidate audit, as a clause a failure message drops straight in. Empty when the
# probe never ran in THIS shell — _helper_pass_transport is called inside a $( ), so callers
# that want the audit must run _helper_askpass_dir in their own shell first (they do below).
_helper_askpass_audit() {
  [ -n "$_HELPER_ASKPASS_WHY" ] || return 0
  printf ' Every candidate directory was tried and rejected — %s' "${_HELPER_ASKPASS_WHY%; }"
}

# Does the local OpenSSH honour SSH_ASKPASS_REQUIRE=force? Introduced in OpenSSH 8.4 —
# older clients only consult SSH_ASKPASS when DISPLAY is set AND there is no tty, which is
# NOT good enough for the console `curl|bash` case (a tty IS present there). `ssh -V` prints
# to stderr, e.g. "OpenSSH_9.2p1 Debian-2+deb12u10, OpenSSL ...". Unparseable ⇒ assume NO
# (fall back to sshpass) rather than silently hang on an unanswered prompt.
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
# Resolve BOTH memos at source time. _helper_pass_transport runs inside a $( ) subshell, so a
# memo written there would be thrown away and every helper op would re-fork `ssh -V` and re-run
# the exec probe. The dir probe writes+execs a file, so it is skipped entirely unless a password
# file exists (a key-only estate never touches the disk for this). NB this pre-resolution is
# against the HELPER's pass file; a caller that re-points HELPER_PASS_FILE (run-pipeline's
# _pve_ssh does, by dynamic scope) changes the memo KEY and gets its own probe — which is the
# whole reason the memo is keyed rather than a bare "already tried" flag (issue #159).
_helper_askpass_supported >/dev/null 2>&1 || :
[ -n "$HELPER_PASS_FILE" ] && [ -f "$HELPER_PASS_FILE" ] && _helper_askpass_dir >/dev/null 2>&1
: # keep the source-time status clean for `set -e` callers

# askpass is usable only if BOTH the client honours `force` AND we found somewhere the
# generated program can actually execute (the noexec trap above).
_helper_askpass_usable() { _helper_askpass_supported && _helper_askpass_dir >/dev/null && [ -n "$_HELPER_ASKPASS_DIR" ]; }

# Which password transport will actually be used? Prints 'askpass' | 'sshpass' | '' (none
# usable). Callers use the empty case to explain WHY a password auth is not attempted.
# Note the auto branch DEGRADES: a noexec-everywhere host silently falls back to sshpass
# when it has it, rather than failing in a way that looks like a bad credential.
_helper_pass_transport() {
  case "$HELPER_PASS_MODE" in
    askpass) _helper_askpass_usable && printf 'askpass'; return ;;
    sshpass) command -v sshpass >/dev/null 2>&1 && printf 'sshpass'; return ;;
  esac
  if _helper_askpass_usable; then printf 'askpass'
  elif command -v sshpass >/dev/null 2>&1; then printf 'sshpass'
  fi
}

# Mint a throwaway askpass program. It contains NO credential — it prints the FIRST line of
# the file named by $PROVISIONER_ASKPASS_FILE (which ssh exports into it). Born 0600 by
# mktemp under umask 077, then 0700 so ssh can exec it. Lands in an EXEC-VERIFIED directory
# (see _helper_askpass_dir). Caller MUST rm it (every caller below does, immediately after
# the op returns, so it never outlives one invocation).
_helper_askpass_new() {
  local f
  # Called plainly (not in a $( )) so the memo survives into THIS shell — a subshell could
  # not write $_HELPER_ASKPASS_DIR back and every op would re-run the exec probe.
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

# Run "$@" (a complete ssh/sftp command line that already carries the password-auth -o
# flags) with the helper password supplied from $HELPER_PASS_FILE. rc = the command's rc,
# or 255 when no password transport is available at all (same shape as an ssh failure).
# Owns the `timeout` prefix (from _HELPER_OP_TIMEOUT, as the callers used to) so that on the
# sshpass path the wrapping order stays exactly what it has always been: timeout → sshpass →
# ssh/sftp. NB: the askpass child inherits our stdin but never reads it, so the sftp command
# pipe feeding stdin (the never-batch-mode invariant above) is untouched.
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
      # Legacy path, kept for hosts that already have sshpass (the control image bakes it).
      # `-f <file>`: the password stays in a file, never on argv.
      "${to[@]}" sshpass -f "$HELPER_PASS_FILE" "$@"
      return $?
      ;;
    *)
      if _helper_askpass_supported; then
        # Re-run the probe HERE, in this shell: _helper_pass_transport ran inside a $( ), so
        # whatever it learned about the candidates died with that subshell. This is the failure
        # path, it is about to give up, and the audit is the only thing that makes the next
        # occurrence diagnosable in one line instead of a day (issue #159).
        _helper_askpass_dir >/dev/null 2>&1 || :
        _helper_log "no password transport: askpass has nowhere EXECUTABLE to live and sshpass is not installed — set PROVISIONER_ASKPASS_DIR, or check 'findmnt -no OPTIONS /tmp'.$(_helper_askpass_audit)"
      else
        _helper_log "no password transport available (this ssh predates SSH_ASKPASS_REQUIRE=force and sshpass is not installed)"
      fi
      return 255
      ;;
  esac
}

# ── Low-level auth-resolved transports ────────────────────────────────────────────────
# One sftp session reading commands from STDIN. Auth is whatever helper_detect resolved.
# NEVER uses -b (see the password-sftp invariant above).
#
# THE TWO STREAMS ARE NOT MERGED (issue #897). This used to end `2>&1` on both branches and
# every caller took its verdict off the result — i.e. off a text that begins with sftp
# echoing back the path WE handed it. Which stream a line arrived on IS the evidence that
# tells our own echo from the far end's reply, and merging them threw that evidence away.
# Callers that need a verdict go through _helper_sftp_session below; callers that only want
# the transport (helper_ls, helper_mkdir_p, helper_remove, helper_rmdir) redirect stderr
# themselves, and for those it now lands on THEIR stderr instead of inside their stdout —
# which is why a far-end complaint can no longer arrive inside a listing dressed as a
# filename.
_helper_sftp_run() {
  local to=(); [ -n "${_HELPER_OP_TIMEOUT:-}" ] && to=(timeout -k 5 "$_HELPER_OP_TIMEOUT")
  if [ "$_HELPER_AUTH" = password ]; then
    # _helper_pass_run owns the timeout prefix on this branch (issue #104). NO BatchMode
    # here, deliberately — see the password-sftp invariant at the top of this file.
    _helper_pass_run sftp \
      -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
      -P "$HELPER_PORT" "${_HELPER_SSH_OPTS[@]}" "$HELPER"
  else
    "${to[@]}" sftp -i "$HELPER_KEY" -o IdentitiesOnly=yes -o PreferredAuthentications=publickey -o BatchMode=yes \
      -P "$HELPER_PORT" "${_HELPER_SSH_OPTS[@]}" "$HELPER"
  fi
}

# ── ONE sftp session, the two streams kept apart (issue #897) ─────────────────────────
# _helper_sftp_session <commands> — run the commands in one session and publish what came
# back, in the CALLER'S shell. It is a plain function call and NOT a pipeline on purpose: a
# `$( )` would carry the assignments off with the subshell.
#
#   _SFTP_RC    sftp's exit status. THE verdict.
#   _SFTP_ERR   what the FAR END said. The ONLY text any verdict may be read from. A path
#               appears here only because something went wrong with it, which is what makes
#               a wide vocabulary safe against it and unsafe against anything else.
#   _SFTP_OUT   what the session printed: our own commands echoed back, the per-file
#               announcements, and listings. DATA, never evidence.
#
# Callers snapshot what they need into locals IMMEDIATELY, because a nested helper call
# (helper_get inside the put-verification, for one) runs its own session and clobbers these.
_SFTP_RC=0
_SFTP_ERR=""
_SFTP_OUT=""
_helper_sftp_session() {
  local errf=""
  _SFTP_OUT=""; _SFTP_ERR=""; _SFTP_RC=0
  errf="$(mktemp "${TMPDIR:-/tmp}/prov-sftp-err.XXXXXX" 2>/dev/null)" || errf=""
  if [ -z "$errf" ]; then
    # Nowhere to keep the replies. Degrade to the EXIT STATUS ALONE and say so out loud.
    # Merging the streams back together to recover some text is the defect itself (#897);
    # a weaker verdict is acceptable, one that can read a filename as a failure is not.
    _SFTP_OUT="$(printf '%s\n' "$1" | _helper_sftp_run 2>/dev/null)"; _SFTP_RC=$?
    _helper_log "could not create a temp file to keep the helper's replies apart from its own echo — this session is judged on its EXIT STATUS alone"
    return 0
  fi
  _SFTP_OUT="$(printf '%s\n' "$1" | _helper_sftp_run 2>"$errf")"; _SFTP_RC=$?
  _SFTP_ERR="$(cat "$errf" 2>/dev/null)"
  rm -f "$errf"
  return 0
}

# _helper_sftp_said — the one-line account of the session just run, for a message a human
# reads: the FAR END's replies first (the reason), then the session's own output with sftp's
# chatter stripped (the context).
#
# NEVER EMPTY. "the transfer said:" printed over nothing is half of what made #889 hard to
# see — the chatter filter removed the very line the verdict had fired on, so the error
# arrived with silence underneath it. If both streams really are silent, the exit status is
# the finding and it is printed instead.
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

# _helper_scrub_target <text> — print it with the helper's coordinates replaced by the fixed
# markers the rest of this file uses.
#
# WHY. The user@host is a SECRET (SPEC §6.2: the helper's coordinates) and these lines are
# captured and shipped OFF-BOX by run-pipeline's self-log (issue #84) — which is why every
# message in this library says 'HELPER' and never interpolates $HELPER. A TRANSCRIPT is the
# one place the address can arrive without anyone having interpolated it: ssh writes it
# itself ("ssh: connect to host <host> port 22: Connection refused", "<user>@<host>:
# Permission denied (password).", "Connection closed by <ip> port <p>"). Handing more
# transcript back to the caller — which is the right fix for #406 and #897 — would otherwise
# have widened that exposure, so it is closed here.
#
# ── THE WHOLE TOKEN FIRST, AND WHY THE ORDER IS THE WHOLE FIX ─────────────────────────
# The first cut of this function replaced only the HOST half, which turned
# `iapetus@helper.iapetus.dedyn.io` into `iapetus@HELPER` — and that token is invisible to
# BOTH of scrub-log.py's defences downstream. Its `_USER_AT_HOST_RE` requires a DOTTED host
# to the right of the `@`, and `HELPER` has no dot; its verbatim-literal pass is a substring
# match for the exact `user@host` value, which no longer appears anywhere. Measured against
# the real scrubber: the untouched line came out `REDACTED`, the half-rewritten one came out
# verbatim. So a function added to prevent a leak had converted a token both layers caught
# into one neither catches — and against a password-only seedbox that bans on failed logins
# (#87/#90), the account name is half the credential pair.
#
# THE RULE THIS ENCODES: never hand a HALF-REWRITTEN secret downstream. Replace the complete
# token before any of its parts, so anything that reaches the next layer is either intact
# (and recognised) or wholly gone.
#
# A BARE LOGIN NAME standing on its own is still left alone: it can be an ordinary word, and
# blanking it would mangle paths in the very message someone is reading to find out what
# broke. The 4-character interlock is scrub-log.py's reasoning in miniature — a blind
# substring replace of something short does more harm than the leak it prevents.
#
# ── AND THE ADDRESS LITERALS (#897 review, F3) ────────────────────────────────────────
# The two shapes named above that matter most on a banned seedbox — `Connection closed by
# <ip> port <p>` and `Received disconnect from <ip> port 22:2: Too many authentication
# failures` — carry the RESOLVED ADDRESS, not the DNS name, so a substring replace of
# $HELPER never touches them. The shipped artifact is covered (scrub-log.py pseudonymises
# IPs), but the paths with NO downstream scrubber are not: needle.sh's PVE console output
# and genesis.sh on the build host both source this library and print these lines raw. So
# every dotted quad is collapsed here too. In a HELPER transcript an address is the helper's
# by construction, the estate's addresses are secret as a class (SPEC §6.2), and the cost of
# over-redacting an odd dotted-quad-shaped token in a diagnostic is far below the cost of
# the leak — the same posture scrub-log.py states for itself. IPv4 only: the helper's SFTP
# path is IPv4-only (it needs an A record), so there is no v6 literal to meet here.
_helper_scrub_target() {
  local text="$1" host="${HELPER#*@}" collapsed
  [ -n "$HELPER" ] && [ "${#HELPER}" -ge 4 ] && text="${text//"$HELPER"/HELPER}"
  [ -n "$host" ] && [ "${#host}" -ge 4 ] && text="${text//"$host"/HELPER}"
  # THE RESULT IS ONLY TAKEN IF THERE IS ONE. `\b` is a GNU extension, and every box in this
  # chain is Debian, but a sed that errored or is not GNU would otherwise turn the whole
  # message into an EMPTY STRING — which is the "label printed over silence" defect of #889
  # wearing a different hat, arrived at through the scrubber. Keep the name-scrubbed text and
  # lose only the address pass.
  collapsed="$(printf '%s' "$text" | sed -E 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/REDACTED-ADDRESS/g' 2>/dev/null)"
  [ -n "$collapsed" ] && text="$collapsed"
  printf '%s' "$text"
}

# One exec command with the resolved auth. Returns the remote command's rc (or 255 on a
# transport/channel failure — which is exactly how the channel probe detects SFTP-only).
#
# `ssh -n` (stdin ← /dev/null) is MANDATORY: this runs a REMOTE COMMAND (never interactive),
# and the exec-channel probe (helper_detect) fires while hook.sh is running under `curl|bash`,
# where the process stdin IS the pipe still feeding the script. Without -n, ssh reads that
# pipe as the remote command's stdin and SWALLOWS the rest of hook.sh — so the needle is
# fetched but hook exits before running it (silent wedge, SFTP-only helper only: the exec
# probe's ssh is the trigger; a key+exec helper's probe succeeds too fast to notice). None of
# our remote commands (true/test/mkdir/mv/rm/ls) read stdin, so -n is always safe here.
_helper_ssh_raw() {
  local to=(); [ -n "${_HELPER_OP_TIMEOUT:-}" ] && to=(timeout -k 5 "$_HELPER_OP_TIMEOUT")
  if [ "$_HELPER_AUTH" = password ]; then
    # _helper_pass_run owns the timeout prefix on this branch (issue #104).
    _helper_pass_run ssh -n \
      -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
      -p "$HELPER_PORT" "${_HELPER_SSH_OPTS[@]}" "$HELPER" "$@"
  else
    "${to[@]}" ssh -n -i "$HELPER_KEY" -o IdentitiesOnly=yes -o PreferredAuthentications=publickey -o BatchMode=yes \
      -p "$HELPER_PORT" "${_HELPER_SSH_OPTS[@]}" "$HELPER" "$@"
  fi
}

# ── Quoting helpers ───────────────────────────────────────────────────────────────────
# _shq: single-quote for a remote POSIX shell (exec path).  _sftpq: double-quote for the
# sftp command parser (it groups double-quoted tokens; backslash-escape embedded " and \).
_shq()   { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
_sftpq() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

# Error markers sftp/scp print on a failed op (success prints none of these).
#
# MATCHED AGAINST THE FAR END'S REPLIES ONLY — $_SFTP_ERR, never $_SFTP_OUT (issue #897).
# That is what lets this set be WIDE: on stderr a path appears only because something went
# wrong with it, so widening the vocabulary cannot turn a FILENAME into a verdict. On the
# merged text it could, and did: `failure` matched `…-failures.log` in sftp's own echo of
# the get we had just asked for, and the file that says why a build died was the one file
# this library insisted it could not fetch.
#
# `failure`/`failed` are matched as WHOLE WORDS even here, so that a reply which happens to
# name a file called `…-failures.log` (`File "…-failures.log" not found.`) is classified on
# what the far end SAID and not on the name it quoted back. The trailing alternative is the
# real sftp shape: `Couldn't create directory: Failure`.
#
# The last alternative is sftp's general "a command inside the session failed" shape —
# `download /x: not a regular file`, `remote open("/x"): Permission denied`, `stat /x: …` —
# so a refusal worded in a way nobody listed here is still a refusal rather than a success.
# Widened in #897 for exactly that reason: the false-SUCCESS direction had no backstop at
# all on the verification path, and "a wording we do not recognise" was reading as "fine".
_HELPER_ERR_RE='permission denied|no such file|not found|couldn.?t|cannot|can.?t|not a regular file|no space left|quota exceeded|disk quota|(^|[^[:alnum:]])(failure|failed)([^[:alnum:]]|$)|fail$|^(remote|local|download|upload|stat|lstat|open|read|write|rename|mkdir|rmdir|remove|readdir|setstat|symlink|realpath)[a-z_]* .*: '

# A REJECTED CREDENTIAL, specifically — narrow on purpose, mirroring hook.sh's
# classify_ssh_failure 'auth' set exactly (same markers, same reasoning). This is DELIBERATELY
# NOT _HELPER_ERR_RE: that set also matches genuine transport text ("Couldn't read packet:
# Connection reset by peer"), so testing it before XPORT_RE would misclassify a real transport
# fault as a permanent refusal and stop retrying something that should have retried. This set
# only matches text an auth rejection actually produces.
# rclone words a refused login "unable to authenticate" (#1201), never a transport fault; only "Permission denied (" / ", please" is auth - a bare one is a file permission
_HELPER_AUTH_RE='permission denied ?\(|permission denied, please|authentication failed|no more authentication methods|too many authentication failures|access denied|unable to authenticate'

# Markers that mean the SESSION died rather than the operation being refused (issue #159).
# These are RETRYABLE and — the part that matters — they do NOT establish anything about the
# remote path, so a message must not claim the file is absent on the strength of one. Kept
# separate from _HELPER_ERR_RE, which is the "the helper answered and said no" set.
#
# _HELPER_AUTH_RE MUST be tested BEFORE this, every time both are consulted — hook.sh's
# classify_ssh_failure documents the identical trap on its own 'auth' vs 'banned' ordering: a
# REJECTED credential also ends in a server-side disconnect, so the transcript is
# `Permission denied (publickey,password).` FOLLOWED BY `Connection closed.` Testing this
# pattern first classifies that as a transport fault, which RETRIES — a second, then a third,
# real failed login against a login-attempt-hardened seedbox, exactly the #87/#90 ban risk
# this file exists to prevent, arrived at from the opposite direction.
#
# `message authentication code incorrect` belongs HERE and not in the refusal set: it is the
# documented iapetus-seedbox corruption (see HELPER_CIPHERS above), it is a property of the
# link and not a decision the helper made, and it is the one shape a retry genuinely fixes.
# Before #897 it matched nothing at all, so a corrupted download exited 0, wrote a damaged
# file, and helper_get's `[ -f dst ]` backstop called that a success.
_HELPER_XPORT_RE='connection (timed out|closed|reset)|lost connection|broken pipe|connection to .* closed|no route to host|network is unreachable|banner exchange|kex_exchange|client_loop|write failed|message authentication code'

# ── Will this credential actually be OFFERED? — one source of truth (issue #146) ──────
# Prints NOTHING when the named auth ('key'|'password') WILL be attempted, and otherwise the
# reason it will not, phrased as a clause a failure message can drop straight in.
#
# WHY THIS EXISTS. The #143 replacement text still said "(tried key '<path>', password
# '<path>')" on every auth-shaped failure, interpolating the CONFIGURED paths whether or not
# either was ever sent. On the real estates it usually was not: the helper is a password-only
# proftpd seedbox, PROVISIONER_HELPER_AUTH is preloaded to 'password' (issue #90) precisely so
# no doomed pubkey login is fired, and the key block is then skipped entirely. The live capture
# on 2026-08-09 12:21Z accordingly claimed "tried key '/root/.ssh/id_ed25519'" for a key that
# was never offered — sending whoever read it to check that key's permissions, its presence in
# the helper's authorized_keys and its format, none of which had been consulted. That is the
# exact hour #143 was filed to stop costing, reintroduced inside #143's own fix.
#
# THE RULE, again: an error asserts ONLY what it established. "Tried" is a claim about what
# left this host, so it must be read off the code that decides what leaves this host.
#
# Every branch here is a guard _helper_auth_probe used to spell out inline; nothing about WHICH
# auths are attempted changes. Cheap and pure (env + `test -f`) except the password-transport
# branch, which is the same `$( _helper_pass_transport )` the probe already ran — so a failure
# path pays for one extra askpass-dir probe and the happy path pays nothing at all.
# WHERE THE PIN ACTUALLY CAME FROM (issue #157). Naming only PROVISIONER_HELPER_AUTH is a
# half-truth that costs an hour: on every estate the boot chain PRELOADS that variable from the
# durable fact FILE, so the operator who unsets the env var — the only knob the message names —
# finds the pin still in force on the next run and has nothing to go on. It matters most in the
# one procedure that must work under compromise: after revoking every authorized key on a
# key-capable helper (HELPER-HARDENING §4 step 1), a fact file still reading 'key' makes the
# chain offer a pubkey and never ask for the password. Empty cache path ⇒ no clause, so minimal
# callers that never set one (hook.sh) read exactly as they did.
_helper_auth_pin_origin() {
  [ -n "$HELPER_AUTH_CACHE" ] || return 0
  printf ". NB nobody necessarily TYPED that: the boot chain preloads it from the durable auth fact at '%s', so unsetting the environment variable alone does NOT lift the pin — delete that file too when you are deliberately re-deriving the auth (docs/handbook/HELPER-HARDENING.md §4)" "$HELPER_AUTH_CACHE"
}

_helper_auth_skip_reason() {
  case "$1" in
    key)
      # The declared-auth pin (issue #90). Named as the ENV VAR because that is the knob; the
      # boot chain preloads it from the staged per-estate helper-auth fact (needle.sh,
      # control-boot.sh, run-pipeline.sh all do this), which is where an operator changes it —
      # and _helper_auth_pin_origin names that file, because the env var alone is not enough
      # to lift the pin.
      [ "$HELPER_AUTH" = password ] && { printf "key auth was NOT attempted, so the key '%s' is not implicated — PROVISIONER_HELPER_AUTH=password pins this estate to password auth (a pubkey attempt against a password-only helper is a wasted failed login and accrues toward the provider's ban)%s" "$HELPER_KEY" "$(_helper_auth_pin_origin)"; return 0; }
      [ -n "$HELPER_KEY" ] || { printf 'key auth was NOT attempted — no key path is configured (PROVISIONER_HELPER_ID/HELPER_ID are empty)'; return 0; }
      [ -f "$HELPER_KEY" ] || { printf "key auth was NOT attempted — the key file '%s' does not exist on this host" "$HELPER_KEY"; return 0; }
      ;;
    password)
      [ "$HELPER_AUTH" = key ] && { printf "password auth was NOT attempted, so the password file '%s' is not implicated — PROVISIONER_HELPER_AUTH=key pins this estate to key auth%s" "$HELPER_PASS_FILE" "$(_helper_auth_pin_origin)"; return 0; }
      [ -n "$HELPER_PASS_FILE" ] || { printf 'password auth was NOT attempted — no password file is configured (PROVISIONER_HELPER_PASS_FILE is empty)'; return 0; }
      [ -f "$HELPER_PASS_FILE" ] || { printf "password auth was NOT attempted — the password file '%s' does not exist on this host" "$HELPER_PASS_FILE"; return 0; }
      # The $( ) that computes the transport discards what the dir probe learned, so re-run it
      # here (same shell as the printf) to get the per-candidate audit into the sentence.
      [ -n "$(_helper_pass_transport)" ] || { _helper_askpass_dir >/dev/null 2>&1 || :
        printf 'password auth was NOT attempted — this host has no usable way to SUPPLY a password: no exec-capable SSH_ASKPASS directory and no sshpass. Set PROVISIONER_ASKPASS_DIR to an exec-capable dir, or install sshpass.%s' "$(_helper_askpass_audit)"; return 0; }
      ;;
  esac
  return 0    # printed nothing ⇒ this auth WILL be attempted
}

# ── Detection (run once, cached) ──────────────────────────────────────────────────────
# AUTH probe uses an sftp `quit` (tests auth AND the sftp subsystem in one shot). Key
# first (if a key file exists), then password (if a passfile + a password transport
# exist — askpass or sshpass, issue #104; sshpass is no longer required) — UNLESS
# HELPER_AUTH pins one type (issue #90), in which case ONLY that type is attempted so the
# other never fires a doomed login. `HELPER_AUTH=password` skips the key block entirely
# (the whole point: no pubkey attempt against a password-only helper); `=key` skips the
# password block. Each block still VERIFIES its auth (an sftp quit), so a declared-but-
# broken auth still fails cleanly to rc 1 rather than silently claiming success.
#
# THE GUARDS LIVE IN _helper_auth_skip_reason (issue #146), NOT inline here. They used to be
# written out twice — once as the conditions above, once as the failure message's "(tried key
# '…', password '…')" — and the two disagreed: the message interpolated the CONFIGURED paths
# unconditionally, so a password-only estate was told its key had been tried and rejected when
# the key block had been skipped entirely. Reading them from one function means the sentence
# that says what was offered is generated by the same code that decides what to offer, and the
# two cannot drift apart again.
_helper_auth_probe() {
  if [ -z "$(_helper_auth_skip_reason key)" ]; then
    if printf 'quit\n' | timeout -k 5 "$HELPER_PROBE_TIMEOUT" sftp -i "$HELPER_KEY" -o IdentitiesOnly=yes \
         -o PreferredAuthentications=publickey -o BatchMode=yes \
         -P "$HELPER_PORT" "${_HELPER_SSH_OPTS[@]}" "$HELPER" >/dev/null 2>"${_HELPER_PROBE_ERRF:-/dev/null}"; then
      printf 'key'; return 0
    fi
  fi
  # Evaluated ONLY if the key path did not already win — same lazy order as before, so a
  # key-auth estate never pays for the password-transport probe (which writes and EXECs a
  # throwaway script to find a non-noexec directory).
  if [ -z "$(_helper_auth_skip_reason password)" ]; then
    # Only the LAST probe's words classify a failure (#1201): a refused key on a password-only host is expected.
    [ -z "${_HELPER_PROBE_ERRF:-}" ] || : > "$_HELPER_PROBE_ERRF"
    if printf 'quit\n' | _HELPER_OP_TIMEOUT="$HELPER_PROBE_TIMEOUT" _helper_pass_run sftp \
         -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
         -P "$HELPER_PORT" "${_HELPER_SSH_OPTS[@]}" "$HELPER" >/dev/null 2>"${_HELPER_PROBE_ERRF:-/dev/null}"; then
      printf 'password'; return 0
    fi
  fi
  return 1
}

# ── Is the TARGET even there? — connectivity vs auth (issue #143) ─────────────────────
# THE RULE THIS ENCODES: an error must not assert a cause it has not established. The line
# this replaced — "no working auth to HELPER (tried key '…', password '…')" — stated a
# CONCLUSION (the credentials were rejected) on an observation that does not support it (no
# transport worked). Every fact in it was true and the conclusion it invited was wrong: with
# PROVISIONER_HELPER_PORT unthreaded, HELPER_PORT falls back to 22, nothing on the real helper
# answers there, and the operator is sent to the password file, DNS, sshpass and the systemd
# environment. That produced a bogus go-live blocker (#136, closed as invalid) and burned a
# day on 2026-08-09 for what was an unthreaded port.
#
# So on the FAILURE PATH ONLY (never the happy path — a working helper pays nothing: no extra
# login, no extra latency) we ask the cheap prior question: does anything accept a TCP
# connection at HELPER:<port>? A closed port means the SSH conversation never happened, so NO
# credential was ever offered and none can be implicated.
#
# Same discipline as hook.sh's classify_ssh_failure(), which tests `ssh_askpass:`/`exec(`
# BEFORE any auth pattern for exactly this reason. That function is NOT reachable from here
# (it lives in hook.sh; needle.sh and run-pipeline.sh source this lib without it), so this
# MIRRORS its structure — non-auth explanations first, same vocabulary — rather than inventing
# a second taxonomy. NOT memoized, deliberately: a cached "refused" reused after the helper
# came back would be the very sin this function exists to stop.
#
# Prints exactly one of: open | refused | unreachable | dns | untestable
_helper_reach() {
  local host out rc
  host="${HELPER#*@}"
  [ -n "$host" ] || { printf 'untestable'; return 0; }
  # bash's built-in /dev/tcp — no external tool (`nc` is not on a fresh PVE host), the same
  # probe hook.sh's reachability pre-check uses. Run in its own `bash -c` so the fd can never
  # escape into this shell, and under `timeout` so an unrouted address cannot hang a lap.
  # host/port are passed as ARGUMENTS, not interpolated into the -c string: an address that
  # arrived from a config file must never be able to become shell.
  out="$(timeout 5 bash -c 'exec 3<>/dev/tcp/"$0"/"$1"' "$host" "$HELPER_PORT" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && { printf 'open'; return 0; }
  out="$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')"
  # FIRST, exactly like classify_ssh_failure's envfault case: a bash built without net
  # redirections reports the path as a missing FILE. That is "we could not ask", never
  # "nothing is listening" — turning an unasked question into an answer is the whole defect.
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

# The failure line for a helper we could not use (issue #143). It REPORTS what was observed
# and names the WHOLE target it observed it against — the port included, because the port was
# the missing fact both times this misfired.
#
# WHY THE HOST IS STILL THE FIXED MARKER 'HELPER': the user@host is a SECRET (SPEC §6 — the
# helper's coordinates) and these lines are captured and shipped off-box by run-pipeline's
# self-log (issue #84), so it must never be interpolated; the scrubber is only the second
# layer of defence. The PORT is named: it is a number, it is what the operator lacks, and the
# rest of the chain (hook.sh's pre-check, needle's runlog) already prints it on this console.
#
# AND IT NAMES ONLY THE CREDENTIALS THAT ACTUALLY LEFT THIS HOST (issue #146). The two auth
# branches below carry ${tried} — built from _helper_auth_skip_reason, the same function whose
# verdicts _helper_auth_probe obeys — instead of interpolating ${HELPER_KEY}/${HELPER_PASS_FILE}
# unconditionally. On the failure path "attempted" and "not skipped" are the same set: the probe
# returns non-zero only after walking BOTH blocks, and a block that was not skipped ran (a block
# that ran and SUCCEEDED never reaches this function). So the sentence is a report, not a guess.
#
# The connectivity branches (refused/unreachable/dns) are UNCHANGED and deliberately name no
# credential at all — they already say "NO credential was tried", which stays exactly right
# whatever the auth configuration was. #143's distinction is the thing this must not disturb.
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
    # NEITHER auth was offerable ⇒ not one byte of credential left this host, so there is no
    # authentication failure to report at all. This is a LOCAL CONFIGURATION fault, and the
    # two clauses say which one. It replaces ONLY the auth branches below; the connectivity
    # classification still runs and still wins, because a target that is not there blocks the
    # lap whatever the credential situation is, and #143's ordering — non-auth explanations
    # BEFORE any auth-shaped one — is the rule that must not be re-litigated here.
    tried="NO credential was offered: not one byte was sent, so nothing here is an authentication failure, it is a LOCAL CONFIGURATION fault on this host. ${key_skip}; ${pw_skip}"
    # …and the VERB changes with it. "could not authenticate" is itself a claim that an
    # authentication was attempted, which is the very shape of assertion #146 is about.
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

# #1203: the access path's sign-in check. ONE rclone listing of the login root (the folder-is-plain check of
# _helper_crypt_ready is that listing, and it is cached for later calls), one credential, no retry. Sets _HELPER_AUTH.
# Auto with both on hand picks the password: a per-estate chrooted login has no key to offer (pin it with helper-auth).
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

# Resolve auth + channel and cache. Returns 0 on success, 1 if no auth works, 2 if unset.
# Idempotent; safe to call at the top of every interface function.
helper_detect() {
  [ -n "$_HELPER_DETECTED" ] && return 0
  [ -n "$HELPER" ] || { _helper_log "HELPER (user@host) not set — cannot reach helper"; return 2; }
  # The message is composed by _helper_log_no_auth (issue #143): it classifies the TCP path
  # FIRST and only reports an auth failure for a conversation that actually happened. NB it
  # never interpolates $HELPER (user@host) — a SECRET (SPEC §6: the helper's coordinates), and
  # run-pipeline's self-log ships these lines off-box (issue #84).
  # _HELPER_DETECT_REFUSED=1 = the last login offered was REFUSED (auth wording, never logged): helper_get maps it to its
  # "refused" rc 2 so a retrying caller stops (#1201). Every other failure stays rc 1.
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
  # Persist the resolved auth for durability (issue #87) when a cache path is set. This is the
  # FIRST-successful-detection capture: even a brand-new estate records the fact here, so the
  # next process / a full rebuild preloads it (via PROVISIONER_HELPER_AUTH) instead of probing
  # 'auto' and firing a doomed pubkey login. Idempotent (writes only on a change) and STRICTLY
  # best-effort — a capture failure must never fail detection. The value is a TYPE ('key'|
  # 'password'), not a secret; the cache PATH is a local fact file, so this line is leak-safe.
  if [ -n "$HELPER_AUTH_CACHE" ]; then
    if [ ! -f "$HELPER_AUTH_CACHE" ] || [ "$(cat "$HELPER_AUTH_CACHE" 2>/dev/null)" != "$_HELPER_AUTH" ]; then
      if ( umask 077; printf '%s\n' "$_HELPER_AUTH" > "$HELPER_AUTH_CACHE" ) 2>/dev/null; then
        _helper_log_quiet "recorded helper auth '${_HELPER_AUTH}' → ${HELPER_AUTH_CACHE}"
      else
        _helper_log_quiet "could not persist helper auth to ${HELPER_AUTH_CACHE} (non-fatal)"
      fi
    fi
  fi
  # CHANNEL probe: with the working auth, an exec `true`. Refusal (proftpd mod_sftp:
  # "exec request failed on channel 0", rc 255) ⇒ SFTP-only.
  if _helper_crypt_alias; then _HELPER_EXEC=0   # #1203: no exec probe; the access path is file transfer only
  elif _HELPER_OP_TIMEOUT="$HELPER_PROBE_TIMEOUT" _helper_ssh_raw true >/dev/null 2>&1; then _HELPER_EXEC=1; else _HELPER_EXEC=0; fi
  _HELPER_DETECTED=1
  # 'HELPER' (not $HELPER) — the user@host is a SECRET (SPEC §6) and this line is captured +
  # shipped by run-pipeline's self-log (issue #84). This message fires on the FIRST helper_detect
  # of essentially every run (state_pull alone triggers it), so it is the highest-value leak site.
  # port= is here for the same reason the failure line carries it (issue #143): the ONE line
  # that says the helper works should also say which port it worked on, so a later failure can
  # be compared against a known-good target instead of re-derived from four scripts.
  _helper_log_quiet "HELPER → port=${HELPER_PORT} auth=${_HELPER_AUTH} channel=$([ "$_HELPER_EXEC" = 1 ] && echo exec || echo sftp-only)"
  return 0
}

# Accessors (for callers/logging/tests) + a cache reset (tests / a changed target).
#
# ONE EXTERNAL CALLER WRITES THESE THREE FIELDS DIRECTLY (issue #157). needle.sh's
# _host_helper_transport_restore assigns _HELPER_DETECTED / _HELPER_AUTH / _HELPER_EXEC to
# values it snapshotted, to put the transport back after a probe it had to make and that
# failed. It cannot use helper_reset_detection for that: a RESET makes the next helper op
# re-probe, and on a password-pinned estate a re-probe under a cleared pin is precisely the
# doomed pubkey login that accrues toward the provider's ban (#87/#90). Restoring the three
# fields is the only way to return to the prior state at ZERO logins.
#
# SO: these three names are part of that contract. Renaming or repurposing them here without
# updating needle.sh will silently break the restore — silently, because the failure is a
# re-probe that still works, just at the cost this library exists to avoid.
helper_auth()    { helper_detect >/dev/null 2>&1; printf '%s' "$_HELPER_AUTH"; }
helper_channel() { helper_detect >/dev/null 2>&1; [ "$_HELPER_EXEC" = 1 ] && printf 'exec' || printf 'sftp-only'; }
helper_reset_detection() { _HELPER_DETECTED=""; _HELPER_AUTH=""; _HELPER_EXEC=""; }

# ── CRYPT MODE: the seedbox behind one rclone `crypt` remote (issues #1074/#1075) ──────
# DORMANT unless a per-estate crypt key exists: no key file ⇒ nothing below is reached and
# the ssh/sftp paths run byte-for-byte as before. Keyed ⇒ every transfer goes through
# `rclone` against ONE remote (crypt over sftp, file NAMES encrypted too), so nothing on the
# seedbox side can be addressed by a raw name any more.
#
# THIRD STATE (#1202): the same rclone path with NO encryption - `/etc/provisioner/helper-access` = rclone, or
# PROVISIONER_HELPER_ACCESS=rclone - makes [prov-crypt] an alias of the sftp remote (plain files, no key, no canary).
# A key, or crypt required, always wins and still refuses without its key.
#
# KEY INPUT. PROVISIONER_HELPER_CRYPT_KEY_FILE (default /etc/provisioner/helper-crypt-key,
# next to helper-pass), 0600: line 1 = the crypt password, line 2 (optional) = the salt.
# Default path absent ⇒ dormant. An EXPLICIT path that is missing/empty is an ERROR, never a
# silent fall-back to plaintext (secrets would land in the clear where encryption was asked).
#
# CONF LIFECYCLE. A 0600 rclone.conf in a fresh 0700 temp dir, made per operation and removed
# the instant it returns (the askpass rule, #104) — no EXIT trap to fight the sourcing
# script's. Passwords/salt are obscured via `rclone obscure -` on STDIN, so no secret is ever
# on argv or in a child's environment. The sftp stanza carries the existing host/port/user,
# key OR password (per the resolved auth), and the #87/#104 cipher/MAC pin.
#
# PATHS. Callers pass login-relative paths; the crypt remote is rooted at the estate folder (#1228), so the folder prefix is stripped here (a path outside it is refused); a leading '/' is dropped and any
# '..' refused. Presence follows the #313 rule: "absent" only when the listing positively says
# so (rclone exit 3 = directory not found), never on a transport error.
_helper_crypt_keyfile() { printf '%s' "${PROVISIONER_HELPER_CRYPT_KEY_FILE:-/etc/provisioner/helper-crypt-key}"; }
_helper_crypt_keyed() {
  [ -n "${PROVISIONER_HELPER_CRYPT_KEY_FILE:-}" ] && return 0
  # PROVISIONER_HELPER_CRYPT=required (set on keyed hosts): a missing key is an error, never plaintext.
  [ "${PROVISIONER_HELPER_CRYPT:-}" = required ] && return 0
  [ -s "$(_helper_crypt_keyfile)" ]
}
# #1202: the access path ON without encryption. Only when no key is declared or present: a keyed or
# crypt=required estate is never downgraded to this, it refuses without its key.
_helper_crypt_alias() {
  _helper_crypt_keyed && return 1
  [ "${PROVISIONER_HELPER_ACCESS:-}" = rclone ] && return 0
  [ "$(head -n 1 "${PROVISIONER_HELPER_ACCESS_FILE:-/etc/provisioner/helper-access}" 2>/dev/null | tr -d '[:space:]')" = rclone ]
}
_helper_crypt_on() {
  _helper_crypt_keyed && return 0
  _helper_crypt_alias
}
# The host key must be VERIFIED as strictly as today's accept-new path: TOFU on first contact,
# then refuse a mismatch. rclone only verifies when given known_hosts_file (and has no
# accept-new), so seed the entry with the same ssh probe, then refuse if it is still absent.
# Hostspec = the ONE shared rule, bootstrap/known_hosts_hostspec.sh (#780), run as `sh`.
_HELPER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
_helper_crypt_khfile() { printf '%s' "${HOME:-/root}/.ssh/known_hosts"; }
# #1227: hook.sh sources this file ALONE, before any checkout, so the sibling script may not exist. Same rule,
# inline; tests/helper_prelib_hostspec.sh holds the two identical over a table of pairs.
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
# #1202: without a key an ENCRYPTED folder lists as encrypted names, and a missing plain name would read as
# "absent". Look at the root once (cached): crypt-shaped names refuse every operation. Nested sessions are
# guarded by setting the flag first; the listing is plain, so it never needs the child key.
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
# rc 0 = usable; else logs why and returns 2 (callers return it as "could not tell").
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
# _helper_crypt_obscure <file> <line> — obscured form of one line of <file>, via stdin.
_helper_crypt_obscure() { sed -n "${2}p" "$1" | tr -d '\r' | rclone obscure - 2>/dev/null; }
# The sftp stanza. A function of its own so tests can swap in rclone's local backend.
# rclone's Go client offers its own host-key order, not OpenSSH's, so a key first recorded by ssh
# (accept-new) can mismatch (#1155): offer exactly the types recorded for this host. None => no line.
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
# The crypt stanza. Held byte-identical to bootstrap/helper-crypt-fetch.sh (the pre-lib copy) by
# tests/helper_crypt_prelib.sh (#1075).
# #1228: the estate's folder under the login ("" = the login root). The crypt remote is rooted THERE, so
# encrypted names never land outside the folder; callers keep passing login-relative paths.
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
# #1202: a root listing (stdin) of an ENCRYPTED folder: a crypt-shaped name (base32hex, 26+ chars: the shortest
# encrypted one) and none of the layout's own plain top-level names (a plain root with a hash-named file is plain).
_helper_crypt_looks_encrypted() {
  local t; t="$(cat)"
  grep -qxE '(scripts|secrets|images|state|restic|version|version-built|downloads)/?' <<<"$t" && return 1
  grep -qE '^[0-9a-v]{26,}/?$' <<<"$t"
}
# #1202: the same remote name over plain files
_helper_crypt_alias_stanza() { local b; b="$(_helper_crypt_base)" || return 1; printf '[prov-crypt]\ntype = alias\nremote = prov-sftp:%s\n' "$b"; }
_CRY_DIR=""
# A fresh 0700 dir under <base> for one operation's conf, after sweeping dead runs' leftovers.
_helper_crypt_conf_dir() {
  local d o
  # Sweep confs a killed run left behind (ours, older than any op can last).
  # A dir whose owner process is still alive is a LIVE long op (copy can run 30min+): never swept.
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
# _helper_crypt_session <rclone args…> → _CRY_RC / _CRY_OUT / _CRY_ERR (streams apart, #897).
_CRY_RC=0; _CRY_OUT=""; _CRY_ERR=""; _CRY_PID=""; _CRY_OLDTRAPS=""; _CRY_SIGRC=""; _CRY_X_KEY=""; _CRY_X_BASE=""
_helper_crypt_untrap() { trap - INT TERM HUP; [ -z "$_CRY_OLDTRAPS" ] || eval "$_CRY_OLDTRAPS"; _CRY_OLDTRAPS=""; }
# A signal mid-op must not leave the conf behind (obscured ≠ encrypted): kill rclone, remove
# the dir, put the caller's traps back and re-raise so THEY run.
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
# A local operand must not parse as a flag or as a remote spec (`prov-sftp:x` would bypass crypt).
_helper_crypt_local() { case "$1" in /*|./*) printf '%s' "$1" ;; *) printf './%s' "$1" ;; esac; }
# _helper_crypt_p <path> — the crypt-remote spelling of a path (empty ⇒ root); 1 = refused.
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

# KEY CANARY (#1075). A wrong key (or a plain, not yet migrated folder) decrypts NOTHING, and rclone
# then lists "empty" or "not found" with rc 0 - which must never read as "absent / first build".
# A marker at the root of the estate folder must decrypt before an absence is trusted. First use of a truly empty
# folder writes it; real decryptable names also prove the key (and heal a lost marker). A populated
# folder with nothing decryptable is UNKNOWN (a wrong key, or an existing plain folder awaiting #1078),
# unless PROVISIONER_HELPER_CRYPT_INIT=1 says this is the deliberate first use (shared-account roots
# are never empty).
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
    # #1228: the crypt root is the estate's folder; one not made yet holds nothing to hide, whatever the key.
    # First use (INIT) writes the marker; a read just trusts the absence.
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
# helper_crypt_marker_init <dir> (#1077) — first use of an estate folder under the CURRENT key: write
# the key marker, but only where that cannot hide old files. The shared-account root is never empty,
# so the root can't tell; the estate's own folder can. rc 0 marker present or written · 1 the folder
# already holds PLAIN files (refused: they would turn invisible beside new encrypted ones) · 2 could not tell.
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
# An absence is trusted only when nothing was skipped in that listing AND the key is proven.
_helper_crypt_absent() {   # rc 1 absent (trusted) · 2 could not tell
  _HELPER_CRYPT_UNNAMEABLE=""; _HELPER_CRYPT_UNNAMEABLE_NAME=""   # no stale cause from an earlier call (#1287)
  local sk=0; _helper_crypt_skipped && sk=1
  _helper_crypt_canary || return 2
  if [ "$sk" = 1 ] && [ "${HELPER_ABSENT_TOLERATE_PLAIN:-}" = 1 ] && [ -n "${1:-}" ]; then
    # #1394: a caller that asks about ONE name (the version pointer) may establish its absence
    # beside plain entries it did not write, IF every skipped name parses and none is the asked
    # name. A plain file literally called <name> keeps the refusal; it is never read as the answer.
    # A line counts as parsed ONLY in the exact form "<name>[/]: Skipping undecryptable <file|dir> name":
    # name non-empty, no further "/" and no space. Anything else (nameless, a path) is unparsable => refuse.
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
    # #1287: say WHY to the caller (a plain file in the encrypted folder), not just in the log.
    _HELPER_CRYPT_UNNAMEABLE=1
    _HELPER_CRYPT_UNNAMEABLE_NAME="$(grep -iE 'undecryptable|not decrypt|illegal base32' <<<"$_CRY_ERR" | head -n 1 | sed -E 's#^([0-9]{4}/[0-9/]+ [0-9:]+ )?[A-Z]+ *: *##; s#: .*##')"
    _helper_log "crypt mode: names that could not be decrypted were skipped, so absence is not established"; return 2
  fi
  return 1
}

# stat one path via its parent's listing. Prints "<size>" (-1 for a dir) on rc 0.
# rc 0 present · 1 absent (established) · 2 could not tell
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

# helper_presence contract: 0 present · 1 absent (established) · 2 could not tell.
_helper_crypt_presence() {
  local v
  _HELPER_CRYPT_UNNAMEABLE=""; _HELPER_CRYPT_UNNAMEABLE_NAME=""   # set by _helper_crypt_absent (#1287)
  _helper_crypt_ready || return 2
  _helper_crypt_stat "$1" >/dev/null; v=$?
  case "$v" in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}
# Same contract as _helper_put_verify: 0 there+same · 1 absent · 3 can't ask · 4 there, wrong.
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
    # rc 2 = the helper REFUSED the login (#1201): a retrying caller (control-init) stops on it.
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

# Names rclone could not decrypt (foreign/stray files) are skipped by rclone with exit 0. A
# listing that silently lacks them is not the whole directory, so say so in the shape
# needle-purge reads as UNREADABLE and return 2 — never a clean or empty verdict.
_helper_crypt_foreign() {
  grep -qiE 'undecryptable|not decrypt|illegal base32' <<<"$_CRY_ERR" || return 0
  printf 'ssh: rclone skipped names it could not decrypt in %s — the listing is incomplete\n' "$1" >&2
  return 2
}
# Plain names (exec `ls -1` shape: no dotfiles, dirs without the slash). A failure prints a
# line needle-purge's classifier reads (#304): "ls: cannot access…No such file" = absent,
# a leading "ssh: " = unreadable (fail-safe — never mistaken for an entry).
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
# `ls -la` shape (mode links owner group size Mon DD HH:MM name) — needle-purge parses this.
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
# The cross-job lock (#79) in crypt mode: the SAME atomic raw mkdir, on the ENCRYPTED path. rclone
# gives the encrypted name of each segment (`cryptdecode --reverse`, from the config's own password
# and salt, so no key on argv); the parent is made through the crypt remote; release and inspection
# then go through the crypt remote, where the lock is an ordinary directory with its real name.
# #1203: the lock on the access path - the SINGLE deliberate exception to "no raw transport". The lock is the estate's
# only mutex (#79) and an atomic exclusive create does not exist through rclone (its mkdir succeeds on an existing
# folder), so this is ONE raw sftp mkdir on the plain path, as keyed mode does, with the login the access path resolved.
# A refusal is rc 2 (not established), logged, never retried; existing = held (1); created = 0.
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
  # Allow-list (#1075): only what rclone's name encoding emits (base32/base64 alphabet), '/' between
  # segments, never a leading '-' or '/', so odd output can never reach `mkdir '-x'`.
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
# Same guards and rc as the raw helper_clear_tree; one rclone call per entry.
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

# ── Interface: transfers (always SFTP — works on exec AND sftp-only helpers) ──────────
# _helper_put_verify <remote> [<local-source>] — helper_put's post-upload check.
#   rc 0 = it is there (and, when <local-source> is given, it is the SAME SIZE as what we sent —
#          and, for a SMALL file, the SAME BYTES too when the readback could be done; issue #434)
#   rc 1 = the helper ANSWERED and the path is not there
#   rc 3 = the question could not be asked — the check session itself failed, or the answer
#          arrived in a shape no size could be read out of
#   rc 4 = it IS there and it is NOT what we sent (size mismatch, not a regular file, or — for a
#          small file — the SAME SIZE but DIFFERENT bytes; issue #434)
#
# helper_exists cannot express rc 3: it returns 0 for any output without a 'not found' marker,
# so a session that died on connect reads there as "it exists". On the verification of an
# upload that is exactly backwards — it would turn a failed put into a reported success, the
# vacuous-check shape this repo keeps finding. helper_exists answers 2 for "could not tell"
# (#1287); needle's state wipe (#131) relies on _helper_gone treating that as NOT confirmed gone.
#
# ── WHY IT COMPARES A SIZE AND NOT ONLY AN EXISTENCE (issue #313) ─────────────────────
# Existence alone is a check that CANNOT SEE the failure it is placed to catch. Every path
# this library writes is written repeatedly across rebuilds, so the target usually ALREADY
# HAS a file on it from an earlier run. An upload that lands nothing new — a truncated
# transfer, a session that wrote somewhere else entirely (genesis.sh with the helper layout
# unresolved, which is how this was found live on 2026-08-26), a server that accepted the
# open and dropped the body — then verifies against that OLD copy and reports success. The
# only cheap question whose answer differs between "the bytes we just sent" and "whatever was
# lying there" is the size, so that is the question now asked.
#
# SIZE, AND FOR A SMALL FILE ALSO CONTENT (issue #434) — but NEVER a server-side checksum. The
# sftp-only transport (the proftpd seedbox — the live helper) offers no way to run sha256sum at
# all, so a checksum computed on the FAR end would exist on one channel and not the other, i.e.
# the strong check would be missing on precisely the estate that has only the weak transport;
# and on the exec channel it would mean hashing multi-GB seeds on a seedbox on every put. So the
# content check is done the one way BOTH channels support: for a file under HELPER_PUT_VERIFY_MAX
# we DOWNLOAD the remote copy and compare bytes LOCALLY. Size alone catches truncation, the empty
# write and a stale copy of a DIFFERENT length; it is blind to the failure this check exists for —
# "this put never overwrote an OLDER copy" — whenever old and new are the SAME LENGTH, which the
# estate's fixed-width receipts routinely are (version-built, version, the tofu state's small
# siblings). The content check closes exactly that gap, and only for the small files where it is
# cheap: a large upload keeps the size-only check, so no seed is ever round-tripped to verify it.
# A readback that CANNOT be done (a transient get failure) does not downgrade a size match — the
# rc 0 contract is "there and same size", which the ls already established; it just warns that the
# stronger check was skipped, never worse than the #313 behaviour it builds on.
#
# _helper_verify_small_content <remote> <local-src> — the CONTENT half (issue #434). The SIZE
# already matched; download the remote copy into a throwaway dir and compare bytes locally.
#   rc 0 = identical · rc 4 = present but DIFFERENT bytes · rc 3 = could not fetch it to compare
# The destination must NOT pre-exist (helper_get reads `[ -f dst ]` as part of success, so a
# path mktemp already created would make a FAILED download look like a 0-byte match — the same
# trap _state_lock_read documents), so it lands at a name INSIDE a fresh mktemp -d.
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

# _helper_put_verify_matched <remote> <local-src> <size> — the SIZE matched. For a SMALL file
# ALSO compare content (issue #434); a large file, or one with no readable local source, keeps
# the size-only verdict (#313). Both size-match sites in _helper_put_verify route through this,
# so the content gate lives in ONE place (and the mutation test can neuter it in ONE place).
_helper_put_verify_matched() {
  local path="$1" src="$2" size="$3" rc
  # No usable local source ⇒ size/existence is all we have; keep the #313 behaviour verbatim.
  [ -n "$src" ] && [ -f "$src" ] || return 0
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -lt "$HELPER_PUT_VERIFY_MAX" ] || return 0    # large upload: size-only (no seed round-trip)
  _helper_verify_small_content "$path" "$src"; rc=$?
  case "$rc" in
    0) return 0 ;;
    4) _helper_log "verify: '${path}' is the right SIZE (${size} bytes) on the helper but the BYTES DIFFER from what we sent — either a same-length corruption, or this upload never overwrote an OLDER copy sitting at that path"; return 4 ;;
    *) # Could not fetch it back to compare. The size DID match, so the rc 0 contract ("there and
       # same size") still holds; degrade to it rather than fail a probably-good upload, but say so.
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
    # ONE command, THREE answers, and it exits 0 for all three on purpose: that makes a
    # non-zero rc here unambiguously the transport/channel and never the file. The bare
    # `test -e` form above cannot do that — its rc 1 is both "absent" and "the remote shell
    # disagreed with us", which is the ambiguity rc 3 exists to keep out of the caller.
    # `wc -c <file` and not `stat`: POSIX, and identical on the BSD-ish shells a helper may run.
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
  # THE VERDICT IS THE EXIT STATUS FIRST, and the far end's REPLIES after it (issue #897).
  # The listing itself ($_SFTP_OUT) is data and is parsed for a SIZE further down; it is
  # never asked whether the transfer worked, because it is full of names the far end chose.
  local replies
  _helper_sftp_session "$(printf 'ls -la %s\n' "$(_sftpq "$path")")"
  rc=$_SFTP_RC; out="$_SFTP_OUT"; replies="$_SFTP_ERR"
  [ "$rc" -ne 0 ] && return 3
  grep -qiE "$_HELPER_XPORT_RE" <<<"$replies" && return 3
  # STAYS ON THE WORDS, deliberately (#958): here a refusal read as an absence is FAIL-SAFE
  # — rc 1 means the upload did not land, so helper_put retries and then fails loudly.
  grep -qiE 'not found|no such file|can.?t ls' <<<"$replies" && return 1
  # ANY OTHER COMPLAINT IS "COULD NOT ASK", NEVER "IT IS THERE". This is the half of #897
  # with no backstop behind it: before, an `ls` refused in words this file did not list fell
  # straight through to `return 0` below and an upload that never landed was verified as
  # good. rc 3 makes helper_put retry and then fail loudly, which is the right end for a
  # question that was never answered.
  grep -qiE "$_HELPER_ERR_RE" <<<"$replies" && return 3
  [ -z "$want" ] && return 0                        # existence-only (a directory, or no source)
  # The size comes out of the `ls -la` we already ran — no second session, and no extra
  # command for a password-only helper to charge us a login for. The line is SAFE to parse
  # because the sftp CLIENT formats it, not the server: for a path that globs to a file,
  # OpenSSH's do_globbed_ls builds the line itself with ls_file() from the SFTP attributes —
  #   -rw-------  1 owner group  <size> Mon DD HH:MM  <name>
  # — so field 5 is the size whatever the server is (proftpd mod_sftp included, which supplies
  # a longname only for DIRECTORY listings, a shape this branch never asks for).
  got="$(printf '%s\n' "$out" | awk '
      $1 ~ /^[-dlbcps]/ && length($1) >= 10 && $5 ~ /^[0-9]+$/ { s = $5 }
      END { if (s != "") print s }')"
  if [ -z "$got" ]; then
    # NOT a mismatch — an unreadable answer. Say which it is; the caller retries and then
    # fails loudly, which is the right end for a question that never got answered.
    # THROUGH _helper_sftp_said, like every other transcript (#897 review, F4). This line
    # used to dump $_SFTP_OUT raw — which BEGINS `Connected to <host>.` — with neither the
    # chatter filter nor the scrub, which made the claim above ("closed here") false while
    # it stood. The listing itself is what this message is about and the chatter filter
    # keeps it; only the banner and our own echo go.
    _helper_log "verify: could not read a size for '${path}' out of the helper's listing: $(_helper_sftp_said)"
    return 3
  fi
  if [ "$got" = "$want" ]; then _helper_put_verify_matched "$path" "$src" "$want"; return $?; fi
  _helper_log "verify: '${path}' is ${got} bytes on the helper, but the file we sent is ${want} bytes"
  return 4
}

# helper_put <local> <remote>  — 0 on success, where SUCCESS means the remote path holds a file
# of the same size as the one we sent, not merely that something is there (issue #313).
#
# ── WHY THIS RETRIES, AND WHY IT STOPPED CLAIMING "not present after upload" (issue #159) ──
# On the 2026-08-10 00:55Z lap this printed, for a 788-byte steps feed, into a directory the
# same run had already written to successfully minutes earlier:
#     [helper-lib] put: …/state/logs/20260810T005545Z-steps.log not present after upload
# The post-upload verification was RIGHT to fire — the file genuinely was not there — but the
# sentence asserted a state of the world ("the upload happened and the file is absent") that the
# code had not established, because of what it threw away: the sftp run's EXIT STATUS. The
# password path wraps sftp in `timeout -k 5 $_HELPER_OP_TIMEOUT`, the caller of this particular
# put (run-pipeline's ship_steps_log) pins that cap to 30s for a small file, and a `timeout`
# kill exits 124/137 having printed NO error marker at all. Output-only classification cannot
# tell that from a clean session, so a killed upload was reported as a mystery.
#
# So: rc is read, and the three outcomes are now distinguished.
#   • the helper ANSWERED and refused (an _HELPER_ERR_RE marker) ⇒ deterministic, ONE attempt,
#     no retry. Retrying a refusal is how a password-only seedbox earns a login ban (#87/#90).
#   • the SESSION did not complete (non-zero rc, or an _HELPER_XPORT_RE marker) ⇒ nothing is
#     established about the remote path; retryable.
#   • the session looked clean but the file is NOT there ⇒ retryable, and this is the case the
#     live failure was. A small file that vanishes on a link that worked moments before is the
#     signature of a transport hiccup, not of a decision the helper made.
# Attempts are bounded on BOTH axes — a count AND a wall-clock budget — because this runs on a
# best-effort path (the steps feed fires at every milestone) and an unbounded retry against a
# wedged helper would turn a warning into the wedge #58 forbids.
#
#   PROVISIONER_HELPER_PUT_ATTEMPTS   how many tries a retryable failure gets   (default 3)
#   PROVISIONER_HELPER_PUT_BUDGET     total seconds across all of them
#                                     (default 3 × _HELPER_OP_TIMEOUT, else 180)
#   PROVISIONER_HELPER_PUT_BACKOFF    seconds before the 2nd try, doubling      (default 2)
# NB helper_get deliberately does NOT retry: control-boot.sh reads a failed get as "the optional
# file is absent" (see its sequential-pull comment), so retries there would triple the cost of
# the normal absent case for no gain.
helper_put() {
  helper_detect || return 2
  _helper_crypt_on && { _helper_crypt_put "$@"; return $?; }   # crypt mode (#1075)
  local src="$1" dst="$2" replies rc why n=1 back="${PROVISIONER_HELPER_PUT_BACKOFF:-2}"
  [ -f "$src" ] || { _helper_log "put: local source missing: $src"; return 2; }
  local tries="${PROVISIONER_HELPER_PUT_ATTEMPTS:-3}" budget="${PROVISIONER_HELPER_PUT_BUDGET:-}"
  if [ -z "$budget" ]; then
    if [ -n "${_HELPER_OP_TIMEOUT:-}" ]; then budget=$(( _HELPER_OP_TIMEOUT * 3 )); else budget=180; fi
  fi
  # READ ONLY — never assign to SECONDS, it is the sourcing script's own lap timer.
  local t0=$SECONDS v
  while :; do
    # THE UPLOAD IS JUDGED ON ITS EXIT STATUS AND THE FAR END'S REPLIES (issue #897). The
    # session's own output is NOT consulted: it is where `sftp> put "…"` and `Uploading
    # <local> to <remote>` live, i.e. two full copies of paths this side chose, and reading
    # a verdict off those is how a file named after failures failed its own transfer.
    _helper_sftp_session "$(printf 'put %s %s\n' "$(_sftpq "$src")" "$(_sftpq "$dst")")"
    rc=$_SFTP_RC; replies="$_SFTP_ERR"
    # _HELPER_AUTH_RE MUST be tested before _HELPER_XPORT_RE — see the ordering comment above
    # _HELPER_XPORT_RE's definition for why. _HELPER_ERR_RE (the broad refusal set) is tested
    # LAST, after XPORT_RE, because ERR_RE also matches genuine transport text and would
    # misclassify a real transport fault as a permanent refusal if tested earlier.
    # HERE-STRINGS, not `printf … | grep -q`: that pipeline returns 141 under pipefail when
    # grep exits on the first match, and 141 reads here as "no marker" — a verdict failing
    # toward success (#897).
    if grep -qiE "$_HELPER_AUTH_RE" <<<"$replies"; then
      # A REJECTED CREDENTIAL. Deterministic: report it once, do not retry — a repeated
      # refusal buys nothing and costs failed logins (#87/#90).
      _helper_log "put failed ($src → $dst): $(_helper_sftp_said)"; return 1
    elif grep -qiE "$_HELPER_XPORT_RE" <<<"$replies"; then
      why="the sftp SESSION did not complete (transport fault) — whether '${dst}' exists on the helper is NOT established: $(_helper_sftp_said)"
    elif grep -qiE "$_HELPER_ERR_RE" <<<"$replies"; then
      # The helper ANSWERED and refused, for a reason other than auth (path missing, etc).
      # Deterministic: report it once, do not retry.
      _helper_log "put failed ($src → $dst): $(_helper_sftp_said)"; return 1
    else
      case "$rc" in
        # Nothing was established about the remote path, so do not spend a second session
        # asking: go straight to the retry. The cap is NAMED because on the live failure it
        # was the invisible actor — 30s, set by the caller, for a 788-byte file.
        124|137) why="the upload was KILLED by the per-op cap (_HELPER_OP_TIMEOUT=${_HELPER_OP_TIMEOUT:-unset}s, rc ${rc}) before it finished — nothing about '${dst}' on the helper is established; raise that cap if this file is not small" ;;
        255)     why="the sftp session failed at the transport/auth layer (rc 255) — nothing about '${dst}' on the helper is established" ;;
        *)
          # rc 0 (the live case) or an odd exit: ASK. _helper_put_verify, unlike helper_exists,
          # separates "the helper says no" from "the check itself did not complete", so an
          # unanswerable question can never be recorded as either a success or an absence.
          # The SOURCE is handed over too (issue #313) so the answer is about THESE bytes and
          # not merely about the path — a path that, on a rebuilt estate, is nearly always
          # already occupied by an older copy of the same file.
          _helper_put_verify "$dst" "$src"; v=$?
          case "$v" in
            0) [ "$n" -gt 1 ] && _helper_log "put SUCCEEDED on attempt ${n} ($src → $dst)"
               return 0 ;;
            1) if [ "$rc" -eq 0 ]; then
                 why="the upload printed no error and exited 0, but '${dst}' is NOT there afterwards"
               else
                 why="the sftp session exited ${rc} and '${dst}' is not there afterwards"
               fi ;;
            # Retryable, like the absence above: a truncated transfer is exactly what a second
            # attempt fixes. What it must never be is SILENT — before #313 this case was the
            # one the check could not see at all, and it reported success on the old copy.
            4) why="'${dst}' IS on the helper but it is NOT the file we just sent (size mismatch, reported above) — either the transfer was truncated, or this upload never overwrote an OLDER copy sitting at that path" ;;
            *) why="the upload session exited ${rc}, and the VERIFICATION session did not complete either — whether '${dst}' landed is NOT established" ;;
          esac ;;
      esac
    fi
    # ── retryable ──
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

# helper_get <remote> <local>  — 0 on success (verified: local file exists afterwards).
#
# ── THE FETCH THAT CONDEMNED ITS OWN FILE (issue #897) ────────────────────────────────
# This is the function the issue was filed on. It used to grep the MERGED transcript, which
# begins `sftp> get "state/logs/…-failures.log" "…"` and continues `Fetching <remote> to
# <local>` — our own path, twice — against a vocabulary containing `failure`. So the one
# artifact a build ships to say why it died was the one file this could not fetch, on an
# estate where everything else fetched clean. Exactly #889, one library over, and this one
# runs on the box on every lap.
# It also never read the exit status at all: a session that died at the transport layer was
# judged solely on whether some words appeared, with `[ -f dst ]` as the only real backstop —
# and a half-written file passes `[ -f dst ]`.
# Now: the exit status, then the FAR END's replies, then the destination check. All three.
helper_get() {
  # Failure is 1 (retryable) unless detection saw the login REFUSED (_HELPER_DETECT_REFUSED): then 2, so a retrying
  # caller (control-init) stops instead of re-dialling a login that locks (#1201).
  if ! helper_detect; then
    [ "${_HELPER_DETECT_REFUSED:-0}" = 1 ] && { _helper_log "get ($1): the helper REFUSED the login - not retried"; return 2; }
    return 1
  fi
  _helper_crypt_on && { _helper_crypt_get "$@"; return $?; }   # crypt mode (#1075)
  local src="$1" dst="$2" rc replies
  _helper_sftp_session "$(printf 'get %s %s\n' "$(_sftpq "$src")" "$(_sftpq "$dst")")"
  rc=$_SFTP_RC; replies="$_SFTP_ERR"
  # AUTH first (the ordering trap above). rc 2 = a REFUSED login, which a retrying caller must not re-dial (#1201).
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

# ── Interface: metadata ops (exec fast-path when available, else SFTP) ────────────────

# A BELT on the walk, not its floor (issue #958). The floor is the estate's own directory.
HELPER_PRESENCE_WALK_MAX=4

# THE ESTATE'S OWN DIRECTORY — the floor of every walk. Resolved at CALL time so sourcing
# order cannot decide it, and `-` not `:-` throughout: an explicit empty REMOTE_DIR means
# "the chroot root, I mean it" and must not fall through to the next rung.
_helper_presence_base() {
  printf '%s' "${HELPER_PRESENCE_BASE-${REMOTE_DIR-${PROVISIONER_REMOTE_DIR-}}}"
}

# _helper_under <candidate> <base> — is it the estate's own directory, or inside it?
_helper_under() {
  if [ -z "$2" ]; then
    case "$1" in /*) return 1 ;; *) return 0 ;; esac   # no layout ⇒ the login dir is ours
  fi
  case "$1" in "$2"|"$2"/*) return 0 ;; *) return 1 ;; esac
}

# _helper_presence_dirs <remote> [base] — the ancestors to list, nearest first, NEVER above
# the estate's own directory. The walk climbs because the answer comes from a listing that
# SUCCEEDED; it stops at the base because the `play@` account is SHARED and not chrooted
# (#75), so a walk bounded by a level COUNT lists the operator's tree and every sibling
# estate's on every ordinary lap (#958).
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

# _helper_said_about <path> <stderr> — did the far end complain about EXACTLY that path?
# Attribution is by the path the client QUOTES back and by nothing else: no vocabulary
# HERE, so there is nothing HERE to widen along (#958). The claim stops at attribution —
# see the three greps in _helper_presence_sftp for the shape that quotes no path. MEASURED: the client absolutises a relative
# argument before quoting it (`Can't ls: "<pwd>/state/x" not found`) and `readdir` adds a
# trailing slash, so all four shapes are matched — and always ON A COMPONENT BOUNDARY, or
# `/…/nope.tfstate` would answer for the probe of `state`.
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

# helper_presence <remote> — rc 0 PRESENT · 1 ABSENT, ESTABLISHED · 2 nothing established.
#
# WHY THE PROBE IS A LISTING OF THE PARENT (#958). MEASURED against OpenSSH 9.2: an `ls` of
# a FILE prints the byte-identical `Can't ls: "<path>" not found` whether the far end
# answered NO_SUCH_FILE, PERMISSION_DENIED or FAILURE — the client stats, the stat fails,
# the glob finds nothing, and the status code is DISCARDED. So a refusal cannot be told
# from an absence in that sentence, and reading one as the other applies an empty state
# over a live fleet. A directory listing that CAME BACK is evidence; that sentence is not.
helper_presence() {
  helper_detect || return 2
  _helper_crypt_on && { _helper_crypt_presence "$@"; return $?; }   # crypt mode (#1075)
  local path="$1"
  if [ "$_HELPER_EXEC" = 1 ]; then _helper_presence_exec "$path"; return $?; fi
  _helper_presence_sftp "$path"
}

# The exec channel's own three answers, in ONE remote command: `test -e` is false both for
# an absent path and for one inside a directory that would not let us look, so the far side
# walks up itself and only says ABSENT under a directory it could actually read.
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
    # `-1a`, NEVER `-1`: the CLIENT filters dot-names out of an ls without -a, so a
    # REFUSED `.lock` or `.tmp` sidecar was missing from its parent's listing and read as
    # an ESTABLISHED absence — #958's own bug, inside #958's own fix.
    cmds="${cmds}ls -1a $(_sftpq "$d")
"
  done <<<"$dirs"
  # ONE SESSION, therefore one login — the unit of cost against this seedbox (#87/#90).
  _helper_sftp_session "$cmds"
  rc=$_SFTP_RC; out="$_SFTP_OUT"; err="$_SFTP_ERR"
  [ "$rc" -ne 0 ] && return 2
  # WHAT IS LEFT OVER after every line about a path of ours is set aside is the only text
  # any vocabulary sees (#897/#936) — and it is handed over UNEDITED. An earlier draft
  # deleted every probed path from it first; under the per-estate chroot `access` IS a
  # probed path, so `access denied` became ` denied` and a real auth refusal classified as
  # nothing at all (#958).
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
  # THESE THREE ARE LOAD-BEARING, NOT A BACKSTOP. One real refusal shape carries no path
  # at all — `Couldn't read directory: Permission denied`, MEASURED, a readdir refused
  # after the opendir succeeded — so nothing can attribute it, and without this the parent
  # reads as EMPTY and the leaf as an established absence (#958).
  grep -qiE "$_HELPER_AUTH_RE" <<<"$residue" && return 2
  grep -qiE "$_HELPER_XPORT_RE" <<<"$residue" && return 2
  grep -qiE "$_HELPER_ERR_RE" <<<"$residue" && return 2
  # The leaf listed without a word against it: it is there.
  _helper_said_about "$path" "$err" || return 0
  # Otherwise the DEEPEST listing that came back settles it — it either holds the next
  # component of our path or positively does not. `ls -1a <dir>` prints each entry as
  # `<dir as we spelled it>/<name>` (measured), so entries are read off our own spelling.
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
    # Not there ⇒ the branch our path is on stops here, so nothing below it can be there.
    # There, but this is not the immediate parent ⇒ the branch continues into a directory
    # we could not read, which says nothing about the leaf.
    [ "$found" = 0 ] && return 1
    [ "$depth" = 0 ] && return 0
    return 2
  done <<<"$dirs"
  return 2
}

# helper_exists <remote>  — rc 0 it exists, 1 it is ESTABLISHED absent, 2 could not tell
# (no config, or the presence probe established nothing - e.g. a plain file in a crypt folder).
#
# #1287: 2 used to be folded into 0 ("assume there"), which sent a caller down the "it is
# there" road on a question nobody answered. Every caller now handles 2 itself; an `if
# helper_exists` reads 2 as "no", so a caller that needs the fail-safe says so explicitly.
helper_exists() {
  helper_detect || return 2
  local v
  helper_presence "$1"; v=$?
  case "$v" in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

# _helper_gone <path> <verb>  — confirm a delete: rc 0 gone, 1 still there, 2 cannot tell.
# "Cannot tell" is a failure, never a success (#1287; needle's wipe, #131, relies on it).
_helper_gone() {
  local v
  helper_exists "$1"; v=$?
  case "$v" in
    1) return 0 ;;
    0) _helper_log "$2: $1 still present"; return 1 ;;
    *) _helper_log "$2: could not confirm $1 is gone (presence not established)"; return 1 ;;
  esac
}

# helper_mkdir_p <remote>  — create dir + parents, idempotent. sftp has no `mkdir -p`, so
# we mkdir each path prefix (an existing component just errors 'Failure', ignored) and
# verify the leaf. Relative paths (the boot chain's helper layout is login-home-relative)
# and absolute paths both handled.
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
  # #1287: one retry on "cannot tell" - a blip right after a good mkdir must not abort a boot step.
  helper_exists "$dir"; local _mk=$?
  if [ "$_mk" = 2 ]; then sleep "${PROVISIONER_HELPER_MKDIR_RETRY_PAUSE:-1}"; helper_exists "$dir"; _mk=$?; fi
  return "$_mk"
}

# helper_mkdir_exclusive <remote>  — create ONE directory and report WHO created it.
#   rc 0 = THIS call created it (the caller now owns it)
#   rc 1 = it was already there (somebody else owns it)
#   rc 2 = the question could not be answered — nothing is established, own nothing
#
# ── WHY THIS EXISTS AND WHY IT IS A DIRECTORY (issue #79) ─────────────────────────────
# This is the repo's only MUTUAL-EXCLUSION primitive: run-pipeline's cross-job state lock
# (state_lock_acquire) is built on it and on nothing else. Mutual exclusion needs exactly one
# thing from the transport — a create that FAILS when the target already exists, atomically,
# with the loser able to tell it lost. Nothing else in this file supplies that:
#
#   • helper_mkdir_p is idempotent BY DESIGN — it ignores the per-component error and then
#     asks helper_exists, so "I made it" and "it was already yours" both come back 0. That is
#     right for a layout directory and useless for a lock.
#   • helper_rename LOOKS like the classic answer (create-only rename is how POSIX locks are
#     built) but is NOT usable here, in both channels: its exec branch is `mv -f`, which
#     overwrites, and its SFTP branch REMOVES the target and retries on refusal — i.e. it is
#     specified to clobber precisely the file whose existence would have meant "held".
#   • plain `rename` over SFTP cannot be trusted either: OpenSSH's sftp client prefers the
#     posix-rename@openssh.com extension (which overwrites) when the server offers it, and a
#     server that maps the legacy SSH2_FXP_RENAME straight onto rename(2) — proftpd mod_sftp
#     does — overwrites too, silently. A "lock" that two jobs can both take is worse than no
#     lock: it converts a visible collision into a corrupted state file.
#
# mkdir(2) is the one operation that is EEXIST-atomic on every filesystem, is exposed
# identically by SSH_FXP_MKDIR and by a remote `mkdir`, and is implemented by every SFTP
# server we could plausibly meet. So the lock is a DIRECTORY, and the metadata about who holds
# it is an ordinary file the winner writes INSIDE it afterwards. The window between the two is
# harmless by construction: the directory is the mutex, the file is only the receipt.
#
# rc 2 IS NOT rc 1. A transport fault, a killed session or a rejected credential establishes
# NOTHING about the remote path, and reading that as "held" would wedge an estate on a network
# blip while reading it as "free" would hand the lock to a second concurrent apply. Both are
# wrong, so the third answer is spelled out and the caller decides. That is also why the
# confirmation uses _helper_put_verify and not helper_exists: helper_exists returns 0 for any
# output without a not-found marker (fail-SAFE for needle's wipe, fail-OPEN for us), which
# would turn an unanswerable question into a claim of ownership — the vacuous-check shape this
# repo keeps finding. The verify helper is the one that separates "absent" from "cannot ask".
helper_mkdir_exclusive() {
  helper_detect || return 2
  _helper_crypt_on && { _helper_crypt_mkdir_exclusive "$@"; return $?; }   # crypt mode (#1075)
  _helper_mkdir_exclusive_raw "$1"
}
# The raw atomic mkdir (sftp or exec), on a path as the seedbox spells it. Crypt mode calls it with
# the ENCRYPTED name of the lock (#1075), so atomicity is unchanged and no plain name appears.
_helper_mkdir_exclusive_raw() {
  local dir="$1" out rc v
  if [ "$_HELPER_EXEC" = 1 ]; then
    # NOT `mkdir -p`: -p makes an existing directory a SUCCESS, which is exactly the answer
    # this function exists to distinguish. Bare mkdir returns nonzero on EEXIST.
    _helper_ssh_raw "mkdir $(_shq "$dir")" >/dev/null 2>&1; rc=$?
    case "$rc" in
      0)   return 0 ;;
      255) return 2 ;;                       # ssh transport/channel failure, not a remote rc
      *)   # The remote mkdir refused. EEXIST is the expected reason, but a missing parent or a
           # read-only tree lands here too and must NOT be reported as "held".
           _helper_put_verify "$dir"; v=$?
           case "$v" in 0) return 1 ;; *) return 2 ;; esac ;;
    esac
  fi
  # Replies only, never the echo (issue #897): `sftp> mkdir "state/locks/…"` carries the
  # caller's own path, so a LOCK whose name contained one of these words could never be
  # taken — every attempt read as "the question could not be answered" and the estate would
  # wedge on a directory name.
  _helper_sftp_session "$(printf 'mkdir %s\n' "$(_sftpq "$dir")")"
  rc=$_SFTP_RC; out="$_SFTP_ERR"
  # _HELPER_AUTH_RE BEFORE _HELPER_XPORT_RE before _HELPER_ERR_RE — the same ordering trap
  # helper_put documents at length. Here all three land on rc 2 anyway, but the order is kept
  # so a future edit that wants to distinguish them inherits the correct precedence.
  if grep -qiE "$_HELPER_AUTH_RE" <<<"$out"; then return 2; fi
  if grep -qiE "$_HELPER_XPORT_RE" <<<"$out"; then return 2; fi
  case "$rc" in 124|137|255) return 2 ;; esac  # killed by _HELPER_OP_TIMEOUT / session failure
  if grep -qiE "$_HELPER_ERR_RE" <<<"$out"; then
    # The helper ANSWERED and refused. sftp says only "Couldn't create directory: Failure" for
    # every cause, so ASK what is actually there rather than assume EEXIST.
    _helper_put_verify "$dir"; v=$?
    case "$v" in 0) return 1 ;; *) return 2 ;; esac
  fi
  # A clean session with no refusal ⇒ we created it. Confirm it, because "sftp exited 0" is not
  # evidence on this transport (it exits 0 even when a command failed — see the invariant at the
  # top of this file), and an unconfirmable creation must never be reported as ownership.
  _helper_put_verify "$dir"; v=$?
  case "$v" in 0) return 0 ;; *) return 2 ;; esac
}

# helper_copy <src> <dst> — SERVER-SIDE copy of a large file, no bytes through this host
# (issue #1070). rc 0 copied · 3 no exec channel (SFTP has no copy; caller warns) · else failed.
# Goes to <dst>.part then renamed, so a killed copy never leaves a truncated <dst>. A real
# copy, not a link: a later re-bake writes in place and must not clobber the other estate's.
helper_copy() {
  helper_detect || return 2
  _helper_crypt_on && { _helper_crypt_copy "$@"; return $?; }   # crypt mode (#1075)
  local a="$1" b="$2"
  [ "$_HELPER_EXEC" = 1 ] || return 3
  _HELPER_OP_TIMEOUT="${PROVISIONER_HELPER_COPY_TIMEOUT:-1800}" \
    _helper_ssh_raw "cp -- $(_shq "$a") $(_shq "${b}.part") && mv -f $(_shq "${b}.part") $(_shq "$b") || { rm -f $(_shq "${b}.part"); false; }" >/dev/null 2>&1
}

# helper_copy_recrypt <src> <dst> <child key file> <child folder> — copy ONE file THROUGH this box into an estate
# with a DIFFERENT key (#1077): read <src> with this box's own key (plain when it has none), write
# <dst> with the child's. A seedbox-side copy would hand the child bytes it cannot read. One rclone
# `copyto` between two crypt remotes, streamed (no plaintext file); the conf holds BOTH keys, so it
# lives only on tmpfs (0600 in a 0700 dir) and is removed when rclone returns, killed or failed.
# rc 0 copied · 2 refused/could not start · else failed. The caller picks the plain helper_copy
# when neither side has a key.
helper_copy_recrypt() {
  helper_detect || return 2
  local a b
  # #1228: <child folder> (arg 4, "" = the child's login root) roots the child's remote; <dst> is spelled
  # login-relative like <src> and is refused outside it. A keyless parent reads the plain path from the login root.
  [ $# -ge 4 ] || return 2
  if _helper_crypt_on; then a="$(_helper_crypt_p "$1")" || return 2
  else a="$(HELPER_PRESENCE_BASE="" _helper_crypt_p "$1")" || return 2; a="prov-sftp:${a#prov-crypt:}"; fi
  b="$(HELPER_PRESENCE_BASE="$4" _helper_crypt_p "$2")" || return 2
  _CRY_X_KEY="$3"; _CRY_X_BASE="$4"
  # --disable copy: never the backend's own copy, which would move the OLD key's bytes
  _HELPER_OP_TIMEOUT="${PROVISIONER_HELPER_COPY_TIMEOUT:-1800}" \
    _helper_crypt_session copyto --disable copy -- "$a" "prov-crypt-child:${b#prov-crypt:}"
  _CRY_X_KEY=""; _CRY_X_BASE=""
  [ "$_CRY_RC" -eq 0 ]
}
# A tmpfs dir for a conf that carries two keys; none usable ⇒ refuse (never fall back to disk).
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

# helper_rename <old> <new>  — atomic where the transport allows. sftp `rename` may refuse
# an existing target (SSH2 rename is create-only; the posix-rename extension overwrites but
# isn't universal), so on failure we remove the target and retry. Callers needing a no-gap
# swap should compose explicitly (see run-pipeline state_push).
helper_rename() {
  helper_detect || return 2
  _helper_crypt_on && { _helper_crypt_rename "$@"; return $?; }   # crypt mode (#1075)
  local a="$1" b="$2" replies rc refused established
  if [ "$_HELPER_EXEC" = 1 ]; then
    _helper_ssh_raw "mv -f $(_shq "$a") $(_shq "$b")" >/dev/null 2>&1; return $?
  fi
  # Exit status AND the far end's replies (issue #897). This one had teeth: the echoed line
  # carries BOTH paths, so a rename of anything named after failures read as refused — and
  # the refusal path below DELETES THE TARGET and retries. A false verdict was costing a file.
  _helper_sftp_session "$(printf 'rename %s %s\n' "$(_sftpq "$a")" "$(_sftpq "$b")")"
  rc=$_SFTP_RC; replies="$_SFTP_ERR"
  refused=0; grep -qiE "$_HELPER_ERR_RE" <<<"$replies" && refused=1
  [ "$rc" -eq 0 ] && [ "$refused" -eq 0 ] && return 0          # it went

  # ── CLASSIFY BEFORE DESTROYING (issue #897 review) ──────────────────────────────────
  # THE RULE, which this file states at helper_put and then broke here: a session that did
  # not COMPLETE establishes nothing about the remote path. Removing $b on a non-zero rc
  # therefore deletes a file on the strength of a question that was never answered — and the
  # worst case is not hypothetical in shape: _HELPER_OP_TIMEOUT kills the session (rc 124)
  # AFTER the server has already performed the rename, the target is then removed, the retry
  # fails because the source is gone, and BOTH copies are lost. An auth rejection (rc 255)
  # and a transport fault are the same shape with a different cause.
  #
  # So the ONLY thing that may drive remove-and-retry is the helper ANSWERING and REFUSING —
  # which is the case this retry was written for in the first place: SSH2 rename is
  # create-only, so "the target is in the way" is a refusal, not a broken session.
  established=1
  grep -qiE "$_HELPER_AUTH_RE" <<<"$replies" && established=0
  grep -qiE "$_HELPER_XPORT_RE" <<<"$replies" && established=0
  case "$rc" in 124|137|255) established=0 ;; esac
  [ "$refused" -eq 1 ] || established=0        # no refusal to act on ⇒ nothing to clear
  if [ "$established" -eq 0 ]; then
    _helper_log "rename ($a → $b) did not complete and NOTHING was removed — whether '${b}' exists on the helper is NOT established: $(_helper_sftp_said)"
    return 1
  fi

  # The helper answered and refused. NOW removing the target is a correct move.
  helper_remove "$b" >/dev/null 2>&1
  _helper_sftp_session "$(printf 'rename %s %s\n' "$(_sftpq "$a")" "$(_sftpq "$b")")"
  rc=$_SFTP_RC; replies="$_SFTP_ERR"
  # The rc is consulted here too, but nothing destructive follows it — a session that did not
  # complete cannot be reported as a rename that happened, so it is a failure either way.
  if [ "$rc" -ne 0 ] || grep -qiE "$_HELPER_ERR_RE" <<<"$replies"; then
    _helper_log "rename failed ($a → $b): $(_helper_sftp_said)"; return 1
  fi
  return 0
}

# helper_remove <remote>  — delete a file, idempotent (absent target ⇒ success). Verified.
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

# helper_rmdir <remote>  — remove an EMPTY directory, idempotent (absent target ⇒ success).
# WHY IT EXISTS: SFTP has no recursive delete and proftpd mod_sftp offers none either, so the
# only way to take a tree off a helper is depth-first — `rm` every file, then `rmdir` the
# directory. That asymmetry (`rm` refuses a directory, `rmdir` refuses a non-empty one) is
# also a safety feature: a caller that mis-walks a tree gets a refusal, not a silent wipe.
# The rc of the remote command is NEVER trusted on either channel — the result is confirmed
# with helper_exists, because needle's state wipe (issue #131) must not treat an unasked
# question as a reassuring answer. (helper_remove's exec branch does trust `rm -f`'s rc; this
# one deliberately does not.) `--` on the exec branch so a path could never parse as a flag.
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

# helper_clear_tree <nfiles> <file> ... <dir> ...  — remove the named FILES, then rmdir the
# named DIRECTORIES, in ONE session — i.e. ONE login, whatever the counts.
#   <nfiles>  how many of the paths that follow are FILES. Every path AFTER those is a
#             DIRECTORY, and the directories are rmdir'd IN THE ORDER GIVEN, so the caller
#             lists them DEEPEST FIRST: SFTP has no recursive delete, `rmdir` refuses a
#             non-empty directory, and a parent can therefore only go once its children have.
#   rc 0 = the session completed and the helper reported no refusal
#      1 = the helper ANSWERED and refused at least one command (a busy directory, a denied
#          DELETE, a name that was already gone)
#      2 = auth/transport fault — NOTHING here is established about the tree
#
# ── WHY A BATCH PRIMITIVE EXISTS AT ALL (issue #307) ──────────────────────────────────
# The unit of cost against this helper is the LOGIN, not the command: it is password-only
# proftpd, so every helper_* call above pays a fresh authentication, and the provider bans on
# repeated failures (issue #87) — which is why needle's state wipe is capped at 64 operations
# and why that cap is a SAFETY budget rather than a speed knob. A per-file walk therefore
# costs ~2 logins per file, and needle's lap-log clear has to take a directory with hundreds
# of files — spread over a handful of per-machine folders — off the helper without spending
# hundreds of logins.
#
# What makes that possible is the transport we already use: helper-lib feeds sftp its
# commands on STDIN (never `sftp -b` — see the password-sftp invariant at the top of this
# file), and an sftp session reads commands until EOF. So N commands cost ONE login.
# helper_mkdir_p has relied on exactly this since the beginning — it emits one `mkdir` per
# path component in a single session — so this is not a new capability being assumed of the
# helper, it is the shape the boot chain already runs against it in production.
#
# WHY A COUNT AND NOT A `--` (OR ANY OTHER) SEPARATOR between the files and the directories:
# a separator token is a token a FILENAME can also be, and the one thing this function must
# never do is mistake one caller-validated path for a marker and re-interpret the rest of the
# list. A leading count cannot be spoofed by anything in the data. (The same reasoning made
# the exec branch below use a newline rather than `;` between its two commands — issue #307's
# first round: `;` is an ordinary character in a filename, a newline provably is not.)
#
# WHAT IS NOT ASSUMED, deliberately:
#   • NO recursive delete. Neither SFTP nor proftpd mod_sftp offers one (see helper_rmdir),
#     and nothing here pretends otherwise: every directory is emptied file by named file and
#     then rmdir'd, exactly as the depth-first walk does — just inside one session.
#   • NO GLOB. `rm <dir>/*` would be one command, but glob expansion happens in the sftp
#     CLIENT against a readdir, so it is not cheaper than passing the names we already read,
#     and it would hand the helper a pattern instead of a path — i.e. it would delete
#     whatever the server happened to return rather than what the caller validated. Every
#     path this function touches is one the caller named and checked.
#
# THE PATHS ARE VALIDATED HERE TOO, cheaply and lexically: an empty path, an absolute one,
# one that starts with `-` (it could parse as a flag), one carrying a `.` or `..` component,
# and one containing a newline or carriage return are all SKIPPED rather than sent. This
# function's callers do their own, stronger checks (needle re-checks every path against the
# wipe root and refuses anything whose type is not proven), and this is the belt to their
# braces — a batch is the one shape where a single bad path would ride along unnoticed among
# good ones.
#
# VERIFIES NOTHING, and that is the point of the split: sftp exits 0 even when a command
# failed, and `rm -f` on the exec channel reports success about paths it never touched. So
# the rc here is a description of the SESSION, never of the tree, and the caller must settle
# "is it actually gone" with a fresh listing (the issue #128 lesson: a question we could not
# ask must never read as a reassuring answer).
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
  # Nothing survived validation (or nothing was asked for): do NOT spend a login saying so.
  [ $((nf + nd)) -gt 0 ] || return 0
  if [ "$_HELPER_EXEC" = 1 ]; then
    # `--` so a path can never parse as a flag; `rm -f` so an entry that is already gone is
    # not a refusal. `rmdir` takes MANY operands and processes them left to right, which is
    # why the caller orders them deepest-first. The rmdir is the LAST command, so ssh hands
    # back ITS rc — which is the one that says whether the tree emptied.
    #
    # SEPARATED BY A NEWLINE, NOT BY `;`. Both are command separators to the remote shell, but
    # a semicolon is also an ordinary character in a FILENAME, and anything reading this
    # command back (a log, a test harness, a human) would then have to guess which semicolons
    # were separators. A newline cannot appear in a path that reaches here at all: the case
    # above refuses one, and so does needle's own escape guard.
    [ "$nf" -gt 0 ] && cmds="rm -f --${rmargs}
"
    [ "$nd" -gt 0 ] && cmds="${cmds}rmdir --${rmdirargs}"
    _helper_ssh_raw "$cmds" >/dev/null 2>&1; rc=$?
    case "$rc" in 0) return 0 ;; 255) return 2 ;; *) return 1 ;; esac
  fi
  # Replies only (issue #897). A batch echoes EVERY path it was handed, and this function is
  # handed a whole directory of lap artifacts at once — so under the old merged-text verdict
  # a single `…-failures.log` among them condemned the entire session, and needle's wipe was
  # told the tree could not be cleared when it had been.
  _helper_sftp_session "$cmds"
  rc=$_SFTP_RC; out="$_SFTP_ERR"
  # _HELPER_AUTH_RE BEFORE _HELPER_XPORT_RE before _HELPER_ERR_RE — the ordering trap
  # helper_put documents at length: a rejected credential also ends in a disconnect, so
  # testing the transport set first would classify a refusal as retryable.
  if grep -qiE "$_HELPER_AUTH_RE" <<<"$out"; then return 2; fi
  if grep -qiE "$_HELPER_XPORT_RE" <<<"$out"; then return 2; fi
  case "$rc" in 124|137|255) return 2 ;; esac   # killed by _HELPER_OP_TIMEOUT / session failure
  if grep -qiE "$_HELPER_ERR_RE" <<<"$out"; then return 1; fi
  return 0
}

# helper_ls_l <remote>  — LONG-format listing (one entry per line, mode column first).
# WHY A SECOND LISTING PRIMITIVE: `ls -1` returns names, and a name cannot tell a real
# directory from a SYMLINK pointing out of the tree — `ls` follows the link and cheerfully
# lists its target. A long listing is the only lstat-grade answer available on both channels
# (SSH2_FXP_READDIR longnames are generated with lstat per the protocol; GNU `ls -l` uses
# lstat for the entries it prints), so a symlink shows its leading `l`. needle's state wipe
# (issue #131) will not descend into anything without it: `state/` is the helper's one
# WRITABLE root and `secrets/` is its sibling, so one followed link is the operator's vault
# password. `-a` so dotfiles are typed too, and `--` so a path cannot parse as a flag.
helper_ls_l() {
  helper_detect || return 2
  _helper_crypt_on && { _helper_crypt_ls_l "$@"; return $?; }   # crypt mode (#1075)
  local path="${1:-.}"
  if [ "$_HELPER_EXEC" = 1 ]; then
    _helper_ssh_raw "ls -la -- $(_shq "$path")"; return $?
  fi
  # NOTE (issue #897): the far end's complaints now arrive on THIS function's stderr rather
  # than inside its stdout, because _helper_sftp_run no longer merges the streams. Callers
  # that classify the answer (needle's stale_listing_kind) already fold stderr back in with
  # `2>&1` — they had to, because the exec branch above always behaved this way. What has
  # stopped happening is a far-end error line arriving in the middle of a LISTING, where it
  # reads as a filename.
  printf 'ls -la %s\n' "$(_sftpq "$path")" | _helper_sftp_run \
    | grep -vE '^sftp>|^Connected to|^Remote working directory|^Changing|^Fetching|^Uploading'
}

# helper_ls <remote>  — print entry names (one per line) under a dir (or a single path).
helper_ls() {
  helper_detect || return 2
  _helper_crypt_on && { _helper_crypt_ls "$@"; return $?; }   # crypt mode (#1075)
  local path="${1:-.}"
  if [ "$_HELPER_EXEC" = 1 ]; then
    _helper_ssh_raw "ls -1 $(_shq "$path")"; return $?
  fi
  # Filter sftp's own chatter; -1 gives one name per line. As with helper_ls_l above, a
  # far-end complaint lands on stderr now (issue #897) and so can no longer be mistaken for
  # an entry; callers that need to tell "absent" from "empty" fold it back in with `2>&1`.
  printf 'ls -1 %s\n' "$(_sftpq "$path")" | _helper_sftp_run \
    | grep -vE '^sftp>|^Connected to|^Remote working directory|^Changing|^Fetching|^Uploading'
}

# helper_run_python <local-program> [args...]  — run ONE python program on the helper and
# WRITE NOTHING THERE (issue #913).
#
# WHY THIS IS HERE AT ALL, in a library whose header says the helper is a pure file store.
# It still is, for everything the boot chain does. This is the operator's 2026-09-21 ruling
# that the seedbox is the estate's OUTSIDE VERIFIER: the one always-on machine that is not
# in the estate and can therefore fetch a published service by its public name over the
# public path. Nothing about that is expressible as a file op, and the alternative — a
# second helper transport hand-rolled inside an ansible role — is the duplication this
# library exists to prevent.
#
# NOTHING IS LEFT BEHIND. The program travels base64'd on the command line and is decoded
# into `python3 -` on the far side, so it exists only as a pipe: no upload, no temp file,
# nothing to clean up and nothing to leave if the run dies. That matters because the only
# writable path on the real seedbox is the estate's own subtree and this needs none of it.
#
# ── THE ARGUMENTS ARE NOT ON THE REMOTE ARGV, AND THAT IS THE POINT (security audit) ──
# The first cut appended `$(_shq "$a")` per argument to the remote command string. The
# arguments this function's one caller passes are `<label>=<fqdn>` pairs — the estate's
# PUBLIC NAMES, secret-class by SPEC §6.2 — and the seedbox is a shared provider box.
# `/proc/<pid>/cmdline` is world-readable there, so for the whole probe window every other
# local account could simply read the estate's published names out of the running command.
#
# So the arguments are carried INSIDE THE BASE64 BLOB instead: a two-line preamble is
# prepended to the program's own source and the whole thing is encoded together, so the
# remote command line carries one opaque token and nothing name-shaped. The preamble sets
# `sys.argv`, which is what the program already reads — no program needs to change, and a
# program run this way cannot tell the difference.
#
# WHAT THIS BUYS AND WHAT IT DOES NOT. It takes the names out of every cleartext scan of
# /proc, every `ps` line and every shell history on the far side. It is NOT encryption: a
# local user who decides to decode that token gets them back. The genuinely better home is
# the remote process's ENVIRONMENT (`/proc/<pid>/environ` is owner-readable), and it is not
# reachable from here: an assignment written into the remote command string lands in the
# remote SHELL's own cmdline, which is the exposure we are removing, and the only other way
# in is the ssh channel's stdin — which `_helper_ssh_raw` closes with a MANDATORY `-n` for a
# reason documented at length above it (without it the exec-channel probe swallows the rest
# of hook.sh under `curl|bash`). Reopening that for this would trade a read-only disclosure
# on the far side for a silent wedge of the boot chain.
#
# THE ARGUMENT VECTOR IS NUL-JOINED AND BASE64'D INSIDE THE PREAMBLE, not interpolated as
# python literals: an argument containing a quote, a backslash or a newline would otherwise
# have to be escaped for python by a shell, which is the shape that goes wrong. There is no
# quoting to get right this way, only bytes.
#
# THE STATUS AND THE OUTPUT ARE SEPARATE ANSWERS, because ssh's rc cannot carry both: 255 is
# both "the transport failed" and a remote program's own exit 255. So:
#   * THIS function's rc says whether the program RAN — 0 it ran, 2 no transport, 3 the
#     helper has no exec channel (SFTP-only, a real seedbox shape), 4 the LOCAL program file
#     was not readable (a caller's own path is wrong, not the seedbox), 5 the LOCAL argument
#     encoding failed before anything was sent (#913 — 4 and 5 used to be one code, and a
#     caller could not tell "wrong path" from "base64 broke" apart).
#   * THE PROGRAM's own exit code arrives on stdout as the last line, `rc=<n>`, appended by
#     the remote shell. A caller reads the two apart, and a caller that reads only one of
#     them gets a verdict it did not establish.
# `$?` after a pipeline is the LAST element's, which is python3's — not base64's.
helper_run_python() {
  # BOUNDED, like every other shipping helper op: `_HELPER_OP_TIMEOUT` is dynamically
  # scoped, so declaring it here caps the ssh session this function opens. A remote program
  # that hangs must fail rather than hold the lap open.
  local _HELPER_OP_TIMEOUT="${PROVISIONER_HELPER_RUN_TIMEOUT:-120}"
  helper_detect || return 2
  _helper_crypt_alias && { _helper_log "run_python: the access path reaches the seedbox for file transfer only and never opens a shell on it, so a program cannot run there"; return 3; }
  _helper_crypt_on && { _helper_log "run_python: not available in crypt mode"; return 3; }
  [ "$_HELPER_EXEC" = 1 ] || return 3
  local prog="$1"; shift
  [ -r "$prog" ] || return 4
  local argb64 b64
  # argv[0] is the program's BASENAME, never the local path: a caller's checkout layout is
  # nobody's business on the far side either.
  argb64="$(printf '%s\0' "$(basename -- "$prog")" "$@" | base64 -w0)" || return 5
  # `[:-1]` drops the empty tail element that the trailing NUL leaves behind. The preamble
  # is TWO lines so the program's own line numbers move by a known amount in a traceback.
  b64="$( { printf 'import sys\nsys.argv=__import__("base64").b64decode("%s").decode("utf-8").split("\\0")[:-1]\n' \
                   "$argb64"
           cat -- "$prog"; } | base64 -w0 )" || return 5
  # `printf %s` rather than `echo`: the base64 is one long token and echo's flag handling
  # is not portable across the shells a seedbox might run.
  _helper_ssh_raw "printf %s $(_shq "$b64") | base64 -d | python3 -; echo \"rc=\$?\""
}
