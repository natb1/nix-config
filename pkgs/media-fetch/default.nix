# media-fetch: search for media and fetch what the user picks into a
# staging batch, for media-stage to file. The script's header is the usage.
# Its interface names no network: the corpus it searches is desk's slskd
# (hosts/desk/soulseek.nix), "corpus fetch" in everything it prints, and
# tabletop games come from itch.io too. Standard library only. The tests
# run in the build, against a fake slskd and a fake itch.io.
#
# stateDir: where results and jobs live, for every user of this copy (the
# script's MEDIA_FETCH_STATE, which still overrides it). Default: each
# user's own $XDG_STATE_HOME/media-fetch.
# corpusKeyFile, corpusDownloads: slskd's API key file and download
# directory, the script's CORPUS_KEY_FILE and CORPUS_DOWNLOADS: set here
# so the script itself never names them.

{ lib, python3Packages, stateDir ? null
, corpusKeyFile ? "/etc/slskd/api.env"
, corpusDownloads ? "/srv/media/staging/corpusfetch"
}:

python3Packages.buildPythonApplication {
  pname = "media-fetch";
  version = "0.1.0";
  pyproject = false;
  src = ./.;

  installPhase = ''
    runHook preInstall
    install -Dm755 media_fetch.py $out/bin/media-fetch
    runHook postInstall
  '';

  makeWrapperArgs = [
    "--set-default" "CORPUS_KEY_FILE" corpusKeyFile
    "--set-default" "CORPUS_DOWNLOADS" corpusDownloads
  ] ++ lib.optionals (stateDir != null) [ "--set-default" "MEDIA_FETCH_STATE" stateDir ];

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    python -m unittest -v test_media_fetch
    runHook postCheck
  '';

  meta = {
    description = "Search for media and fetch it into a media-stage batch";
    mainProgram = "media-fetch";
    platforms = [ "x86_64-linux" "aarch64-darwin" ];
  };
}
