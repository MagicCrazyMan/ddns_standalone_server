#
# 本镜像不在容器内编译源码，只负责把宿主机上用 musl 静态链接好的
# 可执行文件（由 docker/build.sh 预置到 .build/<arch>/）打包进镜像。
#
# 本文件刻意不含任何 RUN 指令：宿主机没注册 QEMU/binfmt 时，
# docker buildx 依然可以直接交叉构建 linux/arm64 镜像。
#
# 构建入口：
#     ./docker/build.sh    单架构本地构建
#     ./docker/push.sh     多架构构建 + 推送到 GHCR

FROM debian:13

ARG VERSION=unknown
ARG TARGETARCH=amd64

LABEL org.opencontainers.image.title="ddns_standalone_server" \
      org.opencontainers.image.description="Standalone DDNS server (\"/ip\" echo service)" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.architecture="${TARGETARCH}"

# 静态链接的 musl 可执行文件，无运行时依赖
# 源文件已是 0755，COPY 会保留该权限，因此无需 RUN chmod
COPY .build/${TARGETARCH}/ddns_standalone_server /usr/local/bin/ddns_standalone_server

# 以非 root 用户运行：使用纯数字 uid/gid，
# 避免 groupadd/useradd 在交叉构建时需要指令模拟
USER 10001:10001

# 与 src/main.rs 中绑定的端口保持一致
EXPOSE 9080

ENTRYPOINT ["/usr/local/bin/ddns_standalone_server"]
