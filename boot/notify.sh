#!/usr/bin/env bash
# notify.sh — the SPEC §16 milestone-notification primitive (issue #103).
#
# ONE sender, TWO homes. This exact file runs:
#   • on the CONTROL node, called straight out of the repo by run-pipeline.sh
#     (notify_event), and
#   • on the PVE HOST, installed by ansible/roles/notify as
#     /usr/local/sbin/provisioner-notify and called at BOOT — with no Ansible, no repo
#     and (during the §17 upgrade) no control node — by the pve-upgrade on-host state
#     machine's pve_upgrade_notify_command seam.
# It is COPIED, never re-implemented, so there is exactly one implementation to fix
# (the single-implementation rule: ORCHESTRATOR-LESSONS L-156/L-346, "one question,
#  one answerer" — the July translation's CONTRACT.md stated it first and #649 deleted it).
#
# ── THE DESIGN IN ONE PARAGRAPH (SPEC §16) ────────────────────────────────────
# Decouple EMITTING a milestone from DECIDING to notify on it. Callers emit a named
# event at every meaningful checkpoint — cheap, and a near-no-op when nothing is
# routed to it. A declarative ROUTE TABLE (globs, first match wins) decides what
# actually pings a phone, so changing your mind is a CONFIG edit, never a code edit.
# And because a failure can break the very network the ping needs (SPEC §17's
# NIC-rename trap), the AUTHORITATIVE RECORD is the on-disk journal this script
# always writes — Pushover is only the tap on the shoulder. THE JOURNAL IS WRITTEN
# EVEN WHEN THE SEND FAILS; that is the whole point of the ordering below.
#
# ── HARD CONTRACT (why this file can never break a lap) ───────────────────────
#   • EXIT 0 on every operational outcome — success, HTTP error, timeout, unreachable,
#     unconfigured, malformed config. The ONLY nonzero exit is 2 for "called with no
#     event name", which is a caller bug and is what the test suite asserts on.
#   • NO `set -e`. Every step is individually guarded so the journal write is reached.
#   • EVERY network call is BOUNDED (connect-timeout + max-time + an outer `timeout`),
#     and retries are CAPPED and only for transient classes. There is no loop in this
#     file that is not bounded by a validated integer (see _num(): a bad value like
#     '2x' falls back to the default instead of silently disabling the cap).
#   • NO SECRET on argv, in the environment, or in any log line. The Pushover token +
#     user key travel from a 0600 file into a 0600 curl --config file and nowhere else
#     (the `sshpass -f` / restic `--repository-file` precedent). The config file is
#     born under `umask 077` and removed by an EXIT trap.
#   • NO ESTATE ADDRESSING in a notification body. Call sites are secret-free by
#     construction; _scrub() below is the second line of defence and redacts anything
#     address-shaped before it can reach a third-party API.
#
# ── USAGE ─────────────────────────────────────────────────────────────────────
#   notify.sh <event.name> [detail …]
#
# `detail` is EITHER a readable file — in which case it is treated as a key=value
# STATUS FILE and a whitelist of its keys is folded into the message — OR free text.
# That auto-detection is what makes the pve-upgrade seam a pure one-line default
# change: the on-host script already invokes `$NOTIFY_CMD <event> "$STATUS_FILE"`
# (roles/pve-upgrade/templates/provisioner-pve-upgrade.sh.j2), so pointing
# pve_upgrade_notify_command at this script needs no code change on either side.
#
# ── CONFIG (all optional; every one absent ⇒ clean log-only no-op) ────────────
#   /etc/provisioner/notify.conf        non-secret knobs   (PARSED, never sourced)
#   /etc/provisioner/notify-routes.tab  the route table    (see resolution order below)
#   /etc/provisioner/pushover.conf      the credentials    (0600, PARSED, never sourced;
#                                                          see resolution order below)
#
# PARSED, NEVER SOURCED — deliberately. Two of these three files can arrive from the
# helper (the trusted boot channel, but still an external store). `source`ing them
# would make any helper-staged file arbitrary root code execution on the PVE host; a
# strict key=value parser with an allow-list makes it data.

set -o pipefail

# ── Paths + resolution order ──────────────────────────────────────────────────
NOTIFY_DIR="${PROVISIONER_NOTIFY_DIR:-/var/lib/provisioner/notify}"
JOURNAL="${NOTIFY_DIR}/events.log"            # append-only history — THE authoritative record
STATUS_OUT="${NOTIFY_DIR}/notify.status"      # last outcome, machine-readable (mirrored to the helper)
CONF_FILE="${PROVISIONER_NOTIFY_CONF:-/etc/provisioner/notify.conf}"
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || _SELF_DIR=""
# Every /etc candidate below — both route tables AND both credential files — derives from
# ONE variable so the test suite can point them at a temp dir. TEST/DIAGNOSTIC ONLY —
# production never sets it, and the default is the literal /etc/provisioner it has always
# been, so resolution on a real node is byte-for-byte unchanged.
NOTIFY_ETC_DIR="${PROVISIONER_NOTIFY_ETC_DIR:-/etc/provisioner}"

# Credentials, most-specific-source first — the exact twin of the route-table chain below:
#   1. $PROVISIONER_PUSHOVER_CONF          — explicit override. AUTHORITATIVE, NO FALLBACK.
#   2. /etc/provisioner/pushover.conf        — HELPER-STAGED, pulled by control-boot.sh out
#                                             of the estate chroot's secrets/ — WINS when it exists
#   3. /etc/provisioner/pushover.estate.conf — rendered on the CONTROL NODE by
#                                             ansible/roles/notify from the estate vault
#   4. none present ⇒ CREDS_FILE still NAMES slot 2, because that is the path the
#      "no credentials on this node" journal line tells the operator to stage.
#
# SLOT 1 IS ABSOLUTE — IT NEVER FALLS THROUGH, not even when the file is missing or
# unreadable. `PROVISIONER_PUSHOVER_CONF=<path>` has always meant "THIS EXACT FILE", and
# callers (and the test suite) point it at a deliberately absent or deliberately malformed
# path to assert `unconfigured` / `unconfigured-malformed`. A fallthrough would silently
# substitute a DIFFERENT credential file and turn those outcomes into lies — the caller
# would be told "no credentials" while a push went out under someone else's token. So the
# env var is checked for being SET, not for being readable.
#
# WHY (3) HAS ITS OWN FILENAME — the credential twin of the stale-table trap documented at
# the route chain, and it has already bitten once: roles/notify STATS slot 2 to ask "did
# control-boot.sh stage a helper file?". When the vault-rendered credential was written to
# slot 2 as well, the next run mistook ITS OWN OUTPUT for a helper-staged file, took the
# helper-wins branch, and re-pushed a STALE token to the fleet — play green, advisories
# skipped, nothing saying why. Separate filenames make that self-shadowing impossible:
# slot 2 is only ever written by the helper path, slot 3 only ever by the role, and
# precedence is decided HERE, structurally, instead of by a stat that cannot tell the two
# writers apart. The PVE HOST now carries the SAME two slots for the SAME reason (D7): its
# vault-derived credential used to land on slot 2's filename, where the role could not tell
# it from a helper-staged file — so emptying the vault left the withdrawn token live on the
# host, lap green, role printing "nothing is sent". It writes to slot 3's filename there
# too, with a removal companion, and this chain resolves both nodes identically. (An
# earlier revision of this comment claimed slot 2 on the host was "a pure destination
# overwritten every run" and that slot 3 could never exist there. Both halves were false:
# the deploy is guarded, so an emptied vault overwrote nothing — that WAS D7.)
#
# NOTE the deliberate consequence of first-READABLE-wins: a slot 2 that exists but is
# malformed reports `unconfigured-malformed` and does NOT quietly fall through to slot 3.
# Same rule as the route chain — presence decides, content never does — so an operator who
# breaks the helper file is told about THAT file instead of being silently served a
# different credential than the one they think is live.
if [[ -n ${PROVISIONER_PUSHOVER_CONF:-} ]]; then
  CREDS_FILE="$PROVISIONER_PUSHOVER_CONF"
elif [[ -r "${NOTIFY_ETC_DIR}/pushover.conf" ]]; then
  CREDS_FILE="${NOTIFY_ETC_DIR}/pushover.conf"
elif [[ -r "${NOTIFY_ETC_DIR}/pushover.estate.conf" ]]; then
  CREDS_FILE="${NOTIFY_ETC_DIR}/pushover.estate.conf"
else
  CREDS_FILE="${NOTIFY_ETC_DIR}/pushover.conf"
fi

# Route table, most-specific-source first:
#   1. $PROVISIONER_NOTIFY_ROUTES        — explicit override (the test suite uses this)
#   2. /etc/provisioner/notify-routes.tab        — the HELPER-STAGED table, pulled by
#                                           control-boot.sh out of the estate chroot's secrets/
#   3. /etc/provisioner/notify-routes.estate.tab — rendered on the CONTROL NODE by
#                                           ansible/roles/notify (delegate_to: localhost)
#                                           from the estate's `notify_routes` list
#   4. <script dir>/notify-routes.default.tab       — the repo default (control node)
#   5. /usr/local/lib/provisioner/notify-routes.default.tab — the repo default (PVE host,
#                                           installed beside the script by roles/notify)
#   6. nothing found ⇒ the built-in table below: EVERYTHING log-only. An estate that
#      stages no config behaves exactly as it does today — no sends, no failures.
#
# WHY (3) IS ITS OWN PATH AND NOT JUST WRITTEN OVER (2). Two reasons, and the second is
# the one that bites:
#   • THE TWO HOMES RESOLVE THE TABLE IN DIFFERENT PLACES, and (3) exists to serve the
#     one that had nothing. On the PVE HOST, roles/notify picks the winner in ANSIBLE
#     (helper-staged copy > rendered from `notify_routes` > shipped default) and writes
#     the single effective table to (2)'s filename; `notify-routes.estate.tab` never
#     exists there and that host logic is unchanged. The CONTROL node had no equivalent —
#     yet it is the node that emits every `pipeline.*` event, including the failure beacon
#     and the success ping — so an operator who customised `notify_routes` governed only
#     the host-emitted half of their own estate's notifications. (3) is that missing slot:
#     roles/notify renders the SAME table to the control node with `delegate_to: localhost`
#     when `notify_routes` is non-empty, and removes it when the list is emptied, so the
#     controller obeys the estate's routing without a second code path, a second table
#     format, or any change at all on a node where the file is simply absent.
#   • The role decides "is a helper-staged table present?" by stat-ing (2). If the render
#     landed there too, a re-run of host-prep would mistake ITS OWN OUTPUT for a
#     helper-staged table and refuse to re-render — a changed `notify_routes` would then
#     never take effect, silently, forever. Separate paths plus this precedence order make
#     that stale-table trap structurally impossible rather than a rule someone must
#     remember: the helper table still WINS when it exists, and the rendered table is
#     always freshly re-derivable because nothing else ever writes it.
ROUTES_FILE=""
for _c in "${PROVISIONER_NOTIFY_ROUTES:-}" \
          "${NOTIFY_ETC_DIR}/notify-routes.tab" \
          "${NOTIFY_ETC_DIR}/notify-routes.estate.tab" \
          "${_SELF_DIR:+${_SELF_DIR}/notify-routes.default.tab}" \
          /usr/local/lib/provisioner/notify-routes.default.tab; do
  [[ -n $_c && -r $_c ]] && { ROUTES_FILE="$_c"; break; }
done
# The built-in fallback (used only when NO table file exists anywhere). Same shape as
# the file: "<event-glob> <pushover> <priority> <once>". Everything log-only.
BUILTIN_ROUTES='*  no  normal  -'

# ── Defaults for the non-secret knobs (overridable in notify.conf) ────────────
NOTIFY_ENABLED=1                                   # 0 ⇒ journal only, never send
NOTIFY_API_URL="https://api.pushover.net/1/messages.json"
NOTIFY_CONNECT_TIMEOUT=5                           # seconds to establish the TCP/TLS connection
NOTIFY_MAX_TIME=15                                 # seconds for the WHOLE request
NOTIFY_RETRIES=2                                   # ADDITIONAL attempts after the first (so ≤3 total)
NOTIFY_RETRY_DELAY=3                               # seconds between attempts
NOTIFY_ESTATE="${PROVISIONER_ESTATE:-}"            # names the estate in the push title (NOT secret)
NOTIFY_EMERGENCY_RETRY=60                          # Pushover priority=2 requires retry+expire
NOTIFY_EMERGENCY_EXPIRE=3600

# ── Logging: every line goes to stderr so the CALLER's log shows it ───────────
# The caller (run-pipeline's tee'd log, or the pve-upgrade script's >>"$LOG_FILE")
# captures stderr, so "the send failed" is visible where the operator is already
# looking — the constraint "a send failure must be VISIBLE" is met without the caller
# having to check an exit status it is contractually told to ignore.
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_log() { printf '[notify] %s %s\n' "$(_ts)" "$*" >&2; }

# _num <value> <default> <min> <max> — validate an integer knob, fall back on anything
# else. THE '2x' TRAP: an unvalidated value in `(( n >= max ))` is a bash syntax error
# that evaluates false, silently DISABLING the cap and turning a bounded retry into an
# unbounded spin. Every numeric knob in this file goes through here first.
_num() {
  local v="$1" def="$2" lo="$3" hi="$4"
  [[ $v =~ ^[0-9]+$ ]] || { printf '%s' "$def"; return 0; }
  (( v < lo )) && { printf '%s' "$lo"; return 0; }
  (( v > hi )) && { printf '%s' "$hi"; return 0; }
  printf '%s' "$v"
}

# _read_kv <file> <KEY> — echo the value of KEY from a `KEY=value` / `KEY: value` file.
# A strict line parser, NOT `source`: no expansion, no substitution, no execution. Only
# the FIRST match wins; surrounding whitespace and one layer of quotes are stripped.
# The `|| [[ -n $line ]]` is load-bearing, not defensive: the operator's real staged
# pushover.conf has NO TRAILING NEWLINE — the last line ends at EOF — and a plain
# `while read` drops it, silently losing PUSHOVER_USER while the file looks configured.
# The \r strip is the same class of bug for a file edited on Windows.
# So is the BOM strip beside it. A UTF-8 BOM (EF BB BF) is invisible in every editor that
# writes one, but it lands IN FRONT OF the first key, so `^[[:space:]]*PUSHOVER_TOKEN` no
# longer matches line 1 of a BOM'd pushover.conf: the credential file reads as present but
# tokenless, notify.sh journals `unconfigured-malformed`, and the whole estate goes MUTE —
# no failure beacon, no success ping — with nothing but that one journal word to say why.
# Same hole for notify.conf's first knob. Stripping a LEADING BOM per line is safe: the
# sequence is only ever legitimate at byte 0 of a file, never as the head of a config key.
_read_kv() {
  local f="$1" key="$2" line v
  [[ -r $f ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%$'\r'}"
    line="${line#$'\xEF\xBB\xBF'}"
    [[ $line =~ ^[[:space:]]*# ]] && continue
    [[ $line =~ ^[[:space:]]*${key}[[:space:]]*[=:][[:space:]]*(.*)$ ]] || continue
    v="${BASH_REMATCH[1]}"
    v="${v%"${v##*[![:space:]]}"}"                 # rstrip
    v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"
    printf '%s' "$v"; return 0
  done < "$f"
  return 1
}

# Load the non-secret knobs (allow-list; anything else in the file is ignored, so a
# future key can be added to the file before this script knows about it).
if [[ -r $CONF_FILE ]]; then
  for _k in NOTIFY_ENABLED NOTIFY_API_URL NOTIFY_CONNECT_TIMEOUT NOTIFY_MAX_TIME \
            NOTIFY_RETRIES NOTIFY_RETRY_DELAY NOTIFY_ESTATE \
            NOTIFY_EMERGENCY_RETRY NOTIFY_EMERGENCY_EXPIRE; do
    _v="$(_read_kv "$CONF_FILE" "$_k")" && [[ -n $_v ]] && printf -v "$_k" '%s' "$_v"
  done
fi
# Env always wins over the file (the test suite and run-pipeline drive these).
NOTIFY_ENABLED="${PROVISIONER_NOTIFY_ENABLED:-$NOTIFY_ENABLED}"
NOTIFY_ESTATE="${PROVISIONER_ESTATE:-$NOTIFY_ESTATE}"
NOTIFY_API_URL="${PROVISIONER_NOTIFY_API_URL:-$NOTIFY_API_URL}"
NOTIFY_SCOPE="${PROVISIONER_NOTIFY_SCOPE:-default}"

# Validate every numeric knob (see _num's '2x' note). Upper bounds are deliberate: no
# operator edit — or corrupted helper file — can turn this into a long stall in a lap.
NOTIFY_CONNECT_TIMEOUT="$(_num "$NOTIFY_CONNECT_TIMEOUT" 5 1 30)"
NOTIFY_MAX_TIME="$(_num "$NOTIFY_MAX_TIME" 15 2 60)"
NOTIFY_RETRIES="$(_num "$NOTIFY_RETRIES" 2 0 5)"
NOTIFY_RETRY_DELAY="$(_num "$NOTIFY_RETRY_DELAY" 3 0 30)"
NOTIFY_EMERGENCY_RETRY="$(_num "$NOTIFY_EMERGENCY_RETRY" 60 30 600)"
NOTIFY_EMERGENCY_EXPIRE="$(_num "$NOTIFY_EMERGENCY_EXPIRE" 3600 60 10800)"
# Worst case wall-clock this script can cost its caller, stated explicitly:
#   (1 + NOTIFY_RETRIES) * NOTIFY_MAX_TIME + NOTIFY_RETRIES * NOTIFY_RETRY_DELAY
#   = 3*15 + 2*3 = 51s at the defaults, with the shipped table sending on ≤4 events.

# ── Scrubbing: nothing address-shaped may reach a third-party API ─────────────
# IPs and estate identity are secret in this repo (SPEC §6). Call sites are secret-free
# by construction, but a status file or an error string can carry an address in from the
# machine, so EVERY body is scrubbed here before it can leave the node. Over-redact by
# design: losing a token to a false positive is cosmetic, leaking one address is not.
# Also flattens newlines (a curl config value cannot span lines) and truncates to fit
# Pushover's 1024-char message limit.
_scrub() {
  local _s
  _s="$(printf '%s' "$*" \
    | tr '\n\r\t\000' '    ' \
    | sed -E \
        -e 's/-----BEGIN[^-]*PRIVATE KEY-----.*-----END[^-]*PRIVATE KEY-----/[redacted-key]/g' \
        -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?/[redacted-addr]/g' \
        -e 's/([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}/[redacted-mac]/g' \
        -e 's/\b[0-9a-fA-F]{4}\.[0-9a-fA-F]{4}\.[0-9a-fA-F]{4}\b/[redacted-mac]/g' \
        -e 's/[0-9a-fA-F:]*::[0-9a-fA-F:]*/[redacted-addr6]/g' \
        -e 's/\b([0-9a-fA-F]{1,4}:){3,7}[0-9a-fA-F]{1,4}\b/[redacted-addr6]/g' \
        -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/[redacted-host]/g' \
        -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+/[redacted-host]/g' \
        -e 's/(token|password|passphrase|secret|user_key|api_key)[[:space:]]*[=:][[:space:]]*[^[:space:]]+/\1=[redacted]/gI')"
  # Truncated by EXPANSION, not `| head -c 900` (issue #898). head leaves at 900 and SIGPIPEs
  # sed; under pipefail that 141 became this function's status — wrong exactly when the detail
  # is long enough to be worth sending. Nothing reads that status today, which is the only
  # reason it never bit; it was one `|| die` away from being a verdict.
  printf '%s' "${_s:0:900}"
}

# ── Route resolution: first matching glob wins ────────────────────────────────
# Table columns: <event-glob>  <pushover yes|no>  <priority>  <once yes|->
# ORDER IS THE SPECIFICITY RULE — the first line whose glob matches decides, so
# `host.upgrade.failed` must precede `host.upgrade.*`, and `*` is the catch-all last
# line. That is why the table is an ORDERED list, not the mapping SPEC §16 originally
# sketched (a mapping has no defensible order for overlapping wildcards).
# Sets: R_SEND (0/1), R_PRIO, R_ONCE (0/1), R_GLOB.
_resolve_route() {
  local event="$1" glob send prio once line
  R_SEND=0; R_PRIO="normal"; R_ONCE=0; R_GLOB="(builtin default)"
  # `printf | while` would run the loop in a subshell and lose R_*; feed it on stdin via
  # a here-string instead so the assignments survive. The input is a whole table read
  # once — there is no unbounded read here.
  local table
  if [[ -n $ROUTES_FILE && -r $ROUTES_FILE ]]; then table="$(cat "$ROUTES_FILE" 2>/dev/null)"
  else table="$BUILTIN_ROUTES"; fi
  # NOGLOB while parsing. `set -- $line` word-splits — and ALSO pathname-expands, which
  # silently detonates the one row every table must have: the `*` catch-all becomes a list
  # of filenames in the CWD, the row never matches, and the operator's declared default is
  # quietly replaced by this function's initial values. (Caught by driving a role-rendered
  # table through the sender: `anything.else` reported glob=(builtin default) instead of
  # glob=*.) `[[ $event == $glob ]]` below is PATTERN matching, not pathname expansion, so
  # it is unaffected by -f — the globs still work, they just stop touching the filesystem.
  local _reset_glob=0
  [[ $- == *f* ]] || { set -f; _reset_glob=1; }
  while IFS= read -r line; do
    # CR STRIP FIRST. This is the operator-editable, helper-staged file — the one most
    # likely to arrive with CRLF — and a trailing \r rides into the LAST column, so
    # `once\r` no longer equals `once` and the one-shot guard silently turns off; a
    # 2-column CRLF row makes `no\r` match nothing in the send case and disables sending
    # entirely. The shipped table happened to be immune only because both `once` rows
    # carry trailing comments, so `${line%%#*}` ate the \r along with the comment.
    line="${line//$'\r'/}"
    # …AND A LEADING BOM, same reason, worse blast radius. A UTF-8 BOM (EF BB BF) is
    # invisible in the editor that wrote it but is a byte of the FIRST data row — and the
    # first data row of the shipped table is `pipeline.failed`, the #59 failure beacon. Its
    # glob silently becomes `<BOM>pipeline.failed`, matches no event, and the estate's death
    # notification degrades to the `*` catch-all: log-only. The lap still dies; nobody's
    # phone ever rings. Leading-only, per line: the sequence is legitimate at byte 0 of a
    # file and nowhere else, so this cannot corrupt a real glob.
    line="${line#$'\xEF\xBB\xBF'}"
    line="${line%%#*}"                                   # strip comments
    [[ -z ${line//[[:space:]]/} ]] && continue           # skip blanks
    # shellcheck disable=SC2086  # deliberate word-split into the four columns (noglob is on)
    set -- $line
    glob="${1:-}"; send="${2:-no}"; prio="${3:-normal}"; once="${4:--}"
    [[ -n $glob ]] || continue
    # Unquoted RHS = bash glob matching, which is exactly the `vm.*.created` family
    # semantics SPEC §16 asks for.
    # shellcheck disable=SC2053
    if [[ $event == $glob ]]; then
      R_GLOB="$glob"
      case "${send,,}" in yes|true|1|on) R_SEND=1 ;; *) R_SEND=0 ;; esac
      case "${prio,,}" in low|normal|high|emergency) R_PRIO="${prio,,}" ;; *) R_PRIO="normal" ;; esac
      case "${once,,}" in once|yes|true|1) R_ONCE=1 ;; *) R_ONCE=0 ;; esac
      break
    fi
  done <<< "$table"
  (( _reset_glob == 1 )) && set +f      # restore the caller's globbing on EVERY exit path
  return 0
}

_prio_num() {
  case "$1" in low) printf '%s' -1 ;; high) printf '%s' 1 ;; emergency) printf '%s' 2 ;; *) printf '%s' 0 ;; esac
}

# ── The journal: written on EVERY path, before the process can exit ───────────
# This is the authoritative record (SPEC §16). It must survive the send failing, the
# network being the casualty, and the box rebooting mid-phase — so it is a local
# append, 0600, and every failure to write it degrades to stderr rather than aborting.
_journal() {
  local line
  line="$(_ts) $*"
  if install -d -m 0700 "$NOTIFY_DIR" 2>/dev/null; then
    printf '%s\n' "$line" >> "$JOURNAL" 2>/dev/null || _log "could not append to ${JOURNAL} (record kept in this log only)"
    chmod 0600 "$JOURNAL" 2>/dev/null || true
    printf '%s\n' "$line" > "$STATUS_OUT" 2>/dev/null || true
    chmod 0600 "$STATUS_OUT" 2>/dev/null || true
  else
    _log "could not create ${NOTIFY_DIR} (record kept in this log only)"
  fi
  _log "$*"
}

# ── The operator-facing send log (#1110) ──────────────────────────────────────
# One line per PUSHOVER attempt: what the operator was (or was not) told, readable by the
# main session once log-export ships it. Distinct from the journal above, which records
# every event. Carries the scrubbed title/message only — never a credential. BEST-EFFORT:
# every step is guarded, so an unwritable log can never stop or fail a send.
NOTIFY_LOG="${PROVISIONER_NOTIFY_LOG:-/var/log/provisioner/notify.log}"
# _send_log <outcome: ok|failed|skipped> <reason> [http] [attempts]
_send_log() {
  [[ -n $NOTIFY_LOG ]] || return 0
  {
    local _src _ld
    _e() { local v="${1//\\/\\\\}"; printf '%s' "${v//\"/\\\"}"; }
    _src="$(cat "/proc/${PPID}/comm" 2>/dev/null)"
    _ld="$(dirname "$NOTIFY_LOG")"
    [[ -d $_ld ]] || install -d -m 0750 "$_ld"
    [[ -e $NOTIFY_LOG ]] || install -m 0640 /dev/null "$NOTIFY_LOG"
    printf 'ts=%s host=%s source="%s" event=%s title="%s" prio=%s outcome=%s reason=%s http=%s attempts=%s message="%s"\n' \
      "$(date +%Y-%m-%dT%H:%M:%S%z)" "$(hostname -s 2>/dev/null || echo unknown)" \
      "$(_e "$(printf '%s' "${PROVISIONER_NOTIFY_SOURCE:-${_src:-unknown}}" | tr '\n\r' '  ')")" "${EVENT_KEY:-$EVENT}" \
      "$(_e "$(printf '%s' "${NOTIFY_ESTATE:-provisioner}" | tr '\n\r' '  ')")" "${R_PRIO:-normal}" \
      "$1" "${2:--}" "${3:--}" "${4:--}" "$(_e "${SAFE_DETAIL:-${EVENT}}")" >> "$NOTIFY_LOG"
  } 2>/dev/null || true
  return 0
}

# ── main ──────────────────────────────────────────────────────────────────────
EVENT="${1:-}"
if [[ -z $EVENT ]]; then
  printf 'usage: %s <event.name> [detail …]\n' "$(basename "$0")" >&2
  exit 2                                                  # caller bug — the ONLY nonzero exit
fi
shift
DETAIL="$*"

# `detail` is a status FILE ⇒ fold a WHITELIST of its keys into the message. Never dump
# the file wholesale: a status file is machine-written but lives on disk, and an
# unbounded dump is exactly how an address or a secret would get into a push body.
#
# The three ROUTED `host.upgrade.*` events (started/done/failed) carry no author-written
# text at all — the on-host §17 engine calls `notify.sh <event> <status-file>` and nothing
# else — so this is the ONLY place their message can be written (issue #148). They get
# PROSE built from the file's real values; every other status-file caller keeps the
# key=value fold, which is what a log-only record wants.
#
# THE VALUES MUST COME FROM THE FILE. An earlier draft wrote "Proxmox 8 → 9" as a
# constant; that sentence LIES on a 9 → 10 box, and the numbers are sitting right there in
# the status file. (They were being read as `major`, which never matched `pve_major`:
# _read_kv anchors at `^[[:space:]]*${key}`, so the key names have to be exact.) Every
# fragment below is conditional on its value existing — a missing key shortens the
# sentence, it never invents a number.
STATUS_SRC=""
if [[ -n $DETAIL && -f $DETAIL && -r $DETAIL ]]; then
  STATUS_SRC="$DETAIL"; DETAIL=""
  case "$EVENT" in
    host.upgrade.started|host.upgrade.done|host.upgrade.failed)
      # `from`/`to` are the seam's generic names; `pve_major`/`target_major` are what the
      # shipped engine actually writes. Accept either, generic first.
      _u_from="$(_read_kv "$STATUS_SRC" from)"        || _u_from=""
      [[ -n $_u_from ]] || _u_from="$(_read_kv "$STATUS_SRC" pve_major)" || _u_from=""
      _u_to="$(_read_kv "$STATUS_SRC" to)"            || _u_to=""
      [[ -n $_u_to   ]] || _u_to="$(_read_kv "$STATUS_SRC" target_major)" || _u_to=""
      # `failed_at` is the phase the engine was IN when it died; `phase` reads "failed" on
      # that path (a wire format the pipeline's probe parses — see the pve-upgrade role).
      _u_phase="$(_read_kv "$STATUS_SRC" failed_at)"  || _u_phase=""
      [[ -n $_u_phase ]] || _u_phase="$(_read_kv "$STATUS_SRC" phase)" || _u_phase=""
      _u_err="$(_read_kv "$STATUS_SRC" error)"        || _u_err=""
      [[ -n $_u_err ]] || _u_err="$(_read_kv "$STATUS_SRC" result)" || _u_err=""
      # DEGRADED PATH — a status file written by an engine armed BEFORE the failed_at/error
      # keys existed (the host keeps its armed copy until the role is re-run, and this
      # script is helper-served, so the two versions WILL meet). Then `phase` is the literal
      # marker "failed" and `result` is "failed:<reason>": strip both, or the sentence reads
      # "failed during failed: failed:…". A stripped-empty phase just drops the clause.
      [[ $_u_phase == failed ]] && _u_phase=""
      _u_err="${_u_err#failed:}"
      case "$EVENT" in
        host.upgrade.started)
          if [[ -n $_u_from && -n $_u_to ]]; then DETAIL="Upgrading Proxmox ${_u_from} → ${_u_to}."
          elif [[ -n $_u_to ]];               then DETAIL="Upgrading Proxmox to ${_u_to}."
          else                                     DETAIL="Upgrading Proxmox."; fi
          DETAIL="${DETAIL} The box will reboot a few times."
          ;;
        host.upgrade.done)
          # "now on" is the DESTINATION, and on this event the shipped engine has already
          # verified the box reached it (phase_post only writes done after `maj >= TO_MAJOR`),
          # so `to`/`target_major` is the right value. NOT `from`: a producer that writes the
          # seam's generic `from=8 to=9` pair on a done event would otherwise be reported as
          # "now on 8" — a false statement about the machine, which is the whole class of
          # error the "no invented facts" decision exists to prevent.
          if [[ -n $_u_to ]];      then DETAIL="Proxmox upgrade finished — now on ${_u_to}."
          elif [[ -n $_u_from ]];  then DETAIL="Proxmox upgrade finished — now on ${_u_from}."
          else                          DETAIL="Proxmox upgrade finished."; fi
          ;;
        host.upgrade.failed)
          if [[ -n $_u_phase && -n $_u_err ]]; then DETAIL="Proxmox upgrade failed during ${_u_phase}: ${_u_err}."
          elif [[ -n $_u_phase ]];             then DETAIL="Proxmox upgrade failed during ${_u_phase}."
          elif [[ -n $_u_err ]];               then DETAIL="Proxmox upgrade failed: ${_u_err}."
          else                                      DETAIL="Proxmox upgrade failed."; fi
          DETAIL="${DETAIL} Needs you."
          ;;
      esac
      ;;
    *)
      for _k in phase result from to pve_major target_major error note; do
        _v="$(_read_kv "$STATUS_SRC" "$_k")" && [[ -n $_v ]] && DETAIL="${DETAIL:+${DETAIL} }${_k}=${_v}"
      done
      ;;
  esac
fi

_resolve_route "$EVENT"
SAFE_DETAIL="$(_scrub "$DETAIL")"
EVENT_KEY="$(printf '%s' "$EVENT" | tr -c 'A-Za-z0-9._-' '_')"
SCOPE_KEY="$(printf '%s' "$NOTIFY_SCOPE" | tr -c 'A-Za-z0-9._-' '_')"
# nosend is stamped on EVERY journal line, not just the send path: a caller that asked for
# record-only did so because the machine is going down, and that fact must be legible in the
# record whatever the routing table happened to say about this event.
_nosend_tag=""
[[ ${PROVISIONER_NOTIFY_NO_SEND:-0} == 1 ]] && _nosend_tag=" nosend=1"
_base="event=${EVENT} glob=${R_GLOB} estate=${NOTIFY_ESTATE:-unset}${_nosend_tag}${SAFE_DETAIL:+ detail=\"${SAFE_DETAIL}\"}"

# 1. Not routed to Pushover → log-only. This is the SPEC §16 "instrument richly, notify
#    selectively" default and the whole no-op story: an over-instrumented pipeline costs
#    one journal append per event.
if (( R_SEND == 0 )); then
  _journal "route=log-only ${_base}"
  exit 0
fi
if [[ ${NOTIFY_ENABLED} == 0 ]]; then
  _journal "route=disabled ${_base}"
  exit 0
fi

# 1b. RECORD-ONLY. Set by a caller that knows the machine is on its way down (see
#     run-pipeline.sh's signal-handling EXIT trap): the event must still be RECORDED —
#     the journal is the authoritative record and that does not change — but no network
#     call may be started, because a curl during shutdown either delays the shutdown or
#     dies half-way. This is what makes "no curl attempt while the box is shutting down"
#     a structural property rather than an accident of the shipped routing table.
if [[ ${PROVISIONER_NOTIFY_NO_SEND:-0} == 1 ]]; then
  _send_log skipped record-only
  _journal "route=pushover result=record-only prio=${R_PRIO} ${_base} — caller asked for record-only (shutdown in progress); nothing sent"
  exit 0
fi

# 2. The `once` latch (defence in depth for the false-success trap — see run-pipeline.sh
#    notify_scope()). A terminal event marked `once` fires at most one time per SCOPE,
#    where the scope is one cold start (it survives the upgrade's reboots because
#    run-pipeline persists it in STATE_DIR). Latched on ATTEMPT, not on success: the
#    guarantee is "exactly one success notification per cold start", and a retry storm
#    against a down Pushover would otherwise re-fire it on the next pass.
LATCH_DIR="${NOTIFY_DIR}/once/${SCOPE_KEY}"
LATCH="${LATCH_DIR}/${EVENT_KEY}"
if (( R_ONCE == 1 )) && [[ -e $LATCH ]]; then
  _journal "route=pushover result=suppressed-duplicate scope=${SCOPE_KEY} prio=${R_PRIO} ${_base}"
  exit 0
fi

# 3. Credentials. Absent / malformed ⇒ UNCONFIGURED: journal it and exit clean. An estate
#    that never stages pushover.conf therefore runs byte-for-byte as it does today.
PUSH_TOKEN=""; PUSH_USER=""
if [[ -r $CREDS_FILE ]]; then
  PUSH_TOKEN="$(_read_kv "$CREDS_FILE" PUSHOVER_TOKEN)" || PUSH_TOKEN=""
  PUSH_USER="$(_read_kv "$CREDS_FILE" PUSHOVER_USER)" || PUSH_USER=""
fi
# Shape check only — never echo, never log, never compare against anything but a regex.
# Pushover keys are 30 alphanumerics; accept 20-40 so a format change does not brick us.
if [[ ! $PUSH_TOKEN =~ ^[A-Za-z0-9]{20,40}$ || ! $PUSH_USER =~ ^[A-Za-z0-9]{20,40}$ ]]; then
  if [[ -r $CREDS_FILE ]]; then
    _send_log skipped unconfigured-malformed
    _journal "route=pushover result=unconfigured-malformed prio=${R_PRIO} ${_base} — ${CREDS_FILE} present but does not carry a well-formed PUSHOVER_TOKEN/PUSHOVER_USER pair"
  else
    _send_log skipped unconfigured
    _journal "route=pushover result=unconfigured prio=${R_PRIO} ${_base} — no ${CREDS_FILE} on this node (log-only; stage it to enable pushes)"
  fi
  exit 0
fi
if ! command -v curl >/dev/null 2>&1; then
  _send_log skipped no-curl
  _journal "route=pushover result=no-curl prio=${R_PRIO} ${_base} — curl absent on this node; record kept, nothing sent"
  exit 0
fi

# 4. Build the request. The credentials go from their 0600 file into a 0600 curl config
#    file and NOWHERE else — not argv, not the environment, not a log line. The config
#    file is created under `umask 077` in a private directory and removed by the EXIT
#    trap, so it never outlives this process.
umask 077
CFG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/provisioner-notify.XXXXXX" 2>/dev/null)" || CFG_DIR=""
if [[ -z $CFG_DIR ]]; then
  _send_log failed no-tmpdir
  _journal "route=pushover result=no-tmpdir prio=${R_PRIO} ${_base} — could not create a private temp dir; record kept, nothing sent"
  exit 0
fi
# shellcheck disable=SC2317  # invoked via trap
_cleanup() { [[ -n ${CFG_DIR:-} && -d $CFG_DIR ]] && rm -rf "$CFG_DIR" 2>/dev/null; return 0; }
# A signal trap must EXIT, not return. Returning from the INT/TERM handler resumes the
# retry loop below against a curl config file the handler just deleted — three more
# doomed attempts, ~28s of them, precisely while the box is trying to shut down. So the
# signal handler records the abort and exits; only the EXIT trap is a bare cleanup.
# shellcheck disable=SC2317  # invoked via trap
_on_signal() {
  _send_log failed aborted-signal
  _journal "route=pushover result=aborted-signal prio=${R_PRIO} ${_base} — interrupted by a signal mid-send; nothing further attempted"
  _cleanup
  exit 0
}
trap _cleanup EXIT
trap _on_signal INT TERM HUP
CFG="${CFG_DIR}/curl.cfg"

# curl config values are double-quoted, so backslashes and quotes must be escaped or the
# parser silently truncates the value.
_cfgesc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
# TITLE = THE ESTATE, nothing else (issue #148). The `provisioner · ` prefix was a
# constant on every push — it told the operator nothing that the notification arriving on
# this channel did not already tell them, and it cost the estate name half a lock-screen
# line. The estate is the one word that will matter once there is more than one.
# `provisioner` survives ONLY as the fallback for a run with no estate set, because a
# Pushover request with an empty title falls back to the application name.
TITLE="${NOTIFY_ESTATE:-provisioner}"
# BODY = the message the call site wrote, and NOTHING ELSE. The event id used to lead
# every body (`host.needle.detached — cold start is now unattended…`); it is a ROUTING
# KEY, not prose, and it is already on every journal line, which is where an investigation
# starts. It stays as the fallback for a detail-less event only because Pushover rejects
# an empty message — the twelve routed events all carry text.
BODY="${SAFE_DETAIL:-${EVENT}}"
{
  printf 'url = "%s"\n'                 "$(_cfgesc "$NOTIFY_API_URL")"
  printf 'data-urlencode = "token=%s"\n' "$(_cfgesc "$PUSH_TOKEN")"
  printf 'data-urlencode = "user=%s"\n'  "$(_cfgesc "$PUSH_USER")"
  printf 'data-urlencode = "title=%s"\n' "$(_cfgesc "$TITLE")"
  printf 'data-urlencode = "message=%s"\n' "$(_cfgesc "$BODY")"
  printf 'data = "priority=%s"\n'       "$(_prio_num "$R_PRIO")"
  if [[ $R_PRIO == emergency ]]; then
    printf 'data = "retry=%s"\n'  "$NOTIFY_EMERGENCY_RETRY"
    printf 'data = "expire=%s"\n' "$NOTIFY_EMERGENCY_EXPIRE"
  fi
  printf 'connect-timeout = %s\n' "$NOTIFY_CONNECT_TIMEOUT"
  printf 'max-time = %s\n'        "$NOTIFY_MAX_TIME"
  printf 'silent\nshow-error\noutput = /dev/null\nwrite-out = "%%{http_code}"\n'
} > "$CFG" 2>/dev/null || {
  _send_log failed cfg-write-failed
  _journal "route=pushover result=cfg-write-failed prio=${R_PRIO} ${_base}"
  exit 0
}
chmod 0600 "$CFG" 2>/dev/null || true
# The token now exists ONLY inside a 0600 file. Drop the shell copies so nothing can
# leak them through a later expansion, a trap, or a `set -x` someone adds in anger.
PUSH_TOKEN=""; PUSH_USER=""

# 5. Send — bounded attempts, transient classes only. A 4xx (bad token, bad user key) is
#    NOT retried: it cannot succeed on a retry and every attempt burns the operator's
#    Pushover quota. The attempt counter is a validated integer (_num above), so the
#    loop cannot spin.
attempt=1; total=$(( 1 + NOTIFY_RETRIES )); result="unknown"; code=""
while (( attempt <= total )); do
  if command -v timeout >/dev/null 2>&1; then
    code="$(timeout -k 2 "$(( NOTIFY_MAX_TIME + 5 ))" curl --config "$CFG" 2>/dev/null)"; rc=$?
  else
    code="$(curl --config "$CFG" 2>/dev/null)"; rc=$?
  fi
  code="${code//[^0-9]/}"
  if (( rc == 0 )) && [[ $code =~ ^2[0-9][0-9]$ ]]; then
    result="ok"; break
  elif (( rc == 0 )) && [[ $code =~ ^4[0-9][0-9]$ ]]; then
    result="http-${code}"                     # terminal: bad credentials / bad request
    _log "pushover rejected the request (HTTP ${code}) — not retrying (a 4xx cannot succeed on a retry)"
    break
  elif (( rc == 0 )); then
    result="http-${code:-000}"                # 5xx / odd code — transient, retryable
  elif (( rc == 28 || rc == 124 || rc == 137 )); then
    result="timeout"                          # curl --max-time / outer timeout / SIGKILL
  elif (( rc == 6 || rc == 7 )); then
    result="unreachable"                      # DNS failure / connection refused
  else
    result="curl-rc-${rc}"
  fi
  if (( attempt >= total )); then break; fi
  _log "send attempt ${attempt}/${total} failed (${result}) — retrying in ${NOTIFY_RETRY_DELAY}s"
  sleep "$NOTIFY_RETRY_DELAY"
  attempt=$(( attempt + 1 ))
done

# 6. Latch + record. The latch is set on ATTEMPT (see step 2) so a `once` event is a
#    one-shot regardless of outcome. The journal entry lands LAST and unconditionally —
#    it is the authoritative record, and it must exist whether the tap landed or not.
if (( R_ONCE == 1 )); then
  install -d -m 0700 "$LATCH_DIR" 2>/dev/null && : > "$LATCH" 2>/dev/null || true
fi
if [[ $result == ok ]]; then _send_log ok ok "${code:-none}" "${attempt}/${total}"
else _send_log failed "$result" "${code:-none}" "${attempt}/${total}"; fi
_journal "route=pushover result=${result} http=${code:-none} attempts=${attempt}/${total} prio=${R_PRIO} scope=${SCOPE_KEY} ${_base}"
[[ $result == ok ]] || _log "NOTIFICATION NOT DELIVERED (${result}) — the record is in ${JOURNAL}; the lap is unaffected"
exit 0
