---
name: ai-sdd-cheatsheet
description: Print the diagram-driven ai-sdd workflow cheatsheet — the canonical command sequence (bootstrap → plan → run, validate/next/submit/status) that travels with the binary. Use when a user forgets which command comes next, asks "how do I drive a run / what's the workflow", or needs the command reference without leaving the repo.
---

# Show the ai-sdd cheatsheet

This skill is a **thin shell**. The cheatsheet's content lives entirely in the `ai-sdd` binary — the
skill only invokes it and relays the result. Do **not** re-derive, reformat, summarize, or add
commands of your own; the CLI is the single source of truth.

## What to do

1. From the **repo root**, run the cheatsheet command. Prefer the on-PATH binary; fall back to the
   debug build if `ai-sdd` is not resolvable:

   ```sh
   ai-sdd cheatsheet               # preferred — the installed, on-PATH binary
   .build/debug/ai-sdd cheatsheet  # fallback — when ai-sdd is not on PATH
   ```

2. **Relay the command's output VERBATIM.** Show exactly what the binary prints. Do not edit,
   re-order, trim, or annotate the lines.

## Optional light touch

If the **current conversation already makes the user's workflow step obvious** (e.g. they just
finished planning and are about to run), you MAY prepend a **single** orienting line before the
relayed output:

```
You're here: <step> → <command>
```

Otherwise add nothing. This is the only permitted embellishment.

**NO CLI/state detection.** Do not inspect disk, read `.ai-sdd/`, run `status`/`next`, or otherwise
probe the repo to guess the user's state. The optional line comes solely from what the conversation
already makes obvious — never from disk.
