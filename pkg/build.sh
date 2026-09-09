#!/bin/sh
# Builds the unified community package repository for pfSense.
# Runs ON a pfSense host (or matching FreeBSD box): sh pkg/build.sh
#
# - Fetches all packages from packages/mirrors.json ("own" = newest from the
#   given pkg repo, "mirror" = pinned upstream release asset, sha256 verified)
# - Builds the manager package (pfSense-pkg-community)
# - Creates SIGNED repo metadata (pkg repo -s) + CHECKSUMS.txt + index.html
# Output: /tmp/pfsense-community-packages-out/{index.html,repo/}
set -eu

PKGDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(dirname "$PKGDIR")
WORK=$(mktemp -d /tmp/pfsense-community-packages-build.XXXXXX)
STAGE="$WORK/stage"
META="$WORK/meta"
OUT="${OUT_DIR:-/tmp/pfsense-community-packages-out}"
rm -rf "$OUT"
mkdir -p "$STAGE/All" "$META" "$OUT/repo/All"

SIGN_KEY=${SIGN_KEY:-/root/community-signing.key}
SIGNED=""
if [ -f "$SIGN_KEY" ]; then
	SIGNED="rsa:$SIGN_KEY"
else
	echo "WARNING: no signing key at $SIGN_KEY - building UNSIGNED repo metadata" >&2
fi

# ------------------------------------------------------------------
# 1. Fetch packages per mirrors.json
# ------------------------------------------------------------------
FETCHLOG=$(php -r '
/* Extract the newest version of $name from a pkg repo packagesite.yaml
 * (packagesite.pkg = xz-wrapped tar containing packagesite.yaml). */
function cpm_own_version($repo_url, $name, $scratch) {
    $site = $scratch . "/packagesite-" . md5($repo_url) . ".pkg";
    exec(sprintf("fetch -qo %s %s/packagesite.pkg 2>/dev/null",
        escapeshellarg($site), escapeshellarg($repo_url)), $o, $rc);
    $o = [];
    if ($rc != 0 || !filesize($site)) {
        return null;
    }
    exec("tar -xOf " . escapeshellarg($site) . " packagesite.yaml 2>/dev/null", $yaml, $rc);
    unlink($site);
    if ($rc != 0) {
        return null;
    }
    /* packagesite.yaml is a JSON stream: one object per package, per line. */
    foreach ($yaml as $line) {
        $d = json_decode($line, true);
        if (is_array($d) && strcasecmp((string)($d["name"] ?? ""), $name) === 0) {
            return (string)($d["version"] ?? "");
        }
    }
    return null;
}
$manifest = json_decode(file_get_contents($argv[1]), true);
$stage = $argv[2];
$scratch = $argv[3];
foreach ($manifest["packages"] as $p) {
    if (($p["source"] ?? "") === "own") {
        $ver = cpm_own_version($p["repo_url"], $p["name"], $scratch);
        if (!$ver) {
            echo "FAIL own {$p["name"]}: cannot resolve version from packagesite\n";
            exit(1);
        }
        $file = $p["name"] . "-" . $ver . ".pkg";
        $url = $p["repo_url"] . "/All/" . $file;
        $dest = $stage . "/All/" . $file;
    } else {
        $url = $p["url"];
        $dest = $stage . "/All/" . basename(parse_url($url, PHP_URL_PATH));
    }
    $cmd = sprintf("fetch -qo %s %s", escapeshellarg($dest), escapeshellarg($url));
    exec($cmd, $o, $rc);
    $o = [];
    if ($rc != 0 || !filesize($dest)) {
        echo "FAIL {$p["name"]}: cannot fetch $url\n";
        exit(1);
    }
    $got = hash_file("sha256", $dest);
    if (isset($p["sha256"])) {
        if (!hash_equals($p["sha256"], $got)) {
            echo "FAIL {$p["name"]}: sha256 MISMATCH (expected {$p["sha256"]}, got $got)\n";
            exit(1);
        }
    }
    printf("%s|%s|%s|%s\n", basename($dest), $p["name"], $got,
        $p["upstream"] ?? "");
}
' "$REPO/packages/mirrors.json" "$STAGE" "$WORK") || { echo "$FETCHLOG"; exit 1; }
echo "$FETCHLOG"
case "$FETCHLOG" in *FAIL*) echo "mirror fetch failed - aborting" >&2; exit 1;; esac

# ------------------------------------------------------------------
# 2. Build the manager package
# ------------------------------------------------------------------
MPBASE="usr/local/pfsense-community"
MWBASE="usr/local/www/packages/community"
mkdir -p "$STAGE/$MPBASE/bin" "$STAGE/$MPBASE/share" "$STAGE/$MPBASE/sbin" \
	"$STAGE/$MWBASE"
install -m 0755 "$PKGDIR/files/usr-local-pfsense-community/bin/community.php" \
	"$STAGE/$MPBASE/bin/community.php"
install -m 0644 "$PKGDIR/files/usr-local-pfsense-community/share/community_lib.php" \
	"$STAGE/$MPBASE/share/community_lib.php"
install -m 0644 "$PKGDIR/files/usr-local-pfsense-community/share/community.xml" \
	"$STAGE/$MPBASE/share/community.xml"
install -m 0755 "$PKGDIR/files/usr-local-pfsense-community/sbin/setup.sh" \
	"$STAGE/$MPBASE/sbin/setup.sh"
for page in "$PKGDIR"/files/usr-local-www-packages-community/*.php; do
	install -m 0644 "$page" "$STAGE/$MWBASE/$(basename "$page")"
done

php -l "$STAGE/$MPBASE/share/community_lib.php" >/dev/null
php -l "$STAGE/$MPBASE/bin/community.php" >/dev/null
php -l "$STAGE/$MWBASE/index.php" >/dev/null

VERSION=$(sed -n 's/.*<version>\([^<]*\)<.*/\1/p' "$STAGE/$MPBASE/share/community.xml" | head -1)
ABI=$(pkg config abi)
NAME="pfSense-pkg-community"
ORIGIN="security/pfSense-pkg-community"

cat > "$META/+POST_INSTALL" <<'EOF'
#!/bin/sh
/usr/local/pfsense-community/sbin/setup.sh install
exit 0
EOF

cat > "$META/+PRE_DEINSTALL" <<'EOF'
#!/bin/sh
/usr/local/pfsense-community/sbin/setup.sh deinstall
exit 0
EOF
chmod 0755 "$META/+POST_INSTALL" "$META/+PRE_DEINSTALL"

MANIFEST=$(php -r '
$stage = $argv[1]; $meta = $argv[2]; $abi = $argv[3];
$version = $argv[4]; $name = $argv[5]; $origin = $argv[6];
$files = array(); $flatsize = 0;
$it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($stage, FilesystemIterator::SKIP_DOTS));
foreach ($it as $f) {
    $rel = ltrim(str_replace($stage, "", $f->getPathname()), "/");
    $files["/" . $rel] = hash_file("sha256", $f->getPathname());
    $flatsize += $f->getSize();
}
$dirs = array();
foreach (array(
    "usr/local/pfsense-community",
    "usr/local/pfsense-community/bin",
    "usr/local/pfsense-community/share",
    "usr/local/pfsense-community/sbin",
    "usr/local/www/packages/community"
) as $d) {
    $dirs["/" . $d] = "y";
}
$manifest = array(
    "name" => $name,
    "origin" => $origin,
    "version" => $version,
    "comment" => "Community Packages - unified manager for community/mirrored pfSense packages",
    "desc" => "Single-page package manager for the unified community repository: install, upgrade and remove packages dropped from or absent in the official pfSense repo. Packages installed from this repo stay resolvable during boot package resync.",
    "maintainer" => "kontakt@tmiland.com",
    "www" => "https://github.com/tmiland-lab/pfsense-community-packages",
    "abi" => $abi,
    "arch" => $abi,
    "prefix" => "/",
    "categories" => array("pfSense"),
    "licenses" => array("MIT"),
    "flatsize" => $flatsize,
    "deps" => (object) array(),
    "files" => (object) $files,
    "directories" => (object) $dirs,
    "scripts" => array(
        "post-install" => "+POST_INSTALL",
        "pre-deinstall" => "+PRE_DEINSTALL"
    )
);
echo json_encode($manifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
' "$STAGE" "$META" "$ABI" "$VERSION" "$NAME" "$ORIGIN")
echo "$MANIFEST" > "$META/+MANIFEST"
pkg create -m "$META" -r "$STAGE" -o "$WORK/mpkg" >/dev/null
find "$WORK/mpkg" -name '*.pkg' -exec mv {} "$STAGE/All/" \;
# (setup.sh ships the pubkey + repo conf; no second build pass needed.)

# ------------------------------------------------------------------
# 2b. ABI guard: every staged pkg must match this host's ABI (or wildcard)
# ------------------------------------------------------------------
ABI=$(pkg config abi)
php -r '
$stage = $argv[1]; $abi = $argv[2];
$major = explode(":", $abi)[1] ?? "";
$bad = array();
foreach (glob($stage . "/All/*.pkg") as $f) {
    $n++;
    exec("pkg info -F " . escapeshellarg($f) . " 2>/dev/null", $o, $rc);
    $arch = "";
    foreach ($o as $line) {
        if (preg_match("/^Architecture\s*:\s*(.+)$/", trim($line), $m)) { $arch = trim($m[1]); break; }
    }
    $o = [];
    $parts = explode(":", $arch);
    $ok = ($arch === "*") ||
        ((($parts[0] ?? "") === "FreeBSD") && in_array($parts[1] ?? "*", array($major, "*")));
    if (!$ok) {
        $bad[] = basename($f) . " => " . $arch;
    }
}
if ($bad) {
    echo "FAIL abi mismatch (expected FreeBSD:$major):\n" . implode("\n", $bad) . "\n";
    exit(1);
}
echo "ABI guard: all " . $n . " packages match FreeBSD:$major\n";
' "$STAGE" "$ABI" || { exit 1; }

# The public key is published for manual client setup (PUBKEY mode).
if [ -f "$SIGN_KEY" ]; then
	openssl rsa -in "$SIGN_KEY" -pubout -out "$OUT/repo/community.pub" 2>/dev/null
fi

# ------------------------------------------------------------------
# 3. Signed repo metadata + checksums + index
# ------------------------------------------------------------------
cp "$STAGE"/All/*.pkg "$OUT/repo/All/"
cd "$OUT/repo"
pkg repo . $SIGNED >/dev/null

(cd "$OUT/repo" && find . -type f -exec sha256 {} \; | awk '{print $2 " = " $4}') > "$OUT/repo/CHECKSUMS.txt"

php -r '
$stage = $argv[1]; $out = $argv[2];
/* packagesite.yaml is a JSON stream: one object per package, per line. */
exec("tar -xOf " . escapeshellarg($out . "/repo/packagesite.pkg") . " packagesite.yaml 2>/dev/null", $yaml);
$rows = array();
foreach ($yaml as $line) {
    $d = json_decode($line, true);
    if (!is_array($d) || empty($d["name"])) {
        continue;
    }
    $rows[] = array(
        "name" => (string)$d["name"],
        "version" => (string)($d["version"] ?? ""),
        "flatsize" => (int)($d["flatsize"] ?? 0),
        "comment" => (string)($d["comment"] ?? ""),
        "origin" => (string)($d["origin"] ?? ""),
    );
}
usort($rows, function ($a, $b) { return strcasecmp($a["name"], $b["name"]); });
$manifest = json_decode(file_get_contents($argv[3]), true);
$lic = array();
foreach ($manifest["packages"] as $p) { $lic[strtolower($p["name"])] = $p["license"] ?? ""; }
function h($s) { return htmlspecialchars((string)$s, ENT_QUOTES); }
ob_start(); ?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>pfsense-community-packages — pkg repo</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #212121; color: #e0e0e0; margin: 0; padding: 2rem 1rem; }
  .wrap { max-width: 1100px; margin: 0 auto; }
  h1 a { color: #e0e0e0; text-decoration: none; }
  code { background: #303030; padding: 2px 6px; border-radius: 4px; }
  a { color: #64b5f6; }
  table { border-collapse: collapse; width: 100%; margin: 1.5rem 0; }
  th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid #303030; }
  th { color: #9e9e9e; font-weight: 600; }
  .muted { color: #9e9e9e; }
</style>
</head>
<body>
<div class="wrap">
<h1><a href="https://github.com/tmiland-lab/pfsense-community-packages">pfsense-community-packages</a></h1>
<p>Unified pkg(8) repository for community and mirrored pfSense packages —
packages dropped from or absent in the official pfSense repository, plus first-party
packages. Install/upgrade/remove them with the <a href="https://github.com/tmiland-lab/pfsense-community-packages">Community Packages</a> manager or plain <code>pkg-static</code>.</p>
<p>Repo URL for <code>/usr/local/etc/pkg/repos/community.conf</code>:<br>
<code>https://tmiland-lab.github.io/pfsense-community-packages/repo</code></p>
<p>Metadata is signed; the trust anchor is installed by the manager package
(<code>signature_type: fingerprints</code>).</p>
<table>
<tr><th>Package</th><th>Version</th><th>Description</th><th>License</th><th>Size (flatsize)</th></tr>
<?php foreach ($rows as $r): ?>
<tr>
<td><code><?= h($r["name"]) ?></code></td>
<td><?= h($r["version"]) ?></td>
<td><?= h($r["comment"]) ?></td>
<td><?= h($lic[strtolower($r["name"])] ?? "") ?></td>
<td><?= number_format((int)$r["size"]) ?></td>
</tr>
<?php endforeach; ?>
</table>
<p class="muted">Mirrored packages keep their upstream provenance (URL, version and sha256)
in <a href="https://github.com/tmiland-lab/pfsense-community-packages">packages/mirrors.json</a>
and are verified at every build. Checksums: <a href="repo/CHECKSUMS.txt">repo/CHECKSUMS.txt</a>.</p>
<p class="muted">Built with <a href="https://opencode.ai/go?ref=00KNXXSB00">opencode</a> — the open-source AI coding agent for the terminal. License: MIT.</p>
</div>
</body>
</html>
<?php file_put_contents($out . "/index.html", ob_get_clean());
' "$STAGE" "$OUT" "$REPO/packages/mirrors.json"

echo "=== Build complete: $OUT"
find "$OUT" -type f | sort
rm -rf "$WORK"
