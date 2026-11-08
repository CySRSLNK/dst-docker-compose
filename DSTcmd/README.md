# DSTtest

面向 Ubuntu 22.04 LTS x86_64 的饥荒联机版专用服务器安装和管理项目，不需要 Docker。

本项目支持一个房间，地表和可选洞穴分别由 systemd 管理。安装不会自动启动游戏，不会自动更换软件源或修改防火墙。

## 0. 远程服务器准备

目标服务器需要满足：

- Ubuntu `22.04.x LTS`
- `x86_64` 架构
- 正常运行 `systemd`
- 一个可以使用 `sudo` 的普通登录用户
- 能访问 Ubuntu 软件源、Steam 下载服务和 Klei 服务
- 云平台安全组允许后文列出的游戏端口

不需要提前安装 Docker、SteamCMD、screen 或游戏服务器。安装脚本会自动安装所需的系统依赖、启用 i386 软件包架构、创建受限的 `dst` 系统用户并下载 SteamCMD 和游戏服务器。

先通过 SSH 登录并确认系统：

```bash
ssh 用户名@服务器公网IP
lsb_release -ds
uname -m
sudo -v
```

输出应类似：

```text
Ubuntu 22.04.5 LTS
x86_64
```

建议先更新系统并确认磁盘空间：

```bash
sudo apt-get update
df -h /
```

安装脚本会执行 `apt-get update` 和安装依赖。如果服务器不能访问软件源或 Steam，安装会失败；需要先修复网络、代理或云平台出口策略。

## 1. 上传和安装

在本地项目的上一级目录执行上传。Windows PowerShell 示例：

```powershell
scp -r .\DSTtest 用户名@服务器公网IP:~/
```

如果服务器 SSH 使用非默认端口：

```powershell
scp -P 端口号 -r .\DSTtest 用户名@服务器公网IP:~/
```

也可以使用 SFTP、rsync 或云平台文件上传功能，但必须完整上传 `DSTtest` 目录。上传后回到 SSH 会话：

```bash
cd ~/DSTtest
chmod +x install.sh dst.sh shard.sh
sudo bash install.sh
```

安装脚本需要 root 权限，但游戏进程不会以 root 运行，而是使用 `dst` 用户。

仅地表服务器：

```bash
sudo bash install.sh --no-caves
```

安装会从 Steam 分发地址下载 SteamCMD，通过匿名登录下载 AppID `343050`。第一次安装时间取决于服务器带宽，安装完成后不会自动启动游戏。

## 2. 配置房间

默认目录：

| 路径 | 用途 |
| --- | --- |
| `/opt/dst/server` | 游戏程序与运行时模组 |
| `/opt/dst/steamcmd` | SteamCMD |
| `/opt/dst/dst.sh` | 管理脚本 |
| `/etc/dst/dst.conf` | 管理配置，不存放令牌 |
| `/var/lib/dst/DoNotStarveTogether/Cluster_1` | 房间配置、世界存档和游戏日志 |
| `/var/lib/dst/mods` | 模组下载列表和本地模组原始副本 |
| `/var/backups/dst` | 仅管理员可访问的备份 |

从 Klei 账户页面取得服务器令牌，编辑下列文件，只填入令牌本身：

```bash
sudoedit /var/lib/dst/DoNotStarveTogether/Cluster_1/cluster_token.txt
sudoedit /var/lib/dst/DoNotStarveTogether/Cluster_1/cluster.ini
```

`cluster.ini` 中可以修改房间名称、描述、密码、人数等。保留 `console_enabled = true`，停止服务需要通过游戏控制台保存退出。默认生成生存模式，最多 6 人；洞穴使用 `DST_CAVE` 预设。

### 更换房间

“房间”在服务器文件中对应一个 Cluster 目录。当前默认房间是：

```text
/var/lib/dst/DoNotStarveTogether/Cluster_1
```

不要直接修改 `cluster.ini` 里的 `cluster_name` 来切换存档；`cluster_name` 只是房间显示名称，实际存档由 `CLUSTER_NAME` 和目录名决定。

切换到另一个**已经存在的房间**，例如 `Cluster_2`：

```bash
sudo dst stop
sudo dst backup
sudoedit /etc/dst/dst.conf
```

把这一行：

```bash
CLUSTER_NAME=Cluster_1
```

改成：

```bash
CLUSTER_NAME=Cluster_2
```

然后确认目标目录完整存在：

```bash
sudo ls -la /var/lib/dst/DoNotStarveTogether/Cluster_2
sudo dst check
sudo dst start
```

目标目录至少需要有：

```text
cluster.ini
cluster_token.txt
Master/server.ini
```

开启洞穴时还需要：

```text
Caves/server.ini
```

如果要把另一个服务器的房间导入为新房间，先把整个 Cluster 目录上传到远程服务器，再使用安装脚本导入。例如：

```bash
sudo dst stop
sudo bash install.sh --import /home/ubuntu/migration/Cluster_2
```

如果上传目录名不是目标房间名，先在 `/etc/dst/dst.conf` 中设置目标 `CLUSTER_NAME`，再执行安装。安装脚本只会导入到尚不存在的目标目录，不会覆盖已有房间：

```bash
sudoedit /etc/dst/dst.conf
# 例如：CLUSTER_NAME=Cluster_2
sudo bash install.sh --import /home/ubuntu/migration/Cluster_2
sudo dst check
sudo dst start
```

更稳妥的做法是使用安装脚本的 `--import` 参数，并确保目标目录尚未存在；详细命令见“导入现有服务器”。切换房间前必须确认旧房间已经停服，否则两个房间可能使用同一组端口。

### 房间配置文件

| 文件 | 作用 |
| --- | --- |
| `/etc/dst/dst.conf` | 当前使用哪个房间，主要修改 `CLUSTER_NAME` |
| `.../Cluster_x/cluster.ini` | 房间显示名、描述、密码、人数、模式和洞穴开关 |
| `.../Cluster_x/cluster_token.txt` | Klei 服务器令牌，每个房间通常使用自己的令牌 |
| `.../Cluster_x/Master/server.ini` | 地表端口和地表分片设置 |
| `.../Cluster_x/Caves/server.ini` | 洞穴端口和洞穴分片设置 |
| `.../Cluster_x/Master/leveldataoverride.lua` | 地表世界生成设置 |
| `.../Cluster_x/Caves/leveldataoverride.lua` | 洞穴世界生成设置 |
| `.../Cluster_x/Master/modoverrides.lua` | 地表启用哪些 Mod 及其配置 |
| `.../Cluster_x/Caves/modoverrides.lua` | 洞穴启用哪些 Mod 及其配置 |

修改 `cluster.ini`、`server.ini` 或 `modoverrides.lua` 前先执行 `sudo dst stop`，修改后执行 `sudo dst check && sudo dst start`。不要编辑 `/opt/dst/server` 中由 Steam 管理的程序文件。

首次启动前检查：

```bash
sudo dst check
sudo dst start
sudo dst logs
```

`check` 只检查基础文件和权限；真正的令牌认证、模组加载和联网结果需要查看启动日志。`start` 返回表示启动请求已提交，不表示房间已经上线。按 Ctrl+C 退出日志查看不会关闭服务器。

看到服务器启动日志后，可以用 `Ctrl+C` 退出日志查看，再检查服务状态：

```bash
sudo dst status
systemctl is-active dst@Master.service
systemctl is-active dst@Caves.service
```

如果只部署了地表，`dst@Caves.service` 不存在或未启用是正常的。以后重新 SSH 登录服务器时，直接执行 `sudo dst status` 即可查看运行状态；服务器重启后，执行 `sudo dst enable` 开启自动启动。

首次启动失败时，先查看完整日志：

```bash
sudo dst logs Master
sudo journalctl -u dst@Master.service -b --no-pager
```

常见原因是令牌为空、令牌复制时带入了多余内容、云平台端口未放行、旧配置中的地址仍指向容器，或模组配置有 Lua 语法错误。

## 3. 导入现有服务器

先在原服务器保存并停服，再复制整个 `Cluster_1` 文件夹到远程服务器。应包含 `cluster.ini`、`cluster_token.txt`、Master 和 Caves，以及各世界的存档、世界设置和 `modoverrides.lua`。

在**尚未初始化目标房间**时执行：

```bash
sudo bash install.sh \
  --import /home/ubuntu/migration/Cluster_1 \
  --mod-setup /home/ubuntu/migration/dedicated_server_mods_setup.lua \
  --local-mod /home/ubuntu/migration/Local_Collection_Skins
```

将示例中的用户名和路径替换成实际路径。没有本地模组或模组下载列表时，省略对应参数。只导入地表时加 `--no-caves`。

也可用 `--token-file /path/to/token.txt` 提供令牌文件。导入房间本身含有令牌时无需另传此参数。

导入会复制数据，不会修改源目录；目标房间已经存在时会拒绝导入。重复安装不会覆盖已有房间配置或模组副本，也不会自动合并两个存档。

导入后检查旧配置中的端口、`master_ip`、`bind_ip`、`cluster_key`。本项目默认地表和洞穴部署在同一台机器，不需要把旧容器内部地址带过来。

## 4. 模组

下载列表编辑这里：

```bash
sudoedit /var/lib/dst/mods/dedicated_server_mods_setup.lua
```

例如：

```lua
ServerModSetup("123456789")
```

下载列表负责下载；还需要在 Master 和 Caves 的 `modoverrides.lua` 中启用模组并填写配置，例如：

```lua
return {
    ["workshop-123456789"] = { enabled = true },
}
```

本地模组保存在 `/var/lib/dst/mods/模组目录名`。安装、管理命令启动和更新时会复制到游戏 `mods` 目录，减少 Steam 校验覆盖自定义文件的影响。修改后用 `sudo dst restart` 应用；新增文件需确保 `dst` 用户可读取。删除模组时，需要同时清理原始副本、游戏目录及世界中的启用配置。

### 更换 Mod 的标准流程

先停服并备份：

```bash
sudo dst stop
sudo dst backup
```

#### 创意工坊 Mod

1. 编辑下载列表：

```bash
sudoedit /var/lib/dst/mods/dedicated_server_mods_setup.lua
```

2. 添加或删除 Workshop ID：

```lua
ServerModSetup("123456789")
ServerModSetup("987654321")
```

3. 在对应世界启用 Mod：

```bash
sudoedit /var/lib/dst/DoNotStarveTogether/Cluster_1/Master/modoverrides.lua
sudoedit /var/lib/dst/DoNotStarveTogether/Cluster_1/Caves/modoverrides.lua
```

示例：

```lua
return {
    ["workshop-123456789"] = {
        enabled = true,
    },
}
```

只想地表使用的 Mod，只写入 `Master/modoverrides.lua`；地表和洞穴都要使用时，两个 `modoverrides.lua` 都要配置。下载列表中的 Mod 不代表一定启用，`modoverrides.lua` 才决定该世界是否加载。

4. 同步并启动：

```bash
sudo dst restart
sudo dst logs Master
```

`dst restart` 会把 `/var/lib/dst/mods` 同步到游戏目录。删除 Mod 时，同时从下载列表和对应的 `modoverrides.lua` 删除；若要彻底清理已下载文件，再删除 `/opt/dst/server/mods/workshop-模组ID`，不要删除游戏自带的 `modworldgen`、`modservercreation` 等目录。

#### 本地 Mod

将完整的本地 Mod 目录放到：

```text
/var/lib/dst/mods/你的模组目录名/
```

目录中应包含 `modinfo.lua`。然后设置权限并在世界配置中启用：

```bash
sudo chown -R dst:dst /var/lib/dst/mods/你的模组目录名
sudoedit /var/lib/dst/DoNotStarveTogether/Cluster_1/Master/modoverrides.lua
sudo dst restart
```

本地 Mod 的键名通常是目录名，具体以该 Mod 自带说明为准。`Local_Collection_Skins` 这类本地 Mod 不需要写入 `dedicated_server_mods_setup.lua`，但仍需要复制到 `/var/lib/dst/mods/` 并在需要的世界中启用。

### 同时维护多个房间的 Mod

`/var/lib/dst/mods/dedicated_server_mods_setup.lua` 是当前安装的全局下载列表；每个房间通过各自的 `Master/modoverrides.lua` 和 `Caves/modoverrides.lua` 决定是否启用。切换房间时，Mod 文件不需要重复下载，但要检查新房间的 `modoverrides.lua` 是否包含对应配置。

如果两个房间需要完全不同的 Mod 集合，建议分别保存两份配置，在切换房间前覆盖下载列表和对应的 `modoverrides.lua`，再执行 `sudo dst restart`。执行覆盖前先备份，避免误删正在使用的配置。

## 5. 日常管理

```bash
sudo dst start
sudo dst stop
sudo dst restart
sudo dst status
sudo dst logs Master
sudo dst logs Caves
sudo dst backup
sudo dst update
sudo dst enable
sudo dst disable
```

- `stop`：分别发送 `c_shutdown(true)`，等待保存退出。超过约 100 秒后报告失败，并由 systemd 继续清理进程；此时管理脚本不会继续备份或更新。
- `backup`：停服，打包房间、模组副本和管理配置，再恢复原先运行的服务。备份会造成短暂中断。
- `update`：停服、备份、SteamCMD 更新校验、恢复模组副本，再按原先运行状态启动。
- `enable` / `disable`：开启或关闭开机启动，不会立即启动或停止服务。

更新或备份失败时保持停服，保留已有备份，查看错误后再手动启动。备份包含令牌和房间密码，不要公开上传。暂不自动清理历史备份，需自行关注磁盘空间。

异常退出时 systemd 会尝试重启对应世界；5 分钟内最多允许 3 次启动。修复配置后如触发限流，可执行：

```bash
sudo systemctl reset-failed dst@Master.service dst@Caves.service
sudo dst start
```

默认未提供任意远程控制台命令入口，管理通过 SSH 完成。

## 6. 网络端口

新建房间默认配置：

| 用途 | 协议 | 端口 |
| --- | --- | --- |
| 地表游戏端口 | UDP | 10999 |
| 洞穴游戏端口 | UDP | 10998 |
| 地表 Steam 端口 | TCP | 27018、8768 |
| 洞穴 Steam 端口 | TCP | 27019、8769 |
| 地表和洞穴内部通信 | 本机 | 10888 |

根据实际配置检查云平台安全组及 Ubuntu 防火墙。内部通信默认绑定 `127.0.0.1`，不需对公网开放。导入存档时以导入的配置为准。

若已启用 UFW，默认新建双世界可以放行：

```bash
sudo ufw allow 10998:10999/udp
sudo ufw allow 27018:27019/tcp
sudo ufw allow 8768:8769/tcp
```

脚本不会开启 UFW，也不会改动现有 SSH 规则。

## 7. 恢复备份

先停服，把当前房间另行保存。选定备份后，先列出内容，在独立目录解压：

```bash
sudo dst stop
sudo tar -tzf /var/backups/dst/你的备份文件.tar.gz
sudo mkdir -p /var/tmp/dst-restore
sudo tar -xzf /var/backups/dst/你的备份文件.tar.gz -C /var/tmp/dst-restore
```

备份中的 `DoNotStarveTogether/` 和 `mods/` 对应 `/var/lib/dst/`，`dst/` 对应 `/etc/dst/`。确认需要恢复的内容后再替换目标文件，并把数据目录所有者设为 `dst:dst`。不要直接往 `/` 解压。程序本体不在备份中；此功能恢复存档和配置，不负责回滚 Steam 服务器版本。

## 8. 当前范围与验收

第一版仅支持 Ubuntu 22.04 x86_64、systemd、一个房间和最多地表/洞穴两个世界；不包含网页面板、定时更新或多房间管理。

重新运行安装脚本前必须停服。若要改变洞穴开关，停服后使用相应的 `--no-caves` 参数重新安装；已有世界的 `cluster.ini` 不会被覆盖，需同时手动调整 `shard_enabled`。已有安装不建议直接改管理配置中的目录；迁移目录还涉及数据复制和所有权检查。

本地可以做 Bash 语法检查和模拟测试。正式上线前仍需在 Ubuntu 上验证下载、令牌认证、地洞切换、模组加载、停服保存后重启和更新后的存档完整性。
