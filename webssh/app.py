#!/usr/bin/env python3
"""WebSSH — 通过浏览器使用本机 SSH 终端。

特性
  · 全自动适配本机 sshd：端口、用户、密钥、口令都在每次连接时重新探测，
    root 改了端口 / 换了密钥 / 加了新密钥，无需改代码、无需重启服务。
  · 访问口令从 /srv/webssh/ssh.conf 或环境变量实时读取，改完即生效。
  · 失败自动回退：缓存的成功方式失效时，立即做全量重新探测。
"""
import json
import os
import secrets
import threading
import time

import paramiko
from flask import Flask, jsonify, request, render_template, session
from flask_sock import Sock

import discover

CACHE_PATH = discover.CACHE_PATH
MAX_FAILS = 5
LOCK_WINDOW = 300
DEFAULT_ACCESS_PW = "Webssh@39622"

app = Flask(__name__)
app.secret_key = os.environ.get("WEBSSH_SECRET") or secrets.token_hex(32)
sock = Sock(app)

_failed = {}


# --------------------------------------------------------------------------
# 访问口令（每次实时读配置，改完不需要重启）
# --------------------------------------------------------------------------
def access_password():
    return discover.read_conf().get("ACCESS_PASSWORD") or DEFAULT_ACCESS_PW


def _client_ok(ip):
    now = time.time()
    rec = _failed.get(ip)
    if rec and now - rec[1] < LOCK_WINDOW and rec[0] >= MAX_FAILS:
        return False
    return True


def _record_fail(ip):
    now = time.time()
    n, t0 = _failed.get(ip, (0, now))
    if now - t0 > LOCK_WINDOW:
        n, t0 = 0, now
    _failed[ip] = (n + 1, t0)


# --------------------------------------------------------------------------
# 连接尝试结果缓存
# --------------------------------------------------------------------------
def _load_cache():
    try:
        with open(CACHE_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def _save_cache(data):
    try:
        with open(CACHE_PATH, "w", encoding="utf-8") as f:
            json.dump(data, f)
        os.chmod(CACHE_PATH, 0o600)
    except Exception:
        pass


# --------------------------------------------------------------------------
# SSH 连接：自动探测 + 逐组尝试 + 成功后记住方式
# --------------------------------------------------------------------------
def _try_connect(host, port, user, key_path, password, timeout=8):
    cli = paramiko.SSHClient()
    try:
        cli.load_system_host_keys()
    except Exception:
        pass
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        cli.connect(
            host, port=port, username=user,
            password=password,
            key_filename=key_path,
            look_for_keys=(key_path is None),
            allow_agent=(key_path is None),
            timeout=timeout,
            banner_timeout=timeout,
            auth_timeout=timeout,
        )
        return cli, None
    except Exception as e:
        try:
            cli.close()
        except Exception:
            pass
        return None, e


def connect_ssh():
    """返回 (SSHClient, 说明, 错误详情)。"""
    conf = discover.read_conf()
    hosts = discover.candidate_hosts(conf)
    ports = []
    if conf.get("SSH_PORT"):
        try:
            ports.append(int(conf["SSH_PORT"]))
        except ValueError:
            pass
    for p in discover.ssh_ports():
        if p not in ports:
            ports.append(p)
    users = discover.candidate_users(conf)
    keys = discover.candidate_keys(conf)
    passwords = discover.candidate_passwords(conf)

    # 1) 先试上次成功的方式（最快路径）
    cache = _load_cache()
    if cache and cache.get("port") in ports:
        chost = cache.get("host") or hosts[0]
        kp = cache.get("key")
        cli, err = _try_connect(
            chost, cache["port"], cache.get("user", "root"),
            None if cache.get("mode") in ("agent", "password") else kp,
            passwords[0] if cache.get("mode") == "password" and passwords else None,
        )
        if cli:
            return cli, "缓存方式 host=%s port=%s user=%s" % (
                chost, cache["port"], cache.get("user")), []

    # 2) 全量探测：地址 × 端口 × 用户 × (密钥/agent | 口令)
    errors = []
    for host in hosts:
        for port in ports:
            for user in users:
                for key_path, tag in keys:
                    cli, err = _try_connect(host, port, user, key_path, None)
                    if cli:
                        _save_cache({
                            "mode": "agent" if key_path is None else "key",
                            "host": host, "port": port, "user": user,
                            "key": key_path, "ts": int(time.time()),
                        })
                        return cli, "自动探测 host=%s port=%s user=%s key=%s" % (
                            host, port, user, key_path or "ssh-agent"), errors
                    errors.append("%s:%s %s key=%s -> %s" % (
                        host, port, user, key_path or "agent", _short(err)))
                for pw in passwords:
                    cli, err = _try_connect(host, port, user, None, pw)
                    if cli:
                        _save_cache({
                            "mode": "password", "host": host, "port": port,
                            "user": user, "key": None, "ts": int(time.time()),
                        })
                        return cli, "自动探测 host=%s port=%s user=%s 口令" % (
                            host, port, user), errors
                    errors.append("%s:%s %s password -> %s" % (host, port, user, _short(err)))

    return None, "", errors


def _short(err):
    if err is None:
        return "?"
    s = str(err)
    return s[:120]


# --------------------------------------------------------------------------
# 路由
# --------------------------------------------------------------------------
@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/login", methods=["POST"])
def login():
    ip = request.remote_addr or "?"
    if not _client_ok(ip):
        return jsonify(ok=False, msg="失败次数过多，请 5 分钟后再试"), 429
    data = request.get_json(silent=True) or {}
    if data.get("password") == access_password():
        session["authed"] = True
        _failed.pop(ip, None)
        return jsonify(ok=True)
    _record_fail(ip)
    return jsonify(ok=False, msg="口令错误"), 401


@app.route("/api/logout", methods=["POST"])
def logout():
    session.pop("authed", None)
    return jsonify(ok=True)


@app.route("/api/me")
def me():
    return jsonify(authed=bool(session.get("authed")))


@app.route("/api/ssh-info")
def ssh_info():
    """给运维看的自动探测结果，确认当前会用什么方式连。"""
    if not session.get("authed"):
        return jsonify(ok=False), 403
    info = discover.describe()
    return jsonify(ok=True, info=info)


# --------------------------------------------------------------------------
# WebSocket 终端
# --------------------------------------------------------------------------
@sock.route("/ws")
def ws(sock_client):
    try:
        _ws_handler(sock_client)
    except Exception:
        app.logger.exception("ws handler crashed")


def _ws_handler(sock_client):
    if not session.get("authed"):
        sock_client.send("401 未授权，请先登录")
        return

    sock_client.send("\x1b[36m[WebSSH] 自动探测本机 SSH 参数…\x1b[0m")
    client, how, errors = connect_ssh()
    if not client:
        sock_client.send("\r\n\x1b[31mSSH 连接失败，已尝试全部自动探测组合：\x1b[0m\r\n")
        for e in errors[:12]:
            sock_client.send("  " + e + "\r\n")
        sock_client.send(
            "\r\n\x1b[33m排查建议：\x1b[0m\r\n"
            "  · 端口/用户/密钥不对：编辑 /srv/webssh/ssh.conf 显式指定\r\n"
            "  · 需要口令登录：在 ssh.conf 里写 SSH_PASSWORD=xxx\r\n"
            "  · 配置好后无需重启，下次连接自动生效\r\n")
        return

    sock_client.send("\x1b[32m[WebSSH] %s\x1b[0m\r\n" % how)

    chan = client.invoke_shell(term="xterm-256color", width=120, height=32)
    chan.settimeout(0.0)

    def reader():
        try:
            while True:
                if chan.closed or not sock_client.connected:
                    break
                if chan.recv_ready():
                    data = chan.recv(65536)
                    if data:
                        sock_client.send(data.decode("utf-8", "replace"))
                else:
                    time.sleep(0.02)
        except Exception:
            pass
        try:
            sock_client.close()
        except Exception:
            pass

    threading.Thread(target=reader, daemon=True).start()

    try:
        while True:
            msg = sock_client.receive()
            if msg is None:
                break
            if isinstance(msg, str) and msg.startswith("\x00RESIZE"):
                try:
                    _, cols, rows = msg.split(":")
                    chan.resize_pty(int(cols), int(rows))
                except Exception:
                    pass
            else:
                chan.send(msg)
    except Exception:
        pass
    finally:
        try:
            chan.close()
        except Exception:
            pass
        try:
            client.close()
        except Exception:
            pass


if __name__ == "__main__":
    import sys

    if "--check" in sys.argv:
        print(json.dumps(discover.describe(), indent=2, ensure_ascii=False))
        sys.exit(0)

    host = os.environ.get("WEBSSH_BIND", "0.0.0.0")
    port = int(os.environ.get("WEBSSH_PORT", "39622"))
    app.run(host=host, port=port, debug=False, threaded=True)
