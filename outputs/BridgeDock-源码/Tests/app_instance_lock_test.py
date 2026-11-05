"""Cross-process exclusion, crash recovery and child descriptor isolation."""
import pathlib
import select
import subprocess
import sys
import tempfile
import time

binary = str(pathlib.Path(sys.argv[1]).resolve())
children = []


def launch(mode, directory):
    process = subprocess.Popen([binary, mode, str(directory)], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    children.append(process)
    return process


def result(process):
    assert select.select([process.stdout], [], [], 5)[0], "fixture did not respond"
    line = process.stdout.readline().strip()
    assert line, process.stderr.read()
    return line


def probe(directory):
    process = launch("probe", directory)
    line = result(process)
    assert process.wait(timeout=5) == 0
    return line


try:
    with tempfile.TemporaryDirectory(prefix="bridgedock-instance-tests-") as root:
        directory = pathlib.Path(root) / "profile"
        directory.mkdir()
        state = directory / "state.json"
        state.write_text('{"test":"keep existing configuration"}')
        owner = launch("hold", directory)
        assert result(owner) == f"OWNER {owner.pid}"
        lock_file = directory / "app-instance.lock"
        assert lock_file.stat().st_mode & 0o777 == 0o600
        assert probe(directory) == f"OCCUPIED {owner.pid}"
        assert lock_file.read_text().strip() == str(owner.pid)
        assert state.read_text() == '{"test":"keep existing configuration"}'
        alias = pathlib.Path(root) / "alias"
        alias.symlink_to(directory, target_is_directory=True)
        assert probe(alias) == f"OCCUPIED {owner.pid}", "path aliases share ownership"
        assert probe(pathlib.Path(root) / "independent").startswith("OWNER ")
        owner.stdin.write("\n")
        owner.stdin.flush()
        assert owner.wait(timeout=5) == 0
        assert probe(directory).startswith("OWNER "), "normal exit releases lock"

        owner = launch("hold", directory)
        assert result(owner).startswith("OWNER ")
        owner.kill()
        owner.wait(timeout=5)
        assert probe(directory).startswith("OWNER "), "a crash leaves no stale lock"

        child = launch("exec", directory)
        assert result(child).startswith("OWNER ")
        deadline = time.monotonic() + 3
        while not probe(directory).startswith("OWNER "):
            assert time.monotonic() < deadline, "child inherited the app lock"
            time.sleep(0.03)
        assert child.poll() is None, "lock released while exec child is still alive"
        child.terminate()
        child.wait(timeout=5)

        first, second = launch("hold", directory), launch("hold", directory)
        outcomes = [result(first), result(second)]
        assert sum(line.startswith("OWNER ") for line in outcomes) == 1
        assert sum(line.startswith("OCCUPIED ") for line in outcomes) == 1
    print("PASS instance exclusion, simultaneous launch, independent profiles, aliases, normal/crash recovery and exec isolation")
finally:
    for child in children:
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=5)
