# Fetch a release asset from a private GitHub repository, given the release
# tag and the file name. The asset's API URL is resolved through the GitHub
# API at build time, so no asset ID has to be pinned in the configuration.
{
  lib,
  stdenvNoCC,
  curl,
  cacert,
  jq,
}: {
  repo,
  tag,
  filename,
  hash,
}:
stdenvNoCC.mkDerivation {
  name = filename;

  outputHash = hash;
  outputHashAlgo = null; # SRI
  outputHashMode = "flat";

  nativeBuildInputs = [curl cacert jq];

  impureEnvVars =
    lib.fetchers.proxyImpureEnvVars
    ++ ["GITHUB_TOKEN" "GH_TOKEN"];

  builder = builtins.toFile "fetch-github-release-asset.sh" ''
    source $stdenv/setup

    token="''${GITHUB_TOKEN:-}"
    if [ -z "$token" ]; then
      token="''${GH_TOKEN:-}"
    fi
    if [ -z "$token" ]; then
      echo "GITHUB_TOKEN or GH_TOKEN must be set." >&2
      exit 1
    fi

    # Each curl invocation reads this on stdin, so the token is never written
    # to a file in the build directory. curl drops an Authorization header set
    # this way when a redirect leads to another host, so the asset download
    # sends it to api.github.com only.
    curl_config="header = \"Authorization: Bearer $token\""

    curlVersion=$(curl -V | head -1 | cut -d' ' -f2)

    curl=(
      curl
      --config -
      --location
      --max-redirs 20
      --retry 3
      --retry-all-errors
      --continue-at -
      --disable-epsv
      --cookie-jar cookies
      --user-agent "curl/$curlVersion Nixpkgs/$nixpkgsVersion"
    )

    if ! [ -f "$SSL_CERT_FILE" ]; then
      curl+=(--insecure)
    fi

    # Find the asset's API URL from the release tag and the file name
    asset_url=$(
      "''${curl[@]}" -sf \
        "https://api.github.com/repos/$repo/releases/tags/$tag" \
        <<<"$curl_config" \
      | jq -r \
        --arg name "$filename" \
        '.assets[] | select(.name == $name) | .url'
    )

    if [ -z "$asset_url" ]; then
      echo "Asset '$filename' not found in release '$tag' of '$repo'" >&2
      exit 1
    fi

    "''${curl[@]}" --fail \
      -H "Accept: application/octet-stream" \
      "$asset_url" -o "$out" <<<"$curl_config"
  '';

  inherit repo tag filename;

  nixpkgsVersion = lib.trivial.release;
  SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
  preferLocalBuild = true;
}
