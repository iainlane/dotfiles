import os
from pathlib import Path

from prose_lint.baseline import RETENTION_SECONDS, Baseline, prune


def test_a_later_baseline_does_not_replace_the_first(tmp_path: Path) -> None:
    path = tmp_path / "baselines" / "session.json"

    Baseline(digests={"first.md": "1"}).write_once(path)
    Baseline(digests={"second.md": "2"}).write_once(path)

    assert (Baseline.read(path), sorted(path.parent.iterdir())) == (
        Baseline(digests={"first.md": "1"}),
        [path],
    )


def test_pruning_deletes_only_the_expired_baselines(tmp_path: Path) -> None:
    now = 1_000_000_000.0
    expired = tmp_path / "expired.json"
    current = tmp_path / "current.json"
    Baseline(digests={}).write_once(expired)
    Baseline(digests={}).write_once(current)
    os.utime(expired, (now, now - RETENTION_SECONDS - 1))
    os.utime(current, (now, now - RETENTION_SECONDS + 1))

    prune(tmp_path, now=now)

    assert sorted(tmp_path.iterdir()) == [current]
