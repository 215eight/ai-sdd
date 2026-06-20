# Program: Checkout service launch

> Hand this to `ai-sdd-plan-program` as the brief. It is intentionally decision-rich so the planner does
> not invent sub-features, owners, milestones, or sequencing. If anything is ambiguous, STOP and ask
> before emitting the master graph. (Illustrative example for [ai-sdd-plan-program](../../skills/ai-sdd-plan-program/SKILL.md).)

## Goal
Ship a checkout service across backend and web over one cycle: a payment-authorization API, a checkout
UI that consumes it, and monitoring — with an integration checkpoint before the UI builds on the API,
and a manual sign-off before launch.

## Sub-features
Each becomes its own feature plan (`ai-sdd-plan` → `.ai-sdd/features/<id>/`).

- `payments-api` — authorize/capture/refund endpoints + the payment contract. Owner: **alice**.
- `checkout-ui` — the checkout flow consuming `payments-api`. Owner: **carol**.
- `monitoring` — dashboards + alerts for the checkout path. Owner: **dave**.

## Milestones
Validation checkpoints between sub-features (the gates).

- `m1-api-integration` — **automated**. Brings the API up in Docker and runs the contract + e2e-smoke
  client; gates `checkout-ui` (the UI must not build on an unproven API). Owner: **bob**.
- `m2-launch-signoff` — **manual**. A person validates the end-to-end checkout against staging and
  records the verdict; gates `monitoring` going live. Owner: **erin**.

## Sequencing
- `payments-api` → `m1-api-integration` → `checkout-ui`
- `checkout-ui` → `m2-launch-signoff` → `monitoring`

## Constraints
- Shared stack/conventions per the repo's `.ai-sdd/` (do not introduce new ones).
- `payments-api` publishes the payment contract the UI consumes; keep it backward-compatible.
- No new infra beyond what the milestones' Docker integration harness needs.

## Open questions (close WITH the human before emitting the master graph)
1. Is `monitoring` in this program's scope, or a fast-follow after launch?
2. Does `m1-api-integration` start automated, or manual-first then automated once the harness exists?
3. Owners above — confirm leads per sub-feature and per milestone.
