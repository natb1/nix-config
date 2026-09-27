# The wallpaper: five of Mythic Bastionland's knight portraits side by side
# on the 3440x1440 ultrawide, spaced evenly with the Moat Knight's background.
#
# The art is bought (all rights reserved) and this repo is public, so the
# image is not committed or fetched. desk builds it from the Knight Art .cbz
# on its media share, once, into the path it is given (see desktop.nix).

{ writeShellApplication, imagemagick, unzip }:

writeShellApplication {
  name = "knights-wallpaper";
  runtimeInputs = [ imagemagick unzip ];
  text = ''
    out=$1
    [ -e "$out" ] && exit 0

    cbz="/srv/media/rpg/Mythic Bastionland/Mythic Bastionland - Knight Art.cbz"
    knights=(
      1-6_Knight_-_War_Knight
      3-4_Knight_-_Moat_Knight
      5-5_Knight_-_Cosmic_Knight
      3-12_Knight_-_Forge_Knight
      2-1_Knight_-_Trail_Knight
    )
    bg="#18262E" # the Moat Knight's background

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    unzip -q -j "$cbz" "''${knights[@]/%/.png}" -d "$tmp"

    # Each 1937x4559 portrait scales to 612x1440, which leaves 380px: six
    # gaps of 63 or 64 (64 at both edges). The frame lines around each
    # portrait are transparent, so they are filled with the background too.
    args=()
    x=64
    for k in "''${knights[@]}"; do
      args+=(
        "(" "$tmp/$k.png" -background "$bg" -alpha remove -alpha off
        -filter Lanczos -resize x1440 ")" -geometry "+$x+0" -composite
      )
      x=$((x + 612 + 63))
    done

    mkdir -p "$(dirname "$out")"
    magick -size 3440x1440 "xc:$bg" "''${args[@]}" -depth 8 -strip "png:$out.tmp"
    mv "$out.tmp" "$out"
    # Earlier versions, from before the recipe changed.
    find "$(dirname "$out")" -maxdepth 1 -name 'wallpaper-*.png' ! -path "$out" -delete
  '';
}
