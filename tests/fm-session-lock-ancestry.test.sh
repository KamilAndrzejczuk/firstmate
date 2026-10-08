#!/usr/bin/env bash
# tests/fm-session-lock-ancestry.test.sh - session-lock harness identity
# (bin/fm-session-lock-lib.sh).
#
# Two layers. The unit cases drive the library's own functions behind a
# deterministic fake ps, so both platforms' reporting semantics are covered from
# either host: macOS reports argv[0] in `ps -o comm=`, while procps on Linux
# reports the kernel exec name and ignores argv[0] entirely. The end-to-end cases
# run the REAL Stop auto-arm inside real process trees whose shapes differ only
# in how the per-session process is named and what its parent is. Those trees are
# orphaned before the hook fires, so the ancestry walk terminates inside the
# fixture and can never escape into the session running this suite.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-ancestry)
fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-session-lock-lib.sh"

# Claude Code's native installer names the per-session executable by its version,
# so the harness identity has to survive a basename that says nothing.
CLAUDE_VERSION_DIR="$TMP_ROOT/claude-install/share/claude/versions"
mkdir -p "$CLAUDE_VERSION_DIR"
ln -s /bin/bash "$CLAUDE_VERSION_DIR/2.1.220"
VERSIONED_CLAUDE="$CLAUDE_VERSION_DIR/2.1.220"

FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/claude"
NAMED_CLAUDE="$FAKEBIN/claude"

# --- unit layer: identity behind a deterministic process table ---------------

# Run one library expression with <fakebin> shadowing ps. kill is stubbed so
# liveness questions are decided by the process table alone (FM_TEST_KILL_RC=1
# makes every pid dead). The suite itself may run inside a Claude session whose
# CLAUDE_CODE_SESSION_ID and CLAUDE_PID would leak into the expression, so both
# are scrubbed and only FM_TEST_SESSION_ID and FM_TEST_CLAUDE_PID reach it.
# Claude's live-session registry is likewise pinned to FM_TEST_CLAUDE_CONFIG_DIR,
# an empty directory unless a case provides one, never the real ~/.claude.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  local -a session_env=()
  [ -z "${FM_TEST_SESSION_ID:-}" ] || session_env+=("CLAUDE_CODE_SESSION_ID=$FM_TEST_SESSION_ID")
  [ -z "${FM_TEST_CLAUDE_PID:-}" ] || session_env+=("CLAUDE_PID=$FM_TEST_CLAUDE_PID")
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID ${session_env[@]+"${session_env[@]}"} \
    CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-$TMP_ROOT/no-claude-config}" \
    PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    kill() { return \${FM_TEST_KILL_RC:-0}; }
    $expr
  " "$LIB"
}

test_version_named_session_is_identified_on_both_platforms() {
  local dir fakebin shape got
  dir="$TMP_ROOT/version-named"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_CLAUDE_SHAPE:-linux}" in
  700:comm=:linux) printf '%s\n' '2.1.220' ;;
  700:args=:linux) printf '%s\n' '/opt/claude/versions/2.1.220 --resume' ;;
  700:comm=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220' ;;
  700:args=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220 --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '700\n' > "$dir/state/.lock"

  for shape in linux macos; do
    got=$(FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
      || fail "$shape: the version-named session was not found in the ancestry at all"
    [ "$got" = 700 ] || fail "$shape: ancestry resolved '$got', expected the version-named session pid 700"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      || fail "$shape: a live version-named session was not recognized as a harness"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
      || fail "$shape: the session holding the lock did not recognize itself as the owner"
  done
  pass "session-lock: a version-named Claude Code session is identified from its install path and argv[0]"
}

# A harness that is pid 1 of its own PID namespace - a container, or the
# `codex sandbox` this shape was verified in - used to be invisible: the walk
# stopped as soon as the NEXT pid was 1, so the one process that identifies the
# session was never examined and the session could not recognize its own lock.
test_harness_at_namespace_pid1_is_examined() {
  local dir fakebin got
  dir="$TMP_ROOT/namespace-pid1"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  1:comm=) printf '%s\n' "${FM_TEST_PID1_COMM:-claude}" ;;
  1:args=) printf '%s\n' "${FM_TEST_PID1_COMM:-claude}" ;;
  1:ppid=) printf '%s\n' 0 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/fm-watch.sh' ;;
  *:ppid=) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '1\n' > "$dir/state/.lock"

  # Non-vacuity: with a host-shaped pid 1 the same table must find nothing, so
  # this case cannot pass by the walk matching everything it reaches.
  if FM_TEST_PID1_COMM=systemd lib_eval "$fakebin" 'fm_harness_ancestry_pid' >/dev/null 2>&1; then
    fail "a host-shaped pid 1 was read as a harness process"
  fi

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "the harness at namespace pid 1 was not found in the ancestry at all"
  [ "$got" = 1 ] || fail "ancestry resolved '$got', expected the namespace harness pid 1"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the session holding the lock at namespace pid 1 did not recognize itself as the owner"
  pass "session-lock: a harness that is pid 1 of its own namespace is examined, not skipped"
}

test_ordinary_paths_are_never_harness_processes() {
  local dir fakebin shape
  dir="$TMP_ROOT/ordinary-paths"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_PATH_SHAPE:-hookdir}" in
  810:comm=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh' ;;
  810:args=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh --quiet' ;;
  810:comm=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner' ;;
  810:args=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner --once' ;;
  810:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-watch-arm.sh' ;;
  *:ppid=:*) printf '%s\n' 810 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '810\n' > "$dir/state/.lock"

  # Identity may be read from an executable path, but only from whole path
  # components: anything merely living under ~/.claude, and any component that
  # merely starts with a harness name, must stay outside the harness identity.
  for shape in hookdir piprefix; do
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
      fail "$shape: an ordinary script path was treated as a harness process"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 810'; then
      fail "$shape: an ordinary script path passed the harness-liveness predicate"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
      fail "$shape: an ordinary script path claimed the home's session lock"
    fi
  done
  pass "session-lock: ordinary script paths under a harness directory are not harness processes"
}

test_harness_beyond_a_gap_never_owns_the_lock() {
  local dir fakebin got
  dir="$TMP_ROOT/gap"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  900:comm=) printf '%s\n' claude ;;
  900:args=) printf '%s\n' 'claude' ;;
  900:ppid=) printf '%s\n' 910 ;;
  910:comm=) printf '%s\n' bash ;;
  910:args=) printf '%s\n' 'bash tests/run.sh' ;;
  910:ppid=) printf '%s\n' 920 ;;
  920:comm=) printf '%s\n' claude ;;
  920:args=) printf '%s\n' 'claude' ;;
  920:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 900 ;;
esac
SH
  chmod +x "$fakebin/ps"

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "the contiguous harness run was not resolved"
  [ "$got" = 900 ] || fail "ancestry crossed a non-harness gap, resolved '$got' instead of 900"
  printf '920\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "an unrelated harness beyond a non-harness gap was accepted as this session's lock owner"
  fi
  printf '900\n' > "$dir/state/.lock"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the contiguous harness run did not recognize its own lock"
  pass "session-lock: ownership stops at the first non-harness gap above the contiguous run"
}

test_competing_version_named_session_is_seen_as_live() {
  local dir fakebin
  dir="$TMP_ROOT/competing"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  600:comm=) printf '%s\n' '2.1.220' ;;
  600:args=) printf '%s\n' '/opt/claude/versions/2.1.220' ;;
  600:ppid=) printf '%s\n' 1 ;;
  650:comm=) printf '%s\n' claude ;;
  650:args=) printf '%s\n' claude ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 650 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # pid 600 is a different live session that holds the lock; this process
  # descends from 650 instead. Treating 600 as dead would let this session
  # reclaim a live competitor's home.
  printf '600\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a lock held outside this ancestry was claimed as this session's own"
  fi
  lib_eval "$fakebin" 'fm_harness_pid_alive 600' \
    || fail "a live competing version-named session was classified as a dead lock owner"
  pass "session-lock: a live version-named session holding the lock is not mistaken for a stale owner"
}

# A background Claude session's process table. The hook fires inside
# `claude bg-spare` (710), whose parent is `claude bg-pty-host` (720). With the
# transient daemon gone the pty-host is reparented to launchd, so the contiguous
# claude-named run from the hook ends at 720 and the live front-end 700 that
# holds the lock is no longer an ancestor at all. FM_TEST_DAEMON_PRESENT=1 puts
# the daemon (730) back between 720 and 700: the healthy topology.
write_background_session_ps() {  # <fakebin>
  cat > "$1/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_DAEMON_PRESENT:-0}" in
  700:comm=:*) printf '%s\n' claude ;;
  700:args=:*) printf '%s\n' 'claude --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  730:comm=:*) printf '%s\n' claude ;;
  730:args=:*) printf '%s\n' 'claude daemon run --origin transient' ;;
  730:ppid=:*) printf '%s\n' 700 ;;
  720:comm=:*) printf '%s\n' 'claude bg-pty-host' ;;
  720:args=:*) printf '%s\n' 'claude bg-pty-host /tmp/pty.sock 120 40 -- claude --bg-spare' ;;
  720:ppid=:1) printf '%s\n' 730 ;;
  720:ppid=:*) printf '%s\n' 1 ;;
  710:comm=:*) printf '%s\n' 'claude bg-spare' ;;
  710:args=:*) printf '%s\n' 'claude bg-spare /tmp/claim.sock' ;;
  710:ppid=:*) printf '%s\n' 720 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 710 ;;
esac
SH
  chmod +x "$1/ps"
}

owned() {  # <fakebin> <state>
  lib_eval "$1" "fm_session_lock_owned_by_self '$2'"
}

foreign_owner() {  # <fakebin> <state>  -> prints the foreign pid
  lib_eval "$1" "fm_session_lock_foreign_owner_live '$2' && printf '%s' \"\$FM_SESSION_LOCK_FOREIGN_OWNER_PID\""
}

test_same_session_id_owns_a_recycled_background_chain() {
  local dir fakebin state got
  dir="$TMP_ROOT/background-session"
  fakebin=$(fm_fakebin "$dir")
  state="$dir/state"
  mkdir -p "$state"
  write_background_session_ps "$fakebin"
  printf '700\n' > "$state/.lock"
  printf 'S1\n' > "$state/.lock-session"

  # The divergence itself, so none of the verdicts below can be vacuous: with
  # the daemon gone the front-end is not an ancestor, with it back it is.
  if lib_eval "$fakebin" 'fm_harness_ancestry_pids' | grep -qx 700; then
    fail "the recycled chain still reached the front-end, so the id cases would prove nothing"
  fi
  FM_TEST_DAEMON_PRESENT=1 lib_eval "$fakebin" 'fm_harness_ancestry_pids' | grep -qx 700 \
    || fail "the healthy chain did not reach the front-end"

  # 1. The session's own id from its model-loop process: owned, not foreign.
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state" \
    || fail "the same session's trusted id did not own the lock after the helper chain was recycled"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null; then
    fail "the session's own live front-end was reported as a foreign owner despite the matching id"
  fi
  # 2. A different id: the existing refusal, naming the live owner.
  if FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a different session id claimed a live owner's lock"
  fi
  got=$(FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state") \
    || fail "a different session id did not see the live owner as foreign"
  [ "$got" = 700 ] || fail "the foreign owner pid was '$got', expected 700"
  # 3. The trust gate: the right id carried by a CLAUDE_PID outside the run.
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 owned "$fakebin" "$state"; then
    fail "an id whose CLAUDE_PID is outside the current Claude run was trusted"
  fi
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 foreign_owner "$fakebin" "$state" >/dev/null \
    || fail "an untrusted id suppressed the foreign-owner verdict"
  printf 'S1:x\n' > "$state/.lock-session"
  FM_TEST_SESSION_ID='S1:x' FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state" \
    || fail "a trusted id containing a colon did not own the lock"
  if FM_TEST_SESSION_ID='S1:x' FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null; then
    fail "a matching id containing a colon was reported as a foreign owner"
  fi
  printf 'S1\r' > "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a recorded id containing a carriage return was treated as a session id"
  fi
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null \
    || fail "a carriage-return sidecar suppressed the foreign-owner verdict"
  printf 'S1\n' > "$state/.lock-session"
  # 4. No id at all: the legacy ancestry verdict, unchanged.
  if owned "$fakebin" "$state"; then
    fail "with no session id the recycled chain claimed the lock"
  fi
  foreign_owner "$fakebin" "$state" >/dev/null \
    || fail "with no session id the live owner was not reported as foreign"
  # 5. The healthy chain owns by ancestry whatever the environment says.
  FM_TEST_DAEMON_PRESENT=1 FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state" \
    || fail "ancestry membership lost to a different session id"
  FM_TEST_DAEMON_PRESENT=1 owned "$fakebin" "$state" \
    || fail "ancestry membership lost with no session id"
  if FM_TEST_DAEMON_PRESENT=1 FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null; then
    fail "an ancestor was reported as a foreign owner"
  fi
  # 6. Never fail open: no sidecar, a symlinked sidecar, and a dead recorded pid
  # are all ancestry-only, so the dead one is left for the ordinary reclaim.
  rm -f "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a lock with no recorded session id was owned through the environment id"
  fi
  printf 'S1\n' > "$dir/elsewhere"
  ln -s "$dir/elsewhere" "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a symlinked sidecar was trusted"
  fi
  rm -f "$state/.lock-session"
  printf 'S1\n' > "$state/.lock-session"
  if FM_TEST_KILL_RC=1 FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a same-session lock whose recorded pid is dead was owned instead of left for reclaim"
  fi
  pass "session-lock: a trusted same-session id keeps owning a recycled background chain, and nothing weaker does"
}

test_anchor_pid_is_the_model_loop_process_only_for_a_trusted_id() {
  local dir fakebin got
  dir="$TMP_ROOT/background-anchor"
  fakebin=$(fm_fakebin "$dir")
  write_background_session_ps "$fakebin"

  got=$(FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for a trusted id"
  [ "$got" = 710 ] || fail "a trusted id anchored '$got', expected the model-loop process 710"
  got=$(lib_eval "$fakebin" 'fm_session_lock_anchor_pid') || fail "no anchor pid was resolved without an id"
  [ "$got" = 720 ] || fail "without an id the anchor was '$got', expected the outermost pid 720"
  got=$(FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for an untrusted id"
  [ "$got" = 720 ] || fail "an untrusted id anchored '$got', expected the outermost pid 720"
  got=$(FM_TEST_DAEMON_PRESENT=1 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for the healthy chain"
  [ "$got" = 700 ] || fail "the healthy chain without an id anchored '$got', expected the outermost pid 700"
  got=$(FM_TEST_DAEMON_PRESENT=1 FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for the healthy chain with a trusted id"
  [ "$got" = 710 ] || fail "the healthy chain with a trusted id anchored '$got', expected 710 rather than the front-end"
  pass "session-lock: a trusted id anchors the lock on the model-loop process, anything else on the outermost pid"
}

# A conversation Claude Code moved to the background, as observed on Claude Code
# 2.1.289 on macOS. The terminal client 6372 recorded the lock and stays alive on
# its own tty. The conversation now runs in a detached engine (53013, a
# version-named `--fork-session --resume` process under a new session id) whose
# pty host (52125) is parented to launchd, so every hook fires below 53013 and
# 52125 and never reaches 6372. 7000 is an unrelated live interactive session.
write_parked_session_ps() {  # <fakebin>
  cat > "$1/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
engine=/Users/u/.local/share/claude/versions/2.1.289
host=/Users/u/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude
case "$pid:$field" in
  6372:comm=|7000:comm=) printf '%s\n' claude ;;
  6372:args=|7000:args=) printf '%s\n' claude ;;
  6372:ppid=|7000:ppid=) printf '%s\n' 70722 ;;
  70722:comm=) printf '%s\n' -zsh ;;
  70722:args=) printf '%s\n' -zsh ;;
  70722:ppid=) printf '%s\n' 1 ;;
  53013:comm=) printf '%s\n' "$engine" ;;
  53013:args=) printf '%s\n' "$engine --session-id E1 --fork-session --resume /tmp/C0.jsonl" ;;
  53013:ppid=) printf '%s\n' 52125 ;;
  52125:comm=) printf '%s\n' "$host" ;;
  52125:args=) printf '%s\n' "$host --bg-pty-host /tmp/cc-daemon/pty/E1.sock 179 63 -- $engine" ;;
  52125:ppid=) printf '%s\n' 1 ;;
  1:comm=) printf '%s\n' /sbin/launchd ;;
  1:args=) printf '%s\n' /sbin/launchd ;;
  1:ppid=) printf '%s\n' 0 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=) printf '%s\n' 53013 ;;
esac
SH
  chmod +x "$1/ps"
}

# Claude's live-session registry entry for one pid: <dir> <pid> <json>.
write_claude_session_entry() {
  mkdir -p "$1/sessions"
  printf '%s\n' "$3" > "$1/sessions/$2.json"
}

parked() {  # <fakebin> <state>
  lib_eval "$1" "fm_session_lock_parked_by_self '$2'"
}

# Not a handoff: <fakebin> <state> <label> <session-id> <claude-pid> <owner>.
# The live owner must keep the ordinary foreign-owner verdict.
expect_not_parked() {
  local fakebin=$1 state=$2 label=$3 got
  if FM_TEST_SESSION_ID=$4 FM_TEST_CLAUDE_PID=$5 parked "$fakebin" "$state" >/dev/null; then
    fail "$label: a lock the session cannot prove it continues was handed over"
  fi
  got=$(FM_TEST_SESSION_ID=$4 FM_TEST_CLAUDE_PID=$5 foreign_owner "$fakebin" "$state") \
    || fail "$label: the live owner was not reported as foreign"
  [ "$got" = "$6" ] || fail "$label: the foreign owner pid was '$got', expected $6"
}

test_parked_client_lock_is_handed_to_its_background_session() {
  local dir fakebin nojq state config got
  dir="$TMP_ROOT/parked-session"
  fakebin=$(fm_fakebin "$dir")
  nojq=$(fm_fakebin "$dir/nojq")
  state="$dir/state"
  config="$dir/claude-config"
  mkdir -p "$state"
  write_parked_session_ps "$fakebin"
  write_parked_session_ps "$nojq"
  printf '#!/usr/bin/env bash\nexit 2\n' > "$nojq/jq"
  chmod +x "$nojq/jq"
  printf '6372\n' > "$state/.lock"
  # The client re-keyed to a fresh id of its own when its conversation left.
  printf 'C1\n' > "$state/.lock-session"
  write_claude_session_entry "$config" 6372 \
    '{"pid":6372,"sessionId":"C0","kind":"interactive","parkedJobId":"f44b1372"}'
  write_claude_session_entry "$config" 53013 \
    '{"pid":53013,"sessionId":"E1","kind":"bg","jobId":"f44b1372"}'
  write_claude_session_entry "$config" 7000 \
    '{"pid":7000,"sessionId":"X1","kind":"interactive"}'
  export FM_TEST_CLAUDE_CONFIG_DIR="$config"

  # The divergence itself: neither ownership signal holds, so every verdict
  # below is decided by the registry link alone.
  got=$(FM_TEST_SESSION_ID=E1 FM_TEST_CLAUDE_PID=53013 lib_eval "$fakebin" 'fm_harness_ancestry_pids' | tr '\n' ' ')
  [ "$got" = '53013 52125 ' ] || fail "the engine's ancestry was '$got', expected '53013 52125 '"
  if FM_TEST_SESSION_ID=E1 FM_TEST_CLAUDE_PID=53013 owned "$fakebin" "$state"; then
    fail "the engine owned the client's lock outright, so the handoff cases would prove nothing"
  fi

  # 1. The reported case: the lock's client parked exactly this background job.
  FM_TEST_SESSION_ID=E1 FM_TEST_CLAUDE_PID=53013 parked "$fakebin" "$state" \
    || fail "the background session was not recognised as the continuation of the client holding lock 6372"
  if got=$(FM_TEST_SESSION_ID=E1 FM_TEST_CLAUDE_PID=53013 foreign_owner "$fakebin" "$state"); then
    fail "the session's own parked client $got was reported as a foreign live owner"
  fi

  # 2. Every weaker combination keeps the ordinary foreign-owner verdict.
  expect_not_parked "$fakebin" "$state" "no session id" '' '' 6372
  expect_not_parked "$fakebin" "$state" "an untrusted id" E1 6372 6372
  expect_not_parked "$fakebin" "$state" "a different trusted id" E2 53013 6372
  if FM_TEST_SESSION_ID=E1 FM_TEST_CLAUDE_PID=53013 parked "$nojq" "$state" >/dev/null; then
    fail "the handoff was decided without a working jq"
  fi
  write_claude_session_entry "$config" 6372 \
    '{"pid":6372,"sessionId":"C0","kind":"interactive","parkedJobId":"0ther000"}'
  expect_not_parked "$fakebin" "$state" "a client parked into a different job" E1 53013 6372
  write_claude_session_entry "$config" 6372 \
    '{"pid":6372,"sessionId":"C2","kind":"interactive"}'
  expect_not_parked "$fakebin" "$state" "a client that took up another conversation" E1 53013 6372
  write_claude_session_entry "$config" 6372 \
    '{"pid":6372,"sessionId":"C0","kind":"bg","parkedJobId":"f44b1372"}'
  expect_not_parked "$fakebin" "$state" "a lock owner that is not an interactive client" E1 53013 6372
  write_claude_session_entry "$config" 6372 \
    '{"pid":9999,"sessionId":"C0","kind":"interactive","parkedJobId":"f44b1372"}'
  expect_not_parked "$fakebin" "$state" "a client entry describing another pid" E1 53013 6372
  write_claude_session_entry "$config" 6372 \
    '{"pid":6372,"sessionId":"C0","kind":"interactive","parkedJobId":"f44b1372"}'
  write_claude_session_entry "$config" 53013 \
    '{"pid":53013,"sessionId":"E9","kind":"bg","jobId":"f44b1372"}'
  expect_not_parked "$fakebin" "$state" "a job entry running another session id" E1 53013 6372
  write_claude_session_entry "$config" 53013 \
    '{"pid":53013,"sessionId":"E1","kind":"interactive","jobId":"f44b1372"}'
  expect_not_parked "$fakebin" "$state" "a model-loop process that is not a background job" E1 53013 6372
  rm -f "$config/sessions/53013.json"
  expect_not_parked "$fakebin" "$state" "no registry entry for the model-loop process" E1 53013 6372
  printf '%s\n' '{"pid":53013,"sessionId":"E1","kind":"bg","jobId":"f44b1372"}' > "$dir/elsewhere.json"
  ln -s "$dir/elsewhere.json" "$config/sessions/53013.json"
  expect_not_parked "$fakebin" "$state" "a symlinked registry entry" E1 53013 6372
  rm -f "$config/sessions/53013.json"
  write_claude_session_entry "$config" 53013 \
    '{"pid":53013,"sessionId":"E1","kind":"bg","jobId":"f44b1372"}'
  FM_TEST_SESSION_ID=E1 FM_TEST_CLAUDE_PID=53013 parked "$fakebin" "$state" >/dev/null \
    || fail "restoring the registry link did not restore the handoff"
  printf '7000\n' > "$state/.lock"
  expect_not_parked "$fakebin" "$state" "an unrelated live interactive session" E1 53013 7000
  # A dead client is the ordinary stale-owner reclaim, not a handoff.
  printf '6372\n' > "$state/.lock"
  if FM_TEST_KILL_RC=1 FM_TEST_SESSION_ID=E1 FM_TEST_CLAUDE_PID=53013 parked "$fakebin" "$state" >/dev/null; then
    fail "a dead client's lock was treated as a live handoff"
  fi
  # A lock already inside this ancestry is plain ownership, never a handoff.
  printf '53013\n' > "$state/.lock"
  FM_TEST_SESSION_ID=E1 FM_TEST_CLAUDE_PID=53013 owned "$fakebin" "$state" \
    || fail "the engine did not own a lock naming its own model-loop pid"
  if FM_TEST_SESSION_ID=E1 FM_TEST_CLAUDE_PID=53013 parked "$fakebin" "$state" >/dev/null; then
    fail "a lock this session already owns was reported as a handoff"
  fi
  unset FM_TEST_CLAUDE_CONFIG_DIR
  pass "session-lock: a client's lock is handed only to the background session Claude records it parked into"
}

# --- end-to-end layer: the real Stop auto-arm in real process trees ----------

install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-path-lib.sh" "$dir/bin/fm-path-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/fm-cursor-lib.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$dir/bin/fm-supervision-engine-lib.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
  # The fixture arm written here stands in for the watcher arm, so the home opts out
  # of the supervision host a Claude home otherwise runs by default.
  mkdir -p "$dir/config"
  : > "$dir/config/supervision-host-off"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# A primary home with one task in flight, so the hook's scope and supervision-need
# gates both pass and only identity decides the outcome.
make_primary_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  install_autoarm_scripts "$dir"
  # The process that fires the hook records its own pid as the session lock
  # owner, exactly as a real session does at session start.
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FIXTURE_ORPHAN_HERE:-0}" = 1 ]; then
  i=0
  while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
    sleep 0.05
    i=$((i + 1))
  done
fi
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/hook.rc"
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
"$FM_SESSION_BIN" "$FM_HOME/session.sh"
exit 0
SH
  chmod +x "$dir/session.sh" "$dir/daemon.sh"
}

# Start the fixture tree detached from this suite's own process tree: the
# launcher exits immediately, so the tree is reparented to init and the ancestry
# walk terminates inside the fixture. Returns once the hook has recorded its exit
# code.
run_fixture_tree() {  # <dir> <session-bin> [<daemon-bin>]
  local dir=$1 session_bin=$2 daemon_bin=${3:-} i
  if [ -n "$daemon_bin" ]; then
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
      FM_HOME="$dir" FM_SESSION_BIN="$session_bin" FM_FIXTURE_ORPHAN_HERE=0 \
      bash -c '"$0" "$1" &' "$daemon_bin" "$dir/daemon.sh"
  else
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
      FM_HOME="$dir" FM_FIXTURE_ORPHAN_HERE=1 \
      bash -c '"$0" "$1" &' "$session_bin" "$dir/session.sh"
  fi
  i=0
  while [ "$i" -lt 400 ] && [ ! -s "$dir/state/hook.rc" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/state/hook.rc" ] || fail "the fixture hook never finished"
}

hook_rc() {
  tr -d '[:space:]' < "$1/state/hook.rc"
}

epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

test_e2e_version_named_session_claims_the_home() {
  local dir
  dir="$TMP_ROOT/e2e-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named session"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "no claim was recorded, got: $(epoch_outcome "$dir")"
  pass "session-lock e2e: a version-named session claims the home and arms supervision"
}

test_e2e_daemon_parented_session_claims_the_home() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-parented"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$NAMED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  [ -n "$session_pid" ] && [ "$session_pid" != "$daemon_pid" ] \
    || fail "fixture did not produce a distinct daemon and session: session=$session_pid daemon=$daemon_pid"
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  expect_code 2 "$(hook_rc "$dir")" "a session parented by a harness-named daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a daemon-parented session"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  pass "session-lock e2e: a session parented by a harness-named daemon claims the home and arms supervision"
}

test_e2e_daemon_parented_version_named_session_keeps_its_lock() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  [ "$lock_after" != "$daemon_pid" ] \
    || fail "the live session's lock was reclaimed as stale and rewritten to the shared daemon pid $daemon_pid"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session under a daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named daemon-parented session"
  pass "session-lock e2e: a version-named session under a harness-named daemon keeps its own lock"
}

# --- end-to-end layer: a background session whose helper chain is recycled ---
#
# The topology the four issue reports (#3902, #2314, #3398, #4066) recorded with
# real process listings: a front-end that acquired the lock, a transient daemon
# under it, the pty-host the daemon spawned, and the bg-spare inside the pty-host
# that runs the model loop and therefore fires every hook. Every fixture process
# is the fake claude, so the ancestry walk sees a contiguous claude-named run
# exactly as in production, and the tree is orphaned before use. The daemon is
# then ended while the front-end stays alive - the recycling that breaks the run
# above the pty-host - and the spare fires the real Stop auto-arm, the real
# turn-end guard, and the real lock script once per phase under a chosen hook
# environment, recording every verdict for the assertions below.

BG_FIXTURE_PIDS=()
reap_background_fixture() {
  local pid
  for pid in ${BG_FIXTURE_PIDS[@]+"${BG_FIXTURE_PIDS[@]}"}; do
    kill -TERM "$pid" 2>/dev/null || true
  done
}
trap 'reap_background_fixture; fm_test_cleanup' EXIT

make_background_session_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  # The whole bin, because the real turn-end guard composes far more of it than
  # the auto-arm alone; only the arm is replaced by the recording stub above.
  cp -R "$ROOT/bin" "$dir/bin"
  install_autoarm_scripts "$dir"
  # Every fixture script ends in an explicit exit so bash can never tail-exec the
  # script under test in place of the fake claude, which would collapse the
  # chain the assertions depend on.
  cat > "$dir/frontend.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/frontend-pid"
CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/frontend-lock.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/frontend-lock.rc"
"$FM_FIXTURE_CLAUDE" "$FM_HOME/daemon.sh" &
disown
while [ ! -e "$FM_HOME/state/stop-frontend" ]; do sleep 0.05; done
exit 0
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
exec -a 'claude bg-pty-host' "$FM_FIXTURE_CLAUDE" "$FM_HOME/ptyhost.sh" &
while :; do sleep 0.1; done
exit 0
SH
  cat > "$dir/ptyhost.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/ptyhost-pid"
exec -a 'claude bg-spare' "$FM_FIXTURE_CLAUDE" "$FM_HOME/spare.sh" &
while [ ! -e "$FM_HOME/state/stop-spare" ]; do sleep 0.1; done
exit 0
SH
  cat > "$dir/spare.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/spare-pid"
n=1
while [ ! -e "$FM_HOME/state/stop-spare" ]; do
  req="$FM_HOME/state/fire-$n"
  if [ -f "$req" ]; then
    out="$FM_HOME/state/phase-$n"
    mkdir -p "$out"
    unset CLAUDE_CODE_SESSION_ID CLAUDE_PID
    # shellcheck disable=SC1090
    . "$req"
    ( . "$FM_HOME/bin/fm-session-lock-lib.sh" && fm_harness_ancestry_pids ) > "$out/ancestry" 2>/dev/null
    printf '%s\n' '{"session_id":"fixture","stop_hook_active":true}' \
      | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" > "$out/hook.out" 2>&1
    printf '%s\n' "$?" > "$out/hook.rc"
    printf '%s\n' '{"session_id":"fixture","stop_hook_active":true}' \
      | "$FM_HOME/bin/fm-turnend-guard.sh" --claude > "$out/guard.out" 2>&1
    printf '%s\n' "$?" > "$out/guard.rc"
    "$FM_HOME/bin/fm-lock.sh" > "$out/lock.out" 2>&1
    printf '%s\n' "$?" > "$out/lock.rc"
    cp "$FM_HOME/state/.lock" "$out/lock-after"
    [ ! -e "$FM_HOME/state/.lock-session" ] || cp "$FM_HOME/state/.lock-session" "$out/session-after"
    : > "$out/done"
    n=$((n + 1))
  fi
  sleep 0.05
done
exit 0
SH
  chmod +x "$dir/frontend.sh" "$dir/daemon.sh" "$dir/ptyhost.sh" "$dir/spare.sh"
}

wait_for_file() {  # <path> <what>
  local i=0
  while [ "$i" -lt 400 ] && [ ! -s "$1" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$1" ] || fail "background-session fixture never produced $2"
}

fire_phase() {  # <dir> <n> <hook-environment-script>
  local dir=$1 n=$2
  printf '%s\n' "$3" > "$dir/state/fire-$n.tmp"
  mv "$dir/state/fire-$n.tmp" "$dir/state/fire-$n"
  wait_for_file "$dir/state/phase-$n/hook.rc" "phase $n"
  local i=0
  while [ "$i" -lt 400 ] && [ ! -e "$dir/state/phase-$n/done" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$dir/state/phase-$n/done" ] || fail "background-session fixture never finished phase $n"
}

phase_value() {  # <dir> <n> <file>
  tr -d '[:space:]' < "$1/state/phase-$2/$3"
}

arm_count() {  # <dir>
  [ -e "$1/state/arm-ran" ] || { printf '0'; return; }
  wc -l < "$1/state/arm-ran" | tr -d ' '
}

# The recycled chain must still be treated as the owner: arm, no diagnostic,
# lock accepted, line 1 untouched while the recorded pid lives, sidecar bytes
# untouched. An owned actionable close records two arm invocations - the
# foreground arm plus the handling successor the hook starts before the rewake -
# so the cumulative <expected-arms> grows by two for every owned phase.
expect_phase_owned() {  # <dir> <n> <expected-arms> <expected-lock-pid> <label>
  local dir=$1 n=$2 arms=$3 lock_pid=$4 label=$5
  expect_code 2 "$(phase_value "$dir" "$n" hook.rc)" "$label: the Stop auto-arm did not rewake"
  [ "$(arm_count "$dir")" = "$arms" ] || fail "$label: expected $arms arm(s), got $(arm_count "$dir")"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "$label: no rewake claim was recorded, got: $(epoch_outcome "$dir")"
  expect_code 0 "$(phase_value "$dir" "$n" guard.rc)" "$label: the turn-end guard did not allow the stop"
  if grep -q 'OWNED BY ANOTHER LIVE SESSION' "$dir/state/phase-$n/guard.out"; then
    fail "$label: the turn-end guard took the foreign-owner exit: $(cat "$dir/state/phase-$n/guard.out")"
  fi
  expect_code 0 "$(phase_value "$dir" "$n" lock.rc)" "$label: fm-lock.sh refused the session's own lock: $(cat "$dir/state/phase-$n/lock.out")"
  [ "$(phase_value "$dir" "$n" lock-after)" = "$lock_pid" ] \
    || fail "$label: lock line 1 is $(phase_value "$dir" "$n" lock-after), expected $lock_pid"
  cmp -s "$dir/state/phase-$n/session-after" "$dir/sidecar-initial" \
    || fail "$label: the session sidecar is not byte-identical to the one the owner wrote"
}

# Not the owner: no arm, the guard's foreign-owner diagnostic naming the live
# owner, and the lock refusal naming both the owner pid and its recorded id.
# The auto-arm's stand-down is visible once per standing-down session (exit 2
# with a notice naming the owner) and silent afterwards (exit 0, no output).
expect_phase_foreign() {  # <dir> <n> <expected-arms> <owner-pid> <label> <hook-rc>
  local dir=$1 n=$2 arms=$3 owner=$4 label=$5 hook_rc=$6
  expect_code "$hook_rc" "$(phase_value "$dir" "$n" hook.rc)" "$label: the Stop auto-arm did not stand down as expected"
  if [ "$hook_rc" = 2 ]; then
    grep -q "STOOD DOWN.*pid $owner, session S1" "$dir/state/phase-$n/hook.out" \
      || fail "$label: the stand-down notice did not name the owner: $(cat "$dir/state/phase-$n/hook.out")"
  elif [ -s "$dir/state/phase-$n/hook.out" ]; then
    fail "$label: a repeated stand-down printed: $(cat "$dir/state/phase-$n/hook.out")"
  fi
  [ "$(arm_count "$dir")" = "$arms" ] || fail "$label: a non-owner armed: $(arm_count "$dir") arm(s), expected $arms"
  expect_code 0 "$(phase_value "$dir" "$n" guard.rc)" "$label: a non-owner Stop did not end safely"
  grep -q "OWNED BY ANOTHER LIVE SESSION.*lock owner pid $owner" "$dir/state/phase-$n/guard.out" \
    || fail "$label: the guard did not report the live owner $owner: $(cat "$dir/state/phase-$n/guard.out")"
  expect_code 1 "$(phase_value "$dir" "$n" lock.rc)" "$label: fm-lock.sh accepted a lock this session does not own"
  grep -q "another live firstmate session holds the lock (pid $owner, session S1)" "$dir/state/phase-$n/lock.out" \
    || fail "$label: the refusal did not name the owner pid and recorded session: $(cat "$dir/state/phase-$n/lock.out")"
  [ "$(phase_value "$dir" "$n" lock-after)" = "$owner" ] || fail "$label: a non-owner rewrote the lock"
}

test_e2e_background_session_keeps_its_lock_across_a_recycled_chain() {
  local dir frontend daemon ptyhost spare i
  dir="$TMP_ROOT/e2e-background-session"
  make_background_session_home "$dir"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_FIXTURE_CLAUDE="$NAMED_CLAUDE" FM_POLL=1 FM_HEARTBEAT=999999 \
    FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0 \
    bash -c '"$0" "$1" &' "$NAMED_CLAUDE" "$dir/frontend.sh"
  wait_for_file "$dir/state/frontend-lock.rc" "the front-end's lock result"
  wait_for_file "$dir/state/spare-pid" "the bg-spare"
  frontend=$(tr -d '[:space:]' < "$dir/state/frontend-pid")
  daemon=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  ptyhost=$(tr -d '[:space:]' < "$dir/state/ptyhost-pid")
  spare=$(tr -d '[:space:]' < "$dir/state/spare-pid")
  BG_FIXTURE_PIDS+=("$frontend" "$daemon" "$ptyhost" "$spare")
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/frontend-lock.rc")" "the front-end could not acquire the lock: $(cat "$dir/state/frontend-lock.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$frontend" ] \
    || fail "the front-end's lock names $(cat "$dir/state/.lock"), expected its own pid $frontend"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = S1 ] \
    || fail "the front-end did not record its trusted session id beside the lock"
  cp "$dir/state/.lock-session" "$dir/sidecar-initial"

  # Phase 1: the healthy contiguous chain, the session's own id.
  fire_phase "$dir" 1 'export CLAUDE_CODE_SESSION_ID=S1; export CLAUDE_PID=$$'
  grep -qx "$frontend" "$dir/state/phase-1/ancestry" || fail "the healthy chain did not reach the front-end"
  expect_phase_owned "$dir" 1 2 "$frontend" "healthy chain"

  # Recycle the bridge: the daemon ends, the pty-host is reparented to init, and
  # the front-end that holds the lock stays alive.
  kill -TERM "$daemon"
  i=0
  while [ "$i" -lt 200 ] && { kill -0 "$daemon" 2>/dev/null || [ "$(ps -o ppid= -p "$ptyhost" 2>/dev/null | tr -d ' ')" != 1 ]; }; do
    sleep 0.05
    i=$((i + 1))
  done
  [ "$(ps -o ppid= -p "$ptyhost" 2>/dev/null | tr -d ' ')" = 1 ] || fail "the pty-host was not reparented to init after the daemon ended"
  kill -0 "$frontend" 2>/dev/null || fail "the front-end died with the daemon, so the recycled case cannot be exercised"

  # Phase 2: the same session id over the broken chain - the reported drift.
  fire_phase "$dir" 2 'export CLAUDE_CODE_SESSION_ID=S1; export CLAUDE_PID=$$'
  if grep -qx "$frontend" "$dir/state/phase-2/ancestry"; then
    fail "the recycled chain still reached the front-end, so this phase proves nothing"
  fi
  grep -qx "$spare" "$dir/state/phase-2/ancestry" || fail "the hook's ancestry lost its own spare"
  expect_phase_owned "$dir" 2 4 "$frontend" "recycled chain, same session"

  # Phases 3-5: a different id, the right id from a CLAUDE_PID outside the run,
  # and no id at all are each a non-owner over the same broken chain. A trusted
  # id anchors the first on the spare; the untrusted and absent ids both anchor
  # on the pty-host, so the third is the second's episode and stays silent.
  fire_phase "$dir" 3 'export CLAUDE_CODE_SESSION_ID=S2; export CLAUDE_PID=$$'
  expect_phase_foreign "$dir" 3 4 "$frontend" "recycled chain, different session" 2
  fire_phase "$dir" 4 "export CLAUDE_CODE_SESSION_ID=S1; export CLAUDE_PID=$frontend"
  expect_phase_foreign "$dir" 4 4 "$frontend" "recycled chain, untrusted id" 2
  fire_phase "$dir" 5 ''
  expect_phase_foreign "$dir" 5 4 "$frontend" "recycled chain, no id" 0

  # Phase 6: the front-end exits; the same session reclaims its dead anchor
  # onto the spare - the model-loop process - not onto the outermost pty-host.
  : > "$dir/state/stop-frontend"
  i=0
  while [ "$i" -lt 200 ] && kill -0 "$frontend" 2>/dev/null; do
    sleep 0.05
    i=$((i + 1))
  done
  kill -0 "$frontend" 2>/dev/null && fail "the front-end did not exit"
  fire_phase "$dir" 6 'export CLAUDE_CODE_SESSION_ID=S1; export CLAUDE_PID=$$'
  expect_phase_owned "$dir" 6 6 "$spare" "dead front-end, same session"
  [ "$spare" != "$ptyhost" ] || fail "fixture collapsed the spare into the pty-host"

  : > "$dir/state/stop-spare"
  pass "session-lock e2e: a background session keeps its lock and its supervision across a recycled helper chain"
}

# --- end-to-end layer: a conversation moved to the background ----------------
#
# The topology observed on Claude Code 2.1.289 on macOS: the terminal client
# that took the lock stays alive and idle, while its conversation continues
# under a new session id in a detached version-named engine whose pty host has
# been reparented to init. Client and engine each run one request loop, so the
# real lock script, Stop auto-arm, and turn-end guard fire inside each tree
# under a chosen environment. Claude's live-session registry is a fixture
# directory whose entries the test writes with the real pids.

make_parked_session_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state" "$dir/claude-config/sessions"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  cp -R "$ROOT/bin" "$dir/bin"
  install_autoarm_scripts "$dir"
  cat > "$dir/runner.sh" <<'SH'
#!/usr/bin/env bash
role=$1
if [ "${FM_FIXTURE_ORPHAN_HERE:-0}" = 1 ]; then
  i=0
  while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
    sleep 0.05
    i=$((i + 1))
  done
fi
printf '%s\n' "$$" > "$FM_HOME/state/$role-pid"
n=1
while [ ! -e "$FM_HOME/state/stop-$role" ]; do
  req="$FM_HOME/state/$role-fire-$n"
  if [ -f "$req" ]; then
    out="$FM_HOME/state/$role-phase-$n"
    mkdir -p "$out"
    unset CLAUDE_CODE_SESSION_ID CLAUDE_PID FM_PHASE_STEPS
    # shellcheck disable=SC1090
    . "$req"
    for step in ${FM_PHASE_STEPS:-autoarm guard lock}; do
      case "$step" in
        autoarm)
          printf '%s\n' '{"session_id":"fixture","stop_hook_active":true}' \
            | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" > "$out/hook.out" 2>&1
          printf '%s\n' "$?" > "$out/hook.rc"
          ;;
        guard)
          printf '%s\n' '{"session_id":"fixture","stop_hook_active":true}' \
            | "$FM_HOME/bin/fm-turnend-guard.sh" --claude > "$out/guard.out" 2>&1
          printf '%s\n' "$?" > "$out/guard.rc"
          ;;
        lock)
          "$FM_HOME/bin/fm-lock.sh" > "$out/lock.out" 2>&1
          printf '%s\n' "$?" > "$out/lock.rc"
          ;;
      esac
    done
    cp "$FM_HOME/state/.lock" "$out/lock-after"
    [ ! -e "$FM_HOME/state/.lock-session" ] || cp "$FM_HOME/state/.lock-session" "$out/session-after"
    : > "$out/done"
    n=$((n + 1))
  fi
  sleep 0.05
done
exit 0
SH
  cat > "$dir/ptyhost.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/ptyhost-pid"
"$FM_FIXTURE_ENGINE" "$FM_HOME/runner.sh" engine &
while [ ! -e "$FM_HOME/state/stop-engine" ]; do sleep 0.1; done
exit 0
SH
  chmod +x "$dir/runner.sh" "$dir/ptyhost.sh"
}

fire_role_phase() {  # <dir> <role> <n> <hook-environment-script>
  local dir=$1 role=$2 n=$3 i=0
  printf '%s\n' "$4" > "$dir/state/$role-fire-$n.tmp"
  mv "$dir/state/$role-fire-$n.tmp" "$dir/state/$role-fire-$n"
  while [ "$i" -lt 600 ] && [ ! -e "$dir/state/$role-phase-$n/done" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$dir/state/$role-phase-$n/done" ] || fail "parked-session fixture never finished $role phase $n"
}

role_value() {  # <dir> <role> <n> <file>
  tr -d '[:space:]' < "$1/state/$2-phase-$3/$4"
}

role_text() {  # <dir> <role> <n> <file>
  cat "$1/state/$2-phase-$3/$4" 2>/dev/null
}

test_e2e_parked_conversation_takes_over_its_clients_lock() {
  local dir config client engine ptyhost epoch_before
  dir="$TMP_ROOT/e2e-parked-session"
  config="$dir/claude-config"
  make_parked_session_home "$dir"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" CLAUDE_CONFIG_DIR="$config" FM_FIXTURE_ORPHAN_HERE=1 \
    FM_POLL=1 FM_HEARTBEAT=999999 FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0 \
    bash -c '"$0" "$1" client &' "$NAMED_CLAUDE" "$dir/runner.sh"
  wait_for_file "$dir/state/client-pid" "the terminal client"
  client=$(tr -d '[:space:]' < "$dir/state/client-pid")
  BG_FIXTURE_PIDS+=("$client")
  # The client takes the lock for its conversation C0, then re-keys to a fresh
  # id C1 when the conversation leaves - the sidecar the engine then finds.
  fire_role_phase "$dir" client 1 'export FM_PHASE_STEPS=lock CLAUDE_CODE_SESSION_ID=C0 CLAUDE_PID=$$'
  expect_code 0 "$(role_value "$dir" client 1 lock.rc)" "the client could not take the lock: $(role_text "$dir" client 1 lock.out)"
  fire_role_phase "$dir" client 2 'export FM_PHASE_STEPS=lock CLAUDE_CODE_SESSION_ID=C1 CLAUDE_PID=$$'
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$client" ] || fail "the client's lock does not name the client $client"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = C1 ] || fail "the client did not re-key the sidecar to C1"

  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" CLAUDE_CONFIG_DIR="$config" FM_FIXTURE_ENGINE="$VERSIONED_CLAUDE" \
    FM_POLL=1 FM_HEARTBEAT=999999 FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0 \
    bash -c '"$0" "$1" &' "$NAMED_CLAUDE" "$dir/ptyhost.sh"
  wait_for_file "$dir/state/engine-pid" "the background engine"
  engine=$(tr -d '[:space:]' < "$dir/state/engine-pid")
  ptyhost=$(tr -d '[:space:]' < "$dir/state/ptyhost-pid")
  BG_FIXTURE_PIDS+=("$engine" "$ptyhost")
  write_claude_session_entry "$config" "$client" \
    "{\"pid\":$client,\"sessionId\":\"C0\",\"kind\":\"interactive\",\"parkedJobId\":\"f44b1372\"}"
  write_claude_session_entry "$config" "$engine" \
    "{\"pid\":$engine,\"sessionId\":\"E1\",\"kind\":\"bg\",\"jobId\":\"f44b1372\"}"

  # Phase 1 - the reported incident: a Stop in the background conversation
  # while the idle client still holds the lock under its own fresh id.
  fire_role_phase "$dir" engine 1 'export CLAUDE_CODE_SESSION_ID=E1 CLAUDE_PID=$$'
  expect_code 2 "$(role_value "$dir" engine 1 hook.rc)" \
    "the Stop auto-arm did not claim the home for the background conversation: $(role_text "$dir" engine 1 hook.out)"
  [ "$(arm_count "$dir")" = 2 ] || fail "the background conversation armed $(arm_count "$dir") time(s), expected 2"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "no rewake claim was recorded, got: $(epoch_outcome "$dir")"
  [ "$(role_value "$dir" engine 1 lock-after)" = "$engine" ] \
    || fail "lock line 1 is $(role_value "$dir" engine 1 lock-after), expected the engine $engine"
  [ "$(role_value "$dir" engine 1 session-after)" = E1 ] \
    || fail "the sidecar names $(role_value "$dir" engine 1 session-after), expected the conversation's id E1"
  expect_code 0 "$(role_value "$dir" engine 1 guard.rc)" "the turn-end guard blocked the owning conversation: $(role_text "$dir" engine 1 guard.out)"
  if grep -q 'OWNED BY ANOTHER LIVE SESSION' "$dir/state/engine-phase-1/guard.out"; then
    fail "the guard reported the conversation's own client as a foreign owner"
  fi
  expect_code 0 "$(role_value "$dir" engine 1 lock.rc)" "fm-lock.sh refused the conversation's lock: $(role_text "$dir" engine 1 lock.out)"

  # Phase 2 - the idle client is now the other session: read-only, visibly.
  fire_role_phase "$dir" client 3 'export FM_PHASE_STEPS="lock autoarm guard" CLAUDE_CODE_SESSION_ID=C1 CLAUDE_PID=$$'
  expect_code 1 "$(role_value "$dir" client 3 lock.rc)" "the client took the lock back from its live background conversation"
  grep -q "another live firstmate session holds the lock (pid $engine, session E1)" "$dir/state/client-phase-3/lock.out" \
    || fail "the client's refusal did not name the conversation: $(role_text "$dir" client 3 lock.out)"
  expect_code 2 "$(role_value "$dir" client 3 hook.rc)" "the client's auto-arm stood down silently"
  grep -q "STOOD DOWN.*pid $engine, session E1" "$dir/state/client-phase-3/hook.out" \
    || fail "the client's stand-down notice did not name the owner: $(role_text "$dir" client 3 hook.out)"
  grep -q "OWNED BY ANOTHER LIVE SESSION.*lock owner pid $engine" "$dir/state/client-phase-3/guard.out" \
    || fail "the client's guard did not report the owner: $(role_text "$dir" client 3 guard.out)"
  [ "$(arm_count "$dir")" = 2 ] || fail "the read-only client armed supervision"
  [ "$(role_value "$dir" client 3 lock-after)" = "$engine" ] || fail "the client rewrote the conversation's lock"

  # Phases 3-4 - without Claude's link the same live client keeps its lock: the
  # engine stands down with one visible notice, then stays silent.
  printf '%s\n' "$client" > "$dir/state/.lock"
  printf 'C1\n' > "$dir/state/.lock-session"
  write_claude_session_entry "$config" "$client" \
    "{\"pid\":$client,\"sessionId\":\"C0\",\"kind\":\"interactive\",\"parkedJobId\":\"0ther000\"}"
  epoch_before=$(cat "$dir/state/.claude-autoarm-epoch")
  fire_role_phase "$dir" engine 2 'export CLAUDE_CODE_SESSION_ID=E1 CLAUDE_PID=$$'
  expect_code 2 "$(role_value "$dir" engine 2 hook.rc)" "an unlinked background session stood down silently"
  grep -q "STOOD DOWN.*pid $client, session C1" "$dir/state/engine-phase-2/hook.out" \
    || fail "the stand-down notice did not name the live owner and its id: $(role_text "$dir" engine 2 hook.out)"
  grep -q "OWNED BY ANOTHER LIVE SESSION.*lock owner pid $client" "$dir/state/engine-phase-2/guard.out" \
    || fail "the guard did not report the unlinked owner: $(role_text "$dir" engine 2 guard.out)"
  expect_code 1 "$(role_value "$dir" engine 2 lock.rc)" "fm-lock.sh handed over a lock without Claude's link"
  [ "$(role_value "$dir" engine 2 lock-after)" = "$client" ] || fail "an unlinked session rewrote the client's lock"
  fire_role_phase "$dir" engine 3 'export CLAUDE_CODE_SESSION_ID=E1 CLAUDE_PID=$$'
  expect_code 0 "$(role_value "$dir" engine 3 hook.rc)" "the stand-down notice repeated within one episode"
  [ ! -s "$dir/state/engine-phase-3/hook.out" ] || fail "a repeated stand-down printed: $(role_text "$dir" engine 3 hook.out)"
  [ "$(arm_count "$dir")" = 2 ] || fail "a standing-down session armed supervision"
  [ "$(cat "$dir/state/.claude-autoarm-epoch")" = "$epoch_before" ] || fail "a standing-down session wrote the auto-arm ledger"

  # Phase 5 - session start's own acquisition performs the same handoff and
  # says so once the link is back.
  write_claude_session_entry "$config" "$client" \
    "{\"pid\":$client,\"sessionId\":\"C0\",\"kind\":\"interactive\",\"parkedJobId\":\"f44b1372\"}"
  fire_role_phase "$dir" engine 4 'export FM_PHASE_STEPS=lock CLAUDE_CODE_SESSION_ID=E1 CLAUDE_PID=$$'
  expect_code 0 "$(role_value "$dir" engine 4 lock.rc)" "session start refused the parked conversation's lock: $(role_text "$dir" engine 4 lock.out)"
  grep -qx "lock acquired: harness pid $engine" "$dir/state/engine-phase-4/lock.out" \
    || fail "the handoff did not report the acquisition: $(role_text "$dir" engine 4 lock.out)"
  grep -q "handed over from pid $client" "$dir/state/engine-phase-4/lock.out" \
    || fail "the handoff did not say whose lock it took: $(role_text "$dir" engine 4 lock.out)"
  [ "$(role_value "$dir" engine 4 lock-after)" = "$engine" ] || fail "session start did not re-point the lock at the engine"
  [ "$(role_value "$dir" engine 4 session-after)" = E1 ] || fail "session start did not record the conversation's id"

  : > "$dir/state/stop-client"
  : > "$dir/state/stop-engine"
  pass "session-lock e2e: a conversation moved to the background takes over its idle client's lock, and nothing weaker does"
}

# The client's own Stop hook may still be parked in its arm when its
# conversation leaves. Its open claim was armed for the client's lock, so once
# the background conversation takes the lock that claim can never commit a
# rewake and must not make the new owner defer: the new owner arms its own
# cycle and the next watcher event wakes it, while the old hook goes silent.
test_e2e_parked_conversation_is_woken_past_its_clients_open_claim() {
  local dir config client engine ptyhost i
  dir="$TMP_ROOT/e2e-parked-open-claim"
  config="$dir/claude-config"
  make_parked_session_home "$dir"
  # Every arm attaches to one shared cycle that closes on the next watcher event.
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
i=0
while [ "$i" -lt 600 ] && [ ! -e "$FM_HOME/state/watcher-event" ]; do
  sleep 0.05
  i=$((i + 1))
done
[ -e "$FM_HOME/state/watcher-event" ] && printf 'stale: fixture-event actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" CLAUDE_CONFIG_DIR="$config" FM_FIXTURE_ORPHAN_HERE=1 \
    FM_POLL=1 FM_HEARTBEAT=999999 FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0 \
    bash -c '"$0" "$1" client &' "$NAMED_CLAUDE" "$dir/runner.sh"
  wait_for_file "$dir/state/client-pid" "the terminal client"
  client=$(tr -d '[:space:]' < "$dir/state/client-pid")
  BG_FIXTURE_PIDS+=("$client")
  fire_role_phase "$dir" client 1 'export FM_PHASE_STEPS=lock CLAUDE_CODE_SESSION_ID=C0 CLAUDE_PID=$$'
  expect_code 0 "$(role_value "$dir" client 1 lock.rc)" "the client could not take the lock: $(role_text "$dir" client 1 lock.out)"

  # The client's Stop hook claims and parks in its arm, holding a live claim.
  printf '%s\n' 'export FM_PHASE_STEPS=autoarm CLAUDE_CODE_SESSION_ID=C0 CLAUDE_PID=$$' > "$dir/state/client-fire-2"
  i=0
  while [ "$i" -lt 400 ] && { [ "$(arm_count "$dir")" != 1 ] || [ "$(epoch_outcome "$dir")" != arming ]; }; do
    sleep 0.05
    i=$((i + 1))
  done
  [ "$(epoch_outcome "$dir")" = arming ] || fail "the client's hook never held an open claim"

  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" CLAUDE_CONFIG_DIR="$config" FM_FIXTURE_ENGINE="$VERSIONED_CLAUDE" \
    FM_POLL=1 FM_HEARTBEAT=999999 FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0 \
    bash -c '"$0" "$1" &' "$NAMED_CLAUDE" "$dir/ptyhost.sh"
  wait_for_file "$dir/state/engine-pid" "the background engine"
  engine=$(tr -d '[:space:]' < "$dir/state/engine-pid")
  ptyhost=$(tr -d '[:space:]' < "$dir/state/ptyhost-pid")
  BG_FIXTURE_PIDS+=("$engine" "$ptyhost")
  write_claude_session_entry "$config" "$client" \
    "{\"pid\":$client,\"sessionId\":\"C0\",\"kind\":\"interactive\",\"parkedJobId\":\"f44b1372\"}"
  write_claude_session_entry "$config" "$engine" \
    "{\"pid\":$engine,\"sessionId\":\"E1\",\"kind\":\"bg\",\"jobId\":\"f44b1372\"}"

  # The background conversation's Stop takes the lock; then the event arrives.
  printf '%s\n' 'export FM_PHASE_STEPS=autoarm CLAUDE_CODE_SESSION_ID=E1 CLAUDE_PID=$$' > "$dir/state/engine-fire-1"
  i=0
  while [ "$i" -lt 400 ] && [ "$(arm_count "$dir")" -lt 2 ] && [ ! -e "$dir/state/engine-phase-1/done" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  : > "$dir/state/watcher-event"
  i=0
  while [ "$i" -lt 600 ] && { [ ! -e "$dir/state/engine-phase-1/done" ] || [ ! -e "$dir/state/client-phase-2/done" ]; }; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$dir/state/engine-phase-1/done" ] && [ -e "$dir/state/client-phase-2/done" ] \
    || fail "the client and engine hooks did not both finish after the watcher event"

  [ "$(role_value "$dir" engine 1 lock-after)" = "$engine" ] \
    || fail "lock line 1 is $(role_value "$dir" engine 1 lock-after), expected the engine $engine"
  expect_code 2 "$(role_value "$dir" engine 1 hook.rc)" \
    "the background conversation was not woken by the watcher event: $(role_text "$dir" engine 1 hook.out)"
  grep -q '^stale: fixture-event actionable' "$dir/state/engine-phase-1/hook.out" \
    || fail "the new owner's wake did not carry the event: $(role_text "$dir" engine 1 hook.out)"
  expect_code 0 "$(role_value "$dir" client 2 hook.rc)" "the superseded client hook delivered a wake"
  [ ! -s "$dir/state/client-phase-2/hook.out" ] || fail "the superseded client hook printed: $(role_text "$dir" client 2 hook.out)"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "no rewake was recorded, got: $(epoch_outcome "$dir")"
  grep -q " session_pid=$engine " "$dir/state/.claude-autoarm-epoch" \
    || fail "the rewake is not bound to the engine: $(cat "$dir/state/.claude-autoarm-epoch")"

  : > "$dir/state/stop-client"
  : > "$dir/state/stop-engine"
  pass "session-lock e2e: a conversation that takes its parked client's lock is woken past the client's open claim"
}

# A same-session confirmation must refresh a /clear re-key even while another
# process holds .lock.acquire. The prior-session-sweep-is-finishing refusal is
# a takeover rule and does not apply here; the confirmation waits, then writes
# the new id.
test_same_session_confirmation_refreshes_rekeyed_id_under_claim_lock() {
  local dir session_pid holder_pid confirm_pid
  dir="$TMP_ROOT/confirm-under-claim"
  mkdir -p "$dir/state"
  cat > "$dir/run.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/acquire.out" 2>&1
acquire_rc=$?
if [ "$acquire_rc" != 0 ]; then
  printf '%s\n' "$acquire_rc" > "$FM_HOME/state/acquire.rc"
  printf '%s\n' 1 > "$FM_HOME/state/confirm.rc"
  exit 1
fi
cp "$FM_HOME/state/.lock-session" "$FM_HOME/state/sidecar-after-acquire"
printf '%s\n' 0 > "$FM_HOME/state/acquire.rc"

bash -c '
  set -u
  . "$1"
  fm_lock_try_acquire "$2/.lock.acquire" || exit 1
  : > "$2/holder-ready"
  while [ ! -e "$2/release-holder" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
    sleep 0.05
  done
  fm_lock_release "$2/.lock.acquire"
' _ "$FM_WAKE" "$FM_HOME/state" &
printf '%s\n' "$!" > "$FM_HOME/state/holder-pid"

i=0
while [ "$i" -lt 400 ] && [ ! -e "$FM_HOME/state/holder-ready" ]; do
  sleep 0.05
  i=$((i + 1))
done
if [ ! -e "$FM_HOME/state/holder-ready" ]; then
  printf '%s\n' 2 > "$FM_HOME/state/confirm.rc"
  exit 2
fi

CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/confirm.out" 2>&1 &
printf '%s\n' "$!" > "$FM_HOME/state/confirm-pid"

i=0
while [ "$i" -lt 20 ]; do
  sleep 0.05
  i=$((i + 1))
done

: > "$FM_HOME/state/release-holder"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/confirm-pid")"
printf '%s\n' "$?" > "$FM_HOME/state/confirm.rc"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/holder-pid")" || true
SH
  chmod +x "$dir/run.sh"

  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" FM_WAKE="$ROOT/bin/fm-wake-lib.sh" \
    "$NAMED_CLAUDE" "$dir/run.sh" &
  session_pid=$!
  BG_FIXTURE_PIDS+=("$session_pid")
  wait_for_file "$dir/state/acquire.rc" "the initial lock acquisition"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/acquire.rc")" \
    "the session could not acquire its lock: $(cat "$dir/state/acquire.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/sidecar-after-acquire")" = S1 ] \
    || fail "the initial acquire did not record S1"
  wait_for_file "$dir/state/holder-pid" "the claim-lock holder pid"
  holder_pid=$(tr -d '[:space:]' < "$dir/state/holder-pid")
  BG_FIXTURE_PIDS+=("$holder_pid")
  wait_for_file "$dir/state/confirm-pid" "the same-session confirmation pid"
  confirm_pid=$(tr -d '[:space:]' < "$dir/state/confirm-pid")
  BG_FIXTURE_PIDS+=("$confirm_pid")
  wait_for_file "$dir/state/confirm.rc" "the contended confirmation result"
  wait "$session_pid" || true
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/confirm.rc")" \
    "the same-session confirmation failed while the claim lock was held: $(cat "$dir/state/confirm.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = S2 ] \
    || fail "the sidecar still names $(cat "$dir/state/.lock-session"), expected the re-keyed id S2"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$(tr -d '[:space:]' < "$dir/state/session-pid")" ] \
    || fail "the confirmation rewrote lock line 1"
  grep -q 'lock acquired: harness pid' "$dir/state/confirm.out" \
    || fail "the confirmation did not report acquisition: $(cat "$dir/state/confirm.out")"
  pass "session-lock: a same-session confirmation waits for the claim lock and refreshes a re-keyed id"
}

# If another live session publishes while a confirmation is waiting on the claim
# lock, the waiter must not overwrite that session's sidecar or report success.
test_same_session_confirmation_does_not_steal_after_wait() {
  local dir session_pid holder_pid confirm_pid other_pid
  dir="$TMP_ROOT/confirm-no-steal"
  mkdir -p "$dir/state"
  cat > "$dir/run.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/acquire.out" 2>&1
acquire_rc=$?
if [ "$acquire_rc" != 0 ]; then
  printf '%s\n' "$acquire_rc" > "$FM_HOME/state/acquire.rc"
  printf '%s\n' 1 > "$FM_HOME/state/confirm.rc"
  exit 1
fi
cp "$FM_HOME/state/.lock-session" "$FM_HOME/state/sidecar-after-acquire"
printf '%s\n' 0 > "$FM_HOME/state/acquire.rc"

"$FM_CLAUDE" -c '
  printf "%s\n" "$$" > "$FM_HOME/state/other-pid"
  while [ ! -e "$FM_HOME/state/stop-other" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
    sleep 0.05
  done
' &
printf '%s\n' "$!" > "$FM_HOME/state/other-bash-pid"
i=0
while [ "$i" -lt 400 ] && [ ! -s "$FM_HOME/state/other-pid" ]; do
  sleep 0.05
  i=$((i + 1))
done
[ -s "$FM_HOME/state/other-pid" ] || {
  printf '%s\n' 2 > "$FM_HOME/state/confirm.rc"
  exit 2
}

bash -c '
  set -u
  . "$1"
  fm_lock_try_acquire "$2/.lock.acquire" || exit 1
  : > "$2/holder-ready"
  while [ ! -e "$2/release-holder" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
    sleep 0.05
  done
  fm_lock_release "$2/.lock.acquire"
' _ "$FM_WAKE" "$FM_HOME/state" &
printf '%s\n' "$!" > "$FM_HOME/state/holder-pid"

i=0
while [ "$i" -lt 400 ] && [ ! -e "$FM_HOME/state/holder-ready" ]; do
  sleep 0.05
  i=$((i + 1))
done
if [ ! -e "$FM_HOME/state/holder-ready" ]; then
  printf '%s\n' 2 > "$FM_HOME/state/confirm.rc"
  exit 2
fi

CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/confirm.out" 2>&1 &
printf '%s\n' "$!" > "$FM_HOME/state/confirm-pid"

i=0
while [ "$i" -lt 20 ]; do
  sleep 0.05
  i=$((i + 1))
done

cp "$FM_HOME/state/other-pid" "$FM_HOME/state/.lock"
printf '%s\n' OTHER > "$FM_HOME/state/.lock-session"
: > "$FM_HOME/state/release-holder"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/confirm-pid")"
printf '%s\n' "$?" > "$FM_HOME/state/confirm.rc"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/holder-pid")" || true
: > "$FM_HOME/state/stop-other"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/other-bash-pid")" || true
SH
  chmod +x "$dir/run.sh"

  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" FM_WAKE="$ROOT/bin/fm-wake-lib.sh" \
    FM_CLAUDE="$NAMED_CLAUDE" \
    "$NAMED_CLAUDE" "$dir/run.sh" &
  session_pid=$!
  BG_FIXTURE_PIDS+=("$session_pid")
  wait_for_file "$dir/state/acquire.rc" "the initial lock acquisition"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/acquire.rc")" \
    "the session could not acquire its lock: $(cat "$dir/state/acquire.out")"
  wait_for_file "$dir/state/other-pid" "the other live harness pid"
  other_pid=$(tr -d '[:space:]' < "$dir/state/other-pid")
  BG_FIXTURE_PIDS+=("$other_pid")
  wait_for_file "$dir/state/holder-pid" "the claim-lock holder pid"
  holder_pid=$(tr -d '[:space:]' < "$dir/state/holder-pid")
  BG_FIXTURE_PIDS+=("$holder_pid")
  wait_for_file "$dir/state/confirm-pid" "the same-session confirmation pid"
  confirm_pid=$(tr -d '[:space:]' < "$dir/state/confirm-pid")
  BG_FIXTURE_PIDS+=("$confirm_pid")
  wait_for_file "$dir/state/confirm.rc" "the contended confirmation result"
  wait "$session_pid" || true
  [ "$(tr -d '[:space:]' < "$dir/state/confirm.rc")" != 0 ] \
    || fail "the waiter reported success after another live session published: $(cat "$dir/state/confirm.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = OTHER ] \
    || fail "the waiter overwrote the other session's sidecar to $(cat "$dir/state/.lock-session")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$other_pid" ] \
    || fail "the waiter rewrote lock line 1 off the other live session"
  grep -q "another live firstmate session holds the lock (pid $other_pid, session OTHER)" "$dir/state/confirm.out" \
    || fail "the waiter did not refuse the other live owner: $(cat "$dir/state/confirm.out")"
  pass "session-lock: a waiting confirmation does not steal another session's lock"
}

# A failed line-1 write after publishing a new id must restore the previous
# sidecar, not leave the new id beside the unclaimed pid.
test_failed_lock_write_restores_previous_sidecar() {
  local dir stale_pid
  dir="$TMP_ROOT/restore-sidecar"
  mkdir -p "$dir/state"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/acquire.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/acquire.rc"
      printf "%s\n" "$$" > "$FM_HOME/state/stale-pid"
    '
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/acquire.rc")" \
    "the first session could not acquire its lock: $(cat "$dir/state/acquire.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = S1 ] \
    || fail "the first session did not record S1"
  stale_pid=$(tr -d '[:space:]' < "$dir/state/stale-pid")
  cp "$dir/state/.lock" "$dir/state/lock-before-reclaim"
  chmod a-w "$dir/state/.lock" || fail "could not make the stale lock read-only"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reclaim.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reclaim.rc"
    '
  chmod u+w "$dir/state/.lock" 2>/dev/null || true
  [ "$(tr -d '[:space:]' < "$dir/state/reclaim.rc")" != 0 ] \
    || fail "a read-only stale lock was overwritten: $(cat "$dir/state/reclaim.out")"
  grep -q 'cannot write session lock' "$dir/state/reclaim.out" \
    || fail "the reclaim did not fail on the lock write: $(cat "$dir/state/reclaim.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = S1 ] \
    || fail "the failed reclaim left sidecar $(cat "$dir/state/.lock-session"), expected the previous id S1"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$stale_pid" ] \
    || fail "the failed reclaim rewrote lock line 1"
  cmp -s "$dir/state/lock-before-reclaim" "$dir/state/.lock" \
    || fail "the failed reclaim changed lock bytes when line 1 was unwritable"
  pass "session-lock: a failed lock write restores the previous sidecar"
}

# A failed line-1 write that had no previous sidecar must not leave the new id
# behind; the lock stays ancestry-only.
test_failed_lock_write_removes_new_sidecar_when_none_existed() {
  local dir
  dir="$TMP_ROOT/restore-absent-sidecar"
  mkdir -p "$dir/state"
  printf '1\n' > "$dir/state/.lock"
  chmod a-w "$dir/state/.lock" || fail "could not make the stale lock read-only"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reclaim.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reclaim.rc"
    '
  chmod u+w "$dir/state/.lock" 2>/dev/null || true
  [ "$(tr -d '[:space:]' < "$dir/state/reclaim.rc")" != 0 ] \
    || fail "a read-only stale lock was overwritten: $(cat "$dir/state/reclaim.out")"
  grep -q 'cannot write session lock' "$dir/state/reclaim.out" \
    || fail "the reclaim did not fail on the lock write: $(cat "$dir/state/reclaim.out")"
  [ ! -e "$dir/state/.lock-session" ] \
    || fail "the failed reclaim left sidecar $(cat "$dir/state/.lock-session"), expected none"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = 1 ] \
    || fail "the failed reclaim rewrote lock line 1"
  pass "session-lock: a failed lock write removes a newly created sidecar"
}

# A completed reclaim must keep the new id beside the new pid after the writer
# exits, so a late signal cannot unwind a verified publication.
test_verified_reclaim_keeps_new_sidecar() {
  local dir
  dir="$TMP_ROOT/verified-reclaim"
  mkdir -p "$dir/state"
  printf '1\n' > "$dir/state/.lock"
  printf 'S1\n' > "$dir/state/.lock-session"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reclaim.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reclaim.rc"
      printf "%s\n" "$$" > "$FM_HOME/state/new-pid"
    '
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/reclaim.rc")" \
    "the reclaim failed: $(cat "$dir/state/reclaim.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = S2 ] \
    || fail "the verified reclaim left sidecar $(cat "$dir/state/.lock-session"), expected S2"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$(tr -d '[:space:]' < "$dir/state/new-pid")" ] \
    || fail "the verified reclaim did not record the new anchor pid"
  pass "session-lock: a verified reclaim keeps the new sidecar beside the new pid"
}

test_version_named_session_is_identified_on_both_platforms
test_harness_at_namespace_pid1_is_examined
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_same_session_id_owns_a_recycled_background_chain
test_anchor_pid_is_the_model_loop_process_only_for_a_trusted_id
test_parked_client_lock_is_handed_to_its_background_session
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock
test_e2e_background_session_keeps_its_lock_across_a_recycled_chain
test_e2e_parked_conversation_takes_over_its_clients_lock
test_e2e_parked_conversation_is_woken_past_its_clients_open_claim
test_same_session_confirmation_refreshes_rekeyed_id_under_claim_lock
test_same_session_confirmation_does_not_steal_after_wait
test_failed_lock_write_restores_previous_sidecar
test_failed_lock_write_removes_new_sidecar_when_none_existed
test_verified_reclaim_keeps_new_sidecar
