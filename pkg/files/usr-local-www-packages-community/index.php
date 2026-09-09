<?php
/*
 * index.php
 *
 * Community Packages - single page manager. Lists every package offered by
 * the unified community repository with its install status and contextual
 * action buttons (Install when absent, Upgrade/Delete when installed).
 * Operations run pkg-static synchronously and show its output inline.
 */
require_once('guiconfig.inc');
require_once('/usr/local/pfsense-community/share/community_lib.php');

$pgtitle = array(gettext('System'), gettext('Community Packages'));
$pglinks = array('', '@self');

/* head.inc renders the theme (CSS), page chrome and opens the body. */
include('head.inc');

$input_errors = array();
$savemsg = '';
$action_output = null;

if ($_POST) {
	if (isset($_POST['refresh'])) {
		list($rc, $out) = cpm_repo_update();
		$action_output = $out;
		$savemsg = ($rc == 0) ? gettext('Repository metadata refreshed.') : gettext('Repository refresh FAILED - see output.');
	} else {
		$action = $_POST['cpmaction'] ?? '';
		$name = $_POST['pkgname'] ?? '';
		list($ok, $out) = cpm_action($action, $name);
		$action_output = $out;
		$savemsg = $ok ?
			sprintf(gettext('Action %1$s on %2$s completed.'), $action, $name) :
			sprintf(gettext('Action %1$s on %2$s FAILED - see output.'), $action, $name);
		if (!$ok) {
			$input_errors[] = gettext('Package operation failed - see output below.');
		}
	}
}

/* display_top_tabs() takes its argument by reference - pass a variable. */
$tab_array = array(
	array(gettext('Community Packages'), true, '/packages/community/index.php'),
);
display_top_tabs($tab_array);

if ($input_errors) {
	print_input_errors($input_errors);
}
if ($savemsg) {
	print_info_box($savemsg, $input_errors ? 'alert-danger' : 'success');
}

$available = cpm_available();
$installed = cpm_installed();

$form = new Form(false);
$section = new Form_Section('Repository');
$section->addInput(new Form_StaticText(
	gettext('Status'),
	sprintf(gettext('%1$d packages offered, %2$d installed.') . ' ',
		count($available),
		count(array_intersect_key($installed, $available)))
));
$section->addInput(new Form_Button(
	'refresh',
	gettext('Refresh repository metadata'),
	null,
	'fa-solid fa-arrows-rotate'
))->setHelp(gettext('Re-downloads the repository metadata (pkg update -f -r community).'));
$form->add($section);
print $form;
?>
<div class="panel panel-default">
	<div class="panel-heading"><h2 class="panel-title"><?= gettext('Packages') ?></h2></div>
	<div class="table-responsive">
		<table class="table table-striped table-hover table-condensed">
		<thead>
			<tr>
				<th><?= gettext('Package') ?></th>
				<th><?= gettext('Description') ?></th>
				<th><?= gettext('Source') ?></th>
				<th><?= gettext('Installed') ?></th>
				<th><?= gettext('Available') ?></th>
				<th><?= gettext('Status') ?></th>
				<th><?= gettext('Actions') ?></th>
			</tr>
		</thead>
		<tbody>
<?php $lastsrc = ''; foreach ($available as $row):
	$inst = $installed[$row['name']] ?? null;
	$status = cpm_status($inst, $row['version']);
	if ($row['repo'] !== $lastsrc):
		$lastsrc = $row['repo']; ?>
				<tr><td colspan="7" style="font-weight:600;"><?= $row['repo'] == 'community' ? gettext('Community repository (ours + mirrors)') : gettext('Official repository (manageable add-ons)') ?></td></tr>
<?php endif; ?>
				<tr>
					<td><code><?= htmlspecialchars($row['name']) ?></code></td>
					<td><?= htmlspecialchars($row['comment']) ?></td>
					<td><span class="label <?= $row['repo'] == 'community' ? 'label-primary' : 'label-default' ?>"><?= $row['repo'] == 'community' ? gettext('Community') : gettext('Official') ?></span></td>
					<td><?= $inst !== null ? htmlspecialchars($inst) : '<span class="community-muted">-</span>' ?></td>
					<td><?= htmlspecialchars($row['version']) ?></td>
					<td>
<?php if ($status == 'not-installed'): ?>
						<span class="label label-default"><?= gettext('Not installed') ?></span>
<?php elseif ($status == 'up-to-date'): ?>
						<span class="label label-success"><?= gettext('Up to date') ?></span>
<?php elseif ($status == 'update'): ?>
						<span class="label label-warning"><?= gettext('Update available') ?></span>
<?php else: ?>
						<span class="label label-info"><?= gettext('Newer than repository') ?></span>
<?php endif; ?>
					</td>
					<td>
<?php if ($status == 'not-installed'): ?>
						<form method="post" class="community-inlineform">
							<input type="hidden" name="cpmaction" value="install" />
							<input type="hidden" name="pkgname" value="<?= htmlspecialchars($row['name']) ?>" />
							<button type="submit" class="btn btn-xs btn-primary"><?= gettext('Install') ?></button>
						</form>
<?php else: ?>
<?php if ($status != 'up-to-date'): ?>
						<form method="post" class="community-inlineform">
							<input type="hidden" name="cpmaction" value="upgrade" />
							<input type="hidden" name="pkgname" value="<?= htmlspecialchars($row['name']) ?>" />
							<button type="submit" class="btn btn-xs btn-warning"><?= gettext('Upgrade') ?></button>
						</form>
<?php endif; ?>
						<form method="post" class="community-inlineform">
							<input type="hidden" name="cpmaction" value="delete" />
							<input type="hidden" name="pkgname" value="<?= htmlspecialchars($row['name']) ?>" />
							<button type="submit" class="btn btn-xs btn-danger community-delete"
								onclick="return confirm('<?= gettext('Remove this package from the firewall?') ?>')">
								<?= gettext('Delete') ?></button>
						</form>
<?php endif; ?>
					</td>
				</tr>
<?php endforeach; ?>
<?php if (empty($available)): ?>
				<tr><td colspan="7"><?= gettext('Repository metadata unavailable - press Refresh repository metadata.') ?></td></tr>
<?php endif; ?>
				</tbody>
			</table>
		</div>
	</div>
</div>

<?php if ($action_output !== null): ?>
<div class="panel panel-default">
	<div class="panel-heading"><h2 class="panel-title"><?= gettext('Package operation output') ?></h2></div>
	<div class="panel-body">
		<pre class="community-output"><?= htmlspecialchars(implode("\n", (array)$action_output)) ?></pre>
	</div>
</div>
<?php endif; ?>

<script type="text/javascript">
//<![CDATA[
	/* Theme-agnostic layout helpers. */
	$('.community-inlineform').css('display', 'inline-block').css('margin-left', '4px');
	$('.community-muted').css('opacity', '0.5');
	$('.community-output').css('white-space', 'pre-wrap').css('margin', '0');
//]]>
</script>

<?php include('foot.inc'); ?>
