# Fetch a release asset from a private GitHub repo by tag + filename.
# Resolves the asset URL via the GitHub API at build time, so no
# asset IDs need to be pinned in configuration.
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

    cat > netrc <<EOF
    machine api.github.com
      login x-access-token
      password $token
    EOF

    curlVersion=$(curl -V | head -1 | cut -d' ' -f2)

    curl=(
      curl
      --location
      --max-redirs 20
      --retry 3
      --retry-all-errors
      --continue-at -
      --disable-epsv
      --cookie-jar cookies
      --user-agent "curl/$curlVersion Nixpkgs/$nixpkgsVersion"
      --netrc-file "$PWD/netrc"
    )

    if ! [ -f "$SSL_CERT_FILE" ]; then
      curl+=(--insecure)
    fi

    # Look up the asset ID by release tag + filename
    asset_url=$(
      "''${curl[@]}" -sf \
        "https://api.github.com/repos/$repo/releases/tags/$tag" \
      | jq -r \
        --arg name "$filename" \
        '.assets[] | select(.name == $name) | .url'
    )

    if [ -z "$asset_url" ]; then
      echo "Asset '$filename' not found in release '$tag' of '$repo'" >&2
      exit 1
    fi

    # Download the asset binary
    "''${curl[@]}" --fail \
      -H "Accept: application/octet-stream" \
      "$asset_url" -o "$out"
  '';

  inherit repo tag filename;

  nixpkgsVersion = lib.trivial.release;
  SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
  preferLocalBuild = true;
}
