# cron-runner

Your cron triggers your GitHub Actions workflows, on a dockerless self-hosted runner. One `docker compose up`.

GitHub's native `schedule:` trigger is best effort. Under load GitHub can drop a run and stay silent about it for hours. No error, no log. cron-runner fires your workflows from your own crontab instead and runs them on its own runner, the official GitHub Actions image with every docker binary stripped out.

Two containers, one host:

1. **Scheduler.** supercronic runs your crontab. Every tick dispatches one workflow through the GitHub REST API and logs the HTTP status (`204` = dispatched; a failure retries on the next tick).
2. **Runner.** The official runner, dockerless. No docker inside, no socket, no ports. Jobs run directly in the container with passwordless sudo, GitHub-hosted style: workflows install their own system deps per-run.

## Quick start

```bash
git clone https://github.com/srnoob2570/cron-runner && cd cron-runner
cp .env.example .env        # set GH_TOKEN + GH_REPO
cp crontab.example crontab  # edit your schedule (gitignored)
docker compose up -d --build
```

The scheduler starts dispatching on the next tick, and the runner shows up under **Settings → Actions → Runners**.

### Split deployments

Only one half? Each service also ships as its own template:

```bash
docker compose -f docker-compose.scheduler.yml up -d --build  # cron dispatch only
docker compose -f docker-compose.runner.yml up -d --build     # runner only
```

Same `.env`, same images. The scheduler template still needs the `cp crontab.example crontab` step first. On one host, run both templates as-is — each gets its own Compose project (`cron-runner-scheduler`, `cron-runner-runner`) so they don't clobber each other. `docker compose -f <template> down` then targets exactly one.

> Run the `cp` steps **before** `up`. If `up` runs first, Docker creates `./crontab` as an empty root-owned directory and the scheduler's mount fails. Remove it (`sudo rm -rf ./crontab`) and repeat.

### `.env`

```ini
GH_TOKEN=ghp_xxx        # PAT for both containers, see below
GH_REPO=owner/repo      # workflows dispatched here, runner registers here
# RUNNER_NAME=cron-runner
# RUNNER_LABELS=self-hosted,cron-runner
```

### `GH_TOKEN`

Both containers use one token. Create it under Settings → Developer settings → Personal access tokens. The prefix tells you which kind you made: `ghp_` is classic, `github_pat_` is fine-grained.

- **Classic.** Check the `repo` scope and nothing else. That one scope covers both calls this stack makes, but it grants read/write on every repo your user can reach.
- **Fine-grained.** Repository access: only the repo in `GH_REPO`. Under Permissions, set `Actions` and `Administration` to **Read and write** each. `Metadata: read` is added automatically; nothing else, `Contents` included, gets used.

The two permissions map to the two calls: `Actions: write` dispatches your workflows, `Administration: write` mints the registration token the runner uses at every boot. Registration also requires the token's user to be an admin on the repo. Fine-grained is the smaller grant; whichever you pick, a read-only token will fail.

Fine-grained tokens expire, at most a year out. After expiry the scheduler logs `dispatch FAILED ... http=401` and the runner dies on every boot trying to mint its token. Mint a fresh one, paste it into `.env`, and run `docker compose up -d`.

A bare `restart` is not enough here. Restart does not re-read `.env`, so the containers keep the old token until they are recreated. Revoke the previous token only after both halves work again. Classic and fine-grained are interchangeable, so switching between them is just another swap.

### `crontab`

Standard cron syntax; each job dispatches one workflow. The repo comes from `GH_REPO`, the ref defaults to `main`:

```text
*/10 * * * * /scheduler/dispatch.sh update.yml main
0 3 * * *    /scheduler/dispatch.sh nightly.yml
```

Times are UTC; edits apply after `docker compose restart scheduler`.

Point your workflow at the pool with `on: workflow_dispatch` and `runs-on: [self-hosted, cron-runner]`. `RUNNER_LABELS` defaults to `self-hosted,cron-runner`, so the quick start works as-is. Set your own labels in `.env` if you want a different pool name.

### System dependencies

The image ships `sudo` with a passwordless entry for the `runner` user and nothing else beyond the runner itself. Workflows install what they need per-run, exactly like on GitHub-hosted runners:

```yaml
- name: Install system dependencies
  run: |
    sudo apt-get update
    sudo apt-get install -y libwebkit2gtk-4.1-dev build-essential xdg-utils rpm
```

Nothing a job installs survives a recreate: `docker compose up -d --build --force-recreate` resets everything. There is no cache layer to outlive it; for heavyweight toolchains, `actions/cache` stores on GitHub's side and still works.

## How it works

- **Scheduler.** Supercronic, pinned by version + sha256 and baked into the image at build time, reads `/etc/crontabs/root`. Each job calls `POST /repos/{owner}/{repo}/actions/workflows/{workflow}/dispatches` and logs the result.
- **Runner.** Ephemeral per boot. Every container start mints a fresh registration token, wipes the previous config and re-registers with `--replace` under the same name. GitHub ends up with exactly one runner entry, and each boot costs one API call. The entrypoint unsets `GH_TOKEN` before the listener starts; jobs only see the ephemeral `GITHUB_TOKEN` GitHub injects per run. If the listener dies, `restart: always` re-runs the whole cycle.
- **Containment.** Both containers cap memory/PIDs; the scheduler additionally runs with `cap_drop: ALL` and `no-new-privileges` (it needs no elevated calls). The runner keeps passwordless sudo so jobs can install system deps; the container has no docker binaries, no socket, and no host mounts. Nothing a job installs survives a recreate: `docker compose up -d --build --force-recreate`.

## Limitations

- No `container:`, `services:` or `docker://` actions. There is no docker daemon inside; that's the point. Shell steps and JS actions work as-is; other toolchains come from the standard `setup-*` actions on demand.
- The runner registers with `--disableupdate`, so an image rebuild is the only update path: `docker compose build --build-arg RUNNER_VERSION=<latest> && docker compose up -d`. Rebuild at least monthly; GitHub stops queueing jobs to runners more than 30 days behind.
- For public repos with untrusted PRs, apply [GitHub's self-hosted runner guidance](https://docs.github.com/en/actions/reference/security/secure-use); prefer private or trusted repos.
- The runner caps at `mem_limit: 6g` and `pids_limit: 384`: heavy release builds fit, runaway jobs get killed instead of taking the host down.

## Development

Formatting is enforced by [pre-commit](https://pre-commit.com). Run `pre-commit install` once per clone, and from then on every commit reformats what you touch: shell via shfmt, YAML/Markdown via prettier, plus trailing whitespace and trailing newlines. `pre-commit run --all-files` reformats the whole tree in one pass.

## License

[MIT](LICENSE)
