# SSH Key Auto-Generation Module
#
# This module automatically generates SSH keys on new machines if they don't exist.
# This eliminates the manual step of running ssh-keygen on each new machine.
#
# Features:
# - Generates Ed25519 key (modern, secure, fast)
# - Only generates if key doesn't already exist
# - Sets correct permissions automatically
# - Uses hostname-based comment for identification
#
# After key generation:
#   1. View your public key: cat ~/.ssh/id_ed25519.pub
#   2. Add it to services.sshAuthorizedKeys.keys in modules/home/default.nix
#   3. Commit, push, and run `rebuild` on the other hosts so they accept this
#      machine's key
#
# Security:
#   - Keys are generated locally on each machine
#   - Private keys never leave the machine
#   - No passphrase (for automation - add one manually if needed)

{
  config,
  lib,
  pkgs,
  ...
}:

let
  sshDir = "${config.home.homeDirectory}/.ssh";

  # Primary key (default for most operations)
  primaryKeyFile = "${sshDir}/id_ed25519";

in
{
  # Generate primary SSH key if it doesn't exist. The key's comment takes the
  # host from `uname -n` (coreutils): activation's PATH has no `hostname`.
  home.activation.generatePrimarySshKey = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -f "${primaryKeyFile}" ]; then
      echo "Generating SSH key at ${primaryKeyFile}..."
      $DRY_RUN_CMD ${pkgs.openssh}/bin/ssh-keygen \
        -t ed25519 \
        -C "$(whoami)@$(uname -n)" \
        -N "" \
        -f "${primaryKeyFile}"

      echo ""
      echo "✓ SSH key generated successfully!"
      echo ""
      echo "Your public key:"
      echo "----------------"
      $DRY_RUN_CMD cat "${primaryKeyFile}.pub"
      echo "----------------"
      echo ""
      echo "Next steps:"
      echo "  1. Copy the public key above"
      echo "  2. Add it to services.sshAuthorizedKeys.keys in modules/home/default.nix (natb1/nix-config)"
      echo "  3. Commit, push, and run 'rebuild' on the other hosts so this machine can SSH into them"
      echo ""
    fi
  '';

}
