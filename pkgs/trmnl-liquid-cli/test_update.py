import io
import struct
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import update


def section(number: int, payload: bytes) -> bytes:
    header = bytearray(64)
    header[:8] = b"DWARFS\x02\x05"
    struct.pack_into("<I", header, 48, number)
    struct.pack_into("<Q", header, 56, len(payload))
    return bytes(header) + payload


class UpdateTests(unittest.TestCase):
    def test_stable_container_tags(self):
        tags = ["latest", "0.1.0", "0.2.0", "0.3.0-rc1", "0.10.0"]
        self.assertEqual(update.latest_version(tags), "0.10.0")

    def test_embedded_filesystem_has_elf_bytes_after_it(self):
        image = section(0, b"data") + section(1, b"metadata")
        self.assertEqual(
            update.embedded_filesystem(b"ELF prefix" + image + b"ELF suffix"), image
        )

    def test_truncated_filesystem_is_rejected(self):
        with self.assertRaisesRegex(update.UpdateError, "truncated"):
            update.embedded_filesystem(b"ELF prefix" + section(0, b"data")[:-1])

    def test_publication_failure_restores_all_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            originals = {"first": b"original first", "second": b"original second"}
            for name, content in originals.items():
                (root / name).write_bytes(content)
            replace = update.os.replace

            def fail_second(source, destination):
                if destination.name == "second":
                    raise OSError("injected publication failure")
                replace(source, destination)

            with (
                patch.object(update.os, "replace", side_effect=fail_second),
                self.assertRaisesRegex(OSError, "injected"),
            ):
                update.publish(
                    root, {"first": b"changed first", "second": b"changed second"}
                )
            self.assertEqual(
                {name: (root / name).read_bytes() for name in originals}, originals
            )

    def test_registry_blob_rejects_changed_bytes(self):
        registry = update.Registry.__new__(update.Registry)
        registry.headers = {}
        with (
            patch.object(update, "fetch", return_value=b"changed"),
            self.assertRaisesRegex(update.UpdateError, "do not match"),
        ):
            registry.blob("blobs/expected", "sha256:" + "0" * 64)

    def test_removed_container_binary_is_not_read_from_a_lower_layer(self):
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w") as archive:
            member = tarfile.TarInfo("usr/local/bin/.wh.trmnl-liquid-cli")
            archive.addfile(member)
        lower = io.BytesIO()
        with tarfile.open(fileobj=lower, mode="w") as archive:
            member = tarfile.TarInfo("usr/local/bin/trmnl-liquid-cli")
            member.size = len(b"old binary")
            archive.addfile(member, io.BytesIO(b"old binary"))
        registry = update.Registry.__new__(update.Registry)
        registry.headers = {}
        with (
            patch.object(
                registry, "blob", side_effect=[buffer.getvalue(), lower.getvalue()]
            ) as blob,
            self.assertRaisesRegex(update.UpdateError, "removed"),
        ):
            registry.binary(update.Release("0.2.0", "manifest", ["lower", "upper"]))
        self.assertEqual(blob.call_count, 1)

    def test_replaced_container_binary_is_not_read_from_a_lower_layer(self):
        upper = io.BytesIO()
        with tarfile.open(fileobj=upper, mode="w") as archive:
            member = tarfile.TarInfo("usr/local/bin/trmnl-liquid-cli")
            member.type = tarfile.SYMTYPE
            member.linkname = "/different/program"
            archive.addfile(member)
        lower = io.BytesIO()
        with tarfile.open(fileobj=lower, mode="w") as archive:
            member = tarfile.TarInfo("usr/local/bin/trmnl-liquid-cli")
            member.size = len(b"old binary")
            archive.addfile(member, io.BytesIO(b"old binary"))
        registry = update.Registry.__new__(update.Registry)
        registry.headers = {}
        with (
            patch.object(
                registry, "blob", side_effect=[upper.getvalue(), lower.getvalue()]
            ) as blob,
            self.assertRaisesRegex(update.UpdateError, "regular file"),
        ):
            registry.binary(update.Release("0.2.0", "manifest", ["lower", "upper"]))
        self.assertEqual(blob.call_count, 1)


if __name__ == "__main__":
    unittest.main()
