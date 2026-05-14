# Host isolation rules

**Hard constraint:** Everything the lab does happens inside containers. The host OS is read-only from the lab's perspective. This isn't a style preference — it's a safety contract with the user.

## Forbidden — never do these

- `sudo` anything. Any command requiring host root.
- Install host packages: `apt`, `apt-get`, `yum`, `dnf`, `brew`, `pacman`, `pip install` *outside* a container or venv.
- Write to host system paths: `/etc/`, `/usr/`, `/var/` (outside container layers), `/boot/`, `/lib/`, `/lib64/`, `/opt/`.
- Modify systemd units, write to `~/.config/systemd/`, run `systemctl`.
- Change kernel parameters: `sysctl`, writes to `/proc/sys/*`, writes to `/sys/*`.
- Edit shell rc files on the host: `~/.bashrc`, `~/.zshrc`, `~/.profile`, `~/.bash_profile`.
- Bind to privileged host ports (< 1024).
- Modify `/etc/hosts`, `/etc/resolv.conf`, or DNS resolver config on the host.

In `docker-compose.yml`, the following are forbidden unless the topic *is* that capability and the use is justified in RESEARCH.md "Design decisions":

- `privileged: true`
- `network_mode: host`
- `pid: host`
- `ipc: host`
- `cap_add` for `SYS_ADMIN`, `NET_ADMIN`, `SYS_PTRACE`, or `ALL`
- Bind mounts whose source is outside `./labs/<topic-slug>/`. Particularly: no `/var/run/docker.sock`, no `/etc/`, no `$HOME`, no `/` itself.

## Required — always do these

- All state lives inside the lab directory. Use named volumes scoped to the lab, or relative bind mounts (e.g., `./data:/var/lib/...`).
- Run as a non-root user inside containers wherever the upstream image supports it.
- Host port mappings use the high range (≥ 15000). Default values surfaced in `.env.example` so users can change them.
- Every service has `healthcheck:` or a one-line comment explaining why none is needed (rare; almost always a code smell).

## Pre-validation checklist

Run these greps before invoking `scripts/validate_lab.sh`. Any hit must be resolved at the root — do not delete the check.

```bash
cd labs/<topic-slug>

# 1. Forbidden compose flags
grep -nE 'privileged:|network_mode:.*host|pid:.*host|ipc:.*host' docker-compose.yml && echo "FAIL: forbidden compose flag" && exit 1

# 2. Forbidden bind-mount sources (anything starting with absolute system path)
grep -nE '^\s*-\s+(/etc|/var|/usr|/home|/root|/boot|/lib|/proc|/sys)(/|:)' docker-compose.yml && echo "FAIL: forbidden bind source" && exit 1

# 3. docker.sock mount
grep -n 'docker.sock' docker-compose.yml && echo "FAIL: docker socket mount" && exit 1

# 4. sudo anywhere in lab files
grep -rn 'sudo ' . && echo "FAIL: sudo in lab files" && exit 1

# 5. Privileged host ports
grep -nE '^\s+-\s+"[0-9]{1,3}:' docker-compose.yml && echo "FAIL: privileged host port" && exit 1

echo "Pre-validation checks passed."
```

(The checklist is run as part of `scripts/validate_lab.sh`; the script aborts if any check fails.)

## When a topic genuinely needs more

Some topics are *about* capabilities normally forbidden — e.g., demonstrating a packet-capture proxy may need `cap_add: NET_ADMIN`. In those cases:

1. State the requirement in RESEARCH.md "Design decisions" with a one-paragraph justification.
2. Use the minimum capability needed (prefer specific `cap_add` over `privileged: true`).
3. Document the implication in README.md so the user running the lab knows what they are granting.

If the topic requires modifying the host OS to work at all (kernel module load, sysctl change), the skill must decline the topic and explain why to the user.
