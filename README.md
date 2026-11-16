# WebSSH —— 浏览器里用本机 SSH 终端（一键部署包）

在浏览器里开一个完整的终端，直连**这台服务器自己**的 SSH。
后端用本机密钥免密登录，等于把 SSH 搬进了网页。

**核心特性：零维护。** 本机 sshd 改了端口 / 换了密钥 / 新增了密钥，你**不用改代码、不用重启服务**，下次打开页面自动适配。

---

## 一、三步部署

### 1. 把包传到目标服务器

只传一个文件就够了（脚本、源码、文档全在里面）：

```bash
scp webssh-1.0.0.tar.gz root@目标服务器:/root/
```

### 2. 解压

```bash
cd /root && tar -xzf webssh-1.0.0.tar.gz
cd weback 2>/dev/null || true     # 包内是平铺的，若在解压目录直接下一步即可
```

### 3. 一键安装

```bash
sudo bash deploy.sh
```

看到这个就是成功了：

```
════════════════════════════════════════════════════════════
  WebSSH 部署完成

  访问地址   http://1.2.3.4:39622/
  登录口令   Xk9mQ2vL7pR4tA
  安装目录   /srv/webssh
  配置文件   /srv/webssh/ssh.conf （改完即时生效，无需重启）
  服务名     webssh
════════════════════════════════════════════════════════════
```

浏览器打开上面地址，输入口令即可。

> 口令默认**随机生成**并写进 `/srv/webssh/ssh.conf`。想自己指定用 `-w`。

---

## 二、脚本做了什么

按顺序，每步都会打印结果，任何一步失败会明确报错并停下：

| 步骤 | 内容 |
|---|---|
| 1 | 检查 root、systemd、python3（≥3.8）、sshd 是否具备 |
| 2 | 安装依赖 paramiko / flask / flask-sock（优先建 venv，避免污染系统 Python） |
| 3 | 把程序文件部署到 `/srv/webssh` |
| 4 | 生成 `/srv/webssh/ssh.conf`（含随机访问口令，权限 600） |
| 5 | **准备免密登录**：没有密钥就 `ssh-keygen` 生成，把公钥写进 `authorized_keys`，再实测 `ssh` 能不能通 |
| 6 | 生成并安装 systemd 服务，`enable` + `restart` |
| 7 | 防火墙：检测到已启用的 ufw / firewalld 才放行端口 |
| 8 | **自检**：端口监听 + 首页 200 + 登录接口 200，三项全过才算成功 |

第 5 步是关键——很多同类项目装完打不开终端，就是因为它没帮你把"后端能不能免密登录本机"这件事做掉并验证。

---

## 三、参数

```
sudo bash deploy.sh [选项]

  -p, --port <端口>        WebSSH 网页监听端口（默认 39622）
  -b, --bind <地址>        监听地址（默认 0.0.0.0；只让本机访问用 127.0.0.1）
  -d, --dir <目录>         安装目录（默认 /srv/webssh）
  -w, --password <口令>    指定网页登录口令（默认随机生成）
  -u, --ssh-user <用户>    WebSSH 自动登录用的本机系统用户（默认 root）
  -s, --service <名字>     服务名（默认 webssh；同机多实例时改这个）
      --no-firewall        不改动防火墙
      --uninstall          卸载
      --status             查看当前状态
  -y, --yes                不交互，全部用默认值
  -h, --help               帮助
```

常用组合：

```bash
# 全默认
sudo bash deploy.sh

# 换端口 + 自己指定口令
sudo bash deploy.sh -p 8080 -w 'MyStrongPw@2026'

# 只允许本机访问（配合 nginx 反代做 HTTPS 时用这个）
sudo bash deploy.sh -b 127.0.0.1 -p 8080

# 用普通用户 ops 登录（root 禁止 SSH 登录时用）
sudo bash deploy.sh -u ops

# 同一台机跑第二个实例
sudo bash deploy.sh -s webssh2 -d /srv/webssh2 -p 39623 -w 'OtherPw@2026'
```

重复执行 `deploy.sh` 就是**升级/修复**：文件覆盖、配置里的口令保留、服务重启，不会重复生成密钥。

---

## 四、目录结构与文件说明

```
/srv/webssh/                 安装目录（可用 -d 改）
├── app.py                   Flask + flask-sock + paramiko 主程序
├── discover.py              自动探测本机 SSH 参数（端口/用户/密钥/口令）
├── ssh.conf                 配置（600 权限，改完即时生效）
├── ssh.conf.example         配置模板
├── README.md                项目说明
├── templates/index.html     xterm.js 前端
├── static/                  xterm 资源（本地内置，不依赖外网 CDN）
├── .ssh_cache.json          上次成功的连接方式（自动生成，失效自动重探）
└── venv/                    依赖虚拟环境（用到时才有）

/etc/systemd/system/webssh.service    systemd 服务定义
```

---

## 五、配置 `/srv/webssh/ssh.conf`

格式 `KEY=VALUE`，`#` 开头是注释。**改完不需要重启服务**，下一次连接自动生效。

```ini
# 网页登录口令
ACCESS_PASSWORD=YourPwHere

# 自动登录用的系统用户（留空=自动探测）
SSH_USER=root

# 以下留空即自动探测，一般不用填
# SSH_HOST=127.0.0.1
# SSH_PORT=22
# SSH_KEY=/root/.ssh/id_ed25519
# SSH_PASSWORD=
```

| 键 | 说明 |
|---|---|
| `ACCESS_PASSWORD` | 浏览器登录口令，改完即时生效 |
| `SSH_USER` | 后端要登录的系统用户 |
| `SSH_HOST` | 强制指定连接地址 |
| `SSH_PORT` | 强制指定端口（写错也不会挂，会自动回退到探测值） |
| `SSH_KEY` | 强制指定私钥路径 |
| `SSH_PASSWORD` | 仅当你想用密码登录 SSH 时填（明文，注意权限） |

改口令示例（立即生效，无需重启）：

```bash
echo 'ACCESS_PASSWORD=新的强口令' >> /srv/webssh/ssh.conf
```

---

## 六、自动适配原理（为什么不用回来找我改配置）

每次打开终端时才去探测，而不是启动时探测一次：

| 项 | 探测方式 | 你改了之后 |
|---|---|---|
| SSH 端口 | `sshd -T` 有效配置 → 解析 `sshd_config` 及 `sshd_config.d/*.conf`（含 Include）→ `ss -tlnp` 实际监听 | 立即生效 |
| 连接地址 | 配置 → `127.0.0.1` → `::1` → 本机网卡 IP（最多 4 个） | 立即生效 |
| 登录用户 | 配置 → 环境变量 → `root` → 当前用户 | 立即生效 |
| 密钥 | 扫描 `~/.ssh`、`/root/.ssh`、`/home/*/.ssh` 下所有私钥，**按文件头 `BEGIN ... PRIVATE KEY` 识别，不依赖文件名**，新的优先 | 换名、换路径、新增都自动识别 |
| 失败回退 | 上次成功的方式失效时清缓存，全量重新探测 | 不会卡死 |

**唯一无法自动发现的是 SSH 密码**——明文密码在系统里没有任何存储位置，能读到它本身就是安全问题。所以：

- 改 root 密码、但仍用密钥登录 → **什么都不用做**；
- 要改用密码登录 → 在 `ssh.conf` 写 `SSH_PASSWORD=新密码`，立即生效。

随时查看当前会用哪套参数连：

```bash
python3 /srv/webssh/app.py --check
```

```json
{
  "conf_path": "/srv/webssh/ssh.conf",
  "hosts": ["127.0.0.1", "::1", "10.0.0.5"],
  "ports": [48332],
  "users": ["root"],
  "keys": ["/root/.ssh/id_ed25519", "ssh-agent"],
  "has_password": false
}
```

浏览器登录后访问 `/api/ssh-info` 也能看到同样的信息。

---

## 七、服务管理

```bash
systemctl status webssh        # 状态
systemctl restart webssh       # 重启
systemctl stop webssh          # 停止
journalctl -u webssh -f        # 实时日志
bash deploy.sh --status        # 脚本自带的状态汇总
```

已设 `enable`（开机自启）+ `Restart=always`（崩溃自动拉起）。

---

## 八、故障排查

**① 打开页面，点登录没反应**

先强刷 `Ctrl+Shift+R`（浏览器可能缓存了旧页面）。仍旧没反应，按 F12 看 Console 是否有报错；同时确认静态资源可访问：

```bash
curl -I http://127.0.0.1:39622/static/xterm.min.js   # 应返回 200
```

本项目 xterm 资源是**本地内置**的，不走外网 CDN（早期版本用 CDN，国内网络下加载失败会导致整页脚本中断，已修掉）。

---

**② 登录后终端里报「SSH 连接失败，已尝试全部自动探测组合」**

页面上会列出所有尝试组合和原因。常见原因：

```bash
# 看 sshd 是否真的在跑、监听哪个端口
sshd -T | grep -i '^port'
ss -tlnp | grep sshd

# 确认 root 允许用密钥登录
grep -E 'PermitRootLogin|PubkeyAuthentication' /etc/ssh/sshd_config
```

- `PermitRootLogin no` → 改用 `sudo bash deploy.sh -u 普通用户`
- `PubkeyAuthentication no` → 改成 `yes` 后 `systemctl reload sshd`
- 端口不是默认的 → 一般不用管，会自动探测；实在要指定就写 `SSH_PORT`

---

**③ 端口被占用**

```bash
ss -tlnp | grep 39622
```
换端口重装：`sudo bash deploy.sh -p 39623`

---

**④ 外网访问不了，但本机 curl 是 200**

按这个顺序查：

1. 本机防火墙：`iptables -L -n | grep 39622`、`ufw status`、`firewall-cmd --list-ports`
2. **云厂商安全组**（阿里云/腾讯云/AWS 控制台）——这一步最容易漏，脚本改不了
3. 服务是不是监听在 `127.0.0.1`：`ss -tlnp | grep 39622` 应显示 `0.0.0.0:39622`

---

**⑤ pip 安装依赖失败**

```bash
# 换国内镜像
sudo bash deploy.sh   # 脚本会优先用 venv
# 手工装：
/srv/webssh/venv/bin/pip install paramiko flask flask-sock -i https://pypi.tuna.tsinghua.edu.cn/simple
```

离线环境下，先在能联网的机器上 `pip download` 好再传过去。

---

**⑥ 重新登录后提示「口令错误」**

口令在 `/srv/webssh/ssh.conf` 的 `ACCESS_PASSWORD=`，直接看：

```bash
grep ACCESS_PASSWORD /srv/webssh/ssh.conf
```

连续错 5 次会锁 IP 5 分钟，重启服务可立即解锁：

```bash
systemctl restart webssh
```

---

**⑦ SELinux 机器上密钥不生效**

```bash
restorecon -R -v /root/.ssh
```

---

## 九、安全建议（认真看）

1. **这个页面等于 root shell。** 谁能打开它、输对口令，谁就是你服务器的主人。
2. **改掉默认口令**，用 14 位以上随机串：`echo 'ACCESS_PASSWORD=xxx' >> /srv/webssh/ssh.conf`
3. **限制来源**，二选一：
   - 云安全组只放行你办公网 IP；
   - 或 `sudo bash deploy.sh -b 127.0.0.1`，前面挂 nginx 做 HTTPS + 基础认证。
4. **不要长期对公网裸开**。临时用、用完 `systemctl stop webssh`。
5. 长期使用强烈建议加 HTTPS，否则口令是明文传输。

nginx 反代参考：

```nginx
location / {
    proxy_pass http://127.0.0.1:39622;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;      # WebSocket 必须
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 3600s;                    # 终端别被 60s 掐断
}
```

---

## 十、卸载

```bash
# 在安装包目录执行（会自动从 unit 里读回真实安装目录）
sudo bash deploy.sh --uninstall
```

会停服务、禁用自启、删 unit 与安装目录。`/root/.ssh` 里的密钥不动（可能你的其他用途也在用），需要时自己删。

---

## 十一、二次开发

```
app.py       路由 /api/login /api/me /api/ssh-info /ws(WebSocket)
             · connect_ssh()   自动探测 + 逐组尝试 + 缓存成功方式
             · _ws_handler()   WebSocket ⇄ paramiko shell 双向转发
discover.py  read_conf()       实时读配置
             ssh_ports()       端口探测
             candidate_hosts() 连接地址候选
             candidate_keys()  密钥扫描
templates/index.html  xterm.js + 登录逻辑（登录按钮先绑定，终端后初始化）
```

改完代码重启生效：`systemctl restart webssh`
改完配置不用重启。

---

## 十二、已验证记录

在本机（Ubuntu 24.04 / Python 3.12 / sshd 非默认端口 48332）实测：

| 项目 | 结果 |
|---|---|
| 全新一键部署（独立端口 39777 独立目录） | ✅ 通过 |
| 部署后浏览器登录 → root shell | ✅ 通过（回显 `DEPLOY_TEST_OK` / `root`） |
| 卸载流程 | ✅ 通过 |
| 重复部署（覆盖升级） | ✅ 通过 |
| 缓存端口失效自动重探 | ✅ 0.2s 落到正确端口 |
| 新增无效密钥排在最前 | ✅ 自动跳过，用正确密钥 |
| 配置里故意写错端口 | ✅ 回退到探测值 |
| 改访问口令不重启服务 | ✅ 旧口令立即失效、新口令立即生效 |
