# Podman runs each container health check from a transient systemd unit, and
# `podman healthcheck run` exits 1 whenever the container is not healthy,
# including while it is still inside its start period. The unit then shows as
# failed until the next check passes, so every container whose check needs
# time to pass leaves a failed unit behind after each start.
#
# Upstream fixed this in podman 6 by adding `--ignore-result` to
# `podman healthcheck run` and using it from the timer. These are those two
# commits, rewritten for the 5.8 sources and without their test changes.
# Drop them once nixpkgs ships podman 6.
_: _: prev: {
  podman = prev.podman.overrideAttrs (old: {
    patches =
      (old.patches or [])
      ++ [
        ./podman/0001-podman-healthcheck-run-add-ignore-result-flag.patch
        ./podman/0002-healthcheck_linux-avoid-failing-transient-units.patch
      ];
  });
}
