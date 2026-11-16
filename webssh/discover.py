#!/usr/bin/env python3
"""discover.py — 自动发现本机 SSH 登录参数。

设计目标：root 改了端口 / 换了密钥 / 加了新密钥 / 改了用户 / 改了口令，
WebSSH 无需改代码、无需重启即可自动适配。

发现优先级
  端口：sshd -T 有效配置 → 静态解析 sshd_config(+Include) → 实际监听端口 → 22
  用户：ssh.conf 指定 → 环境变量 → root → 当前用户
  密钥：ssh.conf 指定 → ~/.ssh 下所有私钥(按文件头识别) → ssh-agent
  口令：ssh.conf / 环境变量（口令无法自动"发现"，必须由你写入配置）
"""
import glob
import getpass
import os
import re
import subprocess

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONF_PATH = os.environ.get("WEBSSH_CONF", os.path.join(BASE_DIR, "ssh.conf"))
CACHE_PATH = os.path.join(BASE_DIR, ".ssh_cache.json")


# --------------------------------------------------------------------------
# 配置读取：每次调用都重新读文件，改完即生效，不需要重启
# --------------------------------------------------------------------------
def read_conf():
    conf = {}
    if os.path.isfile(CONF_PATH):
        try:
            with open(CONF_PATH, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    k, v = line.split("=", 1)
                    conf[k.strip().upper()] = v.strip().strip('"').strip("'")
        except Exception:
            pass
    # 环境变量覆盖配置文件
    for k_env, k_conf in (
        ("WEBSSH_SSH_HOST", "SSH_HOST"),
        ("WEBSSH_SSH_PORT", "SSH_PORT"),
        ("WEBSSH_SSH_USER", "SSH_USER"),
        ("WEBSSH_SSH_KEY", "SSH_KEY"),
        ("WEBSSH_SSH_PASSWORD", "SSH_PASSWORD"),
        ("WEBSSH_PASSWORD", "ACCESS_PASSWORD"),
    ):
        if os.environ.get(k_env):
            conf[k_conf] = os.environ[k_env]
    return conf


# --------------------------------------------------------------------------
# 端口发现
# --------------------------------------------------------------------------
def _parse_conf_ports():
    files = ["/etc/ssh/sshd_config"] + sorted(glob.glob("/etc/ssh/sshd_config.d/*.conf"))
    ports, seen, visited = [], set(), set()

    def scan(path, depth=0):
        if path in visited or depth > 5 or not os.path.isfile(path):
            return
        visited.add(path)
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    s = line.strip()
                    if not s or s.startswith("#"):
                        continue
                    m = re.match(r"^Port\s+(\d+)", s, re.I)
                    if m:
                        p = int(m.group(1))
                        if p not in seen:
                            seen.add(p)
                            ports.append(p)
                    m = re.match(r"^Include\s+(.+)$", s, re.I)
                    if m:
                        for pat in m.group(1).split():
                            for f2 in glob.glob(pat):
                                scan(f2, depth + 1)

        except Exception:
            pass

    for f in files:
        scan(f)
    return ports


def _listening_sshd_ports():
    out = []
    try:
        res = subprocess.run(["ss", "-tlnp"], capture_output=True, text=True, timeout=10)
        for line in res.stdout.splitlines():
            if "sshd" not in line:
                continue
            m = re.search(r":(\d+)\s+", line)
            if m:
                p = int(m.group(1))
                if p not in out:
                    out.append(p)
    except Exception:
        pass
    return out


def ssh_ports():
    ports = []
    try:
        res = subprocess.run(["sshd", "-T"], capture_output=True, text=True, timeout=15)
        for line in (res.stdout or "").splitlines():
            if line.lower().startswith("port "):
                try:
                    p = int(line.split()[1])
                except Exception:
                    continue
                if p not in ports:
                    ports.append(p)
    except Exception:
        pass
    if not ports:
        ports = _parse_conf_ports()
    for p in _listening_sshd_ports():
        if p not in ports:
            ports.append(p)
    return ports or [22]


# --------------------------------------------------------------------------
# 用户 / 密钥 / 口令候选
# --------------------------------------------------------------------------
def candidate_users(conf):
    users = []
    for u in [conf.get("SSH_USER"), os.environ.get("USER"), getpass.getuser(), "root"]:
        if u and u not in users:
            users.append(u)
    return users


def candidate_hosts(conf):
    """连接地址候选：配置 → 回环 v4/v6 → 本机主 IP。
    有些机器 sshd 只监听特定网卡/不监听 127.0.0.1，靠这个兜底。"""
    hosts = []
    if conf.get("SSH_HOST"):
        hosts.append(conf["SSH_HOST"])
    for h in ("127.0.0.1", "::1"):
        if h not in hosts:
            hosts.append(h)
    try:
        out = subprocess.run(["hostname", "-I"], capture_output=True, text=True, timeout=5).stdout
        for ip in out.split():
            if ip not in hosts:
                hosts.append(ip)
            if len(hosts) >= 4:      # 最多 4 个，避免全量探测过慢
                break
    except Exception:
        pass
    return hosts


def _is_private_key(path):
    try:
        if os.path.getsize(path) > 65536 or os.path.getsize(path) == 0:
            return False
        with open(path, "rb") as f:
            head = f.read(200)
        return b"PRIVATE KEY" in head
    except Exception:
        return False


def candidate_keys(conf):
    """返回 [(key_path_or_None, 标签)]，None 表示走 ssh-agent。"""
    out = []
    explicit = conf.get("SSH_KEY")
    if explicit and os.path.isfile(os.path.expanduser(explicit)):
        out.append((os.path.expanduser(explicit), "conf"))

    dirs = []
    for d in [os.path.expanduser("~/.ssh"), "/root/.ssh"] + glob.glob("/home/*/.ssh"):
        if os.path.isdir(d) and d not in dirs:
            dirs.append(d)

    found = []
    for d in dirs:
        try:
            names = os.listdir(d)
        except Exception:
            continue
        for name in names:
            if name.endswith(".pub") or name in ("known_hosts", "known_hosts.old", "config", "authorized_keys"):
                continue
            p = os.path.join(d, name)
            if os.path.isfile(p) and _is_private_key(p):
                found.append(p)

    # 新改的密钥优先：按修改时间倒序
    found.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    for p in found:
        if not any(p == e[0] for e in out):
            out.append((p, "scan"))

    out.append((None, "agent"))
    return out


def candidate_passwords(conf):
    pw = conf.get("SSH_PASSWORD")
    return [pw] if pw else []


def describe():
    conf = read_conf()
    ports = []
    if conf.get("SSH_PORT"):
        try:
            ports.append(int(conf["SSH_PORT"]))
        except ValueError:
            pass
    for p in ssh_ports():
        if p not in ports:
            ports.append(p)
    return {
        "conf_path": CONF_PATH,
        "conf_exists": os.path.isfile(CONF_PATH),
        "hosts": candidate_hosts(conf),
        "ports": ports,
        "users": candidate_users(conf),
        "keys": [k or "ssh-agent" for k, _ in candidate_keys(conf)],
        "has_password": bool(conf.get("SSH_PASSWORD")),
        "access_password_source": "ssh.conf/env" if conf.get("ACCESS_PASSWORD") else "内置默认",
    }


if __name__ == "__main__":
    import json

    print(json.dumps(describe(), indent=2, ensure_ascii=False))
