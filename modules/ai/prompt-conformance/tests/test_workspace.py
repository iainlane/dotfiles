import errno
import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

from claude_prompt_conformance.platforms.direct import DirectProcessRunner
from claude_prompt_conformance.process import ProcessSupervisor
from claude_prompt_conformance.workspace import (
    GitWorkspaceInspector,
    LinkedWorkspaceOverlay,
    WorkspaceOverlayParentError,
    WorkspaceSnapshotParentError,
    WorkspaceSnapshotTypeError,
    WorkspaceUntrackedPatchError,
    _append_untracked_evidence,
    snapshot_workspace,
)


def test_inspector_retains_untracked_files_without_following_links(
    tmp_path: Path,
) -> None:
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    run_git(workspace, "init", "--quiet")
    run_git(workspace, "config", "user.name", "Test")
    run_git(workspace, "config", "user.email", "test@example.invalid")
    (workspace / "tracked.txt").write_text("tracked\n")
    run_git(workspace, "add", "tracked.txt")
    run_git(workspace, "commit", "--quiet", "-m", "base")
    base_revision = run_git(workspace, "rev-parse", "HEAD").strip()
    (workspace / "binary.bin").write_bytes(b"\x00binary")
    outside = tmp_path / "outside.txt"
    outside.write_text("private contents\n")
    (workspace / "link").symlink_to(outside)
    (workspace / "untracked.txt").write_text("new contents\n")
    (workspace / "untracked.txt").chmod(0o755)
    artefacts = tmp_path / "artefacts"
    artefacts.mkdir()

    evidence = GitWorkspaceInspector(
        DirectProcessRunner(ProcessSupervisor()), _git_program()
    ).inspect(workspace, base_revision, artefacts, "/bin:/usr/bin")

    snapshots = artefacts / "untracked-files"
    retained = tuple(
        (
            path.relative_to(snapshots),
            stat.S_IMODE(path.stat().st_mode),
            path.read_bytes(),
        )
        for path in sorted(snapshots.rglob("*"))
        if path.is_file()
    )
    snapshot = artefacts / "workspace-snapshot"
    snapshot_entries = tuple(
        (
            "symlink" if path.is_symlink() else "file",
            path.relative_to(snapshot),
            None if path.is_symlink() else stat.S_IMODE(path.stat().st_mode),
            (os.readlink(path).encode() if path.is_symlink() else path.read_bytes()),
        )
        for path in sorted(snapshot.rglob("*"))
        if path.is_symlink() or path.is_file()
    )
    assert (
        evidence.status,
        evidence.diff.read_text(),
        evidence.changed_files,
        retained,
        snapshot_entries,
    ) == (
        "?? binary.bin\n?? link\n?? untracked.txt\n",
        (
            'diff --git "a/binary.bin" "b/binary.bin"\n'
            "new file mode 100644\n"
            'Binary untracked file "b/binary.bin"\n'
            'diff --git "a/link" "b/link"\n'
            "new file mode 120000\n"
            "--- /dev/null\n"
            '+++ "b/link"\n'
            "@@ -0,0 +1 @@\n"
            f"+{outside}\n"
            "\\ No newline at end of file\n"
            'diff --git "a/untracked.txt" "b/untracked.txt"\n'
            "new file mode 100755\n"
            "--- /dev/null\n"
            '+++ "b/untracked.txt"\n'
            "@@ -0,0 +1 @@\n"
            "+new contents\n"
        ),
        ("binary.bin", "link", "untracked.txt"),
        (
            (Path("files/binary.bin"), 0o644, b"\x00binary"),
            (Path("files/untracked.txt"), 0o755, b"new contents\n"),
            (Path("symlinks/link"), 0o644, str(outside).encode()),
        ),
        (
            ("file", Path("binary.bin"), 0o644, b"\x00binary"),
            ("symlink", Path("link"), None, str(outside).encode()),
            ("file", Path("tracked.txt"), 0o644, b"tracked\n"),
            ("file", Path("untracked.txt"), 0o755, b"new contents\n"),
        ),
    )


def test_untracked_evidence_rejects_stale_children_beneath_snapshot_symlinks(
    tmp_path: Path,
) -> None:
    snapshot = tmp_path / "snapshot"
    snapshot.mkdir()
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "private.txt").write_text("private contents\n")
    (snapshot / "parent").symlink_to(outside)
    artefacts = tmp_path / "artefacts"
    artefacts.mkdir()
    patch = artefacts / "diff.patch"
    patch.write_text("")

    with pytest.raises(WorkspaceSnapshotParentError) as raised:
        _append_untracked_evidence(snapshot, artefacts, ("parent/private.txt",), patch)

    assert (
        raised.value,
        patch.read_bytes().decode(),
        tuple(path.relative_to(artefacts) for path in artefacts.rglob("*")),
    ) == (
        WorkspaceSnapshotParentError(snapshot / "parent"),
        "",
        (Path("diff.patch"),),
    )


def test_untracked_evidence_retains_non_utf8_symlink_targets(tmp_path: Path) -> None:
    snapshot = tmp_path / "snapshot"
    snapshot.mkdir()
    os.symlink(b"\xff", os.fsencode(snapshot / "link"))
    artefacts = tmp_path / "artefacts"
    artefacts.mkdir()
    patch = artefacts / "diff.patch"
    patch.write_text("")

    _append_untracked_evidence(snapshot, artefacts, ("link",), patch)

    retained = artefacts / "untracked-files" / "symlinks" / "link"
    assert (retained.read_bytes(), patch.read_text()) == (
        b"\xff",
        (
            'diff --git "a/link" "b/link"\n'
            "new file mode 120000\n"
            'Binary untracked symlink "b/link"\n'
        ),
    )


def test_untracked_evidence_marks_regular_files_without_a_final_newline(
    tmp_path: Path,
) -> None:
    snapshot = tmp_path / "snapshot"
    snapshot.mkdir()
    (snapshot / "first.txt").write_bytes(b"payload")
    (snapshot / "second.txt").write_bytes(b"next\n")
    (snapshot / "carriage-lines.txt").write_bytes(b"a\rb\n")
    (snapshot / "unterminated-carriage.txt").write_bytes(b"a\r")
    artefacts = tmp_path / "artefacts"
    artefacts.mkdir()
    patch = artefacts / "diff.patch"
    patch.write_text("")

    _append_untracked_evidence(snapshot, artefacts, ("first.txt", "second.txt"), patch)
    _append_untracked_evidence(
        snapshot,
        artefacts,
        ("carriage-lines.txt", "unterminated-carriage.txt"),
        patch,
    )

    retained = artefacts / "untracked-files" / "files"
    assert (
        tuple(
            (path.relative_to(retained), path.read_bytes())
            for path in sorted(retained.iterdir())
        ),
        patch.read_bytes().decode(),
    ) == (
        (
            (Path("carriage-lines.txt"), b"a\rb\n"),
            (Path("first.txt"), b"payload"),
            (Path("second.txt"), b"next\n"),
            (Path("unterminated-carriage.txt"), b"a\r"),
        ),
        (
            'diff --git "a/first.txt" "b/first.txt"\n'
            "new file mode 100644\n"
            "--- /dev/null\n"
            '+++ "b/first.txt"\n'
            "@@ -0,0 +1 @@\n"
            "+payload\n"
            "\\ No newline at end of file\n"
            'diff --git "a/second.txt" "b/second.txt"\n'
            "new file mode 100644\n"
            "--- /dev/null\n"
            '+++ "b/second.txt"\n'
            "@@ -0,0 +1 @@\n"
            "+next\n"
            'diff --git "a/carriage-lines.txt" "b/carriage-lines.txt"\n'
            "new file mode 100644\n"
            "--- /dev/null\n"
            '+++ "b/carriage-lines.txt"\n'
            "@@ -0,0 +1 @@\n"
            "+a\rb\n"
            'diff --git "a/unterminated-carriage.txt" '
            '"b/unterminated-carriage.txt"\n'
            "new file mode 100644\n"
            "--- /dev/null\n"
            '+++ "b/unterminated-carriage.txt"\n'
            "@@ -0,0 +1 @@\n"
            "+a\r\n"
            "\\ No newline at end of file\n"
        ),
    )


def test_untracked_evidence_reports_patch_open_failures(tmp_path: Path) -> None:
    snapshot = tmp_path / "snapshot"
    snapshot.mkdir()
    artefacts = tmp_path / "artefacts"
    artefacts.mkdir()
    patch = artefacts / "diff.patch"
    patch.mkdir()

    with pytest.raises(WorkspaceUntrackedPatchError) as raised:
        _append_untracked_evidence(snapshot, artefacts, (), patch)

    assert (
        raised.value.path,
        type(raised.value.cause),
        raised.value.cause.errno,
    ) == (
        patch,
        IsADirectoryError,
        errno.EISDIR,
    )


def test_overlay_rejects_repository_controlled_parent_symlinks(
    tmp_path: Path,
) -> None:
    source = tmp_path / "overlay"
    rule = source / ".claude" / "rules" / "global.md"
    rule.parent.mkdir(parents=True)
    rule.write_text("Rule.\n")
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    outside = tmp_path / "outside"
    outside.mkdir()
    (workspace / ".claude").symlink_to(outside)

    with pytest.raises(WorkspaceOverlayParentError) as raised:
        LinkedWorkspaceOverlay(source).install(workspace)

    assert (
        raised.value,
        tuple(outside.iterdir()),
    ) == (
        WorkspaceOverlayParentError(workspace / ".claude"),
        (),
    )


def test_inspector_excludes_deleted_children_beneath_untracked_symlinks(
    tmp_path: Path,
) -> None:
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    run_git(workspace, "init", "--quiet")
    run_git(workspace, "config", "user.name", "Test")
    run_git(workspace, "config", "user.email", "test@example.invalid")
    tracked = workspace / "tracked" / "private.txt"
    tracked.parent.mkdir()
    tracked.write_text("public contents\n")
    run_git(workspace, "add", "tracked/private.txt")
    run_git(workspace, "commit", "--quiet", "-m", "base")
    base_revision = run_git(workspace, "rev-parse", "HEAD").strip()
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "private.txt").write_text("private contents\n")
    tracked.unlink()
    tracked.parent.rmdir()
    tracked.parent.symlink_to(outside)
    artefacts = tmp_path / "artefacts"
    artefacts.mkdir()

    evidence = GitWorkspaceInspector(
        DirectProcessRunner(ProcessSupervisor()), _git_program()
    ).inspect(workspace, base_revision, artefacts, "/bin:/usr/bin")
    snapshot = artefacts / "workspace-snapshot"
    entries = tuple(
        (
            "symlink" if path.is_symlink() else "file",
            path.relative_to(snapshot),
            os.readlink(path) if path.is_symlink() else path.read_text(),
        )
        for path in sorted(snapshot.rglob("*"))
        if path.is_symlink() or path.is_file()
    )

    assert (
        evidence.changed_files,
        entries,
    ) == (
        ("tracked", "tracked/private.txt"),
        (("symlink", Path("tracked"), str(outside)),),
    )


def test_snapshot_rejects_non_regular_sources_without_opening_them(
    tmp_path: Path,
) -> None:
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    fifo = workspace / "tracked.fifo"
    os.mkfifo(fifo)
    destination = tmp_path / "snapshot"

    with pytest.raises(WorkspaceSnapshotTypeError) as raised:
        snapshot_workspace(workspace, destination, ("tracked.fifo",))

    assert (raised.value, destination.exists()) == (
        WorkspaceSnapshotTypeError(fifo),
        False,
    )


def run_git(workspace: Path, *arguments: str) -> str:
    """Run a local Git command for repository-level outcome assertions."""

    result = subprocess.run(
        (_git_program(), "-C", str(workspace), *arguments),
        check=True,
        capture_output=True,
        env=(
            os.environ
            | {
                "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_CONFIG_NOSYSTEM": "1",
            }
        ),
        text=True,
    )
    return result.stdout


def _git_program() -> str:
    program = shutil.which("git")
    if program is None:
        pytest.fail("Git is required for workspace tests")

    return program
