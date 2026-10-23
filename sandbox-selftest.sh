#!/usr/bin/env bash
# Runs INSIDE the sandbox container. Prints "PASS|FAIL|WARN <description>" lines.
# Env: CANARY (path of a host file outside the project that must be invisible), HOST_PORT (model server port).
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; }
blocked() { local d=$1; shift; if "$@" >/dev/null 2>&1; then fail "$d"; else pass "$d"; fi; }
check()   { local d=$1; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }

blocked "Cannot write to system dirs (read-only root filesystem)" touch /usr/probe
blocked "Cannot modify /etc" touch /etc/probe
check   "All Linux capabilities dropped" grep -Eq '^CapEff:[[:space:]]*0+$' /proc/self/status
check   "no-new-privileges is set" grep -Eq '^NoNewPrivs:[[:space:]]*1' /proc/self/status
blocked "Cannot mount filesystems" mount -t tmpfs none /mnt
blocked "No container-engine socket exposed" test -e /var/run/docker.sock -o -e /run/podman/podman.sock
blocked "Host home folder not visible (/Users)" test -e /Users
blocked "No SSH keys or host credentials (~/.ssh)" test -e /root/.ssh
if [ -n "${CANARY:-}" ]; then
  blocked "Host file outside the project is invisible" bash -c "find / -xdev -name '$(basename "$CANARY")' 2>/dev/null | grep -q . || find / -name '$(basename "$CANARY")' -not -path '/proc/*' -not -path '/workspace/*' 2>/dev/null | grep -q ."
fi
check   "Project folder is writable" bash -c 'touch /workspace/.selftest && rm /workspace/.selftest'
check   "Home dir is a throwaway tmpfs" grep -q ' /root tmpfs ' /proc/mounts
check   "Memory limit enforced" bash -c '[ "$(cat /sys/fs/cgroup/memory.max)" != max ]'
check   "Process limit enforced" bash -c '[ "$(cat /sys/fs/cgroup/pids.max)" != max ]'
blocked "Env has no host secrets (only OMLX_API_KEY passed in)" bash -c 'env | grep -Eiq "^(AWS_|GITHUB_|GH_|ANTHROPIC_|OPENAI_|SSH_AUTH_SOCK)"'

net() { node -e "const net=require('net');const [h,p]=process.argv.slice(1);const s=net.connect({host:h,port:+p,timeout:3000},()=>process.exit(0));s.on('error',()=>process.exit(1));s.on('timeout',()=>process.exit(1))" "$1" "$2"; }
if net example.com 443; then echo "WARN Outbound internet is reachable (not blocked)"; else echo "PASS Outbound internet blocked"; fi
if net host.containers.internal "${HOST_PORT:-8001}"; then echo "WARN Host loopback services are reachable via host.containers.internal (model server, and any other local port)"; fi
