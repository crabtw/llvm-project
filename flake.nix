{
  outputs = { self, nixpkgs }:
    let

      systems = [
        "x86_64-linux"
      ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

      buildPackage = { system }:
        let

          pkgs = import nixpkgs {
            inherit system;
          };

        in pkgs.mkShell {
          buildInputs = with pkgs; [
            # deps
            cmake
            python3
            libedit
            libffi
            libbfd
            libxml2
            ncurses
            zlib
            ninja

            # host toolchain
            llvmPackages_latest.lldClang

            # review
            arcanist
          ];
        };

    in {
      devShell = forAllSystems (system:
        buildPackage { inherit system; }
      );
    };
}
