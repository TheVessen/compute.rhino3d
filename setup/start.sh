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

# ------------------------------------------------------------
# Install yak packages declared in the manifest (packages.json,
# mounted by docker-launch.sh). Already-installed packages are
# skipped, so restarts are fast; recreating the container gives
# a clean slate and reinstalls everything at the pinned versions.
# ------------------------------------------------------------
MANIFEST=/packages.json

if [ -f "$MANIFEST" ]; then
    echo "  Installing yak packages from manifest ..."
    installed=$(yak list 2>/dev/null || true)

    while IFS=$'\t' read -r name version; do
        [ -z "$name" ] && continue
        if echo "$installed" | grep -qi "^${name} "; then
            echo "    $name already installed — skipping"
            continue
        fi
        # yak takes the version as a second positional arg; passing an exact
        # version (e.g. 1.0.0-beta.2) is also how prerelease packages install
        if [ -n "$version" ] && [ "$version" != "null" ]; then
            echo "    yak install $name $version"
            yak install "$name" "$version" || echo "    WARNING: failed to install $name $version"
        else
            echo "    yak install $name"
            yak install "$name" || echo "    WARNING: failed to install $name"
        fi
    done < <(jq -r '.yak[]? | [.name, (.version // "null")] | @tsv' "$MANIFEST")

    # Sanity-check that declared local packages are actually present
    # (either in /plugins or live-mounted under /plugins-local)
    while read -r f; do
        [ -z "$f" ] && continue
        if [ ! -e "/plugins/$f" ] && [ ! -e "/plugins-local/$f" ]; then
            echo "    WARNING: '$f' is declared in packages.json (local) but missing from /plugins and /plugins-local"
        fi
    done < <(jq -r '.local[]?' "$MANIFEST")

    echo ""
fi

# ------------------------------------------------------------
# Load custom plugins mounted at /plugins (see docker-launch.sh)
#   *.gha / *.dll / folders  -> copied into the GH Libraries folder
#   *.yak                    -> installed via yak
# Runs on every container start, so updating a plugin is just
# replacing the file on the host and `docker restart`.
# ------------------------------------------------------------
GH_LIBRARIES=/root/.config/Grasshopper/Libraries

for src in /plugins /plugins-local; do
    if [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
        echo "  Loading custom plugins from $src ..."
        mkdir -p "$GH_LIBRARIES"

        # Loose assemblies and folders (everything except .yak archives)
        find "$src" -mindepth 1 -maxdepth 1 ! -name '*.yak' ! -name 'README*' \
            -exec cp -rf {} "$GH_LIBRARIES/" \;

        # Yak archives
        for y in "$src"/*.yak; do
            [ -e "$y" ] || continue
            echo "  yak install $(basename "$y")"
            yak install "$y" || echo "  WARNING: failed to install $y"
        done

        echo "  Custom plugins loaded."
        echo ""
    fi
done

# ------------------------------------------------------------
# Flatten TFM subfolders (MyPlugin/net7.0/*.gha -> MyPlugin/*).
# Rhino 9 on Linux crashes resolving multi-target plugin layouts
# (GetRuntimeSpecificFolder bug: OS suffix is null on Linux), and
# one such folder silently breaks loading of ALL Grasshopper
# plugins. Applies to both copied plugins and yak packages.
# Prefers the netcore folder (net*.0) when several TFMs exist.
# ------------------------------------------------------------
YAK_PACKAGES=/root/.local/share/mcneel/rhinoceros/packages

flatten_tfm_dirs() {
    local base="$1"
    [ -d "$base" ] || return 0
    find "$base" -type d \( -name "net[0-9].0*" -o -name "net[0-9][0-9].0*" -o -name "net4[0-9]*" \) 2>/dev/null \
        | while read -r tfm; do
            ls "$tfm"/*.gha >/dev/null 2>&1 || continue
            parent="$(dirname "$tfm")"
            case "$(basename "$tfm")" in
                net4*)
                    # net48-only plugins can't load on .NET-core Rhino anyway;
                    # only flatten if no netcore sibling exists
                    if ls -d "$parent"/net[0-9].0* "$parent"/net[0-9][0-9].0* >/dev/null 2>&1; then
                        echo "  Dropping $(basename "$parent")/$(basename "$tfm") (netcore variant exists)"
                        rm -rf "$tfm"
                        continue
                    fi
                    ;;
            esac
            echo "  Flattening $(basename "$parent")/$(basename "$tfm")"
            cp -rf "$tfm"/. "$parent"/
            rm -rf "$tfm"
        done
}

flatten_tfm_dirs "$GH_LIBRARIES"
flatten_tfm_dirs "$YAK_PACKAGES"

# ------------------------------------------------------------
# Refresh the font cache so custom fonts mounted at
# /usr/local/share/fonts/custom (see docker-launch.sh) are
# visible to text-to-curve components.
# ------------------------------------------------------------
if command -v fc-cache >/dev/null 2>&1; then
    if [ -d /usr/local/share/fonts/custom ] && [ -n "$(ls -A /usr/local/share/fonts/custom 2>/dev/null)" ]; then
        echo "  Refreshing font cache (custom fonts found) ..."
        fc-cache -f >/dev/null 2>&1
    fi
fi

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