# Repository Atlas: cron-runner (self-hosted-actions)

## Project Responsibility

A self-hosted GitHub Actions alternative to the unreliable native `schedule:` trigger: a two-container Compose stack where cron dispatches workflows via the GitHub REST API and a dockerless ephemeral runner executes them. One `docker compose up` replaces GitHub's best-effort `schedule:` with your own crontab.

## System Entry Points

- `docker-compose.yml`: Stack definition — `scheduler` and `runner` services, hardening (`cap_drop: ALL`, `no-new-privileges`, memory/PID limits, tmpfs), `.env` variable injection, runner cache bind mount (`./runner-cache` → `/home/runner/.cache`) with toolchain redirect env vars.
- `docker-compose.scheduler.yml` / `docker-compose.runner.yml`: Split templates, one service each (own project `name:`; `cron-runner-scheduler` / `cron-runner-runner`), same hardening as the full stack.
- `Dockerfile`: Runner image — official `ghcr.io/actions/actions-runner` with docker binaries/CLI plugins stripped, plus `git curl unzip jq` and the Tauri release toolchain (GTK/WebKit dev libs, build-essential, rpm, Rust via rustup minimal in `/usr/local`); build-time check that `docker`/`gh` are absent. Entry: `runner/entrypoint.sh`.
- `scheduler/Dockerfile`: Scheduler image — `alpine:3.22` + pinned/SHA256-verified supercronic; Alpine's default crontab removed so a missing mount fails loudly. Entry: `scheduler/entrypoint.sh`.
- `.env.example`: Configuration contract — `GH_TOKEN` (PAT: classic `repo` scope, or fine-grained `Administration:RW` + `Actions:RW`), `GH_REPO`; optional `RUNNER_NAME`, `RUNNER_LABELS`.
- `crontab.example`: Schedule template — cron lines invoking `dispatch.sh WORKFLOW [REF]`, mounted read-only as `/etc/crontabs/root`.

## Directory Map (Aggregated)

| Directory    | Responsibility Summary                                                                                                                                                                                                                                                                   | Detailed Map                     |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| `runner/`    | Ephemeral runner boot cycle: registration-token minting, config wipe, unattended re-registration with `--replace` (exactly one runner entry on GitHub), secret unsetting, then `exec` of the listener. Persistent toolchain cache lives outside this dir, mounted from `./runner-cache`. | [View Map](runner/codemap.md)    |
| `scheduler/` | Cron-to-dispatch translation: supercronic runs the mounted crontab; `dispatch.sh` POSTs `workflow_dispatch` per tick, logging HTTP 204 or deferring to the next tick on failure.                                                                                                         | [View Map](scheduler/codemap.md) |

## Data & Control Flow

1. `.env` supplies `GH_TOKEN`/`GH_REPO` to both services via Compose.
2. Scheduler: supercronic → cron tick → `dispatch.sh` → `POST /repos/{repo}/actions/workflows/{wf}/dispatches` (204 = dispatched, else retry next tick).
3. Runner: boot → wipe `.runner`/credentials → mint registration token → `config.sh --replace --disableupdate` → unset PAT → `exec run.sh`; GitHub queues the dispatched workflow onto the runner (`runs-on: [self-hosted, cron-runner]`).
4. Failure semantics: container exit + `restart: always` re-runs the whole cycle in both halves.

## Cross-Cutting Concerns

- **Containment:** both containers drop all capabilities, forbid privilege escalation, cap memory/PIDs, use tmpfs scratch; no docker daemon, socket, or ports anywhere. The runner's single data volume is the toolchain cache bind mount (`./runner-cache` → `/home/runner/.cache`, env redirects for npm/Go/Gradle/Cargo); it survives recreations and is cleaned manually (`rm -rf runner-cache/*`).
- **Update path:** runner registers with `--disableupdate`; image rebuild (`--build-arg RUNNER_VERSION=`) is the only update path — required at least monthly or GitHub stops queueing jobs.
- **Formatting:** `.pre-commit-config.yaml` enforces shfmt (shell, 4-space indent) and prettier (YAML/Markdown) plus whitespace hygiene.
- **Token lifecycle:** token expiry surfaces as `dispatch FAILED http=401` + runner boot failures; fix requires `docker compose up -d` (recreate, not restart) after updating `.env`.
