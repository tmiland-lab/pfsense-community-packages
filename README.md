# pfsense-community-packages

[![Mirror + build repo](https://github.com/tmiland-lab/pfsense-community-packages/actions/workflows/mirror.yml/badge.svg)](https://github.com/tmiland-lab/pfsense-community-packages/actions/workflows/mirror.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![pfSense](https://img.shields.io/badge/pfSense-2.8.x-%23214783)](https://www.pfsense.org)
[![Repo](https://img.shields.io/badge/pkg%20repo-gh--pages-8A2BE2)](https://tmiland-lab.github.io/pfsense-community-packages/)

Unified pkg(8) repository + single-page package manager for community and
mirrored pfSense packages — everything Netgate dropped from (or never put in)
the official repository, plus first-party packages, with **signed repo
metadata** and full upstream provenance.

Packages installed through this repository stay **resolvable during the
pfSense boot package resync** (`needs_package_sync`) — the stock behaviour of
removing unresolvable packages ("Package X does not exist in current pfSense
version and it has been removed") is what silently deleted RESTAPI and
DNSCrypt on firewalls after Netgate dropped them from the 2.8.x repo.

![Community Packages manager](docs/screenshots/community-packages.png)

## What's in the repo

| Package | Source | License |
|---|---|---|
| pfSense-pkg-community (this manager) | first-party | MIT |
| pfSense-pkg-configbackup | [tmiland-lab](https://github.com/tmiland-lab/pfsense-configbackup) | MIT |
| pfSense-pkg-abuseipdb | [tmiland](https://github.com/tmiland/pfsense-abuseipdb) | MIT |
| pfSense-pkg-adguardhome | [tmiland](https://github.com/tmiland/pfsense-adguardhome) | MIT |
| pfSense-pkg-airvpn-remotes | [tmiland-lab](https://github.com/tmiland-lab/pfsense-airvpn-remotes) | MIT |
| pfSense-pkg-vpn-providers | [tmiland-lab](https://github.com/tmiland-lab/pfsense-vpn-providers) | MIT |
| pfSense-theme-lightdark | [tmiland-lab](https://github.com/tmiland-lab/pfsense-theme-lightdark) | MIT |
| pfSense-pkg-ovpn-totp | [tmiland-lab](https://github.com/tmiland-lab/pfsense-ovpn-totp) | MIT |
| pfSense-pkg-RESTAPI | [pfrest](https://github.com/pfrest/pfSense-pkg-RESTAPI) (mirror) | Apache-2.0 |
| pfSense-pkg-saml2-auth | [pfrest](https://github.com/pfrest/pfSense-pkg-saml2-auth) (mirror) | Apache-2.0 |
| pfSense-pkg-dnscrypt-proxy | [nopoz](https://github.com/nopoz/pfsense-dnscrypt-proxy) (mirror) | ISC |
| pfSense-pkg-wgeasy | [MarceloMayo74](https://github.com/MarceloMayo74/pfsense-wgeasy) (mirror) | Apache-2.0 |
| pfSense-pkg-wg-export | [3um3le3ee](https://github.com/3um3le3ee/pfSense-wireguard-peer-export) (mirror) | GPL-3.0 |
| pfSense-pkg-Mullvad | [mmahrous](https://github.com/mmahrous/pfSense-pkg-Mullvad) (mirror) | Apache-2.0 |

Live listing: <https://tmiland-lab.github.io/pfsense-community-packages/>

## Install (pfSense CLI)

```sh
cat > /usr/local/etc/pkg/repos/community.conf <<'EOF'
community: {
    url: "https://tmiland-lab.github.io/pfsense-community-packages/repo",
    mirror_type: "NONE",
    signature_type: "PUBKEY",
    pubkey: "/usr/local/etc/pkg/community.pub",
    enabled: yes
}
EOF
fetch -o /usr/local/etc/pkg/community.pub \
  https://tmiland-lab.github.io/pfsense-community-packages/community.pub
pkg update -r community
pkg install -y -r community pfSense-pkg-community
```

Installing the manager package re-installs the repo configuration and trust
anchor on every upgrade, and registers **System → Community Packages** in the
GUI. Simplest path: install the repo conf + pubkey once, then let the manager
handle everything else.

## The manager (System → Community Packages)

One page, every package, inline status:

- **Not installed** → *Install* button
- **Up to date** → *Delete* button
- **Update available** → *Upgrade* + *Delete* buttons
- A *Refresh repository metadata* button (`pkg update -f -r community`)
- The official repository's add-on packages are listed and managed on the
  same page (core system files are excluded and left to pfSense upgrades)
- Package names link to their upstream project repositories (curated
  URLs from `packages/mirrors.json` for community packages; the package's
  declared home page for official ones)
- Versions are shown as monospace chips — installed and available side by
  side, with the available version highlighted when an update exists
- **View: Grouped / Flat** — group the list by source repository
  (community first, then official) or switch to a plain alphabetical
  listing; the preference is kept across package actions

Every operation runs `pkg-static` synchronously and shows its output on the
same page. CLI equivalent:

```sh
/usr/local/pfsense-community/bin/community.php list
/usr/local/pfsense-community/bin/community.php install pfSense-pkg-RESTAPI
/usr/local/pfsense-community/bin/community.php delete pfSense-pkg-dnscrypt-proxy
```

## Security / audit model

- **Signed metadata**: the repo metadata is signed (`pkg repo . rsa:`); the
  firewall verifies the embedded signature against the published public key
  (`signature_type: PUBKEY`), same mechanism the official repos use.
- **Mirrored packages** are pinned upstream release assets. Every mirror has
  a provenance entry in `packages/mirrors.json` (upstream URL, version,
  license, expected sha256). Builds **fail hard** on checksum mismatch.
  Where upstream publishes checksums, they are verified before recording;
  where upstream does not (`pfrest`), the recorded hash documents the
  reviewed build and is re-checked at every build.
- **ABI guard**: every staged package is checked against the target ABI at
  build time; mismatches fail the build (see `_excluded` in `mirrors.json`).
  Packages built on a *newer* FreeBSD userland than the target (poudriere's
  `FreeBSD_version` annotation) also fail the build — pkg would otherwise
  reject the whole repository on the firewall.
- **First-party packages** resolve to the newest build from their own
  repository at build time.
- Mirrors are refreshed weekly by
  [.github/workflows/mirror.yml](.github/workflows/mirror.yml) (FreeBSD VM
  runner) or manually: `sh pkg/build.sh` on a pfSense host.

## Resync survival

pfSense's boot package resync reinstalls every package listed in
`installedpackages` and **removes** those it cannot resolve from any enabled
repository. Because this repository is enabled on the firewall and keeps
mirrors of the dropped packages resolvable, community packages survive
resyncs instead of being uninstalled.

## Adding a package

Add an entry to `packages/mirrors.json` — either `own` (a pkg repository to
resolve the newest version from) or `mirror` (a pinned upstream release asset
+ sha256). Rebuild. Only redistribute what the upstream license permits.

## Uninstall

```sh
pkg remove -y pfSense-pkg-community
```

The menu entry is removed, but the **repo configuration is intentionally
kept** so already-installed community packages stay resolvable at boot.
Remove `/usr/local/etc/pkg/repos/community.conf` manually only if you accept
that installed community packages will be dropped at the next boot resync.

## Support

If you find this useful, consider
[sponsoring](https://github.com/sponsors/tmiland) or
[tipping](https://coindrop.to/tmiland) — it keeps the mirrors fresh.

---

Built with [opencode](https://opencode.ai/go?ref=00KNXXSB00) — the open-source
AI coding agent for the terminal. Grab your own at
[opencode.ai/go](https://opencode.ai/go?ref=00KNXXSB00).

## License

MIT — see [LICENSE](LICENSE). Mirrored packages keep their upstream licenses
(see table above); redistribute only what those licenses permit.
