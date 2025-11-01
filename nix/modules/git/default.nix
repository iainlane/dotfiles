{
  pkgs,
  lib,
  ...
}: {
  programs.git = {
    enable = true;

    package = pkgs.gitFull;

    ignores = [
      # macOS metadata
      ".DS_Store"
      # Local Claude preferences that vary per machine.
      ".claude/settings.local.json"
      # Crush's working directory; it is recreated on demand.
      ".crush"

      # direnv
      ## state
      ".direnv"
      ## these are config but usually we don't want to commit them
      ".envrc"
      "flake.nix"
      "flake.lock"
    ];

    signing = {
      key = lib.mkDefault "E352D5C51C5041D4";
      signByDefault = true;
    };

    settings = {
      user = {
        name = lib.mkDefault "Iain Lane";
        email = lib.mkDefault "iain@orangesquash.org.uk";
      };

      alias = {
        # Fetch a GitLab merge request by ID.
        mr = "!sh -c 'git fetch $0 merge-requests/$1/head'";
        # Pull a branch named like the current branch from origin.
        pb = "!sh -c 'git fetch origin \"$0:$0\"'";
        # Show the diff against the upstream tracking branch.
        du = "diff '@{u}'";
      };
      color.ui = true;
      push.default = "current";

      diff.tool = "nvimdiff";
      difftool.prompt = false;

      merge = {
        tool = "diffview";
        "dpkg-mergechangelogs" = {
          name = "debian/changelog merge driver";
          driver = "dpkg-mergechangelogs -m %O %A %B %A";
        };
      };

      mergetool = {
        prompt = false;
        keepBackup = false;
        diffview.cmd = "nvim -c \"DiffviewOpen\" \"\${MERGE}\"";
      };

      rerere.enabled = true;
      rebase.autosquash = true;
      pull.ff = "only";
      init.defaultBranch = "main";

      pager = {
        diff = "delta";
        log = "delta";
        reflog = "delta";
        show = "delta";
      };

      delta = {
        navigate = true;

        catppuccin-latte = {
          light = true;
          syntax-theme = "Catppuccin Latte";
        };

        catppuccin-mocha = {
          dark = true;
          syntax-theme = "Catppuccin Mocha";
        };
      };

      interactive.diffFilter = "delta --color-only";
      credential.helper =
        if pkgs.stdenv.isDarwin
        then "osxkeychain"
        else "libsecret";

      sendemail = {
        smtpencryption = "tls";
        smtpserver = "mail.messagingengine.com";
        smtpuser = "laney@fastmail.fm";
        smtpserverport = 587;
        suppresscc = "self";
      };

      # Git URL shortcuts and authentication rewrites.

      # Allow gnome:<path> shorthand for SSH URLs; also rewrite git:// to SSH
      # for pushes.
      "url \"ssh://git.gnome.org/git/\"" = {
        insteadOf = "gnome:";
        pushInsteadOf = "git://git.gnome.org/git/";
      };

      # lp: shorthand for Launchpad Git URLs.
      "url \"git+ssh://laney@git.launchpad.net/\"".insteadOf = "lp:";

      # Rewrite SSH GitHub URLs to HTTPS for pushes.
      "url \"https://github.com/\"".insteadOf = [
        "git@github.com:"
        "ssh://git@github.com/"
      ];
    };
  };
}
