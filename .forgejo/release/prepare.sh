#!/bin/sh
# Release prepare hook for LangID.
# Builds the plugin archive from the tagged tree, rendering install.xml from
# the single VERSION source.  The prebuilt helper binary is part of the
# package; it must be committed so git archive includes it.
set -eu

: "${GITHUB_WORKSPACE:?prepare.sh: GITHUB_WORKSPACE 未设置}"
: "${RELEASE_VERSION:?prepare.sh: RELEASE_VERSION 未设置}"
: "${RELEASE_ASSETS_FILE:?prepare.sh: RELEASE_ASSETS_FILE 未设置}"
FORGEJO_DIR="${FORGEJO_DIR:-$GITHUB_WORKSPACE/.forgejo}"

cd "$GITHUB_WORKSPACE"
version="$RELEASE_VERSION"
DIST="$GITHUB_WORKSPACE/dist"
ASSET_ZIP="$GITHUB_WORKSPACE/dist/LangID-$version.zip"
ASSET_TAR="$GITHUB_WORKSPACE/dist/LangID-$version.tar.gz"
BINARY_REL="bin/linux-x86_64/langid"

if ! command -v zip >/dev/null 2>&1; then
  RELEASE_JOB_PACKAGES=zip node "$FORGEJO_DIR/scripts/run.mjs" ensure-tools
fi
command -v zip >/dev/null 2>&1 || { echo "[ERROR] zip 不可用" >&2; exit 1; }

rm -rf "$DIST"
if [ -d .git ]; then
  mkdir -p "$DIST/LangID"
  git archive --format=tar HEAD | tar -x -C "$DIST/LangID"
else
  mkdir -p "$DIST/LangID"
  tar --exclude=.git --exclude=.forgejo --exclude=dist --exclude=target -cf - . | tar -xf - -C "$DIST/LangID"
fi
rm -rf "$DIST/LangID/.forgejo" "$DIST/LangID/dist" "$DIST/LangID/t" "$DIST/LangID/target"

# The LMS plugin is useless without the helper binary.  Refuse to build a
# package which would silently install a plugin that cannot detect anything.
binary="$DIST/LangID/$BINARY_REL"
if [ ! -f "$binary" ] || [ ! -x "$binary" ]; then
  echo "[ERROR] $binary 缺失或不可执行；请先运行 scripts/build.sh 并提交 " >&2
  exit 1
fi
chmod 0755 "$binary"

if ! grep -q '<version>@VERSION@</version>' "$DIST/LangID/install.xml"; then
  echo "[ERROR] $DIST/LangID/install.xml 缺少 @VERSION@ 占位符" >&2
  exit 1
fi
sed -i "s/@VERSION@/$version/g" "$DIST/LangID/install.xml"
if grep -q '@VERSION@' "$DIST/LangID/install.xml" 2>/dev/null; then
  echo "[ERROR] install.xml 仍包含 @VERSION@" >&2
  exit 1
fi
# Keep VERSION in the archive: Plugins::LangID::API->version reads it at
# runtime.  install.xml is the rendered, authoritative copy for LMS.
rm -f "$ASSET_ZIP" "$ASSET_TAR"
cd "$DIST" && zip -qr "$ASSET_ZIP" LangID
if [ "true" = "true" ]; then
  if [ "folder" = "folder" ]; then
    tar -C "$DIST" -czf "$ASSET_TAR" LangID
  fi
fi

: > "$RELEASE_ASSETS_FILE"
printf '%s\n' "$ASSET_ZIP" >> "$RELEASE_ASSETS_FILE"
if [ -s "$ASSET_TAR" ]; then
  printf '%s\n' "$ASSET_TAR" >> "$RELEASE_ASSETS_FILE"
fi

echo "[prepare] 资产清单（$RELEASE_ASSETS_FILE）："
while IFS= read -r asset; do
  [ -n "$asset" ] || continue
  [ -s "$asset" ] || { echo "[ERROR] 产物不存在或为空：$asset" >&2; exit 1; }
  echo "  - $(basename "$asset")  $(wc -c < "$asset") bytes"
done < "$RELEASE_ASSETS_FILE"
