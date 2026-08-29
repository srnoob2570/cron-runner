# cron-runner

**Reliable cron triggers for GitHub Actions plus a dockerless self-hosted runner, in one `docker compose up`.**

GitHub's native `schedule:` trigger is best-effort: under load it can be silently dropped for hours, no error, no log. cron-runner fires your workflows from your own cron instead — and runs them on its own runner, a variant of the official GitHub Actions runner with every docker binary stripped from the image.

Two containers, one host:

1. **Scheduler** — supercronic running your crontab. Every tick dispatches a workflow through the GitHub REST API and logs the HTTP status (`204` = dispatched; a failure retries on the next tick).
2. **Runner** — the official runner, dockerless: no docker inside, no socket, no volumes, no ports. Jobs run directly in the container.

## Quick start

```bash
git clone https://github.com/srnoob2570/cron-runner && cd cron-runner
cp .env.example .env        # set GH_TOKEN + GH_REPO
cp crontab.example crontab  # edit your schedule (gitignored)
docker compose up -d --build
```

The scheduler starts dispatching on the next tick, and the runner shows up under **Settings → Actions → Runners**.

> Run the `cp` steps **before** `up`: if `up` runs first, Docker creates `./crontab` as an empty root-owned directory and the scheduler's mount fails. Remove it (`sudo rm -rf ./crontab`) and repeat.

### `.env`

```ini
GH_TOKEN=ghp_xxx        # classic: repo — fine-grained: Administration:RW + Actions:RW
GH_REPO=owner/repo      # workflows dispatched here, runner registers here
# RUNNER_NAME=cron-runner
# RUNNER_LABELS=self-hosted,cron-runner
```

### `crontab`

Standard cron syntax; each job dispatches one workflow. The repo comes from `GH_REPO`, the ref defaults to `main`:

```text
*/10 * * * * /scheduler/dispatch.sh update.yml main
0 3 * * *    /scheduler/dispatch.sh nightly.yml
```

Times are UTC; edits apply after `docker compose restart scheduler`.

Point your workflow at the pool with `on: workflow_dispatch` and `runs-on: [self-hosted, cron-runner]` — `RUNNER_LABELS` defaults to `self-hosted,cron-runner`, so the quick start works as-is; set your own labels in `.env` if you want a different pool name.

## How it works

- **Scheduler.** supercronic (pinned by version + sha256, baked into the image at build time) reads `/etc/crontabs/root`. Each job POSTs to `POST /repos/{repo}/actions/workflows/{workflow}/dispatches` and logs the result.
- **Runner.** Ephemeral per boot: every container start mints a fresh registration token, wipes the previous config and re-registers with `--replace` under the same name — exactly one runner entry in GitHub, one API call per boot. `GH_TOKEN` is `unset` before the listener starts; jobs only ever see the ephemeral `GITHUB_TOKEN` GitHub injects per run. If the listener dies, `restart: always` re-runs the whole cycle.
- **Containment.** Both containers run with `cap_drop: ALL`, `no-new-privileges`, memory/PID limits and tmpfs scratch. Nothing a job installs survives a recreate: `docker compose up -d --build --force-recreate`.

## Limitations

- No `container:`, `services:` or `docker://` actions — there is no docker daemon inside, that's the point. Shell steps and JS actions work as-is; other toolchains come from the standard `setup-*` actions on demand.
- Runner updates ship via image rebuild: `docker compose build --build-arg RUNNER_VERSION=<latest> && docker compose up -d` — the runner runs `--disableupdate`, so the rebuild is the only update path. Rebuild at least monthly — GitHub stops queueing jobs to runners more than 30 days behind.
- For public repos with untrusted PRs, apply [GitHub's self-hosted runner guidance](https://docs.github.com/en/actions/reference/security/secure-use); prefer private or trusted repos.

## License

[MIT](LICENSE)