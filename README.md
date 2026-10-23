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
./PiSandboxApp/build.sh        # -> PiSandboxApp/dist/PiSandbox.app and PiSandbox.zip
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

## Guiding the agent

`agent-home/AGENTS.md` holds always-on rules. `agent-home/skills/` holds skills
(`sandbox-workflow`, `small-steps`, `verify-before-done`). Edit freely.

## License

MIT
