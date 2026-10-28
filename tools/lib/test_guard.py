"""Test-only disk gate and owned scratch space. Never sweeps existing temp files."""
from contextlib import contextmanager
from pathlib import Path
import math
import os
import shutil
import signal
import sys
import tempfile
sys.dont_write_bytecode = True

GIB = 1024 ** 3

def require_free_space(script):
    try:
        minimum = float(os.environ.get('KK_MIN_FREE_GB', '20'))
        if not math.isfinite(minimum) or minimum < 0:raise ValueError()
    except ValueError:
        raise SystemExit('KK_MIN_FREE_GB 必须为非负有限数值')
    free = shutil.disk_usage(Path(script).resolve().parent).free / GIB
    if free < minimum:
        print(f'磁盘剩余 {free:.1f} GiB，低于 {minimum:g} GiB，停止', file=sys.stderr)
        raise SystemExit(2)

def install_exit_signals():
    previous = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
    def stop(sig, _frame):
        # Allow finally blocks to finish even when the user presses Ctrl-C again.
        for item in previous:signal.signal(item, signal.SIG_IGN)
        raise SystemExit(128 + sig)
    for sig in previous:signal.signal(sig, stop)
    return previous

def _remove_owned(path):
    # Called only with the exact result of our mkdtemp, never a caller's --output.
    raw = str(path)
    if not raw or path.is_symlink() or path.parent not in (Path('/tmp'), Path('/private/tmp')) or not path.name.startswith('kikishima-test.'):
        raise RuntimeError(f'拒绝清理非本次创建的临时目录：{raw!r}')
    shutil.rmtree(path)

class CreatedDirectory:
    """2026-10-19: directly remove only a temporary directory this script created.

    Creation must succeed without exist_ok. Keep its inode so a replacement or
    symlink can never turn cleanup into deletion of someone else's directory.
    """
    @classmethod
    def create(cls, path):
        path = Path(path).absolute()
        parent = path.parent.resolve()
        roots = (Path('/tmp').resolve(), Path(os.environ.get('TMPDIR', tempfile.gettempdir())).resolve())
        if not any(parent == root or parent.is_relative_to(root) for root in roots):
            raise RuntimeError(f'拒绝在临时目录外登记清理路径：{path}')
        path.mkdir()  # Existing paths are never adopted, overwritten or deleted.
        stat = path.lstat()
        owned = cls()
        owned.path, owned.parent, owned.identity = path, parent, (stat.st_dev, stat.st_ino)
        return owned

    def remove(self):
        if self.path.is_symlink() or self.path.parent.resolve() != self.parent:
            raise RuntimeError(f'拒绝清理被替换的临时路径：{self.path}')
        if not self.path.exists():return
        stat = self.path.lstat()
        if (stat.st_dev, stat.st_ino) != self.identity:
            raise RuntimeError(f'拒绝清理非本次创建的目录：{self.path}')
        shutil.rmtree(self.path)

@contextmanager
def guarded_workspace(script, output=None):
    require_free_space(script)
    previous = install_exit_signals()
    owned = None
    old_env = {key: os.environ.get(key) for key in ('TMPDIR', 'CLANG_MODULE_CACHE_PATH', 'PYTHONDONTWRITEBYTECODE')}
    old_tempdir = tempfile.tempdir
    try:
        # Always own a separate scratch root, even when the caller preserves
        # --output. Compiler intermediates must never accumulate with screenshots.
        owned = Path(tempfile.mkdtemp(prefix='kikishima-test.', dir='/tmp'))
        if output is None:
            root = owned
        else:
            root = Path(output).resolve()
            root.mkdir(parents=True, exist_ok=True)
        os.environ.update(TMPDIR=str(owned)+'/', CLANG_MODULE_CACHE_PATH=str(owned/'clang-cache'), PYTHONDONTWRITEBYTECODE='1')
        tempfile.tempdir = None
        yield root
    finally:
        try:
            if owned is not None:_remove_owned(owned)
        finally:
            for key, value in old_env.items():
                if value is None:os.environ.pop(key, None)
                else:os.environ[key] = value
            tempfile.tempdir = old_tempdir
            for sig, handler in previous.items():signal.signal(sig, handler)

if __name__ == '__main__':
    if len(sys.argv) != 3 or sys.argv[1] != '--check':raise SystemExit('usage: test_guard.py --check SCRIPT')
    require_free_space(sys.argv[2])
