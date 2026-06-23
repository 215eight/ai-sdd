# Slice: typed-evidence-schema  (Part 1 — the prerequisite)

## Delivers
A typed, machine-readable evidence format for the convention Discovery Record so a parser reads
citations with **zero heuristics**, plus the conversion of the real `swift.md` to it — leaving the
repo reconciled.

- **Format (DC1):** each Discovery Record row carries its citations in the **Evidence cell** as
  labeled-prefix backticked tokens — `` `path:<repo-relative-path>` `` and `` `cmd:<command>` ``. A
  parser collects ONLY tokens whose backtick content starts with a known prefix (`path:` / `cmd:`);
  every other backticked token (convention vocabulary like `` `@Test` ``, `` `swiftlint` ``) and all
  prose is ignored. This is what makes parsing heuristic-free.
- **No-citation rows (DC3):** an open-gap / "no X found" row carries **no** `path:`/`cmd:` token (it
  may keep descriptive prose + `Status: open gap`). Zero typed tokens ⇒ nothing to verify.
- **Bootstrap authors it:** update `skills/ai-sdd-bootstrap/SKILL.md` §1 "Discover the repo" and the
  Discovery Record format it prescribes, so a future re-bootstrap emits the typed format. Update the
  vendored copy `.ai-sdd/skills/ai-sdd-bootstrap/SKILL.md` **identically** (keep the two byte-for-byte
  the same). The skill must explain: cite evidence as `path:`/`cmd:` tokens (machine-checkable);
  concrete paths only (no globs, DC4); commit SHAs / other evidence stay prose (not drift-checked,
  DC2); open-gap rows carry no token.
- **Convert the real file:** rewrite `.ai-sdd/conventions/swift.md`'s Discovery Record into the typed
  format. CRITICAL: every `path:` token must point at a file that exists; every `cmd:` token must exit
  0; open-gap rows (Lint, Migration, Endpoint, CI/release) carry no token. Verify each citation by hand
  before finishing.

## Acceptance
- The bootstrap skill (both copies, byte-identical) prescribes the typed evidence format with the
  `path:`/`cmd:` token convention, the concrete-paths rule, and the no-token open-gap rule.
- `.ai-sdd/conventions/swift.md` Discovery Record is fully converted; spot-checking each token: every
  cited path exists, every cited command exits 0, every open-gap row has no token.
- No behavior change to the engine yet (this slice is docs/conventions only) — `swift build`,
  `swift test`, `swift run ai-sdd validate .ai-sdd` stay green.

## Stack
swift — but this slice is conventions + skill markdown only (no Swift source change). Touches
`skills/ai-sdd-bootstrap/SKILL.md`, `.ai-sdd/skills/ai-sdd-bootstrap/SKILL.md`,
`.ai-sdd/conventions/swift.md`.

## depends_on
(none)
