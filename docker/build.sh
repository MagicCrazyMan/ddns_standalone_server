#!/usr/bin/env bash
#
# 在宿主机上用 musl 静态链接构建 ddns_standalone_server，
# 然后打包为 Docker 镜像：
#     <IMAGE_NAME>:<Cargo.toml 中的 version>
#     <IMAGE_NAME>:latest
#
# 链接器优先使用 cargo-zigbuild（zig 自带 musl 交叉链接能力），
# 未安装时回退到 musl-gcc。
#
# 用法：
#     ./docker/build.sh                   构建当前宿主机架构
#     ./docker/build.sh --arch arm64      交叉构建 linux/arm64
#     ./docker/build.sh -a amd64          显式指定 linux/amd64
#     ./docker/build.sh --help
#
# 可用环境变量（可选）：
#     IMAGE_NAME    镜像名，默认 ddns_standalone_server
#                    多架构推送到 GHCR 时用 docker/push.sh
#     ARCH          目标架构 amd64 / arm64，默认按宿主机自动识别
#     TARGET        直接指定 Rust 目标三元组，覆盖 ARCH 推导
#     TAG_SUFFIX    标签后缀：设为 -arm64 时打出 :<version>-arm64 与 :latest-arm64
#     NO_LATEST=1   只打版本标签，不打 :latest
#     PUSH=1        构建完成后立即 docker push 本次打出的所有标签
#     OFFLINE=1     给 cargo 加 --offline，跳过索引更新（依赖已缓存时更快）
#     STAGE_ONLY=1  只编译并把产物暂存到 .build/<arch>/，不构建 docker 镜像
#     NO_ZIGBUILD=1 强制使用系统 musl-gcc，即使已安装 cargo-zigbuild

set -euo pipefail

BINARY_NAME="ddns_standalone_server"
IMAGE_NAME="${IMAGE_NAME:-ddns_standalone_server}"
TAG_SUFFIX="${TAG_SUFFIX:-}"
NO_LATEST="${NO_LATEST:-0}"
PUSH="${PUSH:-0}"
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

# ---------------------------------------------------------------- 参数解析

ARCH_ARG=""
TARGET_ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)   usage; exit 0 ;;
        -a|--arch)   ARCH_ARG="${2:-}"; shift 2 ;;
        --arch=*)    ARCH_ARG="${1#*=}"; shift ;;
        -t|--target) TARGET_ARG="${2:-}"; shift 2 ;;
        --target=*)  TARGET_ARG="${1#*=}"; shift ;;
        *)           usage >&2; die "未知参数：$1" ;;
    esac
done

# ---------------------------------------------------------------- 架构映射

die_arch() { die "不支持的架构：$1（仅支持 amd64 / arm64）"; }

host_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        *) die "不支持的宿主机架构：$(uname -m)（仅支持 x86_64 / aarch64）" ;;
    esac
}

arch_to_target() {
    case "$1" in
        amd64) echo x86_64-unknown-linux-musl ;;
        arm64) echo aarch64-unknown-linux-musl ;;
        *) die_arch "$1" ;;
    esac
}

target_to_arch() {
    case "$1" in
        x86_64-unknown-linux-musl)   echo amd64 ;;
        aarch64-unknown-linux-musl)  echo arm64 ;;
        *) die "不支持的 TARGET：$1（仅支持 x86_64-unknown-linux-musl / aarch64-unknown-linux-musl）" ;;
    esac
}

if [[ -n "$TARGET_ARG" ]]; then
    TARGET="$TARGET_ARG"
    ARCH="$(target_to_arch "$TARGET")"
elif [[ -n "${TARGET:-}" ]]; then
    ARCH="$(target_to_arch "$TARGET")"
elif [[ -n "$ARCH_ARG" ]]; then
    ARCH="$(echo "$ARCH_ARG" | tr 'A-Z' 'a-z')"
    TARGET="$(arch_to_target "$ARCH")"
else
    ARCH="$(host_arch)"
    TARGET="$(arch_to_target "$ARCH")"
fi

ARCH="$(echo "$ARCH" | tr 'A-Z' 'a-z')"
case "$ARCH" in amd64|arm64) ;; *) die_arch "$ARCH" ;; esac
PLATFORM="linux/$ARCH"
CC_BIN="${CC_BIN:-}"
HOST_ARCH="$(host_arch)"

# ---------------------------------------------------------------- 工具链检查

command -v cargo >/dev/null 2>&1 || die "未找到 cargo，请先安装 Rust 工具链：https://rustup.rs"
command -v rustc >/dev/null 2>&1 || die "未找到 rustc，请先安装 Rust 工具链：https://rustup.rs"
command -v docker >/dev/null 2>&1 || die "未找到 docker，请先安装 Docker Engine：https://docs.docker.com/engine/install/"

# 1) 检查 Rust 标准库是否包含该 target
TARGET_LIBDIR="$(rustc --print target-libdir --target "$TARGET" 2>/dev/null || true)"
if [[ ! -d "$TARGET_LIBDIR" ]]; then
    cat >&2 <<EOF
$(printf '\033[31merror:\033[0m') 未安装 Rust target：$TARGET

请先安装该 target：

    rustup target add $TARGET

如果机器上没有 rustup，请先安装：https://rustup.rs
EOF
    exit 1
fi

# 2) 选择链接器：优先 cargo-zigbuild（zig 自带 musl 交叉链接），其次 musl-gcc
USE_ZIGBUILD=0
LINKER_FLAGS=()
if [[ "${NO_ZIGBUILD:-0}" != 1 ]] \
    && command -v cargo-zigbuild >/dev/null 2>&1 \
    && command -v zig >/dev/null 2>&1; then
    USE_ZIGBUILD=1
fi

if [[ "$USE_ZIGBUILD" == 1 ]]; then
    ZIG_VERSION="$(zig version 2>/dev/null || echo '?')"
    info "链接器:   zig $ZIG_VERSION（cargo-zigbuild）+ rust-lld 最终链接"
    # 新版 zig 的 lld 驱动不支持 Rust 给 aarch64-musl 传的
    # --fix-cortex-a53-843419，因此 C 依赖交给 zigbuild，
    # 最终链接改用 Rust 自带的 rust-lld（它接受该参数）。
    LINKER_FLAGS=(-C linker=rust-lld -C linker-flavor=ld.lld)
else
    if [[ -z "$CC_BIN" ]]; then
        if [[ "$HOST_ARCH" == "$ARCH" ]]; then
            # 原生构建：musl-tools 在 amd64 / arm64 上提供的都是 musl-gcc
            CC_BIN="musl-gcc"
        else
            # 交叉编译：需要带目标前缀的 musl 工具链
            case "$ARCH" in
                amd64) CC_BIN="x86_64-linux-musl-gcc" ;;
                arm64) CC_BIN="aarch64-linux-musl-gcc" ;;
            esac
        fi
    fi

    if ! command -v "$CC_BIN" >/dev/null 2>&1; then
        cat >&2 <<EOF
$(printf '\033[31merror:\033[0m') 未找到 musl 编译工具链，也没有可用的 cargo-zigbuild

请任选一种方式安装：

  A. 原生构建（$HOST_ARCH -> $ARCH，推荐）
      Debian/Ubuntu 上 musl-tools 同时提供 amd64 与 arm64 版本：

          sudo apt install musl-tools

  B. 用 zig 作为交叉链接器（无需额外系统包）
      # 安装 zig，例如 apt / AUR / 官网 tar 包：https://ziglang.org/download/
      cargo install cargo-zigbuild
      然后重跑本脚本

  C. 交叉编译（$HOST_ARCH 上构建 $ARCH）
      Debian/Ubuntu 无官方交叉包，可选其一：
        * musl.cc 预编译工具链：https://musl.cc/#binaries
          下载对应 *-linux-musl-cross.tgz，解压后把 bin/ 加入 PATH
        * musl-cross-make 自行构建：https://github.com/richfelker/musl-cross-make

  当前需要的链接器：$CC_BIN（宿主机架构：$HOST_ARCH，目标架构：$ARCH）
EOF
        exit 1
    fi

    info "链接器:   $CC_BIN$([[ "$HOST_ARCH" == "$ARCH" ]] && echo "（原生构建）" || echo "（交叉编译）")"
fi

# ---------------------------------------------------------------- 编译

# rust-lld 需要能被 rustc 找到
if [[ "$USE_ZIGBUILD" == 1 ]] && ! command -v rust-lld >/dev/null 2>&1; then
    RUST_LLD_DIR="$(rustc --print sysroot)/lib/rustlib/$(rustc -vV | sed -n 's/^host: //p')/bin"
    if [[ -x "$RUST_LLD_DIR/rust-lld" ]]; then
        export PATH="$RUST_LLD_DIR:$PATH"
    else
        warn "未找到 rust-lld，回退到 zig 自带链接器（aarch64 可能因 --fix-cortex-a53-843419 失败）"
        LINKER_FLAGS=()
    fi
fi

EXTRA_FLAGS=(-C strip=symbols)
if [[ ${#LINKER_FLAGS[@]} -gt 0 ]]; then
    EXTRA_FLAGS+=("${LINKER_FLAGS[@]}")
fi
export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }${EXTRA_FLAGS[*]}"

CARGO_OFFLINE=()
[[ "$OFFLINE" == 1 ]] && CARGO_OFFLINE+=(--offline)

if [[ "$USE_ZIGBUILD" == 1 ]]; then
    BUILD_CMD=(cargo zigbuild --release --target "$TARGET" "${CARGO_OFFLINE[@]}")
else
    TARGET_UPPER="$(echo "$TARGET" | tr 'a-z-' 'A-Z_')"
    export "CARGO_TARGET_${TARGET_UPPER}_LINKER=$CC_BIN"
    export "CC_${TARGET//-/_}=$CC_BIN"
    BUILD_CMD=(cargo build --release --target "$TARGET" "${CARGO_OFFLINE[@]}")
fi

info "目标架构: $ARCH（$TARGET，Docker platform: $PLATFORM）"
info "开始编译（release，musl 静态链接）..."
(cd "$PROJECT_ROOT" && "${BUILD_CMD[@]}")

BIN_SOURCE="$PROJECT_ROOT/target/$TARGET/release/$BINARY_NAME"
[[ -f "$BIN_SOURCE" ]] || die "未找到编译产物：$BIN_SOURCE"

if command -v file >/dev/null 2>&1 && ! file -b "$BIN_SOURCE" | grep -qiE 'statically linked|static-pie linked'; then
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
BIN_PATH="$BIN_DIR/$BINARY_NAME"
mkdir -p "$BIN_DIR"
rm -f "$BIN_PATH"
cp "$BIN_SOURCE" "$BIN_PATH"
chmod 0755 "$BIN_PATH"

if [[ "$STAGE_ONLY" == 1 ]]; then
    info "STAGE_ONLY=1，已暂存：$BIN_PATH"
    exit 0
fi

TAG_VERSION="$IMAGE_NAME:${VERSION}${TAG_SUFFIX}"
TAG_LATEST="$IMAGE_NAME:latest${TAG_SUFFIX}"

TAGS=(-t "$TAG_VERSION")
PUSH_TAGS=("$TAG_VERSION")
if [[ "$NO_LATEST" != 1 ]]; then
    TAGS+=(-t "$TAG_LATEST")
    PUSH_TAGS+=("$TAG_LATEST")
fi

info "构建镜像（$PLATFORM）：${PUSH_TAGS[*]}"
docker build \
    --platform "$PLATFORM" \
    --build-arg "VERSION=$VERSION" \
    --build-arg "TARGETARCH=$ARCH" \
    -f "$SCRIPT_DIR/Dockerfile" \
    "${TAGS[@]}" \
    "$SCRIPT_DIR"

if [[ "$PUSH" == 1 ]]; then
    for tag in "${PUSH_TAGS[@]}"; do
        info "推送 $tag"
        docker push "$tag"
    done
fi

info "完成："
docker image ls --format '  {{.Repository}}:{{.Tag}}  ({{.Size}})' \
    | grep -E "^  ${IMAGE_NAME}:" || true
echo
echo "运行示例："
echo "  docker compose -f \"$SCRIPT_DIR/docker-compose.yml\" up -d"
echo "  或 docker run -d --rm -p 9080:9080 --name $BINARY_NAME ${IMAGE_NAME}:latest${TAG_SUFFIX}"
