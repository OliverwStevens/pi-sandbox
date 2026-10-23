# pi-sandbox

Run the [pi coding agent](https://github.com/earendil-works/pi) in "yolo" mode inside a locked-down
Podman container on macOS, talking to an OpenAI-compatible model server (omlx, Ollama, LM Studio, ...)
that runs on your Mac. Includes a small SwiftUI app to set it all up and launch it.

## How it works

- Pi runs in a Podman container (Podman machine VM on macOS). Only the project folder you choose is mounted at `/workspace`.
- The container reaches your host model server at `host.containers.internal:<port>`.
- Hardening: `--cap-drop=ALL`, `no-new-privileges`, read-only root filesystem, tmpfs for `/tmp` and `/root`, memory/CPU/PID limits, fresh agent home each run.
- Pi is installed at a pinned version with `--ignore-scripts`.
- **Not restricted:** outbound network. Pi can reach the internet and your LAN. Use git; pi can delete anything in the mounted folder.

## App

Requires macOS 14+, Apple silicon, and Command Line Tools (no Xcode needed).

```bash
./PiSandboxApp/build.sh        # -> PiSandboxApp/dist/PiSandbox.app, .zip and .dmg
```

The app is ad-hoc signed, not notarized. On another Mac: right-click the app and choose Open, or run
`xattr -dr com.apple.quarantine PiSandbox.app`.

The app checks podman, the podman machine, the image and your model server; lets you pick host/port/API key/model
and a project folder; and launches pi in Terminal. Config lives in `~/Library/Application Support/PiSandbox`
(the API key is stored there in a `0600` file).

## Script only

```bash
export OMLX_API_KEY=...        # your server key
# edit agent-home/models.json: baseUrl port and model id
./pi-sandbox ~/path/to/project
```

## Coding with the sandbox

1. Make sure the project is a git repo with your work committed. Pi can edit or delete anything in the folder.
2. In the app: pick the project folder, check all rows are green, click **Launch Pi**. A Terminal window opens with pi running in `/workspace`.
3. Talk to pi in that terminal. Describe a task; it reads, edits and runs commands inside the container (pi has `git`, `rg`, `node`; install more with the Dockerfile).
4. Review in your normal editor and git on the Mac: `git diff`, `git checkout .` to undo. The folder is shared live, so edits appear in your IDE at once.
5. Useful in pi: `/model` to switch model, `/skill:small-steps` to force a skill, Ctrl+C to interrupt, `/quit` to exit. Stop everything from the menu bar item.

The container has no toolchains for your stack (Ruby, Swift, Python...). Add them to the `Dockerfile`, then rebuild the image from the app.

## Verifying the sandbox

Click **Run self-test** in the app (or run `sandbox-selftest.sh` inside the container with the same flags).
It tries to write system dirs, mount filesystems, find host files and credentials, and checks that capabilities
are dropped and limits are set. Known gaps are reported as warnings: outbound internet is open, and any service
listening on your Mac's loopback is reachable via `host.containers.internal`, not just the model server.

## Monitor tab

While pi runs, the **Monitor** tab ranks the session. Pi's session log is saved to the host and analysed with
heuristic rules: risky shell commands (pipes into a shell, credential paths, uploads, installs, mass deletes),
edits outside the project, and edits to files your Mac later executes (git hooks, CI, scripts, `.envrc`). It
also diffs the project folder for new symlinks and host-executed files, shows container CPU/memory, and lists
network connections that are not the model server. It reports a 0-100 risk score, what the model is doing
(exploring, implementing, verifying, stuck) and which attempts the sandbox blocked. These are heuristics, not proof.

## Guiding the agent

`agent-home/AGENTS.md` holds always-on rules. `agent-home/skills/` holds skills
(`sandbox-workflow`, `small-steps`, `verify-before-done`). Edit freely.

## License

MIT
