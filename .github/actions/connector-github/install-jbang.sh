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

if [ -z "$version" ] || [ -z "$expected_sha256" ]; then
  echo "::error::install-jbang.sh needs both JBANG_VERSION and JBANG_SHA256 set."
  echo "::error::Both are pinned as step-level env in action.yml; see its PINS note."
  exit 1
fi

asset="jbang-${version}.tar"
url="${base_url}/download/v${version}/${asset}"
install_dir="${install_root}/${version}"
bin_dir="${install_dir}/jbang-${version}/bin"

echo "::group::Install JBang ${version}"

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
# is worth reusing. Presence of the launcher is the test — a half-extracted
# directory from a killed job must not count as installed.
if [ -x "${bin_dir}/jbang" ] && [ -f "${bin_dir}/jbang.jar" ]; then
  echo "JBang ${version} is already installed at ${install_dir}; reusing it."
  add_to_path "$bin_dir"
  jbang version
  echo "::endgroup::"
  exit 0
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

echo "Downloading ${url}"
curl --fail --silent --show-error --location \
     --retry 5 --retry-delay 2 --retry-connrefused \
     --connect-timeout 15 --max-time 600 \
     --output "${work_dir}/${asset}" \
     "$url"

# Two shas are compared as text rather than piped through `sha256sum -c` so the
# failure message can name both values; a checksum mismatch is the one failure
# here that must not be mistaken for a network blip.
if command -v sha256sum >/dev/null 2>&1; then
  actual_sha256="$(sha256sum "${work_dir}/${asset}" | cut -d' ' -f1)"
elif command -v shasum >/dev/null 2>&1; then
  actual_sha256="$(shasum -a 256 "${work_dir}/${asset}" | cut -d' ' -f1)"
else
  echo "::error::Neither sha256sum nor shasum is available, so the download cannot be verified."
  exit 1
fi

if [ "$actual_sha256" != "$expected_sha256" ]; then
  echo "::error::SHA-256 mismatch on ${asset} — refusing to install."
  echo "::error::expected ${expected_sha256}"
  echo "::error::actual   ${actual_sha256}"
  echo "::error::If JBANG_VERSION was bumped without bumping JBANG_SHA256, that is the cause:"
  echo "::error::the checksums live at ${base_url}/download/v${version}/checksums_sha256.txt"
  exit 1
fi
echo "SHA-256 verified: ${actual_sha256}"

mkdir -p "$work_dir/unpacked"
tar -xf "${work_dir}/${asset}" -C "$work_dir/unpacked"

if [ ! -f "$work_dir/unpacked/jbang-${version}/bin/jbang" ]; then
  echo "::error::${asset} did not contain jbang-${version}/bin/jbang."
  echo "::error::The asset layout changed; install-jbang.sh needs updating."
  exit 1
fi

# Replace rather than merge: a previous partial install must not survive.
rm -rf "$install_dir"
mkdir -p "$install_dir"
mv "$work_dir/unpacked/jbang-${version}" "$install_dir/"
chmod +x "${bin_dir}/jbang"

add_to_path "$bin_dir"
jbang version
echo "::endgroup::"
