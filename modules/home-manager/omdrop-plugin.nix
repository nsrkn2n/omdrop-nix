{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
# User-side wiring for omdrop: the `omdrop` command and the receiver that
# serves AirDrop uploads on port 8771.
#
# The receiver is a *user* service and is deliberately not enabled: `omdrop on`
# starts it for the length of a receive window, so "visible to everyone" stays
# a bounded state instead of a machine that receives forever.
#
# Upstream's `omdrop setup` does this install by hand (copies the unit into
# ~/.config/systemd/user, symlinks the binary into ~/.local/bin). Doing it
# declaratively means the unit always matches the installed package version.
  let
    cfg = config.programs.omdrop-plugin;

    # The unit the package generated, with its @PLUGIN_DIR@ already substituted
    # for the store path. The download directory is the one path the unit lets
    # the receiver write to, so a custom one has to be patched in here.
    unitText = let
      raw = builtins.readFile "${cfg.package}/lib/systemd/user/airdrop-receiver.service";
    in
      if cfg.downloadDir == null || baseNameOf cfg.downloadDir == "Downloads"
      then raw
      else replaceStrings ["%h/Downloads"] [cfg.downloadDir] raw;

    # The plugin's own receiver unit, with the store path already in place.
    # Nothing enables it here: `omdrop on` is what starts it, for a window.
    receiverUnit = pkgs.writeTextFile {
      name = "airdrop-receiver.service";
      text = unitText;
    };

    # Only the keys actually set are written: a receiver given an empty download
    # dir or a blank name refuses to start, and an absent key is a default.
    settings = filterAttrs (_: v: v != null) {
      name = cfg.name;
      model = cfg.model;
      download_dir = cfg.downloadDir;
      max_receive_percent = cfg.maxReceivePercent;
    };

    configText = concatStringsSep "\n" (mapAttrsToList (k: v: "${k} = ${generators.toPretty {} v}") settings);
  in {
    options.programs.omdrop-plugin = {
      enable = mkEnableOption "omdrop, the AirDrop CLI and receiver";

      package = mkOption {
        type = types.package;
        default = pkgs.callPackage ../../pkgs/omdrop-plugin.nix {};
        defaultText = literalExpression "pkgs.callPackage ../../pkgs/omdrop-plugin.nix {}";
        description = "omdrop-plugin package to use.";
      };

      installCommand = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Symlink ${"~"}/.local/bin/omdrop at the package, the way upstream's
          `omdrop setup` does. The command is already on PATH through
          home.packages; this is for the muscle memory of typing `omdrop` and
          for anyone whose PATH prefers ~/.local/bin.
        '';
      };

      installReceiverUnit = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Install airdrop-receiver.service as a user unit. It is never enabled
          by itself: `omdrop on` starts it for a bounded window.
        '';
      };

      name = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "thonkpad";
        description = ''
          What nearby Apple devices see this computer as. Leave unset and the
          receiver derives a default, or run `omdrop name` at any time -- the
          two write the same ~/.config/airdrop/config.toml.
        '';
      };

      model = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "Linux";
        description = "The model string shown next to the name in the AirDrop sheet.";
      };

      downloadDir = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/home/youn/Downloads";
        description = ''
          Where received files land. The directory must exist and be owned by
          the user; the receiver refuses to start otherwise. Unset means
          ~/Downloads, which the receiver falls back to on its own.
        '';
      };

      maxReceivePercent = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Refuse an upload once free disk space drops below this percentage.";
      };
    };

    config = mkIf cfg.enable {
      home.packages = [cfg.package];

      home.file.".local/bin/omdrop" = mkIf cfg.installCommand {
        source = "${cfg.package}/bin/omdrop";
      };

      # Installed to ~/.config/systemd/user, where `systemctl --user` (and the
      # plugin's own `omdrop on`) look for it. writable so `omdrop dir` can drop
      # its ReadWritePaths override next to it.
      home.file.".config/systemd/user/airdrop-receiver.service" = mkIf cfg.installReceiverUnit {
        source = receiverUnit;
      };

      # The identity (~/.omdrop/keys) is created on first use by `omdrop setup`,
      # which is also what migrates an existing opendrop one.
      xdg.configFile."airdrop/config.toml" = mkIf (settings != {}) {
        text = configText + "\n";
      };
    };
  }
