#!/bin/sh
# Release preflight hook for LangID.
# Version has a single source of truth: VERSION. install.xml is a template
# containing @VERSION@ and is rendered only when packaging a release.
set -eu

cd "${GITHUB_WORKSPACE:-$(pwd)}"

errors=0
ok()   { echo "[OK] $*"; }
err()  { echo "[ERROR] $*"; errors=$((errors + 1)); }
warn() { echo "[WARN] $*"; }

version="${RELEASE_VERSION:-}"
tag="${RELEASE_TAG:-v$version}"
expected_sha="${RELEASE_SHA:-}"

if [ -z "$version" ]; then
  echo "[ERROR] RELEASE_VERSION 未设置（本 hook 需由 release Action 运行）"
  exit 1
fi

echo "[preflight] version=$version tag=$tag"

# 1. VERSION is the only place the version is written.
if [ ! -f VERSION ]; then
  err "缺少 VERSION 文件"
else
  version_file=$(head -n 1 VERSION | tr -d '[:space:]')
  if [ "$version_file" = "$version" ]; then
    ok "VERSION = $version"
  else
    err "VERSION 是 '${version_file:-<未找到>}'，应更新为 $version"
  fi
fi

# 2. The manifest must be a template, not a second version definition.
install="install.xml"
if [ ! -f "$install" ]; then
  err "找不到 $install"
elif grep -q '<version>@VERSION@</version>' "$install"; then
  ok "$install 使用 @VERSION@ 占位符"
else
  err "$install 缺少 <version>@VERSION@</version> 占位符"
fi

# 3. Cargo.toml must agree with VERSION (the binary and the plugin are
#    released together).
if [ ! -f Cargo.toml ]; then
  err "找不到 Cargo.toml"
else
  cargo_version=$(sed -n 's/^version = "\([^"]*\)"$/\1/p' Cargo.toml | head -n 1)
  if [ "$cargo_version" = "$version" ]; then
    ok "Cargo.toml version = $version"
  else
    err "Cargo.toml version 是 '${cargo_version:-<未找到>}'，应更新为 $version"
  fi
fi

# 4. The helper binary is part of the release; it must be tracked by git
#    (prepare.sh uses git archive), executable and report the same version.
binary="bin/linux-x86_64/langid"
if [ ! -f "$binary" ]; then
  err "缺少 $binary（请先运行 scripts/build.sh 并提交）"
elif [ ! -x "$binary" ]; then
  err "$binary 不可执行"
else
  ok "$binary 存在且可执行"
fi

if [ -f "$binary" ] && git ls-files --error-unmatch "$binary" >/dev/null 2>&1; then
  ok "$binary 已被 git 跟踪"
else
  err "$binary 未被 git 跟踪，git archive 不会包含它"
fi

if [ -f "$binary" ] && git diff --quiet HEAD -- "$binary" 2>/dev/null; then
  ok "$binary 与 HEAD 一致"
else
  warn "$binary 与 HEAD 不一致（发布包将使用 HEAD 中的版本）"
fi

if [ -x "$binary" ]; then
  reported=$("$binary" --version 2>/dev/null || true)
  if [ -n "$reported" ]; then
    case "$reported" in
      *"$version"*) ok "helper version: $reported" ;;
      *) err "helper 报告的版本是 '$reported'，应包含 $version" ;;
    esac
  else
    warn "无法运行 $binary --version（非 Linux x86_64 构建机？）"
  fi
fi

# 5. HEAD is the tagged commit.
head_sha=$(git rev-parse HEAD 2>/dev/null || true)
if [ -z "$expected_sha" ]; then
  warn "RELEASE_SHA 未设置，跳过 HEAD 校验"
elif [ "$head_sha" = "$expected_sha" ]; then
  ok "HEAD = $head_sha（tag $tag 指向的提交）"
else
  err "HEAD ($head_sha) 与 tag $tag 指向的提交 ($expected_sha) 不一致"
fi

echo
if [ "$errors" -ne 0 ]; then
  echo "[ERROR] preflight 失败：$errors 项检查未通过（可设 RELEASE_PRECHECK_OVERRIDE=pass 临时放行）"
  exit 1
fi
echo "[OK] preflight 通过"
