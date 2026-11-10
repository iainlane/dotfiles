import json
import re
import subprocess
import sys


def notice(tag: str, url: str) -> str:
    match = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", tag)
    if match is None:
        raise ValueError(f"Unexpected TeamClaude release tag: {tag}")
    if tuple(map(int, match.groups())) <= (1, 1, 26):
        return ""
    return (
        f"TeamClaude {tag} is available: {url}\n"
        "Review upstream PR #621 before replacing the pinned fork.\n"
    )


def main() -> int:
    if len(sys.argv) != 1:
        print("Usage: update-teamclaude", file=sys.stderr)
        return 1
    try:
        result = subprocess.check_output(
            ["gh", "api", "repos/KarpelesLab/teamclaude/releases/latest"], text=True
        )
        release = json.loads(result)
        sys.stdout.write(notice(release["tag_name"], release["html_url"]))
    except (subprocess.CalledProcessError, OSError, ValueError, KeyError) as error:
        print(f"Could not check TeamClaude releases: {error}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
