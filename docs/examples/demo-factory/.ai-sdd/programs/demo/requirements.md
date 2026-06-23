# Program: Demo product (auth + billing + search)

> **APPROVED — decisions closed; master graph emitted.** Demo fixture; planning gate cleared.

## Goal

A tiny, self-contained product program that exists to make the factory dashboard render a realistic
picture. Three features are built against one shared build pattern and integrated behind a single
milestone gate, so the project dashboard and the program master graph both show a meaningful status
mix (one feature done, one in progress, the milestone and the downstream feature still pending).

## Sub-features (each → its own `ai-sdd-plan` feature)

Single-owner program; the `maintainer` owns every node. The program tier is used for the **milestone
gate**, not for multi-person coordination.

- **`auth`** — user sign-up and login. Slices: `signup` → `login`. Owner: **maintainer**.
- **`billing`** — invoice generation. Slice: `invoices`. Owner: **maintainer**.
- **`search`** — full-text index and query. Slices: `index` → `query`. Owner: **maintainer**.

Each feature descends into the shared minimal build pattern `build/` (one trivial worker).

## Milestones

- **`m1-core-integrated`** (`milestone-gate`, owner: **maintainer**) — a human validates that auth and
  billing are integrated and records `validation-result.v1`; the structural check enforces
  `outcome == pass`. `search` unlocks only after the milestone passes.

## Sequencing

`auth` and `billing` run in parallel and both gate into `m1-core-integrated`; once the milestone
passes, `search` unlocks downstream:

```
auth     ─┐
          ├─▶ m1-core-integrated ─▶ search
billing  ─┘
```
