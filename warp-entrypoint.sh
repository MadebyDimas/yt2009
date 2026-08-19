#!/bin/bash
(
  for i in $(seq 1 15); do
    sleep 2
    if warp-cli --accept-tos status 2>/dev/null | grep -q "Status update: Connected"; then
      echo "[warp-auto-connect] WARP is connected."
      break
    fi
    echo "[warp-auto-connect] Attempting WARP connect (attempt $i)..."
    warp-cli --accept-tos connect 2>/dev/null || true
  done
) &

exec /entrypoint.sh "$@"
