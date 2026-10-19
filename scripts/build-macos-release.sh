#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_dir="$project_root/build/release"
identity_file="$release_dir/signing-identity"
mkdir -p "$release_dir"

# Reuse the same certificate so Keychain can recognise subsequent releases.
# An explicit override must be the SHA-1 fingerprint from find-identity.
identities="$(security find-identity -v -p codesigning)"
identity="${TERMES_SIGNING_IDENTITY:-}"
if [[ -z "$identity" && -f "$identity_file" ]]; then
  identity="$(cat "$identity_file")"
fi
if [[ -z "$identity" ]]; then
  identity="$(printf '%s\n' "$identities" | awk 'length($2) == 40 && $2 ~ /^[0-9A-F]+$/ { print $2; exit }')"
fi
if [[ -z "$identity" ]] || ! printf '%s\n' "$identities" | awk -v identity="$identity" '$2 == identity { found = 1 } END { exit !found }'; then
  printf '%s\n' 'A valid signing certificate is required. Check security find-identity -v -p codesigning and set TERMES_SIGNING_IDENTITY to its SHA-1 fingerprint.' >&2
  exit 1
fi

export TOOLCHAINS="${TERMES_TOOLCHAINS:-org.swift.641202610071a com.apple.dt.toolchain.XcodeDefault}"
export SWIFT_EXEC_MANIFEST="$(xcrun --toolchain com.apple.dt.toolchain.XcodeDefault --find swiftc)"
xcrun swift --version

source_packages="${TERMES_SOURCE_PACKAGES_DIR:-$release_dir/SourcePackages}"
if [[ -z "${TERMES_SOURCE_PACKAGES_DIR:-}" && -d "$project_root/build/mobile-swift64/SourcePackages" ]]; then
  source_packages="$project_root/build/mobile-swift64/SourcePackages"
fi

printf 'Building signed Release; log: %s\n' "$release_dir/build.log"
if ! xcodebuild -project "$project_root/Termes.xcodeproj" -scheme Termes \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$release_dir" -clonedSourcePackagesDirPath "$source_packages" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -skipPackagePluginValidation CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" \
  build > "$release_dir/build.log" 2>&1; then
  tail -n 80 "$release_dir/build.log" >&2
  exit 1
fi

app="$release_dir/Build/Products/Release/Termes.app"
codesign --verify --deep --strict --verbose=2 "$app"
printf '%s\n' "$identity" > "$identity_file"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
archive="$release_dir/Termes-$version-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
printf 'App: %s\nArchive: %s\n' "$app" "$archive"
