#!/bin/sh
# Builds one package from a pinned upstream port: for upstreams that ship
# neither release assets nor a pkg repository, only a FreeBSD-ports style
# source tree (the layout pfsense/FreeBSD-ports uses).
#
# Called by build.sh for mirrors.json entries with "source": "port".
# The staging and manifest steps follow the port's own install.sh: the file
# list comes from the port's pkg-plist, version/comment/maintainer/license
# from its Makefile, and the description from its pkg-descr - unchanged.
#
# Usage: build-port.sh <source-tarball-url> <tarball-sha256> <port-path>
#                      <stage All dir> <scratch dir> <upstream-url>
# stdout: one "PKG=<file name>" line for the built package.
# stderr: progress and, on failure, "FAIL port <name>: why" and a non-zero exit.
set -eu
umask 022

URL=$1
SHA=$2
PORT_PATH=$3
ALLDIR=$4
SCRATCH=$5
UPSTREAM=$6

NAME=$(basename "$PORT_PATH")
die() {
	echo "FAIL port ${NAME}: $*" >&2
	exit 1
}

WORK="$SCRATCH/port-build-${NAME}"
rm -rf "$WORK"
mkdir -p "$WORK/src" "$WORK/out"
trap 'rm -rf "$WORK"' EXIT

TARBALL="$WORK/source.tar.gz"
fetch -qo "$TARBALL" "$URL" || die "cannot fetch $URL"
GOT=$(sha256 -q "$TARBALL")
[ "$GOT" = "$SHA" ] || die "sha256 MISMATCH (expected $SHA, got $GOT)"
tar -xzf "$TARBALL" -C "$WORK/src" --strip-components=1

PORT="$WORK/src/$PORT_PATH"
[ -f "$PORT/Makefile" ] || die "$PORT_PATH/Makefile not found in the tarball"
[ -f "$PORT/pkg-plist" ] || die "$PORT_PATH/pkg-plist not found in the tarball"

field() {
	sed -n "s/^$1=[[:space:]]*//p" "$PORT/Makefile" | head -1
}

VERSION=$(field PORTVERSION)
[ -n "$VERSION" ] || die "no PORTVERSION in the Makefile"
REVISION=$(field PORTREVISION)
if [ -n "$REVISION" ] && [ "$REVISION" != "0" ]; then
	VERSION="${VERSION}_${REVISION}"
fi

COMMENT=$(field COMMENT)
MAINTAINER=$(field MAINTAINER)
LICENSE=$(field LICENSE)
CATEGORIES=$(field CATEGORIES | cut -d' ' -f1)
[ -n "$COMMENT" ] || die "no COMMENT in the Makefile"
[ -n "$MAINTAINER" ] || die "no MAINTAINER in the Makefile"
[ -n "$LICENSE" ] || die "no LICENSE in the Makefile - not redistributable"
[ -n "$CATEGORIES" ] || CATEGORIES=net

# %%DATADIR%% in the plist; $PREFIX/share/$PORTNAME is the FreeBSD default,
# but ports may override DATADIR in the Makefile.
DATADIR=$(field DATADIR)
if [ -n "$DATADIR" ]; then
	DATADIR=$(echo "$DATADIR" | sed -e 's|\${PREFIX}|/usr/local|g' \
		-e "s|\${PORTNAME}|${NAME}|g")
	case "$DATADIR" in
	*'$'*) die "unresolved variable in DATADIR '$DATADIR'" ;;
	esac
else
	DATADIR=/usr/local/share/$NAME
fi

# Stage the files named by the port's plist; @-prefixed entries (@dir,
# @sample, ...) are skipped, exactly like the port's own install.sh does.
STAGE="$WORK/stage"
PLIST="$WORK/plist"
: > "$PLIST"
grep -v '^@' "$PORT/pkg-plist" | while read -r entry; do
	[ -n "$entry" ] || continue
	case "$entry" in
	%%DATADIR%%/*) path="${DATADIR}/${entry#%%DATADIR%%/}" ;;
	/*) path="$entry" ;;
	*) path="/usr/local/$entry" ;;
	esac
	src="$PORT/files$path"
	[ -f "$src" ] || die "$src missing (listed in pkg-plist)"
	mkdir -p "$STAGE$(dirname "$path")"
	case "$path" in
	/usr/local/bin/*) install -m 0755 "$src" "$STAGE$path" ;;
	*) install -m 0644 "$src" "$STAGE$path" ;;
	esac
	echo "$path" >> "$PLIST"
done
[ -s "$PLIST" ] || die "nothing staged from pkg-plist"

INFOXML="$STAGE$DATADIR/info.xml"
sed -e "s|%%PKGVERSION%%|${VERSION}|" "$INFOXML" > "$INFOXML.new"
install -m 0644 "$INFOXML.new" "$INFOXML"
rm -f "$INFOXML.new"

# The scripts are what repository-built pfSense packages ship: the pfSense
# package hooks run through /etc/rc.packages.
cat > "$WORK/+MANIFEST" <<MANIFEST
name: "${NAME}"
version: "${VERSION}"
origin: "${PORT_PATH}"
comment: "${COMMENT}"
maintainer: "${MAINTAINER}"
www: "${UPSTREAM}"
abi: "$(pkg config abi)"
prefix: "/usr/local"
licenselogic: "single"
licenses: ["${LICENSE}"]
categories: ["${CATEGORIES}"]
desc: <<EOD
$(cat "$PORT/pkg-descr")
EOD
scripts: {
  post-install: "/usr/local/bin/php -f /etc/rc.packages ${NAME} POST-INSTALL"
  pre-deinstall: "/usr/local/bin/php -f /etc/rc.packages ${NAME} DEINSTALL"
  post-deinstall: "/usr/local/bin/php -f /etc/rc.packages ${NAME} POST-DEINSTALL"
}
MANIFEST

pkg create -M "$WORK/+MANIFEST" -p "$PLIST" -r "$STAGE" -o "$WORK/out" >&2 ||
	die "pkg create failed"

PKGFILE=$(ls "$WORK"/out/"${NAME}"-*.pkg 2>/dev/null | head -1)
[ -n "$PKGFILE" ] || die "pkg create produced no package"
mv "$PKGFILE" "$ALLDIR/"
echo "PKG=$(basename "$PKGFILE")"
