# A history of TSM's auction-house prices for WoW Classic Era. The TSM app
# (gaming.nix) rewrites TradeSkillMaster_AppHelper/AppData.lua on every sync
# and keeps no past copies; each time it does, tsm-history.py stores the data
# sets with a new downloadTime in ~/.local/state/tsm-history/history.db.
#
# Its `price` view is the one to query: dataset, scope (realm or region),
# downloaded, item ("i:<id>"), name (only for items the TSM app has shown),
# field and value (copper for prices).

{ pkgs, ... }:

let
  wow = "/srv/games/battlenet/drive_c/Program Files (x86)/World of Warcraft";
  appData = "${wow}/_classic_era_/Interface/AddOns/TradeSkillMaster_AppHelper/AppData.lua";

  tsm-history = pkgs.writers.writePython3Bin "tsm-history" { } (builtins.readFile ./tsm-history.py);
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
      ExecStart = "${pkgs.lib.getExe tsm-history} \"${appData}\" %S/tsm-history/history.db %h/.local/share/tsm-app/item_cache.json";
    };
  };

  systemd.user.paths.tsm-history = {
    description = "Watch TSM's AppData.lua for a new sync";
    wantedBy = [ "default.target" ];
    pathConfig.PathChanged = appData;
  };
}
