# Example: the SDLC Plant

A worked set of specs for the PM → Design → Engineering → Ops lifecycle described in
[../../architecture.md](../../architecture.md) §13. These are **illustrative reference
specs** showing the format at each level — not live engine config (the engine doesn't
exist yet). They are intentionally cross-consistent: the Plant references the Factory,
the Factory references the Pipeline, the Pipeline references the Worker, the Worker
references the Check.

```
sdlc-plant/
├── config.yaml                       # layered context injection + active model catalog
├── models.yaml                       # Model Catalog: tiers -> (provider, model, reasoning)
├── plant.yaml                        # the whole Plant: factories + conductor + contracts
├── factories/
│   ├── code.factory.yaml             # the Code Factory
│   └── requirements.factory.yaml     # the Requirements Factory (vague idea -> locked spec)
├── pipelines/
│   ├── crud-ui.pipeline.yaml         # a typed DAG (an OPSX-style schema)
│   └── requirements.pipeline.yaml    # normalize -> clarify <-> ask -> author
├── workers/
│   ├── load.gdoc.worker.yaml         # a transport loader: Google Doc -> intake-source.v1
│   ├── intake.normalizer.worker.yaml # JOIN: synthesizes a SET of sources -> one normalized-intake.v1
│   ├── coder.api.worker.yaml         # a Worker: write-scoped, stack-parameterized
│   ├── reviewer.worker.yaml          # a read-only Worker (capability guardrails)
│   └── await-ci.worker.yaml          # a sensor: park on an async event (CI/MR), resume later
├── checks/
│   ├── typecheck.go.check.yaml       # a deterministic gate/eval
│   ├── no-open-decisions.check.yaml  # the "spec locked" repeatability gate
│   └── contract-compat.check.yaml    # enforces additive=>minor / breaking=>new-major (ADR-0017)
├── resources/
│   ├── github.resource.yaml          # a Resource (hands): MCP or CLI + access scope
│   └── google-docs.resource.yaml     # the transport for the gdoc intake loader
├── traits/
│   └── apple.traits.yaml             # composable convention/capability modules
├── stacks/
│   └── ios-mac-app.stack.yaml        # a Stack = a named bundle of Traits
└── schemas/
    └── intake-source.schema.yaml     # intake-bundle (a union of sources) + intake-source (discriminated envelope)
```

All files use a Kubernetes-style `apiVersion` / `kind` / `metadata` / `spec` envelope —
familiar, fork-friendly, and a reminder that **specs are data**.
