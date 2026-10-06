# media-playlist: the playlists of desk's Navidrome (hosts/desk/music.nix),
# from a shell, for an agent to manage. The script's header is the usage.
# It keeps no playlists itself: they are Navidrome's own, so every client of
# the account sees the same ones. Standard library only. The tests run in
# the build, against a fake Navidrome.
#
# url: the server, the script's NAVIDROME_URL (which still overrides it).

{ python3Packages, url ? "http://localhost:4533" }:

python3Packages.buildPythonApplication {
  pname = "media-playlist";
  version = "0.1.0";
  pyproject = false;
  src = ./.;

  installPhase = ''
    runHook preInstall
    install -Dm755 media_playlist.py $out/bin/media-playlist
    runHook postInstall
  '';

  makeWrapperArgs = [ "--set-default" "NAVIDROME_URL" url ];

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    python -m unittest -v test_media_playlist
    runHook postCheck
  '';

  meta = {
    description = "Manage the playlists of a Navidrome music server";
    mainProgram = "media-playlist";
    platforms = [ "x86_64-linux" "aarch64-darwin" ];
  };
}
