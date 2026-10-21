FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# 配置国内镜像源
RUN sed -i 's|archive.ubuntu.com|mirrors.aliyun.com|g; \
            s|security.ubuntu.com|mirrors.aliyun.com|g; \
            s|cn.archive.ubuntu.com|mirrors.aliyun.com|g' \
            /etc/apt/sources.list

# 启用 multiverse，并配置 i386 架构
RUN apt-get update && \
    apt-get install -y --no-install-recommends screen software-properties-common && \
    add-apt-repository -y multiverse && \
    dpkg --add-architecture i386 && \
    apt-get update

# 安装 SteamCMD 和服务器运行所需的基础依赖
RUN apt-get install -y --no-install-recommends \
    lib32gcc-s1 \
    libstdc++6:i386 \
    libgcc-s1:i386 \
    libcurl4-gnutls-dev:i386 \
    && rm -rf /var/lib/apt/lists/*

# 复制 SteamCMD 和脚本
COPY Steamcmd/ /root/Steamcmd/
COPY begin.sh /root/begin.sh
COPY start.sh /root/start.sh
COPY end.sh /root/end.sh

RUN chmod +x /root/begin.sh
RUN chmod +x /root/start.sh
RUN chmod +x /root/end.sh

# 创建服务器安装目录
RUN mkdir -p /root/dontstarvetogether_dedicated_server

# 下载饥荒联机版专用服务器
RUN chmod +x /root/Steamcmd/steamcmd.sh && \
    /root/Steamcmd/steamcmd.sh \
      +force_install_dir /root/dontstarvetogether_dedicated_server \
      +login anonymous \
      +app_update 343050 validate \
      +quit

COPY dedicated_server_mods_setup.lua /root/dontstarvetogether_dedicated_server/mods/dedicated_server_mods_setup.lua

WORKDIR /root