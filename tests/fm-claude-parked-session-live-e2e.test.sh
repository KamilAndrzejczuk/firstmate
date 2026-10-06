#!/usr/bin/env bash
# tests/fm-claude-parked-session-live-e2e.test.sh - default-on, token-free live
# guard for the parked-conversation handoff (fm_session_lock_parked_by_self in
# bin/fm-session-lock-lib.sh).
#
# Why this file exists: the handoff reads Claude Code's own live-session
# registry, ${CLAUDE_CONFIG_DIR:-~/.claude}/sessions/<pid>.json - the
# interactive client's parkedJobId and the background job's kind, jobId, and
# sessionId - plus the background engine's process shape. A Claude release can
# rename any of those without notice, and a stubbed registry can only confirm
# the field names already written into the stub. The portable counterpart in
# tests/fm-session-lock-ancestry.test.sh pins the logic itself in CI.
#
# This guard never starts, stops, attaches to, or messages a Claude session, so
# it spends no tokens, and it writes only under its own temp directory. It looks
# for a conversation already parked on this machine - a live interactive client
# whose entry names a background job, and that job's live engine - and runs the
# shipped predicate against those real processes and entries, with a scratch
# lock naming the client. The one substitution is where the ancestry walk
# starts: a hook fires below the engine, so the walk starts at the engine's own
# pid and classifies every hop with the library's real harness predicate.
# With no parked conversation it reports a skip naming what to do, and
# FM_CLAUDE_PARKED_LIVE=1 turns that skip into a failure. To create one, move a
# Claude Code conversation to the background, keep its terminal open, and re-run
# this guard after any Claude Code upgrade.
# shellcheck disable=SC2016 # single quotes are deliberate: the inner bash expands its own arguments
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CLAUDE_PARKED_LIVE claude jq

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/bin/fm-session-lock-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-parked-session-live)
SESSIONS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"
INSTALLED=$(claude --version 2>/dev/null | head -n 1)

# Print "<client> <engine> <job> <session-id> <version>" for every live parked
# pair, where <version> is the Claude Code version the engine's entry records.
parked_pairs() {
  local entry client job engine sid version
  for entry in "$SESSIONS"/*.json; do
    [ -f "$entry" ] && [ ! -L "$entry" ] || continue
    jq -r 'select(type == "object" and .kind == "interactive" and (.parkedJobId | type) == "string")
      | "\(.pid) \(.parkedJobId)"' "$entry" 2>/dev/null
  done | while read -r client job; do
    kill -0 "$client" 2>/dev/null || continue
    for entry in "$SESSIONS"/*.json; do
      [ -f "$entry" ] && [ ! -L "$entry" ] || continue
      jq -r --arg job "$job" 'select(type == "object" and .kind == "bg" and .jobId == $job)
        | "\(.pid) \(.sessionId) \(.version // "unknown")"' "$entry" 2>/dev/null
    done | while read -r engine sid version; do
      kill -0 "$engine" 2>/dev/null && printf '%s %s %s %s %s\n' "$client" "$engine" "$job" "$sid" "$version"
    done
  done
}

# The contiguous Claude run from pid $1 upward, as fm_harness_ancestry_pids
# would report it from a hook shell directly below that pid.
engine_ancestry() {  # <engine-pid>
  bash -c '
    . "$1"
    pid=$2
    while comm=$(ps -o comm= -p "$pid" 2>/dev/null); do
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      fm_harness_process_matches "$comm" "$args" || break
      printf "%s\n" "$pid"
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d " ")
      case "$pid" in ""|*[!0-9]*|0) break ;; esac
    done
  ' _ "$LIB" "$1"
}

# Run the shipped predicate as a hook below <engine> with <session-id>.
parked_as_engine() {  # <state> <engine-pid> <session-id> <ancestry>
  env CLAUDE_CODE_SESSION_ID="$3" CLAUDE_PID="$2" bash -c '
    . "$1"
    fm_session_lock_parked_by_self "$2" "$3" && printf "%s" "$FM_SESSION_LOCK_PARKED_FROM_PID"
  ' _ "$LIB" "$1" "$4"
}

checked=0
pairs=$(parked_pairs)
while read -r client engine job sid version; do
  [ -n "$client" ] || continue
  VERSION="Claude Code $version"
  pids=$(engine_ancestry "$engine")
  printf '%s\n' "$pids" | grep -qx "$engine" \
    || fail "$VERSION: background engine $engine for job $job is not classified as a Claude harness process"
  if printf '%s\n' "$pids" | grep -qx "$client"; then
    printf 'note: %s: client %s is an ancestor of engine %s, so ancestry already owns its lock\n' "$VERSION" "$client" "$engine"
    continue
  fi
  state="$TMP_ROOT/$engine/state"
  mkdir -p "$state"
  printf '%s\n' "$client" > "$state/.lock"
  printf 'client-fresh-id\n' > "$state/.lock-session"
  got=$(parked_as_engine "$state" "$engine" "$sid" "$pids") \
    || fail "$VERSION: background session $engine (job $job) was not recognised as the conversation its live client $client parked"
  [ "$got" = "$client" ] || fail "$VERSION: the handoff named client '$got', expected $client"
  if parked_as_engine "$state" "$engine" "$sid-not-this-session" "$pids" >/dev/null; then
    fail "$VERSION: a session id that is not the job's own was handed client $client's lock"
  fi
  checked=$((checked + 1))
  pass "$VERSION: live client $client hands its lock only to its background session $engine (job $job)"
done <<EOF
$pairs
EOF

if [ "$checked" -eq 0 ]; then
  if [ "${FM_CLAUDE_PARKED_LIVE:-}" = 1 ]; then
    fail "FM_CLAUDE_PARKED_LIVE=1 but no parked Claude conversation was found under $SESSIONS ($INSTALLED installed); move a conversation to the background, keep its terminal open, and re-run"
  fi
  printf 'skip: live: no parked Claude conversation under %s (%s installed); move a conversation to the background, keep its terminal open, and re-run\n' "$SESSIONS" "$INSTALLED"
fi
