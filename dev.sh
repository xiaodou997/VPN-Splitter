#!/bin/bash
# SPDX-License-Identifier: MIT
# One development entrypoint. No installation, Git writes or implicit downloads.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MODE=${1:-doctor}
if [[ $# -gt 0 ]]; then shift; fi
usage() {
    cat <<'TEXT'
用法：/bin/bash dev.sh [doctor [app|engine]|run|test|engine [--fetch]|engine-test|provider-test]
  doctor          只读检查，一次列出全部环境问题；默认检查界面开发环境
  doctor engine   检查原生引擎构建环境，包括 Go；不下载、不构建
  run             构建并打开 LocalDev；不需要 Go，不连接 VPN
  test            运行 LocalDev 的离线回归
  engine --fetch  下载固定公开源码/模块，编译链接候选；不运行产物
  engine          仅使用已有缓存构建候选，缺缓存即停止
  engine-test     运行设置完成门控和构建工具离线测试；不需要 Go
  provider-test   运行正式启动元数据与入口离线测试；不连接 VPN
不需要历史补丁或 ZIP；本入口不执行 git pull 或安装任何软件。
TEXT
}
require_python() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo 'E_PYTHON：开发工具需要 Python 3.9+；请先安装或检查 PATH。应用运行不需要 Python。' >&2
        exit 2
    fi
    if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'; then
        echo 'E_PYTHON：当前 Python 版本低于 3.9；请使用受支持的 Python 3。不会自动安装。' >&2
        exit 2
    fi
    export PYTHONDONTWRITEBYTECODE=1
}
case "$MODE" in
    doctor)
        [[ $# -le 1 && ${1:-app} =~ ^(app|engine)$ ]] || { usage >&2; exit 2; }
        require_python
        exec python3 "$ROOT/tools/dev/doctor.py" "${1:-app}"
        ;;
    run)
        [[ $# == 0 ]] || { usage >&2; exit 2; }
        exec /bin/bash "$ROOT/tools/localdev/build.sh" run
        ;;
    test)
        [[ $# == 0 ]] || { usage >&2; exit 2; }
        require_python
        exec /bin/bash "$ROOT/tools/localdev/test.sh"
        ;;
    engine)
        [[ $# == 0 || ( $# == 1 && $1 == --fetch ) ]] || { usage >&2; exit 2; }
        require_python
        python3 "$ROOT/tools/dev/doctor.py" engine
        exec /bin/bash "$ROOT/tools/wireguard/build.sh" build "$@"
        ;;
    engine-test)
        [[ $# == 0 ]] || { usage >&2; exit 2; }
        require_python
        exec /bin/bash "$ROOT/tools/wireguard/test.sh"
        ;;
    provider-test)
        [[ $# == 0 ]] || { usage >&2; exit 2; }
        require_python
        exec /bin/bash "$ROOT/tools/provider/test.sh"
        ;;
    help|-h|--help) usage ;;
    *) usage >&2; exit 2 ;;
esac
