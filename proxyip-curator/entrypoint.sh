#!/bin/bash
# ponytail: loop forever, sleep INTERVAL_SEC between cycles.
set -u
: "${INTERVAL_SEC:=1800}"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

# one-shot mode
if [ "${1:-}" = "once" ]; then
  exec /app/run.sh
fi

while :; do
  log "=== cycle start ==="
  /app/run.sh || log "cycle exited non-zero (continuing)"
  log "=== cycle done, sleep ${INTERVAL_SEC}s ==="
  sleep "$INTERVAL_SEC"
done
