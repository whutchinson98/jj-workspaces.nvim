"""HUT-94 CLI capability probes, not tests of a plugin implementation.

Run: python3 tests/probes/discovery.py
Validated with jj 0.44.0. Uses only the Python standard library and jj.
Every mutation is confined to a unique temporary directory; no remotes are used.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


# Explicit JSON fields: json(self) does not include the workspace root in jj 0.44.
INVENTORY = r"""
'{"name":' ++ json(name) ++
',"path":' ++ json(root) ++
',"commit_id":' ++ json(target.commit_id()) ++ "}\n"
""".strip()


class DiscoveryCapabilities(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="jj-workspaces-discovery-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        config = self.base / "config.toml"
        config.write_text('[user]\nname = "Probe"\nemail = "probe@example.invalid"\n')
        self.env = {**os.environ, "JJ_CONFIG": str(config)}
        self.repo = self.base / "repository"
        self.jj(self.base, "git", "init", "--no-colocate", str(self.repo))

    def jj(self, cwd, *args, success=True):
        result = subprocess.run(
            ["jj", "--no-pager", "--color=never", *args],
            cwd=cwd, env=self.env, text=True, capture_output=True, timeout=20,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def root(self, cwd):
        return Path(self.jj(cwd, "workspace", "root", "--ignore-working-copy").stdout.removesuffix("\n"))

    def inventory(self, cwd):
        output = self.jj(
            cwd, "workspace", "list", "--ignore-working-copy", "-T", INVENTORY,
        ).stdout
        return {entry["name"]: entry for entry in map(json.loads, output.splitlines())}

    def add_workspace(self, name="feature", directory="feature"):
        path = self.base / directory
        self.jj(self.repo, "workspace", "add", "--name", name, str(path))
        return path

    def operation(self, cwd):
        return self.jj(
            cwd, "op", "log", "--ignore-working-copy", "--limit", "1", "-T", "id",
        ).stdout

    @staticmethod
    def metadata_path(root):
        # Capability probe for jj's on-disk layout, not a public plugin API.
        repo = root / ".jj" / "repo"
        return repo.resolve() if repo.is_dir() else (repo.parent / repo.read_text()).resolve()

    def test_colocated_and_non_colocated_roots_and_subdirectories(self):
        colocated = self.base / "colocated"
        self.jj(self.base, "git", "init", "--colocate", str(colocated))
        for root in (self.repo, colocated):
            nested = root / "src" / "deep"
            nested.mkdir(parents=True)
            self.assertEqual(self.root(nested), root)
            self.assertEqual(self.inventory(nested)["default"]["path"], str(root))

    def test_workspace_name_is_independent_of_escaped_directory_path(self):
        path = self.add_workspace("feature", 'different name with spaces "quotes"\tand\nnewline\n')
        self.assertEqual(self.root(path), path)
        records = self.inventory(path)
        self.assertEqual(records, self.inventory(self.repo))
        self.assertEqual(records["feature"]["path"], str(path))
        self.assertEqual(len(records["feature"]["commit_id"]), 40)
        self.assertEqual(self.metadata_path(path), self.metadata_path(self.repo))

    def test_relative_paths_use_workspace_root_not_editor_subdirectory(self):
        nested = self.repo / "src" / "deep"
        nested.mkdir(parents=True)
        for cwd in (self.repo, nested):
            self.assertEqual((self.root(cwd) / "../feature").resolve(), self.base / "feature")
            absolute = self.base / "elsewhere"
            self.assertEqual(self.root(cwd) / absolute, absolute)

    def test_independent_repositories_do_not_share_identity(self):
        other = self.base / "unrelated"
        self.jj(self.base, "git", "init", "--no-colocate", str(other))
        self.assertEqual(set(self.inventory(self.repo)), {"default"})
        self.assertEqual(set(self.inventory(other)), {"default"})
        self.assertNotEqual(self.metadata_path(self.repo), self.metadata_path(other))

    def test_nested_jj_and_git_only_boundaries(self):
        nested = self.repo / "nested"
        self.jj(self.repo, "git", "init", "--colocate", str(nested))
        self.assertEqual(self.root(nested), nested)
        # This is entirely inside our owned fixture. Leave a real Git-only repo.
        shutil.rmtree(nested / ".jj")
        self.assertTrue((nested / ".git").exists())
        # jj itself crosses this boundary; the future plugin must stop first.
        self.assertEqual(self.root(nested), self.repo)

    def test_outside_repository_returns_error(self):
        self.jj(self.base, "workspace", "root", "--ignore-working-copy", success=False)

    def test_moved_and_missing_paths_remain_in_inventory(self):
        feature = self.add_workspace()
        moved = self.base / "moved"
        feature.rename(moved)
        self.assertIsNone(self.inventory(self.repo)["feature"]["path"])
        # Current root can be discovered even though its registered path is gone.
        self.assertEqual(self.root(moved), moved)
        self.assertIsNone(self.inventory(moved)["feature"]["path"])
        shutil.rmtree(moved)
        self.assertIsNone(self.inventory(self.repo)["feature"]["path"])
        self.jj(
            self.repo, "workspace", "root", "--ignore-working-copy",
            "--name", "feature", success=False,
        )

    def test_read_only_inventory_does_not_snapshot_files(self):
        before = self.operation(self.repo)
        dirty = self.repo / "not-yet-snapshotted.txt"
        dirty.write_text("unsnapshotted\n")
        self.root(self.repo)
        self.inventory(self.repo)
        self.assertEqual(self.operation(self.repo), before)
        self.assertEqual(dirty.read_text(), "unsnapshotted\n")

    def test_stale_workspace_can_be_inspected_without_repair(self):
        feature = self.add_workspace()
        local_state = feature / ".jj" / "working_copy"
        before_state = {p.relative_to(local_state): p.read_bytes()
                        for p in local_state.rglob("*") if p.is_file()}
        self.assertTrue(before_state, "Expected working-copy state files in the fixture")
        self.jj(self.repo, "describe", "-r", "feature@", "-m", "rewrite from another workspace")
        before_op = self.operation(self.repo)
        self.assertEqual(self.root(feature), feature)
        self.assertEqual(self.inventory(feature)["feature"]["path"], str(feature))
        after_state = {p.relative_to(local_state): p.read_bytes()
                       for p in local_state.rglob("*") if p.is_file()}
        self.assertEqual(after_state, before_state)
        self.assertEqual(self.operation(self.repo), before_op)


if __name__ == "__main__":
    print(subprocess.run(["jj", "--version"], capture_output=True, text=True, check=True).stdout.strip())
    unittest.main(verbosity=2)
