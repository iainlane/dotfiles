import json
import unittest

from update_plan import Node, Plan


def path_info(references: dict[str, list[str]]) -> str:
    return json.dumps({path: {"references": refs} for path, refs in references.items()})


# nixpkgs/stdenv is shared by every package. `host` depends on the `source`
# flake input, `plugin` builds on `host`, and `docs` depends on nothing local.
# `mac-app` has no derivation on this system.
REFERENCES = {
    "/nix/store/host.drv": ["/nix/store/source", "/nix/store/stdenv.drv"],
    "/nix/store/plugin.drv": ["/nix/store/tarball.drv", "/nix/store/stdenv.drv"],
    "/nix/store/tarball.drv": ["/nix/store/host.drv"],
    "/nix/store/docs.drv": ["/nix/store/stdenv.drv"],
    "/nix/store/stdenv.drv": [],
    "/nix/store/source": [],
}
NODES = [
    Node(name="plugin", path="/nix/store/plugin.drv", updater=True),
    Node(name="docs", path="/nix/store/docs.drv", updater=True),
    Node(name="host", path="/nix/store/host.drv", updater=False),
    Node(name="source", path="/nix/store/source", updater=True),
    Node(name="mac-app", path=None, updater=True),
]


class PlanTest(unittest.TestCase):
    def plan(self, output: str) -> Plan:
        def query(paths: list[str]) -> str:
            self.assertEqual(
                paths,
                [
                    node.path
                    for node in NODES
                    if node.path is not None and node.path.endswith(".drv")
                ],
            )
            return output

        return Plan.from_query(NODES, query)

    def test_orders_updaters_after_what_they_depend_on(self) -> None:
        self.assertEqual(
            self.plan(path_info(REFERENCES)).order(),
            ["docs", "mac-app", "source", "plugin"],
        )

    def test_reads_the_list_form_of_path_info(self) -> None:
        listed = json.dumps(
            [{"path": path, "references": refs} for path, refs in REFERENCES.items()]
        )
        self.assertEqual(
            self.plan(listed).order(), ["docs", "mac-app", "source", "plugin"]
        )

    def test_selects_the_updaters_downstream_of_changed_packages(self) -> None:
        plan = self.plan(path_info(REFERENCES))
        cases = {
            ("host",): ["plugin"],
            ("source",): ["plugin"],
            ("docs",): [],
            ("plugin", "unknown"): [],
        }
        self.assertEqual(
            {changed: plan.downstream(list(changed)) for changed in cases}, cases
        )


if __name__ == "__main__":
    unittest.main()
