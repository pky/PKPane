#!/usr/bin/env python3
"""SFTP認証方式の行列テスト用に、認証構成の違うSSHサーバー群をDockerで起動・停止する。

start: 専用一時ルート(0700)に試験鍵と資格情報を生成し、docker compose でサーバー群を起動、
       全台の準備完了(SSHバナー受信)とホスト公開鍵の取得を待ってから configuration.json(0600)の
       パスを標準出力へ1行だけ出す。Dockerが無いときは終了コード3(呼び出し側はskip扱い)。
stop <configuration.json>: compose down と一時ルートの削除。
"""
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import sys
import time

COMPOSE_FILE = Path(__file__).resolve().parent / "sftp-auth-matrix" / "compose.yaml"
ROOT_PREFIX = "pkpane-rv26-sftp-matrix-"
PROJECT_PREFIX = "pkpane-rv26-matrix-"
USERNAME = "matrix"
FIXTURE_FILE_NAME = "read-only.txt"
READY_TIMEOUT_SECONDS = 60.0
NO_DOCKER_EXIT_CODE = 3

# サービス名 → コンテナ内でホスト公開鍵を1行出すコマンド
HOST_KEY_COMMANDS = {
    "password-only": ["cat", "/etc/ssh/ssh_host_ed25519_key.pub"],
    "keyboard-interactive-only": ["cat", "/etc/ssh/ssh_host_ed25519_key.pub"],
    "publickey-only": ["cat", "/etc/ssh/ssh_host_ed25519_key.pub"],
    "openssh-8": ["cat", "/etc/ssh/ssh_host_ed25519_key.pub"],
    "dropbear": [
        "sh",
        "-c",
        "dropbearkey -y -f /etc/dropbear/dropbear_ed25519_host_key | grep '^ssh-ed25519'",
    ],
}


ORBSTACK_BIN = Path("/Applications/OrbStack.app/Contents/MacOS/xbin")


def docker_executable():
    found = shutil.which("docker")
    if found:
        return found
    bundled = ORBSTACK_BIN / "docker"
    if os.access(bundled, os.X_OK):
        return str(bundled)
    return None


def compose_prefix(docker):
    """`docker compose` プラグインが未登録の環境(OrbStack の GUI 初期設定前)でも動くよう、
    プラグインが使えなければ同梱の docker-compose 実行ファイルへ切り替える。"""
    probe = subprocess.run(
        [docker, "compose", "version"], stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if probe.returncode == 0:
        return [docker, "compose"]
    candidates = [shutil.which("docker-compose"),
                  str(Path(os.path.realpath(docker)).parent / "docker-compose"),
                  str(ORBSTACK_BIN / "docker-compose")]
    for candidate in candidates:
        if candidate and os.access(candidate, os.X_OK):
            return [candidate]
    raise RuntimeError("docker compose(または docker-compose)が見つかりません")


COMPOSE = None


def compose_environment(password=None, authorized_key=None):
    """compose.yaml は資格情報の変数を必須(:?)にしているため、down のときも空でない値を渡す。"""
    environment = dict(os.environ)
    environment["PKPANE_MATRIX_PASSWORD"] = password or "unused"
    environment["PKPANE_MATRIX_AUTHORIZED_KEY"] = authorized_key or "unused"
    return environment


def compose_down(docker, project, check):
    result = subprocess.run(
        compose_command(docker, project, "down", "--remove-orphans", "--timeout", "5"),
        env=compose_environment(), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE, text=True)
    if check and result.returncode != 0:
        raise RuntimeError(f"compose down に失敗しました: {result.stderr.strip()[-400:]}")


def compose_command(docker, project, *args):
    global COMPOSE
    if COMPOSE is None:
        COMPOSE = compose_prefix(docker)
    return [*COMPOSE, "-p", project, "-f", str(COMPOSE_FILE), *args]


def validated_root(configuration_path):
    path = Path(configuration_path)
    if path.is_symlink() or path.name != "configuration.json":
        raise RuntimeError("行列テストの configuration.json 以外は扱えません")
    root = path.parent.resolve()
    if root.parent != Path("/private/tmp") or not root.name.startswith(ROOT_PREFIX):
        raise RuntimeError("専用一時ルート以外は扱えません")
    return root


def wait_for_banner(port, deadline):
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1.0) as connection:
                connection.settimeout(2.0)
                data = connection.recv(256)
                text = data.decode("ascii", "replace")
                for line in text.splitlines():
                    if line.startswith("SSH-2.0-"):
                        return line.strip()
        except OSError:
            pass
        time.sleep(0.2)
    raise RuntimeError(f"ポート {port} の SSH バナーを期限内に受信できませんでした")


def host_port(docker, project, service):
    output = subprocess.check_output(
        compose_command(docker, project, "port", service, "22"), text=True).strip()
    if not output:
        raise RuntimeError(f"{service} の公開ポートを取得できません")
    return int(output.rsplit(":", 1)[1])


def host_public_key(docker, project, service):
    output = subprocess.check_output(
        compose_command(docker, project, "exec", "-T", service, *HOST_KEY_COMMANDS[service]),
        text=True).strip()
    parts = output.split()
    if len(parts) < 2 or not parts[0].startswith("ssh-"):
        raise RuntimeError(f"{service} のホスト公開鍵を取得できません")
    return " ".join(parts[:2])


def start():
    docker = docker_executable()
    if docker is None:
        print("Docker が見つからないため行列テストを skip します。", file=sys.stderr)
        sys.exit(NO_DOCKER_EXIT_CODE)
    if os.getuid() == 0:
        raise RuntimeError("root では実行できません")

    token = secrets.token_hex(6)
    root = Path("/private/tmp") / f"{ROOT_PREFIX}{token}"
    root.mkdir(mode=0o700)
    project = f"{PROJECT_PREFIX}{token}"
    started = False
    try:
        key_path = root / "ed25519"
        subprocess.run(
            ["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "pkpane-matrix",
             "-f", str(key_path)],
            check=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
        authorized_key = (root / "ed25519.pub").read_text().strip()
        password = secrets.token_urlsafe(18)
        wrong_password = secrets.token_urlsafe(18)
        while wrong_password == password:
            wrong_password = secrets.token_urlsafe(18)

        environment = compose_environment(password, authorized_key)
        with (root / "compose.log").open("a") as log:
            subprocess.run(
                compose_command(docker, project, "up", "-d", "--build", "--quiet-pull"),
                check=True, env=environment, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        started = True

        deadline = time.monotonic() + READY_TIMEOUT_SECONDS
        servers = {}
        for service in HOST_KEY_COMMANDS:
            port = host_port(docker, project, service)
            banner = wait_for_banner(port, deadline)
            servers[service] = {
                "port": port,
                "hostPublicKey": host_public_key(docker, project, service),
                "banner": banner,
            }

        configuration = {
            "host": "127.0.0.1",
            "username": USERNAME,
            "password": password,
            "wrongPassword": wrong_password,
            "privateKeyPath": str(key_path),
            "fixtureFileName": FIXTURE_FILE_NAME,
            "composeProject": project,
            "servers": servers,
        }
        configuration_path = root / "configuration.json"
        descriptor = os.open(configuration_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as output:
            json.dump(configuration, output, indent=2)
        print(configuration_path)
    except BaseException:
        # 一時ルートは消すので、原因追跡のために compose の出力末尾だけ標準エラーへ残す。
        log_path = root / "compose.log"
        if log_path.is_file():
            tail = log_path.read_text(errors="replace").splitlines()[-40:]
            print("compose.log(末尾):", file=sys.stderr)
            for line in tail:
                print("  " + line, file=sys.stderr)
        if started:
            compose_down(docker, project, check=False)
        shutil.rmtree(root, ignore_errors=True)
        raise


def stop(configuration_path):
    root = validated_root(configuration_path)
    configuration = json.loads((root / "configuration.json").read_text())
    project = configuration["composeProject"]
    if not project.startswith(PROJECT_PREFIX):
        raise RuntimeError("行列テスト以外の compose project は停止しません")
    docker = docker_executable()
    if docker is None:
        raise RuntimeError("Docker が見つからないため停止できません")
    compose_down(docker, project, check=True)
    shutil.rmtree(root)
    print("行列テスト用サーバー群を停止しました。")


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "start":
        start()
    elif len(sys.argv) == 3 and sys.argv[1] == "stop":
        stop(sys.argv[2])
    else:
        raise RuntimeError("使用方法: rv26_sftp_auth_matrix.py start | stop <configuration.json>")
