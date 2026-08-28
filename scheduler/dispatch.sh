#!/bin/sh
# cronrunner dispatcher: trigger one GitHub Actions workflow via the REST API.
#
# Usage (invoked by crond with fields from the crontab file):
#   dispatch.sh TYPE OWNER/REPO WORKFLOW REF
#
# Auth: GH_TOKEN from the environment (.env via compose). No gh CLI in this
# image on purpose (minimal surface).
set -eu

TYPE="${1:-workflow}"
REPO="${2:?missing repo argument}"
WORKFLOW="${3:?missing workflow argument}"
REF="${4:-main}"

OWNER="${REPO%%/*}"
NAME="${REPO#*/}"

case "$TYPE" in
    workflow) endpoint="actions/workflows/${WORKFLOW}/dispatches" ;;
    *) echo "FATAL: unsupported dispatch type '${TYPE}'" >&2; exit 1 ;;
esac

http_code="$(curl -sS -o /tmp/dispatch.out -w '%{http_code}' --max-time 30 \
    -X POST \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${OWNER}/${NAME}/${endpoint}" \
    -d "{\"ref\":\"${REF}\"}" || echo 000)"

case "$http_code" in
    204) echo "$(date -u +%FT%TZ) dispatch OK ${TYPE} ${REPO}/${WORKFLOW}@${REF} (204)" ;;
    *)   echo "$(date -u +%FT%TZ) dispatch FAILED ${TYPE} ${REPO}/${WORKFLOW}@${REF} http=${http_code} (retries next cron tick)" ;;
esac