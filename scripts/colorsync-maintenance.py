#!/usr/bin/env python3
"""Explicit, backed-up maintenance of orphaned UUyc ColorSync records."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile
from urllib.parse import unquote, urlparse
import uuid

CACHE = Path("/Library/Caches/ColorSync/com.apple.colorsync.devices")
PROFILE_DIRECTORY = Path("/Library/ColorSync/Profiles/Displays")
NAME_PREFIXES = ("UUyc companion", "UUDisplay")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_file(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as source:
        metadata = os.fstat(source.fileno())
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError("只接受普通文件，不能处理链接或设备文件")
        return source.read(), metadata


def load_cache(raw):
    cache = plistlib.loads(raw)
    if not isinstance(cache, dict):
        raise ValueError("不支持的 ColorSync 缓存结构，停止处理")
    return cache


def owned_name(name):
    return isinstance(name, str) and any(
        name == prefix or name.startswith(prefix + " · ") for prefix in NAME_PREFIXES
    )


def owned_record(key, record):
    if not isinstance(key, str) or not key.startswith("Device.mntr.") or not isinstance(record, dict):
        return False
    try:
        uuid.UUID(key.removeprefix("Device.mntr."))
    except ValueError:
        return False
    descriptions = record.get("DeviceDescriptions")
    return isinstance(descriptions, dict) and bool(descriptions) and all(
        owned_name(name) for name in descriptions.values()
    )


def profile_urls(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "DeviceProfileURL":
                yield child
            else:
                yield from profile_urls(child)
    elif isinstance(value, list):
        for child in value:
            yield from profile_urls(child)


def missing_owned_profile(value, names, device_uuid):
    if not isinstance(value, str):
        return False
    if value.startswith("file:"):
        url = urlparse(value)
        if url.netloc not in ("", "localhost") or url.query or url.fragment:
            return False
        value = unquote(url.path)
    path = Path(value)
    if not path.is_absolute() or path.parent != PROFILE_DIRECTORY:
        return False
    if not any(path.name.casefold() == (name + "-" + device_uuid + ".icc").casefold() for name in names):
        return False
    try:
        # 包含链接在内的已有文件都保留；权限错误也不能当成文件缺失。
        path.lstat()
    except FileNotFoundError:
        return True
    except OSError:
        return False
    return False


def stale_records(cache, online_uuids):
    online_uuids = {value.upper() for value in online_uuids}
    result = []
    for key, record in cache.items():
        if not owned_record(key, record):
            continue
        device_uuid = key.removeprefix("Device.mntr.")
        if device_uuid.upper() in online_uuids:
            continue
        profiles = record.get("FactoryProfiles")
        if not isinstance(profiles, dict) or not list(profile_urls(profiles)):
            continue
        urls = list(profile_urls(record))
        names = set(record["DeviceDescriptions"].values())
        if urls and all(missing_owned_profile(url, names, device_uuid) for url in urls):
            result.append(key)
    return sorted(result)


def display_snapshot():
    script = Path(__file__).with_name("display-snapshot.swift")
    result = subprocess.run(["/usr/bin/swift", str(script)], check=True, capture_output=True, text=True, timeout=20)
    displays = json.loads(result.stdout)
    if not isinstance(displays, list):
        raise ValueError("显示器快照格式错误")
    for display in displays:
        uuid.UUID(display["uuid"])
        if not all(isinstance(display[key], int) for key in ("id", "vendor", "product", "serial")):
            raise ValueError("显示器快照不完整")
    return displays


def require_offline():
    displays = display_snapshot()
    if any(display["vendor"] == 0x5555 for display in displays):
        raise ValueError("本程序或探测工具的虚拟屏仍在线；请先断开并完全退出应用")
    return {display["uuid"] for display in displays}


def check_color_service(timeout):
    if not 0 < timeout <= 60:
        raise ValueError("查询超时须在 0 到 60 秒之间")
    script = Path(__file__).with_name("colorsync-query.swift")
    result = subprocess.run(["/usr/bin/swift", str(script)], check=True, capture_output=True, text=True, timeout=timeout)
    return json.loads(result.stdout)


def require_quiet():
    online = require_offline()
    result = subprocess.run(["/usr/bin/pgrep", "-f", r"(^|/)colorsync\.useragent(\s|$)"], capture_output=True, timeout=5)
    if result.returncode != 1:
        raise ValueError("colorsync.useragent 仍在运行或无法检查；停止用户颜色代理后再应用/回退")
    return online


def serialize(cache, original):
    format = plistlib.FMT_BINARY if original.startswith(b"bplist") else plistlib.FMT_XML
    return plistlib.dumps(cache, fmt=format, sort_keys=False)


def prepare(cache_path, output):
    online = require_offline()
    raw, metadata = read_file(cache_path)
    cache = load_cache(raw)
    removed = stale_records(cache, online)
    if not removed:
        raise ValueError("没有符合条件的失效记录，无需清理")
    cleaned = serialize({key: value for key, value in cache.items() if key not in removed}, raw)
    current, _ = read_file(cache_path)
    if current != raw:
        raise ValueError("缓存在检查期间发生变化，请重新生成预览")
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    manifest = {
        "version": 1, "cache": str(cache_path.absolute()), "removed": removed,
        "before_sha256": digest(raw), "after_sha256": digest(cleaned),
        "uid": metadata.st_uid, "gid": metadata.st_gid, "mode": stat.S_IMODE(metadata.st_mode),
    }
    for name, contents in (
        ("backup.plist", raw), ("cleaned.plist", cleaned),
        ("manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2).encode()),
    ):
        descriptor = os.open(output / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as file:
            file.write(contents)
            file.flush()
            os.fsync(file.fileno())
    return manifest


def read_plan(output):
    manifest_raw, _ = read_file(output / "manifest.json")
    manifest = json.loads(manifest_raw)
    if manifest.get("version") != 1:
        raise ValueError("不支持的清理预览版本")
    backup, _ = read_file(output / "backup.plist")
    cleaned, _ = read_file(output / "cleaned.plist")
    if digest(backup) != manifest["before_sha256"] or digest(cleaned) != manifest["after_sha256"]:
        raise ValueError("备份或预览文件发生变化，停止处理")
    original = load_cache(backup)
    expected = {key: value for key, value in original.items() if key not in manifest["removed"]}
    if load_cache(cleaned) != expected:
        raise ValueError("预览包含删除记录以外的修改，停止处理")
    return manifest, backup, cleaned


def replace_checked(path, expected, replacement, metadata):
    descriptor, temporary_name = tempfile.mkstemp(prefix=".uudisplay-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as file:
            file.write(replacement)
            file.flush()
            os.fchown(file.fileno(), metadata.st_uid, metadata.st_gid)
            os.fchmod(file.fileno(), stat.S_IMODE(metadata.st_mode))
            os.fsync(file.fileno())
        current, current_metadata = read_file(path)
        if current != expected or (current_metadata.st_dev, current_metadata.st_ino) != (metadata.st_dev, metadata.st_ino):
            raise ValueError("缓存发生变化，取消写入")
        os.replace(temporary_name, path)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)


def apply_plan(output, rollback=False):
    online = require_quiet()
    manifest, backup, cleaned = read_plan(output)
    path = Path(manifest["cache"])
    current, metadata = read_file(path)
    expected, replacement = (cleaned, backup) if rollback else (backup, cleaned)
    if current != expected:
        raise ValueError("缓存与预览不一致；拒绝覆盖新记录，请重新生成预览")
    if not rollback and stale_records(load_cache(backup), online) != manifest["removed"]:
        raise ValueError("在线状态或 ICC 文件发生变化，请重新生成预览")
    require_quiet()
    replace_checked(path, expected, replacement, metadata)
    return len(manifest["removed"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("audit", "prepare"):
        child = commands.add_parser(command)
        child.add_argument("--cache", type=Path, default=CACHE)
        if command == "prepare":
            child.add_argument("--output", type=Path, required=True)
    for command in ("apply", "rollback"):
        child = commands.add_parser(command)
        child.add_argument("--plan", type=Path, required=True)
    health = commands.add_parser("healthcheck")
    health.add_argument("--timeout", type=float, default=10)
    args = parser.parse_args()
    try:
        if args.command == "audit":
            displays = display_snapshot()
            raw, _ = read_file(args.cache)
            cache = load_cache(raw)
            owned = [key for key, value in cache.items() if owned_record(key, value)]
            stale = stale_records(cache, {display["uuid"] for display in displays})
            print(json.dumps({"owned_records": len(owned), "stale_records": len(stale), "stale_keys": stale,
                              "online_virtual_displays": [display for display in displays if display["vendor"] == 0x5555]},
                             ensure_ascii=False, indent=2))
        elif args.command == "prepare":
            manifest = prepare(args.cache, args.output)
            print(f"已备份并生成预览：{args.output}；候选删除 {len(manifest['removed'])} 条，系统缓存尚未修改。")
        elif args.command == "healthcheck":
            print(json.dumps(check_color_service(args.timeout), indent=2))
        else:
            manifest, _, _ = read_plan(args.plan)
            if Path(manifest["cache"]) != CACHE:
                raise ValueError("应用/回退仅允许处理标准 ColorSync 缓存路径")
            count = apply_plan(args.plan, rollback=args.command == "rollback")
            print(f"{'已回退' if args.command == 'rollback' else '已清理'} {count} 条记录；备份保留在 {args.plan}。")
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"停止处理：{error}\n")


if __name__ == "__main__":
    main()
