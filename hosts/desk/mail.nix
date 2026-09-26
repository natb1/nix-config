# Outgoing mail for alerts, as root: msmtp as sendmail, through Google
# Workspace (natb1.com's MX) with an app password. Direct delivery to the MX
# on port 25 is out: T-Mobile Home Internet is behind carrier-grade NAT, and a
# residential IP would fail SPF anyway.
#
# Not managed by this repo: /etc/msmtp/gmail-app-password (root 0600), a
# Google app password for nathan@natb1.com, listed in the README.
{ ... }:

{
  programs.msmtp = {
    enable = true;
    setSendmail = true;
    defaults = {
      auth = true;
      tls = true;
      port = 587;
    };
    accounts.default = {
      host = "smtp.gmail.com";
      from = "nathan@natb1.com";
      user = "nathan@natb1.com";
      passwordeval = "cat /etc/msmtp/gmail-app-password";
    };
  };
}
