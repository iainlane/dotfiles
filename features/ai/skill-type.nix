# The type of a value in `dotfiles.ai.skills` and `dotfiles.claudeCode.skills`.
{lib}:
lib.types.attrTag {
  directory = lib.mkOption {
    type = lib.types.path;
    description = ''
      A skill directory that contains SKILL.md, or a directory of skill
      directories. For a directory of skills the key is ignored and each skill
      keeps its own directory name. The tree links the directory unchanged.
    '';
  };

  skill = lib.mkOption {
    type = lib.types.submodule {
      options = {
        frontmatter = lib.mkOption {
          type = lib.types.submodule {
            freeformType = with lib.types; attrsOf anything;

            options = {
              description = lib.mkOption {
                type = lib.types.str;
                description = "What the skill does and when to use it.";
              };

              disable-model-invocation = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = ''
                  Whether only the user can invoke the skill. The tree also
                  renders the equivalent Codex policy into
                  `agents/openai.yaml`.
                '';
              };

              user-invocable = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = ''
                  Whether the user can invoke the skill as a command. Claude
                  Code treats a missing field as true, but Crush treats it as
                  false, so every rendered skill contains the field.
                '';
              };
            };
          };
          description = ''
            The SKILL.md frontmatter, without `name`: the skill's key is its
            name.
          '';
        };

        body = lib.mkOption {
          type = lib.types.str;
          description = "The Markdown that follows the frontmatter.";
        };
      };
    };
    description = "A skill defined in Nix, which the tree renders into SKILL.md.";
  };
}
