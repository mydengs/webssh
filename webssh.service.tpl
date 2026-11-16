[Unit]
Description=WebSSH - 浏览器访问本机 SSH 终端
Documentation=file://__APP_DIR__/README.md
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=__APP_DIR__
ExecStart=__PYTHON__ __APP_DIR__/app.py
Restart=always
RestartSec=3
Environment=WEBSSH_BIND=__BIND__
Environment=WEBSSH_PORT=__PORT__
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
