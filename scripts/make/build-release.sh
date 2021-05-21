#!/bin/sh

# AdGuard Home Release Script
#
# The commentary in this file is written with the assumption that the reader
# only has superficial knowledge of the POSIX shell language and alike.
# Experienced readers may find it overly verbose.

# The default verbosity level is 0.  Show log messages if the caller requested
# verbosity level greather than 0.  Show every command that is run if the
# verbosity level is greater than 1.  Show the environment if the verbosity
# level is greater than 2.  Otherwise, print nothing.
#
# The level of verbosity for the build script is the same minus one level.  See
# below in build().
verbose="${VERBOSE:-0}"
readonly verbose

if [ "$verbose" -gt '2' ]
then
	env
	set -x
elif [ "$verbose" -gt '1' ]
then
	set -x
fi

# By default, sign the packages, but allow users to skip that step.
sign="${SIGN:-1}"
readonly sign

# Exit the script if a pipeline fails (-e), prevent accidental filename
# expansion (-f), and consider undefined variables as errors (-u).
set -e -f -u

# Function log is an echo wrapper that writes to stderr if the caller requested
# verbosity level greater than 0.  Otherwise, it does nothing.
log() {
	if [ "$verbose" -gt '0' ]
	then
		# Don't use quotes to get word splitting.
		echo "$1" 1>&2
	fi
}

log 'starting to build AdGuard Home release'

# Require the channel to be set.  Additional validation is performed later by
# go-build.sh.
channel="$CHANNEL"
readonly channel

# Check VERSION against the default value from the Makefile.  If it is that, use
# the version calculation script.
if [ "${VERSION:-}" = 'v0.0.0' ] || [ "${VERSION:-}" = '' ]
then
	version="$( sh ./scripts/make/version.sh )"
else
	version="$VERSION"
fi
readonly version

log "channel '$channel'"
log "version '$version'"

# Check architecture and OS limiters.  Add spaces to the local versions for
# better pattern matching.
if [ "${ARCH:-}" != '' ]
then
	log "arches: '$ARCH'"
	arches=" $ARCH "
else
	arches=''
fi
readonly arches

if [ "${OS:-}" != '' ]
then
	log "oses: '$OS'"
	oses=" $OS "
else
	oses=''
fi
readonly oses

snap_enabled="${BUILD_SNAP:-1}"
readonly snap_enabled

if [ "$snap_enabled" -eq '0' ]
then
	log 'snap: disabled'
fi

# Require the gpg key and passphrase to be set if the signing is required.
if [ "$sign" -eq '1' ]
then
	gpg_key_passphrase="$GPG_KEY_PASSPHRASE"
	gpg_key="$GPG_KEY"
else
	gpg_key_passphrase=''
	gpg_key=''
fi
readonly gpg_key_passphrase gpg_key

# The default distribution files directory is dist.
dist="${DIST_DIR:-dist}"
readonly dist

log "checking tools"

# Make sure we fail gracefully if one of the tools we need is missing.  Use
# alternatives when available.
sha256sum_cmd='sha256sum'
for tool in gpg gzip sed "$sha256sum_cmd" snapcraft tar zip
do
	if ! command -v "$tool" > /dev/null
	then
		if [ "$tool" = "$sha256sum_cmd" ] && command -v 'shasum' > /dev/null
		then
			# macOS doesn't have sha256sum installed by default, but
			# it does have shasum.
			log 'replacing sha256sum with shasum -a 256'
			sha256sum_cmd='shasum -a 256'
		else
			log "pieces don't fit, '$tool' not found"

			exit 1
		fi
	fi
done
readonly sha256sum_cmd

# Data section.  Arrange data into space-separated tables for read -r to read.
# Use 0 for missing values.
#
# TODO(a.garipov): Remove armv6, because it was always overwritten by armv7.
# Rename armv7 to armhf.  Rename the 386 snap to i386.

#    os  arch      arm mips       snap
platforms="\
darwin   amd64     0   0          0
darwin   arm64     0   0          0
freebsd  386       0   0          0
freebsd  amd64     0   0          0
freebsd  arm       5   0          0
freebsd  arm       6   0          0
freebsd  arm       7   0          0
freebsd  arm64     0   0          0
linux    386       0   0          386
linux    amd64     0   0          amd64
linux    arm       5   0          0
linux    arm       6   0          armv6
linux    arm       7   0          armv7
linux    arm64     0   0          arm64
linux    mips      0   softfloat  0
linux    mips64    0   softfloat  0
linux    mips64le  0   softfloat  0
linux    mipsle    0   softfloat  0
linux    ppc64le   0   0          0
windows  386       0   0          0
windows  amd64     0   0          0"
readonly platforms

# Function build builds the release for one platform.  It builds a binary, an
# archive and, if needed, a snap package.
build() {
	# Get the arguments.  Here and below, use the "build_" prefix for all
	# variables local to function build.
	build_dir="${dist}/${1}/AdGuardHome"\
		build_ar="$2"\
		build_os="$3"\
		build_arch="$4"\
		build_arm="$5"\
		build_mips="$6"\
		build_snap="$7"\
		;

	# Use the ".exe" filename extension if we build a Windows release.
	if [ "$build_os" = 'windows' ]
	then
		build_output="./${build_dir}/AdGuardHome.exe"
	else
		build_output="./${build_dir}/AdGuardHome"
	fi

	mkdir -p "./${build_dir}"

	# Build the binary.
	#
	# Set GOARM and GOMIPS to an empty string if $build_arm and $build_mips
	# are zero by removing the zero as if it's a prefix.
	#
	# Don't use quotes with $build_par because we want an empty space if
	# parallelism wasn't set.
	env\
		GOARCH="$build_arch"\
		GOARM="${build_arm#0}"\
		GOMIPS="${build_mips#0}"\
		GOOS="$os"\
		VERBOSE="$(( verbose - 1 ))"\
		VERSION="$version"\
		OUT="$build_output"\
		sh ./scripts/make/go-build.sh\
		;

	log "$build_output"

	if [ "$sign" -eq '1' ]
	then
		gpg\
			--default-key "$gpg_key"\
			--detach-sig\
			--passphrase "$gpg_key_passphrase"\
			--pinentry-mode loopback\
			-q\
			"$build_output"\
			;
	fi

	# Prepare the build directory for archiving.
	cp ./CHANGELOG.md ./LICENSE.txt ./README.md "$build_dir"

	# Make archives.  Windows and macOS prefer ZIP archives; the rest,
	# gzipped tarballs.
	case "$build_os"
	in
	('darwin'|'windows')
		build_archive="./${dist}/${build_ar}.zip"
		# TODO(a.garipov): Find an option similar to the -C option of
		# tar for zip.
		( cd "${dist}/${1}" && zip -9 -q -r "../../${build_archive}" "./AdGuardHome" )
		;;
	(*)
		build_archive="./${dist}/${build_ar}.tar.gz"
		tar -C "./${dist}/${1}" -c -f - "./AdGuardHome" | gzip -9 - > "$build_archive"
		;;
	esac

	log "$build_archive"

	# build_snap is a string, so use string comparison for it.
	#
	# TODO(a.garipov): Consider using a different empty value in the
	# platforms table.
	if [ "$build_snap" = '0' ] || [ "$snap_enabled" -eq '0' ]
	then
		return
	fi

	# Prepare snap build.
	build_snap_output="./${dist}/AdGuardHome_${build_snap}.snap"
	build_snap_dir="${build_snap_output}.dir"

	# Create the meta subdirectory and copy files there.
	mkdir -p "${build_snap_dir}/meta"
	cp "$build_output"\
		'./scripts/snap/local/adguard-home-web.sh'\
		"$build_snap_dir"
	cp -r './scripts/snap/gui'\
		"${build_snap_dir}/meta/"

	# TODO(a.garipov): Remove this crutch later.
	case "$build_snap"
	in
	('386')
		build_snap_arch="i386"
		;;
	('armv6'|'armv7')
		build_snap_arch="armhf"
		;;
	(*)
		build_snap_arch="$build_snap"
		;;
	esac

	# Create a snap.yaml file, setting the values.
	sed -e 's/%VERSION%/'"$version"'/'\
		-e 's/%ARCH%/'"$build_snap_arch"'/'\
		./scripts/snap/snap.tmpl.yaml\
		>"${build_snap_dir}/meta/snap.yaml"

	# TODO(a.garipov): The snapcraft tool will *always* write everything,
	# including errors, to stdout.  And there doesn't seem to be a way to
	# change that.  So, save the combined output, but only show it when
	# snapcraft actually fails.
	set +e
	build_snapcraft_output="$(
		snapcraft pack "$build_snap_dir" --output "$build_snap_output" 2>&1
	)"
	build_snapcraft_exit_code="$?"
	set -e
	if [ "$build_snapcraft_exit_code" != '0' ]
	then
		log "$build_snapcraft_output"
		exit "$build_snapcraft_exit_code"
	fi

	log "$build_snap_output"
}

log "starting builds"

# Go over all platforms defined in the space-separated table above, tweak the
# values where necessary, and feed to build.
echo "$platforms" | while read -r os arch arm mips snap
do
	# See if the architecture or the OS is in the allowlist.  To do so, try
	# removing everything that matches the pattern (well, a prefix, but that
	# doesn't matter here) containing the arch or the OS.
	#
	# For example, when $arches is " amd64 arm64 " and $arch is "amd64",
	# then the pattern to remove is "* amd64 *", so the whole string becomes
	# empty.  On the other hand, if $arch is "windows", then the pattern is
	# "* windows *", which doesn't match, so nothing is removed.
	#
	# See https://stackoverflow.com/a/43912605/1892060.
	if [ "${arches##* $arch *}" != '' ]
	then
		log "$arch excluded, continuing"

		continue
	elif [ "${oses##* $os *}" != '' ]
	then
		log "$os excluded, continuing"

		continue
	fi

	case "$arch"
	in
	(arm)
		dir="AdGuardHome_${os}_${arch}_${arm}"
		ar="AdGuardHome_${os}_${arch}v${arm}"
		;;
	(mips*)
		dir="AdGuardHome_${os}_${arch}_${mips}"
		ar="$dir"
		;;
	(*)
		dir="AdGuardHome_${os}_${arch}"
		ar="$dir"
		;;
	esac

	build "$dir" "$ar" "$os" "$arch" "$arm" "$mips" "$snap"
done

log "packing frontend"

build_archive="./${dist}/AdGuardHome_frontend.tar.gz"
tar -c -f - ./build ./build2 | gzip -9 - > "$build_archive"
log "$build_archive"

log "calculating checksums"

# Calculate the checksums of the files in a subshell with a different working
# directory.  Don't use ls, because files matching one of the patterns may be
# absent, which will make ls return with a non-zero status code.
(
	cd "./${dist}"

	files="$( find . ! -name . -prune \( -name '*.tar.gz' -o -name '*.zip' \) )"

	# Don't use quotes to get word splitting.
	$sha256sum_cmd $files > ./checksums.txt
)

log "writing versions"

echo "version=$version" > "./${dist}/version.txt"

# Create the verison.json file.

version_download_url="https://static.adguard.com/adguardhome/${channel}"
version_json="./${dist}/version.json"
readonly version_download_url version_json

# Point users to the master branch if the channel is edge.
if [ "$channel" = 'edge' ]
then
	version_history_url='https://github.com/AdguardTeam/AdGuardHome/commits/master'
else
	version_history_url='https://github.com/AdguardTeam/AdGuardHome/releases'
fi
readonly version_history_url

rm -f "$version_json"
echo "{
  \"version\": \"${version}\",
  \"announcement\": \"AdGuard Home ${version} is now available!\",
  \"announcement_url\": \"${version_history_url}\",
  \"selfupdate_min_version\": \"0.0\",
" >> "$version_json"

# Same as with checksums above, don't use ls, because files matching one of the
# patterns may be absent.
ar_files="$( find "./${dist}/" ! -name "${dist}" -prune \( -name '*.tar.gz' -o -name '*.zip' \) )"
ar_files_len="$( echo "$ar_files" | wc -l )"
readonly ar_files ar_files_len

i='1'
# Don't use quotes to get word splitting.
for f in $ar_files
do
	platform="$f"

	# Remove the prefix.
	platform="${platform#./${dist}/AdGuardHome_}"

	# Remove the filename extensions.
	platform="${platform%.zip}"
	platform="${platform%.tar.gz}"

	# Use the filename's base path.
	filename="${f#./${dist}/}"

	if [ "$i" -eq "$ar_files_len" ]
	then
		echo "  \"download_${platform}\": \"${version_download_url}/${filename}\"" >> "$version_json"
	else
		echo "  \"download_${platform}\": \"${version_download_url}/${filename}\"," >> "$version_json"
	fi

	i="$(( i + 1 ))"
done

echo '}' >> "$version_json"

log "finished"
