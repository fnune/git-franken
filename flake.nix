{
  description = "Rebuild disposable integration branches from a manifest";

  # nixpkgs is deliberately the only input. Dev tooling (formatters, linters)
  # comes from nixpkgs directly rather than from flake wrappers, because a flake
  # input is inherited by every consumer: extra inputs here would force everyone
  # installing this package to either fetch our dev tooling or `follows` it away.
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

    formatters = pkgs: [pkgs.alejandra pkgs.shfmt pkgs.prettier];

    # bats parses `@test "..." { }`, which shfmt cannot.
    shellFiles = "git-franken tests/*.bash";
  in {
    packages = forAllSystems (pkgs: rec {
      default = git-franken;
      git-franken = pkgs.writeShellApplication {
        name = "git-franken";
        runtimeInputs = [pkgs.git];
        text = builtins.readFile ./git-franken;
        meta = {
          description = "Rebuild disposable integration branches from a manifest";
          mainProgram = "git-franken";
        };
      };
    });

    formatter = forAllSystems (pkgs:
      pkgs.writeShellApplication {
        name = "fmt";
        runtimeInputs = formatters pkgs;
        text = ''
          cd "''${1:-.}"
          alejandra --quiet .
          # shellcheck disable=SC2086
          shfmt --write --indent 2 ${shellFiles}
          prettier --write --log-level warn '**/*.{md,json}'
        '';
      });

    checks = forAllSystems (pkgs: {
      lint =
        pkgs.runCommand "git-franken-lint" {
          nativeBuildInputs = formatters pkgs ++ [pkgs.shellcheck];
        } ''
          cp -r ${nixpkgs.lib.cleanSource ./.}/. work
          chmod -R +w work
          cd work

          shellcheck --severity=style ${shellFiles}
          # shellcheck disable=SC2086
          shfmt --diff --indent 2 ${shellFiles}
          alejandra --check .
          prettier --check --log-level warn '**/*.{md,json}'

          touch "$out"
        '';

      tests =
        pkgs.runCommand "git-franken-tests" {
          nativeBuildInputs = [pkgs.bats pkgs.git pkgs.coreutils];
          GIT_FRANKEN = nixpkgs.lib.getExe self.packages.${pkgs.system}.git-franken;
        } ''
          cp -r ${nixpkgs.lib.cleanSource ./.}/. work
          chmod -R +w work
          cd work
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          bats tests/git-franken.bats
          touch "$out"
        '';
    });

    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        packages = formatters pkgs ++ [pkgs.bats pkgs.git pkgs.shellcheck];
      };
    });
  };
}
