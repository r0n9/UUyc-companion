#!/usr/bin/env python3
"""Run on the controlling Mac: reconnect one device after its old session closes."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time


class ReconnectError(Exception):
    pass


def run_cli(cli, arguments, timeout):
    try:
        result = subprocess.run([str(cli), *arguments], capture_output=True, text=True,
                                timeout=timeout, check=False)
        value = json.loads(result.stdout)
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
        raise ReconnectError("无法读取 UU CLI 的有效响应，已停止操作。") from error
    if result.returncode != 0 or not isinstance(value, dict) or value.get("success") is not True:
        raise ReconnectError("UU CLI 报告失败，已停止操作。")
    return value


def connected_ids(value):
    data = value.get("data")
    if not isinstance(data, dict) or not isinstance(data.get("connections"), list):
        raise ReconnectError("无法识别连接状态格式，不能确认旧连接已关闭。")
    rows = data["connections"]
    if data.get("total") != len(rows) or data.get("hasActiveConnections") is not bool(rows):
        raise ReconnectError("连接状态不一致，不能确认旧连接已关闭。")
    identifiers = set()
    for row in rows:
        if not isinstance(row, dict):
            raise ReconnectError("无法识别连接记录。")
        # 不把连接自身的 id 当成远程设备 ID；未知版本的结构拒绝操作。
        values = [row[key] for key in ("deviceId", "deviceID", "device_id") if key in row]
        if not values or any(isinstance(item, bool) or not isinstance(item, (str, int)) for item in values):
            raise ReconnectError("连接记录缺少可识别的设备 ID，请手动重连。")
        ids = {str(item) for item in values}
        if len(ids) != 1 or not next(iter(ids)):
            raise ReconnectError("连接记录的设备 ID 不一致，请手动重连。")
        identifiers.update(ids)
    return identifiers


def reconnect(cli, device, call=run_cli, clock=time.monotonic, sleep=time.sleep):
    if device not in connected_ids(call(cli, ["device", "status"], 2)):
        raise ReconnectError("目标设备当前没有连接，未执行断开或重连。")
    # 给伴侣的 15 秒窗口留出余量；所有子进程调用共用这一截止时间。
    deadline = clock() + 10

    def invoke(arguments):
        remaining = deadline - clock()
        if remaining <= 0:
            raise ReconnectError("重连等待已超时，请手动连接；未继续发起连接请求。")
        return call(cli, arguments, min(2, remaining))

    invoke(["device", "disconnect", device])
    while device in connected_ids(invoke(["device", "status"])):
        sleep(min(0.1, max(0, deadline - clock())))
    sleep(0.2)
    invoke(["device", "connect", device])


def main():
    parser = argparse.ArgumentParser(description="在控制端 Mac 上恢复远程声音：先点击被控端伴侣的恢复按钮，再重连指定设备。")
    parser.add_argument("--device", required=True, help="目标 Mac 的设备 ID；不会断开其他设备")
    parser.add_argument("--cli", type=Path, default=Path("/Applications/UURemote.app/Contents/Helpers/uuyc-cli"))
    parser.add_argument("--ready", action="store_true", help="已开启被控端的 15 秒重连窗口，跳过提示")
    arguments = parser.parse_args()
    device = arguments.device.strip()
    if not device or device.startswith("-"):
        parser.error("必须提供明确的目标设备 ID")
    try:
        if device not in connected_ids(run_cli(arguments.cli, ["device", "status"], 2)):
            raise ReconnectError("目标设备当前没有连接，未执行断开或重连。")
        if not arguments.ready:
            input("请在被控端伴侣点击「恢复远程声音」，然后立即回到这里按回车：")
        reconnect(arguments.cli, device)
        print("已确认旧连接关闭并提交一次重连请求，请在控制端确认画面和声音。")
    except (ReconnectError, EOFError, KeyboardInterrupt) as error:
        print(str(error) or "操作已取消。", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
