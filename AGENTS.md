# AGENTS.md

## Repository Map

A full codemap is available at `codemap.md` in the project root.

Before working on any task, read `codemap.md` to understand:

- Project architecture and entry points
- Directory responsibilities and design patterns
- Data flow and integration points between modules

For deep work on a specific folder, also read that folder's `codemap.md`.

## Commands

- No test suite. Verification: `pre-commit run --all-files` (shfmt for `*.sh` with 4-space indent + `-ci`, prettier for YAML/Markdown).
- Compose validity check: `docker compose config -q` (also with `-f docker-compose.scheduler.yml` / `-f docker-compose.runner.yml` for the split templates).
- Run the stack: `docker compose up -d --build` (only after the setup order below).
- Split templates: `docker compose -f docker-compose.scheduler.yml up -d --build` (scheduler only, needs `./crontab` mounted) and `docker compose -f docker-compose.runner.yml up -d --build` (runner only). Each has its own project `name:` (`cron-runner-scheduler` / `cron-runner-runner`) so both can run from one clone.
- Wipe everything a job installed: `docker compose up -d --build --force-recreate` (tmpfs state dies with the container). The toolchain cache in the `runner-cache` named volume survives everything until wiped: `docker compose exec runner sh -c 'rm -rf /home/runner/.cache/*'` (no downtime) or `docker compose down -v`.

## Setup order (matters)

Run `cp .env.example .env` and `cp crontab.example crontab` **before** `docker compose up -d --build`. If `up` runs first, Docker creates `./crontab` as an empty root-owned directory and the scheduler mount fails; fix with `sudo rm -rf ./crontab` and repeat.

The runner's `runner-cache` volume needs no host setup: the image seeds `/home/runner/.cache` with `runner` ownership, so Docker initializes a fresh volume with correct permissions.

## Recreate vs restart

- `.env` changes (e.g., new `GH_TOKEN`): `docker compose up -d` — `restart` does not re-read `.env`, so containers keep the old value until recreated.
- Crontab edits: `docker compose restart scheduler` is enough (mounted read-only, re-read only at supercronic start).

## Runner updates

The runner registers with `--disableupdate`: image rebuild is the only update path. GitHub stops queueing jobs to runners more than 30 days behind — rebuild monthly with `docker compose build --build-arg RUNNER_VERSION=<latest>` then `docker compose up -d`.

## Token contract

One PAT serves both services; a read-only token fails. Classic: `repo` scope. Fine-grained: `Actions: RW` + `Administration: RW`, and the token user must be admin on `GH_REPO`. Token expiry shows as `dispatch FAILED http=401` plus runner boot failures — fix by updating `.env` and recreating.

## Shell dialects

- `scheduler/*.sh` run on Alpine busybox: POSIX `/bin/sh`, `set -eu`; no bash-only syntax.
- `runner/entrypoint.sh` is bash on the actions-runner image: `set -euo pipefail`.

## Conventions

- Cron lines call `dispatch.sh WORKFLOW [REF]` (ref defaults to `main`); the repo always comes from `GH_REPO`. The old `OWNER/REPO WORKFLOW REF` form is rejected by the script.
- Secrets (`.env`, `.env.prod`, `crontab`) are gitignored: never commit or print them.
- Docker stays out by design (dockerless runner, no socket, stripped binaries, build-time check). Keep image/Compose edits docker-free.
- apt-level toolchain deps (Tauri libs, build-essential) are baked into the `Dockerfile`: the runner is non-root with no sudo, so a workflow's own `sudo apt-get install` step can never work. Workflow edits in target repos must drop such steps. Rust is not baked: workflows install it per-run (e.g. `dtolnay/rust-toolchain`), persisted via `CARGO_HOME`/`RUSTUP_HOME` on the cache volume.
