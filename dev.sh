#!/bin/bash
# SPDX-License-Identifier: MIT
# One development entrypoint. No installation, Git writes or implicit downloads.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MODE=${1:-doctor}
if [[ $# -gt 0 ]]; then shift; fi
usage() {
    cat <<'TEXT'
用法：/bin/bash dev.sh [doctor [app|engine]|run|test|engine [--fetch]|engine-flow [--fetch]|engine-test|provider-test|packet-flow-test|provider-build [--fetch] [--sign]|provider-runtime-test|external-run|external-build|external-test|external-executor-build|external-execution-test|external-helper-build [--identity NAME --team-id TEAM] [--route-trial]|external-helper-test|external-flow-build|external-flow-test]
  doctor          只读检查，一次列出全部环境问题；默认检查界面开发环境
  doctor engine   检查原生引擎构建环境，包括 Go；不下载、不构建
  run             构建并打开 LocalDev；不需要 Go，不连接 VPN
  test            运行 LocalDev 的离线回归
  engine --fetch  下载固定公开源码/模块，编译链接候选；不运行产物
  engine          仅使用已有缓存构建候选，缺缓存即停止
  engine-flow     编译公共 packetFlow 数据通道候选；可加 --fetch；不运行产物
  engine-test     运行设置完成门控和构建工具离线测试；不需要 Go
  provider-test   运行正式启动元数据与入口离线测试；不连接 VPN
  packet-flow-test 运行数据包桥接离线测试；需要已有 Go/Swift/C 编译器，不安装工具
  provider-build  构建集成 packetFlow 的正式 App/扩展，默认 unsigned；--fetch 下载固定依赖，--sign 使用本地签名；不安装、不启动
  provider-runtime-test 运行正式生命周期、设置门控与运行授权离线回归；不修改网络
  external-run    构建并打开第三方 VPN 只读识别/规则预览；无需开发签名或 Go
  external-build  只编译 External 开发预览，不打开、不检测网络
  external-test   External 纯逻辑与入口离线回归，不修改网络
  external-executor-build 仅编译有限前台路由执行器，不运行、不提权、不安装 Helper
  external-execution-test 运行有限执行/撤销与持久化标记离线回归，不修改网络
  external-helper-build 构建独立控制 App/受限 Helper；默认不可授权、不安装、不运行；签名/试写显式选择
  external-helper-test 会话、身份合同、客户端/界面与构建离线回归，不注册服务或修改网络
  external-flow-build 编译 FLOW-01 Transparent Proxy 探针库；不打包/签名/安装/启动扩展
  external-flow-test 规则 first-match 与 provider 合同离线回归；不激活 Network Extension
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
    engine-flow)
        [[ $# == 0 || ( $# == 1 && $1 == --fetch ) ]] || { usage >&2; exit 2; }
        require_python
        python3 "$ROOT/tools/dev/doctor.py" engine
        exec /bin/bash "$ROOT/tools/wireguard/build.sh" build --packet-flow "$@"
        ;;
    packet-flow-test)
        [[ $# == 0 ]] || { usage >&2; exit 2; }
        require_python
        exec python3 -m unittest discover -s "$ROOT/tests/packet_flow" -v
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
    provider-build)
        require_python
        exec python3 "$ROOT/tools/provider/build-runtime.py" "$@"
        ;;
    provider-runtime-test)
        [[ $# == 0 ]] || { usage >&2; exit 2; }
        require_python
        exec /bin/bash "$ROOT/tools/provider/runtime-test.sh"
        ;;
    external-run|external-build)
        [[ $# == 0 ]] || { usage >&2; exit 2; }
        require_python
        exec python3 "$ROOT/tools/external/build.py" "${MODE#external-}"
        ;;
    external-test)
        [[ $# == 0 ]] || { usage >&2; exit 2; }
        require_python
        exec /bin/bash "$ROOT/tools/external/test.sh"
        ;;
    external-executor-build)
        [[ $# == 0 ]] || { usage >&2; exit 2; }
        require_python
        exec python3 "$ROOT/tools/external/executor-build.py"
        ;;
    external-execution-test)
        [[ $# == 0 ]] || { usage >&2; exit 2; }
        require_python
        exec /bin/bash "$ROOT/tools/external/execution-test.sh"
        ;;
    external-helper-build)
        require_python
        exec python3 "$ROOT/tools/external/helper-build.py" "$@"
        ;;
    external-helper-test)
        [[ $# == 0 ]] || { usage >&2; exit 2; }
        require_python
        exec /bin/bash "$ROOT/tools/external/helper-test.sh"
        ;;
    external-flow-build)
        [[ $# == 0 ]] || { usage >&2; exit 2; }
        require_python
        exec python3 "$ROOT/tools/external/flow-build.py"
        ;;
    external-flow-test)
        [[ $# == 0 ]] || { usage >&2; exit 2; }
        require_python
        exec /bin/bash "$ROOT/tools/external/flow-test.sh"
        ;;
    help|-h|--help) usage ;;
    *) usage >&2; exit 2 ;;
esac
