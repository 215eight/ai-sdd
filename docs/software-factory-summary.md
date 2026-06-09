# Software Factory — The Simple Version (with Diagrams)

A plain-English companion to [software-factory-research.md](software-factory-research.md).
All diagrams are Mermaid — they render on GitHub, VS Code, and most markdown viewers.

---

## 1. The core surprise: code is the easy part

Everyone thinks AI makes teams fast because it writes code quickly. But writing
code was only ever a small slice of the job. AI speeds up that slice — and leaves
the rest untouched.

```mermaid
pie showData
title Where an engineer's time actually goes
"Writing code — the part AI speeds up" : 22
"Everything else — specs, design, integration, review, testing, deploy" : 78
```

**In one line:** if AI makes 22% of the work twice as fast, the whole job barely
moves. That's why teams *feel* 30–40% faster but only ship ~11% faster.

---

## 2. Copilot vs. Factory: a helper vs. an assembly line

A **copilot** sits next to one engineer and helps them type faster.
A **factory** takes a feature request and runs it down an assembly line to a
finished, reviewed pull request — the human checks the work instead of doing it.

```mermaid
flowchart LR
    subgraph COPILOT["🧑‍💻 COPILOT — a helper"]
        direction TB
        A1["Engineer writes code"] --> A2["AI autocompletes / suggests"]
        A2 --> A3["Engineer still does the other 78%"]
    end

    subgraph FACTORY["🏭 FACTORY — an assembly line"]
        direction TB
        B1["Engineer writes a short spec"] --> B2["System builds the whole feature"]
        B2 --> B3["Engineer reviews & approves"]
    end

    COPILOT -.->|"the upgrade you actually want"| FACTORY
```

A factory isn't "a smarter AI." It's three extra things bolted around the AI:
a **coordinator** (decides the order of work), **automatic checks** (catch mistakes
before a human sees them), and a **learning loop** (gets better over time).

---

## 3. What the assembly line looks like

The spec goes in, and the work flows through stages that depend on each other.
After every stage there's an automatic **gate**: tests, type-checks, and linters.
If a gate fails, the robot fixes its own work and retries — *before* a human is
ever asked to look.

```mermaid
flowchart LR
    SPEC["📝 Short feature spec"] --> PLAN["🗺️ Make a plan<br/>break work into ordered steps"]
    PLAN --> DB["Database changes"]
    DB --> API["API layer"]
    API --> UI["Frontend / UI"]
    UI --> TEST["Tests"]

    DB -.-> GATE
    API -.-> GATE
    UI -.-> GATE
    TEST -.-> GATE
    GATE{"✅ Automatic checks<br/>tests · types · linters"}
    GATE -->|"fails"| FIX["🤖 Robot fixes itself<br/>and retries"]
    FIX --> GATE
    GATE -->|"passes"| PR["📦 Pull request<br/>ready for human review"]
    PR --> HUMAN["🧑‍⚖️ Human approves"]
```

The trick that makes this reliable: **the checks live inside the loop, not just at
the end.** The robot can't move forward with broken work.

---

## 4. The biggest time-saver: review the plan, not the code

Humans are the slow, expensive part now (review time balloons with AI). The fix
isn't reviewing faster — it's reviewing *earlier and smaller*. Check the short plan,
not the giant pile of code, because mistakes get more expensive the later you catch them.

```mermaid
flowchart TD
    R["❌ Bad line of research"] --> R2["leads to..."]
    R2 --> P["❌❌ Bad section of the plan"]
    P --> P2["leads to..."]
    P2 --> C["❌❌❌ Hundreds of bad lines of code"]

    style R fill:#fff3cd,stroke:#d39e00
    style P fill:#ffe0b2,stroke:#e8590c
    style C fill:#f8d7da,stroke:#c92a2a
```

> A bad line of code is one bad line. A bad line of *plan* becomes hundreds of bad
> lines of code. So spend your scarce review attention up at the plan.

---

## 5. The four hard problems (and which is hardest)

Building a factory means solving four things. Three have decent off-the-shelf
tools. One you have to build yourself.

```mermaid
flowchart TB
    F["🏭 Software Factory"] --> P1
    F --> P2
    F --> P3
    F --> P4

    P1["🧠 Codebase Intelligence<br/><i>make the AI match YOUR code's style</i>"]
    P2["🔀 Orchestration<br/><i>do the steps in the right order</i>"]
    P3["✅ Verification<br/><i>make sure it actually works</i>"]
    P4["🤝 Trust & Review<br/><i>let humans approve safely</i>"]

    P1 --> H["⚠️ THE HARD ONE<br/>No tool solves this for you.<br/>Your code's rules live in<br/>people's heads, not docs."]

    style P1 fill:#e7f5ff,stroke:#1971c2
    style H fill:#fff5f5,stroke:#c92a2a
```

**Why codebase intelligence is the hard one:** every team has unwritten rules
("we always do payments *this* way"). A spec never captures them, so the AI writes
code that compiles but breaks your conventions. You have to teach the factory your
house style.

---

## 6. Which approach should you copy?

Three well-known styles. Two are popular but break in a real multi-team company.
One is the proven winner.

```mermaid
flowchart LR
    subgraph BMAD["📋 BMAD — strict checklist"]
        direction TB
        M1["Lots of upfront planning docs"]
        M2["⚠️ Human ends up<br/>running the whole thing"]
        M3["Assumes 1 dev, fresh project"]
    end

    subgraph RALPH["🔁 Ralph — loop a robot"]
        direction TB
        R1["Cheap, simple, runs alone"]
        R2["⚠️ Unpredictable, hard to audit"]
        R3["Rewrites things it shouldn't"]
    end

    subgraph STRIPE["🏆 Stripe-style — guardrails"]
        direction TB
        S1["Robot does the creative part"]
        S2["✅ Fixed steps it MUST follow"]
        S3["1,000+ auto-merged PRs / week"]
    end

    BMAD -.->|"too rigid"| STRIPE
    RALPH -.->|"too loose"| STRIPE
```

**The winning recipe (Stripe's):** let the AI be creative *inside* strict,
deterministic guardrails. More controllable than a free-running loop, less rigid
and bureaucratic than a checklist. This is the pattern to build toward.

---

## 7. The whole thing in seven sentences

```mermaid
mindmap
  root(("🏭 Software<br/>Factory"))
    ("1 · Code is only ~22% of the work")
      ("attack the other 78%")
    ("2 · Factory ≠ smarter AI")
      ("it's orchestration + checks + learning")
    ("3 · Review the plan, not the diff")
      ("catch mistakes while they're cheap")
    ("4 · Determinism wins")
      ("AI inside strict guardrails")
    ("5 · Build codebase intelligence yourself")
      ("teach it your house style")
    ("6 · Narrow scope + strong checks")
      ("beats a bigger model")
    ("7 · Ignore the hype")
      ("demand real numbers: CI pass rate, cleanup time")
```

1. **Code is the easy 22%** — the factory's real job is the other 78%.
2. **A factory is not a smarter AI** — it's a coordinator + automatic checks + a learning loop.
3. **Review the plan, not the code** — fix mistakes while they're still one sentence.
4. **Boring and predictable wins** — let AI be creative *inside* strict guardrails.
5. **Codebase intelligence is yours to build** — no tool teaches the AI your house style.
6. **Narrow the job, check it hard** — that beats waiting for a smarter model.
7. **Discount the hype** — "fully autonomous" demos are marketing; demand real metrics.
