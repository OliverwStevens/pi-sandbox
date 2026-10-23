---
name: sandbox-workflow
description: Default plan-implement-check loop for any coding task in the sandbox. Use at the start of a non-trivial task (new feature, bug fix, refactor).
---

1. Restate the goal in one sentence and list acceptance checks (a command that must pass).
2. `git status`; if the tree is dirty, commit or stash first so the work is revertable.
3. Explore with `rg` and targeted reads. Write a 3-5 line plan.
4. Implement the smallest slice. Run the acceptance check.
5. Fix failures from real output, not guesses. Repeat 4-5.
6. Commit a checkpoint. Summarize: what changed, what was verified, what is left.
