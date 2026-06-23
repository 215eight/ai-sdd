#!/usr/bin/env bash
# Regenerate the committed PORTABLE program run state for the demo factory.
#
# Writes `.ai-sdd/runs/demo-program-run/run.json` + `events/NNNNNN.json` directly (no `ai-sdd start`),
# so `pipelineDir` stays a RELATIVE path (`.ai-sdd/programs/demo`) and the fixture commits + clones
# portably. Each event JSON matches the engine's Codable encoding byte-for-byte
# (`JSONEncoder([.prettyPrinted, .sortedKeys])`: 2-space indent, sorted keys, `\/`-escaped slashes,
# empty arrays as `[\n\n  ]`). Deterministic + idempotent: re-running reproduces identical bytes.
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
