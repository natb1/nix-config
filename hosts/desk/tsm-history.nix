# A history of auction-house prices for WoW Classic Era, in
# ~/.local/state/tsm-history/history.db, from two sources (tsm-history.py):
#
# - TSM: the TSM app (gaming.nix) rewrites TradeSkillMaster_AppHelper/
#   AppData.lua on every sync and keeps no past copies; each rewrite stores
#   the data sets with a new downloadTime. Query the `price` view: dataset,
#   scope (realm or region), downloaded, item ("i:<id>"), name, field, value.
# - Auctionator: the in-game scans of the realm's own auction house, which
#   Auctionator prunes after a few weeks. Its saved variables are written on
#   logout and /reload, so they are read when WoW exits (battlenet's watcher
#   in gaming.nix) and daily. Query the `auctionator` view: realm, day,
#   item, name, low and high (the day's lowest buyout, lowest and highest
#   seen), available.
#
# Prices are in copper. Names are only those the TSM app has shown.

{ pkgs, ... }:

let
  wow = "/srv/games/battlenet/drive_c/Program Files (x86)/World of Warcraft";
  appData = "${wow}/_classic_era_/Interface/AddOns/TradeSkillMaster_AppHelper/AppData.lua";

  tsm-history = pkgs.writers.writePython3Bin "tsm-history" {
    libraries = [ pkgs.python3Packages.cbor2 ];
  } (builtins.readFile ./tsm-history.py);

  # Every account's: each has its own Auctionator saved variables.
  auctionator-history = pkgs.writeShellScript "auctionator-history" ''
    shopt -s nullglob
    files=("${wow}"/_classic_era_/WTF/Account/*/SavedVariables/Auctionator.lua)
    exec ${pkgs.lib.getExe tsm-history} auctionator "$STATE_DIRECTORY/history.db" "''${files[@]}"
  '';
in
{
  environment.systemPackages = [ tsm-history pkgs.sqlite ];

  systemd.user.services.tsm-history = {
    description = "Record TSM's AppData.lua into the price history";
    unitConfig = {
      RequiresMountsFor = "/srv/games";
      ConditionPathExists = appData;
    };
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "tsm-history";
      ExecStart = "${pkgs.lib.getExe tsm-history} tsm %S/tsm-history/history.db \"${appData}\" %h/.local/share/tsm-app/item_cache.json";
    };
  };

  systemd.user.services.auctionator-history = {
    description = "Record Auctionator's scans into the price history";
    unitConfig.RequiresMountsFor = "/srv/games";
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "tsm-history";
      ExecStart = auctionator-history;
    };
  };

  # Besides WoW's exit: a session that never ends cleanly, or a /reload.
  systemd.user.timers.auctionator-history = {
    description = "Record Auctionator's scans daily";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };

  systemd.user.paths.tsm-history = {
    description = "Watch TSM's AppData.lua for a new sync";
    wantedBy = [ "default.target" ];
    pathConfig.PathChanged = appData;
  };
}
