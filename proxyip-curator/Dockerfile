# syntax=docker/dockerfile:1.7
# ponytail: alpine + shell only. no python, no node. ~15MB.
ARG ALPINE_VERSION=3.20
FROM alpine:${ALPINE_VERSION}

# APK_MIRROR: local build sets it (orbstack), GH Action leaves empty.
# e.g. --build-arg APK_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/alpine
ARG APK_MIRROR=""

RUN set -eux; \
    if [ -n "$APK_MIRROR" ]; then \
      sed -i "s|https\?://dl-cdn.alpinelinux.org/alpine|${APK_MIRROR}|g" /etc/apk/repositories; \
    fi; \
    apk add --no-cache curl jq bash coreutils tzdata ca-certificates; \
    rm -rf /var/cache/apk/*

ENV TZ=Asia/Shanghai \
    INTERVAL_SEC=21600 \
    MAX_KEEP=200 \
    PROBE_TIMEOUT=12 \
    PROBE_CONCURRENCY=20 \
    RETEST_ONLY_ON_START=0

WORKDIR /app
COPY run.sh entrypoint.sh /app/
RUN chmod +x /app/run.sh /app/entrypoint.sh

# Runtime env required:
#   GIST_TOKEN     — GitHub PAT with gist scope
#   GIST_ID        — target gist id
#   GIST_FILENAME  — filename inside gist (default: proxyip.json)
#   SOURCES        — comma-separated URLs of ip lists (txt/json)
#   REGION_FILTER  — optional, e.g. JP,US,HK  (matches #TAG lines)
#   CHECKER_API    — default https://api.090227.xyz/check

ENTRYPOINT ["/app/entrypoint.sh"]
