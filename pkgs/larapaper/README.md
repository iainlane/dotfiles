# LaraPaper

`larapaper` packages the application and its Composer dependencies. Its frontend
build uses the npm lockfile, including Inter from Fontsource. `larapaper-image`
adds PHP 8.4 with Imagick, nginx, Chromium, Node.js and the Ruby Liquid
renderer. Supervisor runs PHP-FPM, nginx, the queue worker and the scheduler.
Nix packages provide Noto, CJK, emoji and Open Sans fallback fonts for Chromium.

The source starts from [LaraPaper 0.43.1] and applies the [asset configuration
PR] and [local fonts PR]. The Composer lockfile pins [trmnl-blade's asset
configuration PR]. `trmnl-framework` builds the released framework with the
patch from [framework PR 31]. Highcharts, Chartkick and MapLibre come from
hashed npm archives. Their versions follow the packaged renderer configuration.

[asset configuration PR]: https://github.com/usetrmnl/larapaper/pull/299
[LaraPaper 0.43.1]: https://github.com/usetrmnl/larapaper/releases/tag/0.43.1
[local fonts PR]: https://github.com/usetrmnl/larapaper/pull/298
[trmnl-blade's asset configuration PR]:
  https://github.com/bnussbau/trmnl-blade/pull/18
[framework PR 31]: https://github.com/usetrmnl/trmnl-framework/pull/31

HTML image rendering keeps the browser's file origin. The image permits
cross-origin requests for public font files, including requests from that file
origin. This avoids Chromium's local-network restriction on synthetic HTTP
origins when `APP_URL` uses a private address.

The image serves software assets from `APP_URL`. Older recipe versions retain
their published CSS; all screens use the rebuilt JavaScript from the packaged
framework version. Changes to the framework derivation rebuild the application
and image through Nix dependencies. Saved templates with literal CDN URLs still
need those URLs changed. Remote plugin data, map tiles and user-supplied images
remain runtime requests.

The Liquid wrapper source was recovered from the pinned upstream 0.2.0
container. [Its provenance record] includes the image, layer, executable and
source hashes. Only the trailing blank line differs from the recovered file. The
wrapper runs with Ruby 3.4 and the original locked gems, without Tebako.

[Its provenance record]: ../trmnl-liquid-cli/source.json

The image runs as UID/GID 82, matching the upstream Alpine image. The existing
database and generated-image volume names remain unchanged. Their mount points
are under `/var/lib/larapaper`; application files remain in the read-only Nix
store. Laravel generates caches at startup, after it receives `APP_KEY` through
the environment, then runs database migrations. The application key never enters
the build output.

Build the Ancaster image and run the VM check with:

```sh
nix build .#packages.aarch64-linux.larapaper-image
nix build .#checks.x86_64-linux.larapaper
```

The VM check runs on x86 Linux and starts the image with the deployment's
capability restrictions and a private IP for `APP_URL`. It checks HTTP assets,
multilingual font loading, production rendering, Chromium rendering, Imagick,
Liquid and persistent images after a restart.

Run `nix run .#update-larapaper` to update the release pin and both dependency
hashes. The package-update workflow discovers this updater automatically.
`nix run .#update-larapaper -- --force` refreshes the hashes for the current
release. Both commands preserve the pinned patches and restore the package file
if an update fails. `nix run .#update-trmnl-framework` updates the framework
release while retaining the PR patch and archiving the previous release's
published CSS, fonts and images.

Highcharts, Chartkick and MapLibre are separate packages:
`larapaper-highcharts`, `larapaper-chartkick` and `larapaper-maplibre-gl`. Each
package's updater, such as `nix run .#update-larapaper-highcharts`, reads that
library's version from the packaged `trmnl-blade` configuration and refreshes
its npm archive hash. Asset URLs use those versions.

`nix run .#update-trmnl-liquid-cli` selects the latest stable container tag,
verifies the manifest and layers, extracts the wrapper and original lockfile,
checks the embedded Liquid gem against RubyGems, and regenerates the gemset and
provenance record. Extraction uses a Linux Nix builder, including when the
updater runs on macOS.

The library updaters and the Liquid updater accept `--force` to refresh the
current pins, and all of them run in the package-update workflow.
