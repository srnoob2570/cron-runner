# cron-runner scheduler image — alpine with the scripts baked in.
#
# The scripts are COPYed into the image, NOT bind-mounted: PaaS code syncs
# (Dokploy) re-clone the checkout without recreating containers, which
# silently breaks bind mounts of running containers (the cron daemon keeps
# ticking but the dispatch script is gone).
FROM alpine:3.22

RUN apk add --no-cache curl

COPY --chmod=0755 scheduler/ /scheduler/

ENTRYPOINT ["/bin/sh", "/scheduler/entrypoint.sh"]