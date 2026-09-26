# media-fetch: search a download network and fetch what the user picks into
# a staging batch, for media-stage to file. The script's header is the usage.
# Its interface names no network; the backend behind it today is desk's
# slskd (hosts/desk/soulseek.nix). Standard library only. The tests run in
# the build, against a fake slskd.

{ python3Packages }:

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
