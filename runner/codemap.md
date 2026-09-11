# runner/

## Responsibility

Container lifecycle layer for a dockerless, ephemeral GitHub Actions self-hosted runner. Owns the boot-time registration cycle: token minting, state wipe, re-registration, and handoff to the runner listener process.

## Design

- **Init/Supervisor pattern (container entrypoint as bootstrap):** `entrypoint.sh` acts as a one-shot bootstrap; `exec ./run.sh` replaces the shell so the runner process becomes PID 1 and receives container signals directly (`RUNNER_MANUALLY_TRAP_SIG=1`).
- **Idempotent re-registration via `--replace`:** a stable `RUNNER_NAME` (default `cron-runner`) plus `--replace` guarantees GitHub holds exactly one runner entry regardless of container recreations. `--disableupdate` pins the runner version to the image build.
- **Fail-fast environment contract:** `set -euo pipefail`; `GH_TOKEN` and `GH_REPO` are mandatory (`:?` expansion). Failure at any step exits the container, and Compose's `restart: always` retries the whole cycle.
- **Stateless runner, cold starts:** no persistent volumes; every job starts from the image as-is. System deps come from per-run `sudo apt-get` (the image ships sudo with a NOPASSWD sudoers entry for `runner`). `APPIMAGE_EXTRACT_AND_RUN=1` (compose) covers AppImage bundling without FUSE. The entrypoint does no cache work.
- **Secret hygiene:** the PAT (`GH_TOKEN`), repo, and minted token are `unset` before the listener starts, so job processes only see the per-run ephemeral `GITHUB_TOKEN` injected by GitHub.

## Flow

1. Container start → `entrypoint.sh` validates `GH_TOKEN` / `GH_REPO`.
2. `rm -f .runner .credentials .credentials_rsaparams` — wipes previous registration state (required because `config.sh` refuses to run while `.runner` exists).
3. `POST /repos/{GH_REPO}/actions/runners/registration-token` (curl + jq) → extracts `.token`; empty/failed token aborts with a FATAL message.
4. `./config.sh` runs unattended with `--url`, `--token`, `--name`, `--disableupdate`, `--replace`, `--work _work`, plus optional `--labels` from `RUNNER_LABELS`.
5. `unset` all credential variables → `exec ./run.sh` starts the listener.

## Integration

- Built by: root `Dockerfile` (FROM `ghcr.io/actions/actions-runner:$RUNNER_VERSION`, docker binaries stripped, `entrypoint.sh` copied to `/usr/local/bin/`).
- Orchestrated by: `docker-compose.yml` `runner` service (`restart: always`, memory/PID caps, passwordless sudo for job installs, `APPIMAGE_EXTRACT_AND_RUN`).
- Configured by: `.env` via Compose (`GH_TOKEN`, `GH_REPO`, `RUNNER_NAME`, `RUNNER_LABELS`).
- Depends on: GitHub REST API (registration-token endpoint), official runner scripts (`config.sh`, `run.sh`).
- Companion: `scheduler/` dispatches the workflows this runner then executes.
