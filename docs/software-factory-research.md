# AI Software Factories: A Research Briefing for Engineering Leaders

> Research compiled June 2026 by a multi-agent research team. Tied to the Gauntlet
> case study *Athena Digital: The Software Factory Problem* (SF-2026-02). Inline
> citations `[n]` map to the numbered Sources list at the end. Unverified claims are
> flagged `[unverified]`.

## 1. What a "Software Factory" Means

### The historical meaning (2004): codified abstraction, no AI

The term predates the AI era by two decades. In *Software Factories: Assembling Applications with Patterns, Models, Frameworks, and Tools* (Wiley, 2004), Jack Greenfield and Keith Short defined a software factory as "a configuration of languages, patterns, frameworks, and tools that can be used to rapidly and cost-effectively produce an open-ended set of unique variants of a standard product" [1][2]. The "factory" came entirely from **codified reuse** — software product lines (SPL), model-driven development, generative programming — not from machine learning. The leverage was abstraction: define a standard product once, then instantiate variants cheaply.

This older meaning still matters because it frames the right ambition. A factory mass-produces *variants of a standard product conforming to known conventions*. The modern twist is using LLM agents, instead of code generators and models, to instantiate those variants against a real codebase's idioms.

### The AI-era meaning (2024–2026): spec → deployable PR

The modern definition is an **agentic system that ingests a high-level specification and autonomously produces working, tested, deployable software** — typically a reviewed pull request across the full stack — with humans acting as reviewers and orchestrators rather than typists [3]. The clearest current articulation (Mager, Mar 2026) names four subsystems: **Intake** (normalize messy human input into structured tasks), **Orchestrator** (route work, manage state, prevent agent conflicts), **Execution** (specialized agents: architect, coder, reviewer, tester, deployer), and a **Feedback loop**. Its slogan captures the distinction from a one-shot pipeline: *"A pipeline runs once. A factory learns"* [3].

The critical line separating a **factory from a copilot/assistant** is end-to-end autonomy plus three structural features: an orchestration layer, automated verification "backpressure," and a learning loop. Trust expands incrementally along a maturity ladder: read-only → draft PRs → auto-merge → full factory [3].

### The central insight: coding is the minority of the work

The defining thesis of this era is that **writing code was never the bottleneck**. Jennifer Riggins' canonical August 2025 essay argues the real constraints are information retrieval, approvals, queues, review, integration, and deployment friction — not typing [4]. The memorable framing: *"Devs don't need AI to write their code, they need it to get out of the damn queue."* This is reinforced by the observation that integration is now the binding constraint — "a 20-minute CI pipeline is unacceptable when you generate a feature in 20 minutes" [5] — and connected to Fred Brooks' principle that optimizing one stage of a pipeline yields diminishing returns [6].

The hard data behind the paradox comes from Faros AI's "AI Productivity Paradox" report (telemetry from 10,000+ developers across 1,255 teams), **all figures confirmed against the primary source** [7]: high-AI-adoption teams complete **+21% more tasks** and merge **+98% more PRs**, but **PR review time rises +91%**, **bugs per developer +9%**, and **average PR size +154%** — with **no significant correlation between AI adoption and company-level delivery improvement**. Corroborating evidence: METR's 2025 randomized controlled trial found experienced open-source developers were **19% slower** with AI tools despite predicting they'd be 24% faster (confirmed) [8]; Harness's *State of Software Delivery 2025* found **67%** of developers spend more time debugging AI-generated code and **68%** more time on AI-related security vulnerabilities (confirmed; the second figure is specifically AI-*related* vulnerabilities) [9].

The implication for a factory: individual coding speedups don't aggregate into team velocity because the gain lands on ~20% of the work. A factory must attack the other ~80% — and, per the Faros numbers, **review is now the new bottleneck**, which is why "Quality & Verification" and "Human Interface & Trust" are first-class design problems rather than afterthoughts.

---

## 2. The State of the Art

### HumanLayer — the context-engineering thesis

HumanLayer (YC F24, founded 2023 by Dexter Horthy; confirmed, though the round is more precisely a YC-batch *pre-seed* of ~$500k, with more raised since) [10] began as a human-in-the-loop API and pivoted toward coding-agent tooling. Its intellectual core is two widely-cited bodies of work.

**12-Factor Agents** (~23k GitHub stars, dual-licensed CC BY-SA 4.0 / Apache 2.0; confirmed) [11] is a Heroku-style manifesto whose central thesis is **"don't use prompts for control flow — own your context window, prompts, and control flow."** The most reliable "agents" are mostly deterministic software with LLM decision points placed surgically; framework-based fully-agentic builds are observed to hit a ~70–80% reliability ceiling, then hallucinate or loop [11]. Key factors include Own Your Prompts, Own Your Context Window, Tools Are Structured Outputs, Contact Humans With Tool Calls, Small Focused Agents, and Stateless Reducer.

**Advanced Context Engineering (ACE/FCA)** operationalizes a **Research → Plan → Implement (RPI)** workflow, where each phase produces a compacted markdown artifact that becomes the input to the next [12][13]. Two mechanisms matter:

- **Frequent Intentional Compaction (FIC):** deliberately distill greps, logs, and JSON into structured artifacts to keep context-window utilization in a **40–60% band** (confirmed against the primary doc), compacting proactively rather than at exhaustion [12][14]. Sub-agents run noisy discovery (Glob/Grep/Read) in throwaway context windows so the parent stays clean.
- **Context-quality hierarchy:** incorrect information is worse than missing information, which is worse than noise — so optimize for *correctness > completeness > size*. "You always get better results if you use less of [the context window]" [12].

The single most leveraged idea: **review the plan, not the diff.** "A bad line of code is a bad line. But a bad line of a plan could lead to hundreds of bad lines of code. And a bad line of research could land you with thousands of bad lines of code" [12]. Concentrate scarce human review on small, readable research/plan artifacts rather than 2,000-line diffs.

- **Where it shines:** well-bounded changes; auditable artifact chains; teams wanting reliability over emergent autonomy.
- **Where it breaks:** results are **mostly self-reported anecdotes from one team** (e.g., a 35k-LOC feature shipped to the 300k-LOC BAML Rust codebase in ~7 hours; ~$12k/month Opus spend for a 3-person team). The authors themselves flag limited generalizability and document failures (removing Hadoop dependencies from parquet-java failed after ~7 hours; race conditions and deep-domain tasks resisted the method) [12]. **[unverified at claimed scale.]**

### iamkelly.ai — what it actually is

iamkelly.ai is **a live marketing landing page** for "Kelly Claude," an AI persona created by **Austen Allred**, founder of Gauntlet AI and former CEO of BloomTech/Lambda School [15][16]. The page funnels to four real commercial offerings: "Build My Idea" (AI-built, human-refined product in 7 days, from $2,000), "Beyond Vibe Code" (education), the "OpenClaw Handbook" (a book), and a community voting system. It is entangled with a **$kellyclaude crypto token on Base** [17].

The verifiable core is *a funnel plus a manifesto*. The dramatic claims — Kelly as a self-improving autonomous factory with an LLC, bank accounts, and a human employee, mass-producing autonomous B2C companies — come from Allred's promotional X posts and token-listing copy, **not independent audit** [18]. Tellingly, the token-listing copy itself states value is "shaped by attention, participation, and liquidity rather than functional output" [17] — an explicit signal to discount the software claims.

- **Why it's relevant:** Allred ran a "build a fully autonomous software factory" challenge inside Gauntlet, mining ~100+ experiments and "plugging the best learnings" into Kelly [18] — a near-exact structural match to the Athena case study (which is itself fictional and appears modeled on this movement). Even the most aggressive public "autonomous factory" concedes continuous human refinement ("2–4 hours/week of human assistance," "AI-built, human-refined").
- **Where it breaks:** no measurable engineering metrics (CI pass rate, cleanup time) are disclosed; the tech-stack and autonomy claims are marketing-grade. **[unverified.]** Treat the persona/autonomy framing as marketing and the underlying ambition as real but unproven at scale.

### BMAD — structured persona pipeline

BMAD-METHOD ("Breakthrough Method for Agile AI-Driven Development") imposes a two-phase agile pipeline with markdown handoff artifacts [19]. Phase 1 (Planning): Analyst → PM (PRD.md) → Architect → PO. Phase 2 (Development): a Scrum Master agent "shards" the PRD into hyper-detailed self-contained story files, then Dev implements and QA reviews.

- **Where it shines:** exhaustive upfront specification reduces downstream ambiguity; rich traceability; mature ecosystem. Its value is almost entirely in *planning artifacts*, not codegen — itself a validation of the "78% is non-coding" thesis. (A community claim of 55–58% reduction in project hours circulates but is **unverified by controlled study** — treat as vendor/community claim.)
- **Where it breaks:** real brownfield usage (GitHub issue #446) documents that **the human becomes the workflow engine** — "No task tracking or decision mechanism to coordinate agents. I become the workflow engine" [20]. Story-status workflows break; "everything assumes one monolithic system (one Brief, one PRD, one Architecture)," which "prevents trunk-based development with parallel features"; dev agents pick stories without checking predecessors, skip checklists, and fabricate data on timeout; the PM produced "a 500+ page brief." It is fundamentally a verbose prompt-engineering system that assumes a **single developer on a greenfield monolith**.

### Ralph — the recursive single-agent loop

The Ralph (Ralph Wiggum) loop was coined by **Geoffrey Huntley in July 2025** (confirmed) [21][22]. Minimal form: `while :; do cat PROMPT.md | claude ; done`. Each iteration gets a **fresh, garbage-collected context window**; the agent reads an `IMPLEMENTATION_PLAN.md`, picks exactly one task, implements, commits, exits. **The filesystem — not conversation history — is the only shared state** (confirmed). Convergence comes from **backpressure**: type systems, tests, linters, and security scanners gate commits. Used to build the CURSED language over ~3 months of autonomous operation.

- **Where it shines:** simplicity (no orchestration engine), cost efficiency (one bounded task per iteration), self-healing via backpressure, autonomy on long-running greenfield work. The "one validation sub-agent as backpressure" idea is its most transferable concept.
- **Where it breaks:** "deterministically bad in a non-deterministic world." **No automatic drift detection** — when implementation diverges from specs, a human must notice [23]. Recovery is opaque (git reset vs. rescue prompt, no thresholds). Explicitly framed for "greenfield projects where you can accept 90% automated completion with 10% human cleanup" [23]. It tends to **reimplement existing features** unless aggressively told not to — exactly the brownfield-convention risk. This is the source of the "opaque when a multi-agent system produces a broken migration" critique: powerful, but disqualifying for strict auditability without added scoping, deterministic state, and structured rollback.

### Spec-driven tools and agent platforms

**GitHub Spec Kit** (open-sourced Sept 2, 2025, MIT license; surpassed 16k stars in its first week; ~30 agent integrations — all confirmed, though "30+" reflects current docs vs. the three agents named at launch) [24][25] makes the spec the unit of work via a gated loop: `/constitution → /specify → /plan → /tasks → /implement`, each emitting a reviewable markdown artifact. Philosophy: "specifications are the source of truth, code is the generated output." **Shines** at auditability and agent-agnosticism; **breaks** on brownfield — it is a prompt/template toolkit, not an orchestrator or codebase-intelligence engine, and its docs don't cover legacy/multi-repo handling.

**Amazon Kiro** (launched Jul 14, 2025) generates user stories + acceptance criteria, a design doc, and a task list, with **Steering files** (per-project conventions) and **Hooks** (event-triggered quality prompts) [26]. Notably, Kiro's team later added bugfix and design-first spec types, explicitly acknowledging that mandatory requirements-first pipelines "create structural friction for brownfield codebases" [27].

**OpenAI Codex** (cloud + CLI, launched Apr 16, 2025) runs parallel sandboxed tasks, uses `AGENTS.md` for per-repo instructions, and differentiates on **execution-backed review** — it runs code and surfaces test logs as evidence before a human touches the diff [28][29].

**Devin** (Cognition) takes a ticket and returns a PR from a sandboxed environment. Its documented sweet spot is **"well-scoped, pattern-following brownfield tasks"** — migrations, test generation, security-vuln resolution. Cognition's Nov 2025 review cites a **67% PR-merge rate** (up from 34% a year prior; vendor-internal benchmark) [30][31]. Vendor case studies (Mercedes-Benz "8 months → 8 days," Itaú "70% of vulns auto-resolved") are **vendor-reported and unverified**. Weaknesses: ambiguous requirements, "rabbit holes" on complex tasks, coordinated cross-module edits.

**Stripe's Minions** is the strongest production existence proof [32] (verified against Stripe's primary blog): **over 1,000 PRs merged weekly** fully unattended (humans review only); **devboxes spin up in ~10 seconds**; **CI is bounded to at most 2 rounds** against a **3M+ test suite** with selective test execution. The architecture **interleaves agent loops with deterministic steps** — "the creativity of an agent with the assurance they'll always complete Stripe-required steps like linters." **One caveat:** the widely-repeated "~30% of bugs resolved during an internal Fix-It Week" figure does **not** appear in Stripe's primary posts and is **[unverified]** — sourced only to secondary write-ups.

---

## 3. The Four Hard Sub-Problems

### (1) Codebase Intelligence — the unsolved differentiator

This is the linchpin and the one gap no off-the-shelf product solves. The unanimous finding across sources: **specs alone are insufficient for brownfield** because "legacy codebases have rules that live in developer memory rather than documentation" — an agent working from a spec that omits them "can produce syntactically valid code that violates unwritten rules" [33]. And "enterprise codebases with 100,000+ files cannot be comprehensively specified without exceeding context and human-review limits" [33].

The engineering trade-offs span three layers:

- **Structural indexing** (e.g., Aider's tree-sitter + PageRank repo map [34]): cheapest, deterministic, works day-one with zero examples, language-agnostic. Best for cold-start.
- **Retrieval (RAG):** chunk-embedding with Merkle-tree incremental sync (Cursor-style) stays fresh against high deploy frequency; obfuscated/self-hosted paths support compliance. But single-pass retrieval misses cross-file dependencies — iterative (RepoCoder draft-then-re-retrieve) or **code-graph** retrieval is likely needed for whole-PR correctness. Notably, Sourcegraph's Cody **dropped embeddings** for Enterprise in favor of a BM25 code-graph search, citing third-party exposure and vector-refresh debt past 100k repos — a signal that a self-hosted symbol/code-graph index may beat a vector DB for an auditable v1.
- **Convention enforcement:** *soft* (retrieve a nearest sibling file as a few-shot exemplar) vs. *hard* (linters, type-checkers, config as enforceable contracts the agent self-corrects against). The hard path is higher-leverage and auditable.

Trade-off summary: **retrieval beats fine-tuning** for a factory — fine-tuning internalizes deep style but costs ~$50k–$500k per run and goes stale every commit; long-context stuffing matches RAG only for small repos and degrades in the "dumb zone" mid-window. Retrieval is incremental, auditable, and never stale.

### (2) Orchestration & Decomposition

The core trade-off is **determinism vs. emergent autonomy**:

- **Sequential handoff** (BMAD) is traceable but brittle and makes the human the coordination engine.
- **Free-form multi-agent swarms** (Ralph, Gas Town) maximize parallelism but add nondeterminism, infinite-handoff risk, and opacity on failure.
- **The emerging best-fit pattern** is a **deterministic coordinator dispatching role-scoped agents with explicit allowed flows** — Factory.ai's coordinator + bounded "droids" (code, review, docs, test, Knowledge) [35], or graph-based orchestration where agents/tools are nodes in a directed graph. This is more debuggable than a swarm and less human-bottlenecked than sequential personas.

The deepest version: a **dependency-aware DAG with typed, machine-checkable contracts** at each handoff (migration → schema, API → OpenAPI, frontend → typed clients, tests → acceptance criteria), run topologically with per-node checkpoints. Checkpointing avoids regenerating a correct migration on every retry; the lack of automatic drift detection in loop systems argues for **approval gates at node boundaries**.

Gas Town's auditability pattern is worth borrowing: its "Beads" are Git-backed issue entries serving as both data and control plane, so every assignment and decision persists in Git — a compliance-friendly trail. Its governing principle, **"nondeterministic idempotence"** (the path varies but the outcome converges because acceptance criteria are explicit), is the right mental model. But its cost (~$100/hour running 12–30 agents) and complexity argue against a swarm for a small, time-boxed v1.

### (3) Quality & Verification

The key reframe: **verification gates belong *inside* the loop, not just on the PR.** The mechanism is non-zero-exit **backpressure** — typecheck/lint, coverage (~80%) plus mutation testing, SAST/dependency/secret scans, then human review, then post-merge integration. A failing gate rejects the iteration and triggers self-repair *before* a PR is opened; the **same CI** then reruns on the PR.

The real trade-offs:

- **AI-written tests pass tautologically.** Property-based testing (an executable spec) and acceptance-criteria-as-properties are the antidote. Separate the test-authoring node from the implementation node so the agent can't grade its own homework.
- **Selective CI + bounded iterations** (Stripe: relevant tests only, max 2 rounds) is what makes the integration bottleneck tractable at scale [32].
- Agentic remediation hits roughly 43–90% fix rates on SWE-bench, exceeding 90% *with validation in the loop* — confirming that verification, not raw model capability, closes the gap to a high first-run pass rate.

The honest ceiling: Devin's real-world **67% merge rate** [31] is sobering against an 80%-first-run target. The lesson everywhere is that **pattern-narrowing plus strong verification**, not a smarter model, is what gets you there.

### (4) Human Interface & Trust

The trade-off is between "nothing ships without review" and keeping cleanup minimal. The resolution, consistent across HumanLayer's leverage argument and at-scale review data (Cloudflare: 131,246 reviews across 48,095 MRs, median 3m39s), is to **shift reviewers from line-by-line to architecture-plus-spot-check**:

- Surface a **design summary** (DAG plan + typed contracts) for approval, plus spot-check anchors — *review the plan, not the diff* [12].
- Use **calibrated thresholds** set high then loosened per-category and per-product, so pilots can graduate trust independently.
- Implement approval as a **first-class, auditable tool call** (HumanLayer's `require_approval` / `human_as_tool` primitives) rather than ad-hoc UI [13].
- Emit per-PR: the spec, the plan, the contracts, and stage-scoped commits — explainability rests on diff viewers plus signed, versioned change records.

**Compliance is a hard gate, not a feature.** SOC2/HIPAA require every change attributable to an *authorized human/session* — verified identity (not shared keys), audit rows capturing identity/agent/tool/decision/policy, two-person approval, six-year ePHI retention, and PHI redaction before any egress. The structural conclusion: **deterministic, pre-reviewed workflows are certifiable; black-box multi-agent systems are not.** "No human request behind a change" is itself a major compliance gap — which is precisely why Ralph-style opacity is disqualifying here.

---

## 4. Mapping to the Athena Digital Case Study

*(Athena Digital, SF-2026-02, is a fictional March 2026 Gauntlet case study. It appears closely modeled on the Allred/Gauntlet "software factory" movement described above. The mapping below connects the concepts to its four design areas and constraints: 7 repos, 3 languages, 4 DBs, no monorepo; ≥80% first-run CI pass; <30 min cleanup; SOC2/HIPAA auditable; human-in-the-loop; v1 = 3 engineers, 60 days, CRUD+UI across two products.)*

Athena's diagnosis *is* the industry thesis verbatim: coding is 22% of work, perceived gains are 30–40% but cycle time improved only 11% / throughput 8%. The Faros and METR data are the quantitative backbone for why a *system-level redesign* — not more copilots — is required [4][7][8]. The four design areas map cleanly:

**Design Area 1 — Codebase Intelligence (the must-build).** No current tool solves brownfield convention-conformance across a heterogeneous fleet; this is the differentiating component Athena must own [33]. Concrete recommendation: **lead with a deterministic structural index** (tree-sitter repo maps work day-one across TS/Python/Go [34]), then layer **incremental, self-hosted retrieval** (Merkle-diffed, audit-friendly, fits 23 deploys/day). Encode each product's conventions as **hard contracts** (the repo's own lint/type/test rules) plus per-repo `AGENTS.md`/Steering/`constitution.md` files [26][28], and treat the **4 patterns as the unit of reuse** — exactly Devin's documented sweet spot of "pattern-following brownfield tasks" [30]. Prefer per-change scoping over per-system specs to stay inside review limits [33].

**Design Area 2 — Orchestration & Decomposition.** Adopt a **deterministic coordinator + role-scoped agents with explicit allowed flows** (Factory-style droids / graph DAG) [35], **not** a Ralph/Gas-Town swarm. The 4 patterns become DAG templates; **v1 CRUD+UI is a near-deterministic, fixed DAG** with typed contracts at each handoff and per-node checkpoints. This is what makes ≥80% first-run CI pass plausible across 7 repos without the human becoming the workflow engine (BMAD's documented failure [20]).

**Design Area 3 — Quality & Verification.** Implement **backpressure gates inside the loop** so the agent self-repairs before opening a PR, then rerun the *same* CI on the PR. Use **selective CI + bounded retries** (Stripe's model [32]) to respect the integration bottleneck. Separate test-authoring from implementation; use acceptance-criteria-as-properties to prevent tautological tests. Pattern-narrowing to CRUD+UI is what makes the 80% bar realistic given Devin's 67% real-world ceiling on broader work [31].

**Design Area 4 — Human Interface & Trust.** Satisfy "nothing ships without review" *and* <30-min cleanup by **shifting review upstream to the plan artifact** [12], surfacing a design summary for approval plus spot-check anchors, with approval as an auditable tool call [13]. Emit per-PR the spec/plan/contracts/stage-scoped commits and an **immutable, identity-attributed audit record** for SOC2/HIPAA. Per-product trust thresholds let the two pilot products graduate independently.

**Why the greenfield-single-dev assumptions break BMAD (and Ralph) for Athena:** BMAD's monolithic "one Brief / one PRD / one Architecture" model is incompatible with 7 heterogeneous repos and trunk-based parallel features, and it makes the human the coordination engine [20]. Ralph's nondeterminism, lack of drift detection, opaque recovery, and tendency to reimplement existing features violate both the auditability/SOC2-HIPAA constraints and the brownfield convention-conformance requirement [23]. **The correct synthesis is Stripe's:** wrap a bounded, narrowly-scoped agentic core in deterministic guardrails — more controllable than Ralph, less brittle and less verbose than BMAD [32]. Narrowing v1 to one pattern across two products is the de-risking move every source's failure analysis supports.

---

## 5. Key Takeaways

1. **Coding is ~22% of the work; the factory's job is the other ~78%.** Copilots accelerate the minority slice and don't move team velocity — Faros found +21% tasks but no company-level delivery gain, and +91% review time [4][7].
2. **Factory ≠ copilot.** The defining features are an orchestration layer, automated verification backpressure, a learning loop, and incremental trust expansion — not a smarter model [3].
3. **Review is the new bottleneck — so review the plan, not the diff.** A bad line of research becomes thousands of bad lines of code; concentrate scarce human attention on small, auditable spec/plan artifacts [12].
4. **Determinism wins for control and compliance.** "Don't use prompts for control flow"; the reliable pattern is deterministic orchestration with surgically-placed, narrowly-scoped LLM steps — the synthesis behind Stripe's 1,000+ unattended PRs/week [11][32].
5. **Codebase intelligence is the one thing you must build.** No off-the-shelf tool solves brownfield convention-conformance across a multi-repo/multi-language fleet, because the rules live in developer memory. Lead with structural indexing, layer retrieval, enforce conventions as hard contracts [33][34].
6. **Pattern-narrowing + strong verification, not raw model power, hits the quality bar.** Devin's real-world ceiling is ~67% merge; an 80%+ first-run target is reachable only by constraining to well-defined patterns with fast in-loop gates [31][32].
7. **Backpressure is the most transferable idea from the loop crowd.** CI/tests/types/lint as non-zero-exit gates inside the loop drive convergence; selective CI + bounded retries make integration tractable [23][32].
8. **Discount the hype.** Kelly Claude's "autonomous factory," Elad Gil's "5–10x team reduction" (**no traceable primary source — unverified, possibly fabricated**), and the "60% of non-engineers contribute code" figure (**a real DX report, but misstated — it's ~60% of designers/PMs *using AI daily*, not contributing code**) are all narrative, not audited engineering metrics [15][17]. Demand measurable acceptance criteria (CI pass rate, cleanup time).

### Uncertainty ledger

- **Stripe "~30% of bugs in a Fix-It Week":** [unverified] — not in Stripe's primary posts; secondary only.
- **HumanLayer/ACE results** (35k LOC in 7 hours, etc.): [unverified at scale] — self-reported, single team; authors flag limited generalizability.
- **iamkelly.ai autonomy/revenue/tech-stack claims:** [unverified] — promotional, token-incentivized.
- **Elad Gil "5–10x":** [unverified] — no traceable primary source.
- **"60% of non-engineers contribute code":** misstated; the real DX figure is ~60% of designers/PMs *use AI daily*.
- **BMAD "55–58% hours saved"** and **Devin Mercedes/Itaú case studies:** vendor/community claims, not controlled studies.

---

## 6. Sources

1. Greenfield & Short, *Software Factories* (Wiley, 2004) — https://www.softwarefactories.com/TheBook.html
2. Software factory (Microsoft .NET) — Wikipedia — https://en.wikipedia.org/wiki/Software_factory_(Microsoft_.NET)
3. Mager, "Software Factory: The End Goal of Agentic Engineering" (Mar 2026) — https://www.mager.co/blog/2026-03-19-software-factory/
4. Riggins, "Writing code was never the bottleneck" — LeadDev (Aug 2025) — https://leaddev.com/velocity/writing-code-was-never-the-bottleneck
5. Galbraith, "The bottleneck has shifted" — Depot (Feb 2026) — https://depot.dev/blog/the-bottleneck-has-shifted
6. "AI Coding Assistants Haven't Sped up Delivery…" (Agoda) — InfoQ (Mar 2026) — https://www.infoq.com/news/2026/03/agoda-ai-code-bottleneck/
7. "The AI Productivity Paradox Research Report" — Faros AI — https://www.faros.ai/blog/ai-software-engineering
8. METR, "Early-2025 AI experienced OS developer study" (2025) — https://metr.org/blog/2025-07-10-early-2025-ai-experienced-os-dev-study/
9. Harness, "State of Software Delivery Report 2025" (press release) — https://www.prnewswire.com/news-releases/harness-releases-its-state-of-software-delivery-report-developers-excited-by-promise-of-ai-to-combat-burnout-but-security-and-governance-gaps-persist-302345391.html
10. HumanLayer on Y Combinator — https://www.ycombinator.com/companies/humanlayer
11. humanlayer/12-factor-agents (GitHub) — https://github.com/humanlayer/12-factor-agents
12. Advanced Context Engineering for Coding Agents (ace-fca.md) — https://github.com/humanlayer/advanced-context-engineering-for-coding-agents/blob/main/ace-fca.md
13. humanlayer/humanlayer (SDK + CodeLayer) — https://github.com/humanlayer/humanlayer
14. DeepWiki: Frequent Intentional Compaction (FIC) — https://deepwiki.com/humanlayer/advanced-context-engineering-for-coding-agents/4.2-frequent-intentional-compaction-(fic)
15. Kelly Claude AI — iamkelly.ai — https://iamkelly.ai/
16. Austen Allred — Founder, Gauntlet AI (LinkedIn) — https://www.linkedin.com/in/austenallred
17. Kelly Claude (KELLYCLAUDE): When AI Personas Enter the Token Economy — XT — https://www.xt.com/en/blog/post/kelly-claude-kellyclaude-when-ai-personas-enter-the-token-economy
18. Austen Allred on X — Gauntlet "autonomous software factory" challenge — https://x.com/Austen/status/2033933431529173238
19. BMAD-METHOD (GitHub) — https://github.com/bmad-code-org/BMAD-METHOD
20. BMAD-METHOD Issue #446 — feature-driven approach and agent coordination (brownfield critique) — https://github.com/bmad-code-org/BMAD-METHOD/issues/446
21. Huntley, "Ralph Wiggum as a software engineer" (Jul 2025) — https://ghuntley.com/ralph/
22. ghuntley/how-to-ralph-wiggum (GitHub) — https://github.com/ghuntley/how-to-ralph-wiggum
23. "The Ralph Loop: Long-Running AI Agents" — ZeroSync — https://www.zerosync.co/blog/ralph-loop-technical-deep-dive
24. "Spec-driven development with AI: new open-source toolkit" — GitHub Blog (Sept 2, 2025) — https://github.blog/ai-and-ml/generative-ai/spec-driven-development-with-ai-get-started-with-a-new-open-source-toolkit/
25. GitHub Spec Kit Documentation — https://github.github.com/spec-kit/
26. Kiro — "Introducing Kiro" — https://kiro.dev/blog/introducing-kiro/
27. Kiro — "New spec types: fix bugs and build on top of existing apps" — https://kiro.dev/blog/specs-bugfix-and-design-first/
28. Codex (AI agent) — Wikipedia (AGENTS.md, CLI launch, subagent model, execution-backed review) — https://en.wikipedia.org/wiki/Codex_(AI_agent)
29. "Introducing Codex" — OpenAI — https://openai.com/index/introducing-codex/
30. "Devin, the AI Engineer: Review, Testing & Limitations in 2026" — Idlen — https://www.idlen.io/blog/devin-ai-engineer-review-limits-2026/
31. "Devin AI Software Engineer Explained" (67% merge rate; case studies) — Skywork — https://skywork.ai/blog/devin-ai-software-engineer-cognition-definition/
32. "Minions: Stripe's one-shot, end-to-end coding agents" — Stripe Dev Blog — https://stripe.dev/blog/minions-stripes-one-shot-end-to-end-coding-agents
33. "Spec-Driven Development for Brownfield Enterprise Codebases" — Augment Code — https://www.augmentcode.com/guides/spec-driven-development-brownfield-codebases
34. "Building a better repository map with tree-sitter" (PageRank repo map) — Aider — https://aider.chat/2023/10/22/repomap.html
35. "Factory AI: Multi-Agent Coding Platform Review 2026" (coordinator + role-scoped droids) — Digital Applied — https://www.digitalapplied.com/blog/factory-ai-multi-agent-coding-platform-review
36. "The AI Productivity Paradox" coverage ("More Code, More Bugs") — ADTmag (Apr 22, 2026) — https://adtmag.com/articles/2026/04/22/more-code-more-bugs.aspx
37. DX, "AI-assisted engineering: Q4 impact report 2025" (origin of the ~60% designers/PMs figure) — https://getdx.com/blog/ai-assisted-engineering-q4-impact-report-2025/
38. "Welcome to Gas Town" (Beads, Mayor/Polecats/Refinery, nondeterministic idempotence) — Steve Yegge — https://steve-yegge.medium.com/welcome-to-gas-town-4f25ee16dd04
39. "Understanding Spec-Driven Development: Kiro, spec-kit, and Tessl" — Martin Fowler — https://martinfowler.com/articles/exploring-gen-ai/sdd-3-tools.html
40. Sabaliauskas, "A Comparative Analysis of AI Agentic Frameworks: BMAD-Method vs. GitHub Spec Kit" — https://medium.com/@mariussabaliauskas/a-comparative-analysis-of-ai-agentic-frameworks-bmad-method-vs-github-spec-kit-edd8a9c65c5e
