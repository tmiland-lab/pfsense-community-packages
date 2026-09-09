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
FPR_DIR="/usr/local/etc/pkg/fingerprints/community/trusted"
# SHA256 of the repo signing key's DER-encoded public key.
FPR="d3966d287681128b34e5cdd7e83e81d2e4a326b2e3154949b6d510d8be427bd2"

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
  mkdir -p /usr/local/etc/pkg/repos "$FPR_DIR"
  cat > "$REPO_CONF" <<'EOF'
community: {
    url: "https://tmiland-lab.github.io/pfsense-community-packages/repo",
    mirror_type: "NONE",
    signature_type: "fingerprints",
    fingerprints: "/usr/local/etc/pkg/fingerprints/community",
    enabled: yes
}
EOF
  printf 'function: sha256\nfingerprint: %s\n' "$FPR" > "$FPR_DIR/community"
  chmod 644 "$FPR_DIR/community" "$REPO_CONF"
  register_config
  # Bootstrap repo metadata (best effort - the GUI can refresh later).
  /usr/sbin/pkg-static update -r community >/dev/null 2>&1 || true
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
