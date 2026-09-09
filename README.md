# pfsense-community-packages

Unified pkg(8) repository + single-page package manager for community and
mirrored pfSense packages — everything Netgate dropped from (or never put in)
the official repository, plus first-party packages, with **signed repo
metadata** and full upstream provenance.

Packages installed through this repository stay **resolvable during the
pfSense boot package resync** (`needs_package_sync`) — the stock behaviour of
removing unresolvable packages ("Package X does not exist in current pfSense
version and it has been removed") is what silently deleted RESTAPI and
DNSCrypt on firewalls after Netgate dropped them from the 2.8.x repo.

## What's in the repo

| Package | Source | License |
|---|---|---|
| pfSense-pkg-community (this manager) | first-party | MIT |
| pfSense-pkg-configbackup | [tmiland-lab](https://github.com/tmiland-lab/pfsense-configbackup) | MIT |
| pfSense-pkg-abuseipdb | [tmiland](https://github.com/tmiland/pfsense-abuseipdb) | MIT |
| pfSense-pkg-adguardhome | [tmiland](https://github.com/tmiland/pfsense-adguardhome) | MIT |
| pfSense-theme-lightdark | [tmiland-lab](https://github.com/tmiland-lab/pfsense-theme-lightdark) | MIT |
| pfSense-pkg-RESTAPI | [pfrest](https://github.com/pfrest/pfSense-pkg-RESTAPI) (mirror) | Apache-2.0 |
| pfSense-pkg-saml2-auth | [pfrest](https://github.com/pfrest/pfSense-pkg-saml2-auth) (mirror) | Apache-2.0 |
| pfSense-pkg-dnscrypt-proxy | [nopoz](https://github.com/nopoz/pfsense-dnscrypt-proxy) (mirror) | ISC |
| pfSense-pkg-WireGuard-ClientExport | [sirius0](https://github.com/sirius0/pfsense-pkg-wireguard-client-export) (mirror) | Apache-2.0 |

Live listing: <https://tmiland-lab.github.io/pfsense-community-packages/>

## Install (pfSense CLI)

```sh
cat > /usr/local/etc/pkg/repos/community.conf <<'EOF'
community: {
    url: "https://tmiland-lab.github.io/pfsense-community-packages/repo",
    mirror_type: "NONE",
    signature_type: "fingerprints",
    fingerprints: "/usr/local/etc/pkg/fingerprints/community",
    enabled: yes
}
EOF
mkdir -p /usr/local/etc/pkg/fingerprints/community/trusted
cat > /usr/local/etc/pkg/fingerprints/community/trusted/community <<'EOF'
function: sha256
fingerprint: SIGNING_KEY_FINGERPRINT
EOF
pkg update -r community
pkg install -y -r community pfSense-pkg-community
```

Installing the manager package re-installs the repo configuration and trust
anchor on every upgrade, and registers **System → Community Packages** in the
GUI. Simplest path: install the repo conf + trust anchor once, then let the
manager handle everything else.

## The manager (System → Community Packages)

One page, every package, inline status:

- **Not installed** → *Install* button
- **Up to date** → *Delete* button
- **Update available** → *Upgrade* + *Delete* buttons
- A *Refresh repository metadata* button (`pkg update -f -r community`)

Every operation runs `pkg-static` synchronously and shows its output on the
same page. CLI equivalent:

```sh
/usr/local/pfsense-community/bin/community.php list
/usr/local/pfsense-community/bin/community.php install pfSense-pkg-RESTAPI
/usr/local/pfsense-community/bin/community.php delete pfSense-pkg-dnscrypt-proxy
```

## Security / audit model

- **Signed metadata**: the repo metadata is signed (`pkg repo -s`); the
  firewall verifies the signature fingerprint
  (`signature_type: fingerprints`), same mechanism the official repos use.
  The trust anchor ships with the manager package and is printed in
  `repo/CHECKSUMS.txt` builds.
- **Mirrored packages** are pinned upstream release assets. Every mirror has
  a provenance entry in `packages/mirrors.json` (upstream URL, version,
  license, expected sha256). Builds **fail hard** on checksum mismatch.
  Where upstream publishes checksums, they are verified before recording;
  where upstream does not (`pfrest`), the recorded hash documents the
  reviewed build and is re-checked at every build.
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

## License

MIT — see [LICENSE](LICENSE). Mirrored packages keep their upstream licenses
(see table above); redistribute only what those licenses permit.
