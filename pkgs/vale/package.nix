# Take Vale 3.24.0 with a local fix on older nixpkgs channels. prose-lint
# relies on fixes from 3.18.0 to 3.22.0 that place alerts correctly:
#
# - an alert in a paragraph whose text overlaps a `TokenIgnores` match, which
#   earlier releases could also report at the ignored token;
# - a word before a code span (vale-cli/vale#1147). Comments read as Markdown
#   are full of code spans.
#
# 3.18.0 also stopped linting comments in a file that `[formats]` maps onto
# Perl, which prose-lint does for Nix, shell and INI files. The patch restores
# that. Vale 3.25.1 includes the fix.
{
  upstreamPackage,
  fetchFromGitHub,
  lib,
}: let
  version = "3.24.0";
in
  (
    if lib.versionAtLeast upstreamPackage.version "3.25.1"
    then upstreamPackage
    else
      assert lib.assertMsg (lib.versionOlder upstreamPackage.version version) ''
        nixpkgs now provides vale ${upstreamPackage.version}. Check whether it includes
        pkgs/vale/0001-read-a-mapped-code-format-with-its-grammar.patch, then
        remove the compatibility package or move it to that release.
      '';
        upstreamPackage.overrideAttrs (finalAttrs: old: {
          inherit version;

          src = fetchFromGitHub {
            owner = "vale-cli";
            repo = "vale";
            tag = "v${finalAttrs.version}";
            hash = "sha256-s3KEAUjZHApRG2+qxOJAzyXMP3FJNnJXzu2nv4oHwe8=";
          };

          patches =
            (old.patches or [])
            ++ [
              ./0001-read-a-mapped-code-format-with-its-grammar.patch
            ];

          # By default buildGoModule builds from a `vendor` directory that
          # `go mod vendor` makes, and `go mod vendor` copies only the directories
          # of imported Go packages. The tree-sitter grammars compile C sources
          # that include headers from directories with no Go files: go-tree-sitter's
          # `php/parser.c` includes `tree_sitter/parser.h`, for example. Those
          # headers are missing from `vendor`, and the C compiler fails.
          #
          # With proxyVendor, the fixed-output derivation runs `go mod download`
          # and keeps Go's download cache. The build reads modules from that cache
          # through a `file://` GOPROXY, and Go extracts each module from its
          # archive in full, headers included.
          proxyVendor = true;
          vendorHash = "sha256-cuSjULIbb7JtP0CkX4eFm9RChi3nQW46k5Ik9DyGYKk=";

          ldflags = [
            "-s"
            "-X main.version=${finalAttrs.version}"
          ];
        })
  ) .overrideAttrs (old: {
    passthru =
      (old.passthru or {})
      // {
        updateScript = null;
        maintenance = {
          source = "input";
          inputs = ["nixpkgs" "nixpkgs-stable"];
          temporary = true;
          retirement = "Remove compatibility packaging when every channel provides Vale 3.25.1 or newer.";
        };
      };
  })
