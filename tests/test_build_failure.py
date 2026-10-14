"""A failed compiler must stop the real packaging script before copying stale output."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class BuildFailureTests(unittest.TestCase):
    def test_compile_failure_does_not_package_stale_binary(self):
        script = Path(__file__).resolve().parents[1] / 'build.sh'
        with tempfile.TemporaryDirectory(prefix='kikishima-build-test-') as root:
            root = Path(root)
            (root / 'build.sh').write_bytes(script.read_bytes())
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            compiler = bin_dir / 'swift'
            compiler.write_text('#!/bin/sh\necho "simulated compiler failure" >&2\nexit 42\n')
            compiler.chmod(0o755)
            stale = root / '.build/arm64-apple-macosx/release/Kikishima'
            stale.parent.mkdir(parents=True)
            stale.write_text('OLD_BINARY')
            stale.chmod(0o755)
            result = subprocess.run(
                ['bash', str(root / 'build.sh')], capture_output=True, text=True,
                env={**os.environ, 'PATH': f'{bin_dir}:{os.environ["PATH"]}'},
                timeout=10,
            )
            self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
            self.assertFalse((root / 'build/Kikishima.app/Contents/MacOS/Kikishima').exists())


if __name__ == '__main__':
    unittest.main()
