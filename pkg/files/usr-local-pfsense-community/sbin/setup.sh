#!/bin/sh
# pfsense-community package setup: installs the unified community repository
# configuration + signature trust anchor, registers the menu entry.
#
# NOTE on deinstall: the repo configuration is intentionally KEPT so that
# packages installed from this repository remain resolvable during the
# pfSense boot package resync (unresolvable packages are removed). Remove
# /usr/local/etc/pkg/repos/community.conf manually if you really want it
# gone - but installed community packages will then be dropped at the next
# boot resync.

CM_BASE="/usr/local/pfsense-community"
REPO_CONF="/usr/local/etc/pkg/repos/community.conf"
PUBKEY="/usr/local/etc/pkg/community.pub"

write_pubkey() {
  cat > "$PUBKEY" <<'EOF'
-----BEGIN PUBLIC KEY-----
MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAtqlVmzxvpFPb8M2CzhTk
+u4c7NdpDUu08ou27M7alT0IHxDHDx3Ns8xYnwHxWqYX2QaKSC3SERmBjjr2k7uZ
/KIgSngvaJW6SpKPiRaWp4Z0sRV1SRWyW/msPUUnrPfBTwwEZjlRR7xJCnMzFFcv
smWYvsgzZ+n18/+KBhxnv+H0l1xl0mBsIpK30ZXLSCghJ3lwUk4nc/pXVeUF3WK9
r6WOmABsYg76YWK7fgHFCUaKG6FYnEI0zf0v/U+/KTRP0lFR2YF5a5m4+qL3HSP4
XTwrdJNNQ53+neWeF8dAiM1kNfcoJfNxV3XdJHqp3db/lhT0uMiti+0XUAaYofnZ
ZSfwQlYs3JNRVmYKkbYgABm+DAl9uQAjKzrX6dPGVhcEr/hsNMR1nHdF2FuPWyNW
n5/g0PZekExJ+IIkUkzpf0NVJe0aje8Mj1DPzv0yyzxLC/u2xl4iiQoPTT6+tkh7
W4AGl1WlUhcaOtfFJv3rxG5bDf2t6sFeqlGq9wl6bRInyYT9o7njvymCSIl0pzxy
c04zJldk69eBGwNAH48XKurg2GB58Img+sL+xB8XEeoraOLBYYnUYHX5E8aQmNmd
ntWr4EAig36SwZheugztKZwHr7r7Qr8NFOrPtsBgyLjChMEzWe8VHmdW1ZEIOKvQ
FEVXWloBpk7sipZSNpDbgksCAwEAAQ==
-----END PUBLIC KEY-----
EOF
  chmod 644 "$PUBKEY"
}

register_config() {
  php <<'PHP'
<?php
require_once("/etc/inc/config.inc");
$config = parse_config(true);

$menu = array(
    'name' => 'Community Packages',
    'tooltiptext' => 'Install, upgrade and remove community and mirrored pfSense packages',
    'section' => 'System',
    'url' => '/packages/community/index.php'
);

$menus = config_get_path('installedpackages/menu', []);
$found = false;
foreach ($menus as $k => $m) {
    if (isset($m['name']) && $m['name'] == $menu['name']) {
        $menus[$k] = $menu;
        $found = true;
        break;
    }
}
if (!$found) {
    $menus[] = $menu;
}
config_set_path('installedpackages/menu', $menus);

write_config("Installed pfSense-pkg-community: registered menu");
PHP
}

unregister_config() {
  php <<'PHP'
<?php
require_once("/etc/inc/config.inc");
$config = parse_config(true);

$menus = config_get_path('installedpackages/menu', []);
$out = array();
foreach ($menus as $m) {
    if (isset($m['name']) && $m['name'] == 'Community Packages') {
        continue;
    }
    $out[] = $m;
}
config_set_path('installedpackages/menu', $out);

write_config("Removed pfSense-pkg-community: unregistered menu");
PHP
}

case "$1" in
install)
  mkdir -p /usr/local/etc/pkg/repos
  cat > "$REPO_CONF" <<'EOF'
community: {
    url: "https://tmiland-lab.github.io/pfsense-community-packages/repo",
    mirror_type: "NONE",
    signature_type: "PUBKEY",
    pubkey: "/usr/local/etc/pkg/community.pub",
    enabled: yes
}
EOF
  write_pubkey
  chmod 644 "$REPO_CONF"
  register_config
  # Bootstrap repo metadata (best effort - the GUI can refresh later).
  /usr/local/sbin/pkg-static update -r community >/dev/null 2>&1 || true
  ;;
deinstall)
  unregister_config
  ;;
*)
  echo "Usage: $0 install|deinstall"
  exit 1
  ;;
esac

exit 0
