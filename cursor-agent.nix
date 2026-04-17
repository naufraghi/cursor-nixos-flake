# Cursor Agent CLI from the official lab tarball (bundled Node; FHS-wrapped).
{ pkgs, agentVersions, system }:
let
  inherit (agentVersions) labVersion;
  agentArch = agentVersions.sources.${system};
  src = pkgs.fetchurl {
    inherit (agentArch) url sha256;
  };
  agentDist = pkgs.stdenvNoCC.mkDerivation {
    pname = "cursor-agent-dist";
    version = labVersion;
    inherit src;
    sourceRoot = ".";
    installPhase = ''
      mkdir -p $out
      cp -r dist-package $out/
    '';
    dontStrip = true;
    preferLocalBuild = true;
  };
in
pkgs.buildFHSEnv {
  pname = "cursor-agent";
  version = labVersion;
  runScript = pkgs.writeShellScript "cursor-agent-wrap" ''
    exec ${agentDist}/dist-package/cursor-agent "$@"
  '';
  targetPkgs = pkgs: [ pkgs.stdenv.cc.cc.lib ];
  meta = with pkgs.lib; {
    description = "Cursor Agent CLI (upstream lab build)";
    homepage = "https://cursor.com";
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };
}
