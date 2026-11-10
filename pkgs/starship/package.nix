{
  upstreamPackage,
  starshipSource,
  rustPlatform,
  tzdata,
}:
upstreamPackage.overrideAttrs (old: {
  src = starshipSource;
  cargoDeps = rustPlatform.importCargoLock {lockFile = "${starshipSource}/Cargo.lock";};
  env = (old.env or {}) // {TZDIR = "${tzdata}/share/zoneinfo";};
  passthru =
    (old.passthru or {})
    // {
      updateScript = null;
      tests = {};
      slowTests = (old.passthru.slowTests or {}) // (old.passthru.tests or {});
      maintenance = {
        source = "input";
        inputs = ["starship-custom"];
        temporary = true;
        retirement = "Return to the packaged source after Starship PR #6834 is released.";
      };
    };
})
