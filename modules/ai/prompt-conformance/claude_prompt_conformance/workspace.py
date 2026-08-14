"""Repository and per-instance workspace capabilities."""

import difflib
import json
import os
import shutil
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import TextIO

from .errors import ConformanceError
from .models import (
    InstancePaths,
    NetworkAccess,
    ProcessCapabilities,
    ProcessInvocation,
    RepositorySpec,
    WorkspaceEvidence,
)
from .ports import ProcessRunner
from .process import command_program
from .storage import remove_tree


@dataclass(eq=True)
class RepositoryPreparationError(ConformanceError):
    url: str
    revision: str
    operation: tuple[str, ...]
    return_code: int
    stderr: Path

    def __str__(self) -> str:
        operation = command_program(self.operation)
        return (
            f"Git failed while preparing {self.url} at {self.revision} "
            f"during {operation} (exit {self.return_code}; {self.stderr})"
        )


@dataclass(eq=True)
class WorkspaceInspectionError(ConformanceError):
    evidence: str
    return_code: int
    stderr: Path

    def __str__(self) -> str:
        return (
            f"Git could not collect {self.evidence} evidence "
            f"(exit {self.return_code}; {self.stderr})"
        )


@dataclass(eq=True)
class WorkspaceUntrackedPathError(ConformanceError):
    path: str

    def __str__(self) -> str:
        return f"Git returned an unsafe untracked path: {self.path!r}"


@dataclass(eq=True)
class WorkspaceUntrackedReadError(ConformanceError):
    path: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not read untracked file {self.path}: {self.cause}"


@dataclass(eq=True)
class WorkspaceUntrackedWriteError(ConformanceError):
    path: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not retain untracked file {self.path}: {self.cause}"


@dataclass(eq=True)
class WorkspaceUntrackedPatchError(ConformanceError):
    path: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not append untracked patch evidence to {self.path}: {self.cause}"


@dataclass(eq=True)
class WorkspaceUntrackedTypeError(ConformanceError):
    path: Path

    def __str__(self) -> str:
        return f"untracked path has an unsupported file type: {self.path}"


@dataclass(eq=True)
class WorkspaceSnapshotReadError(ConformanceError):
    path: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not read workspace snapshot source {self.path}: {self.cause}"


@dataclass(eq=True)
class WorkspaceSnapshotWriteError(ConformanceError):
    source: Path
    destination: Path
    cause: OSError

    def __str__(self) -> str:
        return (
            f"could not write workspace snapshot path {self.destination}: {self.cause}"
        )


@dataclass(eq=True)
class WorkspaceSnapshotCopyError(ConformanceError):
    source: Path
    destination: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not copy workspace snapshot path {self.source}: {self.cause}"


@dataclass(eq=True)
class WorkspaceSnapshotParentError(ConformanceError):
    path: Path

    def __str__(self) -> str:
        return f"workspace snapshot parent is not a safe directory: {self.path}"


@dataclass(eq=True)
class WorkspaceSnapshotTypeError(ConformanceError):
    path: Path

    def __str__(self) -> str:
        return f"workspace snapshot source has an unsupported file type: {self.path}"


@dataclass(eq=True)
class WorkspaceOverlayParentError(ConformanceError):
    path: Path

    def __str__(self) -> str:
        return f"the prompt overlay parent is not a safe directory: {self.path}"


@dataclass(eq=True)
class WorkspaceOverlayDestinationError(ConformanceError):
    path: Path

    def __str__(self) -> str:
        return f"the repository already contains a prompt overlay path: {self.path}"


@dataclass(frozen=True)
class _SnapshotFile:
    contents: bytes
    mode: int


@dataclass(frozen=True)
class _SnapshotSymlink:
    target: bytes


class DirectoryInstanceFactory:
    """Allocate a fixed directory layout beneath the selected result path."""

    def create(self, name: str, results: Path) -> InstancePaths:
        root = results / name
        paths = InstancePaths(
            root=root,
            workspace=root / "workspace",
            control=root / "control",
            candidate_state=root / "state" / "candidate",
            candidate_cache=root / "cache" / "candidate",
            candidate_temp=root / "tmp" / "candidate",
            judge_state=root / "state" / "judge",
            judge_cache=root / "cache" / "judge",
            judge_temp=root / "tmp" / "judge",
        )
        for path in (
            paths.workspace,
            paths.control,
            paths.candidate_state,
            paths.candidate_cache,
            paths.candidate_temp,
            paths.judge_state,
            paths.judge_cache,
            paths.judge_temp,
        ):
            path.mkdir(parents=True, exist_ok=True)
        return paths

    def clean(self, instance: InstancePaths) -> None:
        try:
            remove_tree(instance.root)
        except OSError:
            shutil.rmtree(instance.root, ignore_errors=True)


class GitRepositoryMaterialiser:
    """Fetch exact revisions using private Git configuration and identity."""

    def __init__(self, runner: ProcessRunner, git_program: str) -> None:
        self._runner = runner
        self._git_program = git_program

    def materialise(
        self,
        repository: RepositorySpec,
        destination: Path,
        control: Path,
        environment_path: str,
        comparison_revision: str,
    ) -> None:
        home = control / "git-home"
        home.mkdir()
        global_config = control / "gitconfig"
        global_config.write_text("")
        hooks = control / "hooks"
        hooks.mkdir()
        environment = clean_environment(environment_path) | {
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(home / ".config"),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": str(global_config),
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_SSH_COMMAND": "false",
        }
        commands = (
            ("init", "--quiet"),
            ("remote", "add", "origin", repository.url),
            ("fetch", "--quiet", "--depth=2", "origin", repository.revision),
            (
                "checkout",
                "--quiet",
                "-b",
                "prompt-conformance",
                repository.revision,
            ),
            ("config", "user.name", "Prompt Conformance Candidate"),
            ("config", "user.email", "prompt-conformance@example.invalid"),
            ("config", "commit.gpgSign", "false"),
            ("config", "tag.gpgSign", "false"),
            ("config", "core.hooksPath", str(hooks)),
            ("config", "credential.helper", ""),
        )
        if comparison_revision != repository.revision:
            commands = (
                commands[:3]
                + (("fetch", "--quiet", "--depth=1", "origin", comparison_revision),)
                + commands[3:]
            )
        for index, arguments in enumerate(commands):
            invocation = ProcessInvocation(
                command=(self._git_program, "-C", str(destination), *arguments),
                cwd=control,
                environment=environment,
                capabilities=ProcessCapabilities(
                    writable_paths=(destination, control),
                    network=NetworkAccess.PUBLIC,
                ),
                stdout=control / f"git-{index}.stdout",
                stderr=control / f"git-{index}.stderr",
            )
            result = self._runner.run(invocation)
            if not result.succeeded:
                raise RepositoryPreparationError(
                    repository.url,
                    repository.revision,
                    arguments,
                    result.return_code,
                    invocation.stderr,
                )


class LinkedWorkspaceOverlay:
    """Link Nix-built prompt artefacts into Claude's project configuration."""

    def __init__(self, source: Path) -> None:
        self._source = source

    def install(self, workspace: Path) -> None:
        for source in self._source.rglob("*"):
            if source.is_dir():
                continue
            relative = source.relative_to(self._source)
            destination = workspace / relative
            ensure_overlay_parent(workspace, destination.parent)
            if destination.exists() or destination.is_symlink():
                raise WorkspaceOverlayDestinationError(destination)
            destination.symlink_to(source)
        exclude = workspace / ".git" / "info" / "exclude"
        with exclude.open("a") as file:
            file.write("\n/.claude/\n")


def ensure_overlay_parent(workspace: Path, parent: Path) -> None:
    current = workspace
    for part in parent.relative_to(workspace).parts:
        current /= part
        try:
            current.mkdir()
        except FileExistsError:
            if current.is_symlink() or not current.is_dir():
                raise WorkspaceOverlayParentError(current) from None


class GitWorkspaceInspector:
    """Capture Git status, patch, commits, revision, and changed paths."""

    def __init__(self, runner: ProcessRunner, git_program: str) -> None:
        self._runner = runner
        self._git_program = git_program

    def inspect(
        self,
        workspace: Path,
        base_revision: str,
        artefacts: Path,
        environment_path: str,
    ) -> WorkspaceEvidence:
        status = self._capture(
            workspace, artefacts, environment_path, "status", ("status", "--short")
        )
        diff = self._capture(
            workspace,
            artefacts,
            environment_path,
            "diff",
            ("diff", "--no-ext-diff", "--binary", base_revision),
        )
        untracked = tuple(
            path.decode(errors="surrogateescape")
            for path in self._capture(
                workspace,
                artefacts,
                environment_path,
                "untracked-files",
                ("ls-files", "--others", "--exclude-standard", "-z"),
            )
            .read_bytes()
            .split(b"\0")
            if path
        )
        deleted = {
            path.decode(errors="surrogateescape")
            for path in self._capture(
                workspace,
                artefacts,
                environment_path,
                "deleted-files",
                ("ls-files", "--deleted", "-z"),
            )
            .read_bytes()
            .split(b"\0")
            if path
        }
        untracked_paths = frozenset(untracked)
        evidence_files = tuple(
            path
            for path in (
                item.decode(errors="surrogateescape")
                for item in self._capture(
                    workspace,
                    artefacts,
                    environment_path,
                    "evidence-files",
                    ("ls-files", "--cached", "--others", "--exclude-standard", "-z"),
                )
                .read_bytes()
                .split(b"\0")
                if item
            )
            if path not in deleted and not _has_untracked_parent(path, untracked_paths)
        )
        snapshot = artefacts / "workspace-snapshot"
        snapshot_workspace(workspace, snapshot, evidence_files)
        _append_untracked_evidence(snapshot, artefacts, untracked, diff)
        commits = self._capture(
            workspace,
            artefacts,
            environment_path,
            "commits",
            ("log", "--format=fuller", f"{base_revision}..HEAD"),
        )
        head = (
            self._capture(
                workspace,
                artefacts,
                environment_path,
                "head",
                ("rev-parse", "HEAD"),
            )
            .read_text()
            .strip()
        )
        tracked = (
            self._capture(
                workspace,
                artefacts,
                environment_path,
                "changed-files",
                ("diff", "--name-only", base_revision),
            )
            .read_text()
            .splitlines()
        )
        return WorkspaceEvidence(
            workspace=snapshot,
            base_revision=base_revision,
            head_revision=head,
            status=status.read_text(),
            diff=diff,
            commits=commits,
            changed_files=tuple(sorted(set(tracked) | set(untracked))),
        )

    def _capture(
        self,
        workspace: Path,
        artefacts: Path,
        environment_path: str,
        name: str,
        arguments: tuple[str, ...],
    ) -> Path:
        output = artefacts / f"git-{name}.txt"
        invocation = ProcessInvocation(
            command=(self._git_program, "-C", str(workspace), *arguments),
            cwd=workspace,
            environment=clean_environment(environment_path),
            capabilities=ProcessCapabilities(
                (), NetworkAccess.NONE, readable_paths=(workspace,)
            ),
            stdout=output,
            stderr=artefacts / f"git-{name}.stderr",
        )
        result = self._runner.run(invocation)
        if not result.succeeded:
            raise WorkspaceInspectionError(name, result.return_code, invocation.stderr)
        return output


def snapshot_workspace(
    workspace: Path,
    destination: Path,
    files: tuple[str, ...],
) -> None:
    """Retain Git-visible files as the immutable input to the evaluator."""

    relative_paths = tuple(_snapshot_relative_path(relative) for relative in files)
    for relative in relative_paths:
        _validate_snapshot_source(workspace, relative)

    try:
        destination.mkdir()
    except OSError as error:
        raise WorkspaceSnapshotWriteError(workspace, destination, error) from error

    for relative in relative_paths:
        _copy_snapshot_source(workspace, destination, relative)


def _has_untracked_parent(path: str, untracked: frozenset[str]) -> bool:
    return any(
        parent != Path(".") and str(parent) in untracked
        for parent in Path(path).parents
    )


def _snapshot_relative_path(value: str) -> Path:
    relative = Path(value)
    if not relative.parts or relative.is_absolute() or ".." in relative.parts:
        raise WorkspaceUntrackedPathError(value)
    return relative


def _validate_snapshot_source(workspace: Path, relative: Path) -> None:
    parent, descriptors = _open_snapshot_parent(workspace, relative)
    try:
        mode = _snapshot_source_mode(parent, workspace / relative, relative.name)
    finally:
        _close_descriptors(descriptors)

    if not stat.S_ISREG(mode) and not stat.S_ISLNK(mode):
        raise WorkspaceSnapshotTypeError(workspace / relative)


def _copy_snapshot_source(workspace: Path, destination: Path, relative: Path) -> None:
    source = workspace / relative
    target = destination / relative
    parent, descriptors = _open_snapshot_parent(workspace, relative)
    try:
        mode = _snapshot_source_mode(parent, source, relative.name)
        if stat.S_ISLNK(mode):
            _copy_snapshot_symlink(parent, source, target, relative.name)
            return
        if not stat.S_ISREG(mode):
            raise WorkspaceSnapshotTypeError(source)
        _copy_snapshot_file(parent, source, target, relative.name)
    finally:
        _close_descriptors(descriptors)


def _open_snapshot_parent(
    workspace: Path, relative: Path
) -> tuple[int, tuple[int, ...]]:
    descriptors: list[int] = []
    current_path = workspace
    try:
        current = os.open(workspace, os.O_RDONLY | os.O_DIRECTORY)
        descriptors.append(current)
        for part in relative.parts[:-1]:
            current_path /= part
            mode = os.stat(part, dir_fd=current, follow_symlinks=False).st_mode
            if not stat.S_ISDIR(mode):
                raise WorkspaceSnapshotParentError(current_path)
            current = os.open(
                part,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=current,
            )
            descriptors.append(current)
    except WorkspaceSnapshotParentError:
        _close_descriptors(tuple(descriptors))
        raise
    except OSError as error:
        _close_descriptors(tuple(descriptors))
        raise WorkspaceSnapshotReadError(current_path, error) from error

    return current, tuple(descriptors)


def _snapshot_source_mode(parent: int, source: Path, name: str) -> int:
    try:
        return os.stat(name, dir_fd=parent, follow_symlinks=False).st_mode
    except OSError as error:
        raise WorkspaceSnapshotReadError(source, error) from error


def _copy_snapshot_symlink(parent: int, source: Path, target: Path, name: str) -> None:
    try:
        link = os.readlink(name, dir_fd=parent)
    except OSError as error:
        raise WorkspaceSnapshotReadError(source, error) from error

    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.symlink_to(link)
    except OSError as error:
        raise WorkspaceSnapshotWriteError(source, target, error) from error


def _copy_snapshot_file(parent: int, source: Path, target: Path, name: str) -> None:
    descriptor, mode = _open_snapshot_file(parent, source, name)

    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        target_file = target.open("xb")
    except OSError as error:
        os.close(descriptor)
        raise WorkspaceSnapshotWriteError(source, target, error) from error

    try:
        with target_file, os.fdopen(descriptor, "rb", closefd=False) as source_file:
            shutil.copyfileobj(source_file, target_file)
            os.fchmod(target_file.fileno(), stat.S_IMODE(mode))
    except OSError as error:
        raise WorkspaceSnapshotCopyError(source, target, error) from error
    finally:
        os.close(descriptor)


def _open_snapshot_file(parent: int, source: Path, name: str) -> tuple[int, int]:
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW,
            dir_fd=parent,
        )
    except OSError as error:
        raise WorkspaceSnapshotReadError(source, error) from error

    try:
        mode = os.fstat(descriptor).st_mode
    except OSError as error:
        os.close(descriptor)
        raise WorkspaceSnapshotReadError(source, error) from error

    if stat.S_ISREG(mode):
        return descriptor, mode

    os.close(descriptor)
    raise WorkspaceSnapshotTypeError(source)


def _close_descriptors(descriptors: tuple[int, ...]) -> None:
    for descriptor in reversed(descriptors):
        os.close(descriptor)


def _append_untracked_evidence(
    snapshot: Path,
    artefacts: Path,
    relatives: tuple[str, ...],
    patch_path: Path,
) -> None:
    try:
        with patch_path.open("a", encoding="utf-8") as patch:
            for relative in relatives:
                _append_untracked_entry_evidence(snapshot, artefacts, relative, patch)
    except WorkspaceUntrackedPatchError:
        raise
    except OSError as error:
        raise WorkspaceUntrackedPatchError(patch_path, error) from error


def _append_untracked_entry_evidence(
    snapshot: Path,
    artefacts: Path,
    relative: str,
    patch: TextIO,
) -> None:

    relative_path = Path(relative)
    if relative_path.is_absolute() or ".." in relative_path.parts:
        raise WorkspaceUntrackedPathError(relative)

    entry = _read_retained_untracked_entry(snapshot, relative_path)
    match entry:
        case _SnapshotSymlink(target):
            retain_untracked_symlink(target, artefacts, relative_path, patch)
        case _SnapshotFile(contents, mode):
            retain_untracked_file(contents, mode, artefacts, relative_path, patch)


def _read_retained_untracked_entry(
    snapshot: Path, relative: Path
) -> _SnapshotFile | _SnapshotSymlink:
    source = snapshot / relative
    parent, descriptors = _open_snapshot_parent(snapshot, relative)
    try:
        mode = _snapshot_source_mode(parent, source, relative.name)
        if stat.S_ISLNK(mode):
            try:
                target = os.readlink(os.fsencode(relative.name), dir_fd=parent)
            except OSError as error:
                raise WorkspaceSnapshotReadError(source, error) from error
            return _SnapshotSymlink(target)
        if not stat.S_ISREG(mode):
            raise WorkspaceUntrackedTypeError(source)
        descriptor, mode = _open_snapshot_file(parent, source, relative.name)
        try:
            with os.fdopen(descriptor, "rb") as retained:
                return _SnapshotFile(retained.read(), mode)
        except OSError as error:
            raise WorkspaceUntrackedReadError(source, error) from error
    finally:
        _close_descriptors(descriptors)


def retain_untracked_symlink(
    target: bytes,
    artefacts: Path,
    relative: Path,
    patch: TextIO,
) -> None:
    snapshot = artefacts / "untracked-files" / "symlinks" / relative
    try:
        snapshot.parent.mkdir(parents=True, exist_ok=True)
        snapshot.write_bytes(target)
    except OSError as error:
        raise WorkspaceUntrackedWriteError(snapshot, error) from error

    header = (
        f"diff --git {_git_patch_path('a', relative)} "
        f"{_git_patch_path('b', relative)}\n"
        "new file mode 120000\n"
    )
    _append_untracked_patch(
        patch, _render_untracked_patch(header, target, relative, "symlink")
    )


def retain_untracked_file(
    contents: bytes,
    mode: int,
    artefacts: Path,
    relative: Path,
    patch: TextIO,
) -> None:
    snapshot = artefacts / "untracked-files" / "files" / relative
    try:
        snapshot.parent.mkdir(parents=True, exist_ok=True)
        snapshot.write_bytes(contents)
        snapshot.chmod(stat.S_IMODE(mode))
    except OSError as error:
        raise WorkspaceUntrackedWriteError(snapshot, error) from error

    header = (
        f"diff --git {_git_patch_path('a', relative)} "
        f"{_git_patch_path('b', relative)}\n"
        f"new file mode {_git_file_mode(mode)}\n"
    )

    _append_untracked_patch(
        patch,
        _render_untracked_patch(header, contents, relative, "file"),
    )


def _render_untracked_patch(
    header: str,
    contents: bytes,
    relative: Path,
    kind: str,
) -> str:
    try:
        text = contents.decode()
    except UnicodeDecodeError:
        return header + f"Binary untracked {kind} {_git_patch_path('b', relative)}\n"

    if b"\0" in contents:
        return header + f"Binary untracked {kind} {_git_patch_path('b', relative)}\n"

    patch = header + "".join(
        difflib.unified_diff(
            (),
            _split_diff_lines(text),
            fromfile="/dev/null",
            tofile=_git_patch_path("b", relative),
        )
    )
    if contents and not contents.endswith(b"\n"):
        patch += "\n\\ No newline at end of file\n"
    return patch


def _split_diff_lines(value: str) -> tuple[str, ...]:
    parts = value.split("\n")
    terminated = tuple(f"{part}\n" for part in parts[:-1])
    if not parts[-1]:
        return terminated
    return (*terminated, parts[-1])


def _git_patch_path(prefix: str, relative: Path) -> str:
    return json.dumps(f"{prefix}/{relative}", ensure_ascii=True)


def _git_file_mode(mode: int) -> str:
    return "100755" if mode & 0o111 else "100644"


def _append_untracked_patch(patch: TextIO, contents: str) -> None:
    try:
        patch.write(contents)
    except OSError as error:
        raise WorkspaceUntrackedPatchError(Path(str(patch.name)), error) from error


def clean_environment(environment_path: str) -> dict[str, str]:
    return {
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "PATH": environment_path,
        "TZ": "UTC",
    }
