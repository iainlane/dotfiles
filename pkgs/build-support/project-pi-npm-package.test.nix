{lib}: let
  project = import ./project-pi-npm-package.nix {inherit lib;};
  host = "@earendil-works/pi-coding-agent";
  root = {
    name = "fixture";
    dependencies = {
      runtime = "1.0.0";
      ${host} = "*";
    };
    devDependencies = {
      development = "1.0.0";
      typebox = "*";
    };
    peerDependenciesMeta.other.optional = false;
    peerDependencies = {
      ${host} = "*";
      other = "*";
    };
  };
  runtime = {
    version = "1.0.0";
    resolved = "https://example.invalid/runtime.tgz";
    integrity = "sha512-fixture";
  };
  lock.packages = {
    "" = root;
    "node_modules/${host}" = {
      version = "1.0.0";
      resolved = "https://example.invalid/host.tgz";
      peer = true;
    };
    "node_modules/typebox" = {
      version = "1.0.0";
      resolved = "https://example.invalid/typebox.tgz";
      dev = true;
    };
    "node_modules/runtime" = runtime;
    "node_modules/git-runtime" = {
      resolved = "git+https://example.invalid/runtime.git#0123456789012345678901234567890123456789";
    };
    "node_modules/${host}/node_modules/@earendil-works/pi-ai" = {
      version = "1.0.0";
      resolved = "https://example.invalid/host.tgz";
      peer = true;
    };
  };
  projected = project {
    package = root;
    packageLock = lock;
  };
  expectedRoot = {
    name = "fixture";
    dependencies.runtime = "1.0.0";
    devDependencies.development = "1.0.0";
    peerDependencies = {
      ${host} = "*";
      other = "*";
    };
    peerDependenciesMeta = {
      ${host}.optional = true;
      other.optional = false;
    };
  };
  rejects = path: record:
    !(builtins.tryEval (builtins.deepSeq (project {
        package = root;
        packageLock.packages = {
          "" = root;
          ${path} = record;
        };
      })
      true)).success;
in
  assert projected
  == {
    package = expectedRoot;
    packageLock.packages = {
      "" = expectedRoot;
      "node_modules/runtime" = runtime;
      "node_modules/git-runtime" = {
        resolved = "git+https://example.invalid/runtime.git#0123456789012345678901234567890123456789";
      };
    };
  };
  assert lib.all (integrity: rejects "node_modules/runtime" ((removeAttrs runtime ["integrity"]) // integrity)) [{} {integrity = null;} {integrity = "";}];
  assert rejects "node_modules/${host}" (removeAttrs runtime ["integrity"]);
  assert rejects "node_modules/other" ((removeAttrs runtime ["integrity"]) // {peer = true;}); true
