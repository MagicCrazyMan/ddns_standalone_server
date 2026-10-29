#!/usr/bin/env bash
#
# 构建 linux/amd64 + linux/arm64 双架构镜像并推送到 GHCR。
# 使用 docker buildx 多平台构建，自动生成 manifest list：
# 拉取时会按客户端 CPU 架构自动选择对应镜像。
#
# 推送的标签：
#     <IMAGE_NAME>:<version>      ← 多架构 manifest
#     <IMAGE_NAME>:latest         ← 多架构 manifest
#
# 用法：
#     ./docker/push.sh
#     ./docker/push.sh --help
#
# 认证（任选其一）：
#     gh auth refresh -s write:packages -s read:packages
#     echo "$CR_PAT" | docker login ghcr.io -u <GitHub 用户名> --password-stdin
#   脚本会优先复用已有的 gh CLI 登录态；都没有时会报错提示。
#
# 可用环境变量（可选）：
#     IMAGE_NAME   默认 ghcr.io/<小写 GitHub 用户名>/ddns_standalone_server
#     ARCHS        默认 "amd64 arm64"
#     VERSION      覆盖版本号，默认取 Cargo.toml
#     OFFLINE=1    编译时加 --offline，跳过 cargo 索引更新
#     LOCAL=1      只在本机构建各架构镜像，不推送、不生成 manifest
#     SKIP_BUILD=1 跳过编译，直接用 .build/ 里已暂存的二进制

set -euo pipefail

BINARY_NAME="ddns_standalone_server"
ARCHS="${ARCHS:-amd64 arm64}"
OFFLINE="${OFFLINE:-0}"
LOCAL="${LOCAL:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
STAGE_ROOT="$SCRIPT_DIR/.build"

info() { printf '\033[32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,/^set -euo pipefail/{/^set -euo pipefail/d;p}' "${BASH_SOURCE[0]}" \
        | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) usage >&2; die "未知参数：$1" ;;
esac

command -v docker >/dev/null 2>&1 || die "未找到 docker，请先安装 Docker Engine：https://docs.docker.com/engine/install/"

# ---------------------------------------------------------------- 确定镜像名

resolve_owner() {
    if [[ -n "${GHCR_OWNER:-}" ]]; then
        echo "$GHCR_OWNER"
        return
    fi

    if command -v gh >/dev/null 2>&1; then
        local login
        login="$(gh api user --jq .login 2>/dev/null || true)"
        if [[ -n "$login" ]]; then
            echo "$login"
            return
        fi
    fi

    local url
    url="$(git -C "$PROJECT_ROOT" config --get remote.origin.url 2>/dev/null || true)"
    if [[ -n "$url" ]]; then
        echo "$url" | sed -E 's#\.git$##; s#^.*[:/]([^/]+)/[^/]+$#\1#'
        return
    fi

    echo ""
}

if [[ -z "${IMAGE_NAME:-}" ]]; then
    OWNER="$(resolve_owner)"
    [[ -n "$OWNER" ]] || die "无法确定 GitHub 用户名，请显式设置 IMAGE_NAME=ghcr.io/<owner>/$BINARY_NAME"
    IMAGE_NAME="ghcr.io/$OWNER/$BINARY_NAME"
fi

# GHCR 的仓库路径必须全小写，自动纠正并提示
LOWER_IMAGE_NAME="$(echo "$IMAGE_NAME" | tr 'A-Z' 'a-z')"
if [[ "$LOWER_IMAGE_NAME" != "$IMAGE_NAME" ]]; then
    warn "GHCR 路径不能包含大写字母，镜像名已改为：$LOWER_IMAGE_NAME"
    IMAGE_NAME="$LOWER_IMAGE_NAME"
fi

[[ "$IMAGE_NAME" == */* ]] || die "IMAGE_NAME 需要带 registry 前缀，例如 ghcr.io/<owner>/$BINARY_NAME"
REGISTRY="${IMAGE_NAME%%/*}"

# ---------------------------------------------------------------- 架构与版本

ARCH_LIST=()
for arch in $ARCHS; do
    case "$arch" in
        amd64|arm64) ARCH_LIST+=("$arch") ;;
        *) die "不支持的架构：$arch（仅支持 amd64 / arm64）" ;;
    esac
done
[[ ${#ARCH_LIST[@]} -gt 0 ]] || die "ARCHS 为空"

PLATFORMS=""
for arch in "${ARCH_LIST[@]}"; do
    PLATFORMS="${PLATFORMS:+$PLATFORMS,}linux/$arch"
done

cd "$PROJECT_ROOT"

if [[ -n "${VERSION:-}" ]]; then
    info "使用指定的版本号：$VERSION"
else
    VERSION="$(cargo metadata --no-deps --format-version 1 2>/dev/null \
        | grep -o '"version":"[^"]*"' | head -n 1 | cut -d'"' -f4 || true)"
    if [[ -z "$VERSION" ]]; then
        VERSION="$(grep -m1 -E '^version[[:space:]]*=' Cargo.toml | cut -d'"' -f2)"
    fi
fi
[[ -n "$VERSION" ]] || die "无法读取版本号，请设置 VERSION 环境变量"

info "镜像:     $IMAGE_NAME"
info "版本:     $VERSION"
info "平台:     $PLATFORMS"

# ---------------------------------------------------------------- 登录

ensure_login() {
    local registry="$1"
    local cfg="${DOCKER_CONFIG:-$HOME/.docker}/config.json"

    if [[ -f "$cfg" ]] && grep -qs "\"$registry\"" "$cfg"; then
        info "已登录 $registry"
        return 0
    fi

    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        local login
        login="$(gh api user --jq .login 2>/dev/null || true)"
        if [[ -n "$login" ]]; then
            info "使用 gh CLI 的 token 登录 $registry（账号 $login）"
            gh auth token | docker login "$registry" -u "$login" --password-stdin
            return 0
        fi
    fi

    cat >&2 <<EOF
$(printf '\033[31merror:\033[0m') 未登录 $registry

请任选其一：

  1. 补上 packages 权限并自动登录
       gh auth refresh -s write:packages -s read:packages
       gh auth token | docker login $registry -u "\$(gh api user --jq .login)" --password-stdin

  2. 使用 Personal Access Token（需勾选 write:packages + read:packages）
       echo "\$CR_PAT" | docker login $registry -u <GitHub 用户名> --password-stdin

首次推送后，包默认是 private，需要在
  https://github.com/users/<owner>/packages/container/$BINARY_NAME/settings
手动改为 Public，并关联到对应仓库。
EOF
    exit 1
}

if [[ "$LOCAL" != 1 ]]; then
    ensure_login "$REGISTRY"
fi

# ---------------------------------------------------------------- 编译暂存

if [[ "$SKIP_BUILD" != 1 ]]; then
    for arch in "${ARCH_LIST[@]}"; do
        info "======== 编译 $arch ========"
        env \
            STAGE_ONLY=1 \
            OFFLINE="$OFFLINE" \
            "$SCRIPT_DIR/build.sh" --arch "$arch"
    done
else
    info "SKIP_BUILD=1，跳过编译"
fi

# 确认所有架构的产物都在
for arch in "${ARCH_LIST[@]}"; do
    [[ -f "$STAGE_ROOT/$arch/$BINARY_NAME" ]] \
        || die "缺少暂存产物：$STAGE_ROOT/$arch/$BINARY_NAME（请去掉 SKIP_BUILD=1 重新编译）"
done

# ---------------------------------------------------------------- 构建镜像

TAG_VERSION="$IMAGE_NAME:$VERSION"
TAG_LATEST="$IMAGE_NAME:latest"

if [[ "$LOCAL" == 1 ]]; then
    # 本地模式：逐架构构建到本地镜像库（--load 不支持多平台）
    for arch in "${ARCH_LIST[@]}"; do
        info "======== 构建本地镜像 linux/$arch ========"
        docker build \
            --platform "linux/$arch" \
            --build-arg "VERSION=$VERSION" \
            --build-arg "TARGETARCH=$arch" \
            -f "$SCRIPT_DIR/Dockerfile" \
            -t "$IMAGE_NAME:$VERSION-$arch" \
            -t "$IMAGE_NAME:latest-$arch" \
            "$SCRIPT_DIR"
    done

    info "完成（仅本地，未推送）："
    docker image ls --format '  {{.Repository}}:{{.Tag}}  ({{.Size}})' \
        | grep -E "^  ${IMAGE_NAME}:" || true
    exit 0
fi

# 多平台构建 + 推送：buildx 会顺带生成 manifest list
info "多平台构建并推送（$PLATFORMS）..."
docker buildx build \
    --platform "$PLATFORMS" \
    --build-arg "VERSION=$VERSION" \
    -f "$SCRIPT_DIR/Dockerfile" \
    -t "$TAG_VERSION" \
    -t "$TAG_LATEST" \
    --push \
    "$SCRIPT_DIR"

# ---------------------------------------------------------------- 结果

echo
info "已推送："
echo "  $TAG_VERSION"
echo "  $TAG_LATEST"
echo
echo "拉取示例（自动匹配架构）："
echo "  docker pull $TAG_LATEST"
echo "  docker run -d --rm -p 9080:9080 --name $BINARY_NAME $TAG_LATEST"
echo
echo "检查多架构内容："
echo "  docker buildx imagetools inspect $TAG_VERSION"
