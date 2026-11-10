import unittest

from update import notice


class NoticeTest(unittest.TestCase):
    def test_reports_only_newer_upstream_releases(self) -> None:
        cases = {
            "v1.1.25": "",
            "v1.1.26": "",
            "v1.1.27": (
                "TeamClaude v1.1.27 is available: https://example.invalid/release\n"
                "Review upstream PR #621 before replacing the pinned fork.\n"
            ),
        }
        self.assertEqual(
            {tag: notice(tag, "https://example.invalid/release") for tag in cases},
            cases,
        )


if __name__ == "__main__":
    unittest.main()
