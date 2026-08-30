#!/usr/bin/env bash
# cron-runner: a dockerless GitHub Actions runner, ephemeral per boot.
#
# Every container start mints a registration token, wipes any previous
# local config, and registers with --replace. The name is stable, so
# GitHub keeps exactly one runner entry. The script then unsets the
# PAT and execs the listener. One API call per boot is the whole cost.
# If the listener dies, the container exits and restart:always re-runs
# this script from scratch.
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN required}"
: "${GH_REPO:?GH_REPO required, e.g. owner/repo}"
RUNNER_NAME="${RUNNER_NAME:-cron-runner}"

# Wipe the previous config first. config.sh refuses to run while .runner
# exists, and a fresh registration is the point of this setup.
rm -f .runner .credentials .credentials_rsaparams

TOKEN="$(curl -sSL --max-time 30 -X POST \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${GH_REPO}/actions/runners/registration-token" |
    jq -r '.token // empty' || true)"
: "${TOKEN:?FATAL: could not mint registration token (restart:always retries)}"

CONFIG_ARGS=(
    --unattended
    --url "https://github.com/${GH_REPO}"
    --token "${TOKEN}"
    --name "${RUNNER_NAME}"
    --disableupdate
    --replace
    --work "_work"
)
[ -n "${RUNNER_LABELS:-}" ] && CONFIG_ARGS+=(--labels "${RUNNER_LABELS}")

./config.sh "${CONFIG_ARGS[@]}"

# The PAT never reaches jobs. Unset everything before the listener starts.
unset TOKEN CONFIG_ARGS GH_TOKEN GH_REPO

echo "[entrypoint] registered as ${RUNNER_NAME}; starting listener"
exec ./run.sh
