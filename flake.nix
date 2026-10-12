{
  description = "AirDrop for Linux: omdrop-owl (AWDL radio backend) and omdrop-plugin (CLI + receiver), packaged for Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Only used to check that the home-manager module evaluates. Consumers who
    # do not want it can drop it; nothing here depends on it at runtime.
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    home-manager,
    ...
  }: let
    inherit (nixpkgs) lib;

    forAllSystems = f: lib.genAttrs lib.systems.flakeExposed (system: f (nixpkgs.legacyPackages.${system}) system);
  in {
    packages = forAllSystems (
      pkgs: _system: {
        omdrop-owl = pkgs.callPackage ./pkgs/omdrop-owl.nix {};
        omdrop-plugin = pkgs.callPackage ./pkgs/omdrop-plugin.nix {};

        # The CLI is the entry point; pair it with the backend.
        default = pkgs.callPackage ./pkgs/omdrop-plugin.nix {};
      }
    );

    nixosModules = {
      omdrop-owl = ./modules/nixos/omdrop-owl.nix;
      default = self.nixosModules.omdrop-owl;
    };

    homeManagerModules = {
      omdrop-plugin = ./modules/home-manager/omdrop-plugin.nix;
      default = self.homeManagerModules.omdrop-plugin;
    };

    checks = forAllSystems (
      pkgs: system: {
        omdrop-owl = self.packages.${system}.omdrop-owl;
        omdrop-plugin = self.packages.${system}.omdrop-plugin;

        # Evaluates the NixOS module the way a consumer's switch would, so a
        # broken option name or a package that no longer evaluates fails
        # here rather than on someone's machine.
        nixos-module = let
          nixos = import "${pkgs.path}/nixos/lib/eval-config.nix" {
            inherit system;
            modules = [
              ./modules/nixos/omdrop-owl.nix
              {
                programs.omdrop-owl.enable = true;
                programs.omdrop-owl.allowUntested = true;
              }
            ];
          };
        in
          pkgs.runCommand "omdrop-owl-nixos-module-check"
          {
            passAsFile = ["text"];
            text = lib.concatStringsSep "\n" nixos.config.systemd.tmpfiles.rules;
          }
          ''
            grep -q "L+ /usr/lib/omdrop" "$textPath"
            grep -q "/etc/omdrop" "$textPath"
            mkdir "$out"
          '';

        home-manager-module = let
          hm = home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = [
              ./modules/home-manager/omdrop-plugin.nix
              {
                home.username = "omdrop-check";
                home.homeDirectory = "/home/omdrop-check";
                home.stateVersion = "24.11";
                programs.omdrop-plugin.enable = true;
                programs.omdrop-plugin.name = "omdrop-check";
                programs.omdrop-plugin.downloadDir = "/home/omdrop-check/AirDrop";
              }
            ];
          };
        in
          pkgs.runCommand "omdrop-plugin-home-manager-module-check"
          {
            unit = hm.config.home.file.".config/systemd/user/airdrop-receiver.service".source;
            command = hm.config.home.file.".local/bin/omdrop".source;
            config = pkgs.writeText "airdrop-config-check.toml" hm.config.xdg.configFile."airdrop/config.toml".text;
          }
          ''
            test -f "$unit"
            test -f "$command"
            grep -q 'name = "omdrop-check"' "$config"
            grep -q 'download_dir = "/home/omdrop-check/AirDrop"' "$config"
            mkdir "$out"
          '';
      }
    );

    formatter = forAllSystems (pkgs: _system: pkgs.nixfmt-rfc-style);
  };
}
