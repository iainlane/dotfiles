{lib}: {
  package,
  packageLock,
}: let
  hostPackages = [
    "@earendil-works/pi-agent-core"
    "@earendil-works/pi-ai"
    "@earendil-works/pi-coding-agent"
    "@earendil-works/pi-tui"
    "@mariozechner/pi-agent-core"
    "@mariozechner/pi-ai"
    "@mariozechner/pi-coding-agent"
    "@mariozechner/pi-tui"
    "@sinclair/typebox"
    "typebox"
  ];
  hostPeers = lib.filterAttrs (name: _: builtins.elem name hostPackages) (package.peerDependencies or {});
  hostPeerMeta = lib.mapAttrs (_: _: {optional = true;}) hostPeers;
  incomplete = _: record:
    lib.isString (record.resolved or null)
    && lib.any (scheme: lib.hasPrefix scheme record.resolved) ["https://" "http://"]
    && (!(record ? integrity) || record.integrity == null || record.integrity == "");
  omittedHostRecord = path: record:
    ((record.dev or false) || (record.peer or false))
    && lib.any (name: path == "node_modules/${name}" || lib.hasPrefix "node_modules/${name}/node_modules/" path) hostPackages;
  invalid = lib.filterAttrs (path: record: incomplete path record && !(omittedHostRecord path record)) packageLock.packages;
  keep = path: record: !(incomplete path record);
  droppedNames = map (lib.removePrefix "node_modules/") (lib.filter (path: path != "" && !(lib.hasInfix "/node_modules/" path)) (lib.attrNames (lib.filterAttrs (path: record: !(keep path record)) packageLock.packages)));
  withoutDropped = root: field:
    lib.optionalAttrs (root ? ${field}) {
      ${field} = removeAttrs root.${field} droppedNames;
    };
  project = root:
    root
    // withoutDropped root "dependencies"
    // withoutDropped root "devDependencies"
    // {
      peerDependenciesMeta = (root.peerDependenciesMeta or {}) // hostPeerMeta;
    };
in
  assert lib.assertMsg (invalid == {}) "Pi extension lockfile has dependencies without integrity metadata: ${lib.concatStringsSep ", " (lib.attrNames invalid)}"; {
    package = project package;
    packageLock =
      packageLock
      // {
        packages = lib.filterAttrs keep packageLock.packages // {"" = project packageLock.packages."";};
      };
  }
