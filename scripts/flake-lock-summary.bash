#!/usr/bin/env bash

# Summarise the top-level input changes between two flake.lock files as a
# Markdown list, for the body of the automated flake-update pull request.
#
# Usage: flake-lock-summary.bash <before.json> <after.json>

set -euo pipefail

before="${1:?usage: flake-lock-summary.bash <before> <after>}"
after="${2:?usage: flake-lock-summary.bash <before> <after>}"

jq -rn --slurpfile before "${before}" --slurpfile after "${after}" '
  def version($lock; $name):
    $lock.nodes.root.inputs[$name] as $id
    | if $id == null then null
      else $lock.nodes[$id] as $node
        | { ref: ($node.original.ref // $node.locked.ref),
            rev: ($node.locked.rev // $node.locked.narHash) }
      end;

  ($before[0]) as $b
  | ($after[0]) as $a
  | (($b.nodes.root.inputs // {}) + ($a.nodes.root.inputs // {}) | keys)
  | map(
      . as $name
      | version($b; $name) as $old
      | version($a; $name) as $new
      | select($old != $new)
      | if $old == null then "- `\($name)`: added"
        elif $new == null then "- `\($name)`: removed"
        elif ($old.ref // "") != ($new.ref // "")
          then "- `\($name)`: `\($old.ref)` → `\($new.ref)`"
        else "- `\($name)`: `\($old.rev[0:7])` → `\($new.rev[0:7])`"
        end)
  | .[]
'
