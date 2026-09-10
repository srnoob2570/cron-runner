# cron-runner

Your cron triggers your GitHub Actions workflows, on a dockerless self-hosted runner. One `docker compose up`.

GitHub's native `schedule:` trigger is best effort. Under load GitHub can drop a run and stay silent about it for hours. No error, no log. cron-runner fires your workflows from your own crontab instead and runs them on its own runner, the official GitHub Actions image with every docker binary stripped out.

Two containers, one host:

1. **Scheduler.** supercronic runs your crontab. Every tick dispatches one workflow through the GitHub REST API and logs the HTTP status (`204` = dispatched; a failure retries on the next tick).
2. **Runner.** The official runner, dockerless. No docker inside, no socket, no ports. Jobs run directly in the container; one persistent volume keeps toolchain caches across recreations.

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

Same `.env`, same images, same hardening. The scheduler template still needs the `cp crontab.example crontab` step first. On one host, run both templates as-is — each gets its own Compose project (`cron-runner-scheduler`, `cron-runner-runner`) so they don't clobber each other. `docker compose -f <template> down` then targets exactly one.

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

### `runner-cache`

The runner keeps one persistent cache: the `runner-cache` volume, mounted at `/home/runner/.cache`. Toolchain caches survive recreations and image rebuilds there. pip and uv cache under `~/.cache` on their own; the compose file redirects npm, Go, Gradle, Cargo and rustup into the same directory (`npm_config_cache`, `GOMODCACHE`, `GOCACHE`, `GRADLE_USER_HOME`, `CARGO_HOME`, `RUSTUP_HOME`), so one volume covers every toolchain. Rust itself is not baked into the image: a workflow installs it per-run (for example with `dtolnay/rust-toolchain`), and the install lands on the volume, so only the first job pays the download. The image seeds the mount point with `runner` ownership, so a fresh volume just works: no host-side setup, no chown.

`RUNNER_TOOL_CACHE` points at the same volume, so `setup-*` actions (Bun, Node, Python) download their runtimes once and reuse them across runs; wiping the cache removes them and the next run re-downloads.

Cleaning is manual by design, from inside the running container:

```bash
docker compose exec runner du -sh /home/runner/.cache                 # watch size; the cache grows without limit
docker compose exec runner sh -c 'rm -rf /home/runner/.cache/*'       # wipe everything
docker compose exec runner sh -c 'rm -rf /home/runner/.cache/npm'     # or one toolchain
```

`--force-recreate` no longer resets caches. When a build breaks on a stale cache, delete that toolchain's subdirectory and rerun. To remove the volume entirely, `docker compose down -v` (also stops the containers). `actions/cache` also works here: it stores on GitHub's side, and this local cache complements it rather than replacing it.

## How it works

- **Scheduler.** Supercronic, pinned by version + sha256 and baked into the image at build time, reads `/etc/crontabs/root`. Each job calls `POST /repos/{owner}/{repo}/actions/workflows/{workflow}/dispatches` and logs the result.
- **Runner.** Ephemeral per boot. Every container start mints a fresh registration token, wipes the previous config and re-registers with `--replace` under the same name. GitHub ends up with exactly one runner entry, and each boot costs one API call. The entrypoint unsets `GH_TOKEN` before the listener starts; jobs only see the ephemeral `GITHUB_TOKEN` GitHub injects per run. If the listener dies, `restart: always` re-runs the whole cycle.
- **Containment.** Both containers run with `cap_drop: ALL`, `no-new-privileges`, memory/PID limits and tmpfs scratch. Nothing a job installs survives a recreate: `docker compose up -d --build --force-recreate`. The one exception is the toolchain cache volume, which persists until you wipe it.

## Limitations

- No `container:`, `services:` or `docker://` actions. There is no docker daemon inside; that's the point. Shell steps and JS actions work as-is; other toolchains come from the standard `setup-*` actions on demand.
- The runner registers with `--disableupdate`, so an image rebuild is the only update path: `docker compose build --build-arg RUNNER_VERSION=<latest> && docker compose up -d`. Rebuild at least monthly; GitHub stops queueing jobs to runners more than 30 days behind.
- For public repos with untrusted PRs, apply [GitHub's self-hosted runner guidance](https://docs.github.com/en/actions/reference/security/secure-use); prefer private or trusted repos.
- The runner's `mem_limit: 2g` includes the 1g tmpfs on `/tmp`: jobs writing heavily to `/tmp` (builds, tars) hit the OOM limit sooner than the headline number suggests.

## Development

Formatting is enforced by [pre-commit](https://pre-commit.com). Run `pre-commit install` once per clone, and from then on every commit reformats what you touch: shell via shfmt, YAML/Markdown via prettier, plus trailing whitespace and trailing newlines. `pre-commit run --all-files` reformats the whole tree in one pass.

## License

[MIT](LICENSE)
