# WebSSH

浏览器里直接使用本机 SSH 终端。**零维护：本机 sshd 改了端口 / 换了密钥 / 加了新密钥，不用改代码、不用重启。**

## 访问

- 地址：`http://<服务器IP>:39622`
- 口令：默认 `Webssh@39622`（建议在 `/srv/webssh/ssh.conf` 里改）

## 自动适配原理

每次建立连接时（不是一个进程启动时）实时探测：

| 项 | 探测方式 | 你改了之后 |
|---|---|---|
| SSH 端口 | `sshd -T` 有效配置 → 解析 `sshd_config` 及 `sshd_config.d/*.conf`（含 Include）→ `ss -tlnp` 实际监听 | 立即生效 |
| 登录用户 | 配置 → 环境变量 → `root` → 当前用户 | 立即生效 |
| 密钥 | `~/.ssh`、`/root/.ssh`、`/home/*/.ssh` 下所有私钥（按文件头识别，不依赖文件名），新的优先 | 立即生效，换名/新增都行 |
| 口令 | 只能来自 `ssh.conf` 的 `SSH_PASSWORD=`（明文口令无法被系统"发现"） | 你写进配置即生效 |
| 访问口令 | 每次请求读取 `ssh.conf` | 立即生效，不用重启 |

失败会自动全量重探：上次成功的方式失效（端口变了、密钥换了）也不会卡死。

## 配置（全部可选）

编辑 `/srv/webssh/ssh.conf`，格式 `KEY=VALUE`，改完不用重启：

```ini
ACCESS_PASSWORD=换成你的强口令
# SSH_PORT=48332      # 留空=自动探测
# SSH_USER=root
# SSH_KEY=/root/.ssh/xxx
# SSH_PASSWORD=xxx    # 仅在需要密码登录时填
```

查看当前会用什么方式连（命令行）：

```bash
python3 /srv/webssh/app.py --check
```

浏览器登录后访问 `/api/ssh-info` 可看到同样的探测结果。

## 服务管理

```bash
systemctl status webssh      # 状态
systemctl restart webssh     # 重启
journalctl -u webssh -f      # 日志
```

已设 `enable` + `Restart=always`，重启机器自动拉起。

## 文件

```
/srv/webssh/
├── app.py               Flask + flask-sock + paramiko
├── discover.py          自动探测逻辑
├── ssh.conf             配置（600）
├── ssh.conf.example     配置模板
├── templates/index.html xterm.js 前端
├── static/              xterm.js 本地资源（不依赖外网 CDN）
└── .ssh_cache.json      上次成功的连接方式（加速，失效自动重探）
```

## 安全提示

- 监听 `0.0.0.0:39622`，任何能连到该端口的人都能看到登录页，请务必修改善用口令。
- 登录成功后后端用本机密钥免密登录 root，等价于外部拿到 root shell，不建议长期对公网裸开；如条件允许，限制来源 IP 或改成只监听内网。
