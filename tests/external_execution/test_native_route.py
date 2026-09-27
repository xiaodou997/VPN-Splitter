# SPDX-License-Identifier: MIT
"""Execute the complete native C adapter with explicit fake Darwin/kernel declarations."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'Packages/ExternalExecution/Sources/CExternalRoute'
FIXTURES = Path(__file__).parent / 'fixtures'

class NativeRouteTests(unittest.TestCase):
    def test_actual_adapter_with_simulated_kernel(self):
        with tempfile.TemporaryDirectory(prefix='external-route-test-') as directory:
            work = Path(directory)
            source = (SOURCE / 'external_route.c').read_text()
            start = '#if defined(__APPLE__)\n'
            headers = '''#include <sys/socket.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <netinet/in.h>
#include <mach/mach_time.h>
'''
            self.assertEqual(source.count(start), 1); self.assertEqual(source.count(headers), 1)
            # Test copy only. Product compilation always uses the real SDK headers.
            source = source.replace(start, '#if 1 /* EXPLICIT TEST COPY */\n').replace(headers, '#include "darwin_fixture.h"\n')
            (work / 'actual_external_route.c').write_text(source)
            for name in ['darwin_fixture.h', 'route_harness.c']: shutil.copyfile(FIXTURES / name, work / name)
            command = ['cc', '-std=c11', '-D_DEFAULT_SOURCE', '-Wall', '-Wextra', '-Werror',
                       '-I', str(SOURCE / 'include'), str(work / 'route_harness.c'), '-o', str(work / 'harness')]
            compiled = subprocess.run(command, capture_output=True, text=True, timeout=30)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            run = subprocess.run([str(work / 'harness')], capture_output=True, text=True, timeout=15)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn('darwin_kernel_io=TEST_DOUBLES', run.stdout); print(run.stdout.strip())

if __name__ == '__main__': unittest.main()
