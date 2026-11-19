#!/usr/bin/env python3
"""承認済みstock FTPを一時領域・ループバックだけで動かす検証補助。"""
import hashlib
import json
import logging
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import tempfile
import time


def load(path):
    return json.loads(Path(path).read_text())


def serve(root):
    settings = load(root / "settings.json")
    sys.path.insert(0, settings["package"])
    from pyftpdlib.authorizers import DummyAuthorizer
    from pyftpdlib.handlers import FTPHandler
    from pyftpdlib.servers import FTPServer

    logging.disable(logging.CRITICAL)
    authorizer = DummyAuthorizer()
    authorizer.add_user(settings["username"], settings["password"], str(root / "fixture"), perm="elradfmwMT")
    FTPHandler.authorizer = authorizer
    server = FTPServer(("127.0.0.1", 0), FTPHandler)
    settings.update(host="127.0.0.1", port=server.socket.getsockname()[1], pid=os.getpid())
    config = root / "configuration.json"
    with config.open("x") as output:
        json.dump(settings, output)
    config.chmod(0o600)
    server.serve_forever(timeout=0.2)


def start():
    package_root = Path("/private/tmp/pkpane-rv26-stock-ftp-root.txt").read_text().strip()
    package_root = Path(package_root).resolve()
    if package_root.parent != Path("/private/tmp") or not package_root.name.startswith("pkpane-rv26-stock-ftp-"):
        raise RuntimeError("専用一時配布物以外は利用できません")
    expected = "4ba0642078792df63dd3b2e9c8f838f2a3ecf428c7518d5921c0530d53512acf"
    if hashlib.sha256((package_root / "pyftpdlib-2.2.0.tar.gz").read_bytes()).hexdigest() != expected:
        raise RuntimeError("公式配布物のSHA256が一致しません")
    root = Path(tempfile.mkdtemp(prefix="pkpane-rv26-ftp-wire-", dir="/private/tmp"))
    root.chmod(0o700)
    (root / "fixture").mkdir(mode=0o700)
    settings = dict(package=str(package_root / "pyftpdlib-2.2.0"), username=secrets.token_hex(16), password=secrets.token_hex(32))
    settings_path = root / "settings.json"
    with settings_path.open("x") as output:
        json.dump(settings, output)
    settings_path.chmod(0o600)
    with (root / "server.log").open("x") as output:
        process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "serve", str(root)], stdin=subprocess.DEVNULL, stdout=output, stderr=output)
    for _ in range(100):
        config = root / "configuration.json"
        if config.exists():
            print(config)
            return
        if process.poll() is not None:
            raise RuntimeError("隔離FTPの起動に失敗しました（秘密を含むログは表示しません）")
        time.sleep(0.05)
    process.terminate()
    raise RuntimeError("隔離FTP起動が期限を超えました")


def stop(config):
    path = Path(config).resolve()
    if path.name != "configuration.json" or path.parent.parent != Path("/private/tmp") or not path.parent.name.startswith("pkpane-rv26-ftp-wire-"):
        raise RuntimeError("専用一時FTP設定以外は停止できません")
    pid = load(path)["pid"]
    command = subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "command="], text=True).strip()
    if str(Path(__file__).resolve()) not in command or str(path.parent) not in command:
        raise RuntimeError("一時FTPの所有プロセスを確認できません")
    os.kill(pid, signal.SIGTERM)
    for _ in range(100):
        status = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "pid="], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if status.returncode != 0:
            break
        time.sleep(0.05)
    else:
        raise RuntimeError("隔離FTPの終了を確認できません")
    print("隔離FTPの専用プロセスを停止しました。")


if __name__ == "__main__":
    if sys.argv[1] == "start":
        start()
    elif sys.argv[1] == "serve":
        serve(Path(sys.argv[2]))
    elif sys.argv[1] == "stop":
        stop(sys.argv[2])
    else:
        raise RuntimeError("未対応の検証操作です")
