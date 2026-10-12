{
  lib,
  stdenv,
  fetchgit,
  coreutils,
  gnugrep,
  gnused,
  iproute2,
  libarchive,
  keyutils,
  python3,
  util-linux,
  networkmanager,
  procps,
  bash,
}:
# The omdrop plugin: the `omdrop` CLI, the AirDrop receiver
# (airdrop-serve.py) and the Quickshell bar widget.
#
# The plugin is a self-contained project directory -- bin/omdrop finds its
# siblings by resolving $0 and looking for manifest.json one level up -- so it
# is installed whole, with $out *as* that project directory. Symlinking
# $out/bin/omdrop anywhere (e.g. ~/.local/bin/omdrop) keeps that working:
# bin/omdrop resolves $0 through the symlink before walking up.
#
# Upstream installs itself with `omarchy plugin add`, which does two things
# this package does differently: it copies the project to a path of its own
# choosing and it writes the user unit. Here the unit is generated at build
# time with the store path substituted, so `setup` never has to write it.
let
  rev = "b2f9a537b150c26402c5daad8125fb7e61c214ec";

  # Receives the HTTP POSTs from Apple devices and writes the files out.
  # libarchive-c is the receiver's only third-party Python import.
  pythonEnv = python3.withPackages (ps: with ps; [libarchive-c]);

  # The CLI shells out to systemctl, nmcli, ip and ss, and the Quickshell
  # panel shells out to the CLI with a PATH that may have none of them.
  runtimePath = lib.makeBinPath [
    bash
    coreutils
    gnugrep
    gnused
    iproute2
    util-linux
    networkmanager
    procps
    pythonEnv
  ];

  version = "0.16.1";
in
  stdenv.mkDerivation {
    pname = "omdrop-plugin";
    inherit version;

    src = fetchgit {
      url = "https://github.com/brentkearney/omdrop-plugin";
      inherit rev;
      hash = "sha256-VXIpUAmABTPUaiYRcJR71upvlH2SCoYkLO1pubUoooo=";
    };

    nativeBuildInputs = [pythonEnv];

    buildInputs = [
      libarchive
      keyutils
    ];

    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
          runHook preInstall

          # Everything the plugin looks for relative to itself.
          mkdir -p "$out/bin"
          cp -r bin share skills docs "$out"
          cp manifest.json README.md LICENSE preview.png Panel.qml Radar.qml OmdropIcon.qml "$out"
          chmod -R u+w "$out"

          chmod 755 "$out/bin/omdrop"
          chmod 644 "$out/bin"/*.py
          chmod 755 "$out/bin"/*.py
          patchShebangs "$out/bin"

          # Same trick the omdrop-owl helper needs: a PATH that survives a bare
          # caller, and no __pycache__ in the read-only store.
          head -n 1 "$out/bin/omdrop" > "$out/bin/.omdrop.new"
          cat >> "$out/bin/.omdrop.new" <<EOF
      # injected by NixOS packaging (pkgs/omdrop-plugin.nix)
      export PATH="${runtimePath}:\$PATH"
      export PYTHONDONTWRITEBYTECODE=1
      EOF
          tail -n +2 "$out/bin/omdrop" >> "$out/bin/.omdrop.new"
          mv "$out/bin/.omdrop.new" "$out/bin/omdrop"
          chmod 755 "$out/bin/omdrop"

          # bin/identity.py reaches for libkeyutils.so.1 through ctypes, which does
          # not honour RPATH entries, so the unit tells it where the library lives.
          # The ExecStartPre waits shell out to `seq`, `sleep` and `grep`, which the
          # user manager's PATH may not carry -- point them at the store too.
          substituteInPlace share/airdrop-receiver.service \
            --replace-fail @PLUGIN_DIR@ "$out" \
            --replace-fail "ExecStart=/usr/bin/python3 " \
              "ExecStart=${coreutils}/bin/env LD_LIBRARY_PATH=${keyutils}/lib ${pythonEnv}/bin/python3 " \
            --replace-fail "seq 1 40" "${coreutils}/bin/seq 1 40" \
            --replace-fail "seq 1 60" "${coreutils}/bin/seq 1 60" \
            --replace-fail "sleep 0.25" "${coreutils}/bin/sleep 0.25" \
            --replace-fail "sleep 0.5" "${coreutils}/bin/sleep 0.5" \
            --replace-fail "grep -q" "${gnugrep}/bin/grep -q" \
            --replace-fail "ss -Hltn" "${iproute2}/bin/ss -Hltn" \
            --replace-fail "ip -6 addr" "${iproute2}/bin/ip -6 addr"
          mkdir -p "$out/lib/systemd/user"
          cp share/airdrop-receiver.service "$out/lib/systemd/user/airdrop-receiver.service"

          install -Dm644 "$out/LICENSE" "$out/share/doc/$pname/LICENSE"
          install -Dm644 "$out/README.md" "$out/share/doc/$pname/README.md"

          # The unit template must not survive the substitution: a copy that still
          # carries @PLUGIN_DIR@ cannot start, and setup refuses to write one.
          if grep -q '@PLUGIN_DIR@' "$out/lib/systemd/user/airdrop-receiver.service"; then
            echo "omdrop-plugin: unit still carries the @PLUGIN_DIR@ placeholder" >&2
            exit 1
          fi
          grep -q "${pythonEnv}/bin/python3" "$out/lib/systemd/user/airdrop-receiver.service" || {
            echo "omdrop-plugin: unit ExecStart was not redirected to the Nix python" >&2
            exit 1
          }

          # bin/omdrop must be able to find manifest.json through its own path.
          [[ -x "$out/bin/omdrop" && -r "$out/manifest.json" ]] || {
            echo "omdrop-plugin: project directory layout is broken" >&2
            exit 1
          }

          runHook postInstall
    '';

    meta = {
      description = "AirDrop for Linux: send and receive files with nearby Apple devices";
      homepage = "https://github.com/brentkearney/omdrop-plugin";
      changelog = "https://github.com/brentkearney/omdrop-plugin/releases";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
      mainProgram = "omdrop";
    };
  }
