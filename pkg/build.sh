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
        $path = parse_url($url, PHP_URL_PATH);
        if (substr($path, -4) === ".tar") {
            /* Release tar asset: fetch once per URL, verify the tar
             * sha256, extract the named member pkg into the stage.
             * Several entries may share one tar (e.g. the crowdsec
             * release bundles agent + bouncer + wrapper). */
            $member = basename($p["member"] ?? "");
            if ($member === "" || $member !== ($p["member"] ?? "")) {
                echo "FAIL {$p["name"]}: tar asset requires a member file name\n";
                exit(1);
            }
            $tarfile = $scratch . "/asset-" . md5($url) . ".tar";
            if (!is_file($tarfile)) {
                exec(sprintf("fetch -qo %s %s", escapeshellarg($tarfile),
                    escapeshellarg($url)), $o, $rc);
                $o = [];
                if ($rc != 0 || !filesize($tarfile)) {
                    echo "FAIL {$p["name"]}: cannot fetch $url\n";
                    exit(1);
                }
            }
            $got = hash_file("sha256", $tarfile);
            if (isset($p["sha256"])) {
                if (!hash_equals($p["sha256"], $got)) {
                    echo "FAIL {$p["name"]}: sha256 MISMATCH (expected {$p["sha256"]}, got $got)\n";
                    exit(1);
                }
            }
            $dest = $stage . "/All/" . $member;
            exec(sprintf("tar -xf %s -C %s %s", escapeshellarg($tarfile),
                escapeshellarg($stage . "/All"), escapeshellarg($member)), $o, $rc);
            $o = [];
            if ($rc != 0 || !filesize($dest)) {
                echo "FAIL {$p["name"]}: cannot extract $member from $url\n";
                exit(1);
            }
            printf("%s|%s|%s|%s\n", basename($dest), $p["name"], $got,
                $p["upstream"] ?? "");
            continue;
        }
        $base = basename($path);
        if (substr($base, -4) === ".txz") {
            /* pkg repo + the staging copy only handle .pkg-named files;
             * the content is identical, just the name differs. */
            $base = substr($base, 0, -4) . ".pkg";
        }
        $dest = $stage . "/All/" . $base;
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
# The manager gets its own staging root: $STAGE/All holds the fetched
# repository packages, and the manifest walk below must not see them.
MSTAGE="$WORK/mstage"
MPBASE="usr/local/pfsense-community"
MWBASE="usr/local/www/packages/community"
mkdir -p "$MSTAGE/$MPBASE/bin" "$MSTAGE/$MPBASE/share" "$MSTAGE/$MPBASE/sbin" \
	"$MSTAGE/$MWBASE"
install -m 0755 "$PKGDIR/files/usr-local-pfsense-community/bin/community.php" \
	"$MSTAGE/$MPBASE/bin/community.php"
install -m 0644 "$PKGDIR/files/usr-local-pfsense-community/share/community_lib.php" \
	"$MSTAGE/$MPBASE/share/community_lib.php"
install -m 0644 "$PKGDIR/files/usr-local-pfsense-community/share/community.xml" \
	"$MSTAGE/$MPBASE/share/community.xml"
install -m 0755 "$PKGDIR/files/usr-local-pfsense-community/sbin/setup.sh" \
	"$MSTAGE/$MPBASE/sbin/setup.sh"
for page in "$PKGDIR"/files/usr-local-www-packages-community/*.php; do
	install -m 0644 "$page" "$MSTAGE/$MWBASE/$(basename "$page")"
done

# Ship the curated package -> upstream-project URL map (rendered links
# on the manager page; pkg %w values are unreliable for mirrors).
php -r '
$manifest = json_decode(file_get_contents($argv[1]), true);
$links = array();
foreach (($manifest["packages"] ?? array()) as $p) {
	if (!empty($p["name"]) && !empty($p["upstream"])) {
		$links[strtolower($p["name"])] = $p["upstream"];
	}
}
$links["pfsense-pkg-community"] = "https://github.com/tmiland-lab/pfsense-community-packages";
file_put_contents($argv[2], json_encode($links, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
' "$REPO/packages/mirrors.json" "$MSTAGE/$MPBASE/share/community_repos.json"

php -l "$MSTAGE/$MPBASE/share/community_lib.php" >/dev/null
php -l "$MSTAGE/$MPBASE/bin/community.php" >/dev/null
php -l "$MSTAGE/$MWBASE/index.php" >/dev/null

VERSION=$(sed -n 's/.*<version>\([^<]*\)<.*/\1/p' "$MSTAGE/$MPBASE/share/community.xml" | head -1)
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
' "$MSTAGE" "$META" "$ABI" "$VERSION" "$NAME" "$ORIGIN")
echo "$MANIFEST" > "$META/+MANIFEST"
pkg create -m "$META" -r "$MSTAGE" -o "$WORK/mpkg" >/dev/null
find "$WORK/mpkg" -name '*.pkg' -exec mv {} "$STAGE/All/" \;
# (setup.sh ships the pubkey + repo conf; no second build pass needed.)

# ------------------------------------------------------------------
# 2b. ABI + osversion guard: every staged pkg must match this host's ABI
# (or wildcard) AND not be built on a newer FreeBSD userland than the
# target (pkg is_valid_os_version() rejects the whole repo otherwise).
# ------------------------------------------------------------------
ABI=$(pkg config abi)
# pfSense 2.8.1 CE userland. Bump when the repo targets a newer pfSense.
TARGET_OSVERSION=${TARGET_OSVERSION:-1500029}
php -r '
$stage = $argv[1]; $abi = $argv[2]; $osver = (int)$argv[3];
$major = explode(":", $abi)[1] ?? "";
$bad = array();
foreach (array_merge(glob($stage . "/All/*.pkg"), glob($stage . "/All/*.txz")) as $f) {
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
    /* poudriere stamps FreeBSD_version; newer-than-target userland gets
     * the whole repository rejected by pkg on the firewall. */
    $mo = array();
    exec("tar -xOf " . escapeshellarg($f) . " +MANIFEST 2>/dev/null", $mo, $mrc);
    if ($mrc == 0) {
        $man = json_decode(implode("", $mo), true);
        $pv = (int)($man["annotations"]["FreeBSD_version"] ?? 0);
        if ($pv > $osver) {
            $ok = false;
            $bad[] = basename($f) . " => FreeBSD_version " . $pv . " is newer than target " . $osver;
        }
    }
    $mo = array();
}
if ($bad) {
    echo "FAIL abi/osversion mismatch (expected FreeBSD:$major, osversion <= $osver):\n" . implode("\n", $bad) . "\n";
    exit(1);
}
echo "ABI guard: all " . $n . " packages match FreeBSD:$major, osversion <= $osver\n";
' "$STAGE" "$ABI" "$TARGET_OSVERSION" || { exit 1; }

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
$links = array();
foreach ($manifest["packages"] as $p) {
	$lic[strtolower($p["name"])] = $p["license"] ?? "";
	if (!empty($p["upstream"])) {
		$links[strtolower($p["name"])] = $p["upstream"];
	}
}
$links["pfsense-pkg-community"] = "https://github.com/tmiland-lab/pfsense-community-packages";
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
  .ver { font-family: SFMono-Regular, Consolas, "Liberation Mono", Menlo, monospace; display: inline-block; padding: 1px 7px; border-radius: 4px; border: 1px solid #414141; background: #303030; font-size: 0.92em; }
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
<?php $u = $links[strtolower($r["name"])] ?? ""; ?>
<tr>
<td><code><?php if ($u): ?><a href="<?= h($u) ?>"><?= h($r["name"]) ?></a><?php else: ?><?= h($r["name"]) ?><?php endif; ?></code></td>
<td><span class="ver"><?= h($r["version"]) ?></span></td>
<td><?= h($r["comment"]) ?></td>
<td><?= h($lic[strtolower($r["name"])] ?? "") ?></td>
<td><?= number_format((int)$r["flatsize"]) ?></td>
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
