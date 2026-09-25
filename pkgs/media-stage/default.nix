# media-stage: stage, classify and file media into /srv/media.
# docs/desktop-migration.md, "Layout on the share", is the design; the
# script's header is the usage. Built for desk and for the Mac, which runs it
# against the share mounted at /Volumes/media.
#
# The external tools it calls are on the wrapper's PATH, so the command works
# the same on both hosts without anything else installed. The tests run in the
# build: a broken layout rule fails `nix flake check`, not a batch.

{ lib, python3Packages, ffmpeg-headless, poppler-utils, exiftool, mkvtoolnix-cli }:

let
  tools = [ ffmpeg-headless poppler-utils exiftool mkvtoolnix-cli ];
in
python3Packages.buildPythonApplication {
  pname = "media-stage";
  version = "0.1.0";
  pyproject = false;
  src = ./.;

  dependencies = [ python3Packages.guessit ];

  installPhase = ''
    runHook preInstall
    install -Dm755 media_stage.py $out/bin/media-stage
    runHook postInstall
  '';

  makeWrapperArgs = [ "--prefix" "PATH" ":" (lib.makeBinPath tools) ];

  doCheck = true;
  nativeCheckInputs = tools;
  checkPhase = ''
    runHook preCheck
    python -m unittest -v test_media_stage
    runHook postCheck
  '';

  meta = {
    description = "Stage, classify and file media into the /srv/media library";
    mainProgram = "media-stage";
    platforms = [ "x86_64-linux" "aarch64-darwin" ];
  };
}
