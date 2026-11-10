# DST 专用服务器 Web 面板 · 设计方案

> 状态：待确认（v0.1 计划稿）
> 依据：本目录现有 `install.sh`、`dst.sh`、`shard.sh`、`dst.conf`、`README.md`、`tests/smoke.sh`
> 目标机器：Ubuntu 22.04 x86_64 + systemd，单房间（Master + 可选 Caves）

---

## 1. 现状盘点：面板要包装的到底是什么

先把脚本里已经确定的行为列清楚，面板的设计必须顺着这些约束走，而不是再造一套。

| 现有事实 | 出处 | 对面板的直接影响 |
| --- | --- | --- |
| 唯一管理入口是 `sudo dst <cmd>`，root 才能跑 | [dst.sh:5](../dst.sh#L5) | 面板需要一个受控提权通道，不能自己乱拼 shell |
| 全局互斥锁 `/run/lock/dst-manager.lock`，`flock -n`，抢不到直接失败 | [dst.sh:23-24](../dst.sh#L23-L24) | 面板必须把"另一个操作正在运行"当作正常状态展示，并串行化自己的任务 |
| 两个单元 `dst@Master.service`、`dst@Caves.service`，由 `dst.target` 聚合；失败自动重启，5 分钟最多 3 次 | [install.sh:202-240](../install.sh#L202-L240) | 状态/日志按 shard 维度取；面板要能提示"已触发启动限流"并给 `reset-failed` 入口 |
| 停服是优雅的：`ExecStop` → `shard.sh stop` → 往 FIFO 写 `c_shutdown(true)`，最多等 100 秒，超时才 SIGINT | [shard.sh:31-45](../shard.sh#L31-L45) | `stop`/`restart`/`update` 都是长任务，必须走异步作业 + 进度流，不能同步等 HTTP |
| **控制台通道已经存在**：`/run/dst-<shard>/console`（FIFO，0600，目录 0700） | [shard.sh:8](../shard.sh#L8)、[install.sh:216-217](../install.sh#L216-L217) | "发控制台命令"不需要改游戏侧，写入这个 FIFO 即可；这是本方案的核心增量能力 |
| `backup` 的真实语义是**停服 → 打包 → 按原状态启回去**，备份含 token 与房间密码，目录 0700 root | [dst.sh:95-108](../dst.sh#L95-L108) | 按钮文案必须写清"会短暂停服"；备份下载/恢复需要 root 侧配合，不能让面板用户直接读目录 |
| `update` 失败时**保持停服**、保留备份 | [dst.sh:100-106](../dst.sh#L100-L106) | 面板要在失败后显著提示，并提供"仍然启动"按钮 |
| 配置分两层：`/etc/dst/dst.conf`（路径/房间名）与房间目录 `cluster.ini`、`cluster_token.txt`、`Master|Caves/server.ini`、`modoverrides.lua`、`leveldataoverride.lua` | [install.sh:108-181](../install.sh#L108-L181) | 编辑要分流：哪些热改、哪些必须停服 |
| 令牌 `0600 dst:dst`，`dst` 用户可读；目录整体 `chown dst:dst` | [install.sh:176-181](../install.sh#L176-L181) | 面板永不回显令牌原文；写入用"替换"语义 |
| 端口默认 10999/10998 UDP、27018/27019 + 8768/8769 TCP、10888 仅本机 | [README.md:368-388](../README.md#L368-L388) | 网络页做"配置值 vs 实际监听 vs UFW"三列对照 |
| README 明确"默认未提供任意远程控制台命令入口" | [README.md:366](../README.md#L366) | 面板即是在补这个洞，因此安全边界要写进设计，而不是事后加 |
| 首版验收标准写明"不包含网页面板" | [README.md:405-411](../README.md#L405-L411) | 面板保持**零侵入**：不改 `dst.sh`/`shard.sh`/`install.sh`，独立目录独立安装 |

结论：不做"重写一套管理逻辑"，而是 **做一个包装现有脚本的、权限受限的 Web 前端**。所有会改变服务器状态的动作，最终仍落到已被 `tests/smoke.sh` 覆盖的那几条 `dst.sh` 命令上。

---

## 2. 目标与非目标

### 目标（v1）

1. 浏览器完成 README 第 5 节的全部日常操作：`check / start / stop / restart / status / logs / backup / update / enable / disable`。
2. 补上脚本没有的两个高频能力：**实时日志** 和 **控制台命令**（含"谁在线"）。
3. 图形化编辑三处配置（`cluster.ini`、`server.ini`、`modoverrides.lua`），带校验、差异预览、自动备份。
4. Mod 管理：创意工坊 ID 的增删、两个世界分别启停、元数据展示。
5. 备份可视化：列表、手动创建、下载、两阶段恢复、简单保留策略。
6. 默认只监听 `127.0.0.1`，通过 SSH 隧道访问；可选 TLS 反代方案。
7. 单二进制、无 Node/Python 运行时依赖、可离线部署；面板挂掉不影响游戏。

### 非目标（明确不做，避免范围蔓延）

- 多房间同时运行（当前 `dst.conf` 只有一个 `CLUSTER_NAME`）；v1 只做"当前房间"，切换房间留到 v2 且需要先停服。
- 世界生成器的全量表单（几百个 worldgen 参数）。v1 提供预设模板 + Lua 原文编辑，够用且不会做错。
- 多用户 / RBAC / 对外 SaaS。v1 单管理员（或极少数账号），审计留痕。
- 公网裸奔直连。默认就不允许，必须经隧道或 TLS 反代。
- 跨主机的远程管理（面板只管理本机 systemd）。
- 容器化部署（与本项目"不用 Docker"的定位一致）。

---

## 3. 总体架构

```
                    ┌──────────────────────────────────────────┐
  浏览器 (LAN/手机)  │  SPA-lite: Go html/template + htmx        │
  或 SSH 隧道         │  深色主题 / 响应式 / SSE 日志             │
                    └───────────────┬──────────────────────────┘
                                    │ HTTP 127.0.0.1:8080
                                    │ Cookie 会话 + CSRF
┌───────────────────────────────────▼──────────────────────────┐
│ dst-panel            用户 dstpanel，无特权                    │
│  · 认证/会话/限流/审计                                         │
│  · 页面渲染、作业编排、SSE 推送                                │
│  · 只读系统信息：systemctl show、journalctl（systemd-journal 组）│
│  · 不直接读写 /var/lib/dst、/etc/dst、/var/backups/dst         │
└───────────────┬──────────────────────────────┬───────────────┘
                │ sudo -n（仅固定动作）          │ journalctl -f
┌───────────────▼───────────────┐   ┌──────────▼───────────────┐
│ dst-panel-helper   root        │   │ journald                  │
│  · 动作枚举 + 参数白名单        │   │  dst@Master / dst@Caves   │
│  · INI/Lua 校验、原子写、属主   │   └──────────────────────────┘
│  · 调 /usr/local/bin/dst 执行   │
│  · 备份列举/下载暂存/恢复       │
│  · 控制台 FIFO 写入             │
└───────────────┬───────────────┘
                │ 固定参数
┌───────────────▼──────────────────────────────────────────────┐
│ 现有资产（保持不变）                                          │
│  /usr/local/bin/dst → /opt/dst/dst.sh                         │
│  dst.target、dst@Master.service、dst@Caves.service            │
│  /etc/dst/dst.conf、/var/lib/dst/…、/var/backups/dst          │
└──────────────────────────────────────────────────────────────┘
```

### 为什么不是"面板直接以 root 跑"

面板一挂公网就是 root 远程执行入口。拆成 `dstpanel`（无特权）+ root helper（动作枚举）后：Web 层被攻破，攻击者最多触发 helper 允许的那十几个动作，拿不到任意命令；helper 本身很小、可逐行审计、可单独测试。

### 为什么 helper 还要调 `dst.sh`

`dst.sh` 里的停止、备份、更新流程（尤其 100 秒优雅退出、失败保持停服）已被 `tests/smoke.sh` 覆盖。helper 复用它，避免出现"面板的停服逻辑"和"命令行的停服逻辑"两套行为。helper 只做三件 `dst.sh` 不会做的事：结构化的只读查询、受控文件写入、控制台 FIFO 写入。

### 为什么不用 WebSocket / React / 数据库

- 日志和作业进度都是单向推送：**SSE** 足够，且天然支持断线重连（`Last-Event-ID`），反代配置更简单。
- 页面是"表格 + 表单 + 日志"，htmx 的服务端渲染足够，省掉 npm 工具链和前后端两套状态；单二进制 `embed` 静态资源即可。
- 会话用签名 Cookie + 内存表，账号写在 `/etc/dst-panel/users.json`，审计写 JSONL，**v1 不需要数据库**。将来要多用户/权限再上 SQLite（`modernc.org/sqlite`，纯 Go 免 CGO）。

---

## 4. 权限与安全模型

### 4.1 账号与目录

| 对象 | 属主/权限 | 说明 |
| --- | --- | --- |
| 面板进程 | `dstpanel:dstpanel`，home `/var/lib/dst-panel` | `nologin` 系统用户，无 sudo 之外的权限 |
| 附加组 | `systemd-journal` | 只读日志；不加 `dst` 组，避免读到令牌 |
| `/etc/dst-panel/` | `root:dstpanel 0750` | `panel.toml`、`users.json`、`secret` 均 `0640` |
| `/var/lib/dst-panel/` | `dstpanel 0750` | 状态、审计、下载暂存 |
| `/opt/dst-panel/` | `root:root` | `dst-panel`、`dst-panel-helper` 均 `0755`，helper 靠 sudoers 限定 |
| 游戏目录 | 不变 | 面板用户没有任何直接路径权限 |

### 4.2 helper：唯一的提权面

- 只接受**动作名**作为 argv，参数一律走 stdin 的 JSON；`sudoers` 逐动作钉死命令行，连动作都换不了：

```sudoers
Cmnd_Alias DST_PANEL_OPS = \
  /opt/dst-panel/dst-panel-helper status, \
  /opt/dst-panel/dst-panel-helper start, \
  /opt/dst-panel/dst-panel-helper stop, \
  /opt/dst-panel/dst-panel-helper restart, \
  /opt/dst-panel/dst-panel-helper check, \
  /opt/dst-panel/dst-panel-helper enable, \
  /opt/dst-panel/dst-panel-helper disable, \
  /opt/dst-panel/dst-panel-helper backup, \
  /opt/dst-panel/dst-panel-helper update, \
  /opt/dst-panel/dst-panel-helper config-read, \
  /opt/dst-panel/dst-panel-helper config-write, \
  /opt/dst-panel/dst-panel-helper token-write, \
  /opt/dst-panel/dst-panel-helper console, \
  /opt/dst-panel/dst-panel-helper backups-list, \
  /opt/dst-panel/dst-panel-helper backup-spool, \
  /opt/dst-panel/dst-panel-helper backup-restore
dstpanel ALL=(root) NOPASSWD: DST_PANEL_OPS
Defaults:dstpanel env_reset,secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
```

- helper 内部校验（缺一不可）：
  - 读 `/etc/dst/dst.conf` 取路径，**绝不接受客户端传路径**；
  - `CLUSTER_NAME` 匹配 `^[A-Za-z0-9_-]+$`（与 install.sh 同规则）；
  - 目标文件必须落在 `$DATA_DIR/DoNotStarveTogether/$CLUSTER_NAME/{cluster.ini,cluster_token.txt,Master/*,Caves/*}` 或 `$DATA_DIR/mods/` 白名单内；
  - 用 `O_NOFOLLOW` 打开父目录做 `openat`，防 `dst` 用户（游戏进程）预先放置符号链接把 root 写操作引到别处；
  - 单文件 ≤ 256 KiB，请求体 ≤ 1 MiB；
  - 原子写：同目录 `O_EXCL` 临时文件 → `fchown dst:dst` → `fchmod 0640`（token `0600`）→ `rename` → `fsync` 目录；
  - 写前自动把原文件复制到 `/var/lib/dst-panel/snapshots/`，失败可回滚。

### 4.3 Web 安全

| 项 | 方案 |
| --- | --- |
| 默认监听 | `127.0.0.1:8080`，不提供 `0.0.0.0` 配置项（要公网必须自己上反代，见下） |
| 密码 | Argon2id（`golang.org/x/crypto/argon2`），首次启动在 journal 打印一次性 setup token，`/setup` 建号后失效 |
| 会话 | 32 字节随机 ID，HttpOnly + SameSite=Strict + `Secure`（反代 TLS 时）；12 小时绝对过期 + 30 分钟空闲过期；改密/登出全部会话轮换密钥 |
| CSRF | 每会话派生 token，写操作要求 `X-CSRF-Token`，并校验 `Origin`/`Host` |
| 限流 | 登录 5 次/分钟/IP，控制台 30 次/分钟，全局 300 次/分钟；超限 429 + 审计 |
| 二次验证 | 控制台、恢复、更新、停服要求"sudo 模式"：重新输入密码，5 分钟内有效 |
| TLS | 提供 Caddy 示例：`dst.example.com { reverse_proxy 127.0.0.1:8080 }`，附 `header` 硬化；也可继续 `ssh -L 8080:127.0.0.1:8080` |
| 响应头 | `CSP: default-src 'self'`、`X-Frame-Options: DENY`、`Referrer-Policy: no-referrer`、`X-Content-Type-Options: nosniff` |
| 静态资源 | 全部 `embed`，不引 CDN，无外链脚本 |

### 4.4 敏感数据

- **令牌**：只写不读。接口只返回 `tokenPresent`、`tokenUpdatedAt`；替换走独立接口 + 二次验证；日志与审计中永不出现原文。
- **房间密码**：`cluster.ini` 内明文是游戏要求。界面默认 `******`，查看需二次验证并写审计；编辑走"替换"流程。
- **备份**：含令牌和密码。`/var/backups/dst` 保持 `0700 root`；下载由 helper 复制到 `/var/lib/dst-panel/spool/`（`0700 dstpanel`），HTTP 流式发送后立即删除；下载行为审计。
- **日志**：可能含玩家 kuId/IP。页面仅登录可见，支持关键词脱敏高亮；导出需二次验证。
- **控制台**：本质是服务器上下文里的任意 Lua 求值（`RunScript` 一类），等同高权限。默认要求 sudo 模式，逐条审计，长度 ≤ 512 字节，禁止 CR/LF 注入多条。

### 4.5 审计

`/var/lib/dst-panel/audit.jsonl`，追加写、单行 JSON：
`{ts, actor, ip, action, target, args(脱敏), result, durationMs, jobId}`
覆盖登录/失败登录、所有状态变更、配置写入（含 diff 摘要）、控制台命令、备份下载/恢复。页面提供筛选与导出。

### 4.6 破坏性操作的确认梯度

| 级别 | 操作 | 确认方式 |
| --- | --- | --- |
| 普通 | start / check / backup | 单击 |
| 警告 | stop / restart / enable / disable | 弹窗说明影响 + 确认 |
| 危险 | update / 恢复备份 / 覆盖配置 / 改端口 | 输入房间名或 `RESTORE` 才能提交 + 二次验证 |
| 禁止 | 任意 shell、读 token、改 `/etc/dst/dst.conf` 路径 | 不提供接口 |

---

## 5. 功能范围与优先级

| # | 能力 | 页面 | 优先级 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | 登录 / 改密 / 登出 | 登录 | P0 | setup token、Argon2id、会话 |
| 2 | 总览：房间信息、两分片状态、运行时长、内存/CPU、磁盘、令牌状态、最近备份 | 仪表盘 | P0 | 3 秒轮询片段 |
| 3 | start / stop / restart / check / enable / disable | 仪表盘、控制 | P0 | 异步作业 + 实时输出 |
| 4 | 实时日志（跟随、暂停、级别过滤、关键词、下载） | 日志 | P0 | journald SSE，游标续传 |
| 5 | 控制台：单行命令、快捷按钮（保存、玩家列表、公告） | 控制台 | P1 | FIFO，需 sudo 模式，审计 |
| 6 | `cluster.ini` 表单/原文双模编辑 + 差异预览 | 配置 | P1 | 校验键值域，写前快照 |
| 7 | `Master/Caves server.ini`（端口、分片、Steam 端口） | 配置 | P1 | 改端口提示停服 + 安全组 |
| 8 | 备份：列表、创建、下载、两阶段恢复、保留 N 份 | 备份 | P1 | 创建即停服，需明示 |
| 9 | 更新服务器（SteamCMD validate）+ 失败后"仍要启动" | 控制 | P1 | 长作业，输出流式 |
| 10 | Mod：下载列表增删、两世界启停、工坊元数据、本地 Mod 列表 | 模组 | P2 | `GetPublishedFileDetails` 免 key |
| 11 | `modoverrides.lua` / `leveldataoverride.lua` 原文编辑 + Lua 语法粗检 | 配置 | P2 | 世界设置仅对新世界生效，需提示 |
| 12 | 玩家：在线列表、踢人、聊天记录摘要 | 玩家 | P2 | `c_listallplayers()` 解析，best-effort |
| 13 | 服务日志告警/健康检查（失败重启计数、限流状态、`reset-failed`） | 仪表盘 | P2 | 读 `NRestarts`、`Result` |
| 14 | 定时备份 / 定时更新（systemd timer，面板只改配置） | 设置 | P3 | 面板不死才可靠 → 交给 systemd |
| 15 | 通知（Discord/Telegram/Webhook） | 设置 | P3 | 作业结束、异常退出 |
| 16 | 多房间切换 / 新建房间 | 设置 | P3 | 需停服，风险高，最后做 |
| 17 | 公开 API Token（给脚本用） | 设置 | P3 | 可选，默认关 |

---

## 6. 接口设计

### 6.1 HTTP API

所有响应 `application/json`（页面路由除外），错误统一 `{error:{code,message}}`。

| 方法 | 路径 | 作用 |
| --- | --- | --- |
| POST | `/api/login` | 登录，返回会话 Cookie |
| POST | `/api/logout` | 登出 |
| GET | `/api/me` | 当前用户、sudo 模式剩余时间 |
| POST | `/api/sudo` | 二次验证，开启 5 分钟 sudo 模式 |
| GET | `/api/overview` | 仪表盘聚合数据（见 6.7） |
| POST | `/api/actions/{action}` | `action ∈ start,stop,restart,check,backup,update,enable,disable`，返回 `202 {jobId}` |
| GET | `/api/jobs` | 当前/最近作业列表 |
| GET | `/api/jobs/{id}` | 作业快照（状态、开始时间、退出码、摘要） |
| GET | `/api/jobs/{id}/events` | SSE：`log` / `phase` / `done` 事件 |
| POST | `/api/jobs/{id}/cancel` | 仅对可取消作业有效（v1 无，预留） |
| GET | `/api/logs/{shard}` | 最近 N 行（`?lines=200&since=`） |
| GET | `/api/logs/{shard}/stream` | SSE 跟随，`Last-Event-ID` = journal 游标 |
| POST | `/api/console/{shard}` | 发送单行命令，`204` |
| GET | `/api/config` | 四个配置文件的模型 + 原文 + 版本号 |
| PUT | `/api/config/{file}` | 保存，需 `revision` 匹配；`file ∈ cluster, master, caves` |
| POST | `/api/token` | 替换令牌（只写） |
| GET | `/api/mods` | 下载列表、两世界启用状态、工坊元数据 |
| POST | `/api/mods/workshop` | 添加工坊 ID（校验数字、查元数据、写下载列表） |
| DELETE | `/api/mods/workshop/{id}` | 删除 ID（同时清理两个世界的启用项，需确认） |
| PUT | `/api/mods/enabled` | `{id, worlds:["Master","Caves"], enabled, config?}` |
| GET | `/api/backups` | 列表 + 总计大小 + 保留策略 |
| POST | `/api/backups` | 创建（内部调 `dst.sh backup`，含停服） |
| GET | `/api/backups/{name}/download` | 流式下载（先 spool） |
| DELETE | `/api/backups/{name}` | 删除（需二次验证） |
| POST | `/api/backups/{name}/restore` | 两阶段：`?confirm=<房间名>` |
| GET | `/api/players` | 在线玩家（可能为空/过期，带 `stale` 标记） |
| GET | `/api/audit` | 审计查询 |

### 6.2 作业模型（关键）

`start/stop/restart/backup/update` 都是**长任务**（停服最多 100 秒，更新可能数分钟），必须异步：

```json
{
  "id": "01J...",
  "action": "update",
  "status": "running",          // queued|running|succeeded|failed|interrupted
  "startedAt": "2026-11-08T21:00:00+08:00",
  "endedAt": null,
  "exitCode": null,
  "summary": "stopped; backup created; steamcmd validate running",
  "events": 42
}
```

- helper 以 `sudo -n /opt/dst-panel/dst-panel-helper update` 启动，stdout/stderr 逐行读入 ring buffer（保留最后 2000 行）并转发 SSE；
- 同一时间只允许一个作业（与 `/run/lock/dst-manager.lock` 对齐）；第二个请求直接 `409 busy`，并提示当前作业；
- 服务重启后，`running` 作业标记为 `interrupted`，页面给出"检查状态"引导，不假装成功；
- SSE 断线重连时先补发 ring buffer 里 `Last-Event-ID` 之后的行。

### 6.3 helper 动作表

| 动作 | stdin | stdout | 说明 |
| --- | --- | --- | --- |
| `status` | `{}` | JSON | 读 `systemctl show`、`dst.conf`、token 存在性、磁盘、版本 |
| `start/stop/restart/check/enable/disable/backup/update` | `{}` | 文本流 | 直接 `exec /usr/local/bin/dst <动作>`，继承输出与退出码 |
| `config-read` | `{"file":"cluster"}` | `{raw, model, revision, mtime}` | 只读，令牌只给状态 |
| `config-write` | `{"file":"cluster","raw":"...","revision":"..."}` | `{revision}` | 校验 + 快照 + 原子写；`revision` 不匹配返回 `409` |
| `token-write` | `{"token":"..."}` | `{}` | 单行、可打印 ASCII、长度 20–256 |
| `console` | `{"shard":"Master","line":"c_save()"}` | `{}` | `O_WRONLY|O_NONBLOCK` 打开 FIFO；无读者（服务停了）返回 `409` |
| `backups-list` | `{}` | JSON 数组 | 名称/大小/mtime/校验 |
| `backup-spool` | `{"name":"..."}` | `{path,token}` | 复制到 spool，返回一次性下载票据 |
| `backup-restore` | `{"name":"...","confirm":"Cluster_1"}` | 文本流 | 校验归档 → 解压到临时目录 → 停服检查 → 换入 → `chown` |

### 6.4 状态采集（`status` 返回）

```json
{
  "cluster": {
    "name": "Cluster_1", "displayName": "DST Server",
    "gameMode": "survival", "maxPlayers": 6, "pvp": false,
    "passwordSet": true, "shardEnabled": true, "cavesConfigured": true,
    "tokenPresent": true, "tokenUpdatedAt": "..."
  },
  "services": [
    {"shard":"Master","active":"active","subState":"running","pid":1234,
     "since":"2026-11-08T08:31:00+08:00","uptimeSec":3600,"memoryBytes":812000000,
     "cpuPercent":3.2,"restarts":1,"result":"success","unitState":"enabled"},
    {"shard":"Caves","active":"inactive","subState":"dead","pid":null,
     "since":"2026-11-08T07:00:00+08:00","uptimeSec":0,"memoryBytes":0,
     "cpuPercent":0,"restarts":0,"result":"success","unitState":"disabled"}
  ],
  "disk": {"dataBytes":1288490188, "backupBytes":3650722201, "freeBytes":21474836480},
  "backups": {"count":12, "newest":"dst-20261108-190000-ab12cd.tar.gz", "oldest":"dst-20261001-030000-ef34gh.tar.gz"},
  "server": {"buildId":"1234567", "version":"", "updatedAt":"2026-10-20T03:00:00+08:00"}
}
```

实现要点：`systemctl show dst@Master.service -p ActiveState,SubState,MainPID,ActiveEnterTimestamp,MemoryCurrent,CPUUsageNSec,NRestarts,Result,UnitFileState`，一次拿全，避免多次 fork；CPU 百分比由面板 5 秒采样差分计算，内存直接取 `MemoryCurrent`。

### 6.5 并发与顺序

- 面板层：全局单作业 + 每个房间单写者；
- helper 层：仍由 `dst.sh` 的 `flock` 兜底，面板只是提前拦住；
- 配置写入 vs 运行中的服务：允许热改（`cluster_name` 等），但 `server_port`、`shard_enabled`、`cluster_key`、`master_ip` 等触发"必须停服"标记，界面禁止在运行时保存。

---

## 7. 文件与目录布局

### 服务器侧（新增）

```text
/opt/dst-panel/dst-panel                 # 单二进制（嵌入静态资源）
/opt/dst-panel/dst-panel-helper          # root helper
/etc/dst-panel/panel.toml                # 监听地址、超时、保留策略
/etc/dst-panel/users.json                # 用户名、argon2id hash、TOTP 密钥
/etc/dst-panel/secret                    # 会话签名密钥（32B，首次生成）
/etc/sudoers.d/dst-panel                 # 4.2 的规则
/etc/systemd/system/dst-panel.service
/var/lib/dst-panel/audit.jsonl
/var/lib/dst-panel/snapshots/            # 配置写入前快照（保留 50 份）
/var/lib/dst-panel/spool/                # 备份下载暂存（用完即删）
/var/lib/dst-panel/state.json            # 作业历史、玩家缓存
```

### 仓库侧（新增，不动现有文件）

```text
panel/
  go.mod  go.sum
  cmd/dst-panel/main.go
  cmd/dst-panel-helper/main.go
  internal/api/          routes.go dashboard.go actions.go logs.go console.go
                         configs.go mods.go backups.go auth.go audit.go sse.go
  internal/auth/         argon2.go session.go csrf.go ratelimit.go
  internal/privileged/   client.go (sudo 调用 + 超时 + 输出流)
  internal/dst/          ini.go lua.go cluster.go mods.go journal.go
  internal/jobs/         manager.go ringbuf.go
  internal/store/        users.go state.go audit.go
  web/templates/*.html   layout, dashboard, logs, config, mods, backups, console, login
  web/static/app.css app.js (htmx.min.js 本地)
  deploy/dst-panel.service sudoers Caddyfile install-panel.sh
  docs/PANEL_PLAN.md
```

### 安装方式

`install-panel.sh`（root）：建 `dstpanel` 用户 → 装两个二进制 → 写 sudoers/unit → `daemon-reload` → 启动 → 打印 `http://127.0.0.1:8080` 和一次性 setup token。
不修改 `install.sh`；可选后续加 `install.sh --with-panel` 一键联动。

---

## 8. 页面设计

统一框架：左侧导航（仪表盘 / 控制 / 日志 / 控制台 / 配置 / 模组 / 备份 / 设置），顶部状态条（`Master ● 运行中 12:31`、`Caves ○ 未启用`、当前作业进度）。

### 8.1 仪表盘

```
┌ 房间 ─────────────────────────────┐ ┌ 快捷操作 ──────────┐
│ DST Server · 生存 · 6 人 · 有密码  │ │ [启动] [停止] [重启]│
│ Cluster_1                          │ │ [备份] [更新]       │
├ 分片 ─────────────────────────────┤ └────────────────────┘
│ Master  ● active  PID 1234  12:31  │ ┌ 资源 ──────────────┐
│   内存 812 MB  CPU 3.2%  重启 1    │ │ CPU ▁▂▃▅▂  磁盘 42% │
│ Caves   ○ inactive（已配置未启动）  │ │ 存档 1.2G 备份 3.4G │
├ 健康 ─────────────────────────────┤ └────────────────────┘
│ 令牌 ✅ 2026-10-01 更新             │
│ 最近备份 ✅ 2 小时前  / 自动策略 关 │
│ 版本 build 1234567                 │
└───────────────────────────────────┘
```

轮询 `/api/overview`（htmx `hx-trigger="every 3s"`），SSE 仅用于日志与作业。

### 8.2 日志

- 分片切换（Master/Caves），行数 200/500/2000，跟随/暂停，`ERROR|WARNING` 过滤，关键词高亮；
- 自动滚动到底部，暂停时显示"已暂停，N 条新日志"；
- 每条带时间戳与 journal 游标，可"从此刻开始复制"；
- 失败排查模板：底部固定"常见原因"折叠（令牌为空、端口未放行、mod Lua 报错）。

### 8.3 控制台

- 输入框 + 历史命令（↑/↓，仅本浏览器 `localStorage`），发送后从日志流回显结果（DST 控制台无 RPC 返回，只能看日志）；
- 快捷按钮：`c_save()`、`c_listallplayers()`、`c_announce("...")`、`c_shutdown(true)`（后者与"停服"按钮重复，标注风险）；
- 顶部 sudo 模式倒计时；未开启时只读提示。

### 8.4 配置

- 四个 Tab：`cluster.ini` / `Master/server.ini` / `Caves/server.ini` / Lua 文件；
- 表单模式只暴露已知键（带说明、默认值、取值范围），其余键在"高级"里以原文呈现；
- 保存前显示 unified diff，标注影响：`需重启` / `需停服` / `仅新世界生效`；
- 冲突处理：`revision` 不匹配时提示"文件已被其他方式修改"，给"查看差异 / 覆盖 / 放弃"；
- 每次保存自动快照到 `/var/lib/dst-panel/snapshots/`，页面可一键回滚。

### 8.5 模组

- 三块：下载列表（工坊 ID + 名称 + 最后更新 + 大小）、世界启用矩阵（行=Mod，列=Master/Caves，开关）、本地 Mod 列表（目录名、`modinfo.lua` 版本）；
- 添加 ID 时后台查 `ISteamRemoteStorage/GetPublishedFileDetails`（免 API key，POST 表单，批量 ≤ 100），缓存 24 小时，失败不阻塞但显示"元数据未知"；
- 删除/mod 停用后提示"需下载或同步 → 执行重启"；提供"应用到两个世界"。
- 明确提示：`leveldataoverride.lua` 只影响**新生成**的世界；已有存档不重生成。

### 8.6 备份

- 表格：文件、时间、大小、含 Master/Caves、操作（下载/恢复/删除）；
- 顶部：总占用、保留策略（保留 N 份 / 保留 N 天）、"立即备份"；
- 创建前警告"将停服数秒"，恢复前要求输入房间名 + 二次验证，恢复期间禁用所有操作。

### 8.7 设置

- 账号：改密、TOTP、登出全部会话；
- 面板：监听地址（只读展示）、会话超时、审计保留；
- 游戏服务：开机自启（enable/disable）、`reset-failed`（限流恢复）、安装信息（路径/版本）；
- 危险区：删除旧备份、重建世界（v2，默认不提供）。

---

## 9. 关键实现细节

### 9.1 停服/更新的进度体验

`stop` 可能花 100 秒（等 `c_shutdown` 保存），`update` 可能几分钟。作业页显示阶段条：
`停服 → 保存退出 → 备份 → SteamCMD 校验 → 恢复模组 → 启动 → 联网确认`。
阶段判断：解析 `dst.sh` 的标准输出（`Backup:`、`Updating server.`、`Start requested.`）与 `systemctl show` 状态，不猜时间。

### 9.2 日志读取

- 主来源：`journalctl -u dst@<shard>.service -o json --no-pager`，取 `__REALTIME_TIMESTAMP`、`PRIORITY`、`MESSAGE`、`_SYSTEMD_UNIT`；`-f` 跟随，`--after-cursor` 续传。
- 备选：若 journald 未持久化（重启丢历史），额外读 `<cluster>/<shard>/server_log.txt`（若存在）作为下载来源，只读最后 5 MB。
- 面板把 journal 行做 UTF-8 清洗、去掉 ANSI、限制单行 4 KiB，避免一个超长行撑爆 SSE。

### 9.3 控制台写入

helper 用 `open(path, O_WRONLY|O_NONBLOCK)`：服务运行时 `shard.sh` 持有 FIFO 读端，写不会阻塞；服务停止时 `ENXIO` → 返回 `409 服务未运行`。
写入前拒绝 `\r`/`\n`，追加单个 `\n`；回显统一从日志流取，不做假回显。

### 9.4 INI 读写

- 手写小解析器：保留注释、空行、键顺序、未知键；模型 = 有序 `[{section, key, value, lineNo}]`；
- 表单只改已知键，写回时按行号 patch，**不做整文件重新序列化**，避免吃掉注释和自定义键；
- 校验表（示例）：`max_players 1–64`、`game_mode ∈ {survival,endless,wilderness}`、`pvp ∈ {true,false}`、`cluster_password` 允许空、`server_port 1–65535`、`master_port 1–65535`、`cluster_key ^[0-9a-f-]{32,64}$`、`shard_enabled ∈ {true,false}`；
- 值里禁止换行和 `;`/`#` 起始（防注入新键）。

### 9.5 Lua 文件

v1 不做完整解析：引号配对、`{}`/`()`/`[]` 平衡、`return {` 开头、拒绝 `os.execute`/`io.`/`require` 以外的可疑调用（仅警告）。若服务器装了 `lua5.1`/`luac`，用 `luac -p` 做真语法检查（存在即用，缺失降级）。
写前快照 + 重启提示，足够安全。

### 9.6 Mod 元数据

```
POST https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/
itemcount=1&publishedfileids[0]=123456789
```
返回 `title`、`file_size`、`time_updated`、`preview_url`。无需 key；失败/超时 3 秒即降级为"仅 ID"。`preview_url` 由浏览器直连 Steam CDN，面板不代理图片（也可后续加代理避免泄露访问者 IP）。

### 9.7 玩家列表

发送 `c_listallplayers()` → journal 出现形如 `1: 玩家名 <kuId>` 的块 → 解析出名字与 kuId → 缓存 10 秒。
这是 best-effort：日志格式随版本变化，解析失败只显示"未知"，不阻塞其他功能。踢人用 `TheNet:Kick(kuId)`，需二次确认 + 审计。

### 9.8 版本与更新提示

读 `/opt/dst/server/steamapps/appmanifest_343050.acf` 的 `buildid`/`LastUpdated`（存在才显示）；"有新版"不主动联网查询，避免给服务器增加外部依赖，改为"最近一次更新于 X 天前"的提示。

### 9.9 磁盘

`statfs` 取可用空间；备份总大小扫目录（缓存 60 秒）；存档大小 `du` 可能慢，改用按目录递归 `stat` 并在后台 5 分钟刷新一次。

---

## 10. 实施阶段与验收

| 阶段 | 内容 | 产出 | 验收标准 | 预估 |
| --- | --- | --- | --- | --- |
| P0 骨架 | Go module、路由、模板、认证、helper 协议、fake 后端、CI 脚本 | 能登录、能跑 `status` | `go test ./...` 全绿；`curl` 能拿到 overview；helper 单测覆盖路径逃逸/符号链接/超长输入 | 0.5–1 人日 |
| P1 MVP | 仪表盘、start/stop/restart/check、日志 SSE、作业流 | 可用面板 | 在 22.04 真机上完成：启动→看日志→停服（100 秒内保存退出）→再启动；作业失败可见原因 | 1.5–2 人日 |
| P2 配置与备份 | 配置读写+diff+快照、令牌替换、备份列表/创建/下载/恢复、更新 | 覆盖 README 全部日常操作 | 改端口→重启生效；改坏 Lua→拒绝保存；备份下载可解压；恢复后世界可进 | 2–3 人日 |
| P3 模组与控制台 | Mod 增删启停、元数据、控制台、玩家、health | 完整面板 | 加工坊 ID→两世界启用→重启后游戏内可见；控制台 `c_listallplayers()` 能出玩家 | 1.5–2 人日 |
| P4 打磨 | TOTP、审计页、定时任务、通知、Caddy 示例、安装脚本、文档 | 可交付 | 断网/重启面板后状态正确；审计可追溯每个动作；安装脚本在干净 22.04 一次通过 | 1–1.5 人日 |

合计约 **7–10 人日**（含真机联调）。可先做 P0+P1 给你试用，再按反馈推进 P2。

---

## 11. 测试策略

1. **单元测试（Windows 上可跑）**：INI 解析/写回、Lua 粗检、路径白名单、revision 冲突、限流、会话签名、作业状态机、日志解析（含畸形行）。helper 的 unix 相关代码用 `//go:build linux` 隔离，纯逻辑抽到无平台依赖的包。
2. **helper 集成测试（Linux 容器/VM）**：临时目录 + 假 `dst` 脚本，验证原子写、属主、符号链接攻击被拒、FIFO 无读者返回 409。
3. **冒烟脚本** `tests/panel-smoke.sh`：与现有 `tests/smoke.sh` 一样只用临时目录和替身命令，覆盖登录→动作→状态→审计，不需要 root/Steam/systemd。
4. **真机验收清单**：Ubuntu 22.04 全新机器 + 现有 `install.sh` → 装面板 → 逐项走 P1/P2 验收；重点验证停服 100 秒、更新失败留在停服、恢复备份后 `dst check` 通过。
5. **安全自查**：`gosec`、`govulncheck`、手工检查 CSRF/越权/路径穿越/日志注入/SSE 断线。

---

## 12. 风险与对策

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| 面板被公网暴露 | 等于把服务器管理权交出去 | 默认只听 127.0.0.1；文档强调 SSH 隧道；TLS 反代 + TOTP + 限流 |
| 控制台 = 高权限 Lua | 可改服务器行为甚至破坏存档 | 默认关闭/需 sudo 模式；逐条审计；文档写明风险；可配置禁用 |
| 备份/恢复路径被符号链接利用 | root 写任意文件 | `O_NOFOLLOW` + `openat` + 目标白名单 + 归档内容校验（拒绝绝对路径/`..`） |
| 停服耗时被误判为卡死 | 用户重复点击 | 作业串行 + 明确阶段条 + `409 busy`；按钮禁用直到作业结束 |
| 配置写坏导致起不来 | 服务中断 | 写前快照、diff 预览、语法校验、失败一键回滚、备份先行 |
| 更新失败留在停服 | 房间离线 | 失败页显著提示 + "仍然启动" + 原因分类（网络/磁盘/权限/令牌） |
| journald 未持久化 | 重启后日志丢失 | 文档建议 `Storage=persistent`；面板提供 `server_log.txt` 兜底下载 |
| 与 `dst.sh` 行为漂移 | 面板和命令行不一致 | 状态变更只调 `dst.sh`，不复制逻辑；把"面板调用的命令"写进测试断言 |
| 面板自身升级中断 | 管理入口暂时不可用 | 游戏服务与面板解耦；升级只替换二进制并 `restart`；保留上一版本 |

---

## 13. 待确认决策（按推荐值即可开工）

1. **技术栈**：推荐 **Go 单二进制 + Go 模板 + htmx + 预编译 CSS**（服务器零运行时依赖，Windows 上交叉编译）。备选：Go API + Vue3/Element Plus（更好看的 SPA，但需要 npm 构建链）；Python/FastAPI（改起来直观，服务器要 venv）。
2. **访问方式**：推荐默认 `127.0.0.1:8080` + SSH 隧道，另附 Caddy TLS 示例。是否需要我把 Caddy 方案也做成安装脚本的一部分？
3. **v1 范围**：推荐只做"当前房间"（P0–P3），多房间/新建世界放到 v2。是否同意？
4. **是否允许改动现有脚本**：推荐**零侵入**（不改 `dst.sh`/`install.sh`），所有状态变更通过调用它们完成。若你希望加 `dst.sh status --json` 之类，我也可以做成可选补丁。
5. **控制台默认状态**：推荐"登录后仍需二次验证才能发命令"，并且可在设置里彻底禁用。是否接受？
6. **部署机器**：面板和游戏同机（推荐），还是想放另一台机器远程管理？后者会显著增加攻击面和复杂度，v1 不建议。

---

## 附：一句话总结

在现有 `dst.sh` 之上加一层**无特权 Web 前端 + 固定动作的 root helper**，用 SSE 把长任务和日志变可见，把"停服/备份/更新"这些危险操作变成有确认、有阶段、有审计的按钮；默认只在本机回环上跑，通过 SSH 隧道或 TLS 反代访问。
