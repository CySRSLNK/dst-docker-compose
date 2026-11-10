#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
TransferLinux.py —— 为 dst-docker-compose 这套 Linux 部署生成 mod 需要的 .dyn 文件。

背景
----
mod 里每个皮肤 build 名都带前缀 ms_zhnkc9_gmail_com_，而 DST 引擎是按 build 名去
找 anim/dynamic/<build>.dyn 的，原版目录里只有不带前缀的版本，所以必须把原版 .dyn
复制一份、改成带前缀的名字。mod 自带的 scripts/init.lua 里那段 transferInternal()
用的 io.open(..., "rw") 是非法模式，运行期必崩，所以正确做法是离线生成、随包发布。

本脚本就是"离线生成"这一步，针对 docker-compose 部署定制：
  - 直接从 <mod>/scripts/init.lua 的 transfer_set 里读名字，不需要 filter.txt；
  - 默认目录就是本脚本旁边的 Local_Collection_Skins；
  - 支持 --docker，生成后自动 docker cp 进容器（compose 里那个 mod 目录是
    named volume，宿主机改动不会自动同步，见 README 说明）。

用法
----
    # 1) 在宿主机上生成，源目录自动探测本机 Steam 客户端
    python3 TransferLinux.py

    # 2) 只检查缺哪些，不写文件
    python3 TransferLinux.py --check

    # 3) 源目录手动指定（例如从 Windows 客户端拷过来的 data/anim/dynamic）
    python3 TransferLinux.py --src /mnt/dst-client/data/anim/dynamic

    # 4) 生成后直接同步进运行中的容器
    python3 TransferLinux.py --docker dst-server

    # 5) 在容器内部跑（镜像里没有 python，一般用不到）
    docker exec -it dst-server python3 /root/transfer/TransferLinux.py \
        --mod /root/dontstarvetogether_dedicated_server/mods/Local_Collection_Skins

退出码
------
    0  全部成功 / 检查通过
    1  有缺失或失败（加了 --strict；--check 默认就是严格模式）
    2  参数或环境错误
"""

import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# ---------------------------------------------------------------- 常量

PREFIX = "ms_zhnkc9_gmail_com_"
MOD_NAME = "Local_Collection_Skins"

CONTAINER_SERVER_DIR = "/root/dontstarvetogether_dedicated_server"
CONTAINER_MODS_DIR = CONTAINER_SERVER_DIR + "/mods"
CONTAINER_ANIM_DIR = CONTAINER_SERVER_DIR + "/data/anim/dynamic"

# transfer_set 里的条目形如：
#   "anim/dynamic/|abigail_ancient|ms_zhnkc9_gmail_com_abigail_ancient|.dyn"
ENTRY_RE = re.compile(r'"anim/dynamic/\|([^|"]+)\|([^|"]+)\|([^"|]*)"')

STREAM_CANDIDATES_LINUX = [
    "~/.steam/steam/steamapps/common/Don't Starve Together/data/anim/dynamic",
    "~/.local/share/Steam/steamapps/common/Don't Starve Together/data/anim/dynamic",
    "~/.steam/root/steamapps/common/Don't Starve Together/data/anim/dynamic",
    "~/snap/steam/common/.local/share/Steam/steamapps/common/Don't Starve Together/data/anim/dynamic",
    "~/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/common/Don't Starve Together/data/anim/dynamic",
]


def log(msg=""):
    print(msg, flush=True)


def die(msg, code=2):
    print(f"错误：{msg}", file=sys.stderr, flush=True)
    raise SystemExit(code)


def write_report(path_str, items):
    try:
        p = Path(path_str).expanduser()
        p.write_text("\n".join(items) + "\n", encoding="utf-8")
        log(f"完整缺失名单：{p}")
    except OSError as e:
        log(f"警告：写报告文件失败（{path_str}）：{e}")


def inside_container() -> bool:
    return Path("/.dockerenv").exists()


def script_dir() -> Path:
    return Path(__file__).resolve().parent


# ---------------------------------------------------------------- 名字来源


def names_from_init_lua(mod_dir: Path):
    """从 mod 的 scripts/init.lua 解析 transfer_set，返回 [(origin, dst_name), ...]"""
    init_lua = mod_dir / "scripts" / "init.lua"
    if not init_lua.is_file():
        die(f"找不到 {init_lua}，请用 --mod 指定 mod 根目录")

    text = init_lua.read_text(encoding="utf-8", errors="replace")
    pairs, seen = [], set()
    for origin, dest, ext in ENTRY_RE.findall(text):
        name = dest + ext
        if name in seen:
            continue
        seen.add(name)
        pairs.append((origin, name))

    if not pairs:
        die(f"{init_lua} 里没有解析到 transfer_set 条目，文件结构可能变了")
    return pairs


def names_from_filter(filter_path: Path, prefix: str):
    """从纯名单文件读名字，目标名 = prefix + name + .dyn"""
    if not filter_path.is_file():
        die(f"过滤文件不存在：{filter_path}")
    pairs, seen = [], set()
    with filter_path.open("r", encoding="utf-8-sig", errors="replace") as f:
        for lineno, raw in enumerate(f, 1):
            name = raw.strip()
            if not name or name.startswith("#"):
                continue
            if "/" in name or "\\" in name or name.startswith("."):
                log(f"警告：第 {lineno} 行不是纯文件名，已跳过：{name!r}")
                continue
            dst = prefix + name + ".dyn"
            if dst in seen:
                continue
            seen.add(dst)
            pairs.append((name, dst))
    if not pairs:
        die(f"{filter_path} 里没有有效名字")
    return pairs


# ---------------------------------------------------------------- 源目录


def resolve_src(arg_src, container_anim: str):
    if arg_src:
        p = Path(arg_src).expanduser()
        if not p.is_dir():
            die(f"--src 指定的目录不存在：{p}")
        return p

    env = os.environ.get("DST_ANIM_DYNAMIC")
    if env:
        p = Path(env).expanduser()
        if p.is_dir():
            log(f"源目录来自环境变量 DST_ANIM_DYNAMIC：{p}")
            return p

    if inside_container():
        p = Path(container_anim)
        if p.is_dir():
            return p

    for cand in STREAM_CANDIDATES_LINUX:
        p = Path(cand).expanduser()
        if p.is_dir():
            log(f"自动探测到 Steam 客户端：{p}")
            return p

    die(
        "没找到游戏的 data/anim/dynamic。\n"
        "  专用服务器镜像里通常没有这个目录，请从装了客户端的机器上拷一份过来，然后用：\n"
        f"    {Path(sys.argv[0]).name} --src /path/to/data/anim/dynamic\n"
        "  也可以设置环境变量 DST_ANIM_DYNAMIC 指向它。"
    )


class SourceIndex:
    """精确匹配优先，命中不到再用大小写不敏感匹配（Linux 文件系统区分大小写）。"""

    def __init__(self, src: Path):
        self.src = src
        self._lower = None

    def _ci(self):
        if self._lower is None:
            self._lower = {}
            for p in self.src.iterdir():
                if p.is_file():
                    self._lower.setdefault(p.stem.lower(), []).append(p)
        return self._lower

    def find(self, origin: str):
        matches = [p for p in self.src.glob(glob.escape(origin) + ".*") if p.is_file()]
        if not matches:
            matches = [p for p in self._ci().get(origin.lower(), []) if p.is_file()]
        matches.sort(key=lambda p: (p.suffix.lower() != ".dyn", p.name.lower()))
        return matches


# ---------------------------------------------------------------- docker


def docker_available() -> bool:
    return shutil.which("docker") is not None


def docker_running(container: str) -> bool:
    try:
        out = subprocess.run(
            ["docker", "inspect", "-f", "{{.State.Running}}", container],
            capture_output=True,
            text=True,
        )
    except OSError:
        return False
    return out.returncode == 0 and out.stdout.strip() == "true"


def docker_mod_is_volume(container: str, container_mod: str):
    """返回 (是否成功, 挂载类型)。compose 里写成 'Local_Collection_Skins:/path' 时是 named volume，
    宿主机上的同名目录并不会被挂进去，必须 docker cp 或者改成 './Local_Collection_Skins:/path'。"""
    try:
        out = subprocess.run(
            ["docker", "inspect", "-f", "{{json .Mounts}}", container],
            capture_output=True,
            text=True,
        )
    except OSError:
        return False, None
    if out.returncode != 0:
        return False, None

    import json

    try:
        mounts = json.loads(out.stdout)
    except ValueError:
        return False, None

    # 找到容器内路径是 container_mod 或其一层的挂载
    for m in mounts:
        dest = (m.get("Destination") or "").rstrip("/")
        if dest == container_mod.rstrip("/") or container_mod.rstrip("/").startswith(dest + "/"):
            return True, m.get("Type")
    return True, None


def docker_sync(container: str, host_dir: Path, container_mod: str):
    remote = f"{container}:{container_mod}/anim/dynamic"
    log(f"同步到容器：{host_dir} -> {remote}")

    mk = subprocess.run(
        ["docker", "exec", container, "mkdir", "-p", f"{container_mod}/anim/dynamic"],
        capture_output=True,
        text=True,
    )
    if mk.returncode != 0:
        die(f"容器内创建目录失败：{mk.stderr.strip()}")

    cp = subprocess.run(
        ["docker", "cp", f"{host_dir}/.", remote],
        capture_output=True,
        text=True,
    )
    if cp.returncode != 0:
        die(f"docker cp 失败：{cp.stderr.strip()}")
    log("docker cp 完成")


# ---------------------------------------------------------------- 主流程


def main(argv=None) -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

    ap = argparse.ArgumentParser(
        description="离线生成 mod 需要的 .dyn（复制原版 anim/dynamic 下带前缀的副本）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--mod", help=f"mod 根目录（默认脚本旁边的 {MOD_NAME}）")
    ap.add_argument("--src", help="游戏 data/anim/dynamic 目录（默认自动探测）")
    ap.add_argument("--dst", help="目标 anim/dynamic 目录（默认 <mod>/anim/dynamic）")
    ap.add_argument("--filter", help="用纯名单文件代替 scripts/init.lua 的 transfer_set")
    ap.add_argument("--prefix", default=PREFIX, help=f"名单模式下的前缀（默认 {PREFIX}）")
    ap.add_argument("--check", action="store_true", help="只检查缺哪些文件，不复制")
    ap.add_argument("--force", action="store_true", help="目标已存在也重新复制")
    ap.add_argument("--dry-run", action="store_true", help="打印将要复制的文件，不落盘")
    ap.add_argument("--strict", action="store_true", help="有缺失或失败时返回退出码 1")
    ap.add_argument("--report", help="把缺失的 origin 名单写到文件")
    ap.add_argument("--mark-installed", action="store_true", help='确保 install.txt 内容为 "3"')
    ap.add_argument("--docker", nargs="?", const="dst-server", metavar="CONTAINER",
                    help="生成后 docker cp 进容器（默认 dst-server）")
    ap.add_argument("--container-mod", default=f"{CONTAINER_MODS_DIR}/{MOD_NAME}",
                    help="容器内 mod 目录")
    ap.add_argument("--container-anim", default=CONTAINER_ANIM_DIR,
                    help="容器内游戏 data/anim/dynamic（在容器内运行时作为默认源）")
    args = ap.parse_args(argv)

    mod_dir = Path(args.mod).expanduser() if args.mod else script_dir() / MOD_NAME
    if not mod_dir.is_dir():
        die(f"mod 目录不存在：{mod_dir}")

    if args.filter:
        pairs = names_from_filter(Path(args.filter).expanduser(), args.prefix)
        src_hint = "名单文件"
    else:
        pairs = names_from_init_lua(mod_dir)
        src_hint = "scripts/init.lua transfer_set"

    dst_dir = Path(args.dst).expanduser() if args.dst else mod_dir / "anim" / "dynamic"

    log("=" * 60)
    log(f"mod 目录   : {mod_dir}")
    log(f"目标目录   : {dst_dir}")
    log(f"名字来源   : {src_hint}（{len(pairs)} 条）")
    log(f"install.txt: {'需修正为 3' if args.mark_installed else '不处理'}")

    # ---------- 检查模式 ----------
    if args.check:
        missing = [origin for origin, name in pairs if not (dst_dir / name).is_file()]
        log("=" * 60)
        log(f"检查结果：应有 {len(pairs)} 个，缺失 {len(missing)} 个")
        for origin in missing[:30]:
            log(f"  - {origin}")
        if len(missing) > 30:
            log(f"  ... 另有 {len(missing) - 30} 个")
        if args.report and missing:
            write_report(args.report, missing)
        return 0 if not missing else 1

    src_dir = resolve_src(args.src, args.container_anim)
    log(f"源目录     : {src_dir}")

    if args.dry_run:
        log("模式       : dry-run")

    if not args.dry_run:
        try:
            dst_dir.mkdir(parents=True, exist_ok=True)
        except OSError as e:
            die(f"无法创建目标目录 {dst_dir}：{e}")

    index = SourceIndex(src_dir)
    copied, skipped_exist, missing, failed = 0, 0, [], []

    for origin, name in pairs:
        target = dst_dir / name
        if target.is_file() and not args.force:
            skipped_exist += 1
            continue

        matches = index.find(origin)
        if not matches:
            missing.append(origin)
            continue
        src_file = matches[0]

        if args.dry_run:
            log(f"[dry-run] {src_file.name} -> {name}")
            copied += 1
            continue

        try:
            shutil.copy2(src_file, target)
            if not target.is_file():
                raise OSError("复制后文件不存在")
            copied += 1
        except OSError as e:
            failed.append(f"{src_file.name} -> {name}：{e}")

    log("=" * 60)
    log(f"新增 {copied} 个，已存在跳过 {skipped_exist} 个，缺失 {len(missing)} 个，失败 {len(failed)} 个")

    if missing:
        log("以下名字在源目录里找不到（游戏版本差异，或该皮肤本版本没有 .dyn）：")
        for origin in missing[:30]:
            log(f"  - {origin}")
        if len(missing) > 30:
            log(f"  ... 另有 {len(missing) - 30} 个")
        if args.report:
            write_report(args.report, missing)

    if failed:
        log("复制失败：")
        for msg in failed[:20]:
            log(f"  - {msg}")

    # ---------- install.txt ----------
    if args.mark_installed and not args.dry_run:
        flag = mod_dir / "install.txt"
        try:
            flag.write_text("3", encoding="utf-8")
            log(f'已写入 {flag}（内容 "3"，跳过运行期的 transferInternal）')
        except OSError as e:
            log(f"警告：写入 {flag} 失败：{e}")

    # ---------- docker ----------
    if args.docker:
        if inside_container():
            log("检测到当前在容器内运行，跳过 --docker")
        elif not docker_available():
            die("找不到 docker 命令，无法同步进容器")
        elif not docker_running(args.docker):
            die(f"容器 {args.docker} 不存在或未运行")
        else:
            ok, mtype = docker_mod_is_volume(args.docker, args.container_mod)
            if ok and mtype == "volume":
                log("注意：容器里的 mod 目录是 named volume，宿主机改动不会自动同步，")
                log("      所以这里用 docker cp 推送；想直接改宿主机目录的话，把 compose 里的")
                log(f"      {MOD_NAME}:{args.container_mod} 改成 ./{MOD_NAME}:{args.container_mod}")
            docker_sync(args.docker, dst_dir, args.container_mod)

    # ---------- 退出码 ----------
    if (missing or failed) and (args.strict or args.mark_installed):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
