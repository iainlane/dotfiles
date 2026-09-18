# Adapted from LilDojd/dendritic-slop's packages/project-pi-npm-package.nix.
{lib}: {
  package,
  packageLock,
}: let
  # Pi provides an extension's peers at runtime, so npm should not resolve them.
  hostPeerMeta = lib.mapAttrs (_: _: {optional = true;}) (package.peerDependencies or {});

  # npm can record nested Pi peers without integrity hashes. Nix's npm
  # fetchers reject those records, even though these optional dev peers
  # are not installed.
  isFetchable = _: record: !(record ? resolved && !(record ? integrity));

  dropped = lib.filterAttrs (path: record: !isFetchable path record) packageLock.packages;

  # importNpmLock requires a lockfile record for every manifest dependency.
  # Remove dropped top-level dependencies from the manifest too; nested
  # dependencies belong to other packages.
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
