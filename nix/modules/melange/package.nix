{melange}:
melange.overrideAttrs (_finalAttrs: prevAttrs: {
  version = "0.45.4";
  src = prevAttrs.src.overrideAttrs {outputHash = "sha256-Nsp1oFpiuR4A210IeLY76bQb29bdBFPAuCNQbi8rGsI=";};
  vendorHash = "sha256-QY3B+xQgJG4iEGz6C41SObK4aagAyv2UKWhOjKhwr5g=";
})
