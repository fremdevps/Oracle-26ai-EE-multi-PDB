#!/usr/bin/env bash
# desc: (EE) Build the Oracle AI Database 26ai Enterprise Edition image from the install ZIP

set -euo pipefail

# Builds the Enterprise Edition container image with Oracle's official build
# scripts (github.com/oracle/docker-images, OracleDatabase/SingleInstance).
# Oracle does not publish a 26ai EE image, so it is built from the install ZIP.
#
# Usage: build-ee-image.sh [path/to/LINUX.X64_*_db_home.zip]
#
# Without an argument the ZIP is taken from ./ee-install/. The image tag comes
# from DB_IMAGE in .env (default oracle/database:23.26.0-ee).
#
# Optional environment:
#   DOCKER_IMAGES_REF   git branch/tag of oracle/docker-images (default main)
#   EE_BUILD_VERSION    dockerfiles folder to build (default 23.26.0)
#
# .env is optional here: the image can be built before install.sh runs.

usage() {
  sed -n '6,17p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

case "${1:-}" in
-h | --help) usage ;;
esac

# --- Settings ---------------------------------------------------------------
env_value() {
  # env_value KEY -> value of KEY in .env without quotes, or nothing
  [ -f .env ] || return 0
  grep -E "^$1=" .env | tail -1 | cut -d= -f2- | tr -d '"'
}

DB_IMAGE="${DB_IMAGE:-$(env_value DB_IMAGE)}"
DB_IMAGE="${DB_IMAGE:-oracle/database:23.26.0-ee}"
DOCKER_IMAGES_REF="${DOCKER_IMAGES_REF:-main}"
EE_BUILD_VERSION="${EE_BUILD_VERSION:-23.26.0}"
BUILD_ROOT="./.build/docker-images"
MIN_FREE_GB=25

# --- Container engine ------------------------------------------------------
if [ -n "${CONTAINER_CLI:-}" ]; then
  :
elif command -v docker &>/dev/null; then
  CONTAINER_CLI="docker"
elif command -v podman &>/dev/null; then
  CONTAINER_CLI="podman"
else
  echo "ERROR: neither docker nor podman is installed" >&2
  exit 1
fi

for cmd in git md5sum; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required" >&2
    exit 1
  fi
done

# --- Install ZIP -----------------------------------------------------------
ZIP="${1:-}"
if [ -z "$ZIP" ]; then
  shopt -s nullglob
  candidates=(./ee-install/LINUX.X64_*_db_home.zip)
  shopt -u nullglob
  if [ ${#candidates[@]} -eq 0 ]; then
    echo "ERROR: no LINUX.X64_*_db_home.zip in ./ee-install/" >&2
    echo "Download 'Oracle AI Database 26ai for Linux x86-64 ZIP' from" >&2
    echo "  https://www.oracle.com/database/technologies/oracle-database-software-downloads.html" >&2
    echo "and copy it to ./ee-install/ (do not unzip it)." >&2
    exit 1
  fi
  if [ ${#candidates[@]} -gt 1 ]; then
    echo "ERROR: more than one install ZIP in ./ee-install/. Pass the one to use:" >&2
    printf '  %s\n' "${candidates[@]}" >&2
    exit 1
  fi
  ZIP="${candidates[0]}"
fi

if [ ! -f "$ZIP" ]; then
  echo "ERROR: file not found: $ZIP" >&2
  exit 1
fi
ZIP_NAME="$(basename "$ZIP")"
case "$ZIP_NAME" in
LINUX.X64_*_db_home.zip) ;;
*)
  echo "ERROR: '$ZIP_NAME' is not a Linux x86-64 database home ZIP (LINUX.X64_*_db_home.zip)" >&2
  exit 1
  ;;
esac

echo "Install ZIP : $ZIP"
echo "Image tag   : $DB_IMAGE"
echo "Build files : oracle/docker-images@$DOCKER_IMAGES_REF ($EE_BUILD_VERSION)"

if $CONTAINER_CLI image inspect "$DB_IMAGE" &>/dev/null; then
  echo "The image $DB_IMAGE exists already. Remove it first to rebuild:"
  echo "  $CONTAINER_CLI rmi $DB_IMAGE"
  exit 0
fi

# --- Disk space ------------------------------------------------------------
# The build copies the ZIP into the build context, unzips it and installs the
# home: about 20 GB at peak, plus the final image.
if [ "$CONTAINER_CLI" = "docker" ]; then
  root_dir=$($CONTAINER_CLI info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)
else
  root_dir=$($CONTAINER_CLI info -f '{{.Store.GraphRoot}}' 2>/dev/null || echo "$HOME")
fi
free_gb=$(df -BG --output=avail "$root_dir" 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)
if [ -n "$free_gb" ] && [ "$free_gb" -lt "$MIN_FREE_GB" ]; then
  echo "ERROR: only ${free_gb} GB free in $root_dir. The build needs about ${MIN_FREE_GB} GB." >&2
  exit 1
fi

# --- Build files -----------------------------------------------------------
if [ -d "$BUILD_ROOT/.git" ]; then
  echo "Updating $BUILD_ROOT"
  git -C "$BUILD_ROOT" fetch --depth 1 origin "$DOCKER_IMAGES_REF"
  git -C "$BUILD_ROOT" checkout -q FETCH_HEAD
else
  rm -rf "$BUILD_ROOT"
  mkdir -p "$(dirname "$BUILD_ROOT")"
  git clone --depth 1 --branch "$DOCKER_IMAGES_REF" --filter=blob:none --sparse \
    https://github.com/oracle/docker-images.git "$BUILD_ROOT"
fi
git -C "$BUILD_ROOT" sparse-checkout set OracleDatabase/SingleInstance/dockerfiles

DOCKERFILES="$BUILD_ROOT/OracleDatabase/SingleInstance/dockerfiles"
if [ ! -d "$DOCKERFILES/$EE_BUILD_VERSION" ]; then
  echo "ERROR: oracle/docker-images has no '$EE_BUILD_VERSION' folder. Available:" >&2
  for dir in "$DOCKERFILES"/[0-9]*/; do basename "$dir"; done >&2
  exit 1
fi

# --- Build -----------------------------------------------------------------
cleanup() { rm -f "$DOCKERFILES/$EE_BUILD_VERSION/$ZIP_NAME"; }
trap cleanup EXIT

echo "Copying the install ZIP into the build context"
cp "$ZIP" "$DOCKERFILES/$EE_BUILD_VERSION/$ZIP_NAME"

# -e  Enterprise Edition
# -i  skip the MD5 check: Checksum.ee is empty for 26ai in oracle/docker-images
# INSTALL_FILE_1 lets the ZIP keep the name Oracle gave it (the Containerfile
# default is LINUX.X64_2326000_db_home.zip; newer release updates differ).
(
  cd "$DOCKERFILES"
  CONTAINER_CLI="$CONTAINER_CLI" ./buildContainerImage.sh \
    -v "$EE_BUILD_VERSION" -e -i \
    -t "$DB_IMAGE" \
    -o "--build-arg INSTALL_FILE_1=$ZIP_NAME"
)

echo
echo "Built $DB_IMAGE"
$CONTAINER_CLI image ls "$DB_IMAGE"
echo
echo "Next: ./install.sh --edition ee   (see EE.md)"
