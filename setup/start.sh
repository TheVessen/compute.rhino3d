#!/bin/bash

# ============================================================
# Rhino.Compute startup script
# ============================================================

echo ""
echo "============================================"
echo "  Rhino.Compute (x9 branch)"
echo "============================================"

# Token check: warn but don't block
if [ -z "$RHINO_TOKEN" ]; then
    echo ""
    echo "  WARNING: RHINO_TOKEN is not set."
    echo "  The server will start, but computations"
    echo "  will fail without a valid token."
    echo ""
    echo "  To fix, restart with:"
    echo "    docker run -p 6500:6500 \\"
    echo "      -e RHINO_TOKEN=your-token-here \\"
    echo "      rhino-compute-x9"
    echo ""
else
    echo "  RHINO_TOKEN is set."
fi

echo "  Main server:      http://0.0.0.0:6500"
echo "  Geometry backend:  http://localhost:6001 (internal)"
echo ""
echo "  From your host machine, connect to:"
echo "    http://localhost:6500"
echo ""
echo "  Grasshopper definitions must be accessible"
echo "  from inside the container. Use:"
echo "    http://host.docker.internal:<port>/path/to/file.gh"
echo "  instead of http://localhost or http://127.0.0.1"
echo ""
echo "============================================"
echo ""

cd /home/rhino-compute-src/src

# IMPORTANT: --urls http://0.0.0.0:6500 binds to all interfaces
# so the server is reachable from outside the container.
# Without this, it only listens on localhost (container-internal).
CHILD_COUNT="${RHINO_COMPUTE_CHILD_COUNT:-1}"

exec dotnet run \
    --project rhino.compute \
    --configuration Release \
    --no-build \
    -- \
    --urls http://0.0.0.0:6500 \
    --childcount "$CHILD_COUNT" \
    --spawn-on-startup