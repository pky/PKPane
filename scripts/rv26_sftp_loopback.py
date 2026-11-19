#!/usr/bin/env python3
"""既存設定に触れず専用一時設定の非root sshdだけを管理する。"""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time


def root_path(root_pointer_path=None):
    pointer = Path(root_pointer_path or "/private/tmp/pkpane-rv26-sftp-wire-root.txt")
    requested_root = Path(pointer.read_text().strip())
    if requested_root.is_symlink():
        raise RuntimeError("専用一時SFTPルートのsymlinkは利用できません")
    root = requested_root.resolve()
    allowed_prefixes = ("pkpane-rv26-sftp-wire-", "pkpane-rv26-sftp-jump-")
    if root.parent != Path("/private/tmp") or not root.name.startswith(allowed_prefixes):
        raise RuntimeError("専用一時SFTP以外は利用できません")
    if not root.is_dir() or root.stat().st_uid != os.getuid() or root.stat().st_mode & 0o777 != 0o700:
        raise RuntimeError("専用一時SFTPの所有者または権限が不正です")
    # /private/tmp親をStrictModesが拒否するため、専用設定ではこちらで私有領域を検査する。
    required_names = ["host", "ed25519", "authorized_keys", "sshd_config", "configuration.json"]
    if root.name.startswith("pkpane-rv26-sftp-wire-"):
        required_names += ["rsa", "encrypted-ed25519"]
    for name in required_names:
        path = root / name
        if path.is_symlink() or not path.is_file() or path.stat().st_uid != os.getuid() or path.stat().st_mode & 0o777 != 0o600:
            raise RuntimeError("専用一時SFTPの鍵・設定の所有者または権限が不正です")
    return root


def start(root_pointer_path=None):
    root = root_path(root_pointer_path)
    if os.getuid() == 0:
        raise RuntimeError("非root試験でrootは使用できません")
    configuration = json.loads((root / "configuration.json").read_text())
    with (root / "server.log").open("a") as output:
        process = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(root / "sshd_config")], stdin=subprocess.DEVNULL, stdout=output, stderr=output)
    for _ in range(100):
        if process.poll() is not None:
            raise RuntimeError("非root専用sshdの起動に失敗しました（私有ログを分類して確認してください）")
        try:
            with socket.create_connection(("127.0.0.1", configuration["port"]), timeout=0.1):
                configuration["pid"] = process.pid
                with (root / "configuration.json").open("w") as output:
                    json.dump(configuration, output)
                print(root / "configuration.json")
                return
        except OSError:
            time.sleep(0.05)
    process.terminate()
    raise RuntimeError("非root専用sshdの起動が期限を超えました")


def stop(root_pointer_path=None):
    root = root_path(root_pointer_path)
    pid = json.loads((root / "configuration.json").read_text())["pid"]
    command = subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "command="], text=True).strip()
    if "/usr/sbin/sshd" not in command or str(root / "sshd_config") not in command:
        raise RuntimeError("一時sshdの所有プロセスを確認できません")
    os.kill(pid, signal.SIGTERM)
    for _ in range(100):
        status = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "pid="], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if status.returncode != 0:
            break
        time.sleep(0.05)
    else:
        raise RuntimeError("専用sshdの終了を確認できません")
    print("非root専用sshdを停止しました。")


if __name__ == "__main__":
    root_pointer_path = sys.argv[2] if len(sys.argv) > 2 else None
    if len(sys.argv) > 3:
        raise RuntimeError("ルート指定ファイルは1件だけ指定できます")
    if sys.argv[1] == "start":
        start(root_pointer_path)
    elif sys.argv[1] == "stop":
        stop(root_pointer_path)
    else:
        raise RuntimeError("未対応の検証操作です")
