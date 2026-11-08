"""Real Docker boundary tests; explicitly enable with HARNESS_DOCKER_IMAGE."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
import uuid

from scripts.engineering_harness.backend import DockerBackend
from scripts.engineering_harness.engine import Engine
from scripts.engineering_harness.store import Store
from support import policy, repository


@unittest.skipUnless(os.environ.get("HARNESS_DOCKER_IMAGE"), "Set HARNESS_DOCKER_IMAGE to the built fixture image digest")
class DockerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.policy = policy()
        self.policy["image"] = os.environ["HARNESS_DOCKER_IMAGE"]
        self.policy["bridge"] = ["python3", "/opt/fixture_bridge.py"]
        self.backend = DockerBackend(self.policy)
        self.names = []
        self.addCleanup(self.cleanup_containers)

    def cleanup_containers(self):
        for name in self.names:
            subprocess.run(["docker", "rm", "-f", name], capture_output=True)

    def name(self):
        value = "eh-test-" + uuid.uuid4().hex
        self.names.append(value)
        return value

    def test_real_filesystem_and_network_permissions(self):
        workspace = self.root / "workspace"
        (workspace / "src").mkdir(parents=True)
        (workspace / "protected").write_text("trusted")
        code = """
import pathlib, socket
pathlib.Path('src/allowed').write_text('ok')
for path in ['protected', '/outside']:
    try:
        pathlib.Path(path).write_text('bad')
    except OSError:
        pass
    else:
        raise AssertionError('write escaped sandbox')
assert not pathlib.Path('/var/run/docker.sock').exists()
assert not pathlib.Path('/workspace/.git').exists()
try:
    socket.create_connection(('1.1.1.1', 443), timeout=1)
except OSError:
    pass
else:
    raise AssertionError('network escaped sandbox')
print('isolated')
"""
        result = self.backend.execute(self.name(), ["python3", "-c", code], workspace=workspace,
                                      writable=[workspace / "src"], timeout=10)
        self.assertEqual(result.code, 0, result.output)
        self.assertEqual((workspace / "protected").read_text(), "trusted")

    def test_timeout_output_limit_and_cancellation_stop_containers(self):
        for command, kwargs, status in [(["python3", "-c", "import time; time.sleep(60)"], {"timeout": 1}, "timed_out"),
                                        (["python3", "-c", "print('x'*100000)"], {}, "output_limit"),
                                        (["python3", "-c", "import time; time.sleep(60)"], {"cancelled": lambda: True}, "cancelled")]:
            name = self.name()
            result = self.backend.execute(name, command, **kwargs)
            self.assertEqual(result.status, status, result.output)
            self.assertNotIn(self.backend.status(name), ("running", "created"))

    def test_real_container_end_to_end(self):
        self.policy["gates"][0]["argv"] = ["python3", "-c", "from src.value import VALUE; assert VALUE == 1; print('Ran 1 test')"]
        source = repository(self.root / "source")
        store = Store(self.root / "state")
        self.addCleanup(store.close)
        engine = Engine(store)
        run_id = engine.create(source, "Adjust value", self.policy, scope="fullstack")
        for _ in range(7):
            status = engine.step(run_id)
            if status in ("READY_FOR_REVIEW", "BLOCKED"):
                break
        self.assertEqual(status, "READY_FOR_REVIEW", store.events(run_id))
        self.assertTrue(store.audit(run_id))
        for row in store.db.execute("SELECT id FROM attempts"):
            self.names += [f"eh-worker-{row[0]}", f"eh-cap-{row[0]}"]
        self.names += [f"eh-cap-{run_id}", f"eh-gate-{run_id}-1-0"]
