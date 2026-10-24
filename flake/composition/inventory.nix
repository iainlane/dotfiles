{
  lib,
  featureResolver,
}: {
  hosts,
  schema,
}:
lib.mapAttrs (_: hostConfig:
    (lib.evalModules {
      class = "inventory";
      specialArgs = {inherit hostConfig;};
      modules =
        [schema hostConfig.inventoryModule]
        ++ featureResolver.resolveFeatures {
          class = "inventory";
          inherit hostConfig;
        };
    }).config)
hosts
