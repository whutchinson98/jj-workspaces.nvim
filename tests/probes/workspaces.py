"""Local jj create/forget capability probes; not production plugin tests.

Run with python3 -B tests/probes/workspaces.py. No remote is configured or used.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class WorkspaceCapabilities(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="jj-workspaces-operations-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        config = self.base / "config.toml"
        config.write_text('[user]\nname="Probe"\nemail="probe@example.invalid"\n')
        self.env = {**os.environ, "JJ_CONFIG": str(config)}
        self.repo = self.base / "repo"
        self.jj(self.base, "git", "init", "--no-colocate", str(self.repo))

    def jj(self, cwd, *args, success=True):
        result = subprocess.run(
            ["jj", "--no-pager", "--color=never", "--config", "snapshot.auto-update-stale=false", *args],
            cwd=cwd, env=self.env, capture_output=True, text=True, timeout=20,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result.stdout

    def revision(self, cwd, expr="@", snapshot=False):
        args = [] if snapshot else ["--ignore-working-copy"]
        return self.jj(cwd, "log", *args, "--no-graph", "-r", expr, "-T", 'commit_id ++ "\\n"').strip()

    def names(self):
        output = self.jj(self.repo, "workspace", "list", "--ignore-working-copy", "-T", 'json(name) ++ "\\n"')
        return set(map(json.loads, output.splitlines()))

    def add(self, name="feature", path=None, revision=None):
        path = path or self.base / "independent directory"
        revision = revision or self.revision(self.repo, snapshot=True)
        self.jj(self.repo, "workspace", "add", "--name", name,
                "--revision", revision, "--sparse-patterns=copy", "--", str(path))
        return path

    def test_explicit_parent_includes_snapshotted_source_files(self):
        (self.repo / "file.txt").write_text("source content\n")
        parent = self.revision(self.repo, snapshot=True)
        target = self.add(revision=parent)
        self.assertEqual(self.revision(target, "@-"), parent)
        self.assertNotEqual(self.revision(target), parent)
        self.assertEqual((target / "file.txt").read_text(), "source content\n")
        self.assertEqual(self.names(), {"default", "feature"})
        self.assertEqual(self.jj(self.repo, "bookmark", "list", "--ignore-working-copy"), "")
        self.assertEqual(self.jj(self.repo, "git", "remote", "list"), "")

    def test_native_default_parent_differs_from_explicit_current_revision(self):
        current = self.revision(self.repo, snapshot=True)
        parent = self.revision(self.repo, "@-")
        target = self.base / "native"
        self.jj(self.repo, "workspace", "add", "--name", "native", "--", str(target))
        self.assertEqual(self.revision(target, "@-"), parent)
        self.assertNotEqual(self.revision(target, "@-"), current)

    def test_duplicate_name_fails_without_changing_existing_workspace(self):
        target = self.add()
        original = self.revision(target)
        self.jj(self.repo, "workspace", "add", "--name", "feature", "--", str(self.base / "second"), success=False)
        self.assertEqual(self.revision(target), original)
        self.assertEqual(self.names(), {"default", "feature"})

    def test_invalid_revision_preflight_and_existing_destination_fail(self):
        self.jj(self.repo, "log", "--no-graph", "-r", "no-such-bookmark", "-T", "commit_id", success=False)
        self.assertEqual(self.names(), {"default"})
        existing = self.base / "occupied"
        existing.mkdir()
        sentinel = existing / "keep.txt"
        sentinel.write_text("keep\n")
        self.jj(self.repo, "workspace", "add", "--name", "occupied", "--", str(existing), success=False)
        self.assertEqual(sentinel.read_text(), "keep\n")
        self.assertEqual(self.names(), {"default"})

    def test_native_add_failure_can_leave_registered_directory(self):
        for name, args in (("invalid", ["-r", "no-such-bookmark"]),
                           ("ignored", ["--ignore-working-copy"])):
            with self.subTest(name=name):
                target = self.base / name
                self.jj(self.repo, "workspace", "add", "--name", name, *args,
                        "--", str(target), success=False)
                self.assertIn(name, self.names())
                self.assertTrue(target.is_dir())


if __name__ == "__main__":
    unittest.main(verbosity=2)
