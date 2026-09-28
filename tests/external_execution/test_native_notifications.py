# SPDX-License-Identifier: MIT
"""Actual C routing adapter; protocol dispatch, Darwin ABI and kernel IO are doubles."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'Packages/ExternalExecution/Sources/CExternalRoute'
FIXTURES = Path(__file__).parent / 'fixtures'
HEADERS = '''#include <sys/socket.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <netinet/in.h>
#include <mach/mach_time.h>
'''

class NativeNotificationTests(unittest.TestCase):
    def compile_run(self, legacy=False, optimized=False):
        source = (SOURCE / 'external_route.c').read_text()
        self.assertEqual(source.count('#if defined(__APPLE__)\n'), 1)
        self.assertEqual(source.count(HEADERS), 1)
        if legacy:
            self.assertEqual(source.count('socket(PF_ROUTE, SOCK_RAW, 0)'), 1)
            source = source.replace('socket(PF_ROUTE, SOCK_RAW, 0)', 'socket(PF_ROUTE, SOCK_RAW, AF_INET)')
        source = source.replace('#if defined(__APPLE__)\n', '#if 1 /* EXPLICIT TEST COPY */\n')
        source = source.replace(HEADERS, '#include "darwin_fixture.h"\n')
        with tempfile.TemporaryDirectory(prefix='external-notifications-') as folder:
            root = Path(folder)
            (root / 'actual_external_route.c').write_text(source)
            for name in ('darwin_fixture.h', 'route_harness.c', 'route_notifications_harness.c'):
                shutil.copyfile(FIXTURES / name, root / name)
            executable = root / 'harness'
            cmd = ['cc', '-std=c11', '-D_DEFAULT_SOURCE', '-Wall', '-Wextra', '-Werror',
                   '-O2' if optimized else '-O0', '-I', str(SOURCE / 'include'),
                   str(root / 'route_notifications_harness.c'), '-o', str(executable)]
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            p = subprocess.run([str(executable)] + (['legacy'] if legacy else []),
                               capture_output=True, text=True, timeout=15)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertIn('legacy-dispatch=REPRODUCED' if legacy else 'routing-notifications=PASS', p.stdout)
            print(p.stdout.strip())

    def test_notifications_debug(self):
        self.compile_run()

    def test_notifications_optimized(self):
        self.compile_run(optimized=True)

    def test_legacy_protocol_filter_reproduces_installed_route_without_ack(self):
        self.compile_run(legacy=True)

if __name__ == '__main__':
    unittest.main()
