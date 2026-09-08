# scheduler/

## Responsibility

Scheduling and dispatch layer: converts cron ticks into GitHub `workflow_dispatch` API calls. Owns the crontab lifecycle (validation, execution via supercronic) and the per-workflow dispatch command.

## Design

- **Process-replacement entrypoint:** `entrypoint.sh` validates the schedule file then `exec`s `/usr/local/bin/supercronic`, making supercronic PID 1 with clean SIGTERM handling.
- **Fail-loud configuration contract:** a missing `/etc/crontabs/root` mount is a FATAL exit; the base image's Alpine default crontab is deleted at build time so an absent mount can't silently do nothing.
- **At-least-once delivery via retry-on-next-tick:** `dispatch.sh` never retries internally; a failed dispatch (any HTTP status ≠ 204, curl failure ⇒ `000`) is logged with body excerpt (first 300 bytes), exits non-zero so supercronic counts the failure, and is re-attempted on the next cron tick.
- **Fail-fast environment contract:** `set -eu`; `GH_REPO` and `GH_TOKEN` are mandatory; positional-argument guard rejects the obsolete `OWNER/REPO` syntax (`*/*` case pattern).
- **Pinned dependency:** supercronic is fetched at build time with per-arch SHA256 verification (amd64/arm64), avoiding busybox crond's vfork/musl deadlock class.

## Flow

1. Container start → `entrypoint.sh` checks `/etc/crontabs/root` exists → `exec supercronic /etc/crontabs/root`.
2. Each cron tick runs `/scheduler/dispatch.sh WORKFLOW [REF]` (REF defaults to `main`).
3. `dispatch.sh` builds `POST /repos/{GH_REPO}/actions/workflows/{WORKFLOW}/dispatches` with body `{"ref":"$REF"}` (curl, 30s timeout, response body captured to a per-job mktemp file).
4. HTTP `204` → timestamped OK log; anything else → timestamped FAILED log with status + body excerpt and non-zero exit; next tick retries.
5. Crontab edits take effect on `docker compose restart scheduler` (file is mounted read-only, re-read only at supercronic start).

## Integration

- Built by: `scheduler/Dockerfile` (alpine:3.22 + curl + pinned supercronic; `scheduler/` copied to `/scheduler/`).
- Orchestrated by: `docker-compose.yml` `scheduler` service (mounts `./crontab` → `/etc/crontabs/root:ro`, `cap_drop: ALL`, no-new-privileges, 128m/64 pids limits).
- Configured by: `.env` (`GH_TOKEN`, `GH_REPO`) injected as job environment by supercronic.
- Depends on: GitHub REST API (workflow dispatches endpoint).
- Companion: `runner/` registers and executes the dispatched workflows.
