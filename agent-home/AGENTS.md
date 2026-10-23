# Sandbox rules

You run inside a throwaway Podman container. Only /workspace is real; everything else is discarded on exit.
You may run any command without asking. Be bold but small.

- Work only under /workspace. Never try to read or change anything outside it.
- Prefer small steps: change one thing, run it, look at the output, then continue.
- Read the code and existing tests before editing. Match the surrounding style.
- Use `rg` to search, not recursive `ls`/`cat` loops.
- Never claim success without running a check (tests, build, linter, or the program itself). Quote the real output.
- If stuck after 3 attempts at the same approach, stop and explain what you tried; do not loop.
- Use git: `git status` before starting, commit working checkpoints often so changes are easy to undo.
- No network installs of unknown packages without saying why. Prefer what is already present.
- Keep answers short. Show diffs and results, not essays.
