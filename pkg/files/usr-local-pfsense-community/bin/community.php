#!/usr/local/bin/php -f
<?php
/*
 * community.php
 *
 * CLI for the unified community package repository. The GUI page uses the
 * same library (community_lib.php).
 *
 * Usage: community.php <command> [package]
 *   list                   list repository packages with installed status
 *   update                 force-refresh repository metadata
 *   install <package>      install/upgrade a package from the repo
 *   delete <package>       remove an installed package
 *   status                 repository + manager summary
 */

require_once('config.inc');
require_once('/usr/local/pfsense-community/share/community_lib.php');

function c_out($s) {
	echo $s . "\n";
}

$cmd = isset($argv[1]) ? $argv[1] : '';
$arg = isset($argv[2]) ? $argv[2] : '';

switch ($cmd) {
	case 'list':
		$installed = cpm_installed();
		foreach (cpm_available() as $row) {
			$inst = $installed[$row['name']] ?? null;
			c_out(sprintf('%-45s %-12s %-12s %s',
				$row['name'], $inst ?? '-', $row['version'],
				cpm_status($inst, $row['version'])));
		}
		break;

	case 'update':
		list($rc, $out) = cpm_repo_update();
		c_out(implode("\n", $out));
		exit($rc == 0 ? 0 : 1);
		break;

	case 'install':
	case 'upgrade':
	case 'delete':
		if ($arg === '') {
			c_out("Usage: community.php {$cmd} <package>");
			exit(1);
		}
		list($ok, $out) = cpm_action($cmd, $arg);
		c_out(implode("\n", $out));
		exit($ok ? 0 : 1);
		break;

	case 'status':
		$installed = cpm_installed();
		$avail = cpm_available();
		$n = 0;
		foreach ($avail as $row) {
			$st = cpm_status($installed[$row['name']] ?? null, $row['version']);
			if ($st !== 'not-installed') {
				$n++;
			}
		}
		c_out('Repository packages: ' . count($avail));
		c_out('Installed from/managed: ' . $n);
		break;

	default:
		c_out('Usage: community.php <list|update|install|upgrade|delete|status> [package]');
		exit(1);
}
