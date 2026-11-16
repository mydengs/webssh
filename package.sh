#!/usr/bin/env bash
# 重新打离线包：把 webssh/ 源码 + deploy.sh + 文档 + service 模板打成 tar.gz
# 用法：bash package.sh
set -euo pipefail
PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(grep -m1 'WEBSSH_VERSION=' "$PKG_DIR/webssh/app.py" 2>/dev/null | cut -d'"' -f2 || true)"
VERSION="${VERSION:-1.0.0}"
OUT="$PKG_DIR/webssh-${VERSION}.tar.gz"

cd "$PKG_DIR"
rm -f "$PKG_DIR"/webssh-*.tar.gz
tar --exclude='__pycache__' --exclude='*.pyc' --exclude='.ssh_cache.json' \
    --exclude='venv' --exclude='*.log' \
    -czf "$OUT" webssh deploy.sh README.md DEPLOY.md webssh.service.tpl 2>/dev/null \
  || tar --exclude='__pycache__' -czf "$OUT" webssh deploy.sh README.md webssh.service.tpl

echo "[✓] 已生成：$OUT ($(du -h "$OUT" | cut -f1))"
tar -tzf "$OUT" | head -20
