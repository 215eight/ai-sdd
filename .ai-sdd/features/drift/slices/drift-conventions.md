# Slice: drift-conventions  (conditional — Dr1)

## Delivers
Kind 3 — convention↔code drift via deterministic citation re-checking. **Ship only if it stays thin**;
if implementation reveals it needs more than mechanical citation checks, STOP and flag it as a
follow-up (a plan amendment), per Dr1 — do not expand scope inline or reach for LLM judging.

- For each `conventions/<stack>.md` Discovery Record entry, mechanically re-check its **evidence citation**: the cited path exists, and/or the cited command exits 0. A broken citation is a finding (the convention may be ungrounded/outdated). Remedy: `re-bootstrap <stack>`.
- Strictly deterministic — flagging via citation breakage only; **no** LLM-judging of convention-vs-code.
- Integrates into the existing `ai-sdd drift` output as a third kind.
- Tests: a convention with a broken citation (missing path / failing command) is flagged; intact citations are not.

## Acceptance
- A convention whose cited path is missing (or cited command fails) is reported (convention↔code, `re-bootstrap` remedy).
- Intact citations produce no finding.
- Still deterministic; no model invoked.
- `swift build`, `swift test`, `swift run ai-sdd validate .ai-sdd` green.

## Stack
swift — extend `Sources/AISDDEngine/Drift.swift`, tests in `Tests/AISDDEngineTests/EngineTests.swift`.

## depends_on
drift-deterministic
