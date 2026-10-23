---
name: small-steps
description: Break a large or vague task into small verifiable steps. Use when a request is big, ambiguous, or touches many files, especially with a small local model.
---

1. Write the task as a numbered checklist in /workspace/.pi-plan.md (max 8 items, each independently checkable).
2. Do exactly one item at a time. After each: run its check, tick it off in the file, commit.
3. Re-read the checklist before starting each item; do not rely on memory of earlier context.
4. If an item grows beyond ~50 lines of change, split it.
5. Delete .pi-plan.md when everything is done.
