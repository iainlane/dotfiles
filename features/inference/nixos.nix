{pkgs, ...}: {
  environment.systemPackages = with pkgs; [
    clinfo
    nvtopPackages.amd
    vulkan-tools
    amdgpu_top
  ];
}
