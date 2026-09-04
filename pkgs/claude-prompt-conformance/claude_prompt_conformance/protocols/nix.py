"""Schemas emitted by Nix commands."""

import msgspec


class NixBuildResult(msgspec.Struct, frozen=True):
    outputs: dict[str, str]
