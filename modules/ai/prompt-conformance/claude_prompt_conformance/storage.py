"""Stable names and no-follow filesystem operations for retained run state."""

import fcntl
import os
import shutil
import stat
import uuid
from collections.abc import Generator
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from types import TracebackType
from typing import Self

from .errors import ConformanceError, RetainedStateError


@dataclass(eq=True)
class RetainedPathUnsafeError(RetainedStateError):
    path: Path

    def __str__(self) -> str:
        return f"retained run path is not a safe directory or regular file: {self.path}"


@dataclass(eq=True)
class RetainedDirectoryChangedError(RetainedStateError):
    path: Path

    def __str__(self) -> str:
        return f"retained run directory changed after it was validated: {self.path}"


@dataclass(eq=True)
class RunLeaseOpenError(ConformanceError):
    path: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not open the run lease {self.path}: {self.cause}"


@dataclass(eq=True)
class RunLeaseAcquireError(ConformanceError):
    path: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not acquire the run lease {self.path}: {self.cause}"


@dataclass(eq=True)
class RunLeaseReleaseError(ConformanceError):
    path: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not release the run lease {self.path}: {self.cause}"


OUTPUT_MARKER = ".claude-prompt-conformance"
STATE_DIRECTORY = ".claude-prompt-conformance-state"
RESERVED_RUN_NAMES = frozenset(
    {
        OUTPUT_MARKER,
        STATE_DIRECTORY,
        "current-prompt",
        "improvement-summary.json",
        "prompt-context.json",
        "reserved-checks",
        "run-metadata.json",
        "tries",
    }
)


@dataclass(frozen=True)
class DirectoryIdentity:
    """Stable filesystem identity of a validated retained directory."""

    device: int
    inode: int


@contextmanager
def directory_descriptor(
    root: Path,
    directory: Path,
    *,
    create: bool,
) -> Generator[int]:
    """Open a run-owned directory without following any path component."""

    root = root.resolve()
    try:
        relative = directory.relative_to(root)
    except ValueError as error:
        raise RetainedPathUnsafeError(directory) from error
    if any(part in ("", ".", "..") for part in relative.parts):
        raise RetainedPathUnsafeError(directory)

    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    descriptors: list[int] = []
    try:
        current = os.open(root, flags)
        descriptors.append(current)
        for part in relative.parts:
            try:
                child = os.open(part, flags, dir_fd=current)
            except FileNotFoundError:
                if not create:
                    raise
                try:
                    os.mkdir(part, dir_fd=current)
                except FileExistsError:
                    # Another arm of the same run store creating the same
                    # parent is not a reason to fail: the open below still
                    # refuses to follow whatever now holds the name.
                    pass
                child = os.open(part, flags, dir_fd=current)
            descriptors.append(child)
            current = child
    except (NotADirectoryError, OSError) as error:
        for descriptor in reversed(descriptors):
            os.close(descriptor)
        raise RetainedPathUnsafeError(directory) from error

    try:
        yield current
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def ensure_directory(root: Path, directory: Path) -> None:
    """Create a run-owned directory through verified real parent directories."""

    with directory_descriptor(root, directory, create=True):
        pass


def directory_exists(root: Path, directory: Path) -> bool:
    """Test for a real run-owned directory without following path components."""

    root = root.resolve()
    try:
        relative = directory.relative_to(root)
    except ValueError as error:
        raise RetainedPathUnsafeError(directory) from error

    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    descriptors: list[int] = []
    try:
        current = os.open(root, flags)
        descriptors.append(current)
        for part in relative.parts:
            try:
                child = os.open(part, flags, dir_fd=current)
            except FileNotFoundError:
                return False
            descriptors.append(child)
            current = child
        return True
    except OSError as error:
        raise RetainedPathUnsafeError(directory) from error
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def remove_tree(name: str | Path, parent: int | None = None) -> None:
    """Remove a directory tree, making read-only directories deletable.

    Toolchains write read-only trees into run-owned directories: Go marks its
    module cache directories 0555, so their children cannot be unlinked until
    the directories are writable again.
    """

    try:
        shutil.rmtree(name, dir_fd=parent)
    except PermissionError:
        for _path, _directories, _files, descriptor in os.fwalk(name, dir_fd=parent):
            mode = stat.S_IMODE(os.fstat(descriptor).st_mode)
            wanted = mode | stat.S_IWUSR | stat.S_IXUSR
            if wanted != mode:
                os.fchmod(descriptor, wanted)
        shutil.rmtree(name, dir_fd=parent)


def remove_directory(root: Path, directory: Path) -> None:
    """Remove one run-owned directory without following intermediate links."""

    if not directory_exists(root, directory.parent):
        return
    with directory_descriptor(root, directory.parent, create=False) as parent:
        try:
            metadata = os.stat(directory.name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            return
        if not stat.S_ISDIR(metadata.st_mode):
            raise RetainedPathUnsafeError(directory)
        remove_tree(directory.name, parent)


def clear_directory(root: Path, directory: Path, retain: frozenset[str]) -> None:
    """Empty one run-owned directory, keeping named children where they are."""

    with directory_descriptor(root, directory, create=True) as parent:
        for name in os.listdir(parent):
            if name in retain:
                continue
            metadata = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if stat.S_ISDIR(metadata.st_mode):
                remove_tree(name, parent)
                continue
            os.unlink(name, dir_fd=parent)


def directory_identity(root: Path, directory: Path) -> DirectoryIdentity:
    """Capture the filesystem object represented by a retained directory name."""

    with directory_descriptor(root, directory.parent, create=False) as parent:
        try:
            metadata = os.stat(directory.name, dir_fd=parent, follow_symlinks=False)
        except OSError as error:
            raise RetainedPathUnsafeError(directory) from error
        if not stat.S_ISDIR(metadata.st_mode):
            raise RetainedPathUnsafeError(directory)
        return DirectoryIdentity(device=metadata.st_dev, inode=metadata.st_ino)


def read_regular_file(root: Path, source: Path) -> bytes:
    """Read one run-owned regular file without following or blocking on its name."""

    with directory_descriptor(root, source.parent, create=False) as parent:
        try:
            descriptor = os.open(
                source.name,
                os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                dir_fd=parent,
            )
        except FileNotFoundError:
            raise
        except OSError as error:
            raise RetainedPathUnsafeError(source) from error
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode):
                raise RetainedPathUnsafeError(source)
            with os.fdopen(descriptor, "rb", closefd=False) as stream:
                return stream.read()
        finally:
            os.close(descriptor)


def remove_identified_directory(
    root: Path,
    directory: Path,
    identity: DirectoryIdentity,
) -> None:
    """Remove exactly the retained directory previously represented by a name."""

    with directory_descriptor(root, directory.parent, create=False) as parent:
        quarantine = f".{directory.name}.{uuid.uuid4().hex}.unlinking"
        try:
            os.replace(
                directory.name,
                quarantine,
                src_dir_fd=parent,
                dst_dir_fd=parent,
            )
            metadata = os.stat(quarantine, dir_fd=parent, follow_symlinks=False)
        except OSError as error:
            raise RetainedPathUnsafeError(directory) from error

        actual = DirectoryIdentity(device=metadata.st_dev, inode=metadata.st_ino)
        if actual != identity:
            try:
                os.replace(
                    quarantine,
                    directory.name,
                    src_dir_fd=parent,
                    dst_dir_fd=parent,
                )
            except OSError as error:
                raise RetainedPathUnsafeError(directory) from error
            raise RetainedDirectoryChangedError(directory)

        remove_tree(quarantine, parent)


def atomic_write(root: Path, destination: Path, contents: bytes) -> None:
    """Atomically replace a run-owned file through a no-follow parent handle."""

    with directory_descriptor(root, destination.parent, create=True) as parent:
        try:
            metadata = os.stat(
                destination.name,
                dir_fd=parent,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            pass
        else:
            if not stat.S_ISREG(metadata.st_mode):
                raise RetainedPathUnsafeError(destination.parent)
        pending = f".{destination.name}.{uuid.uuid4().hex}.new"
        descriptor: int | None = None
        try:
            descriptor = os.open(
                pending,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600,
                dir_fd=parent,
            )
            with os.fdopen(descriptor, "wb", closefd=True) as stream:
                descriptor = None
                stream.write(contents)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(
                pending,
                destination.name,
                src_dir_fd=parent,
                dst_dir_fd=parent,
            )
            os.fsync(parent)
        finally:
            if descriptor is not None:
                os.close(descriptor)
            try:
                os.unlink(pending, dir_fd=parent)
            except FileNotFoundError:
                pass


def synchronise_directory(directory: Path) -> None:
    """Commit a rename itself, which an fsync of the renamed file does not cover."""

    descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def reset_file(root: Path, destination: Path) -> None:
    """Create or truncate a run-owned regular file without following a link."""

    with directory_descriptor(root, destination.parent, create=True) as parent:
        descriptor = os.open(
            destination.name,
            os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW,
            0o600,
            dir_fd=parent,
        )
        os.close(descriptor)


class RunLease:
    """Hold an exclusive advisory lease for one result path until closed."""

    def __init__(self, output: Path) -> None:
        self.path = output.parent / f".{output.name}.claude-prompt-conformance.lock"
        self._descriptor: int | None = None

    def acquire(self) -> None:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            descriptor = os.open(
                self.path,
                os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW,
                0o600,
            )
        except OSError as error:
            raise RunLeaseOpenError(self.path, error) from error
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
        except OSError as error:
            os.close(descriptor)
            raise RunLeaseAcquireError(self.path, error) from error
        self._descriptor = descriptor

    def __enter__(self) -> Self:
        self.acquire()
        return self

    def __exit__(
        self,
        exception_type: type[BaseException] | None,
        exception: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self.close()

    def close(self) -> None:
        descriptor = self._descriptor
        if descriptor is None:
            return
        self._descriptor = None
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)
        except OSError as error:
            raise RunLeaseReleaseError(self.path, error) from error


def pending_files(destination: Path) -> tuple[Path, ...]:
    """List complete atomic-write candidates left by an interrupted process."""

    candidates = (
        destination.with_name(f".{destination.name}.new"),
        destination.with_name(f"{destination.name}.new"),
        *destination.parent.glob(f".{destination.name}.*.new"),
        *destination.parent.glob(f"{destination.name}.*.new"),
    )
    return tuple(
        sorted({path for path in candidates if path.exists() or path.is_symlink()})
    )
