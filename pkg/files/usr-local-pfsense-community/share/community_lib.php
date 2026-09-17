<?php
/*
 * community_lib.php
 *
 * Shared library for the pfSense-pkg-community package manager. Wraps
 * pkg(8) operations against the unified community repository and provides
 * the available/installed state for the one-page GUI.
 */

if (!function_exists('config_get_path')) {
	require_once('config.inc');
}

if (!defined('CPM_REPO')) {
	define('CPM_REPO', 'community');
	define('CPM_BASE', '/usr/local/pfsense-community');
	define('CPM_PKG', '/usr/local/sbin/pkg-static');
	define('CPM_LINKS', CPM_BASE . '/share/community_repos.json');
}

/* All packages offered by the unified community repository, plus the
 * official repository's manageable packages (pfSense-pkg-*, the status
 * monitoring add-on) - everything else in the official repo is core
 * system material and is excluded. Each row carries its source repo and
 * the package's declared home page (pkg %w). */
function cpm_available() {
	$rows = array();
	$out = array();
	exec(CPM_PKG . ' rquery -r ' . CPM_REPO . ' \'%n|%v|%c|%o|%w\' 2>/dev/null', $out, $rc);
	if ($rc != 0 || empty($out)) {
		cpm_repo_update(true);
		$out = array();
		exec(CPM_PKG . ' rquery -r ' . CPM_REPO . ' \'%n|%v|%c|%o|%w\' 2>/dev/null', $out, $rc);
	}
	foreach ($out as $line) {
		$f = explode('|', $line);
		if (count($f) < 5) {
			continue;
		}
		$rows[$f[0]] = array(
			'name' => $f[0],
			'version' => $f[1],
			'comment' => $f[2],
			'origin' => $f[3],
			'www' => $f[4],
			'repo' => CPM_REPO,
		);
	}
	/* Official repo packages (core files excluded - see cpm_manageable()). */
	$out = array();
	exec(CPM_PKG . ' rquery -r pfSense \'%n|%v|%c|%o|%w\' 2>/dev/null', $out);
	foreach ($out as $line) {
		$f = explode('|', $line);
		if (count($f) < 5 || !cpm_manageable($f[0])) {
			continue;
		}
		if (!isset($rows[$f[0]])) {
			$rows[$f[0]] = array(
				'name' => $f[0],
				'version' => $f[1],
				'comment' => $f[2],
				'origin' => $f[3],
				'www' => $f[4],
				'repo' => 'pfSense',
			);
		}
	}
	ksort($rows, SORT_STRING);
	return $rows;
}

/* Only actual add-on packages are manageable: pfSense-pkg-* and the status
 * monitoring add-on. Everything else (base, kernel, boot, config, deps...)
 * is core system material and must be managed by pfSense upgrades. */
function cpm_manageable($name) {
	return (stripos($name, 'pfSense-pkg-') === 0 ||
		stripos($name, 'pfSense-Status_Monitoring') === 0);
}

/* Curated package -> upstream-project URLs, shipped in
 * share/community_repos.json (generated from packages/mirrors.json at
 * build time). Returns name (lowercased) => url. */
function cpm_repo_links() {
	static $links = null;
	if ($links === null) {
		$links = array();
		if (is_file(CPM_LINKS)) {
			$decoded = json_decode((string)@file_get_contents(CPM_LINKS), true);
			if (is_array($decoded)) {
				foreach ($decoded as $name => $url) {
					if (is_string($name) && is_string($url) && $url !== '') {
						$links[strtolower($name)] = $url;
					}
				}
			}
		}
	}
	return $links;
}

/* Upstream project URL for one available row (or plain name), or null.
 * The curated map wins: several mirrored packages declare garbage www
 * values ("UNKNOWN", template placeholders, the upstream application
 * instead of the pfSense package repo). */
function cpm_repo_link($row) {
	$name = is_array($row) ? (string)($row['name'] ?? '') : (string)$row;
	if ($name === '') {
		return null;
	}
	$links = cpm_repo_links();
	if (isset($links[strtolower($name)])) {
		return $links[strtolower($name)];
	}
	$www = is_array($row) ? trim((string)($row['www'] ?? '')) : '';
	if (!(stripos($www, 'http://') === 0 || stripos($www, 'https://') === 0)) {
		return null;
	}
	if (stripos($www, 'unknown') !== false || stripos($www, 'your_username') !== false) {
		return null;
	}
	return $www;
}

/* Installed package versions (name => version). */
function cpm_installed() {
	$out = array();
	exec(CPM_PKG . ' query \'%n|%v\' 2>/dev/null', $out);
	$map = array();
	foreach ($out as $line) {
		$f = explode('|', $line);
		if (count($f) != 2) {
			continue;
		}
		$map[$f[0]] = $f[1];
	}
	return $map;
}

function cpm_repo_update($quiet = false) {
	$out = array();
	$rc = 1;
	exec(CPM_PKG . ' update -f -r ' . CPM_REPO . ' 2>&1', $out, $rc);
	if (!$quiet) {
		return array($rc, $out);
	}
	return $rc;
}

/* pkg enforces vital at execute time, not while solving: `pkg delete -n`
 * prints an ordinary removal plan and exits 0 either way. */
function cpm_is_vital($name) {
	$out = array();
	$rc = 1;
	exec(CPM_PKG . ' query \'%V\' ' . escapeshellarg($name) . ' 2>/dev/null', $out, $rc);
	return $rc === 0 && trim((string) reset($out)) === '1';
}

/* Factory Defaults (pkg_delete_all) and "Reinstall all packages"
 * (pkg_reinstall_all) both iterate `pkg query -e '%a == 0'` and abort the
 * whole run on the first failure. Automatic keeps this package out of both
 * loops; vital then stops `pkg autoremove` collecting what automatic
 * exposed. Neither flag is safe alone. */
function cpm_set_flags($name) {
	$out = array();
	$rc = 1;
	exec(CPM_PKG . ' set -y -A 1 -v 1 ' . escapeshellarg($name) . ' 2>&1', $out, $rc);
	return array($rc === 0, $out);
}

/* Run a repo operation. Only whitelisted actions, only manageable package
 * names that exist in a known repository. Returns array(ok, output-lines). */
function cpm_action($action, $name) {
	$name = preg_replace('/[^A-Za-z0-9._+-]/', '', (string)$name);
	if (!cpm_manageable($name)) {
		return array(false, array("Package {$name} is core system material and cannot be managed here."));
	}
	$avail = cpm_available();
	if (!isset($avail[$name])) {
		return array(false, array("Package {$name} is not offered by any known repository."));
	}
	$repo = $avail[$name]['repo'];
	switch ($action) {
		case 'install':
		case 'upgrade':
			$cmd = CPM_PKG . ' install -y -r ' . escapeshellarg($repo) . ' ' . escapeshellarg($name);
			break;
		case 'delete':
			/* Only our own vital packages: a blanket -f would skip the
			 * dependency checks as well. */
			$force = ($repo === CPM_REPO && cpm_is_vital($name)) ? '-f ' : '';
			$cmd = CPM_PKG . ' delete -y ' . $force . escapeshellarg($name);
			break;
		default:
			return array(false, array('Unknown action.'));
	}

	/* Sends a concurrent get_pkg_info() down its local-only -U path instead
	 * of racing this transaction for pkg's database lock. */
	if (!function_exists('is_subsystem_dirty')) {
		require_once('util.inc');
	}
	$locked = !is_subsystem_dirty('pkg');
	if ($locked) {
		mark_subsystem_dirty('pkg');
	}
	$out = array();
	$rc = 1;
	exec($cmd . ' 2>&1', $out, $rc);
	/* Flagging an official package vital would break pfSense's own Remove
	 * button, which deletes without -f. */
	if ($rc == 0 && $action !== 'delete' && $repo === CPM_REPO) {
		list($flagged, $flagout) = cpm_set_flags($name);
		if (!$flagged) {
			$out[] = "WARNING: {$name} is installed, but setting its automatic/vital flags failed.";
			$out = array_merge($out, $flagout);
		}
	}
	if ($locked) {
		clear_subsystem_dirty('pkg');
	}
	return array($rc == 0, $out);
}

/* Status of one package: not-installed | up-to-date | update | downgrade. */
function cpm_status($installed, $available) {
	if ($installed === null) {
		return 'not-installed';
	}
	if ((string)$installed === (string)$available) {
		return 'up-to-date';
	}
	/* version_compare understands 0.1.6 and 2.7_5 style well enough here. */
	return version_compare((string)$available, (string)$installed, '>') ? 'update' : 'downgrade';
}
