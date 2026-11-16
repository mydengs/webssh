#!/usr/bin/env bash
#
# WebSSH 一键部署脚本
# 用法：sudo bash deploy.sh [选项]
#
#   -p, --port <端口>        WebSSH 网页监听端口（默认 39622）
#   -b, --bind <地址>        监听地址（默认 0.0.0.0；只让本机访问用 127.0.0.1）
#   -d, --dir <目录>         安装目录（默认 /srv/webssh）
#   -w, --password <口令>    指定网页登录口令（默认随机生成）
#   -u, --ssh-user <用户>    WebSSH 自动登录用的本机系统用户（默认 root）
#   -s, --service <名字>     服务名（默认 webssh；同一台机跑多实例时改这个）
#       --no-firewall        不改动防火墙
#       --uninstall          卸载
#       --status             查看当前状态
#   -y, --yes                不交互，全部用默认值
#   -h, --help               帮助
#
set -euo pipefail

SERVICE_NAME="webssh"
APP_PORT="39622"
APP_BIND="0.0.0.0"
APP_DIR="/srv/webssh"
ACCESS_PW=""
SSH_USER="root"
OPEN_FIREWALL=1
ASSUME_YES=0
ACTION="install"
DIR_FROM_USER=0

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$PKG_DIR/webssh"

C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_B=$'\033[36m'; C_0=$'\033[0m'
info()  { echo "${C_B}[*]${C_0} $*"; }
ok()    { echo "${C_G}[✓]${C_0} $*"; }
warn()  { echo "${C_Y}[!]${C_0} $*"; }
die()   { echo "${C_R}[✗]${C_0} $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
WebSSH 一键部署脚本
用法：sudo bash deploy.sh [选项]

  -p, --port <端口>        WebSSH 网页监听端口（默认 39622）
  -b, --bind <地址>        监听地址（默认 0.0.0.0；只让本机访问用 127.0.0.1）
  -d, --dir <目录>         安装目录（默认 /srv/webssh）
  -w, --password <口令>    指定网页登录口令（默认随机生成）
  -u, --ssh-user <用户>    WebSSH 自动登录用的本机系统用户（默认 root）
  -s, --service <名字>     服务名（默认 webssh；同一台机跑多实例时改这个）
      --no-firewall        不改动防火墙
      --uninstall          卸载
      --status             查看当前状态
  -y, --yes                不交互，全部用默认值
  -h, --help               帮助

示例：
  sudo bash deploy.sh                                   # 全默认安装
  sudo bash deploy.sh -p 8080 -w 'MyPw@2026'            # 换端口+指定口令
  sudo bash deploy.sh -b 127.0.0.1 -p 8080              # 只允许本机访问
  sudo bash deploy.sh -u ops                            # 用普通用户 ops 登录
  sudo bash deploy.sh --status
  sudo bash deploy.sh --uninstall
USAGE
  exit 0
}

# ---------------------------------------------------------------- 参数解析
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--port)      APP_PORT="${2:?}"; shift 2 ;;
    -b|--bind)      APP_BIND="${2:?}"; shift 2 ;;
    -d|--dir)       APP_DIR="${2:?}"; DIR_FROM_USER=1; shift 2 ;;
    -w|--password)  ACCESS_PW="${2:?}"; shift 2 ;;
    -u|--ssh-user)  SSH_USER="${2:?}"; shift 2 ;;
    -s|--service)   SERVICE_NAME="${2:?}"; shift 2 ;;
    --no-firewall)  OPEN_FIREWALL=0; shift ;;
    --uninstall)    ACTION="uninstall"; shift ;;
    --status)       ACTION="status"; shift ;;
    -y|--yes)       ASSUME_YES=1; shift ;;
    -h|--help)      usage ;;
    *) die "未知参数：$1（用 --help 查看用法）" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "请用 root 运行：sudo bash $0"

# ---------------------------------------------------------------- 状态 / 卸载
if [[ "$ACTION" == "status" ]]; then
  info "服务状态"
  systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null | head -12 || warn "服务未安装"
  echo
  info "监听端口"
  ss -tlnp 2>/dev/null | grep -E ":${APP_PORT}\b" || warn "端口 ${APP_PORT} 未监听"
  echo
  info "自动探测到的 SSH 参数"
  if [[ $DIR_FROM_USER -eq 0 && -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
    D="$(awk -F'=' '/^WorkingDirectory=/{print $2; exit}' "/etc/systemd/system/${SERVICE_NAME}.service")"
    [[ -n "${D:-}" ]] && APP_DIR="$D"
  fi
  [[ -f "$APP_DIR/app.py" ]] && python3 "$APP_DIR/app.py" --check || warn "未找到 $APP_DIR/app.py"
  exit 0
fi

if [[ "$ACTION" == "uninstall" ]]; then
  # 没带 -d 时，从已安装的 unit 里读回真实安装目录，避免误删默认路径
  UNIT_EXIST="/etc/systemd/system/${SERVICE_NAME}.service"
  if [[ $DIR_FROM_USER -eq 0 && -f "$UNIT_EXIST" ]]; then
    DETECTED="$(awk -F'=' '/^WorkingDirectory=/{print $2; exit}' "$UNIT_EXIST")"
    [[ -n "${DETECTED:-}" ]] && APP_DIR="$DETECTED"
  fi
  warn "即将卸载 WebSSH（服务 + $APP_DIR）"
  if [[ $ASSUME_YES -eq 0 ]]; then
    read -r -p "确认继续？[y/N] " a; [[ "$a" =~ ^[Yy]$ ]] || die "已取消"
  fi
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload || true
  rm -rf "$APP_DIR"
  ok "已卸载。若要彻底清理，可自行删除 /root/.ssh 中为本项目生成的密钥。"
  exit 0
fi

# ---------------------------------------------------------------- 环境检查
info "检查运行环境"
command -v systemctl >/dev/null || die "本机没有 systemd，本脚本不支持（可手工 nohup 启动）"

SOURCE_KIND=""
if [[ -f "$SRC_DIR/app.py" ]]; then
  SOURCE_KIND="dir"; ok "检测到源码目录：$SRC_DIR"
elif ls "$PKG_DIR"/webssh-*.tar.gz >/dev/null 2>&1; then
  SOURCE_KIND="tar"
  TARBALL="$(ls -1 "$PKG_DIR"/webssh-*.tar.gz | head -1)"
  ok "检测到离线包：$TARBALL"
else
  die "安装包不完整：缺少 webssh/app.py，也找不到 webssh-*.tar.gz"
fi

PY=""
for c in python3 python3.12 python3.11 python3.10 python3.9; do
  command -v "$c" >/dev/null 2>&1 && { PY="$(command -v "$c")"; break; }
done
[[ -n "$PY" ]] || die "未找到 python3，请先：apt install -y python3 | yum install -y python3"
PYV=$("$PY" -c 'import sys;print("%d.%d"%sys.version_info[:2])')
ok "Python: $PY ($PYV)"

[[ "$(printf '%s\n%s\n' "3.8" "$PYV" | sort -V | head -1)" == "3.8" ]] || die "需要 Python ≥ 3.8，当前 $PYV"

SSHD_BIN="$(command -v sshd || echo /usr/sbin/sshd)"
[[ -x "$SSHD_BIN" ]] || die "本机未安装 sshd，WebSSH 无对象可连。请先安装 openssh-server"

# ---------------------------------------------------------------- 安装依赖
info "安装 Python 依赖（paramiko / flask / flask-sock）"

if "$PY" -c "import paramiko, flask, flask_sock" >/dev/null 2>&1; then
  ok "依赖已就绪（系统环境）"
  VENV_PY="$PY"
else
  # 优先用 venv，避免污染系统 Python（PEP 668）
  VENV_DIR="$APP_DIR/venv"
  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    if ! "$PY" -m venv "$VENV_DIR" >/dev/null 2>&1; then
      warn "创建 venv 失败，尝试安装 python3-venv / python3-pip"
      if command -v apt-get >/dev/null; then
        apt-get update -qq >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv python3-pip >/dev/null 2>&1 || true
      elif command -v dnf >/dev/null; then
        dnf install -y -q python3-pip >/dev/null 2>&1 || true
      elif command -v yum >/dev/null; then
        yum install -y -q python3-pip >/dev/null 2>&1 || true
      fi
      "$PY" -m venv "$VENV_DIR" >/dev/null 2>&1 || VENV_DIR=""
    fi
  fi

  if [[ -n "${VENV_DIR:-}" && -x "$VENV_DIR/bin/python" ]]; then
    info "使用虚拟环境：$VENV_DIR"
    "$VENV_DIR/bin/python" -m pip install -q --upgrade pip >/dev/null 2>&1 || true
    "$VENV_DIR/bin/python" -m pip install -q paramiko flask flask-sock \
      || die "pip 安装失败，请检查网络或换用国内镜像后重试"
    VENV_PY="$VENV_DIR/bin/python"
  else
    warn "无法创建虚拟环境，退回系统 pip（--break-system-packages）"
    "$PY" -m pip install -q --break-system-packages paramiko flask flask-sock 2>/dev/null \
      || "$PY" -m pip install -q paramiko flask flask-sock \
      || die "pip 安装失败，请手工安装：pip3 install paramiko flask flask-sock"
    VENV_PY="$PY"
  fi
  "$VENV_PY" -c "import paramiko, flask, flask_sock" || die "依赖安装后仍无法导入"
  ok "依赖安装完成"
fi

# ---------------------------------------------------------------- 部署文件
info "部署程序文件到 $APP_DIR"
mkdir -p "$APP_DIR"
if [[ "$SOURCE_KIND" == "tar" ]]; then
  TMPX="$(mktemp -d)"
  tar -xzf "$TARBALL" -C "$TMPX"
  SRC_DIR="$(find "$TMPX" -maxdepth 2 -type d -name webssh | head -1)"
  [[ -n "$SRC_DIR" ]] || die "压缩包内未找到 webssh 目录"
fi

install -m 0755 -d "$APP_DIR/templates" "$APP_DIR/static"
install -m 0644 "$SRC_DIR/app.py"      "$APP_DIR/app.py"
install -m 0644 "$SRC_DIR/discover.py" "$APP_DIR/discover.py"
install -m 0644 "$SRC_DIR/templates/index.html" "$APP_DIR/templates/index.html"
for f in "$SRC_DIR"/static/*; do install -m 0644 "$f" "$APP_DIR/static/"; done
[[ -f "$SRC_DIR/README.md" ]] && install -m 0644 "$SRC_DIR/README.md" "$APP_DIR/README.md"
[[ -f "$SRC_DIR/ssh.conf.example" ]] && install -m 0644 "$SRC_DIR/ssh.conf.example" "$APP_DIR/ssh.conf.example"
chmod 0755 "$APP_DIR"
rm -rf "$APP_DIR/__pycache__"
ok "文件已就位"

# ---------------------------------------------------------------- 访问口令
if [[ -z "$ACCESS_PW" ]]; then
  if [[ -f "$APP_DIR/ssh.conf" ]] && grep -q '^ACCESS_PASSWORD=' "$APP_DIR/ssh.conf" 2>/dev/null; then
    ACCESS_PW="$(grep '^ACCESS_PASSWORD=' "$APP_DIR/ssh.conf" | head -1 | cut -d= -f2-)"
    ok "沿用已有口令"
  else
    ACCESS_PW="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 14)"
    [[ -n "$ACCESS_PW" ]] || ACCESS_PW="Webssh@$(date +%s | tail -c 6)"
  fi
fi

cat > "$APP_DIR/ssh.conf" <<CONF
# WebSSH 配置 —— 改完不需要重启服务，下次连接自动生效
# 本文件由 deploy.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S')

# 网页登录口令
ACCESS_PASSWORD=$ACCESS_PW

# 自动登录用的系统用户（留空=自动探测 root/当前用户）
SSH_USER=$SSH_USER

# 以下留空即自动探测，一般不需要填
# SSH_HOST=127.0.0.1
# SSH_PORT=22
# SSH_KEY=/root/.ssh/id_ed25519
# SSH_PASSWORD=
CONF
chmod 0600 "$APP_DIR/ssh.conf"
ok "配置已生成：$APP_DIR/ssh.conf"

# ---------------------------------------------------------------- 免密登录准备
info "配置本机 SSH 免密登录（WebSSH 靠它在浏览器里开终端）"
# 注意：不要让 awk 提前 exit，否则 sshd -T 收到 SIGPIPE 会被 pipefail 判为失败
SSH_PORT="$( { "$SSHD_BIN" -T 2>/dev/null || true; } | awk '/^[Pp]ort /{print $2}' | sort -n | uniq | head -1 )"
[[ -n "${SSH_PORT:-}" ]] || SSH_PORT=22
ok "sshd 端口：$SSH_PORT"

HOME_DIR="$(getent passwd "$SSH_USER" | cut -d: -f6)"
[[ -n "$HOME_DIR" && -d "$HOME_DIR" ]] || die "用户 $SSH_USER 不存在"
SSH_DIR="$HOME_DIR/.ssh"
install -m 0700 -d "$SSH_DIR"

KEY_FILE=""
for k in "$SSH_DIR/id_ed25519" "$SSH_DIR/id_rsa" "$SSH_DIR/id_ecdsa"; do
  [[ -f "$k" ]] && { KEY_FILE="$k"; break; }
done
if [[ -z "$KEY_FILE" ]]; then
  info "生成新密钥：$SSH_DIR/id_ed25519"
  ssh-keygen -t ed25519 -f "$SSH_DIR/id_ed25519" -N "" -q -C "webssh@$(hostname)" \
    || die "生成密钥失败"
  KEY_FILE="$SSH_DIR/id_ed25519"
fi
ok "使用密钥：$KEY_FILE"

PUB="$(cat "${KEY_FILE}.pub")"
touch "$SSH_DIR/authorized_keys"
chmod 0600 "$SSH_DIR/authorized_keys"
if ! grep -qF "$PUB" "$SSH_DIR/authorized_keys"; then
  echo "$PUB" >> "$SSH_DIR/authorized_keys"
  ok "公钥已写入 authorized_keys"
else
  ok "公钥已在 authorized_keys 中"
fi
chown -R "$(id -u "$SSH_USER"):$(id -g "$SSH_USER")" "$SSH_DIR" 2>/dev/null || true
if command -v restorecon >/dev/null 2>&1; then
  restorecon -R "$SSH_DIR" >/dev/null 2>&1 || true
fi

# 实测免密是否通
info "实测本机 SSH 免密登录…"
SSH_OK=0
for target in 127.0.0.1 ::1; do
  if ssh -i "$KEY_FILE" -p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile="$HOME_DIR/.ssh/known_hosts" -o ConnectTimeout=6 \
        "${SSH_USER}@${target}" "true" >/dev/null 2>&1; then
    SSH_OK=1; ok "免密登录通过（${SSH_USER}@${target}:${SSH_PORT}）"; break
  fi
done

if [[ $SSH_OK -eq 0 ]]; then
  warn "免密登录未通过，WebSSH 可能连不上！请检查："
  grep -qE '^\s*PermitRootLogin\s+(no|forced-commands-only)' /etc/ssh/sshd_config 2>/dev/null \
    && warn "  · sshd 禁止了 root 登录（PermitRootLogin no）→ 改用 --ssh-user <普通用户> 重跑"
  grep -qE '^\s*PubkeyAuthentication\s+no' /etc/ssh/sshd_config 2>/dev/null \
    && warn "  · sshd 关闭了公钥认证 → 打开 PubkeyAuthentication yes 后 systemctl reload sshd"
  warn "  · 若已禁止口令登录又没配密钥，需要先用密码/控制台把自己救回来"
  warn "  · 也可在 $APP_DIR/ssh.conf 里显式写 SSH_PORT / SSH_KEY / SSH_PASSWORD"
  warn "  继续安装，稍后可用浏览器登录验证。"
fi

# ---------------------------------------------------------------- systemd
info "安装 systemd 服务"
TPL="$PKG_DIR/webssh.service.tpl"
[[ -f "$TPL" ]] || die "缺少 webssh.service.tpl"
UNIT="/etc/systemd/system/${SERVICE_NAME}.service"

sed -e "s#__APP_DIR__#${APP_DIR}#g" \
    -e "s#__PYTHON__#${VENV_PY}#g" \
    -e "s#__BIND__#${APP_BIND}#g" \
    -e "s#__PORT__#${APP_PORT}#g" \
    "$TPL" > "$UNIT"
chmod 0644 "$UNIT"
ok "已写入 $UNIT"

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
systemctl restart "$SERVICE_NAME"
sleep 3

if ! systemctl is-active --quiet "$SERVICE_NAME"; then
  echo
  journalctl -u "$SERVICE_NAME" --no-pager -n 20 || true
  die "服务启动失败，日志见上"
fi
ok "服务已启动并设为开机自启"

# ---------------------------------------------------------------- 防火墙
if [[ $OPEN_FIREWALL -eq 1 ]]; then
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${APP_PORT}/tcp" >/dev/null 2>&1 && ok "ufw 已放行 ${APP_PORT}/tcp"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${APP_PORT}/tcp" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1 && ok "firewalld 已放行 ${APP_PORT}/tcp"
  else
    info "未检测到启用的 ufw/firewalld，跳过防火墙配置"
  fi
fi

# ---------------------------------------------------------------- 自检
info "自检"
LISTEN_OK=0
for i in 1 2 3 4 5; do
  if ss -tln 2>/dev/null | grep -qE ":${APP_PORT}\b"; then LISTEN_OK=1; break; fi
  sleep 1
done
[[ $LISTEN_OK -eq 1 ]] && ok "端口 ${APP_PORT} 已监听" || warn "端口 ${APP_PORT} 未监听，请查 journalctl -u ${SERVICE_NAME}"

HTTP_OK=0
for h in 127.0.0.1 localhost; do
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://${h}:${APP_PORT}/" 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]] && { HTTP_OK=1; break; }
done
[[ $HTTP_OK -eq 1 ]] && ok "首页返回 200" || warn "首页访问异常（HTTP ${code:-000}）"

LOGIN_OK=0
if [[ $HTTP_OK -eq 1 ]]; then
  [[ "$(curl -s -m 8 -X POST "http://127.0.0.1:${APP_PORT}/api/login" \
        -H 'Content-Type: application/json' \
        -d "{\"password\":\"${ACCESS_PW}\"}" -o /dev/null -w '%{http_code}')" == "200" ]] && LOGIN_OK=1
fi
[[ $LOGIN_OK -eq 1 ]] && ok "口令登录接口正常" || warn "口令登录接口异常"

IP_SHOW="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -n "${IP_SHOW:-}" ]] || IP_SHOW="<服务器IP>"

cat <<EOF

${C_G}════════════════════════════════════════════════════════════${C_0}
  ${C_G}WebSSH 部署完成${C_0}

  访问地址   http://${IP_SHOW}:${APP_PORT}/
  登录口令   ${C_Y}${ACCESS_PW}${C_0}
  安装目录   ${APP_DIR}
  配置文件   ${APP_DIR}/ssh.conf （改完即时生效，无需重启）
  服务名     ${SERVICE_NAME}

  常用命令
    systemctl status ${SERVICE_NAME}
    systemctl restart ${SERVICE_NAME}
    journalctl -u ${SERVICE_NAME} -f
    python3 ${APP_DIR}/app.py --check     # 查看自动探测到的 SSH 参数
    bash $0 --uninstall                   # 卸载

${C_Y}  安全提醒：${APP_BIND}:${APP_PORT} 对能访问该端口的所有人开放，
  登录后即拥有 ${SSH_USER} 的 shell。请务必保管好上面的口令，
  并建议在云厂商安全组 / 防火墙中限制来源 IP。${C_0}
${C_G}════════════════════════════════════════════════════════════${C_0}

EOF
