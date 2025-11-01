{
  inputs,
  system,
  ...
}: {
  programs.opencode = {
    enable = true;
    package = inputs.nix-ai-tools.packages.${system}.opencode;
    enableMcpIntegration = true;
  };
}
