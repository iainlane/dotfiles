import asyncio
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from mcp import Client, StdioServerParameters


@dataclass(frozen=True)
class Server:
    program: Path
    name: str

    async def check(
        self, mode: Literal["legacy", "2026-07-28"], url: str | None = None
    ) -> None:
        parameters = url or StdioServerParameters(
            command=str(self.program), env={"FASTMCP_CHECK_FOR_UPDATES": "off"}
        )
        async with asyncio.timeout(60), Client(parameters, mode=mode) as client:
            tools = await client.list_tools()
            server = client.server_info
            if mode == "legacy":
                assert server is not None
                assert server.name == self.name
            assert client.protocol_version == (
                "2025-11-25" if mode == "legacy" else mode
            )
            assert tools.tools

    async def check_proxy(self, proxy: Path) -> None:
        process = await asyncio.create_subprocess_exec(
            str(proxy),
            "--",
            str(self.program),
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        assert process.stderr is not None
        try:
            async with asyncio.timeout(60):
                async for line in process.stderr:
                    message = line.decode()
                    print(message, end="", file=sys.stderr)
                    if match := re.search(
                        r"Uvicorn running on (http://127\.0\.0\.1:\d+)", message
                    ):
                        await self.check("legacy", f"{match[1]}/mcp")
                        return
                raise RuntimeError("MCP proxy exited before accepting connections")
        finally:
            if process.returncode is None:
                process.terminate()
            async with asyncio.timeout(15):
                _ = await process.wait()


def main() -> None:
    nixos, git, proxy = (Path(argument) for argument in sys.argv[1:])
    servers = (Server(nixos, "mcp-nixos"), Server(git, "mcp-git"))
    for server in servers:
        asyncio.run(server.check("legacy"))
        asyncio.run(server.check("2026-07-28"))
    asyncio.run(servers[1].check_proxy(proxy))


if __name__ == "__main__":
    main()
