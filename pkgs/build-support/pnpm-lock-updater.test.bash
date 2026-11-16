set -euo pipefail

updater="$1"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
git -C "$root" init --quiet

# The fakes in flake/local-packages/checks/npm-packages.nix read these. `nix
# build .#<attribute>.tarball` packs `$FAKE_PACKAGES/<attribute>` into
# `$FAKE_STORE/<attribute>-tarball/package.tgz`, and pnpm resolves from
# `$FAKE_REGISTRY`.
export FAKE_PACKAGES="$root/packages" FAKE_REGISTRY="$root/registry.json" FAKE_STORE="$root/store"

# GitHub Actions, which runs the updaters, sets CI, and pnpm reads it.
export CI=true

jq . >"$FAKE_REGISTRY" <<'JSON'
{
  "@scope/host": {"1.0.0": {}, "2.0.0": {}},
  "@scope/tui": {"1.0.0": {}, "1.1.0": {}, "1.2.0": {}},
  "linked": {"1.0.0": {}},
  "leaf": {"1.0.0": {}, "1.1.0": {}},
  "other": {
    "4.0.0": {"dependencies": {"leaf": "^1.0.0"}},
    "4.1.0": {"dependencies": {"leaf": "^1.0.0"}}
  },
  "uses-alias": {"1.0.0": {"dependencies": {"renamed": "npm:@scope/host@^2.0.0"}}},
  "uses-host": {"1.0.0": {"dependencies": {"@scope/host": "^2.0.0"}}},
  "uses-linked": {"1.0.0": {"dependencies": {"linked": "^1.0.0"}}},
  "host-plugin": {
    "1.0.0": {"dependencies": {"@scope/host": "^2.0.0"}, "peerDependencies": {"linked": "^1.0.0"}}
  },
  "@scope/widgets": {
    "1.0.0": {"peerDependencies": {"keymap": "^1.0.0", "theme": "^1.0.0"}}
  },
  "keymap": {"1.0.0": {}},
  "theme": {"1.0.0": {}},
  "chain-start": {"1.0.0": {"dependencies": {"chain-0": "^1.0.0"}}},
  "chain-0": {"1.0.0": {}}, "chain-1": {"1.0.0": {}}, "chain-2": {"1.0.0": {}},
  "chain-3": {"1.0.0": {}}, "chain-4": {"1.0.0": {}}, "chain-5": {"1.0.0": {}},
  "chain-6": {"1.0.0": {}}, "chain-7": {"1.0.0": {}}, "chain-8": {"1.0.0": {}},
  "chain-9": {"1.0.0": {}}
}
JSON

printf '%s\n' '{"semverGroups": [{"dependencies": ["@scope/tui"], "range": ""}, {"range": "^"}]}' >"$root/.syncpackrc.json"

# Writes the manifest of each local package, keyed by attribute name, from
# which the fake nix packs the package's tarball. The catalogue in
# npm-packages.nix lists the same packages.
local_packages() {
	rm -rf "$FAKE_PACKAGES"
	while IFS=$'\t' read -r attribute manifest; do
		mkdir -p "$FAKE_PACKAGES/$attribute"
		printf '%s\n' "$manifest" >"$FAKE_PACKAGES/$attribute/package.json"
	done < <(jq -r 'to_entries[] | [.key, (.value | tojson)] | @tsv' <<<"$1")
}

default_packages='{
  "host": {"name": "@scope/host", "version": "2.0.0"},
  "linked": {"name": "linked", "version": "1.0.0"},
  "consumer": {"name": "@dotfiles/consumer", "version": "1.0.0", "dependencies": {"@dotfiles/private": "^0.1.0", "other": "^4"}},
  "private": {"name": "@dotfiles/private", "version": "0.1.0"}
}'
for count in $(seq 0 9); do
	next=$((count + 1))
	dependencies="{\"chain-$next\": \"^1.0.0\"}"
	if ((count == 9)); then
		dependencies='{}'
	fi
	default_packages="$(jq --arg name "chain-$count" --argjson dependencies "$dependencies" '. + {($name): {name: $name, version: "1.0.0", dependencies: $dependencies}}' <<<"$default_packages")"
done

# Starts the project from its manifests, keyed by path, and its
# pnpm-workspace.yaml. A third argument is the committed pnpm-lock.yaml.
project() {
	rm -rf "$root/scenario"
	mkdir "$root/scenario"
	while IFS=$'\t' read -r path manifest; do
		mkdir -p "$root/scenario/$(dirname "$path")"
		printf '%s\n' "$manifest" >"$root/scenario/$path"
	done < <(jq -r 'to_entries[] | [.key, (.value | tojson)] | @tsv' <<<"$1")
	printf '%s\n' "$2" >"$root/scenario/pnpm-workspace.yaml"
	if (($# > 2)); then
		printf '%s\n' "$3" >"$root/scenario/pnpm-lock.yaml"
	fi
	printf '%s\n' '{' '  dependencyHash = "sha256-old";' '}' >"$root/scenario/package.nix"
	local_packages "$default_packages"
}

update() {
	(cd "$root/scenario" && "$updater" "$@")
}

# Prints the project as one object: its manifests keyed by path, its workspace,
# its lockfile, the links in `.nix-providers`, and whether package.nix has the
# lockfile's hash.
state() {
	cd "$root/scenario"
	local manifests links hash
	manifests="$(find . -name package.json -not -path './.nix-providers/*' | sed 's|^\./||' | LC_ALL=C sort | xargs jq -n '[inputs | {(input_filename): .}] | add')"
	links='{}'
	shopt -s nullglob
	for link in .nix-providers/*; do
		links="$(jq --arg file "${link##*/}" --arg target "$(readlink "$link")" --arg store "$FAKE_STORE/" '. + {($file): ($target | ltrimstr($store))}' <<<"$links")"
	done
	shopt -u nullglob
	hash="$(sha256sum pnpm-lock.yaml | cut -d ' ' -f 1)"
	jq -n --sort-keys \
		--argjson manifests "$manifests" \
		--argjson workspace "$(yq -o=json . pnpm-workspace.yaml)" \
		--argjson lockfile "$(yq -o=json . pnpm-lock.yaml)" \
		--argjson links "$links" \
		--argjson hashed "$(grep -qF "dependencyHash = \"sha256-$hash\";" package.nix && echo true || echo false)" \
		'{$manifests, $workspace, $lockfile, $links, $hashed}'
	cd - >/dev/null
}

expect() {
	jq --sort-keys . | diff -u - <(state)
}

workspace='packages:
  - "."'

# The updater points the manifests' dependencies on local packages and their npm
# aliases at caret ranges of the local versions, and the project's own peer at
# its tarball. It replaces the stale provider overrides with one for each local
# package and each alias, and keeps the other overrides.
project '{"package.json": {
  "name": "fixture",
  "dependencies": {"@scope/host": "^1", "alias": "npm:@scope/host@~1", "other": "^4"},
  "devDependencies": {"linked": "^0", "plain": "npm:linked"},
  "optionalDependencies": {"scoped": "npm:@scope/host"},
  "peerDependencies": {"@scope/host": "^1"}
}}' "$workspace"'
overrides:
  other>dependency: "-"
  "@scope/host": file:.nix-providers/scope-host-1.0.0.tgz
  gone: file:.nix-providers/gone-1.0.0.tgz'
update
expect <<'JSON'
{
  "hashed": true,
  "links": {
    "linked-1.0.0.tgz": "linked-tarball/package.tgz",
    "scope-host-2.0.0.tgz": "host-tarball/package.tgz"
  },
  "lockfile": {
    "importers": {
      ".": {
        "dependencies": {
          "@scope/host": {
            "specifier": "file:.nix-providers/scope-host-2.0.0.tgz",
            "version": "file:.nix-providers/scope-host-2.0.0.tgz"
          },
          "alias": {
            "specifier": "file:.nix-providers/scope-host-2.0.0.tgz",
            "version": "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz"
          },
          "other": {"specifier": "^4", "version": "4.1.0"}
        },
        "devDependencies": {
          "linked": {
            "specifier": "file:.nix-providers/linked-1.0.0.tgz",
            "version": "file:.nix-providers/linked-1.0.0.tgz"
          },
          "plain": {
            "specifier": "file:.nix-providers/linked-1.0.0.tgz",
            "version": "linked@file:.nix-providers/linked-1.0.0.tgz"
          }
        },
        "optionalDependencies": {
          "scoped": {
            "specifier": "file:.nix-providers/scope-host-2.0.0.tgz",
            "version": "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz"
          }
        }
      }
    },
    "lockfileVersion": "9.0",
    "overrides": {
      "alias": "file:.nix-providers/scope-host-2.0.0.tgz",
      "linked": "file:.nix-providers/linked-1.0.0.tgz",
      "other>dependency": "-",
      "plain": "file:.nix-providers/linked-1.0.0.tgz",
      "scoped": "file:.nix-providers/scope-host-2.0.0.tgz"
    },
    "packages": {
      "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz": {
        "resolution": {"tarball": "file:.nix-providers/scope-host-2.0.0.tgz"}
      },
      "leaf@1.1.0": {"resolution": {"integrity": "sha512-leaf-1.1.0"}},
      "linked@file:.nix-providers/linked-1.0.0.tgz": {
        "resolution": {"tarball": "file:.nix-providers/linked-1.0.0.tgz"}
      },
      "other@4.1.0": {"resolution": {"integrity": "sha512-other-4.1.0"}}
    },
    "snapshots": {
      "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz": {},
      "leaf@1.1.0": {},
      "linked@file:.nix-providers/linked-1.0.0.tgz": {},
      "other@4.1.0": {"dependencies": {"leaf": "1.1.0"}}
    }
  },
  "manifests": {
    "package.json": {
      "dependencies": {
        "@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz",
        "alias": "npm:@scope/host@^2.0.0",
        "other": "^4"
      },
      "devDependencies": {"linked": "^1.0.0", "plain": "npm:linked@^1.0.0"},
      "name": "fixture",
      "optionalDependencies": {"scoped": "npm:@scope/host@^2.0.0"},
      "peerDependencies": {"@scope/host": "^1"}
    }
  },
  "workspace": {
    "overrides": {
      "alias": "file:.nix-providers/scope-host-2.0.0.tgz",
      "linked": "file:.nix-providers/linked-1.0.0.tgz",
      "other>dependency": "-",
      "plain": "file:.nix-providers/linked-1.0.0.tgz",
      "scoped": "file:.nix-providers/scope-host-2.0.0.tgz"
    },
    "packages": ["."]
  }
}
JSON

# A project that no longer uses local packages keeps no empty overrides map.
project '{"package.json": {"name": "plain", "dependencies": {"other": "^4"}}}' "$workspace"'
overrides:
  gone: file:.nix-providers/gone-1.0.0.tgz'
update
expect <<'JSON'
{
  "hashed": true,
  "links": {},
  "lockfile": {
    "importers": {
      ".": {"dependencies": {"other": {"specifier": "^4", "version": "4.1.0"}}}
    },
    "lockfileVersion": "9.0",
    "packages": {
      "leaf@1.1.0": {"resolution": {"integrity": "sha512-leaf-1.1.0"}},
      "other@4.1.0": {"resolution": {"integrity": "sha512-other-4.1.0"}}
    },
    "snapshots": {
      "leaf@1.1.0": {},
      "other@4.1.0": {"dependencies": {"leaf": "1.1.0"}}
    }
  },
  "manifests": {
    "package.json": {"dependencies": {"other": "^4"}, "name": "plain"}
  },
  "workspace": {"packages": ["."]}
}
JSON

# A private local package has no registry release, so the updater links and
# overrides it before the first relock.
project '{"package.json": {"devDependencies": {"@dotfiles/private": "^0.1.0"}}}' "$workspace"
update
expect <<'JSON'
{
  "hashed": true,
  "links": {"dotfiles-private-0.1.0.tgz": "private-tarball/package.tgz"},
  "lockfile": {
    "importers": {
      ".": {
        "devDependencies": {
          "@dotfiles/private": {
            "specifier": "file:.nix-providers/dotfiles-private-0.1.0.tgz",
            "version": "file:.nix-providers/dotfiles-private-0.1.0.tgz"
          }
        }
      }
    },
    "lockfileVersion": "9.0",
    "overrides": {
      "@dotfiles/private": "file:.nix-providers/dotfiles-private-0.1.0.tgz"
    },
    "packages": {
      "@dotfiles/private@file:.nix-providers/dotfiles-private-0.1.0.tgz": {
        "resolution": {
          "tarball": "file:.nix-providers/dotfiles-private-0.1.0.tgz"
        }
      }
    },
    "snapshots": {
      "@dotfiles/private@file:.nix-providers/dotfiles-private-0.1.0.tgz": {}
    }
  },
  "manifests": {
    "package.json": {"devDependencies": {"@dotfiles/private": "^0.1.0"}}
  },
  "workspace": {
    "overrides": {
      "@dotfiles/private": "file:.nix-providers/dotfiles-private-0.1.0.tgz"
    },
    "packages": ["."]
  }
}
JSON

# A local package from this repository depends on a private local package, which
# the first relock could not resolve either.
project '{"package.json": {"dependencies": {"@dotfiles/consumer": "^1.0.0"}}}' "$workspace"
update
expect <<'JSON'
{
  "hashed": true,
  "links": {
    "dotfiles-consumer-1.0.0.tgz": "consumer-tarball/package.tgz",
    "dotfiles-private-0.1.0.tgz": "private-tarball/package.tgz"
  },
  "lockfile": {
    "importers": {
      ".": {
        "dependencies": {
          "@dotfiles/consumer": {
            "specifier": "file:.nix-providers/dotfiles-consumer-1.0.0.tgz",
            "version": "file:.nix-providers/dotfiles-consumer-1.0.0.tgz"
          }
        }
      }
    },
    "lockfileVersion": "9.0",
    "overrides": {
      "@dotfiles/consumer": "file:.nix-providers/dotfiles-consumer-1.0.0.tgz",
      "@dotfiles/private": "file:.nix-providers/dotfiles-private-0.1.0.tgz"
    },
    "packages": {
      "@dotfiles/consumer@file:.nix-providers/dotfiles-consumer-1.0.0.tgz": {
        "resolution": {
          "tarball": "file:.nix-providers/dotfiles-consumer-1.0.0.tgz"
        }
      },
      "@dotfiles/private@file:.nix-providers/dotfiles-private-0.1.0.tgz": {
        "resolution": {
          "tarball": "file:.nix-providers/dotfiles-private-0.1.0.tgz"
        }
      },
      "leaf@1.1.0": {"resolution": {"integrity": "sha512-leaf-1.1.0"}},
      "other@4.1.0": {"resolution": {"integrity": "sha512-other-4.1.0"}}
    },
    "snapshots": {
      "@dotfiles/consumer@file:.nix-providers/dotfiles-consumer-1.0.0.tgz": {
        "dependencies": {
          "@dotfiles/private": "file:.nix-providers/dotfiles-private-0.1.0.tgz",
          "other": "4.1.0"
        }
      },
      "@dotfiles/private@file:.nix-providers/dotfiles-private-0.1.0.tgz": {},
      "leaf@1.1.0": {},
      "other@4.1.0": {"dependencies": {"leaf": "1.1.0"}}
    }
  },
  "manifests": {
    "package.json": {"dependencies": {"@dotfiles/consumer": "^1.0.0"}}
  },
  "workspace": {
    "overrides": {
      "@dotfiles/consumer": "file:.nix-providers/dotfiles-consumer-1.0.0.tgz",
      "@dotfiles/private": "file:.nix-providers/dotfiles-private-0.1.0.tgz"
    },
    "packages": ["."]
  }
}
JSON

# A registry package depends on a local package, and the first relock resolves
# the local package's registry release.
project '{"package.json": {"dependencies": {"uses-linked": "^1"}}}' "$workspace"
update
expect <<'JSON'
{
  "hashed": true,
  "links": {"linked-1.0.0.tgz": "linked-tarball/package.tgz"},
  "lockfile": {
    "importers": {
      ".": {
        "dependencies": {"uses-linked": {"specifier": "^1", "version": "1.0.0"}}
      }
    },
    "lockfileVersion": "9.0",
    "overrides": {"linked": "file:.nix-providers/linked-1.0.0.tgz"},
    "packages": {
      "linked@file:.nix-providers/linked-1.0.0.tgz": {
        "resolution": {"tarball": "file:.nix-providers/linked-1.0.0.tgz"}
      },
      "uses-linked@1.0.0": {
        "resolution": {"integrity": "sha512-uses-linked-1.0.0"}
      }
    },
    "snapshots": {
      "linked@file:.nix-providers/linked-1.0.0.tgz": {},
      "uses-linked@1.0.0": {
        "dependencies": {"linked": "file:.nix-providers/linked-1.0.0.tgz"}
      }
    }
  },
  "manifests": {"package.json": {"dependencies": {"uses-linked": "^1"}}},
  "workspace": {
    "overrides": {"linked": "file:.nix-providers/linked-1.0.0.tgz"},
    "packages": ["."]
  }
}
JSON

# An npm alias of a local package in the manifest.
project '{"package.json": {"devDependencies": {"old": "npm:linked@^1"}}}' "$workspace"
update
expect <<'JSON'
{
  "hashed": true,
  "links": {"linked-1.0.0.tgz": "linked-tarball/package.tgz"},
  "lockfile": {
    "importers": {
      ".": {
        "devDependencies": {
          "old": {
            "specifier": "file:.nix-providers/linked-1.0.0.tgz",
            "version": "linked@file:.nix-providers/linked-1.0.0.tgz"
          }
        }
      }
    },
    "lockfileVersion": "9.0",
    "overrides": {
      "linked": "file:.nix-providers/linked-1.0.0.tgz",
      "old": "file:.nix-providers/linked-1.0.0.tgz"
    },
    "packages": {
      "linked@file:.nix-providers/linked-1.0.0.tgz": {
        "resolution": {"tarball": "file:.nix-providers/linked-1.0.0.tgz"}
      }
    },
    "snapshots": {"linked@file:.nix-providers/linked-1.0.0.tgz": {}}
  },
  "manifests": {
    "package.json": {"devDependencies": {"old": "npm:linked@^1.0.0"}}
  },
  "workspace": {
    "overrides": {
      "linked": "file:.nix-providers/linked-1.0.0.tgz",
      "old": "file:.nix-providers/linked-1.0.0.tgz"
    },
    "packages": ["."]
  }
}
JSON

# A registry package depends on an npm alias of a local package.
project '{"package.json": {"dependencies": {"uses-alias": "^1"}}}' "$workspace"
update
expect <<'JSON'
{
  "hashed": true,
  "links": {"scope-host-2.0.0.tgz": "host-tarball/package.tgz"},
  "lockfile": {
    "importers": {
      ".": {
        "dependencies": {"uses-alias": {"specifier": "^1", "version": "1.0.0"}}
      }
    },
    "lockfileVersion": "9.0",
    "overrides": {
      "@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz",
      "renamed": "file:.nix-providers/scope-host-2.0.0.tgz"
    },
    "packages": {
      "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz": {
        "resolution": {"tarball": "file:.nix-providers/scope-host-2.0.0.tgz"}
      },
      "uses-alias@1.0.0": {
        "resolution": {"integrity": "sha512-uses-alias-1.0.0"}
      }
    },
    "snapshots": {
      "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz": {},
      "uses-alias@1.0.0": {
        "dependencies": {
          "renamed": "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz"
        }
      }
    }
  },
  "manifests": {"package.json": {"dependencies": {"uses-alias": "^1"}}},
  "workspace": {
    "overrides": {
      "@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz",
      "renamed": "file:.nix-providers/scope-host-2.0.0.tgz"
    },
    "packages": ["."]
  }
}
JSON

# pnpm turns a global override of the project's own peer into a production
# dependency. The project's dependency points at the tarball, and an override
# scoped to each dependent package replaces the registry release.
project '{"package.json": {
  "devDependencies": {"@scope/host": "^1", "uses-host": "^1"},
  "peerDependencies": {"@scope/host": "^1"}
}}' "$workspace"
update
expect <<'JSON'
{
  "hashed": true,
  "links": {"scope-host-2.0.0.tgz": "host-tarball/package.tgz"},
  "lockfile": {
    "importers": {
      ".": {
        "devDependencies": {
          "@scope/host": {
            "specifier": "file:.nix-providers/scope-host-2.0.0.tgz",
            "version": "file:.nix-providers/scope-host-2.0.0.tgz"
          },
          "uses-host": {"specifier": "^1", "version": "1.0.0"}
        }
      }
    },
    "lockfileVersion": "9.0",
    "overrides": {
      "uses-host>@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz"
    },
    "packages": {
      "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz": {
        "resolution": {"tarball": "file:.nix-providers/scope-host-2.0.0.tgz"}
      },
      "uses-host@1.0.0": {"resolution": {"integrity": "sha512-uses-host-1.0.0"}}
    },
    "snapshots": {
      "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz": {},
      "uses-host@1.0.0": {
        "dependencies": {
          "@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz"
        }
      }
    }
  },
  "manifests": {
    "package.json": {
      "devDependencies": {
        "@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz",
        "uses-host": "^1"
      },
      "peerDependencies": {"@scope/host": "^1"}
    }
  },
  "workspace": {
    "overrides": {
      "uses-host>@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz"
    },
    "packages": ["."]
  }
}
JSON

# A registry package that has a local package as a peer resolves the project's
# copy of the peer, and its snapshot key and references end in the peer's
# version. The package also depends on the registry release of the project's
# peer, which an override scoped to the package replaces.
project '{"package.json": {
  "devDependencies": {"@scope/host": "^1", "host-plugin": "^1", "linked": "^1"},
  "peerDependencies": {"@scope/host": "^1"}
}}' "$workspace"
update
expect <<'JSON'
{
  "hashed": true,
  "links": {
    "linked-1.0.0.tgz": "linked-tarball/package.tgz",
    "scope-host-2.0.0.tgz": "host-tarball/package.tgz"
  },
  "lockfile": {
    "importers": {
      ".": {
        "devDependencies": {
          "@scope/host": {
            "specifier": "file:.nix-providers/scope-host-2.0.0.tgz",
            "version": "file:.nix-providers/scope-host-2.0.0.tgz"
          },
          "host-plugin": {
            "specifier": "^1",
            "version": "1.0.0(linked@file:.nix-providers/linked-1.0.0.tgz)"
          },
          "linked": {
            "specifier": "file:.nix-providers/linked-1.0.0.tgz",
            "version": "file:.nix-providers/linked-1.0.0.tgz"
          }
        }
      }
    },
    "lockfileVersion": "9.0",
    "overrides": {
      "host-plugin>@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz",
      "linked": "file:.nix-providers/linked-1.0.0.tgz"
    },
    "packages": {
      "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz": {
        "resolution": {"tarball": "file:.nix-providers/scope-host-2.0.0.tgz"}
      },
      "host-plugin@1.0.0": {
        "peerDependencies": {"linked": "^1.0.0"},
        "resolution": {"integrity": "sha512-host-plugin-1.0.0"}
      },
      "linked@file:.nix-providers/linked-1.0.0.tgz": {
        "resolution": {"tarball": "file:.nix-providers/linked-1.0.0.tgz"}
      }
    },
    "snapshots": {
      "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz": {},
      "host-plugin@1.0.0(linked@file:.nix-providers/linked-1.0.0.tgz)": {
        "dependencies": {
          "@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz",
          "linked": "file:.nix-providers/linked-1.0.0.tgz"
        }
      },
      "linked@file:.nix-providers/linked-1.0.0.tgz": {}
    }
  },
  "manifests": {
    "package.json": {
      "devDependencies": {
        "@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz",
        "host-plugin": "^1",
        "linked": "^1.0.0"
      },
      "peerDependencies": {"@scope/host": "^1"}
    }
  },
  "workspace": {
    "overrides": {
      "host-plugin>@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz",
      "linked": "file:.nix-providers/linked-1.0.0.tgz"
    },
    "packages": ["."]
  }
}
JSON

# pnpm resolves a `file:` specifier from the directory of the manifest that
# declares it, so a workspace member's dependency on its peer points at the
# tarball through a path from the member's directory.
project '{
  "package.json": {"name": "workspace"},
  "packages/app/package.json": {
    "devDependencies": {"@scope/host": "^1", "uses-host": "^1"},
    "peerDependencies": {"@scope/host": "^1"}
  }
}' 'packages:
  - "packages/*"'
update
expect <<'JSON'
{
  "hashed": true,
  "links": {"scope-host-2.0.0.tgz": "host-tarball/package.tgz"},
  "lockfile": {
    "importers": {
      ".": {},
      "packages/app": {
        "devDependencies": {
          "@scope/host": {
            "specifier": "file:../../.nix-providers/scope-host-2.0.0.tgz",
            "version": "file:.nix-providers/scope-host-2.0.0.tgz"
          },
          "uses-host": {"specifier": "^1", "version": "1.0.0"}
        }
      }
    },
    "lockfileVersion": "9.0",
    "overrides": {
      "uses-host>@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz"
    },
    "packages": {
      "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz": {
        "resolution": {"tarball": "file:.nix-providers/scope-host-2.0.0.tgz"}
      },
      "uses-host@1.0.0": {"resolution": {"integrity": "sha512-uses-host-1.0.0"}}
    },
    "snapshots": {
      "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz": {},
      "uses-host@1.0.0": {
        "dependencies": {
          "@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz"
        }
      }
    }
  },
  "manifests": {
    "package.json": {"name": "workspace"},
    "packages/app/package.json": {
      "devDependencies": {
        "@scope/host": "file:../../.nix-providers/scope-host-2.0.0.tgz",
        "uses-host": "^1"
      },
      "peerDependencies": {"@scope/host": "^1"}
    }
  },
  "workspace": {
    "overrides": {
      "uses-host>@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz"
    },
    "packages": ["packages/*"]
  }
}
JSON

# pnpm-workspace.yaml lists the members. A negated pattern excludes a member,
# and `*` matches only one directory level.
project '{
  "package.json": {"name": "workspace"},
  "packages/app/package.json": {"dependencies": {"linked": "^0"}},
  "packages/app/fixture/package.json": {"dependencies": {"@dotfiles/private": "^0.1.0"}},
  "packages/tool/package.json": {"devDependencies": {"renamed": "npm:@scope/host"}},
  "packages/ignored/package.json": {"dependencies": {"@dotfiles/private": "^0.1.0"}}
}' 'packages:
  - "packages/*"
  - "!packages/ignored"'
update
expect <<'JSON'
{
  "hashed": true,
  "links": {
    "linked-1.0.0.tgz": "linked-tarball/package.tgz",
    "scope-host-2.0.0.tgz": "host-tarball/package.tgz"
  },
  "lockfile": {
    "importers": {
      ".": {},
      "packages/app": {
        "dependencies": {
          "linked": {
            "specifier": "file:../../.nix-providers/linked-1.0.0.tgz",
            "version": "file:.nix-providers/linked-1.0.0.tgz"
          }
        }
      },
      "packages/tool": {
        "devDependencies": {
          "renamed": {
            "specifier": "file:../../.nix-providers/scope-host-2.0.0.tgz",
            "version": "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz"
          }
        }
      }
    },
    "lockfileVersion": "9.0",
    "overrides": {
      "@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz",
      "linked": "file:.nix-providers/linked-1.0.0.tgz",
      "renamed": "file:.nix-providers/scope-host-2.0.0.tgz"
    },
    "packages": {
      "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz": {
        "resolution": {"tarball": "file:.nix-providers/scope-host-2.0.0.tgz"}
      },
      "linked@file:.nix-providers/linked-1.0.0.tgz": {
        "resolution": {"tarball": "file:.nix-providers/linked-1.0.0.tgz"}
      }
    },
    "snapshots": {
      "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz": {},
      "linked@file:.nix-providers/linked-1.0.0.tgz": {}
    }
  },
  "manifests": {
    "package.json": {"name": "workspace"},
    "packages/app/fixture/package.json": {
      "dependencies": {"@dotfiles/private": "^0.1.0"}
    },
    "packages/app/package.json": {"dependencies": {"linked": "^1.0.0"}},
    "packages/ignored/package.json": {
      "dependencies": {"@dotfiles/private": "^0.1.0"}
    },
    "packages/tool/package.json": {
      "devDependencies": {"renamed": "npm:@scope/host@^2.0.0"}
    }
  },
  "workspace": {
    "overrides": {
      "@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz",
      "linked": "file:.nix-providers/linked-1.0.0.tgz",
      "renamed": "file:.nix-providers/scope-host-2.0.0.tgz"
    },
    "packages": ["packages/*", "!packages/ignored"]
  }
}
JSON

# The repository's formatter writes double quotes, and a second update changes
# nothing.
project '{"package.json": {"devDependencies": {"@scope/host": "^2.0.0", "linked": "^1.0.0"}}}' "$workspace"
update
expect <<'JSON'
{
  "hashed": true,
  "links": {
    "linked-1.0.0.tgz": "linked-tarball/package.tgz",
    "scope-host-2.0.0.tgz": "host-tarball/package.tgz"
  },
  "lockfile": {
    "importers": {
      ".": {
        "devDependencies": {
          "@scope/host": {
            "specifier": "file:.nix-providers/scope-host-2.0.0.tgz",
            "version": "file:.nix-providers/scope-host-2.0.0.tgz"
          },
          "linked": {
            "specifier": "file:.nix-providers/linked-1.0.0.tgz",
            "version": "file:.nix-providers/linked-1.0.0.tgz"
          }
        }
      }
    },
    "lockfileVersion": "9.0",
    "overrides": {
      "@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz",
      "linked": "file:.nix-providers/linked-1.0.0.tgz"
    },
    "packages": {
      "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz": {
        "resolution": {"tarball": "file:.nix-providers/scope-host-2.0.0.tgz"}
      },
      "linked@file:.nix-providers/linked-1.0.0.tgz": {
        "resolution": {"tarball": "file:.nix-providers/linked-1.0.0.tgz"}
      }
    },
    "snapshots": {
      "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz": {},
      "linked@file:.nix-providers/linked-1.0.0.tgz": {}
    }
  },
  "manifests": {
    "package.json": {
      "devDependencies": {"@scope/host": "^2.0.0", "linked": "^1.0.0"}
    }
  },
  "workspace": {
    "overrides": {
      "@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz",
      "linked": "file:.nix-providers/linked-1.0.0.tgz"
    },
    "packages": ["."]
  }
}
JSON
rm -rf "$root/first"
cp -R "$root/scenario" "$root/first"
update
diff -r -u "$root/first" "$root/scenario"
printf '%s\n' "$workspace" 'overrides:' '  "@scope/host": file:.nix-providers/scope-host-2.0.0.tgz' '  linked: file:.nix-providers/linked-1.0.0.tgz' | diff -u - "$root/scenario/pnpm-workspace.yaml"

# A normal relock, with or without `--refresh`, keeps the locked versions that
# still satisfy their ranges. Lockfile maintenance moves every dependency of
# the root and of the workspace members, direct and transitive, to the newest
# version in its range, and leaves the manifests' ranges as they were. The
# provider overrides, the scoped override for the project's peer and the other
# overrides remain as in a normal update.
for mode in default --refresh --maintain-lockfile; do
	arguments=()
	other=4.0.0
	leaf=1.0.0
	case "$mode" in
	default) ;;
	--refresh)
		arguments=(--refresh)
		;;
	--maintain-lockfile)
		arguments=(--maintain-lockfile)
		other=4.1.0
		leaf=1.1.0
		;;
	esac

	project '{
  "package.json": {
    "devDependencies": {"@scope/host": "^1", "linked": "^1", "other": "^4", "uses-host": "^1"},
    "peerDependencies": {"@scope/host": "^1"}
  },
  "packages/app/package.json": {"dependencies": {"leaf": "^1.0.0"}}
}' "$workspace"'
  - "packages/*"
overrides:
  other>dependency: "-"' "lockfileVersion: '9.0'
importers:
  .:
    devDependencies:
      other: {specifier: ^4, version: 4.0.0}
  packages/app:
    dependencies:
      leaf: {specifier: ^1.0.0, version: 1.0.0}
snapshots:
  other@4.0.0:
    dependencies:
      leaf: 1.0.0"
	update "${arguments[@]}"
	expect <<JSON
{
  "hashed": true,
  "links": {
    "linked-1.0.0.tgz": "linked-tarball/package.tgz",
    "scope-host-2.0.0.tgz": "host-tarball/package.tgz"
  },
  "lockfile": {
    "importers": {
      ".": {
        "devDependencies": {
          "@scope/host": {
            "specifier": "file:.nix-providers/scope-host-2.0.0.tgz",
            "version": "file:.nix-providers/scope-host-2.0.0.tgz"
          },
          "linked": {
            "specifier": "file:.nix-providers/linked-1.0.0.tgz",
            "version": "file:.nix-providers/linked-1.0.0.tgz"
          },
          "other": {"specifier": "^4", "version": "$other"},
          "uses-host": {"specifier": "^1", "version": "1.0.0"}
        }
      },
      "packages/app": {
        "dependencies": {"leaf": {"specifier": "^1.0.0", "version": "$leaf"}}
      }
    },
    "lockfileVersion": "9.0",
    "overrides": {
      "linked": "file:.nix-providers/linked-1.0.0.tgz",
      "other>dependency": "-",
      "uses-host>@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz"
    },
    "packages": {
      "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz": {
        "resolution": {"tarball": "file:.nix-providers/scope-host-2.0.0.tgz"}
      },
      "leaf@$leaf": {"resolution": {"integrity": "sha512-leaf-$leaf"}},
      "linked@file:.nix-providers/linked-1.0.0.tgz": {
        "resolution": {"tarball": "file:.nix-providers/linked-1.0.0.tgz"}
      },
      "other@$other": {"resolution": {"integrity": "sha512-other-$other"}},
      "uses-host@1.0.0": {"resolution": {"integrity": "sha512-uses-host-1.0.0"}}
    },
    "snapshots": {
      "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz": {},
      "leaf@$leaf": {},
      "linked@file:.nix-providers/linked-1.0.0.tgz": {},
      "other@$other": {"dependencies": {"leaf": "$leaf"}},
      "uses-host@1.0.0": {
        "dependencies": {
          "@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz"
        }
      }
    }
  },
  "manifests": {
    "package.json": {
      "devDependencies": {
        "@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz",
        "linked": "^1.0.0",
        "other": "^4",
        "uses-host": "^1"
      },
      "peerDependencies": {"@scope/host": "^1"}
    },
    "packages/app/package.json": {"dependencies": {"leaf": "^1.0.0"}}
  },
  "workspace": {
    "overrides": {
      "linked": "file:.nix-providers/linked-1.0.0.tgz",
      "other>dependency": "-",
      "uses-host>@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz"
    },
    "packages": [".", "packages/*"]
  }
}
JSON
done

# A chain of local packages, each found only after the previous relock, stops
# the update after 10 rounds.
project '{"package.json": {"dependencies": {"chain-start": "^1"}}}' "$workspace"
if update 2>"$root/unstable.log"; then
	echo 'A relock that keeps finding local packages must stop the update.' >&2
	exit 1
fi
printf '%s\n' 'Relocking still added local npm packages after 10 rounds.' | diff -u - "$root/unstable.log"

# A local package installs @scope/tui 1.1.0, and the project's range resolves
# another version. The direct dependency moves to the exact version, so pnpm
# installs one copy, with one set of module state. The guard covers the
# workspace members too.
#
# Prints a lockfile in which the given importer locks @scope/tui 1.0.0.
tui_lock() {
	printf '%s\n' "lockfileVersion: '9.0'" 'importers:' "  $1:" "    $2:" "      '@scope/tui': {specifier: ^1.0.0, version: 1.0.0}"
}
host_tui="$(jq '.host.dependencies = {"@scope/tui": "1.1.0"}' <<<"$default_packages")"
project '{"package.json": {"devDependencies": {"@scope/host": "^2.0.0", "@scope/tui": "^1.0.0"}}}' "$workspace" "$(tui_lock . devDependencies)"
local_packages "$host_tui"
update
expect <<'JSON'
{
  "hashed": true,
  "links": {"scope-host-2.0.0.tgz": "host-tarball/package.tgz"},
  "lockfile": {
    "importers": {
      ".": {
        "devDependencies": {
          "@scope/host": {
            "specifier": "file:.nix-providers/scope-host-2.0.0.tgz",
            "version": "file:.nix-providers/scope-host-2.0.0.tgz"
          },
          "@scope/tui": {"specifier": "1.1.0", "version": "1.1.0"}
        }
      }
    },
    "lockfileVersion": "9.0",
    "overrides": {"@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz"},
    "packages": {
      "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz": {
        "resolution": {"tarball": "file:.nix-providers/scope-host-2.0.0.tgz"}
      },
      "@scope/tui@1.1.0": {
        "resolution": {"integrity": "sha512-@scope/tui-1.1.0"}
      }
    },
    "snapshots": {
      "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz": {
        "dependencies": {"@scope/tui": "1.1.0"}
      },
      "@scope/tui@1.1.0": {}
    }
  },
  "manifests": {
    "package.json": {
      "devDependencies": {"@scope/host": "^2.0.0", "@scope/tui": "1.1.0"}
    }
  },
  "workspace": {
    "overrides": {"@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz"},
    "packages": ["."]
  }
}
JSON

project '{
  "package.json": {"devDependencies": {"@scope/host": "^2.0.0"}},
  "packages/app/package.json": {"dependencies": {"@scope/tui": "^1.0.0"}}
}' 'packages:
  - "packages/*"' "$(tui_lock packages/app dependencies)"
local_packages "$host_tui"
update
expect <<'JSON'
{
  "hashed": true,
  "links": {"scope-host-2.0.0.tgz": "host-tarball/package.tgz"},
  "lockfile": {
    "importers": {
      ".": {
        "devDependencies": {
          "@scope/host": {
            "specifier": "file:.nix-providers/scope-host-2.0.0.tgz",
            "version": "file:.nix-providers/scope-host-2.0.0.tgz"
          }
        }
      },
      "packages/app": {
        "dependencies": {
          "@scope/tui": {"specifier": "1.1.0", "version": "1.1.0"}
        }
      }
    },
    "lockfileVersion": "9.0",
    "overrides": {"@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz"},
    "packages": {
      "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz": {
        "resolution": {"tarball": "file:.nix-providers/scope-host-2.0.0.tgz"}
      },
      "@scope/tui@1.1.0": {
        "resolution": {"integrity": "sha512-@scope/tui-1.1.0"}
      }
    },
    "snapshots": {
      "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz": {
        "dependencies": {"@scope/tui": "1.1.0"}
      },
      "@scope/tui@1.1.0": {}
    }
  },
  "manifests": {
    "package.json": {"devDependencies": {"@scope/host": "^2.0.0"}},
    "packages/app/package.json": {"dependencies": {"@scope/tui": "1.1.0"}}
  },
  "workspace": {
    "overrides": {"@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz"},
    "packages": ["packages/*"]
  }
}
JSON

# A direct dependency with a `catalog:` specifier keeps that specifier, and its
# entry under `catalog` or `catalogs` in pnpm-workspace.yaml moves to the exact
# version.
for catalog in default tools; do
	specifier="catalog:$catalog"
	entries="catalogs:
  $catalog:"
	pinned="\"catalogs\": {\"$catalog\": {\"@scope/tui\": \"1.1.0\"}}"
	if [[ "$catalog" == default ]]; then
		specifier='catalog:'
		entries='catalog:'
		pinned='"catalog": {"@scope/tui": "1.1.0"}'
	fi

	project "{\"package.json\": {\"devDependencies\": {\"@scope/host\": \"^2.0.0\", \"@scope/tui\": \"$specifier\"}}}" "$workspace
$entries
    \"@scope/tui\": ^1.0.0" "$(tui_lock . devDependencies)"
	local_packages "$host_tui"
	update
	expect <<JSON
{
  "hashed": true,
  "links": {"scope-host-2.0.0.tgz": "host-tarball/package.tgz"},
  "lockfile": {
    "catalogs": {
      "$catalog": {"@scope/tui": {"specifier": "1.1.0", "version": "1.1.0"}}
    },
    "importers": {
      ".": {
        "devDependencies": {
          "@scope/host": {
            "specifier": "file:.nix-providers/scope-host-2.0.0.tgz",
            "version": "file:.nix-providers/scope-host-2.0.0.tgz"
          },
          "@scope/tui": {"specifier": "$specifier", "version": "1.1.0"}
        }
      }
    },
    "lockfileVersion": "9.0",
    "overrides": {"@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz"},
    "packages": {
      "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz": {
        "resolution": {"tarball": "file:.nix-providers/scope-host-2.0.0.tgz"}
      },
      "@scope/tui@1.1.0": {
        "resolution": {"integrity": "sha512-@scope/tui-1.1.0"}
      }
    },
    "snapshots": {
      "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz": {
        "dependencies": {"@scope/tui": "1.1.0"}
      },
      "@scope/tui@1.1.0": {}
    }
  },
  "manifests": {
    "package.json": {
      "devDependencies": {"@scope/host": "^2.0.0", "@scope/tui": "$specifier"}
    }
  },
  "workspace": {
    $pinned,
    "overrides": {"@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz"},
    "packages": ["."]
  }
}
JSON
done

# A relock keeps the version that the lockfile's `catalogs` section records for
# an entry while the entry's range is unchanged, including for a workspace
# member that the lockfile does not list yet.
project '{
  "package.json": {"devDependencies": {"other": "catalog:"}},
  "packages/app/package.json": {"dependencies": {"other": "catalog:"}}
}' 'packages:
  - "."
  - "packages/*"
catalog:
  other: ^4' "lockfileVersion: '9.0'
catalogs:
  default:
    other: {specifier: ^4, version: 4.0.0}
importers:
  .:
    devDependencies:
      other: {specifier: 'catalog:', version: 4.0.0}
snapshots:
  other@4.0.0:
    dependencies:
      leaf: 1.0.0"
update
expect <<'JSON'
{
  "hashed": true,
  "links": {},
  "lockfile": {
    "catalogs": {"default": {"other": {"specifier": "^4", "version": "4.0.0"}}},
    "importers": {
      ".": {
        "devDependencies": {"other": {"specifier": "catalog:", "version": "4.0.0"}}
      },
      "packages/app": {
        "dependencies": {"other": {"specifier": "catalog:", "version": "4.0.0"}}
      }
    },
    "lockfileVersion": "9.0",
    "packages": {
      "leaf@1.0.0": {"resolution": {"integrity": "sha512-leaf-1.0.0"}},
      "other@4.0.0": {"resolution": {"integrity": "sha512-other-4.0.0"}}
    },
    "snapshots": {
      "leaf@1.0.0": {},
      "other@4.0.0": {"dependencies": {"leaf": "1.0.0"}}
    }
  },
  "manifests": {
    "package.json": {"devDependencies": {"other": "catalog:"}},
    "packages/app/package.json": {"dependencies": {"other": "catalog:"}}
  },
  "workspace": {"catalog": {"other": "^4"}, "packages": [".", "packages/*"]}
}
JSON

# A local package and a workspace member install the same version of
# @scope/widgets with different peers, so the lockfile's references to it end
# in different suffixes. The versions match, and the guard leaves the member's
# range as it is.
project '{
  "package.json": {"devDependencies": {"@scope/host": "^2.0.0"}},
  "packages/app/package.json": {"dependencies": {"@scope/widgets": "^1.0.0", "keymap": "^1.0.0"}}
}' 'packages:
  - "packages/*"'
local_packages "$(jq '.host.dependencies = {"@scope/widgets": "1.0.0", "theme": "1.0.0"}' <<<"$default_packages")"
update
expect <<'JSON'
{
  "hashed": true,
  "links": {"scope-host-2.0.0.tgz": "host-tarball/package.tgz"},
  "lockfile": {
    "importers": {
      ".": {
        "devDependencies": {
          "@scope/host": {
            "specifier": "file:.nix-providers/scope-host-2.0.0.tgz",
            "version": "file:.nix-providers/scope-host-2.0.0.tgz"
          }
        }
      },
      "packages/app": {
        "dependencies": {
          "@scope/widgets": {
            "specifier": "^1.0.0",
            "version": "1.0.0(keymap@1.0.0)"
          },
          "keymap": {"specifier": "^1.0.0", "version": "1.0.0"}
        }
      }
    },
    "lockfileVersion": "9.0",
    "overrides": {"@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz"},
    "packages": {
      "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz": {
        "resolution": {"tarball": "file:.nix-providers/scope-host-2.0.0.tgz"}
      },
      "@scope/widgets@1.0.0": {
        "peerDependencies": {"keymap": "^1.0.0", "theme": "^1.0.0"},
        "resolution": {"integrity": "sha512-@scope/widgets-1.0.0"}
      },
      "keymap@1.0.0": {"resolution": {"integrity": "sha512-keymap-1.0.0"}},
      "theme@1.0.0": {"resolution": {"integrity": "sha512-theme-1.0.0"}}
    },
    "snapshots": {
      "@scope/host@file:.nix-providers/scope-host-2.0.0.tgz": {
        "dependencies": {
          "@scope/widgets": "1.0.0(theme@1.0.0)",
          "theme": "1.0.0"
        }
      },
      "@scope/widgets@1.0.0(keymap@1.0.0)": {
        "dependencies": {"keymap": "1.0.0"}
      },
      "@scope/widgets@1.0.0(theme@1.0.0)": {
        "dependencies": {"theme": "1.0.0"}
      },
      "keymap@1.0.0": {},
      "theme@1.0.0": {}
    }
  },
  "manifests": {
    "package.json": {"devDependencies": {"@scope/host": "^2.0.0"}},
    "packages/app/package.json": {
      "dependencies": {"@scope/widgets": "^1.0.0", "keymap": "^1.0.0"}
    }
  },
  "workspace": {
    "overrides": {"@scope/host": "file:.nix-providers/scope-host-2.0.0.tgz"},
    "packages": ["packages/*"]
  }
}
JSON

# The guard stops the update when local packages need different versions, when
# syncpack would reject the exact version, and when pnpm still installs a second
# copy after the guard has run.
for case in conflict syncpack persistent; do
	manifest='{"devDependencies": {"@scope/host": "^2.0.0", "@scope/tui": "^1.0.0"}}'
	packages="$host_tui"
	case "$case" in
	conflict)
		manifest='{"devDependencies": {"@scope/host": "^2.0.0", "@scope/tui": "^1.0.0", "linked": "^1.0.0"}}'
		packages="$(jq '.linked.dependencies = {"@scope/tui": "1.2.0"}' <<<"$host_tui")"
		expected='Local packages need different versions of @scope/tui: 1.1.0 1.2.0'
		;;
	syncpack)
		packages="$(jq '.host.dependencies = {"leaf": "1.0.0"}' <<<"$default_packages")"
		manifest='{"devDependencies": {"@scope/host": "^2.0.0", "leaf": "^1.0.0"}}'
		expected='leaf needs the exact version 1.0.0, which a local package installs, but .syncpackrc.json allows exact versions only for the dependencies in its semver group with "range": "". Add leaf to that group.'
		;;
	persistent)
		manifest='{"devDependencies": {"@scope/host": "^2.0.0", "@scope/tui": "npm:@scope/tui@^1.0.0"}}'
		expected='pnpm still installs a second copy of @scope/tui beside a local package.'
		;;
	esac
	project "{\"package.json\": $manifest}" "$workspace" "$(tui_lock . devDependencies)"
	local_packages "$packages"
	if update 2>"$root/$case.log"; then
		printf 'The %s case must stop the update.\n' "$case" >&2
		exit 1
	fi
	printf '%s\n' "$expected" | diff -u - "$root/$case.log"
done

# Any other argument stops the updater before it changes anything.
project '{"package.json": {"devDependencies": {"linked": "^0"}}}' "$workspace"
cp -R "$root/scenario" "$root/before"
if update --unknown 2>"$root/usage.log"; then
	echo 'An unknown argument must stop the update.' >&2
	exit 1
fi
printf '%s\n' 'Usage: update-scenario [--refresh | --maintain-lockfile]' | diff -u - "$root/usage.log"
diff -r -u "$root/before" "$root/scenario"
