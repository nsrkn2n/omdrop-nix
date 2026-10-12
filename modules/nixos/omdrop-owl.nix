{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
# System-side wiring for omdrop-owl: the AWDL radio backend.
#
# What it installs, and why each part is here:
#   * the package itself -- it carries the polkit action, which polkitd reads
#     out of the system package set;
#   * a tmpfiles symlink /usr/lib/omdrop -> <store>/lib/omdrop, which is the
#     path omdrop-plugin looks in for omdrop-discoverable and send-to-peer.
#     A symlink rather than environment.systemPackages' own linking so that an
#     upgrade swaps all eleven files at once instead of leaving a mix;
#   * the AWDL interfaces marked unmanaged, so NetworkManager leaves awdl0
#     alone while a transfer is in flight.
#
# A switch does not apply tmpfiles rules (only a boot does), so after the
# first switch run:  sudo systemctl restart systemd-tmpfiles-setup.service
  let
    cfg = config.programs.omdrop-owl;
  in {
    options.programs.omdrop-owl = {
      enable = mkEnableOption "omdrop-owl, the AirDrop radio backend for omdrop";

      package = mkOption {
        type = types.package;
        default = pkgs.callPackage ../../pkgs/omdrop-owl.nix {};
        defaultText = literalExpression "pkgs.callPackage ../../pkgs/omdrop-owl.nix {}";
        description = ''
          omdrop-owl package to use. The default is built from this flake, but
          any package that installs omdrop-discoverable under lib/omdrop with a
          polkit action that names it can be substituted.
        '';
      };

      unmanagedInterfaces = mkOption {
        type = types.listOf types.str;
        default = [
          "interface-name:awdl0"
          "interface-name:mon0"
          "interface-name:awdlibss0"
        ];
        example = ["interface-name:awdl0"];
        description = ''
          NetworkManager device specs to hand off to omdrop-owl while
          discoverability is on. The defaults are the three interfaces the
          helper creates: the AWDL netdev, its monitoring interface, and the
          IBSS cell used on exclusive-mode (Intel) cards.
        '';
      };

      allowUntested = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Write /etc/omdrop/allow-untested, which lets omdrop-discoverable use a
          profile whose driver is marked untested. Machines with a tested
          profile -- Intel AX210 (iwlwifi) and MediaTek mt7925e (mt7925e) --
          do not need this; it is for other hardware, where the helper will
          otherwise refuse rather than guess.
        '';
      };
    };

    config = mkIf cfg.enable {
      environment.systemPackages = [cfg.package];

      # Declared whether or not NetworkManager is the configured backend; the
      # NetworkManager module only reads it when networking.networkmanager
      # is enabled.
      networking.networkmanager.unmanaged = cfg.unmanagedInterfaces;

      systemd.tmpfiles.rules = [
        "L+ /usr/lib/omdrop - - - - ${cfg.package}/lib/omdrop"
        "d /etc/omdrop 0755 root root -"
      ];

      # Drop-in configuration read by omdrop-discoverable ahead of the profiles
      # the package ships.
      environment.etc."omdrop/allow-untested" = mkIf cfg.allowUntested {
        text = "1\n";
      };
    };
  }
