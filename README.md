# cronrunner

**Reliable cron triggers for GitHub Actions + ephemeral, Docker-less self-hosted runners — in one `docker compose up`.**

GitHub's native `schedule:` trigger is best-effort: during periods of high load, scheduled runs are [silently dropped](https://docs.github.com/en/actions/using-workflows/events-that-trigger-workflows#schedule), sometimes for hours, with no error and no signal. If your workflow matters (catalog rebuilds, backups, keep-alives, feeds), you need a dispatcher that actually fires.

cronrunner is a tiny self-hosted stack:

1. **scheduler** — a real cron daemon (Alpine + `crond`) that triggers any workflow via the GitHub REST API on a schedule you control. A dropped tick is impossible: if the container is up, cron fires.
2. **runner** — a pool of **ephemeral GitHub Actions runners** in hardened containers. No Docker inside, no Docker socket, no host volumes, no `--privileged`. One job per container; the container dies after the job and a fresh one takes its place.

## Why this design

|            | Native `schedule:`                           | cronrunner scheduler                           |
| ---------- | -------------------------------------------- | ---------------------------------------------- |
| Delivery   | best-effort, **silently dropped under load** | cron in your container: fires or logs an error |
| Delay      | can be delayed minutes–hours                 | cron precision                                 |
| Visibility | nothing (no logs, no errors)                 | every dispatch logged with HTTP status         |

|                       | Typical self-hosted runner       | cronrunner runner                                                                              |
| --------------------- | -------------------------------- | ---------------------------------------------------------------------------------------------- |
| Docker socket mounted | often (root-equivalent leak)     | **never** — docker binaries are deleted from the image                                         |
| Job isolation         | jobs share a persistent runner   | **one job per container**, then the container is destroyed                                     |
| Credentials           | long-lived runner config on disk | registration token minted at boot, expires in 1h; runner self-deregisters after its single job |
| Privileges            | varies                           | `cap_drop: ALL`, `no-new-privileges`, memory/PID limits, tmpfs, no ports, no volumes           |

> **Trade-off:** jobs run directly inside the runner container. `container:`, `services:` and `docker://` actions are not supported — by design. This is what makes the container safe to cap: there is nothing for a job to escape into. Shell steps and JS actions (the vast majority of cron workloads) work as-is.

## Quick start

```bash
git clone https://github.com/srnoob2570/cronrunner && cd cronrunner
cp .env.example .env       # add your PAT
cp crontab.example crontab # edit your schedule (gitignored)
docker compose up -d --build
```

That's it. The scheduler starts dispatching, and the runner pool registers itself under **Settings → Actions → Runners** in your repo.

### 1. `.env`

```ini
GH_TOKEN=ghp_xxx        # classic PAT: `repo` scope (fine-grained: Administration:RW + Contents:R)

RUNNER_SCOPE=repo       # or org
GH_REPO=owner/repo      # where runners register and workflows live
# GH_ORG=your-org       # when RUNNER_SCOPE=org

RUNNER_LABELS=self-hosted,cronrunner   # optional, targets the pool
```

Point your workflow at the pool:

```yaml
on: workflow_dispatch # cronrunner triggers this
jobs:
    update:
        runs-on: [self-hosted, cronrunner]
```

### 2. `crontab`

Standard cron syntax plus dispatch fields — no shell, just workflow triggers:

```text
# ┌───────────── minute (0-59)
# │ ┌───────────── hour (0-23)
# │ │ ┌───────────── day of month (1-31)
# │ │ │ ┌───────────── month (1-12)
# │ │ │ │ ┌───────────── day of week (0-6, Sunday=0)
# │ │ │ │ │
* * * * *  TYPE  OWNER/REPO  WORKFLOW  REF

*/10 * * * *  workflow  owner/repo  update.yml   main
0 3 * * *     workflow  owner/repo  nightly.yml  develop
```

Every tick POSTs to `POST /repos/{owner}/{repo}/actions/workflows/{workflow}/dispatches` and logs the result (`204` = dispatched). A failed dispatch (network blip, rate limit) is logged and simply retried on the next tick.

### 3. Scale the pool (optional)

```bash
docker compose up -d --scale runner=4
```

Each replica registers its own ephemeral runner. With `restart: always`, a replica that finishes a job is recreated with a freshly minted token — the pool is self-healing.

## Toolchains (opt-in)

Keep the image minimal; bake in only what your workflows need (the matching `setup-*` actions then become cache hits):

```bash
BUN_VERSION=1.4.0 NODE_VERSION=22 docker compose build runner
# or set them in .env — compose passes them as build args
```

Everything else is available to jobs through standard `setup-*` actions (they download on demand).

## How the ephemeral cycle works

```text
        ┌──────────────────────────────────────────────────────┐
        │  container boot                                      │
        │  1. mint registration token (GH_TOKEN, expires 1h)   │
        │  2. unset GH_TOKEN — never visible to jobs           │
        │  3. config.sh --ephemeral --disableupdate            │
        │  4. run.sh → waits for exactly ONE job               │
        │  5. job runs → runner exits, self-deregisters,       │
        │     wipes its local config                           │
        │  6. container dies → restart: always → back to 1     │
        └──────────────────────────────────────────────────────┘
```

Ephemerality is the security model: a compromised runner cannot persist, cannot accept a second job, and holds at most a 1-hour-old single-use token. GitHub auto-deregisters ephemeral runners after one job.

**Note:** if you kill an _idle_ runner container (restart, redeploy), GitHub shows it as _offline_ — it never completed its job, so it couldn't self-deregister. Clean up occasionally:

```bash
gh api repos/OWNER/REPO/actions/runners --jq '.runners[] | select(.status=="offline") | .id'
gh api -X DELETE repos/OWNER/REPO/actions/runners/<id> --silent
```

## Security posture

- **No Docker anywhere.** The official runner image ships a Docker CLI (and daemon binaries); cronrunner deletes all of them at build time and fails the build if any reappear. A job has no daemon to talk to.
- **No host access.** No sockets, no bind mounts, no host network, no ports, no privileged mode. Kernel attack surface is the container runtime itself — same as any container.
- **Minimal capabilities.** `cap_drop: ALL` + `no-new-privileges` on both services.
- **Bounded resources.** 2 GB RAM / 384 PIDs per runner, tmpfs scratch space, read-only config mounts.
- **No long-lived secrets in jobs.** `GH_TOKEN` exists only in the entrypoint's environment and is `unset` before the runner process starts. Jobs authenticate with the ephemeral `GITHUB_TOKEN` GitHub injects per run.
- **Scheduler is equally sandboxed** and needs nothing but outbound HTTPS to `api.github.com`.

For public repositories with untrusted PRs, apply [GitHub's self-hosted runner guidance](https://docs.github.com/en/actions/reference/security/secure-use) — prefer running cronrunner against private or trusted repos, or isolate untrusted workloads elsewhere.

## Requirements

- Docker Engine + compose plugin, any host that runs containers
- Outbound HTTPS: `api.github.com`, `github.com`, `objects.githubusercontent.com` (plus your workflows' own needs: registries, CDNs, APIs)
- A PAT with `repo` scope (classic) or `Administration:RW` + `Contents:R` (fine-grained)

## Limitations

- No `container:` / `services:` / `docker://` actions (no daemon by design)
- Runner version updates ship via image rebuild (`RUNNER_VERSION` build arg); `--disableupdate` is set because in-container self-update is useless in ephemeral containers. Rebuild at least monthly — GitHub stops queueing jobs to runners >30 days behind.
- The scheduler triggers only `workflow` dispatches (that's the point); it is not a general-purpose cron

## FAQ

**Why not just `schedule:`?** Because GitHub drops it, [by design](https://docs.github.com/en/actions/using-workflows/events-that-trigger-workflows#schedule), under load, without any error or log. Ask anyone who runs a every-5-minutes workflow.

**Why not a runner on the host with crontab?** Same dispatch reliability, but the runner persists between jobs, holds its registration on disk, and typically ends up with a Docker socket. cronrunner's pool is disposable by construction.

**Can I dispatch to other people's repos?** The scheduler dispatches with the PAT's identity — any repo that PAT can access, so one cronrunner can serve multiple repos: just add lines to the crontab.

## License

[MIT](LICENSE)
