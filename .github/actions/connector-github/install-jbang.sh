#!/usr/bin/env bash
#
# Install a pinned JBang distribution using nothing but bash, curl and tar.
#
# This replaces `uses: jbangdev/setup-jbang@main`, which an actions allow-list
# limited to enterprise-owned, GitHub-authored and Marketplace-verified actions
# will reject. It is also a straight upgrade on what that action does:
# setup-jbang pipes an unpinned https://sh.jbang.dev script into bash and then
# installs "latest", so the bytes that end up on the runner are whatever the
# release feed served that minute. Here one named release asset is fetched and
# discarded unless it matches a SHA-256 recorded in action.yml.
#
# The plain `jbang-<version>.tar` asset is the right one to use: its `bin/jbang`
# launcher runs the `bin/jbang.jar` sitting next to it and never phones home for
# a distribution, and it takes the JDK from $JAVA_HOME instead of bundling its
# own (the `-linux-x64` assets are 3x larger precisely because they carry one).
# `.tar` rather than `.zip` because it is uncompressed — plain `tar` unpacks it,
# with no dependency on `unzip` being present on a hardened runner.
#
# Required environment (set as step-level `env:` in action.yml):
#   JBANG_VERSION  e.g. 0.141.0
#   JBANG_SHA256   SHA-256 of jbang-$JBANG_VERSION.tar
#
# Optional environment:
#   JBANG_DOWNLOAD_BASEURL  release base URL; override to point at a corporate
#                           mirror. Same variable name JBang's own installer
#                           uses, so one mirror setting serves both.
#                           Default: https://github.com/jbangdev/jbang/releases
#   JBANG_INSTALL_ROOT      where distributions are unpacked.
#                           Default: $HOME/.streamx/jbang
set -euo pipefail

version="${JBANG_VERSION:-}"
expected_sha256="${JBANG_SHA256:-}"
base_url="${JBANG_DOWNLOAD_BASEURL:-https://github.com/jbangdev/jbang/releases}"
install_root="${JBANG_INSTALL_ROOT:-$HOME/.streamx/jbang}"

group_open=0
open_group() { echo "::group::$1"; group_open=1; }
close_group() { if [ "$group_open" -eq 1 ]; then echo "::endgroup::"; group_open=0; fi; }
# Without this, a failure inside the group leaves every later step of the job
# folded into a collapsed section titled "Install JBang" — the log looks like
# the failure happened here even when it happened three steps later.
trap close_group EXIT

die() { echo "::error::$*"; exit 1; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    return 1
  fi
}

if [ -z "$version" ] || [ -z "$expected_sha256" ]; then
  die "install-jbang.sh needs both JBANG_VERSION and JBANG_SHA256 set. Both are pinned as step-level env in action.yml; see its PINS note."
fi

asset="jbang-${version}.tar"
url="${base_url}/download/v${version}/${asset}"
install_dir="${install_root}/${version}"
dist_dir="${install_dir}/jbang-${version}"
bin_dir="${dist_dir}/bin"
# Records the SHA-256 of the installed jbang.jar at the moment it was verified,
# so a reused install can be checked instead of merely counted.
stamp_file="${install_dir}/.verified-jar-sha256"

open_group "Install JBang ${version}"

add_to_path() {
  # A composite action cannot alter PATH for later steps except through this
  # file. Outside Actions (a local smoke test) there is nothing to write to.
  if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$1" >> "$GITHUB_PATH"
  else
    echo "GITHUB_PATH is unset; add $1 to PATH by hand if running this locally."
  fi
  export PATH="$1:$PATH"
}

# Persistent self-hosted runners keep $HOME between jobs, so a matching install
# is worth reusing — but only after re-checking it. Reusing on the strength of
# "the directory is there" would mean the checksum guarantee quietly stops
# applying from the second job onwards on exactly the long-lived, shared
# machines where it matters most.
if [ -x "${bin_dir}/jbang" ] && [ -f "${bin_dir}/jbang.jar" ] && [ -f "$stamp_file" ]; then
  recorded_jar_sha="$(cat "$stamp_file")"
  actual_jar_sha="$(sha256_of "${bin_dir}/jbang.jar" || true)"
  if [ -n "$actual_jar_sha" ] && [ "$actual_jar_sha" = "$recorded_jar_sha" ]; then
    echo "JBang ${version} is already installed at ${install_dir} and its jar still matches; reusing it."
    add_to_path "$bin_dir"
    jbang version
    close_group
    exit 0
  fi
  echo "::warning::The cached JBang ${version} at ${install_dir} no longer matches its recorded checksum; reinstalling."
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"; close_group' EXIT

echo "Downloading ${url}"
curl --fail --silent --show-error --location \
     --retry 5 --retry-delay 2 --retry-connrefused \
     --connect-timeout 15 --max-time 600 \
     --output "${work_dir}/${asset}" \
     "$url"

# The two hashes are compared as text rather than piped through `sha256sum -c`
# so the failure message can name both values; a checksum mismatch is the one
# failure here that must not be mistaken for a network blip.
actual_sha256="$(sha256_of "${work_dir}/${asset}" || true)"
if [ -z "$actual_sha256" ]; then
  die "Neither sha256sum nor shasum is available, so the download cannot be verified."
fi

if [ "$actual_sha256" != "$expected_sha256" ]; then
  echo "::error::SHA-256 mismatch on ${asset} — refusing to install."
  echo "::error::expected ${expected_sha256}"
  echo "::error::actual   ${actual_sha256}"
  echo "::error::If JBANG_VERSION was bumped without bumping JBANG_SHA256, that is the cause:"
  die "the checksums live at ${base_url}/download/v${version}/checksums_sha256.txt"
fi
echo "SHA-256 verified: ${actual_sha256}"

mkdir -p "$work_dir/unpacked"
tar -xf "${work_dir}/${asset}" -C "$work_dir/unpacked"

if [ ! -f "$work_dir/unpacked/jbang-${version}/bin/jbang" ]; then
  die "${asset} did not contain jbang-${version}/bin/jbang. The asset layout changed; install-jbang.sh needs updating."
fi

# Replace rather than merge: a previous partial install must not survive.
rm -rf "$install_dir"
mkdir -p "$install_dir"
mv "$work_dir/unpacked/jbang-${version}" "$install_dir/"
chmod +x "${bin_dir}/jbang"
sha256_of "${bin_dir}/jbang.jar" > "$stamp_file"

add_to_path "$bin_dir"
jbang version
close_group
