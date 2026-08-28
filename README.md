# cron-runner

**Reliable cron triggers for GitHub Actions, plus a dedicated Docker-less self-hosted runner, in one `docker compose up`.**

GitHub's native `schedule:` trigger is best-effort. Under load, GitHub [silently drops](https://docs.github.com/en/actions/using-workflows/events-that-trigger-workflows#schedule) scheduled runs, sometimes for hours, with no error and no signal. If your workflow matters, you need a dispatcher that actually fires. Think catalog rebuilds, backups, feeds.

cron-runner is a tiny self-hosted stack:

1. **Scheduler.** A real cron daemon (Alpine + `crond`) that triggers workflows through the GitHub REST API on a schedule you control. If the container is up, cron fires.
2. **Runner.** A dedicated GitHub Actions runner in a hardened container. No Docker inside, no Docker socket, no host volumes, no `--privileged`. It registers once and stays registered, and it periodically recreates itself from the image to wipe whatever state jobs left behind.

## Why this design

|            | Native `schedule:`                           | cron-runner scheduler                           |
| ---------- | -------------------------------------------- | ---------------------------------------------- |
| Delivery   | best-effort, **silently dropped under load** | cron in your container: fires or logs an error |
| Delay      | can be delayed minutes to hours              | cron precision                                 |
| Visibility | nothing (no logs, no errors)                 | every dispatch logged with HTTP status         |

|                       | Typical self-hosted runner       | cron-runner runner                                                                              |
| --------------------- | -------------------------------- | ---------------------------------------------------------------------------------------------- |
| Docker socket mounted | often (root-equivalent leak)     | **never**, docker binaries are deleted from the image                                          |
| State between jobs    | shared, persists silently        | **periodic self-reset**, container recreated from the image, non-persisted state wiped         |
| Credentials           | long-lived config + often socket | registers once; PAT only touches registration, never job steps                                 |
| Privileges            | varies                           | `cap_drop: ALL`, `no-new-privileges`, memory/PID limits, tmpfs, no ports, no volumes           |

> **Trade-off:** jobs run directly inside the runner container. `container:`, `services:` and `docker://` actions are not supported. That's what makes the container safe to cap; there is nothing for a job to escape into. Shell steps and JS actions, the vast majority of cron workloads, work as-is.

## Quick start

```bash
git clone https://github.com/srnoob2570/cron-runner && cd cron-runner
cp .env.example .env       # add your PAT
cp crontab.example crontab # edit your schedule (gitignored)
docker compose up -d --build
```

That's it. The scheduler starts dispatching, and the runner registers itself under **Settings → Actions → Runners** in your repo.

> **Running on a PaaS (Dokploy, Coolify, Railway…)?** Split the two services. Deploy **`docker-compose.scheduler.yml`** (or just the `scheduler/` scripts, a plain `alpine`-based image with no build) wherever your PaaS runs, and **`docker-compose.runner.yml`** on a Docker host, local or a VPS. Both read the same `.env`; the scheduler uses the `CRONTAB` env var, so no files are needed on the PaaS side.

**Prefer scheduler and runner apart?** Each half ships its own compose file:

```bash
# scheduler only (PaaS-friendly, no build)
docker compose -f docker-compose.scheduler.yml up -d

# runner only (Docker host)
docker compose -f docker-compose.runner.yml up -d --build

# both on one host (as before)
docker compose up -d --build
```

### 1. `.env`

```ini
GH_TOKEN=ghp_xxx        # classic PAT: `repo` scope (fine-grained: Administration:RW + Contents:R)

RUNNER_SCOPE=repo       # or org
GH_REPO=owner/repo      # where runners register and workflows live
# GH_ORG=your-org       # when RUNNER_SCOPE=org

RUNNER_LABELS=self-hosted,cron-runner   # optional, targets the pool
RUNNER_NAME_PREFIX=cron-runner          # optional; the runner registers under this exact name
```

Point your workflow at the pool:

```yaml
on: workflow_dispatch # cron-runner triggers this
jobs:
    update:
        runs-on: [self-hosted, cron-runner]
```

### 2. Schedule

Standard cron syntax plus dispatch fields, no shell, just workflow triggers:

```text
# ┌───────────── minute (0-59)
# │ ┌───────────── hour (0-23)
# │ │ ┌───────────── day of month (1-31)
# │ │ │ ┌───────────── month (1-12)
# │ │ │ │ ┌───────────── day of week (0-6, Sunday=0)
# │ │ │ │ │
* * * * *  /scheduler/dispatch.sh  OWNER/REPO  WORKFLOW  REF

*/10 * * * *  /scheduler/dispatch.sh  owner/repo  update.yml   main
0 3 * * *     /scheduler/dispatch.sh  owner/repo  nightly.yml  develop
```

Every tick POSTs to `POST /repos/{owner}/{repo}/actions/workflows/{workflow}/dispatches` and logs the result (`204` = dispatched). A failed dispatch (network blip, rate limit) is logged and retried on the next tick.

Provide the schedule either way. If both are set, the env var wins:

- **`CRONTAB` env var** (PaaS/Dokploy path): pipe-separated entries. Pipes are illegal in cron fields, so the split is unambiguous.

  ```ini
  CRONTAB=*/10 * * * * /scheduler/dispatch.sh owner/repo update.yml main|0 3 * * * /scheduler/dispatch.sh owner/repo nightly.yml develop
  ```

- **`crontab` file** (docker compose path): `cp crontab.example crontab`, edit (gitignored), mounted read-only at `/etc/crontabs/root`.

### 3. Reset cycle (optional but recommended)

The runner is **dedicated**. It registers once and stays registered, with no deregistration, no per-boot API churn and near-zero job pickup latency. To keep state clean, the container **self-resets** every `RUNNER_MAX_LIFETIME` (default 24h, `0` = never):

```ini
RUNNER_MAX_LIFETIME=86400   # seconds; the reset waits until no job is running
```

A reset means the container stops while idle, `restart: always` recreates it from the image, everything not persisted (work dir, caches, anything a job installed) gets wiped, and it re-registers with `--replace` under the same name. One runner entry in GitHub, fresh state each cycle. A plain `docker compose restart runner` also reuses the on-disk registration with zero API calls.

## Toolchains (opt-in)

Keep the image minimal and bake in only what your workflows need. The matching `setup-*` actions then become cache hits:

```bash
BUN_VERSION=1.4.0 NODE_VERSION=22 docker compose build runner
# or set them in .env, compose passes them as build args
```

Everything else is available to jobs through standard `setup-*` actions (they download on demand).

## How the dedicated cycle works

```text
        ┌──────────────────────────────────────────────────────────┐
        │  first boot / recreated container                        │
        │  1. sweep offline leftover runners (crash zombies)       │
        │  2. mint registration token (GH_TOKEN, expires 1h)       │
        │  3. unset GH_TOKEN, never visible to jobs                │
        │  4. config.sh --disableupdate --replace (NOT ephemeral)  │
        │  5. run.sh waits for jobs, forever                       │
        │                                                          │
        │  plain restart: skips 1-4, reuses the on-disk            │
        │  registration, zero API calls, online in seconds         │
        │                                                          │
        │  every RUNNER_MAX_LIFETIME (default 24h):                │
        │  6. when idle, clean stop, restart: always,              │
        │     recreate from image (state wiped), back to 1         │
        └──────────────────────────────────────────────────────────┘
```

The reset is the state-hygiene story. The container is recreated from the image on a fixed cadence, so nothing a job wrote (work dir, package caches, installed files) survives into the next cycle. The registration persists under the same name, so there's exactly one runner in GitHub and no add/remove churn.

The runner registers as `RUNNER_NAME_PREFIX` (default `cron-runner`), so it's easy to recognize in **Settings → Actions → Runners**. If a container dies without a clean exit (SIGKILL, host reboot), the next boot sweeps offline leftovers with the same prefix, and the recreated container re-registers with `--replace`.

## Security posture

- **No Docker anywhere.** The official runner image ships a Docker CLI and daemon binaries. cron-runner deletes all of them at build time and fails the build if any reappear. A job has no daemon to talk to.
- **No host access.** No sockets, no bind mounts, no host network, no ports, no privileged mode. Kernel attack surface is the container runtime itself, same as any container.
- **Minimal capabilities.** `cap_drop: ALL` + `no-new-privileges` on both services.
- **Bounded resources.** 2 GB RAM / 384 PIDs per runner, tmpfs scratch space, read-only config mounts.
- **Periodic state reset.** Every `RUNNER_MAX_LIFETIME` the container is recreated from the image, so job-installed files, work dirs and caches don't accumulate across cycles. `docker compose restart runner` alone does **not** wipe state, it keeps the writable layer. The reset is a recreate.
- **No long-lived secrets in jobs.** `GH_TOKEN` is used only to (re-)register and is `unset` before the runner starts. Jobs authenticate with the ephemeral `GITHUB_TOKEN` GitHub injects per run. The on-disk runner registration (`.credentials`) can only manage the runner itself, it grants no repo or secrets access.
- **Scheduler is equally sandboxed** and needs nothing but outbound HTTPS to `api.github.com`.

For public repositories with untrusted PRs, apply [GitHub's self-hosted runner guidance](https://docs.github.com/en/actions/reference/security/secure-use). Prefer running cron-runner against private or trusted repos, or isolate untrusted workloads elsewhere.

## Requirements

- Docker Engine + compose plugin, any host that runs containers
- Outbound HTTPS: `api.github.com`, `github.com`, `objects.githubusercontent.com` (plus your workflows' own needs: registries, CDNs, APIs)
- A PAT with `repo` scope (classic) or `Administration:RW` + `Contents:R` (fine-grained)

## Limitations

- No `container:` / `services:` / `docker://` actions (no daemon by design)
- Runner version updates ship via image rebuild (`RUNNER_VERSION` build arg); `--disableupdate` is set because in-container self-update conflicts with the reset model. Rebuild at least monthly, GitHub stops queueing jobs to runners >30 days behind.
- The scheduler triggers only `workflow` dispatches (that's the point); it is not a general-purpose cron

## FAQ

**Why not just `schedule:`?** Because GitHub drops it, [by design](https://docs.github.com/en/actions/using-workflows/events-that-trigger-workflows#schedule), under load, without any error or log. Ask anyone who runs a every-5-minute workflow.

**Why not a runner on the host with crontab?** Same dispatch reliability, but that runner typically ends up with a Docker socket, root-ish privileges and no state hygiene. cron-runner's runner is a hardened container that resets itself from the image on a fixed cadence.

**Can I dispatch to other people's repos?** Yes. The scheduler dispatches with the PAT's identity, so it can reach any repo that PAT can access. One cron-runner can serve multiple repos; just add lines to the crontab.

## License

[MIT](LICENSE)
