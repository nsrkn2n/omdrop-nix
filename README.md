# omdrop-nix

AirDrop for Linux, packaged for Nix. Two pieces, both built from the upstream
sources with pinned revisions:

| package | upstream | what it is |
| --- | --- | --- |
| `omdrop-owl` | [t4t5/omdrop-owl](https://github.com/t4t5/omdrop-owl) | the radio half: a userspace AWDL daemon (`owl`) and the `omdrop-discoverable` helper that turns any Wi-Fi card into an AirDrop radio. Intel (iwlwifi) cards get exclusive mode; MediaTek (mt7925e) gets shared mode. Tested on an AX210. |
| `omdrop-plugin` | [brentkearney/omdrop-plugin](https://github.com/brentkearney/omdrop-plugin) | the user half: the `omdrop` CLI, `airdrop-serve.py` (the receiver on port 8771) and the Quickshell bar widget. |

Upstream installs the plugin with `omarchy plugin add`, which is
Omarchy-specific; these modules are the NixOS equivalent. You need **both**
packages — the plugin looks for the backend at `/usr/lib/omdrop`.

## Using it

```nix
# flake.nix
inputs.omdrop-nix.url = "github:nsrkn2n/omdrop-nix";
```

```nix
# configuration.nix
{ inputs, ... }: {
  imports = [ inputs.omdrop-nix.nixosModules.default ];

  programs.omdrop-owl.enable = true;
}
```

and, in the Home Manager block for whoever should receive files:

```nix
{ inputs, ... }: {
  imports = [ inputs.omdrop-nix.homeManagerModules.default ];

  programs.omdrop-plugin = {
    enable = true;
    name = "thonkpad";          # what Apple devices see
    # downloadDir = "~/AirDrop";
  };

  # The receiver runs as *this* user, so it needs to reach the awdl0 the
  # system side creates. NetworkManager is already marked unmanaged by the
  # omdrop-owl module; users in the `networkmanager` group can also do this by
  # hand after a switch:
  #   nmcli general reload conf
}
```

### After the first switch

tmpfiles rules are not applied by a switch, so the `/usr/lib/omdrop` symlink
appears only at the next boot. To get it sooner:

```console
$ sudo systemctl restart systemd-tmpfiles-setup.service
$ nmcli general reload conf
```

Then, as the user:

```console
$ omdrop setup       # once: the TLS identity, the macOS-style config
$ omdrop on          # visible for ten minutes; omdrop on 30 for half an hour
$ omdrop peers       # who is nearby
$ omdrop status
```

`omdrop on` runs the receiver for the length of a window and stops it again,
which is what "visible to Everyone" means — the unit is installed but never
enabled. Nothing is on by default, and it is a good idea to read
`docs/radio-backend.md` and the plugin README once before your first transfer.

## Options

`programs.omdrop-owl` (NixOS):

- `package` — any package that installs `omdrop-discoverable` under
  `lib/omdrop` with a polkit action naming it.
- `unmanagedInterfaces` — defaults to the three interfaces the helper creates
  (`awdl0`, `mon0`, `awdlibss0`), so NetworkManager leaves them alone mid-transfer.
- `allowUntested` — writes `/etc/omdrop/allow-untested`. Only for hardware
  whose profile is marked untested; the iwlwifi and mt7925e profiles are
  tested, so Intel AX210 owners do not need it.

`programs.omdrop-plugin` (Home Manager):

- `package`, `installCommand` (`~/.local/bin/omdrop` symlink),
  `installReceiverUnit`, `name`, `model`, `downloadDir`,
  `maxReceivePercent` — the last three map onto
  `~/.config/airdrop/config.toml`, which `airdrop-serve.py` validates on every
  start. A value the receiver rejects is a value it refuses to start with, so
  a bad `downloadDir` (missing, or owned by someone else) fails loudly.

## Building and checking

```console
$ nix build .#omdrop-owl
$ nix build .#omdrop-plugin
$ nix flake check
```

The checks build both packages *and* evaluate the modules the way a consumer's
switch would, so a stale option name or a source hash that no longer resolves
fails here rather than on someone's machine.

## Status

Works here: X250 (Intel AX210), 0.16.1 of the plugin against a 0.1.0 backend,
probe reports `{"backend":"owl","contract":"0.8.1","hardware":true,"missing":[]}`.

Not packaged: the Quickshell bar widget integration (the QML is installed, but
wiring it to Noctalia's bar is a separate job) and the plugin's
`install-driver` path, which builds a *different* backend (omdrop-awdl, for
Broadcom cards) and refuses to touch an installed package.

## Licences

- `pkgs/omdrop-owl.nix` builds code from `owl` (GPL-3.0-or-later),
  `omdrop-owl` (GPL-3.0-or-later) and `omdrop-awdl` (GPL-2.0-only); the
  radiotap library is ISC.
- `pkgs/omdrop-plugin.nix` installs `omdrop-plugin` (MIT).
- This flake's own expressions are MIT.
