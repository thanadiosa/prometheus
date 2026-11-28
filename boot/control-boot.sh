#!/bin/bash
#
# control-boot.sh — prometheus bootstrap, stage 3a (control-node PRE-REPO stub).
#
# THE PRE-REPO STUB FOR THE CONTROL NODE. Its whole job is to get this VM a git checkout
# and then get out of the way:
#
#     wait for the injected helper credential  →  pull the read-only deploy key  →
#     clone the repo  →  say WHICH COMMIT  →  exec <checkout>/bootstrap/control-init.sh
#
# Chain:  hook.sh (PVE console)  →  needle.sh (PVE host)  →  [this] (control node)
#         →  bootstrap/control-init.sh (from the clone)  →  run-pipeline.sh
#
# Run by provisioner-control-boot.service — the systemd unit the cloud-init snippet needle.sh
# injects installs and enables (see needle.sh step 3). It used to be a cloud-init runcmd line
# directly; it is a unit since issue #170 so that the credential wait and this script's own
# delivery can be retried, which a once-per-instance runcmd could not.
#
# ── WHY THIS FILE IS NOW SO SMALL (issues #169 / #283) ───────────────────────────────
# It used to be the whole of stage 3 — six secret pulls, two repo clones, a digest
# comparison of every helper-staged script against the checkout, and the pipeline hand-off,
# all running from a copy of itself that did NOT come from git. A fix committed to any of
# that was inert on a live estate until somebody re-staged the helper. The PVE half of the
# chain already removed that failure class (hook.sh clones and execs the checkout's
# needle.sh); #283 does the same here. Everything that can wait for a checkout now lives in
# bootstrap/control-init.sh and runs from git, where a push is enough.
#
# #283 also DELETES the drift detector #169's first pass added to this file — the digest
# comparison of every helper-staged script against the checkout, and its opt-in
# warn-vs-die environment gates, together with the list they walked. It was the
# right control for a large staged surface; with nothing left staged that does real work, the
# condition it detected can no longer arise, and a check that can only ever say "fine" is
# noise that has to be maintained.
#
# ── THE RULE FOR CHANGING THIS FILE ──────────────────────────────────────────────────
# It is DELIVERED to the node rather than cloned (see "how this file reaches the node"
# below), so a change here is not live until that delivery re-runs. That is exactly the cost
# #169 exists to remove, and the only reason it is tolerable is that this file is small and
# stable. If you find yourself adding a stage to it, the question to ask first is "can this
# run after the clone instead?" — the answer is almost always yes, and if it is, put it in
# bootstrap/control-init.sh where a push is enough.
#
# ── HOW THIS FILE REACHES THE NODE (the #283 fetch-vs-bake call) ─────────────────────
# needle.sh embeds THIS file — read out of the checkout it is itself running from — into the
# control node's cloud-init snippet, so the bytes that run here come from the same commit as
# the rest of the lap, with nothing staged on the helper and nothing baked into the image.
# The old path (fetch it off the helper with fetch-one.sh) survives as a FALLBACK in the boot
# chain, for a node whose snippet predates that change. Issue #284 audited whether it (and the
# helper staging entry that fills it) could be retired and concluded no — it is the only thing
# such a node can still boot from, so it stays deliberately.
#
# NOT baked into the control image, deliberately, even though the image is built ahead of
# time and baking is the obvious-looking answer: roles/bake-nextgen re-bakes the seed FROM
# THE RUNNING CONTROL NODE, so a baked copy would propagate itself generation to generation
# and go stale on a far SLOWER loop than the helper ever did — and the detector that would
# have caught that is the one this issue deletes. Cloud-init delivery has neither problem:
# needle.sh already has the checkout, so the copy it ships is by construction the commit the
# lap is running.
#
# Preconditions established by the earlier stages / the baked control image:
#   - /etc/provisioner/helper exists — the helper "user@host" (written by needle).
#   - /etc/provisioner/estate exists — WHICH estates/<name>/ to build (written by
#     needle; SPEC §14.6). Missing → the pipeline falls back to its default.
#   - /etc/provisioner/fetch-one.sh exists — the pre-lib transport primitive needle's
#     cloud-init wrote (key-first scp / password-fallback sftp, cipher/MAC pinned).
#   - The helper CREDENTIAL is INJECTED, not baked (issue #151): immediately after
#     starting this VM the PVE host pushes its OWN helper credential in over the
#     QEMU guest agent — the key at /etc/provisioner/helper-id or the password at
#     /etc/provisioner/helper-pass, with /etc/provisioner/helper-cred written last
#     as the "it is complete" sentinel. One credential, shared by host and
#     controller (operator decision, 2026-08-09), so the seed is GENERIC: the same
#     control.vma.zst works against a helper it has never seen. The wait for it is
#     bounded and fails loudly (see the credential block below).
#   - Docker + git are installed in the baked image (SPEC §2: control carries Docker +
#     the repo; tofu/ansible/restic run as pinned container images, not host-installed).
#   - Outbound network via vmbr0 (host connectivity; OPNsense is not up yet).
#
# What this script deliberately does NOT do: bake secrets into the image, reuse
# long-lived fleet keys, or configure the host OS network (that is Ansible's
# host-prep role, run BY the pipeline control-init.sh hands off to).
#
set -uo pipefail

# err-trap (#1719): this script runs where bootstrap/err-trap.sh is not (deployed, or before the repo exists), so the
# WARN-and-carry-on trap is inlined: name-only, saved stderr, set -E so functions inherit; it never stops the script.
set -E; exec {_et_fd}>&2 || _et_fd=2
trap 'case "${BASH_COMMAND%%[=[:space:]]*}" in "["|"[["|test|"((") ;; *) printf "WARN  %s:%s: unchecked command failed (exit %s), carrying on: %s (arguments not shown)\n" "${0##*/}" "$LINENO" "$?" "${BASH_COMMAND%%[=[:space:]]*}" >&"$_et_fd" ;; esac' ERR

# ── Layout ────────────────────────────────────────────────────────────────────
STATE_DIR="/etc/provisioner"
HELPER_FILE="${STATE_DIR}/helper"          # written by needle.sh
ESTATE_FILE="${STATE_DIR}/estate"          # written by needle.sh — which estate to build (SPEC §14.6)
SSH_DIR="${STATE_DIR}/ssh"
# The three BACKBONE VMIDs this lap is being built with (issue #224). needle.sh resolved them
# — from the operator's environment, from estates/<estate>/estate.tfvars, or from the
# 100/101/102 defaults — and wrote them into the cloud-init snippet, so they are FACTS about
# this lap rather than something to re-derive. Read only to make the diagnostics below name
# the right machine; the pipeline reads the same files itself and owns the real resolution.
# Absent (an older snippet) ⇒ the historical constants, which is what such a lap used.
CONTROL_VMID="$(tr -d '[:space:]' < "${STATE_DIR}/control-vmid" 2>/dev/null || true)"
CONTROL_VMID="${CONTROL_VMID:-101}"
DEPLOY_KEY="${SSH_DIR}/github_deploy"      # pulled from helper; read-only repo access
GIT_ASKPASS_HELPER="${STATE_DIR}/git-askpass.sh"
FETCH_ONE="${STATE_DIR}/fetch-one.sh"      # written by needle.sh's cloud-init snippet

# WHERE THE CHECKOUT LANDS. The same path the PVE host uses for the same repo, deliberately:
# one name for "the provisioner checkout" everywhere in the estate, so an operator debugging
# either box looks in the same place. Overridable for a test lap.
REPO_DIR="${PROVISIONER_REPO_DIR:-/opt/provisioner}"
REPO_URL="git@github.com:parrhasia/prometheus.git"
CONTROL_INIT="${REPO_DIR}/bootstrap/control-init.sh"   # what we hand off to
# WHICH VERSION THIS LAP BUILDS (issue #232) — written into this node's cloud-init snippet by
# needle.sh, out of the value hook.sh resolved from the estate's helper pointer and pinned the
# PVE host's own checkout at. Absent ⇒ nothing pinned ⇒ the newest code, which is what every
# node did before this issue and what an OLDER snippet (one written by a pre-#232 needle) still
# produces. That degradation is the graceful-degrade contract working: a missing artifact keeps
# the previous behaviour rather than failing.
VERSION_FILE="${STATE_DIR}/version"
# THE FULL COMMIT ID THE PVE HOST VERIFIED (review M4): needle.sh writes it into the same cloud-init snippet, from the value hook.sh
# checked the release signature of. The label above is only a NAME and can be moved between the PVE host's resolution and this
# node's; the id cannot. Absent / `none` (a snippet from before this existed, or a needle run by hand) keeps today's behaviour,
# said out loud, and the signature check below still applies to whatever commit ends up checked out.
BUILD_COMMIT_FILE="${STATE_DIR}/build-commit"
BUILD_TAG_KIND_FILE="${STATE_DIR}/build-tag-kind"   # which kind of signed tag the PVE host verified: gate | candidate (#1791)

# Helper-side root (must match what is placed on the helper "starter" area).
# Same REMOTE_DIR root as needle.sh; secrets live under it, never in git. needle.sh
# threads the (possibly confined) layout via /etc/provisioner/remote-dir; fall back to
# PROVISIONER_REMOTE_DIR / the default (empty = the helper login home). With the per-estate
# chroot (issue #75, SPEC §14) the account IS the estate, so the paths are chroot-relative
# (secrets/…) — no <estate> segment — matching genesis/needle/run-pipeline.
REMOTE_DIR_FILE="${STATE_DIR}/remote-dir"      # written by needle.sh's cloud-init snippet
# Env FIRST, file second — the same priority run-pipeline.sh settled on in #199, and by
# PRESENCE (`+x`), because empty is the chroot root, not "unset" (issue #204). This used to
# give the file priority over the env; harmless in practice (we export the resolved value
# below, so the two agreed), but the two orders drifting is how #199 happened in the first
# place. One rule for the whole chain.
if [[ -n ${PROVISIONER_REMOTE_DIR+x} ]]; then
  REMOTE_DIR="$PROVISIONER_REMOTE_DIR"
elif [[ -f $REMOTE_DIR_FILE ]]; then
  REMOTE_DIR="$(tr -d '[:space:]' < "$REMOTE_DIR_FILE")"
else
  REMOTE_DIR=""
fi

log() { printf '\n[control-boot] %s\n' "$*" >&2; }
die() { printf '\n[control-boot] ERROR: %s\n' "$*" >&2; exit 1; }

# ── Which version does this node build? (issue #232) ──────────────────────────
# Env FIRST, file second — the SAME priority as REMOTE_DIR above and the same one #199 settled
# on for the whole chain, so there is one rule and not two. `:-` and not `+x` here, unlike
# REMOTE_DIR: for the version an empty value and an unset one mean the same thing ("newest"),
# whereas for REMOTE_DIR empty is the chroot root and unset is "nobody told me" (issue #204).
#
# ref_is_sane is byte-for-byte the function in bootstrap/hook.sh, and that is deliberate rather
# than duplication that got away: the PVE host and this node must never disagree about what a
# version string is, and neither can source a shared file — both run BEFORE the checkout they
# are creating exists. This node re-validates rather than trusting what it was handed, because
# the value crossed a cloud-init drive to get here and the drive is a separate trust hop; it
# then becomes `git checkout` argv on this box and a systemd `Environment=` line for the
# PVE-upgrade resume unit.
ref_is_sane() {
  local r="${1:-}" t
  [[ -n $r ]] || return 1
  [[ $r == *..* ]] && return 1
  [[ $r =~ ^[A-Za-z0-9][A-Za-z0-9._/+-]{0,127}$ ]] || return 1
  # #1134: an operator-mistake guard for whole dotted-number names, not a trust boundary (a/0.2.0 just resolves as a branch).
  t="${r#refs/tags/}"; t="${t#tags/}"
  [[ $t =~ ^[vV]?[0-9]+\.[0-9]+(\.[0-9]+)*([-+].*)?$ && ! $t =~ ^[0-9]{2}\.(0[1-9]|1[0-2])\.(00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})$ ]] && return 1
  return 0
}

PROVISIONER_VERSION="${PROVISIONER_VERSION:-}"
version_where="the environment (PROVISIONER_VERSION)"
if [[ -z $PROVISIONER_VERSION && -f $VERSION_FILE ]]; then
  PROVISIONER_VERSION="$(head -n 1 "$VERSION_FILE" | tr -d '[:space:]')"
  version_where="this node's cloud-init snippet (${VERSION_FILE})"
fi
# The explicit unpin word. This branch is on the NORMAL path, not a courtesy: needle.sh writes
# `newest` into this file on every UNPINNED lap, deliberately, because the alternative (omit
# the write_files entry) would leave a copy BAKED INTO THE SEED by an earlier pinned lap
# untouched — roles/bake-nextgen bakes control.vma.zst from a running control node and its
# generalize pass scrubs identity, not this — and the node would then pin itself to another
# estate's version with nobody having asked. See the long note at needle.sh's version_entry.
# It also catches the two hand-driven cases: PROVISIONER_VERSION set in the environment for a
# re-run, and an operator hand-placing the file. Without this branch 'newest' would be resolved
# as a REF, find nothing, and kill the node for asking for the default.
case "$PROVISIONER_VERSION" in
  newest|NEWEST) PROVISIONER_VERSION=""; log "version says 'newest' (from ${version_where}) — building the repo's default branch" ;;
esac
if [[ -n $PROVISIONER_VERSION ]] && ! ref_is_sane "$PROVISIONER_VERSION"; then
  # NOT a fall-back to newest. A node labelled with one version that was built from another is
  # the exact failure issue #232 exists to remove, and it is invisible afterwards; a node that
  # refuses to boot is visible in the first minute. The boot chain unit retries, so this failure
  # is also recoverable the moment an operator corrects the value.
  die "$(printf 'the requested provisioner version %q is not a usable git ref.' "$PROVISIONER_VERSION")
It came from ${version_where}.
A version is a YY.MM.NNN tag (expected like 26.10.001; old names such as 0.2.0 are gone), a branch,
or a full commit sha: letters, digits and . _ / + - only, no leading '-', no '..', at most 128 characters.
NOT falling back to the newest code: building something other than the version this node is
labelled with is worse than not building at all."
fi
if [[ -n $PROVISIONER_VERSION ]]; then
  log "building provisioner version '${PROVISIONER_VERSION}' (from ${version_where})"
else
  log "no version pinned (no ${VERSION_FILE}, no PROVISIONER_VERSION) — building the newest code, as every node did before a version could be pinned"
fi

# ── #1127: "migrate again from the old system", for THIS run only ─────────────────────────
# needle.sh writes the ask (an item name, `all`, or `none`) into the snippet. It is deleted just
# before the hand-off below, so a retry of this script before then still sees it and no later
# run, and no seed baked from this node, ever does.
LEGACY_AGAIN_FILE="${STATE_DIR}/restore-legacy-again"
PROVISIONER_RESTORE_LEGACY_AGAIN="${PROVISIONER_RESTORE_LEGACY_AGAIN:-}"
if [[ -z $PROVISIONER_RESTORE_LEGACY_AGAIN && -f $LEGACY_AGAIN_FILE ]]; then
  PROVISIONER_RESTORE_LEGACY_AGAIN="$(head -n 1 "$LEGACY_AGAIN_FILE" | tr -d '[:space:]')"
fi
[[ $PROVISIONER_RESTORE_LEGACY_AGAIN == none ]] && PROVISIONER_RESTORE_LEGACY_AGAIN=""
if [[ -n $PROVISIONER_RESTORE_LEGACY_AGAIN && $PROVISIONER_RESTORE_LEGACY_AGAIN != all \
      && ( ! $PROVISIONER_RESTORE_LEGACY_AGAIN =~ ^[A-Za-z0-9_][A-Za-z0-9_-]{0,63}(,[A-Za-z0-9_][A-Za-z0-9_-]{0,63})*$ || ,${PROVISIONER_RESTORE_LEGACY_AGAIN}, == *,all,* ) ]]; then
  die "$(printf 'the "migrate again" request %q is not usable: item names separated by commas, or all.' "$PROVISIONER_RESTORE_LEGACY_AGAIN")"
fi
[[ -n $PROVISIONER_RESTORE_LEGACY_AGAIN ]] && log "this run was asked to migrate again from the old system: ${PROVISIONER_RESTORE_LEGACY_AGAIN}"

# ── #1504: "clear the pool a previous install left", for THIS run only ────────────────────
# Same shape as the ask above: needle.sh writes a pool name (or `none`) into the snippet; it is
# deleted just before the hand-off, so no later run and no seed baked from this node sees it.
CLEAR_POOL_FILE="${STATE_DIR}/clear-old-pool"
PROVISIONER_CLEAR_OLD_POOL="${PROVISIONER_CLEAR_OLD_POOL:-}"
if [[ -z $PROVISIONER_CLEAR_OLD_POOL && -f $CLEAR_POOL_FILE ]]; then
  PROVISIONER_CLEAR_OLD_POOL="$(head -n 1 "$CLEAR_POOL_FILE" | tr -d '[:space:]')"
fi
rm -f "$CLEAR_POOL_FILE"   # read once: the value lives in the environment from here, a retry or a seed never sees the file
[[ $PROVISIONER_CLEAR_OLD_POOL == none ]] && PROVISIONER_CLEAR_OLD_POOL=""
if [[ -n $PROVISIONER_CLEAR_OLD_POOL && ! $PROVISIONER_CLEAR_OLD_POOL =~ ^[A-Za-z][A-Za-z0-9_.:-]{0,63}$ ]]; then
  die "$(printf 'the "clear the old pool" request %q is not usable: a plain pool name.' "$PROVISIONER_CLEAR_OLD_POOL")"
fi
[[ -n $PROVISIONER_CLEAR_OLD_POOL ]] && log "this run was asked to clear the pool a previous install left: ${PROVISIONER_CLEAR_OLD_POOL}"

# ── Helper-fetch reliability: retry/backoff (review R3) ───────────────────────
# Wraps this script's ONE required helper pull so the most fragile part of the cold start —
# reaching the helper during the narrow first-boot window — SELF-HEALS against a transient
# helper/DNS blip rather than stranding the node idle.
#
# R3 knobs — env-overridable so a test lap can shorten the window. Defaults: 8 attempts,
# backoff 5→10→20→40→60→60→60 ≈ 4.5 min of grace before we FAIL LOUD.
RETRY_MAX_ATTEMPTS="${PROVISIONER_FETCH_RETRIES:-8}"
RETRY_BASE_DELAY="${PROVISIONER_FETCH_BASE_DELAY:-5}"     # seconds; doubles each miss
RETRY_MAX_DELAY="${PROVISIONER_FETCH_MAX_DELAY:-60}"      # per-attempt backoff cap

# Run "$@" with bounded, capped exponential-ish backoff until it succeeds or the attempt
# cap is hit; returns the wrapped command's success/failure. The CALLER owns fail-loud after
# the cap (it die()s on our nonzero return) — we NEVER proceed without a required artifact.
# The wrapped command MUST be idempotent; ours is (fetch-one.sh overwrites its dest).
retry_backoff() {
  local attempt=1 delay="$RETRY_BASE_DELAY"
  local rc
  while :; do
    "$@"; rc=$?
    (( rc == 0 )) && return 0
    # rc 2 = fetch-one.sh's "the helper REFUSED the credential" (crypt path). A refused password
    # is not a blip: every repeat is another failed login and the seedbox locks the account (#1201).
    if (( rc == 2 )); then log "the helper REFUSED the credential - not retrying (a repeat can lock the login); fix the helper password and reboot this node"; return 2; fi
    (( attempt >= RETRY_MAX_ATTEMPTS )) && return 1
    log "fetch attempt ${attempt}/${RETRY_MAX_ATTEMPTS} failed — helper may be transiently unreachable; retrying in ${delay}s"
    sleep "$delay"
    attempt=$(( attempt + 1 ))
    delay=$(( delay * 2 )); (( delay > RETRY_MAX_DELAY )) && delay="$RETRY_MAX_DELAY"
  done
}

# One fetch attempt, through the PRE-LIB primitive (issue #75). helper-lib.sh is NOT sourced
# here and NOT fetched: since #283 it comes from the checkout (control-init.sh sources it),
# and this file's single pre-repo pull does not justify staging a transport library on the
# helper to make it. fetch-one.sh is the same primitive the boot chain itself uses —
# cipher/MAC-pinned by needle for the seedbox class of helper, key-first with password
# fallback, and it reads every coordinate it needs straight out of /etc/provisioner, so there
# is nothing to thread into it. Args: <remote-path> <local-dest>.
fetch_one() {
  bash "$FETCH_ONE" "$1" "$2"
}

# ── 0. Preflight ──────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]]        || die "must run as root (systemd boot-chain context)"
[[ -f $HELPER_FILE ]]    || die "missing $HELPER_FILE — needle.sh should have written it"
for bin in ssh scp ssh-keygen git docker; do
  command -v "$bin" >/dev/null 2>&1 || die "required binary not found: $bin (expected in baked image)"
done

helper="$(tr -d '[:space:]' < "$HELPER_FILE")"
[[ $helper == *@* ]]     || die "helper is not user@host: '$helper'"
helper_host="${helper#*@}"

# Which estate this host builds (SPEC §14.6): threaded hook → needle → cloud-init.
# Real validation (does estates/<name>/ exist?) is the pipeline preflight's job —
# it has the repo. A missing file degrades to the pipeline's default, loudly.
if [[ -f $ESTATE_FILE ]]; then
  estate="$(tr -d '[:space:]' < "$ESTATE_FILE")"
  log "estate: ${estate}"
else
  estate=""
  log "WARN: ${ESTATE_FILE} missing (older needle snippet?) — pipeline will use its default estate"
fi
# #1772 (M13): the estate name becomes a secrets-folder path component; refuse anything but a plain
# lower-case name HERE, before any path is built (the one rule: bin/new-estate.sh, the orchestrator and estate_format all use it).
[[ -z ${estate:-} || ${estate} =~ ^[a-z][a-z0-9-]{0,30}$ ]] \
  || die "invalid estate name '${estate}' - must be a plain lower-case name (letters, digits, '-')"

# ── THE LAP WAS STARTED FOR THE WRONG ESTATE (issue #789) ─────────────────────
# THE BACKSTOP, not the primary check. hook.sh catches this pair on the PVE console before it
# fetches a single byte (see the long note there for the live failure on one estate this exists to
# replace); this copy is for the node whose hook PREDATES that check — a lap driven by an
# older console one-liner, or a re-run of this script by hand. The two facts arrive here in
# two files written side by side by needle.sh, ${ESTATE_FILE} and ${REMOTE_DIR_FILE}, and
# until now nothing ever read them together: on one estate one said `<estate>` and the other ended
# in `<other-estate>`, and the first thing to notice was the vault refusing a password that was
# entirely correct for the estate it had been fetched from.
#
# It runs HERE, before the deploy key, before the credential wait, and before anything under
# secrets/ is named — every one of those succeeds against the wrong estate's directory, which
# is precisely why the real fault surfaced so late and so wrongly attributed.
#
# foreign_estate_dir is byte-identical to the copy in bootstrap/hook.sh, for the same reason
# ref_is_sane() above is: the PVE host and this node must never disagree about what a foreign
# directory is, and neither can source a shared file — both run BEFORE the checkout exists.
# The rule, in one line: only a directory sitting in the estate-slot position of the helper's
# well-known parent is judged at all; a chroot root (empty), the parent itself and any custom
# layout pass through in silence, because a false refusal here strands a node that would
# otherwise have built.
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
if wrong_estate_dir="$(foreign_estate_dir "$estate" "$REMOTE_DIR")"; then
  remote_dir_where="${REMOTE_DIR_FILE}, written by needle.sh's cloud-init snippet"
  [[ -n ${PROVISIONER_REMOTE_DIR+x} ]] && remote_dir_where="PROVISIONER_REMOTE_DIR in this node's environment"
  die "this box says it is ${estate} but the seedbox directory it was pointed at is ${wrong_estate_dir}'s — the hook was started for the wrong estate; re-run it for ${estate}.
The directory is '${REMOTE_DIR}', from ${remote_dir_where}; the estate name is from ${ESTATE_FILE}.
Nothing has been fetched: this node would otherwise pull ${wrong_estate_dir}'s vault password and open ${estate}'s vault with it, and report that the vault password is wrong.
Fix it on the PVE HOST, not here — the pair is threaded hook → needle → this node's cloud-init — and re-run the hook for ${estate}."
fi

# Helper secrets are CHROOT-RELATIVE (per-estate chroot — issue #75): the SFTP account IS
# the estate, so secrets live directly under 'secrets' with NO ${estate} segment and no
# legacy-flat fallback (collapsed; the account boundary replaces the path namespacing).
SECRETS_REMOTE="${REMOTE_DIR:+${REMOTE_DIR}/}secrets"
DEPLOY_KEY_REMOTE="${SECRETS_REMOTE:+${SECRETS_REMOTE}/}github_deploy"

install -d -m 0700 "$STATE_DIR" "$SSH_DIR"

# The engine's state root, made HERE, before any role can make it by accident (#1830). Every folder under it keeps
# its own mode (0700 for the private ones), but a role that creates a 0700 sub-folder of a root that does not exist
# yet makes the ROOT 0700 too (ansible's `file` gives every folder it has to create the leaf's mode; `mkdir -p` does
# the same under umask 077). That is how a control node's state root came to be 0700 from its first build, shutting
# the build agent (an account of its own since #1754) out of the lock folder below it. 0711 = pass-through only:
# nothing in it is listable, and the sub-folders guard themselves. Runs as root (first boot), so root-owned.
install -d -m 0711 /var/lib/provisioner

# ── 1. The helper credential: INJECTED at first boot, never baked (issue #151) ─
# The image used to carry it — a baked /root/.ssh/id_ed25519 or a baked helper-pass — which
# bound one control.vma.zst to ONE helper: point an estate at a different helper and this
# node boots fine and then dies at the state push, looking like an unrelated fault. Operator
# decision (@amalthe, 2026-08-09): ONE credential, used by both the PVE host and the
# controller. The host — which already reaches the helper, that is how it pulled this image —
# pushes its own credential in over the QEMU guest agent right after starting us:
#   key helper      → ${STATE_DIR}/helper-id    (0600, private key)
#   password helper → ${STATE_DIR}/helper-pass  (0600, unchanged path, so every downstream
#                                                consumer — helper-lib, run-pipeline,
#                                                status-mirror — needs no change)
#   both            → ${STATE_DIR}/helper-cred  (sentinel, written LAST: 'key'|'password')
# It rides the guest agent and NOT cloud-init because the snippet is user-data on a readable
# drive and SPEC §6 keeps secrets out of it.
HELPER_CRED_FILE="${STATE_DIR}/helper-cred"      # sentinel — presence ⇒ credential complete
HELPER_ID_FILE="${STATE_DIR}/helper-id"          # injected private key (key helpers)
LEGACY_HELPER_ID="/root/.ssh/id_ed25519"         # pre-#151 BAKED key (fallback only)
# BOUNDED wait, and the bound is the point (the #58 lesson: no unbounded loop in the detached
# path). This is the LAST of the three waits for the same sentinel and by far the least
# important — needle's own agent wait and the guest chain's await-cred.sh both come first —
# so it keeps a plain literal rather than tracking needle's derived budget (issue #170):
# reaching this wait at all means every earlier gate already passed. Env-overridable so a test
# lap can shorten it, and so an operator re-running this script by hand can lengthen it.
CRED_WAIT_TIMEOUT="${PROVISIONER_CRED_WAIT_TIMEOUT:-300}"
CRED_WAIT_POLL="${PROVISIONER_CRED_WAIT_POLL:-2}"

# Wait for the sentinel, or give up at the deadline. Returns 0 once it is there, 1 at the
# cap. NORMALLY A NO-OP: the boot chain (/etc/provisioner/control-boot-chain.sh from needle's
# snippet, run by provisioner-control-boot.service) already waited for the same sentinel
# before it could even deliver this script, so by the time we run the credential is present
# and this returns on the first test. It exists for the two paths that skip that gate — a
# manual re-run of control-boot.sh, and a node booted from an OLDER cloud-init snippet —
# where the alternative is failing on the first helper pull with a message about the helper.
await_helper_credential() {
  local deadline=$(( SECONDS + CRED_WAIT_TIMEOUT )) next=0
  while (( SECONDS < deadline )); do
    [[ -s $HELPER_CRED_FILE ]] && return 0
    if (( SECONDS >= next )); then
      log "waiting for the PVE host to push the helper credential ($(( deadline - SECONDS ))s left)"
      next=$(( SECONDS + 30 ))
    fi
    sleep "$CRED_WAIT_POLL"
  done
  [[ -s $HELPER_CRED_FILE ]]
}

helper_cred_mode=""
if await_helper_credential; then
  helper_cred_mode="$(tr -d '[:space:]' < "$HELPER_CRED_FILE")"
  log "helper credential present (auth: ${helper_cred_mode}) — injected by the PVE host over the guest agent"
elif [[ -s "${STATE_DIR}/helper-pass" || -s $LEGACY_HELPER_ID ]]; then
  # ONE tolerated degradation: a pre-#151 seed booted by a post-#151 needle whose push
  # failed. It has a baked credential, so run on it rather than fail an estate that would
  # otherwise have worked — but say so, because that image is helper-specific by definition.
  log "WARN: no credential arrived from the PVE host within ${CRED_WAIT_TIMEOUT}s, but this image carries a LEGACY BAKED credential — proceeding on it (a seed from before the credential was handed over)"
else
  die "no helper credential after ${CRED_WAIT_TIMEOUT}s and none baked into this image.
The PVE host pushes it over the QEMU guest agent immediately after starting this VM; nothing arrived at ${HELPER_CRED_FILE}.
On the PVE host: 'journalctl -u provisioner-boot' (look for the [needle] credential hand-off lines) and 'qm agent ${CONTROL_VMID} ping'.
Failing here rather than waiting: without the credential this node cannot fetch one byte from the helper, and an unbounded wait would wedge the lap with nobody watching."
fi

# ── WHERE THIS NODE'S KEY IS, WHEN IT IS NOT AT helper-id (issues #911/#912) ──
# The injection puts the credential at helper-id / helper-pass and everything downstream
# reads it there. The one branch above that does NOT is the legacy baked key: it lives at
# ${LEGACY_HELPER_ID} and nothing in ${STATE_DIR} names it, so a consumer that reads the
# state dir alone — the log-export timer, the SPEC §16 status mirror — resolves no
# credential, exits 0 and ships nothing, quietly, for ever. Same POINTER file needle
# stages on the PVE host for the same reason (#734); both readers already honour it.
if [[ ! -s $HELPER_ID_FILE && ! -s "${STATE_DIR}/helper-pass" && -s $LEGACY_HELPER_ID ]]; then
  printf '%s\n' "$LEGACY_HELPER_ID" > "${STATE_DIR}/helper-key-path"
  chmod 0644 "${STATE_DIR}/helper-key-path"
  log "recorded ${STATE_DIR}/helper-key-path -> ${LEGACY_HELPER_ID} (legacy baked key; without it the timer-driven readers of ${STATE_DIR} find no credential and ship nothing)"
fi

# Pin the helper to IPv4 for every ssh/scp on this node. The bootstrap lifeline is
# IPv4-only (the control node has no IPv6 route before OPNsense exists), but the
# helper may be dual-stacked (an AAAA record). Without this, ssh/scp tries the
# helper's IPv6 address first and burns ~127s per connection on a dead SYN before
# falling back to IPv4 — observed on the production estate cold-start as a fixed ~135s
# stall on EACH secret pull. One ssh_config drop-in covers the deploy-key pull below,
# control-init.sh's remaining secret pulls AND run-pipeline's state push/pull (all use
# the ssh/scp CLI, which reads it).
install -d -m 0755 /etc/ssh/ssh_config.d
printf 'Host %s\n    AddressFamily inet\n' "$helper_host" \
  > /etc/ssh/ssh_config.d/00-provisioner-helper-ipv4.conf

# ── 2. Pull the ONE secret the clone needs: the GitHub deploy key ─────────────
# The rest of the secrets chain — the vault password (which unlocks every other secret: PVE
# API token, rclone/Dropbox creds, restic repo password), the PVE admin password, the tofu
# state passphrase, the Pushover credentials and the notify route table — is pulled by
# control-init.sh FROM THE CLONE (SPEC §6 "Secrets chain"). This one cannot wait: it is what
# makes the clone possible. Neither is ever baked into the image or written to cloud-init.
#
# Retried with capped backoff (review R3): a transient helper/DNS blip in this narrow
# first-boot window must self-heal, not strand the node. After the cap we die LOUD — never
# proceed without the artifact.
[[ -r $FETCH_ONE ]] || die "missing ${FETCH_ONE} — needle's cloud-init should have written it; without it this node has no way to reach the helper"
log "pulling GitHub deploy key from helper (${DEPLOY_KEY_REMOTE})"
retry_backoff fetch_one "$DEPLOY_KEY_REMOTE" "$DEPLOY_KEY" \
  || { rc=$?; rm -f "$DEPLOY_KEY"
       (( rc == 2 )) && die "the helper refused the credential while pulling the deploy key (${DEPLOY_KEY_REMOTE}); not retried, because repeated failed logins lock a seedbox account. Fix the helper password and reboot this node."
       die "could not pull the GitHub deploy key after ${RETRY_MAX_ATTEMPTS} attempts (${DEPLOY_KEY_REMOTE} on helper) — helper unreachable for the whole retry window, or the key is not staged (review R3).
This node cannot clone the provisioner repo without it, and there is no staged copy of the boot logic to fall back to."; }
[[ -s $DEPLOY_KEY ]] || { rm -f "$DEPLOY_KEY"; die "the deploy key fetched from ${DEPLOY_KEY_REMOTE} is EMPTY — re-stage it on the helper and reboot this node."; }
chmod 0600 "$DEPLOY_KEY"

# Authenticate git for this boot based on what the helper handed us at
# secrets/github_deploy — deploy keys are disabled org-wide (issue #10), so the credential
# is one of two shapes and we auto-detect. Byte-for-byte the same auto-detect the PVE host's
# entry script does, so the two boxes can never disagree about what the credential is:
#   • an SSH private key  → clone over SSH   (Option A: machine-user read key)
#   • anything else (PAT) → clone over HTTPS (Option B: fine-grained token). The build node
#                            only READS, so this is a READ-ONLY token on BOTH private repos
#                            (prometheus + landscapes). The read+write token lives ONLY as the
#                            copy job's Actions secret, never on estate hardware (issue #5
#                            audit finding #1). See docs/handbook/REPOS-AND-CREDENTIALS.md.
# A private key always begins with a PEM "-----BEGIN ... KEY-----" header; a PAT
# never does. In token mode we pass the secret via GIT_ASKPASS at runtime so it is
# NEVER written to any repo's .git/config — otherwise it would ride /opt/provisioner
# straight into the next-gen baked image (SPEC §6 "Baking exclusion").
# EXPORTED, because the exec at the bottom hands this environment to control-init.sh, which
# clones the OPTIONAL landscapes repo with the very same credential.
if head -c 64 "$DEPLOY_KEY" 2>/dev/null | grep -q -- '-----BEGIN'; then
  log "github credential is an SSH key — cloning over SSH"
  install -d -m 0700 /root/.ssh
  # github.com's PUBLISHED host keys, verbatim (#940). `ssh-keyscan` here was
  # trust-on-first-use at cold start: an on-path attacker substitutes the whole codebase,
  # which then runs as root on this box. They are LITERALS because nothing is checked out
  # yet; tests/github_host_keys.sh holds them byte-identical to
  # ansible/roles/dev-build-agent/files/github-host-keys and that file against GitHub's own
  # endpoint. Its own file, so no earlier accept-new entry can satisfy the connection.
  printf '%s\n' \
    'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' \
    'github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=' \
    'github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=' \
    > /root/.ssh/known_hosts_github
  chmod 0644 /root/.ssh/known_hosts_github
  export GIT_SSH_COMMAND="ssh -i ${DEPLOY_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/.ssh/known_hosts_github -o GlobalKnownHostsFile=/dev/null"
else
  log "github credential is a token — cloning over HTTPS"
  # Normalise (strip any trailing newline the transport left on it) so the token git sends is exact.
  printf '%s' "$(tr -d '[:space:]' < "$DEPLOY_KEY")" > "$DEPLOY_KEY"
  # URLs carry the username only; GIT_ASKPASS supplies the token → nothing secret on disk.
  REPO_URL="https://x-access-token@github.com/parrhasia/prometheus.git"
  printf '#!/usr/bin/env bash\nexec cat %q\n' "$DEPLOY_KEY" > "$GIT_ASKPASS_HELPER"
  chmod 0700 "$GIT_ASKPASS_HELPER"
  export GIT_ASKPASS="$GIT_ASKPASS_HELPER" GIT_TERMINAL_PROMPT=0
fi

# ── 3. Clone (or update) the provisioner repo — and SAY WHICH COMMIT ──────────
# The clone is REQUIRED and its failure KILLS the boot: there is no fallback copy any more,
# which is the entire point of issue #169 — a lap either runs the committed code or it does
# not run. git is left to stream its own output here, because when the lap really is dead a
# bare `fatal:` at the left margin is precisely the right signal (issue #138's convention:
# column 0 means the lap is dying, and it only keeps that meaning because every OPTIONAL step
# in this chain captures and indents its own).
#
# An existing checkout is UPDATED rather than re-cloned so a re-run on a node that already
# has one is cheap and non-destructive; `--ff-only` so a local edit made while debugging on
# the box is never silently discarded (it fails loudly instead, and the operator decides).
#
# ── THE PINNED PATH, AND THE TRAP IT HAD TO AVOID (issue #232) ───────────────────────
# `git pull --ff-only` CANNOT be the update command once a version can be pinned. A pinned lap
# leaves this checkout on a DETACHED HEAD, and the next boot's `pull --ff-only` then fails with
# "You are not currently on a branch" — which is the `die` below, i.e. a STRANDED CONTROL NODE,
# for a checkout that is in perfect health. So the update is fetch-based:
#   pinned    → fetch, resolve the ref, `checkout --detach`
#   unpinned  → fetch; then `pull --ff-only` if we are on a branch (today's behaviour,
#               unchanged), or `checkout --detach` back onto the default branch's tip if a
#               PREVIOUS pinned lap left us detached.
# The loud-on-local-edit property survives: `git checkout` refuses to clobber a modified file
# exactly as `--ff-only` refuses to discard a local commit.
#
# resolve_ref / default_ref are the SAME two functions bootstrap/hook.sh carries, kept
# identical on purpose — see ref_is_sane above for why the duplication is structural and not
# an oversight. Tags are tried first because a tag is the shape issue #233 mints and the only
# shape meant to be immutable; a bare `git rev-parse` would leave tag-vs-branch precedence to
# git and could resolve a stale local branch of the same name.
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

install -d -m 0755 "$(dirname "$REPO_DIR")" 2>/dev/null || true
if [[ -d "${REPO_DIR}/.git" ]]; then
  log "updating the provisioner checkout at ${REPO_DIR}"
  # --tags --force: a tag that MOVED upstream must move here too. Silently keeping the copy
  # fetched on an earlier boot would be the build-a-different-version-than-the-label failure
  # again, arrived at from the other side.
  git -C "$REPO_DIR" fetch --prune --tags --force origin \
    || die "git fetch failed for the existing checkout at ${REPO_DIR}.
Check outbound network/DNS to github.com from this node (OPNsense may not be up yet — this rides the bootstrap lifeline) and that the deploy key at ${DEPLOY_KEY_REMOTE} still grants READ on parrhasia/prometheus. Or remove ${REPO_DIR} and reboot this node to clone fresh."
  if [[ -z $PROVISIONER_VERSION ]] && git -C "$REPO_DIR" symbolic-ref --quiet HEAD >/dev/null 2>&1; then
    git -C "$REPO_DIR" pull --ff-only \
      || die "git pull failed for the existing checkout at ${REPO_DIR}.
A local modification or a diverged branch stops a fast-forward. Inspect it, or remove ${REPO_DIR} and reboot this node to clone fresh."
  fi
else
  log "cloning the provisioner repo into ${REPO_DIR}"
  # Same retry as the helper pulls (#1662): one reset connection must not cost the whole boot.
  # A failed try's half-made checkout is removed so the next clone starts clean - only the
  # directory this clone created, never one that was already there.
  _repo_preexisted=0; [[ -e $REPO_DIR || -L $REPO_DIR ]] && _repo_preexisted=1
  clone_once() {
    git clone "$REPO_URL" "$REPO_DIR" && return 0
    if (( ! _repo_preexisted )) && [[ -n $REPO_DIR && $REPO_DIR != / ]]; then rm -rf -- "$REPO_DIR"; fi
    return 1
  }
  retry_backoff clone_once \
    || die "git clone failed — this node could not fetch the provisioner code.
The boot chain runs the REPO's code, so there is no staged copy to fall back to.
Check, in this order:
  • outbound network / DNS from this node to github.com (OPNsense is not up yet — this rides the bootstrap lifeline)
  • the deploy key staged at ${DEPLOY_KEY_REMOTE} on the helper — is it still valid, and does it grant READ on parrhasia/prometheus?
  • git's own words above"
  # A fresh clone lands on the default branch, which IS "newest" — an unpinned boot needs
  # nothing more. A pinned one still fetches tags: `git clone` brings only the tags reachable
  # from the branches it cloned, and a release tag on a maintenance branch is not among them.
  [[ -n $PROVISIONER_VERSION ]] && { retry_backoff git -C "$REPO_DIR" fetch --tags --force origin >/dev/null 2>&1 || true; }
fi

# ── Pin the checkout at the requested version (issue #232) ────────────────────
if [[ -n $PROVISIONER_VERSION ]]; then
  pinned_sha="$(resolve_ref "$REPO_DIR" "$PROVISIONER_VERSION")" \
    || die "the provisioner version '${PROVISIONER_VERSION}' (from ${version_where}) does not exist in parrhasia/prometheus.
It was looked for as a tag, as a branch on origin, and as a commit sha — none resolved, after a full fetch.
NOT falling back to the newest code: this node's PVE host built its own half of the lap from '${PROVISIONER_VERSION}', so a controller on some other version is the split this issue exists to close."
  git -C "$REPO_DIR" checkout --detach "$pinned_sha" \
    || die "could not check out provisioner version '${PROVISIONER_VERSION}' (${pinned_sha}) in ${REPO_DIR}.
git refuses a checkout that would overwrite a locally modified file — deliberate, so a debugging edit on this node is never silently discarded. Inspect ${REPO_DIR}, or remove it and reboot this node to clone fresh."
  log "checkout pinned at version '${PROVISIONER_VERSION}' → ${pinned_sha}"
elif ! git -C "$REPO_DIR" symbolic-ref --quiet HEAD >/dev/null 2>&1; then
  # Detached with nothing pinned ⇒ a PREVIOUS boot pinned this node and this one did not. Move
  # it back onto the newest code rather than silently rebuilding last time's version — "the
  # pointer was removed and the node kept building the old code" is an invisible failure of
  # exactly the kind this issue is about.
  _newest="$(default_ref "$REPO_DIR")"
  log "this checkout is detached (a previous boot pinned a version) and nothing is pinned now — moving it back to ${_newest}"
  git -C "$REPO_DIR" checkout --detach "$_newest" \
    || die "could not move the detached checkout at ${REPO_DIR} back onto ${_newest}.
A locally modified file stops it. Inspect ${REPO_DIR}, or remove it and reboot this node to clone fresh."
  unset _newest
fi

# ── THE COMMIT RUN HERE IS THE ONE THE PVE HOST VERIFIED, AND IT IS SIGNED (review M4) ──────────────────────────────
# This node clones the repository AGAIN and runs the checkout as root on the machine that holds the vault password, so it needs
# the same two protections the hook has. (1) The commit is the full id the PVE host verified, not whatever the label resolves to
# now. (2) That commit must carry a gate tag signed by one of the release keys. The verification below is the hook's, copied
# byte for byte (tests/control_boot_build_signature.sh holds the two copies identical): neither file can source the other, both
# run before the checkout they judge exists. This script runs once per control node (the chain's once-only stamp), so no
# already-running node is affected by it; a node whose cloud-init predates this check has no id file and is judged by (2) alone.
_handed=""
if [[ -n ${PROVISIONER_BUILD_COMMIT:-} ]]; then _handed="$PROVISIONER_BUILD_COMMIT"
elif [[ -f $BUILD_COMMIT_FILE ]]; then _handed="$(head -n 1 "$BUILD_COMMIT_FILE" | tr -d '[:space:]')"; fi
if [[ $_handed =~ ^[0-9a-f]{40}$ ]]; then
  if [[ -n $PROVISIONER_VERSION ]]; then
    _label_sha="$(resolve_ref "$REPO_DIR" "$PROVISIONER_VERSION")" || _label_sha=""
    [[ $_label_sha == "$_handed" ]] \
      || die "the version '${PROVISIONER_VERSION}' now points at ${_label_sha:-nothing} but the PVE host verified and built ${_handed}.
The name moved between the two steps. NOT building either: the control node runs exactly the commit that was verified.
Nothing has been provisioned on this node. Fix the version (or retry the whole lap) once it is stable."
  fi
  git -C "$REPO_DIR" cat-file -e "${_handed}^{commit}" 2>/dev/null \
    || die "the commit the PVE host verified (${_handed}) is not in the clone this node made, so it cannot be built here.
Nothing has been provisioned on this node."
  git -C "$REPO_DIR" checkout --detach "$_handed" \
    || die "could not check out the verified commit ${_handed} in ${REPO_DIR}.
git refuses a checkout that would overwrite a locally modified file. Inspect ${REPO_DIR}, or remove it and reboot this node to clone fresh."
  log "checkout set to the commit the PVE host verified: ${_handed}"
else
  log "WARN: no verified commit id was handed over by the PVE host (${BUILD_COMMIT_FILE} absent or 'none') - building what the version resolves to; the release-signature check below still applies"
fi
unset _handed _label_sha
# WHICH KIND OF TAG THE PVE HOST VERIFIED, handed down like the id (#1791): this node accepts a candidate tag only when the host did, and the
# host did only for an estate whose own helper says it is a test estate. Nothing handed, junk, or `gate` = gate tags only (an older needle).
_handed_kind=""
if [[ -n ${PROVISIONER_BUILD_TAG_KIND:-} ]]; then _handed_kind="$PROVISIONER_BUILD_TAG_KIND"
elif [[ -f ${BUILD_TAG_KIND_FILE:-/nonexistent} ]]; then _handed_kind="$(head -n 1 "$BUILD_TAG_KIND_FILE" | tr -d '[:space:]')"; fi
_vbc_candidates_allowed() { [[ $_handed_kind == candidate ]]; }

HOOK_RELEASE_SIGNERS="$(printf '%s\n' \
  'release-signer-b ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAvrcTcKsT2ObIgB0XNc1Ui0tgY7VJxelZxhXPQT+i0v' \
  'release-signer-c ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFScXABmjMwGYwdM0faS75E9HVT9lC1KEyqo0hR+IxYN')"

# THE SECOND LIST: CANDIDATE-ONLY signers (#1833). The coding container's key (release-signer-a) signs candidate tags every day, so it is
# the key that is handled most often; it is accepted for `candidate/<sha>` ONLY. A gate tag signed with it is refused on every estate, test
# estate or not, with a reason naming the slot. The two lists are disjoint: a key on both is a mistake in this file and refuses EVERY
# commit (fail closed), as does a key listed twice. A key is moved between the lists, or withdrawn, by editing the blocks and
# re-publishing the mirror (docs/handbook/BUILD-SIGNATURE.md). Withdraw the last one by leaving the block with no key line: then no
# key is candidate-only (a hook with no candidate-only key still builds gate tags).
HOOK_CANDIDATE_SIGNERS="$(printf '%s\n' \
  'release-signer-a ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEcjxr8HRPqDwjGGSmmU2HwjGVeqlTjFB+yEd7YIX1j/')"

# ONE KIND OF TAG, judged: the tag gate/<sha> (a whole green gate run) or candidate/<sha> (a release signer froze the commit for a
# test build). Same call for both: the tag must be annotated, name exactly this commit under exactly its own name, and verify against
# the carried keys. A candidate's message must also say it is a CANDIDATE and must not say mutants=all, so a gate tag can never be
# passed off as a candidate nor the other way round (the header's own name is signed; a tag moved to another name does not count).
_vbc_tag_ok() {   # <repo_dir> <allowed-signers file> <gate|candidate> <full sha> -> rc 0, or the reason on stdout and rc 1
  local d="$1" allowed="$2" kind="$3" sha="$4" tag raw hobj htype hname vout vco slot msg
  local -a G=(git -C "$d" -c core.fsmonitor=false -c core.hooksPath=/dev/null)
  tag="${kind}/${sha}"
  # the tag is looked for fresh (it may have been made after this checkout was cloned); a failed fetch just leaves what is there to be judged
  "${G[@]}" fetch --quiet --force origin "+refs/tags/${tag}:refs/tags/${tag}" >/dev/null 2>&1 || true
  [[ "$("${G[@]}" cat-file -t "refs/tags/${tag}" 2>/dev/null)" == tag ]] \
    || { echo "there is no signed (annotated) tag ${tag} for this commit"; return 1; }
  raw="$("${G[@]}" cat-file tag "refs/tags/${tag}" 2>/dev/null)" || { echo "cannot read tag ${tag}"; return 1; }
  hobj="$(sed -n '1s/^object //p' <<<"$raw")"; htype="$(sed -n '2s/^type //p' <<<"$raw")"; hname="$(sed -n '3s/^tag //p' <<<"$raw")"
  [[ $htype == commit && $hobj == "$sha" && $hname == "$tag" ]] \
    || { echo "tag ${tag} does not name exactly this commit (it names ${htype:-?} ${hobj:-?} as ${hname:-?})"; return 1; }
  [[ "$("${G[@]}" rev-parse --verify --quiet "refs/tags/${tag}^{commit}" 2>/dev/null)" == "$sha" ]] \
    || { echo "tag ${tag} does not resolve to this commit"; return 1; }
  # (for a candidate the caller hands the file of release AND candidate-only keys; for a gate tag the file of RELEASE keys alone (#1833))
  vout="$("${G[@]}" -c gpg.format=ssh -c gpg.ssh.program=ssh-keygen -c gpg.program=false -c gpg.x509.program=false -c "gpg.ssh.allowedSignersFile=${allowed}" verify-tag "refs/tags/${tag}" 2>&1)" \
    || {
      # a gate tag that fails the release keys may still be signed by a candidate-only key: say so plainly, by the slot's name
      if [[ $kind == gate && -s "$(dirname "$allowed")/allowed-candidate-only" ]]; then
        vco="$("${G[@]}" -c gpg.format=ssh -c gpg.ssh.program=ssh-keygen -c gpg.program=false -c gpg.x509.program=false -c "gpg.ssh.allowedSignersFile=$(dirname "$allowed")/allowed-candidate-only" verify-tag "refs/tags/${tag}" 2>&1)" \
          && { slot="$(sed -n 's/^Good .* signature for \([A-Za-z0-9][A-Za-z0-9._@-]*\) with .*/\1/p' <<<"$vco" | head -n 1)"
               echo "tag ${tag} is signed by ${slot:-a candidate-only key}, a CANDIDATE-ONLY signer: that key may sign candidate tags, never a gate tag"; return 1; }
      fi
      echo "the signature on tag ${tag} is not from a release key: $(tr '\n' ' ' <<<"$vout" | cut -c1-160)"; return 1; }
  # the signed message is what sits between the header's blank line and the signature block; it is signed, so it cannot be edited
  msg="$(sed -n '/^$/,$p' <<<"$raw" | sed '/^-----BEGIN SSH SIGNATURE-----$/,$d')"
  if [[ $kind == candidate ]]; then
    ! grep -qx 'mutants=all' <<<"$msg" && grep -qx "candidate ${sha}" <<<"$msg" && grep -q 'CANDIDATE tag, not a gate pass' <<<"$msg" \
      || { echo "tag ${tag} is not a plain candidate tag (it must say it is a candidate and not a gate pass, and never mutants=all)"; return 1; }
  else
    # A GATE tag counts only when its run checked every suite's break-tests: bin/gate-tag-check.sh refuses a gate record without the
    # line mutants=all for the version cut, and a box must hold the same line (a signature by a release key on a run that skipped the
    # break-tests, or on a hand-made tag with another message, proves less than the gate says) (#1791)
    grep -qx 'mutants=all' <<<"$msg" \
      || { echo "tag ${tag} does not say mutants=all, so its gate run did not check every suite's break-tests"; return 1; }
  fi
  return 0
}

# the judging, with the scratch folder already made: on success prints which kind of tag backed the commit (gate or candidate) and
# returns 0; otherwise prints the reason and returns 1. A candidate tag counts only when _vbc_candidates_allowed says so (a test estate,
# defined by each script from its own trusted source; see docs/handbook/BUILD-SIGNATURE.md), and a gate tag is always tried first.
_vbc_judge() {   # <repo_dir> <allowed-signers file of the RELEASE keys; its folder also holds allowed-candidate and allowed-candidate-only>
  local d="$1" allowed="$2" sha kind why ok="" reasons="" rr lv st ignf
  local -a G=(git -C "$d" -c core.fsmonitor=false -c core.hooksPath=/dev/null)
  sha="$("${G[@]}" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)" && [[ $sha =~ ^[0-9a-f]{40}$ ]] \
    || { echo "the checkout has no readable commit"; return 1; }
  for kind in gate candidate; do
    # a gate tag is judged against the RELEASE keys alone; a candidate against release + candidate-only (#1833)
    if why="$(_vbc_tag_ok "$d" "$([[ $kind == candidate ]] && echo "$(dirname "$allowed")/allowed-candidate" || echo "$allowed")" "$kind" "$sha")"; then
      # a valid candidate tag counts only on a test estate; that question is asked (of the helper, on the hypervisor) only now, so a build
      # that has a gate tag, and a build with no valid tag at all, cost no extra login
      if [[ $kind == candidate ]] && ! _vbc_candidates_allowed; then
        reasons+="${reasons:+; }the commit has a valid candidate tag, but this estate builds gate tags only (it is not marked as a test estate)"; continue
      fi
      ok="$kind"; break
    fi
    reasons+="${reasons:+; }${why}"
  done
  [[ -n $ok ]] || { echo "$reasons"; return 1; }
  # the tree on disk is exactly the signed commit's
  # every one of these asks git a question, and a question git could not answer is NOT the answer "nothing found": the command's own exit
  # status is read first and a failure refuses (an empty output from a failed command used to read as a clean tree)
  rr="$("${G[@]}" for-each-ref refs/replace 2>/dev/null)" || { echo "git could not list the replace refs of ${d}, so the checkout cannot be judged"; return 1; }
  [[ -z $rr ]] \
    || { echo "the checkout carries replace refs, which can swap what git shows for what is signed"; return 1; }
  "${G[@]}" diff-index --quiet HEAD -- 2>/dev/null || { echo "a tracked file in ${d} differs from the signed commit"; return 1; }
  lv="$("${G[@]}" ls-files -v 2>/dev/null)" || { echo "git could not list the files of ${d}, so a hidden change cannot be ruled out"; return 1; }
  [[ -z "$(grep -v '^H ' <<<"$lv")" ]] \
    || { echo "a file in ${d} is hidden from git's change check (assume-unchanged / skip-worktree)"; return 1; }
  st="$("${G[@]}" status --porcelain --untracked-files=all 2>/dev/null)" || { echo "git could not read the state of ${d}, so the checkout cannot be judged"; return 1; }
  [[ -z $st ]] \
    || { echo "${d} holds files that are not in the signed commit"; return 1; }
  # IGNORED leftovers (a re-run on a checkout an earlier lap used): git status does not list them, and a script an earlier,
  # unchecked lap left behind in an ignored name would sit in the tree this lap runs from. Generated DATA the build legitimately
  # leaves in the checkout (.materialized/, .terraform/, key files) is not refused; anything a shell or interpreter could run is:
  # a script suffix, or any file with an execute bit.
  ignf="$(dirname "$allowed")/ignored-files"   # the list goes through a file in the scratch folder so the command's own exit status can be read
  "${G[@]}" ls-files -z -o -i --exclude-standard > "$ignf" 2>/dev/null || { echo "git could not list the ignored files of ${d}, so a runnable leftover cannot be ruled out"; return 1; }
  while IFS= read -r -d '' ign; do
    if [[ $ign =~ \.(sh|bash|py|pl|rb)$ || -x "${d}/${ign}" ]]; then
      echo "${d} holds an ignored file that could be run and is not in the signed commit"; return 1
    fi
  done < "$ignf"
  echo "$ok"
  return 0
}

verify_build_commit() {   # <repo_dir> → rc 0 only for a commit backed by a release-signed tag (prints gate or candidate); else the reason on stdout, rc 1
  local d="$1" scratch allowed line n=0 rc gmaj gmin
  export GIT_NO_REPLACE_OBJECTS=1
  # the verdict comes from git's own ssh-keygen against the carried keys and from nothing the caller's environment can inject: git reads extra
  # configuration from these variables (a gpg.ssh.program that always says yes would be one), and GIT_DIR/GIT_WORK_TREE would point every
  # call below at another repository. This runs in a subshell, so the caller's environment is untouched; no caller needs any of them.
  unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_DIR GIT_WORK_TREE
  command -v ssh-keygen >/dev/null 2>&1 || { echo "ssh-keygen is not installed, so no signature can be checked"; return 1; }
  # ssh signatures in git (gpg.format=ssh, allowedSignersFile, verify-tag) arrived in git 2.34; an older git cannot judge the tag at all
  read -r gmaj gmin < <(git --version 2>/dev/null | sed -n 's/^git version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p')
  { [[ ${gmaj:-0} -gt 2 ]] || { [[ ${gmaj:-0} -eq 2 && ${gmin:-0} -ge 34 ]]; }; } \
    || { echo "git ${gmaj:-?}.${gmin:-?} on this host is older than 2.34 and cannot verify ssh signatures; install a newer git (Debian 12 and Proxmox VE 8 carry one)"; return 1; }
  scratch="$(mktemp -d)" || { echo "no scratch folder for the signer list"; return 1; }
  chmod 0700 "$scratch"
  allowed="${scratch}/allowed-signers"; : > "$allowed"; : > "${scratch}/allowed-candidate-only"
  local seen="" key name
  while IFS= read -r line; do
    # exactly "<name> ssh-ed25519 <base64 key>"; anything else (a placeholder included) is not a key and counts for nothing
    if [[ $line =~ ^([A-Za-z0-9][A-Za-z0-9._@-]*)[[:space:]]+ssh-ed25519[[:space:]]+(AAAAC3NzaC1lZDI1NTE5[A-Za-z0-9+/]+=*)$ ]]; then
      name="${BASH_REMATCH[1]}"; key="${BASH_REMATCH[2]}"
      case " $seen " in *" $key "*) rm -rf "$scratch"; echo "the signer key of ${name} is listed twice (a key may be on one list only); this hook refuses every commit until that is fixed"; return 1 ;; esac
      seen+="$key "
      printf '%s namespaces="git" ssh-ed25519 %s\n' "$name" "$key" >> "$allowed"; n=$((n + 1))
    fi
  done <<< "$HOOK_RELEASE_SIGNERS"
  while IFS= read -r line; do
    if [[ $line =~ ^([A-Za-z0-9][A-Za-z0-9._@-]*)[[:space:]]+ssh-ed25519[[:space:]]+(AAAAC3NzaC1lZDI1NTE5[A-Za-z0-9+/]+=*)$ ]]; then
      name="${BASH_REMATCH[1]}"; key="${BASH_REMATCH[2]}"
      case " $seen " in *" $key "*) rm -rf "$scratch"; echo "the signer key of ${name} is on both the release list and the candidate-only list (or listed twice); this hook refuses every commit until that is fixed"; return 1 ;; esac
      seen+="$key "
      printf '%s namespaces="git" ssh-ed25519 %s\n' "$name" "$key" >> "${scratch}/allowed-candidate-only"
    fi
  done <<< "${HOOK_CANDIDATE_SIGNERS:-}"
  # the candidate file = release keys + candidate-only keys
  cat "$allowed" "${scratch}/allowed-candidate-only" > "${scratch}/allowed-candidate"
  if (( n == 0 )); then echo "this hook carries no release keys"; rc=1
  else _vbc_judge "$d" "$allowed"; rc=$?; fi
  rm -rf "$scratch"
  return $rc
}

export GIT_NO_REPLACE_OBJECTS=1
if ! _sig_why="$(verify_build_commit "$REPO_DIR")"; then
  die "the commit to be built is not signed by the release key (${_sig_why}).
Nothing from the checkout was run and nothing has been provisioned on this node."
fi
_build_kind="${_sig_why:-}"
unset _sig_why
if [[ $_build_kind == candidate ]]; then
  log "WARNING: THIS IS A CANDIDATE BUILD: this node builds a commit signed only as a candidate by a release signer, which is NOT a passed gate run (the PVE host's estate is a test estate)."
fi
unset _build_kind

[[ -r $CONTROL_INIT ]] \
  || die "the checkout at ${REPO_DIR} has no bootstrap/control-init.sh — either the clone is incomplete or this commit predates the split of the boot logic into the repo.
${PROVISIONER_VERSION:+A version is pinned ('${PROVISIONER_VERSION}'), so this is most likely a ref from BEFORE the boot chain was split — pick a newer version, or unpin the estate.
}Remove ${REPO_DIR} and reboot this node."

# THE DRIFT-VISIBILITY BYPRODUCT ISSUE #169 ASKED FOR, and the assertion that this change
# actually did what it claims: this line names a commit, and everything after it ran from
# that commit. NEVER A GATE on its own failure — a checkout we cannot interrogate still
# boots; it is just less reconstructable afterwards.
REPO_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null)" || REPO_COMMIT=""
REPO_COMMIT_DESC="$(git -C "$REPO_DIR" log -1 --format='%h %cI %s' 2>/dev/null)" || REPO_COMMIT_DESC=""
if [[ -n $REPO_COMMIT ]]; then
  log "running the provisioner repo at ${REPO_COMMIT_DESC:-$REPO_COMMIT} (${REPO_DIR}) — version=${PROVISIONER_VERSION:-newest} — this is the code this node executes, not a copy staged on the helper"
else
  log "WARN: cloned/updated ${REPO_DIR} but could not read its commit (git rev-parse failed) — the lap continues UNIDENTIFIED"
fi

# ── 4. Hand off to the checkout's control-init ────────────────────────────────
# `exec`, not a child process, and that is load-bearing in two ways:
#   • this environment — every PROVISIONER_* and every git-auth var exported above — is
#     inherited, so control-init.sh clones landscapes with the same credential and resolves
#     the same helper layout, with no --setenv list to keep in sync;
#   • there is no second process to leak, and nothing after this line can run.
# control-init.sh sources helper-lib.sh from ITS OWN directory ($(dirname "$0")), which is
# ${REPO_DIR}/bootstrap — from git, at the commit named above. That is the whole trick: the
# code and the files it sources arrive together.
export PROVISIONER_REPO_DIR="$REPO_DIR"
export PROVISIONER_REPO_COMMIT="$REPO_COMMIT"
# The version this node was ASKED for (issue #232) — empty means "newest" and is exported as
# such, so control-init.sh and run-pipeline.sh read one stated answer rather than each
# re-reading ${VERSION_FILE}. run-pipeline.sh puts it in the PVE-upgrade resume unit's
# Environment=, which is how the pin survives the reboot in the middle of a lap.
export PROVISIONER_VERSION
export PROVISIONER_RESTORE_LEGACY_AGAIN   # #1127: this run only
export PROVISIONER_CLEAR_OLD_POOL         # #1504: this run only
export PROVISIONER_REMOTE_DIR="$REMOTE_DIR"   # the helper layout needle threaded to us
export PROVISIONER_HELPER="$helper"
[[ -n $estate ]] && export PROVISIONER_ESTATE="$estate"   # WHICH estate to build (SPEC §14.6)

rm -f "$LEGACY_AGAIN_FILE"   # #1127: consumed; the exported value carries it from here
rm -f "$CLEAR_POOL_FILE"     # #1504: consumed likewise
log "handing off to the checkout's control-init: ${CONTROL_INIT}"
# shellcheck disable=SC2093 # deliberate: the die below is the exec-failed fallback, not dead code
exec /bin/bash "$CONTROL_INIT"

# Unreachable: exec replaces this process. Reaching it means /bin/bash could not start the
# checkout's control-init — an error, not a resting state.
die "could not exec ${CONTROL_INIT} — the checkout is present but unrunnable"
