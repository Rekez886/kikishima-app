"""Source-level wiring checks for the one-shot MLX warm-up.

The runtime behaviour lives in tests/mlx_warmup/main.swift; this file only asserts
that the production wiring keeps the properties the runtime test cannot see:
one trigger point, off-main inference, no cancellation of the warm-up, no UI, no
logging, no networking, and a metallib check next to the executable.
"""
from pathlib import Path
import re
import sys

translator = Path('Sources/Kikishima/MLXTranslator.swift').read_text()
warmup_path = Path('Sources/Kikishima/MLXWarmup.swift')
warmup = warmup_path.read_text()

errors = []


def check(condition, message):
    if not condition:
        errors.append(message)


def code_only(source):
    """Strip comments so documentation may name API types without tripping checks."""
    source = re.sub(r'/\*[\s\S]*?\*/', '', source)
    return re.sub(r'//[^\n]*', '', source)


def braced_body(source, marker, start=0):
    """Return the braces-balanced body starting at the first '{' after marker."""
    open_at = source.index('{', source.index(marker, start))
    depth, index = 1, open_at + 1
    while depth and index < len(source):
        depth += (source[index] == '{') - (source[index] == '}')
        index += 1
    if depth:
        raise SystemExit('FAIL mlx warmup wiring: unbalanced braces after ' + marker)
    return source[open_at + 1:index - 1]


# --- load(): ready -> warm-up, on the success path only -----------------------
load_body = braced_body(translator, 'func load()')
ready_at = load_body.find('state = .ready')
flag_at = load_body.find('forKey: "mlxModelReady"')
perform_at = load_body.find('MLXWarmup.shared.perform =')
schedule_at = load_body.find('MLXWarmup.shared.scheduleAfterReady()')
catch_at = load_body.find('} catch {')

check(ready_at >= 0, 'load() must still set state = .ready')
check(flag_at >= 0, 'load() must still persist mlxModelReady')
check(perform_at >= 0, 'load() must inject the warm-up closure')
check(schedule_at >= 0, 'load() must schedule the warm-up')
if ready_at >= 0 and schedule_at >= 0:
    check(ready_at < schedule_at, 'warm-up must be scheduled only after state = .ready')
if flag_at >= 0 and schedule_at >= 0:
    check(flag_at < schedule_at, 'warm-up must be scheduled only after mlxModelReady is persisted')
if perform_at >= 0 and schedule_at >= 0:
    check(perform_at < schedule_at, 'the warm-up closure must be injected before scheduling')
if catch_at >= 0 and schedule_at >= 0:
    check(schedule_at < catch_at, 'warm-up must be scheduled on the success path, not after the failure catch')
failure_path = load_body[catch_at:] if catch_at >= 0 else ''
check('MLXWarmup' not in failure_path, 'the load() failure path must not touch the warm-up')

# --- translate(): no cancellation and no waiting for the warm-up --------------
translate_body = braced_body(translator, 'func translate(')
check('MLXWarmup' not in translate_body,
      'translate() must not cancel or await the warm-up; real translations run in parallel')
check('generate(' in translate_body, 'translate() must run through the shared generate()')
check(translator.find('cancelForRealTranslation') < 0, 'there is no warm-up cancellation API')

# --- inference must not be MainActor-isolated ---------------------------------
generate_at = translator.find('func generate(')
check(generate_at >= 0, 'the shared generate() must exist')
declaration = translator[max(0, generate_at - 200):generate_at]
check('nonisolated' in declaration, 'generate() must be nonisolated so inference stays off the main actor')
check('static' in declaration, 'generate() must be a static (nonisolated) helper')
check('@MainActor' not in declaration, 'generate() must not be MainActor-isolated')
generate_body = braced_body(translator, 'func generate(')
check(re.search(r'group\.addTask\s*\{[\s\S]*?session\.respond', generate_body),
      'session.respond must run inside a group.addTask closure, off the main actor')
check(generate_body.count('generate(') == 0, 'generate() must not call itself')

# --- one shared inference path for translate() and the warm-up ---------------
check(translator.count('generate(') >= 3,
      'translate(), the warm-up closure and the definition must share generate()')
warmup_closure = load_body[perform_at:schedule_at] \
    if perform_at >= 0 and schedule_at >= 0 and perform_at < schedule_at else ''
check('MLXModelController.generate(' in warmup_closure,
      'the warm-up closure must use the shared generate()')
check('MLXWarmup.prompt' in warmup_closure, 'the warm-up must use the fixed prompt')
check('translate(' not in warmup_closure, 'the warm-up must not go through translate() (no model reload)')
check('MLXWarmup.shared.load' not in warmup_closure, 'the warm-up must not load the model again')

# --- MLXWarmup: no MLX, no UI, no logging, no networking ----------------------
warmup_code = code_only(warmup)
check('import MLX' not in warmup_code, 'MLXWarmup must not import MLX')
check('ChatSession' not in warmup_code, 'MLXWarmup must not build a ChatSession; the closure is injected')
check('translate(' not in warmup_code, 'MLXWarmup must not call translate()')
check('tr("' not in warmup_code and 'tr("' not in code_only(warmup_closure),
      'the warm-up must not add localisable UI strings')
for token in ['print(', 'NSLog', 'os_log', 'Logger', 'URLSession', 'https://',
              'SwiftUI', 'AppKit', 'NSAlert', 'NSWindow', 'ProgressView']:
    check(token not in warmup_code, f'MLXWarmup must not use {token}')
check('Task.detached' in warmup_code, 'the warm-up must run in a detached task')
check('priority: .utility' in warmup_code, 'the warm-up must run at utility priority')
check('Task {' not in warmup_code and 'Task(priority' not in warmup_code,
      'the warm-up must not start on the main actor with Task {}')
check(re.search(r'static let timeout: TimeInterval = 20\b', warmup_code),
      'the warm-up timeout must be 20 seconds')
check('.started' in warmup_code, 'Outcome must include .started')
check('static let prompt' in warmup_code, 'the warm-up prompt must be a fixed constant')

# --- metallib must be checked next to the executable -------------------------
check('Bundle.main.executableURL' in warmup_code, 'metallib check must start from Bundle.main.executableURL')
check('deletingLastPathComponent' in warmup_code, 'metallib check must look next to the executable')
check('"mlx.metallib"' in warmup_code, 'metallib check must look for mlx.metallib')
check('.isRegularFile' in warmup_code and 'fileSize' in warmup_code,
      'metallib check must reject missing, non-file and empty files')

if errors:
    for error in errors:
        print('FAIL mlx warmup wiring: ' + error, file=sys.stderr)
    sys.exit(1)
print('PASS mlx warmup wiring: one-shot trigger, off-main inference, no cancel, no UI/log/network')
