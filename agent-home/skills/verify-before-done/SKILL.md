---
name: verify-before-done
description: Final verification pass before saying a task is finished. Use before reporting completion of any change.
---

1. Run the project's tests/build/lint (find them via package.json, Makefile, Gemfile, README).
2. If none exist, run the program once with a realistic input and show the output.
3. `git diff --stat` and skim the full diff for leftover debug code, unrelated edits, secrets.
4. Report: commands run, pass/fail with real output, any known gaps. Never say "should work".
