#!/usr/bin/env bash
# ============================================================
# time-startup.sh
# Measures how long rhino-compute takes to fully start.
# Runs multiple times and reports average, min, max.
#
# Usage:
#   chmod +x time-startup.sh
#   ./time-startup.sh
#   RHINO_TOKEN=your-real-token ./time-startup.sh
#   ./time-startup.sh rhino-compute-x9 3   # image, number of runs
# ============================================================

TOKEN="${RHINO_TOKEN:-your-token-here}"
IMAGE="${1:-rhino-compute-x9}"
RUNS="${2:-3}"
TIMEOUT=180
CONTAINER="rc-timing-test"

# Sub-second clock (works on macOS and Linux)
now_ms() { python3 -c "import time; print(int(time.time() * 1000))"; }
elapsed_s() { python3 -c "print(round(($1 - $T0_MS) / 1000, 2))"; }

echo ""
echo "============================================"
echo "  Rhino Compute Startup Timer"
echo "  Image : $IMAGE"
echo "  Runs  : $RUNS"
echo "============================================"
echo ""

# Arrays to collect results
MAIN_RESULTS=()
GH_RESULTS=()

for RUN in $(seq 1 "$RUNS"); do
    echo "──────────────────────────────────────"
    echo "  Run $RUN / $RUNS"
    echo "──────────────────────────────────────"

    # --- Clean up any leftover test container ---
    if docker ps -aq --filter "name=$CONTAINER" 2>/dev/null | grep -q .; then
        docker rm -f "$CONTAINER" > /dev/null
    fi

    # --- Start the container ---
    T0_MS=$(now_ms)
    echo "  [$(date '+%H:%M:%S')]  Starting container..."

    docker run -d \
        --name "$CONTAINER" \
        -p 6500:6500 \
        -e RHINO_TOKEN="$TOKEN" \
        "$IMAGE" > /dev/null

    # -------------------------------------------------------
    # MILESTONE 1 – main server responds on /healthcheck
    # -------------------------------------------------------
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
        echo "  ✗  Main server did not respond within ${TIMEOUT}s — skipping run."
        docker rm -f "$CONTAINER" > /dev/null
        continue
    fi

    echo "  ✓  Main server ready        ── ${MAIN_READY}s"
    MAIN_RESULTS+=("$MAIN_READY")

    # -------------------------------------------------------
    # MILESTONE 2 – child process (CG) finishes loading GH
    # -------------------------------------------------------
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
        echo "  ⚠  GH child did not finish within ${TIMEOUT}s."
    else
        echo "  ✓  Grasshopper fully loaded  ── ${GH_READY}s"
        GH_RESULTS+=("$GH_READY")
    fi

    # Stop and remove before next run
    docker rm -f "$CONTAINER" > /dev/null
    echo ""

    # Short pause between runs so the port is released
    if [ "$RUN" -lt "$RUNS" ]; then sleep 2; fi
done

# -------------------------------------------------------
# AGGREGATE SUMMARY
# -------------------------------------------------------
calc_stats() {
    # $@ = array of float values
    python3 - "$@" <<'EOF'
import sys, statistics
vals = list(map(float, sys.argv[1:]))
if not vals:
    print("  n/a")
    return
print(f"  avg={statistics.mean(vals):.2f}s  min={min(vals):.2f}s  max={max(vals):.2f}s  "
      f"({'  '.join(str(v)+'s' for v in vals)})")
EOF
}

echo ""
echo "============================================"
echo "  Summary ($RUNS runs)"
echo "============================================"
printf "  Main server ready:\n"
calc_stats "${MAIN_RESULTS[@]}"
printf "  Fully ready (GH):\n"
calc_stats "${GH_RESULTS[@]}"
echo "============================================"
echo ""


