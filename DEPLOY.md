WebSSH 一键部署包
=================

三步走：

  1. scp webssh-1.0.0.tar.gz root@目标服务器:/root/
  2. cd /root && tar -xzf webssh-1.0.0.tar.gz
  3. sudo bash deploy.sh

部署完成后屏幕会直接打印访问地址和登录口令。

详细说明见 README.md，常见问题见 README.md 第八节「故障排查」。

文件清单
--------
  deploy.sh              一键部署/卸载/状态脚本
  README.md              完整文档（部署、配置、排障、安全）
  webssh.service.tpl     systemd 服务模板
  webssh/                程序源码
    app.py               Flask + flask-sock + paramiko
    discover.py          自动探测本机 SSH 参数
    ssh.conf.example     配置模板
    templates/index.html xterm.js 前端
    static/              xterm 本地资源（不依赖外网 CDN）
  package.sh             重新打包脚本（改了源码后执行）

常用命令
--------
  sudo bash deploy.sh                          # 默认安装（39622 端口，随机口令）
  sudo bash deploy.sh -p 8080 -w 'MyPw@2026'   # 换端口 + 指定口令
  sudo bash deploy.sh -b 127.0.0.1 -p 8080     # 只允许本机访问
  sudo bash deploy.sh -u ops                   # 用普通用户登录
  sudo bash deploy.sh -s webssh2 -d /srv/webssh2 -p 39623   # 同机第二个实例
  sudo bash deploy.sh --status                 # 查看状态
  sudo bash deploy.sh --uninstall              # 卸载
  bash package.sh                              # 重新打离线包
