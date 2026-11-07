{
  buildGo127Module,
  fetchFromGitHub,
  lib,
  updaters,
  zsh,
}:
buildGo127Module (finalAttrs: {
  pname = "zsh-lint";
  version = "1.6.1";

  src = fetchFromGitHub {
    owner = "z-shell";
    repo = "zsh-lint";
    tag = "v${finalAttrs.version}";
    hash = "sha256-WhXIYExYo4SqPb3wlUG/AoM0FLA1RvuLomwbfAx1rcc=";
  };

  vendorHash = "sha256-2eDsb1xVMZpjocofTJeVHOHtmytRhQ7rK02OAvnq3MQ=";
  subPackages = ["cmd/zsh-lint"];
  ldflags = ["-s" "-w"];
  nativeCheckInputs = [zsh];

  passthru.updateScript = updaters.mkNixUpdateUpdater {attr = "zsh-lint";};

  meta = {
    description = "Static analyser for Zsh scripts";
    homepage = "https://github.com/z-shell/zsh-lint";
    license = lib.licenses.gpl3Only;
    mainProgram = "zsh-lint";
    platforms = lib.platforms.unix;
  };
})
