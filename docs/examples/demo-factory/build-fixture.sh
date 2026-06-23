#!/usr/bin/env bash
# Regenerate the committed PORTABLE program run state for the demo factory.
#
# Writes `.ai-sdd/runs/demo-program-run/run.json` + `events/NNNNNN.json` directly (no `ai-sdd start`),
# so `pipelineDir` stays a RELATIVE path (`.ai-sdd/programs/demo`) and the fixture commits + clones
# portably. Each event JSON matches the engine's Codable encoding byte-for-byte
# (`JSONEncoder([.prettyPrinted, .sortedKeys])`: 2-space indent, sorted keys, `\/`-escaped slashes,
# empty arrays as `[\n\n  ]`). Deterministic + idempotent: re-running reproduces identical bytes.
#
# The run-state regeneration above is BINARY-FREE (no `ai-sdd` needed). After it, if an `ai-sdd`
# binary is resolvable (on `PATH` or as `.build/debug/ai-sdd`), this script ALSO regenerates the
# committed dashboard snapshot `expected/whole-repo-dashboard.html` via the whole-repo graph command.
# With no binary present it prints a one-line skip notice and still exits 0. The snapshot is
# deterministic too: re-running reproduces identical bytes.
#
# Event log (folds to: auth done, billing in-progress, search + milestone pending):
#   000001 runStarted              {}
#   000002 nodeStarted   auth      (top-level)
#   000003 nodeCompleted auth      => auth reduces to done
#   000004 scoped billing › nodeStarted invoices  => billing reduces to in-progress
set -euo pipefail

# Resolve this script's own directory so it runs correctly from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUN_ID="demo-program-run"
RUN_DIR="${SCRIPT_DIR}/.ai-sdd/runs/${RUN_ID}"
EVENTS_DIR="${RUN_DIR}/events"

# Start clean so the regenerated state is exactly the committed state.
rm -rf "${RUN_DIR}"
mkdir -p "${EVENTS_DIR}"

# RunMeta — pipelineDir RELATIVE to the fixture base (docs/examples/demo-factory).
cat > "${RUN_DIR}/run.json" <<'JSON'
{
  "pipelineDir" : ".ai-sdd\/programs\/demo",
  "runId" : "demo-program-run"
}
JSON

# 000001 — runStarted (no seed artifacts).
cat > "${EVENTS_DIR}/000001.json" <<'JSON'
{
  "runStarted" : {
    "seedArtifacts" : [

    ]
  }
}
JSON

# 000002 — nodeStarted for the top-level feature node `auth`.
cat > "${EVENTS_DIR}/000002.json" <<'JSON'
{
  "nodeStarted" : {
    "node" : "auth"
  }
}
JSON

# 000003 — nodeCompleted for `auth` (=> auth is done).
cat > "${EVENTS_DIR}/000003.json" <<'JSON'
{
  "nodeCompleted" : {
    "node" : "auth",
    "producedArtifacts" : [

    ]
  }
}
JSON

# 000004 — scoped into slice `billing`: a sub-node started (=> billing is in-progress).
cat > "${EVENTS_DIR}/000004.json" <<'JSON'
{
  "scoped" : {
    "event" : {
      "nodeStarted" : {
        "node" : "invoices"
      }
    },
    "slice" : "billing"
  }
}
JSON

echo "wrote ${RUN_DIR}/run.json + $(ls -1 "${EVENTS_DIR}" | wc -l | tr -d ' ') events"

# --- Optional: regenerate the committed dashboard snapshot (needs the `ai-sdd` binary) ----------
# Resolve a binary: PREFER this checkout's own `.build/debug/ai-sdd` (so the snapshot reflects the
# current source, not a possibly-stale globally-installed release), then fall back to `ai-sdd` on
# PATH. If neither is available, skip (still exit 0) so the binary-free run-state regeneration above
# remains the contract.
AISDD_BIN=""
if [ -x "${SCRIPT_DIR}/../../../.build/debug/ai-sdd" ]; then
  AISDD_BIN="${SCRIPT_DIR}/../../../.build/debug/ai-sdd"
elif command -v ai-sdd >/dev/null 2>&1; then
  AISDD_BIN="ai-sdd"
fi

SNAPSHOT="${SCRIPT_DIR}/expected/whole-repo-dashboard.html"
if [ -n "${AISDD_BIN}" ]; then
  "${AISDD_BIN}" graph "${SCRIPT_DIR}/.ai-sdd" --project --dashboard --out "${SNAPSHOT}"
  echo "wrote ${SNAPSHOT}"
else
  echo "skip: ai-sdd not on PATH (and no .build/debug/ai-sdd) — left ${SNAPSHOT} unchanged"
fi
