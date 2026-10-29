#!/usr/bin/env bash
#
# 在当前宿主机上用 musl 静态链接构建 ddns_standalone_server，
# 然后打包为 Docker 镜像：
#     <IMAGE_NAME>:<Cargo.toml 中的 version>
#     <IMAGE_NAME>:latest
#
# 只构建本机架构，不做交叉编译：
#     x86_64  -> x86_64-unknown-linux-musl
#     aarch64 -> aarch64-unknown-linux-musl
#
# 用法：
#     ./docker/build.sh
#     ./docker/build.sh --help
#
# 可用环境变量（可选）：
#     IMAGE_NAME    镜像名，默认 ddns_standalone_server
#     TAG_SUFFIX    标签后缀：设为 -arm64 时打出 :<version>-arm64 与 :latest-arm64
#     NO_LATEST=1   只打版本标签，不打 :latest
#     OFFLINE=1     给 cargo 加 --offline，跳过索引更新（依赖已缓存时更快）
#     STAGE_ONLY=1  只编译并暂存到 .build/<arch>/，不构建 docker 镜像

set -euo pipefail

BINARY_NAME="ddns_standalone_server"
IMAGE_NAME="${IMAGE_NAME:-ddns_standalone_server}"
TAG_SUFFIX="${TAG_SUFFIX:-}"
NO_LATEST="${NO_LATEST:-0}"
OFFLINE="${OFFLINE:-0}"
STAGE_ONLY="${STAGE_ONLY:-0}"

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
    *) usage >&2; die "未知参数：$1（本脚本只构建当前宿主机架构）" ;;
esac

# ---------------------------------------------------------------- 架构识别

case "$(uname -m)" in
    x86_64|amd64)  ARCH=amd64; TARGET=x86_64-unknown-linux-musl ;;
    aarch64|arm64) ARCH=arm64; TARGET=aarch64-unknown-linux-musl ;;
    *) die "不支持的宿主机架构：$(uname -m)（仅支持 x86_64 / aarch64）" ;;
esac

# ---------------------------------------------------------------- 工具链检查

command -v cargo >/dev/null 2>&1 || die "未找到 cargo，请先安装 Rust 工具链：https://rustup.rs"
command -v docker >/dev/null 2>&1 || die "未找到 docker，请先安装 Docker Engine：https://docs.docker.com/engine/install/"

TARGET_LIBDIR="$(rustc --print target-libdir --target "$TARGET" 2>/dev/null || true)"
if [[ ! -d "$TARGET_LIBDIR" ]]; then
    cat >&2 <<EOF
$(printf '\033[31merror:\033[0m') 未安装 Rust target：$TARGET

请先安装：

    rustup target add $TARGET

如果机器上没有 rustup，请先安装：https://rustup.rs
EOF
    exit 1
fi

CC_BIN="${CC_BIN:-musl-gcc}"
if ! command -v "$CC_BIN" >/dev/null 2>&1; then
    cat >&2 <<EOF
$(printf '\033[31merror:\033[0m') 未找到 musl 编译工具链：$CC_BIN

请先安装（Debian/Ubuntu 上 amd64 与 arm64 都由该包提供）：

    sudo apt install musl-tools

其他发行版请用对应的包管理器安装 musl 工具链。
EOF
    exit 1
fi

# ---------------------------------------------------------------- 编译

TARGET_UPPER="$(echo "$TARGET" | tr 'a-z-' 'A-Z_')"
export "CARGO_TARGET_${TARGET_UPPER}_LINKER=$CC_BIN"
export "CC_${TARGET//-/_}=$CC_BIN"
export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }-C strip=symbols"

CARGO_ARGS=(build --release --target "$TARGET")
if [[ "$OFFLINE" == 1 ]]; then
    CARGO_ARGS+=(--offline)
fi

info "架构:   $ARCH（$TARGET）"
info "链接器: $CC_BIN"
info "开始编译（release，musl 静态链接）..."
(cd "$PROJECT_ROOT" && cargo "${CARGO_ARGS[@]}")

BIN_SOURCE="$PROJECT_ROOT/target/$TARGET/release/$BINARY_NAME"
[[ -f "$BIN_SOURCE" ]] || die "未找到编译产物：$BIN_SOURCE"

if command -v file >/dev/null 2>&1 \
    && ! file -b "$BIN_SOURCE" | grep -qiE 'statically linked|static-pie linked'; then
    warn "编译产物可能不是静态链接，请检查 musl 配置：$(file -b "$BIN_SOURCE")"
fi

# ---------------------------------------------------------------- 版本与镜像

cd "$PROJECT_ROOT"

VERSION="$(cargo metadata --no-deps --format-version 1 2>/dev/null \
    | grep -o '"version":"[^"]*"' | head -n 1 | cut -d'"' -f4 || true)"
if [[ -z "$VERSION" ]]; then
    VERSION="$(grep -m1 -E '^version[[:space:]]*=' Cargo.toml | cut -d'"' -f2)"
fi
[[ -n "$VERSION" ]] || die "无法从 Cargo.toml / cargo metadata 读取版本号"

# 按架构暂存，Dockerfile 通过 TARGETARCH 选取对应文件
BIN_DIR="$STAGE_ROOT/$ARCH"
mkdir -p "$BIN_DIR"
rm -f "$BIN_DIR/$BINARY_NAME"
cp "$BIN_SOURCE" "$BIN_DIR/$BINARY_NAME"
chmod 0755 "$BIN_DIR/$BINARY_NAME"

if [[ "$STAGE_ONLY" == 1 ]]; then
    info "STAGE_ONLY=1，已暂存：$BIN_DIR/$BINARY_NAME"
    exit 0
fi

TAG_VERSION="$IMAGE_NAME:${VERSION}${TAG_SUFFIX}"
TAG_LATEST="$IMAGE_NAME:latest${TAG_SUFFIX}"

TAGS=(-t "$TAG_VERSION")
if [[ "$NO_LATEST" != 1 ]]; then
    TAGS+=(-t "$TAG_LATEST")
fi

info "构建镜像（linux/$ARCH）：$TAG_VERSION"
docker build \
    --platform "linux/$ARCH" \
    --build-arg "VERSION=$VERSION" \
    --build-arg "TARGETARCH=$ARCH" \
    -f "$SCRIPT_DIR/Dockerfile" \
    "${TAGS[@]}" \
    "$SCRIPT_DIR"

info "完成："
# 注意：docker image ls 会裁掉 format 里的前导空格，所以这里不按缩进匹配
docker image ls --format '{{.Repository}}:{{.Tag}}  ({{.Size}})' \
    | grep -E "^${IMAGE_NAME}:" \
    | sed 's/^/  /' || true
echo
echo "运行示例："
echo "  docker compose -f \"$SCRIPT_DIR/docker-compose.yml\" up -d"
echo "  或 docker run -d --rm -p 9080:9080 --name $BINARY_NAME $TAG_VERSION"
