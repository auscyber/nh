{
  pkgs,
  crane,
  rev ? "dirty",
  use-nom ? true,
  nix-output-monitor ? null,
}:
assert use-nom -> nix-output-monitor != null;
let
  lib = pkgs.lib;
  craneLib = crane.mkLib pkgs;
  runtimeDeps = lib.optionals use-nom [ nix-output-monitor ];
  cargoToml = lib.importTOML ./Cargo.toml;
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.intersection (lib.fileset.fromSource (lib.sources.cleanSource ./.)) (
      lib.fileset.unions [
        ./.cargo
        ./.config
        ./crates
        ./Cargo.toml
        ./Cargo.lock
      ]
    );

  };
  skipTests = lib.concatStringsSep " " (
    [
      # These do not work in Nix's sandbox
      "--skip test_get_build_image_variants_expression"
      "--skip test_get_build_image_variants_file"
      "--skip test_get_build_image_variants_flake"
    ]
    ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
      # Tests that require sudo in PATH (not available on Darwin)
      "--skip test_build_sudo_cmd_basic"
      "--skip test_build_sudo_cmd_with_preserve_vars"
      "--skip test_build_sudo_cmd_with_preserve_vars_disabled"
      "--skip test_build_sudo_cmd_with_set_vars"
      "--skip test_build_sudo_cmd_force_no_stdin"
      "--skip test_build_sudo_cmd_with_remove_vars"
      "--skip test_build_sudo_cmd_with_askpass"
      "--skip test_build_sudo_cmd_env_added_once"
      "--skip test_elevation_strategy_passwordless_resolves"
      "--skip test_build_sudo_cmd_with_nix_config_spaces"
    ]
  );
  commonArgs = {
    inherit src;
    pname = "nh";
    version = "${cargoToml.workspace.package.version}-${rev}";
    strictDeps = true;
    cargoExtraArgs = "--workspace";
    buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ pkgs.libiconv ];

    # pkgs.sudo is not available on the Darwin platform, and thus breaks build
    # if added to nativeCheckInputs. We must manually disable the tests that
    # *require* it, because they will fail when sudo is missing.
    nativeCheckInputs = lib.optionals (!pkgs.stdenv.hostPlatform.isDarwin) [ pkgs.sudo ];
    env.NH_REV = rev;
  };
  cargoArtifacts = craneLib.buildDepsOnly commonArgs;
in
craneLib.buildPackage (
  commonArgs
  // {
    inherit cargoArtifacts;

    nativeBuildInputs = [
      pkgs.installShellFiles
      pkgs.makeBinaryWrapper
    ];

    cargoTestExtraArgs = "-- ${skipTests}";

    postInstall =
      lib.optionalString (pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform) ''
        # Run both shell completion and manpage generation tasks. Unlike the
        # fine-grained variants, the 'dist' command doesn't allow specifying the
        # path but that's fine, because we can simply install them from the implicit
        # output directories.
        chmod +x $out/bin/xtask
        $out/bin/xtask dist

        # The dist task above should've created
        #  1. Shell completions in comp/
        #  2. The NH manpage (nh.1) in man/
        # Let's install those.
        # The important thing to note here is that installShellCompletion cannot
        # actually load *all* shell completions we generate with 'xtask dist'.
        # Elvish, for example isn't supported. So we have to be very explicit
        # about what we're installing, or this will fail.
        installShellCompletion --cmd nh ./comp/*.{bash,fish,zsh,nu}
        installManPage ./man/nh.1
      ''
      + ''
        # Avoid populating PATH with an 'xtask' cmd
        rm $out/bin/xtask
      '';

    postFixup = ''
      wrapProgram $out/bin/nh \
        --prefix PATH : ${lib.makeBinPath runtimeDeps}
    '';

    nativeInstallCheckInputs = [ pkgs.versionCheckHook ];
    doInstallCheck = false; # FIXME: --version includes 'dirty' and the hook doesn't let us change the assertion
    versionCheckProgram = "${placeholder "out"}/bin/nh";
    versionCheckProgramArg = "--version";

    meta = {
      description = "Yet another nix cli helper";
      homepage = "https://github.com/nix-community/nh";
      license = lib.licenses.eupl12;
      mainProgram = "nh";
      maintainers = with lib.maintainers; [
        drupol
        faukah
        NotAShelf
      ];
    };
  }
)
