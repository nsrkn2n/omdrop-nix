{
  lib,
  stdenv,
  fetchgit,
  cmake,
  git,
  coreutils,
  gawk,
  gnugrep,
  gnused,
  iproute2,
  iputils,
  iw,
  libev,
  libnl,
  libpcap,
  networkmanager,
  procps,
  python3,
  util-linux,
}:
# AirDrop/AWDL radio backend for brentkearney/omdrop-plugin, built for Intel
# (iwlwifi, exclusive mode) and MediaTek (mt7925e, shared mode) cards.
#
# Upstream packaging reference: t4t5/omdrop-owl (Arch PKGBUILD + Debian
# packaging/).  There is no Nix expression upstream, so this packages the same
# layout by hand.
let
  # The userspace AWDL daemon.  Fork of jedbillyb/owl pinned by omdrop-owl; the
  # seven patches in omdrop-owl/patches are what make Intel cards work.
  owlRev = "832d70f815c3d4a06a02117bf0fc5e868daa1ff0";

  # The helper scripts that actually toggle discoverability.
  omdropOwlRev = "ee6a57d971c207c933a424c0d705044a02985b0a";

  # The AWDL Python tooling that omdrop-plugin's send-to-peer depends on.
  omdropAwdlRev = "534f91a525337951ca19c311e53d333bd6d55100";

  owlSrc = fetchgit {
    url = "https://github.com/jedbillyb/owl";
    rev = owlRev;
    hash = "sha256-wke+tR6E4mfmzlGw1tgXiYOkSxeIRvaOmOYNWXIUVR8=";
    fetchSubmodules = true; # googletest + radiotap are add_subdirectory()'d
  };

  omdropOwlSrc = fetchgit {
    url = "https://github.com/t4t5/omdrop-owl";
    rev = omdropOwlRev;
    hash = "sha256-YnBx/k6ao+y7m+p3PxFGCudrbG3/K3g3Ak1NwBdAQbs=";
  };

  omdropAwdlSrc = fetchgit {
    url = "https://github.com/brentkearney/omdrop-awdl";
    rev = omdropAwdlRev;
    hash = "sha256-GqxaM/5Qnj458AQPdHp1Jyfa6HK7tdybO6xDBbKUWc4=";
  };

  pythonEnv = python3.withPackages (ps:
    with ps; [
      dbus-python
      pygobject3
      zeroconf
      pillow
      ifaddr
    ]);

  # omdrop-discoverable runs under `pkexec`, which scrubs the environment.  It
  # hard-codes no interpreter paths, so it needs a PATH of its own.
  runtimePath = lib.makeBinPath [
    pythonEnv
    coreutils
    gawk
    gnugrep
    gnused
    iproute2
    iputils
    iw
    networkmanager
    procps
    util-linux
  ];

  # Staged verbatim from omdrop-awdl/userspace (userspace/stage.sh).
  awdlTools = [
    "send-to-peer"
    "airdrop-send.py"
    "awdl-af-parse.py"
    "awdl_identity.py"
    "awdl_debug.py"
    "ble-airdrop-adv.py"
    "awdl-airdrop-adv.py"
    "awdl-mdns-respond.py"
  ];
in
  stdenv.mkDerivation {
    pname = "omdrop-owl";
    version = "0.1.0";

    src = owlSrc;

    nativeBuildInputs = [
      cmake
      git
      pythonEnv
    ];

    buildInputs = [
      libev
      libnl
      libpcap
    ];

    # cmake >= 4 rejects the cmake_minimum_required() in owl's submodules.
    cmakeFlags = ["-DCMAKE_POLICY_VERSION_MINIMUM=3.5"];

    enableParallelBuilding = true;

    dontCheck = true; # googletest does not build against current GCC

    postPatch = ''
      # Same order as tools/build-owl.sh: each patch builds on the previous one.
      # The patches themselves are only ever read, so they can come straight
      # from the read-only store path.
      for p in ${omdropOwlSrc}/patches/owl-*.patch; do
        echo "applying $p"
        git apply "$p"
      done
    '';

    postConfigure = ''
      # cmakeConfigurePhase leaves the cwd in the build dir; remember where the
      # daemon ends up so installPhase does not have to guess.
      export owlBinary="$PWD/daemon/owl"
    '';

    buildPhase = ''
      runHook preBuild
      cmake --build . --target owl -j"$NIX_BUILD_CORES"
      runHook postBuild
    '';

    installPhase = ''
          runHook preInstall

          libdir="$out/lib/omdrop"
          mkdir -p "$libdir"

          cp ${omdropOwlSrc}/userspace/omdrop-discoverable "$libdir/omdrop-discoverable"
          cp ${omdropOwlSrc}/userspace/owl-profiles "$libdir/owl-profiles"
          cp "$owlBinary" "$libdir/owl"
          for f in ${lib.escapeShellArgs awdlTools}; do
            cp "${omdropAwdlSrc}/userspace/$f" "$libdir/$f"
          done

          chmod 755 "$libdir/omdrop-discoverable" "$libdir/owl" "$libdir/send-to-peer"
          chmod 755 "$libdir"/*.py
          chmod 644 "$libdir/owl-profiles"
          patchShebangs "$libdir"

          # omdrop-discoverable is invoked through pkexec, which hands it a bare
          # environment, and it runs the staged Python tools as root -- so give it a
          # PATH and keep it from dropping __pycache__ into the read-only store.
          head -n 1 "$libdir/omdrop-discoverable" > "$libdir/.omdrop-discoverable.new"
          cat >> "$libdir/.omdrop-discoverable.new" <<EOF
      # injected by NixOS packaging (pkgs/omdrop-owl.nix)
      export PATH="${runtimePath}:\$PATH"
      export PYTHONDONTWRITEBYTECODE=1
      EOF
          tail -n +2 "$libdir/omdrop-discoverable" >> "$libdir/.omdrop-discoverable.new"
          mv "$libdir/.omdrop-discoverable.new" "$libdir/omdrop-discoverable"
          chmod 755 "$libdir/omdrop-discoverable"

          # omdrop-plugin resolves the helper with `readlink -f`, and polkit matches
          # the annotation against the real path -- so the policy has to name the
          # store path, not /usr/lib/omdrop.
          install -Dm644 "${omdropOwlSrc}/packaging/omdrop-owl.policy" \
            "$out/share/polkit-1/actions/io.github.t4t5.omdrop-owl.policy"
          substituteInPlace "$out/share/polkit-1/actions/io.github.t4t5.omdrop-owl.policy" \
            --replace-fail /usr/lib/omdrop/omdrop-discoverable "$libdir/omdrop-discoverable"

          # Shipped for parity with upstream; the omdrop-owl NixOS module
          # additionally sets networking.networkmanager.unmanaged to the same three
          # interfaces.
          install -Dm644 "${omdropOwlSrc}/packaging/99-omdrop-owl-unmanaged.conf" \
            "$out/lib/NetworkManager/conf.d/99-omdrop-owl-unmanaged.conf"

          install -Dm644 "${omdropOwlSrc}/README.md" "$out/share/doc/$pname/README.md"
          install -Dm644 "${owlSrc}/COPYING" "$out/share/doc/$pname/COPYING.owl"
          install -Dm644 "${omdropAwdlSrc}/LICENSE" "$out/share/doc/$pname/LICENSE.omdrop-awdl"

          # Sanity checks, mirroring tools/build-owl.sh and userspace/stage.sh.
          owlHelp="$("$libdir/owl" -S intersect -R 12 -m 02:00:00:00:00:01 -F -E -h 2>&1 || true)"
          if printf '%s' "$owlHelp" | grep -q -e "invalid option" -e "\-R takes" -e "\-m takes"; then
            echo "omdrop-owl: built owl is missing the omdrop-owl patches" >&2
            exit 1
          fi

          grep -q 'export PATH=' "$libdir/omdrop-discoverable" || {
            echo "omdrop-owl: PATH injection failed" >&2
            exit 1
          }

          ${pythonEnv}/bin/python3 -c "import dbus, dbus.mainloop.glib, dbus.service; from gi.repository import GLib; import ifaddr, PIL, zeroconf"

          runHook postInstall
    '';

    meta = {
      description = "AirDrop/AWDL radio backend (OWL) for omdrop on Intel and MediaTek Wi-Fi cards";
      homepage = "https://github.com/t4t5/omdrop-owl";
      license = with lib.licenses; [
        gpl3Plus
        gpl2Only
        isc
      ];
      platforms = lib.platforms.linux;
    };
  }
