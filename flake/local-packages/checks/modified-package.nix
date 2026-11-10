{upstreamPackage}:
upstreamPackage.overrideAttrs (old: {
  passthru = (old.passthru or {}) // {modified = true;};
})
