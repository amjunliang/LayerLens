"""Exercise the actual guardian with disposable commands, never system services."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

GUARDIAN = str(Path(__file__).resolve().parents[1] / "build/lease-guardian")


def await_value(path):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if path.exists() and path.read_text().strip():
            return int(path.read_text())
        time.sleep(0.02)
    raise AssertionError(f"No process ID written to {path}")


def alive(pid):
    result = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(pid)],
                            capture_output=True, text=True)
    return bool(result.stdout.strip()) and not result.stdout.strip().startswith("Z")


def run_case(mode, directory):
    child_file = directory / (mode + ".child")
    guardian_file = directory / (mode + ".guardian")
    child = (
        "import os,signal,time,pathlib; "
        "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
        f"pathlib.Path({str(child_file)!r}).write_text(str(os.getpid())); "
        "time.sleep(60)"
    )
    parent_code = f"""
import os,pathlib,subprocess,sys
p=subprocess.Popen([{GUARDIAN!r},str(os.getpid()),{sys.executable!r},'-c',{child!r}],stdin=subprocess.PIPE)
pathlib.Path({str(guardian_file)!r}).write_text(str(p.pid))
sys.stdin.read(1)
p.stdin.close()
p.wait(timeout=3)
"""
    parent = subprocess.Popen([sys.executable, "-c", parent_code], stdin=subprocess.PIPE)
    guardian_pid = child_pid = None
    try:
        guardian_pid = await_value(guardian_file)
        child_pid = await_value(child_file)
        start = time.monotonic()
        if mode == "normal":
            parent.stdin.close()
        elif mode == "parent-kill":
            parent.kill()
        else:
            os.kill(guardian_pid, signal.SIGTERM)
        deadline = start + 3
        while time.monotonic() < deadline and (alive(child_pid) or alive(guardian_pid)):
            time.sleep(0.02)
        assert not alive(child_pid), f"{mode}: command survived"
        assert not alive(guardian_pid), f"{mode}: guardian survived"
        print(f"PASS {mode}: both exited in {time.monotonic() - start:.3f}s")
    finally:
        if parent.poll() is None:
            parent.stdin.close()
        parent.wait(timeout=4)
        for pid in (guardian_pid, child_pid):
            if pid and alive(pid):
                os.kill(pid, signal.SIGKILL)


with tempfile.TemporaryDirectory(prefix="guardian-", dir="/private/tmp/LayerLens-release-build") as folder:
    for case in ("normal", "parent-kill", "guardian-term"):
        run_case(case, Path(folder))
