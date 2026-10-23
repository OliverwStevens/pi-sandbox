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
if [ -d /workspace/.git/hooks ]; then blocked "Git hooks folder is read-only (they run on your Mac)" touch /workspace/.git/hooks/pre-commit; fi
if [ -f /workspace/.git/config ]; then blocked "Git config is read-only (no new remotes or hooks)" bash -c 'echo x >> /workspace/.git/config'; fi
if [ -d /workspace/.github ]; then blocked "CI workflows folder is read-only" touch /workspace/.github/probe; fi

if [ "${NET_MODE:-open}" = locked ]; then
  if net example.com 443; then fail "Internet is reachable"; else pass "Internet is blocked (example.com)"; fi
  if net github.com 443; then fail "GitHub is reachable"; else pass "GitHub is blocked"; fi
  if net 1.1.1.1 443; then fail "Raw IP addresses are reachable"; else pass "Direct IP connections are blocked"; fi
  if net host.containers.internal "${HOST_PORT:-8001}"; then fail "Mac localhost services are reachable directly"; else pass "Your Mac's localhost services are not reachable"; fi
  if net "${GATE:-pi-gate}" "${HOST_PORT:-8001}"; then pass "Model server is reachable through the gate"; else fail "Model server is NOT reachable through the gate"; fi
else
  if net example.com 443; then echo "WARN Outbound internet is reachable (internet access is ON)"; else echo "PASS Outbound internet blocked"; fi
  if net host.containers.internal "${HOST_PORT:-8001}"; then echo "WARN Mac localhost services are reachable via host.containers.internal (internet access is ON)"; fi
fi
