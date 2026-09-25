#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read-only aggregate diagnostics. Never installs, builds, fetches or reads VPN data."""
from __future__ import annotations
import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import platform
import re
import shutil
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/wireguard'))
from build import Commands, BuildError, clean_environment, LOCK_PATH


@dataclass(frozen=True)
class Check:
    name: str
    ok: bool
    detail: str
    engine_only: bool = False


def version_at_least(text: str, major: int) -> bool:
    match = re.match(r'^(\d+)(?:\.\d+)*$', text.strip())
    return bool(match and int(match[1]) >= major)


def inspect(commands: Commands, lock: dict) -> list[Check]:
    """The command runner is injected for tests; no compiler or live service is used there."""
    result = []
    is_mac = platform.system() == 'Darwin'
    result.append(Check('platform', is_mac and platform.machine() == 'arm64',
        '需要 Apple Silicon Mac；不支持 Intel 或 Rosetta 下的 x86_64 工具链。'))
    result.append(Check('python', sys.version_info >= (3, 9),
        'Python ' + platform.python_version() + '；仅构建/测试工具使用，需要 3.9+。'))

    def check(name, args, accept, hint):
        try:
            value = commands.run(args, timeout=15)
            ok = accept(value)
        except (BuildError, OSError, ValueError):
            ok = False
        result.append(Check(name, ok, hint))

    if is_mac:
        check('macos', ['/usr/bin/sw_vers', '-productVersion'], lambda x: version_at_least(x, 26),
              '需要 macOS 26+。')
        check('xcode', ['/usr/bin/xcodebuild', '-version'], lambda x: bool(re.search(r'^Xcode (\d+)', x, re.M)),
              '需要完整 Xcode；仅 Command Line Tools 不够。请在 Xcode 中完成首次设置。')
        check('sdk', ['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-version'], lambda x: version_at_least(x, 26),
              '需要已选中 Xcode 中的 macOS SDK 26+；本工具不切换开发目录。')
        check('swift', ['/usr/bin/xcrun', 'swift', '--version'],
              lambda x: bool(re.search(r'Swift version (?:[6-9]|[1-9][0-9])\.', x)),
              '需要 Swift 6+，与原生工程使用同一套 Xcode。')
        check('clang', ['/usr/bin/xcrun', '--find', 'clang'], lambda x: bool(x.strip()),
              'Xcode 的 Clang 必须可用。')
    else:
        result.append(Check('apple_sdk', False, '当前不是 macOS，不调用 Apple 工具；原生编译不可用。'))
    git = shutil.which('git')
    if git:
        check('git', [git, '--version'], lambda x: x.startswith('git version '), '需要可运行的 Git；只查询版本，不访问远端。')
    else:
        result.append(Check('git', False, '未找到 Git；请检查 Xcode 工具或 PATH。'))
    go = shutil.which('go')
    versions = lock['go_toolchains']
    if not go:
        result.append(Check('go', False, '未找到 Go；仅引擎构建需要。已安装时请重开终端并检查 PATH。', True))
    else:
        try:
            actual = commands.run([go, 'env', 'GOVERSION'], timeout=15)
            safe = actual if re.fullmatch(r'go\d+\.\d+(?:\.\d+)?', actual) else '无法识别'
            result.append(Check('go', actual in versions, '当前 ' + safe + '；候选要求 ' + ', '.join(versions) + '。', True))
        except (BuildError, OSError):
            result.append(Check('go', False, 'Go 无法运行；不自动下载工具链。', True))
    return result


def report(checks: list[Check], target: str) -> int:
    app_ok = all(x.ok for x in checks if not x.engine_only)
    engine_ok = app_ok and all(x.ok for x in checks)
    for item in checks:
        status = 'OK' if item.ok else ('OPTIONAL' if item.engine_only and target == 'app' else 'MISSING')
        print('[' + status + '] ' + item.name + '：' + item.detail)
    print('schema=dev-doctor-v1')
    print('app_environment=' + ('PASS' if app_ok else 'BLOCKED'))
    print('engine_environment=' + ('PASS' if engine_ok else 'BLOCKED'))
    print('compile_link=NOT_RUN\nsoftware_installation=NOT_REQUESTED\nnetwork_settings=NOT_APPLIED')
    if not all(x.ok for x in checks if x.engine_only):
        print('Go 安装及固定版本说明：docs/development.md；界面构建不需要 Go。')
    ready = engine_ok if target == 'engine' else app_ok
    if ready:
        print('下一步：' + ('/bin/bash dev.sh engine --fetch' if target == 'engine' else '/bin/bash dev.sh run'))
    else:
        print('补齐 MISSING 项后重试：/bin/bash dev.sh doctor ' + target)
    return 0 if ready else 2


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', choices=['app', 'engine'], nargs='?', default='app')
    args = parser.parse_args()
    try:
        lock = json.loads(LOCK_PATH.read_text())
        if not lock['go_toolchains'] or not all(re.fullmatch(r'go\d+\.\d+\.\d+', x) for x in lock['go_toolchains']):
            raise ValueError('invalid lock')
        return report(inspect(Commands(clean_environment()), lock), args.target)
    except (KeyError, ValueError, OSError, TypeError):
        print('E_DOCTOR_LOCK：无法读取固定工具链清单；请保留本地修改并核查仓库完整性。', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
