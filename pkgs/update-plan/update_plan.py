"""Order the repository's updaters by Nix's derivation graph.

A node is a local package, identified by its derivation path, or a flake input
with an updater, identified by its source's store path. A package that this
system cannot build has no path and depends on nothing. A flake input's source
depends on nothing either, so only derivations are queried. A node depends on
every other node whose path is in the closure of its own path. Each updater
runs after the updaters of its dependencies, so it sees the versions that those
updaters chose.
"""

import argparse
import heapq
import json
import subprocess
import sys
from collections.abc import Callable
from dataclasses import dataclass


@dataclass(frozen=True)
class Node:
    name: str
    path: str | None
    updater: bool
    refresh: bool = False
    dependencies: list[str] | None = None


def references(output: str) -> dict[str, list[str]]:
    """Read the references from `nix path-info --json`, which prints an object
    keyed by path, or a list of records in older Nix versions."""
    parsed = json.loads(output)
    records = (
        parsed.items()
        if isinstance(parsed, dict)
        else ((record["path"], record) for record in parsed)
    )
    return {path: record.get("references") or [] for path, record in records}


@dataclass(frozen=True)
class Plan:
    nodes: list[Node]
    # The names of the nodes that each node depends on.
    dependencies: dict[str, set[str]]

    @classmethod
    def from_query(cls, nodes: list[Node], query: Callable[[list[str]], str]) -> "Plan":
        derivations = [
            node.path
            for node in nodes
            if node.path is not None and node.path.endswith(".drv")
        ]
        graph = references(query(derivations))
        by_path = {node.path: node.name for node in nodes if node.path is not None}

        def closure(start: str) -> set[str]:
            seen: set[str] = set()
            pending = list(graph.get(start, []))
            while pending:
                path = pending.pop()
                if path in seen:
                    continue
                seen.add(path)
                pending.extend(graph.get(path, []))
            return seen

        dependencies = {
            node.name: {
                by_path[path]
                for path in closure(node.path)
                if path in by_path and path != node.path
            }
            if node.path is not None
            else set()
            for node in nodes
        }
        for node in nodes:
            if node.dependencies is not None:
                dependencies[node.name] = set(node.dependencies)
        return cls(nodes=nodes, dependencies=dependencies)

    def _sorted(self, names: set[str], *, refresh: bool = False) -> list[str]:
        """The updaters among `names`, each after its dependencies. Names that
        are ready together appear in alphabetical order."""
        updaters = {
            node.name
            for node in self.nodes
            if node.updater and (not refresh or node.refresh)
        }
        waiting = {name: self.dependencies[name] & names for name in names}
        ready = [name for name, needs in waiting.items() if not needs]
        heapq.heapify(ready)
        order: list[str] = []
        visited: set[str] = set()
        while ready:
            name = heapq.heappop(ready)
            visited.add(name)
            if name in updaters:
                order.append(name)
            for other, needs in waiting.items():
                if name in needs:
                    needs.discard(name)
                    if not needs:
                        heapq.heappush(ready, other)
        if visited != names:
            raise ValueError(
                "Maintenance dependency cycle: " + ", ".join(sorted(names - visited))
            )
        return order

    def order(self, *, refresh: bool = False) -> list[str]:
        return self._sorted({node.name for node in self.nodes}, refresh=refresh)

    def describe(self) -> dict:
        dependencies: dict[str, list[str]] = {}
        for name in self.dependencies:
            seen: set[str] = set()
            pending = list(self.dependencies[name])
            while pending:
                dependency = pending.pop()
                if dependency not in seen:
                    seen.add(dependency)
                    pending.extend(self.dependencies[dependency])
            dependencies[name] = sorted(seen)
        return {
            "order": self.order(),
            "refreshOrder": self.order(refresh=True),
            "dependencies": dependencies,
        }

    def downstream(self, changed: list[str]) -> list[str]:
        """The updaters of the nodes that depend on a changed node. Each
        changed node already has its new version, so its own updater does not
        run."""
        known = [name for name in changed if name in self.dependencies]
        for name in sorted(set(changed) - set(known)):
            print(f"update-plan: {name} is not a node on this system", file=sys.stderr)
        affected = {
            name for name, needs in self.dependencies.items() if needs & set(known)
        } - set(known)
        return self._sorted(affected)


def path_info(paths: list[str]) -> str:
    if not paths:
        return "{}"
    return subprocess.run(
        ["nix", "path-info", "--recursive", "--json", "--json-format", "1", *paths],
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--nodes", required=True, help="JSON list of {name, path, updater} records"
    )
    commands = parser.add_subparsers(dest="command", required=True)
    order = commands.add_parser("order", help="print every updater in dependency order")
    order.add_argument("--refresh", action="store_true")
    commands.add_parser(
        "describe", help="print maintenance order and dependencies as JSON"
    )
    downstream = commands.add_parser(
        "downstream", help="print the updaters of nodes that depend on changed nodes"
    )
    downstream.add_argument("changed", nargs="*")
    arguments = parser.parse_args()

    with open(arguments.nodes) as file:
        nodes = [Node(**record) for record in json.load(file)]
    plan = Plan.from_query(nodes, path_info)
    if arguments.command == "describe":
        print(json.dumps(plan.describe(), sort_keys=True))
        return
    names = (
        plan.order(refresh=arguments.refresh)
        if arguments.command == "order"
        else plan.downstream(arguments.changed)
    )
    for name in names:
        print(name)


if __name__ == "__main__":
    main()
