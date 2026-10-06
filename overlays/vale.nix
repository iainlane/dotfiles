# Take Vale 3.24.0 with a local fix, in place of nixpkgs' 3.17.1. prose-lint
# relies on fixes from 3.18.0 to 3.22.0 that place alerts correctly:
#
# - an alert in a paragraph whose text overlaps a `TokenIgnores` match, which
#   earlier releases could also report at the ignored token;
# - a word before a code span (vale-cli/vale#1147). Comments read as Markdown
#   are full of code spans.
#
# 3.18.0 also stopped linting comments in a file that `[formats]` maps onto
# Perl, which prose-lint does for Nix, shell and INI files. The patch restores
# that. It is not yet in a Vale release; vale-cli/vale#1200 proposes it.
#
# Evaluating vale fails once nixpkgs has 3.24.0. At that point, check whether
# the nixpkgs release includes the patch, then remove the overlay or move it to
# that release.
_: _: prev: let
  inherit (prev) lib;

  version = "3.24.0";
in {
  vale = assert lib.assertMsg (lib.versionOlder prev.vale.version version) ''
    nixpkgs now provides vale ${prev.vale.version}. Check whether it includes
    overlays/vale/0001-read-a-mapped-code-format-with-its-grammar.patch, then
    remove overlays/vale.nix or move it to that release.
  '';
    prev.vale.overrideAttrs (finalAttrs: old: {
      inherit version;

      src = prev.fetchFromGitHub {
        owner = "vale-cli";
        repo = "vale";
        tag = "v${finalAttrs.version}";
        hash = "sha256-s3KEAUjZHApRG2+qxOJAzyXMP3FJNnJXzu2nv4oHwe8=";
      };

      patches =
        (old.patches or [])
        ++ [
          ./vale/0001-read-a-mapped-code-format-with-its-grammar.patch
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
    });
}
