#!/usr/bin/env bash
# ============================================================
# time-startup.sh
# Measures how long rhino-compute takes to fully start.
#
# Usage:
#   chmod +x time-startup.sh
#   ./time-startup.sh
#   RHINO_TOKEN=your-real-token ./time-startup.sh
#   ./time-startup.sh rhino-compute-x9   # pass image name as arg
# ============================================================

TOKEN="${RHINO_TOKEN:-your-token-here}"
IMAGE="${1:-rhino-compute-x9}"
TIMEOUT=180
CONTAINER="rc-timing-test"

# Sub-second clock (works on macOS and Linux)
now_ms() { python3 -c "import time; print(int(time.time() * 1000))"; }
elapsed_s() { python3 -c "print(round(($1 - $T0_MS) / 1000, 2))"; }

echo ""
echo "============================================"
echo "  Rhino Compute Startup Timer"
echo "  Image : $IMAGE"
echo "============================================"
echo ""

# --- Clean up any leftover test container ---
if docker ps -aq --filter "name=$CONTAINER" 2>/dev/null | grep -q .; then
    echo "Removing leftover container '$CONTAINER'..."
    docker rm -f "$CONTAINER" > /dev/null
fi

# --- Start the container ---
T0_MS=$(now_ms)
echo "[$(date '+%H:%M:%S')]  docker run ..."

docker run -d \
    --name "$CONTAINER" \
    -p 6500:6500 \
    -e RHINO_TOKEN="$TOKEN" \
    "$IMAGE" > /dev/null

echo ""

# -------------------------------------------------------
# MILESTONE 1 – main server responds on /healthcheck
# -------------------------------------------------------
echo "  Polling http://localhost:6500/healthcheck ..."

MAIN_READY=""
DEADLINE=$(( $(date +%s) + TIMEOUT ))

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
             --max-time 2 http://localhost:6500/healthcheck 2>/dev/null)
    if [ "$STATUS" = "200" ]; then
        MAIN_READY=$(elapsed_s "$(now_ms)")
        break
    fi
    sleep 0.5
done

if [ -z "$MAIN_READY" ]; then
    echo "  ✗  Main server did not respond within ${TIMEOUT}s — aborting."
    docker rm -f "$CONTAINER" > /dev/null
    exit 1
fi

echo "  ✓  Main server ready        ── ${MAIN_READY}s"

# -------------------------------------------------------
# MILESTONE 2 – child process (CG) finishes loading GH
# -------------------------------------------------------
echo "  Waiting for Grasshopper child process ..."

GH_READY=""
DEADLINE=$(( $(date +%s) + TIMEOUT ))

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    if docker logs "$CONTAINER" 2>&1 | grep -qE "CG\s+\[.*\] Application started"; then
        GH_READY=$(elapsed_s "$(now_ms)")
        break
    fi
    sleep 0.5
done

if [ -z "$GH_READY" ]; then
    echo "  ⚠  GH child did not finish within ${TIMEOUT}s (it may still be loading)."
else
    echo "  ✓  Grasshopper fully loaded  ── ${GH_READY}s"
fi

# -------------------------------------------------------
# SUMMARY
# -------------------------------------------------------
echo ""
echo "============================================"
echo "  Results"
echo "============================================"
[ -n "$MAIN_READY" ] && printf "  Main server ready:    %7s s\n" "$MAIN_READY"
[ -n "$GH_READY" ]   && printf "  Fully ready (GH):     %7s s\n" "$GH_READY"
echo "============================================"
echo ""

# -------------------------------------------------------
# KEEP OR REMOVE
# -------------------------------------------------------
read -rp "Keep container running? [y/N] " keep
if [[ "$keep" =~ ^[yY]$ ]]; then
    echo "Container '$CONTAINER' is still running on http://localhost:6500"
else
    docker rm -f "$CONTAINER" > /dev/null
    echo "Container removed."
fi

