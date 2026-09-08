#!/bin/sh
# Dispatch one GitHub Actions workflow: dispatch.sh WORKFLOW [REF]
# Repo comes from GH_REPO, auth from GH_TOKEN; supercronic's job
# environment provides both. If a dispatch fails (network blip, rate
# limit), the script logs GitHub's response, exits non-zero so
# supercronic counts the failure, and the next cron tick retries it.
set -eu

case "$#" in
    1 | 2) ;;
    *)
        echo "FATAL: usage: dispatch.sh WORKFLOW [REF] (ref defaults to main)" >&2
        exit 1
        ;;
esac
WORKFLOW="${1:?missing workflow argument, e.g. update.yml}"
REF="${2:-main}"
: "${GH_REPO:?GH_REPO not set}"
: "${GH_TOKEN:?GH_TOKEN not set}"
case "$GH_REPO" in
    /* | */ | */*/* | http://* | https://* | *" "*)
        echo "FATAL: GH_REPO must be 'owner/repo' (got '${GH_REPO}')" >&2
        exit 1
        ;;
esac

case "$WORKFLOW" in
    */*)
        echo "FATAL: '${WORKFLOW}' looks like a repo. Old syntax dispatch.sh OWNER/REPO WORKFLOW REF is gone. Use dispatch.sh WORKFLOW [REF]; the repo comes from GH_REPO." >&2
        exit 1
        ;;
esac
case "${WORKFLOW}${REF}" in
    *" "* | *"?"* | *"#"* | *'"'* | *"'"* | *'\'*)
        echo "FATAL: WORKFLOW and REF must not contain spaces, quotes, backslashes or ?#" >&2
        exit 1
        ;;
esac

out="$(mktemp)"
trap 'rm -f "$out"' EXIT

http_code="$(curl -sS -o "$out" -w '%{http_code}' --max-time 30 \
    -X POST \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${GH_REPO}/actions/workflows/${WORKFLOW}/dispatches" \
    -d "{\"ref\":\"${REF}\"}")" || http_code=000

case "$http_code" in
    204) echo "$(date -u +%FT%TZ) dispatch OK ${GH_REPO}/${WORKFLOW}@${REF} (204)" ;;
    *)
        echo "$(date -u +%FT%TZ) dispatch FAILED ${GH_REPO}/${WORKFLOW}@${REF} http=${http_code} body=$(head -c 300 "$out" 2>/dev/null | tr '\n' ' ') (retries next cron tick)"
        exit 1
        ;;
esac
