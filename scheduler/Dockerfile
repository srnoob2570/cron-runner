# cron-runner scheduler image: alpine + supercronic, scripts baked in.
FROM alpine:3.22

RUN apk add --no-cache curl

# alpine ships its own default crontab (periodic maintenance jobs);
# removing it makes a missing mount fail loudly at the entrypoint
# instead of silently running nothing.
RUN rm -f /etc/crontabs/root

# supercronic, pinned by version + sha256 per architecture, verified at
# build time. It is a static Go binary, immune to the busybox crond
# vfork/musl deadlock class, and it logs every job run and exits
# cleanly on SIGTERM.
ARG SUPERCRONIC_VERSION=v0.2.49
ARG TARGETARCH
RUN case "${TARGETARCH}" in \
        amd64) SUPERCRONIC_SHA256=a53ae236602c7338aba3fbaff40bda6300eae3b9fedb8261eb06cfe3724430c1 ;; \
        arm64) SUPERCRONIC_SHA256=02aa0cb229ba09050cba6638059dadb9eedc2276632ea43d6a57a2f8c1629dd5 ;; \
        *) echo "FATAL: unsupported architecture ${TARGETARCH:-unknown}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /usr/local/bin/supercronic \
        "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}" \
    && echo "${SUPERCRONIC_SHA256}  /usr/local/bin/supercronic" | sha256sum -c - \
    && chmod +x /usr/local/bin/supercronic

COPY --chmod=0755 scheduler/ /scheduler/

ENTRYPOINT ["/bin/sh", "/scheduler/entrypoint.sh"]
