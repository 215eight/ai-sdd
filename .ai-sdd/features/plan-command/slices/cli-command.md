# Slice: cli-command

## Delivers

The user-facing `ai-sdd plan` subcommand — a thin wrapper over `diff-source` + `ChangePlan` that renders
the classified preview and sets the exit code.

- A read-only `Plan` `ParsableCommand` in `Sources/AISDDCLI/main.swift`, registered in the `subcommands:`
  list. Argument: the `.ai-sdd` dir (like `validate`). Options: `--since <ref>` (baseline, default `HEAD`)
  and `--require-ack <tier>` (threshold, default `contract`).
- **Validate first:** run the existing `validate` wiring check on the dir; on an invalid graph, fail with
  that validation error and do **not** classify.
- Compute the change-list (`diff-source`) and classify it (`ChangePlan`).
- **Output** grouped by tier (`contract` → `local` → `refresh`), each item showing its path, status, and —
  for `contract` — the consuming workers; breaking-removal and new-contract flags rendered inline. With no
  changes, print "no changes".
- **Exit code:** `0` normally; **`2`** (decision D1) when any change meets or exceeds `--require-ack`
  (default `contract`). A new contract with 0 consumers does **not** trip the exit (D3) unless the
  threshold is lowered.
- `ai-sdd plan --help` documents the argument, `--since`, and `--require-ack`.
- Read-only end to end — no file is written or staged.

## Acceptance

- `ai-sdd plan .ai-sdd` with no `.ai-sdd/` changes prints "no changes" and exits `0`.
- A `conventions/*` edit → **refresh**, exit `0`; a `workers/*` edit → **local**, exit `0`.
- A `schemas/*` edit → **contract** with consumers listed, exit **`2`**.
- `--require-ack local` makes a `local`-only change exit `2`.
- `--since <ref>` diffs against `<ref>`.
- Output is grouped by tier with per-item blast radius.
- `plan` against an invalid graph prints the validation error and does not classify.
- `swift build`, `swift test`, and `swift run ai-sdd validate .ai-sdd` green.

## Stack

swift — CLI surface in `Sources/AISDDCLI`, behavior reused from `AISDDEngine`; tests in
`Tests/AISDDEngineTests` (exit-code/threshold/`--since` behavior with injected shell).

## depends_on

classifier
