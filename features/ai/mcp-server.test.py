import asyncio
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from mcp import Client, StdioServerParameters


@dataclass(frozen=True)
class Server:
    program: Path
    name: str
    tools: tuple[str, ...]

    async def check(self, mode: Literal["legacy", "2026-07-28"]) -> None:
        parameters = StdioServerParameters(
            command=str(self.program), env={"FASTMCP_CHECK_FOR_UPDATES": "off"}
        )
        async with asyncio.timeout(60), Client(parameters, mode=mode) as client:
            tools = await client.list_tools()
            server = client.server_info
            if mode == "legacy":
                assert server is not None
                assert server.name == self.name
            assert (
                client.protocol_version,
                tuple(sorted(tool.name for tool in tools.tools)),
            ) == (
                "2025-11-25" if mode == "legacy" else mode,
                self.tools,
            )


def main() -> None:
    nixos, git = (Path(argument) for argument in sys.argv[1:])
    servers = (
        Server(nixos, "mcp-nixos", ("nix", "nix_versions")),
        Server(
            git,
            "mcp-git",
            (
                "git_add",
                "git_branch",
                "git_checkout",
                "git_commit",
                "git_create_branch",
                "git_diff",
                "git_diff_staged",
                "git_diff_unstaged",
                "git_log",
                "git_reset",
                "git_show",
                "git_status",
            ),
        ),
    )
    for server in servers:
        asyncio.run(server.check("legacy"))
        asyncio.run(server.check("2026-07-28"))


if __name__ == "__main__":
    main()
