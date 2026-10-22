"""Real filesystem/signal checks. No app, models, credentials or normal preferences."""
from pathlib import Path
import json
import os
import signal
import stat
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
WORK = Path(sys.argv[1])
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / 'tools/lib'))
from test_guard import _remove_owned, require_free_space, CreatedDirectory
require_free_space(__file__)


def snapshot():
    return {p.name for p in Path('/tmp').iterdir()}


def no_leftovers(before, name, started):
    added = snapshot() - before
    if added:
        details = []
        for entry in sorted(added):
            try:
                info = (Path('/tmp') / entry).lstat()
                kind = ('符号链接' if stat.S_ISLNK(info.st_mode) else
                        '目录' if stat.S_ISDIR(info.st_mode) else
                        '文件' if stat.S_ISREG(info.st_mode) else '其他')
                details.append(f'{entry}: {kind}, uid={info.st_uid}, mtime={info.st_mtime - started:+.3f}s')
            except FileNotFoundError:
                details.append(f'{entry}: 诊断前已消失')
        raise AssertionError(f'{name}: /tmp 新增残留 {details}（只报告，不删除）')
    print('PASS', name, '/tmp 无新增残留')


def diagnose_owned(child):
    # Always diagnose the exact child before signalling. The sandbox may deny ps;
    # Popen still retains its unreaped child identity and actual command/poll state.
    evidence={'pid':child.pid,'argv':child.args,'poll':child.poll()}
    try:
        evidence['ps']=subprocess.run(['/bin/ps','-p',str(child.pid),'-o','pid=,command='],capture_output=True,text=True,check=False).stdout
    except PermissionError:evidence['ps']='sandbox denied; owned unreaped Popen child'
    print('child diagnostic',json.dumps(evidence),flush=True)


def reset_child_signals():
    # This test is single-threaded. Only the forked child changes disposition;
    # Bash must enter with defaults so its own traps can be installed.
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, signal.SIG_DFL)


def run_case(argv, expected, ready=None, send=None, env=None):
    started = time.time()
    before = snapshot()
    child = subprocess.Popen(argv, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             text=True, start_new_session=True, preexec_fn=reset_child_signals)
    try:
        if send is not None:
            deadline = time.monotonic() + 10
            while not ready.exists() and child.poll() is None and time.monotonic() < deadline:time.sleep(0.02)
            if not ready.exists():
                if child.poll() is None:
                    diagnose_owned(child)
                    os.killpg(child.pid, signal.SIGTERM)
                stdout, stderr = child.communicate(timeout=5)
                raise AssertionError(f'Child did not reach the guarded body: {argv}; '
                                     f'exit {child.returncode}\n{stdout}\n{stderr}')
            diagnose_owned(child)
            os.killpg(child.pid, send)
        stdout, stderr = child.communicate(timeout=30)
        if child.returncode != expected:
            raise AssertionError(f'{argv}: exit {child.returncode}, expected {expected}\n{stdout}\n{stderr}')
    finally:
        if child.poll() is None:
            diagnose_owned(child)
            os.killpg(child.pid, signal.SIGTERM)
            child.communicate(timeout=5)
    no_leftovers(before, f'{Path(argv[1]).name} exit={expected}', started)
    return stdout, stderr


# Use the same sourced trap implementation as every production test entry point.
shell = WORK / 'guard-fixture.sh'
shell.write_text('''#!/bin/bash
set -euo pipefail
source "$1/tools/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
printf '%s' "$KK_TEST_TMP_ROOT" > "$3"
printf payload > "$KK_TEST_TMP_ROOT/payload"
case "$2" in
  success) exit 0 ;;
  failure) exit 7 ;;
  interrupt) deadline=$((SECONDS + 10)); while (( SECONDS < deadline )); do sleep 1; done; exit 9 ;;
esac
''')
python = WORK / 'guard_fixture.py'
python.write_text('''from pathlib import Path
import sys, time, os
sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(sys.argv[1])/'tools/lib'))
from test_guard import guarded_workspace
explicit=Path(sys.argv[4]) if len(sys.argv)>4 else None
with guarded_workspace(__file__,output=explicit) as root:
    Path(sys.argv[3]).write_text(str(root))
    (root/'payload').write_text('payload')
    (Path(os.environ['TMPDIR'])/'compiler-intermediate').write_text('scratch')
    if sys.argv[2]=='failure':raise SystemExit(7)
    if sys.argv[2]=='interrupt':
        while True:time.sleep(1)
''')

baseline_started = time.time()
baseline = snapshot()
for fixture, executable in [(shell, '/bin/bash'), (python, sys.executable)]:
    for mode, code, sig in [('success',0,None),('failure',7,None),
                            ('interrupt',130,signal.SIGINT),('interrupt',143,signal.SIGTERM)]:
        ready = WORK / f'{fixture.name}-{mode}-{code}.ready'
        run_case([executable,str(fixture),str(ROOT),mode,str(ready)],code,ready=ready,send=sig)
        assert not Path(ready.read_text()).exists(), 'Owned scratch directory survived'

# Explicit user output is preserved on success, failure and both signals.
for mode, code, sig in [('success',0,None),('failure',7,None),
                        ('interrupt',130,signal.SIGINT),('interrupt',143,signal.SIGTERM)]:
    output = WORK / f'explicit-{code}'
    ready = WORK / f'explicit-{code}.ready'
    run_case([sys.executable,str(python),str(ROOT),mode,str(ready),str(output)],code,ready=ready,send=sig)
    assert (output/'payload').read_text() == 'payload'
    assert not (output/'compiler-intermediate').exists(), 'Compiler scratch polluted preserved output'
print('PASS 显式输出目录在成功、失败、INT、TERM 后均保留')

# Exercise the real preference writer and its shell cleanup on all exit paths.
def preference_snapshot():
    # Keep content and identity too: cleanup must not alter older runs' plists.
    return {p.name: (p.lstat(), p.read_bytes())
            for p in (Path.home() / 'Library/Preferences').glob(
                'kikishima-notch-default-test-*.plist')}


# Build once, before the signal-ready deadline starts. Cold Swift module caches
# can take more than ten seconds; readiness must measure the fixture, not compilation.
notch_binary = WORK / 'notch-default'
run_case(['/bin/bash', str(ROOT/'tools/test_notch_default.sh'),
          '--prepare', str(notch_binary)], 0)

# macOS arm64: Swift precondition failure is SIGTRAP; Bash reports 128 + 5.
for fault, code, sig in [('', 0, None), ('fail', 133, None), ('wait', 130, signal.SIGINT)]:
    prefs_before = preference_snapshot()
    ready = WORK / 'notch-wait.ready'
    env = os.environ.copy()
    env.pop('KK_NOTCH_TEST_FAULT', None)
    if fault:
        env['KK_NOTCH_TEST_FAULT'] = f'wait:{ready}' if fault == 'wait' else fault
    try:
        stdout, stderr = run_case(['/bin/bash', str(ROOT/'tools/test_notch_default.sh'),
                                   '--run-prepared', str(notch_binary)], code,
                                  ready=ready, send=sig, env=env)
        if fault == 'fail':
            assert 'injected notch default failure' in stderr, (
                f'Notch test crashed before the intended fault:\n{stdout}\n{stderr}')
    finally:
        prefs_after = preference_snapshot()
        added = prefs_after.keys() - prefs_before.keys()
        assert not added, f'notch default 新增偏好残留 {sorted(added)}（只报告，不删除）'
        changed = {name for name, (info, content) in prefs_before.items()
                   if name not in prefs_after
                   or (info.st_dev, info.st_ino, info.st_mtime_ns, content) !=
                      (prefs_after[name][0].st_dev, prefs_after[name][0].st_ino,
                       prefs_after[name][0].st_mtime_ns, prefs_after[name][1])}
        assert not changed, f'notch default 改动了已有偏好 {sorted(changed)}'
    print('PASS notch default preferences', fault or 'success', '新增 0 个')

# Direct cleanup needs positive creation ownership, including an unchanged inode.
# These are ordinary folders containing text fixtures, never executable apps.
owned = CreatedDirectory.create(WORK/'owned-test-app')
(owned.path/'fixture').write_text('script-created')
owned.remove()
assert not owned.path.exists()
existing = WORK/'preexisting-test-app';existing.mkdir()
(existing/'keep').write_text('not adopted')
try:CreatedDirectory.create(existing)
except FileExistsError:pass
else:raise AssertionError('Existing path was adopted for direct deletion')
assert (existing/'keep').read_text()=='not adopted'
replaced=CreatedDirectory.create(WORK/'replaced-test-app')
replaced.path.rename(WORK/'original-owned-directory')
replaced.path.mkdir()
(replaced.path/'keep').write_text('replacement')
try:replaced.remove()
except RuntimeError:pass
else:raise AssertionError('Replacement directory was deleted')
assert (replaced.path/'keep').read_text()=='replacement'
linked=CreatedDirectory.create(WORK/'symlink-test-app')
linked.path.rename(WORK/'original-symlink-directory')
linked.path.symlink_to(existing,target_is_directory=True)
try:linked.remove()
except RuntimeError:pass
else:raise AssertionError('Symlink was deleted or followed')
assert (existing/'keep').read_text()=='not adopted'
print('PASS 自建目录直接删除；已有目录、替换目录与符号链接不接管删除')

# A real existing fast test; compilers and caches must stay inside its owned root.
run_case(['/bin/bash',str(ROOT/'tools/test_caption_preview.sh')],0)
# Exercise both gates using the real free-space reading, never faking disk usage.
env = os.environ.copy();env['KK_MIN_FREE_GB']='1000000000'
gated_commands=[['/bin/bash',str(script)] for script in sorted((ROOT/'tools').glob('test_*.sh'))]
gated_commands += [[sys.executable,str(ROOT/'Resources/l10n/gen.py'),'--check']]
for argv in gated_commands:
    stdout, stderr = run_case(argv,2,env=env)
    assert '磁盘剩余 ' in stderr and '低于 1e+09 GiB，停止' in stderr
print('PASS Shell/Python 空间不足均非零退出，且未创建临时目录')

for unsafe in [Path('/tmp'), WORK/'explicit-0']:
    try:_remove_owned(unsafe)
    except RuntimeError:pass
    else:raise AssertionError('Unsafe cleanup path accepted')
assert (WORK/'explicit-0/payload').exists()
# Verify coverage without executing any UI/e2e scripts or unsafe historical tests.
for script in (ROOT/'tools').glob('test_*.sh'):
    text=script.read_text()
    assert 'kk_test_init "${BASH_SOURCE[0]}"' in text, script
    assert '$(mktemp ' not in text, script
    subprocess.run(['/bin/bash','-n',str(script)],check=True)
no_leftovers(baseline, '完整卫生自测', baseline_started)
print('PASS test hygiene: cleanup/gates/signals/explicit-output/real-fast-test/entrypoint coverage')
