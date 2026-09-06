# Adapts a Pi extension's manifest and lockfile for the npm fetchers. Adapted
# from LilDojd/dendritic-slop's `packages/project-pi-npm-package.nix`.
{lib}: {
  package,
  packageLock,
}: let
  # Pi provides an extension's peers at runtime, so npm should not resolve them.
  hostPeerMeta = lib.mapAttrs (_: _: {optional = true;}) (package.peerDependencies or {});

  # npm records the peers nested under `@earendil-works/pi-coding-agent` with a
  # `resolved` URL and no `integrity`, which both `importNpmLock` and
  # `fetchNpmDeps` refuse. Dropping them changes nothing that is installed:
  # those peers are optional and the dev tree is omitted.
  isFetchable = _: record: !(record ? resolved && !(record ? integrity));

  dropped = lib.filterAttrs (path: record: !isFetchable path record) packageLock.packages;

  # `importNpmLock` resolves each name in the manifest's `dependencies` and
  # `devDependencies` against the lockfile's `packages` map, so dropping a
  # record means dropping its name from those lists too. Only top-level
  # records appear in them: a nested record is a dependency of another
  # package, not of the extension.
  droppedNames =
    map (lib.removePrefix "node_modules/")
    (lib.filter (path: !(lib.hasInfix "/node_modules/" path)) (lib.attrNames dropped));

  withoutDropped = attrs: name:
    lib.optionalAttrs (attrs ? ${name}) {
      ${name} = removeAttrs attrs.${name} droppedNames;
    };

  project = root:
    root
    // withoutDropped root "dependencies"
    // withoutDropped root "devDependencies"
    // {
      peerDependenciesMeta = (root.peerDependenciesMeta or {}) // hostPeerMeta;
    };
in {
  package = project package;

  packageLock =
    packageLock
    // {
      packages =
        lib.filterAttrs isFetchable packageLock.packages
        // {
          "" = project packageLock.packages."";
        };
    };
}
