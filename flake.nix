{
  description = "H2 Load Testing";

  inputs = {
    nixpkgs.url = "github:nixOS/nixpkgs/96bf45e4c6427f9152afed99dde5dc16319ddbd6";
    ocaml-overlay.url = "github:dialohq/nix-overlays/6a3388db877f6fda5538e14fd10eede6e00fcc49";
    ocaml-overlay.inputs.nixpkgs.follows = "nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    ocaml-overlay,
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;

        overlays = [
          ocaml-overlay.overlays.default

          (
            self: super: let
              inherit (super) fetchFromGitHub fetchurl pkgs;
            in {
              ocaml-ng =
                super.ocaml-ng
                // {
                  ocamlPackages_5_3 =
                    super.ocaml-ng.ocamlPackages_5_3.overrideScope'
                    (
                      oself: super:
                        with oself; let
                          ocaml_grpc_src = fetchFromGitHub {
                            owner = "dialohq";
                            repo = "ocaml-grpc";
                            rev = "5dfdb4e2744136bebf49b9caec044fbf40de7778";
                            sha256 = "sha256-qJkzTVD3mQWVQ8auFezIZT6sExs5puSfVlb9UORR+PQ=";
                            fetchSubmodules = true;
                          };

                          ocamlProtocSrc = fetchFromGitHub {
                            owner = "dialohq";
                            repo = "ocaml-protoc";
                            rev = "3d2099e5e6b223b8ea38b2279a983878b22b074b";
                            sha256 = "sha256-HeTZTYzq71qenJRkLpPAuz9YSW7UVMb1K1p2F1mc4Oo=";
                            fetchSubmodules = true;
                          };

                          mkGrpcPkg = pname: nativeBuildInputs: buildDeps:
                            buildDunePackage {
                              pname = pname;
                              version = "0.1.0";
                              duneVersion = "3";
                              src = ocaml_grpc_src;
                              nativeBuildInputs = [pkgs.git] ++ nativeBuildInputs;
                              propagatedBuildInputs = buildDeps;
                            };
                        in {
                          pbrt = super.pbrt.overrideAttrs (_: {src = ocamlProtocSrc;});
                          pbrt_services = super.buildDunePackage {
                            pname = "pbrt_services";
                            version = "3.0.1";
                            duneVersion = "3";
                            propagatedBuildInputs = [oself.pbrt oself.pbrt_yojson];
                            src = ocamlProtocSrc;
                          };
                          pbrt_yojson = super.buildDunePackage {
                            pname = "pbrt_yojson";
                            version = "3.0.1";
                            duneVersion = "3";
                            propagatedBuildInputs = [super.yojson super.base64];
                            src = ocamlProtocSrc;
                          };
                          ocaml-protoc = super.ocaml-protoc.overrideAttrs (_: {
                            propagatedBuildInputs =
                              super.ocaml-protoc.propagatedBuildInputs
                              ++ [oself.pbrt_yojson oself.pbrt_services];
                            src = ocamlProtocSrc;
                          });

                          grpc = mkGrpcPkg "grpc" [git ppx_deriving] [git bigstringaf ppx_deriving uri];
                          grpc-server-eio = mkGrpcPkg "grpc-server-eio" [] [grpc-eio-core grpc-server grpc eio];
                          grpc-eio-io-client-h2-ocaml-protoc = mkGrpcPkg "grpc-eio-io-client-h2-ocaml-protoc" [] [grpc-eio-core h2-eio grpc-client-eio ocaml-protoc];
                          grpc-eio-io-server-h2-ocaml-protoc = mkGrpcPkg "grpc-eio-io-server-h2-ocaml-protoc" [] [grpc-eio-core h2-eio grpc-server-eio ocaml-protoc];
                          grpc-client-eio = mkGrpcPkg "grpc-client-eio" [] [grpc grpc-client grpc-eio-core];
                          grpc-client = mkGrpcPkg "grpc-client" [] [grpc];
                          grpc-server = mkGrpcPkg "grpc-server" [] [grpc];
                          grpc-eio-core = mkGrpcPkg "grpc-eio-core" [] [h2-eio stringext grpc eio ppx_expect];
                          arpaca = mkGrpcPkg "arpaca" [git ppx_deriving] [grpc-client-eio grpc-server-eio grpc-eio-io-client-h2-ocaml-protoc grpc-eio-io-server-h2-ocaml-protoc cmdliner];
                        }
                    );
                };
            }
          )
          (self: super: {
            ocamlPackages = super.ocaml-ng.ocamlPackages_5_3;
          })
        ];
      };
    in {
      packages.default = with pkgs.ocamlPackages;
        buildDunePackage {
          pname = "h2-repro";
          version = "0.0.1";
          buildInputs = [
            dune
            grpc
            grpc-server-eio
            grpc-client-eio
            grpc-eio-io-client-h2-ocaml-protoc
            grpc-eio-io-server-h2-ocaml-protoc
            arpaca
            ocaml-protoc
          ];
        };
      devShells.default = pkgs.mkShell {
        inputsFrom = [self.packages.${system}.default];
        packages = with pkgs; [
          alejandra
        ];
      };
    });
}
