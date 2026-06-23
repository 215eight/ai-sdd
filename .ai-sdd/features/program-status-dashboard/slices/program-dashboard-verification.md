# Slice: program-dashboard-verification

**Stack:** swift · **Depends on:** program-dashboard-cli

## Delivers
End-to-end verification against the real guardrails program + a short doc note. No new engine logic.

- Run `swift build`, `swift test`, `swift run ai-sdd validate .ai-sdd` — all green.
- Generate the real artifact: `swift run ai-sdd graph .ai-sdd/programs/guardrails --dashboard --out
  /tmp/prog.html`. Confirm it renders the three feature nodes (`locks`, `provenance`, `drift`), the
  `m1-guardrails-integrated` milestone, and the sequencing edges, with sensible statuses — the
  guardrails run is complete, so features show **done** and m1 shows **passed**. Confirm it is
  self-contained (no server/CDN references) and that names/ids/status are HTML-escaped.
- Regression: `swift run ai-sdd graph .ai-sdd --project --dashboard --out /tmp/proj.html` still works
  unchanged; plain `ai-sdd graph .ai-sdd/programs/guardrails` (and `--html`) Mermaid output unchanged.
- Document the new program-tier invocation where the project/plant dashboard is documented
  (e.g. QUICKSTART.md / the relevant docs), adopter-facing and focused on the new model.

## Acceptance
- All three green commands above pass.
- `/tmp/prog.html` exists, is self-contained, and shows the expected nodes + statuses.
- Project dashboard + plain Mermaid outputs verified unchanged.
- Docs updated.
