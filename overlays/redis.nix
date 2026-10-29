_: _: prev: {
  redis =
    if !prev.stdenv.hostPlatform.isDarwin
    then prev.redis
    else
      assert prev.lib.assertMsg (
        prev.redis.version
        == "8.10.3"
        && prev.lib.hasInfix "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/lib" (prev.redis.postPatch or "")
      ) ''
        The Redis ${prev.redis.version} Darwin SDK patching has changed.
        Remove overlays/redis.nix once the upstream SDK fix is included.
      '';
        prev.redis.overrideAttrs {postPatch = "";};
}
