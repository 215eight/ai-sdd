#!/bin/sh
# Hermetic shell test for the ai-sdd run-integrity pre-commit tripwire.
#
# Drives `.ai-sdd/hooks/pre-commit` against fabricated commit-message files and
# fixture event dirs inside a throwaway temp dir, asserting exit codes and exact
# message/warning text per the slice's acceptance cases. It NEVER installs into
# any real `.git/hooks/` and never touches real run state.
#
# POSIX sh; run with `sh Tests/PrecommitTripwireTests/run-precommit-hook-tests.sh`.

set -u

# Resolve the repo root from this script's location so the test runs from any cwd.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
HOOK="${REPO_ROOT}/.ai-sdd/hooks/pre-commit"

if [ ! -x "${HOOK}" ]; then
  printf 'FAIL: hook not found or not executable: %s\n' "${HOOK}" >&2
  exit 1
fi

FAILURES=0
PASSES=0

pass() { PASSES=$((PASSES + 1)); printf 'ok   - %s\n' "$1"; }
fail() { FAILURES=$((FAILURES + 1)); printf 'FAIL - %s\n' "$1" >&2; }

# Each case runs the hook inside a fresh sandbox dir so the relative
# `.ai-sdd/runs/<feature>/events` path the hook reads resolves to fixtures only.
make_sandbox() {
  SANDBOX=$(mktemp -d 2>/dev/null || mktemp -d -t aisddhook)
  printf '%s' "${SANDBOX}"
}

# Run the hook from inside a sandbox cwd with a given commit-msg file.
# Captures stdout+stderr to $OUT and exit code to $RC.
run_hook() {
  _sandbox="$1"
  _msgfile="$2"
  OUT=$( cd "${_sandbox}" && "${HOOK}" "${_msgfile}" 2>&1 )
  RC=$?
}

# ---------------------------------------------------------------------------
# Case 1: refuses an unsubmitted slice with the EXACT error, non-zero exit.
# ---------------------------------------------------------------------------
SB=$(make_sandbox)
mkdir -p "${SB}/.ai-sdd/runs/myfeat/events"   # empty events dir → not submitted
MSG="${SB}/msg.txt"
printf '[myfeat] my-slice: do the thing\n' > "${MSG}"
run_hook "${SB}" "${MSG}"
EXPECTED='slice "my-slice" of feature "myfeat" was not submitted — run `ai-sdd submit myfeat` first'
if [ "${RC}" -ne 0 ]; then
  pass "unsubmitted slice exits non-zero (rc=${RC})"
else
  fail "unsubmitted slice should exit non-zero (rc=${RC})"
fi
# The exact refusal line must appear verbatim somewhere in output.
if printf '%s\n' "${OUT}" | grep -qF "${EXPECTED}"; then
  pass "unsubmitted slice prints the exact refusal line"
else
  fail "unsubmitted slice missing exact refusal line; got: ${OUT}"
fi
rm -rf "${SB}"

# ---------------------------------------------------------------------------
# Case 2: passes (exit 0) once a nodeCompleted event for the slice exists.
# ---------------------------------------------------------------------------
SB=$(make_sandbox)
mkdir -p "${SB}/.ai-sdd/runs/myfeat/events"
# Fixture mirrors the real on-disk shape: scoped.slice == slice + nodeCompleted.
cat > "${SB}/.ai-sdd/runs/myfeat/events/000007.json" <<'JSON'
{
  "scoped" : {
    "event" : {
      "nodeCompleted" : {
        "node" : "my-slice",
        "producedArtifacts" : [

        ]
      }
    },
    "slice" : "my-slice"
  }
}
JSON
MSG="${SB}/msg.txt"
printf '[myfeat] my-slice: do the thing\n' > "${MSG}"
run_hook "${SB}" "${MSG}"
if [ "${RC}" -eq 0 ]; then
  pass "submitted slice exits 0"
else
  fail "submitted slice should exit 0 (rc=${RC}); got: ${OUT}"
fi
rm -rf "${SB}"

# ---------------------------------------------------------------------------
# Case 2b: nested event shape (worker-level scoped.slice) also counts.
# ---------------------------------------------------------------------------
SB=$(make_sandbox)
mkdir -p "${SB}/.ai-sdd/runs/myfeat/events"
cat > "${SB}/.ai-sdd/runs/myfeat/events/000005.json" <<'JSON'
{
  "scoped" : {
    "event" : {
      "scoped" : {
        "event" : {
          "nodeCompleted" : {
            "node" : "implementer",
            "producedArtifacts" : [ "changeset.v1" ]
          }
        },
        "slice" : "my-slice"
      }
    },
    "slice" : "myfeat"
  }
}
JSON
MSG="${SB}/msg.txt"
printf '[myfeat] my-slice: do the thing\n' > "${MSG}"
run_hook "${SB}" "${MSG}"
if [ "${RC}" -eq 0 ]; then
  pass "submitted slice (nested event shape) exits 0"
else
  fail "nested-shape submitted slice should exit 0 (rc=${RC}); got: ${OUT}"
fi
rm -rf "${SB}"

# ---------------------------------------------------------------------------
# Case 3: non-`[feature] slice:` subjects pass straight through (exit 0).
# ---------------------------------------------------------------------------
SB=$(make_sandbox)
MSG="${SB}/msg.txt"
printf 'chore: bump dependency\n' > "${MSG}"
run_hook "${SB}" "${MSG}"
if [ "${RC}" -eq 0 ]; then
  pass "non-managed subject passes through (exit 0)"
else
  fail "non-managed subject should exit 0 (rc=${RC}); got: ${OUT}"
fi
# And it must not emit the integrity-hook-reached warning.
if printf '%s\n' "${OUT}" | grep -q 'integrity hook reached'; then
  fail "non-managed subject should not emit the reached warning"
else
  pass "non-managed subject emits no warning"
fi
rm -rf "${SB}"

# ---------------------------------------------------------------------------
# Case 4: a matched subject emits a one-line stderr warning when reached, and
#         the warning does not change the success exit code.
# ---------------------------------------------------------------------------
SB=$(make_sandbox)
mkdir -p "${SB}/.ai-sdd/runs/myfeat/events"
cat > "${SB}/.ai-sdd/runs/myfeat/events/000001.json" <<'JSON'
{ "scoped" : { "event" : { "nodeCompleted" : { "node" : "my-slice" } }, "slice" : "my-slice" } }
JSON
MSG="${SB}/msg.txt"
printf '[myfeat] my-slice: ship it\n' > "${MSG}"
# Capture stderr separately to confirm the warning lands on stderr.
ERR=$( cd "${SB}" && "${HOOK}" "${MSG}" 2>&1 1>/dev/null )
RC=$( cd "${SB}" && "${HOOK}" "${MSG}" >/dev/null 2>&1; echo $? )
if printf '%s\n' "${ERR}" | grep -q 'integrity hook reached'; then
  pass "matched subject emits a one-line stderr warning"
else
  fail "matched subject should emit a stderr warning; got: ${ERR}"
fi
if [ "${RC}" -eq 0 ]; then
  pass "warning does not change the success exit code (rc=0)"
else
  fail "warning must not change success exit code (rc=${RC})"
fi
rm -rf "${SB}"

# ---------------------------------------------------------------------------
# Case 5: when `ai-sdd` is not on $PATH, print the install message, exit non-zero.
# ---------------------------------------------------------------------------
SB=$(make_sandbox)
mkdir -p "${SB}/.ai-sdd/runs/myfeat/events"   # even with no event, PATH check fires first
MSG="${SB}/msg.txt"
printf '[myfeat] my-slice: do the thing\n' > "${MSG}"
# Run with an empty PATH (plus a minimal dir for coreutils) so `ai-sdd` is absent.
# We provide a stub PATH containing only the basics the hook needs (sh builtins
# cover most of it; grep/head/printf are needed). Point PATH at a dir WITHOUT ai-sdd.
STUBBIN="${SB}/bin"
mkdir -p "${STUBBIN}"
for tool in sh grep head printf mktemp dirname cat; do
  src=$(command -v "${tool}" 2>/dev/null) && [ -n "${src}" ] && ln -sf "${src}" "${STUBBIN}/${tool}" 2>/dev/null
done
OUT=$( cd "${SB}" && PATH="${STUBBIN}" "${HOOK}" "${MSG}" 2>&1 )
RC=$?
if [ "${RC}" -ne 0 ]; then
  pass "missing ai-sdd exits non-zero (rc=${RC})"
else
  fail "missing ai-sdd should exit non-zero (rc=${RC})"
fi
if printf '%s\n' "${OUT}" | grep -qF 'install ai-sdd or use --no-verify'; then
  pass "missing ai-sdd prints the install message"
else
  fail "missing ai-sdd missing install message; got: ${OUT}"
fi
rm -rf "${SB}"

# ---------------------------------------------------------------------------
# Case 6: chaining — when a sibling `.pre-commit.local` is present, the managed
#         hook delegates to it AFTER a passing integrity check, preserving its
#         exit code. We emulate the installed layout: copy the hook into a fake
#         hooks dir alongside a `.pre-commit.local`, run from a sandbox cwd whose
#         events fixture marks the slice submitted.
SB=$(make_sandbox)
HOOKS="${SB}/hooks"
mkdir -p "${HOOKS}"
cp "${HOOK}" "${HOOKS}/pre-commit"
chmod +x "${HOOKS}/pre-commit"
# A chained local hook that fails with a distinct exit code (7).
cat > "${HOOKS}/.pre-commit.local" <<'LOCAL'
#!/bin/sh
echo "local-hook-ran" >&2
exit 7
LOCAL
chmod +x "${HOOKS}/.pre-commit.local"
# Mark the slice submitted so the integrity check passes and delegation happens.
mkdir -p "${SB}/.ai-sdd/runs/myfeat/events"
cat > "${SB}/.ai-sdd/runs/myfeat/events/000001.json" <<'JSON'
{ "scoped" : { "event" : { "nodeCompleted" : { "node" : "my-slice" } }, "slice" : "my-slice" } }
JSON
MSG="${SB}/msg.txt"
printf '[myfeat] my-slice: ship it\n' > "${MSG}"
OUT=$( cd "${SB}" && "${HOOKS}/pre-commit" "${MSG}" 2>&1 )
RC=$?
if [ "${RC}" -eq 7 ]; then
  pass "chained .pre-commit.local runs and its exit code is preserved (rc=7)"
else
  fail "chained hook exit code should be preserved (expected 7, rc=${RC}); got: ${OUT}"
fi
if printf '%s\n' "${OUT}" | grep -q 'local-hook-ran'; then
  pass "chained .pre-commit.local actually executed"
else
  fail "chained hook did not run; got: ${OUT}"
fi
# And the refusal path must NOT reach the chained hook (integrity fails first).
rm -f "${SB}/.ai-sdd/runs/myfeat/events/000001.json"
OUT=$( cd "${SB}" && "${HOOKS}/pre-commit" "${MSG}" 2>&1 )
RC=$?
if [ "${RC}" -ne 0 ] && ! printf '%s\n' "${OUT}" | grep -q 'local-hook-ran'; then
  pass "refusal short-circuits before delegating to the chained hook"
else
  fail "refusal must not delegate to the chained hook (rc=${RC}); got: ${OUT}"
fi
rm -rf "${SB}"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "${PASSES}" "${FAILURES}"
[ "${FAILURES}" -eq 0 ] || exit 1
exit 0
