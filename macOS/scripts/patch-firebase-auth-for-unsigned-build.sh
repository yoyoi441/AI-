#!/bin/bash
set -euo pipefail

derived_data_path=${1:?"usage: $0 DERIVED_DATA_PATH"}
target="$derived_data_path/SourcePackages/checkouts/firebase-ios-sdk/FirebaseAuth/Sources/Swift/Storage/AuthKeychainServices.swift"
patch_file="$(cd "$(dirname "$0")" && pwd)/firebase-auth-unsigned-macos-keychain.patch"

swift_source_root="$(dirname "$(dirname "$target")")"
auth_source="$swift_source_root/Auth/Auth.swift"

if grep -q 'unsignedBuildStorageURL' "$target" &&
   grep -q 'TOKEN_MIHARIBAN_UNSIGNED_BUILD' "$target" &&
   grep -q 'token_mihariban_unsigned' "$auth_source"; then
  exit 0
fi

if grep -q 'TOKEN_MIHARIBAN_UNSIGNED_BUILD' "$target" ||
   grep -q 'token_mihariban_unsigned' "$auth_source"; then
  echo "Firebase Auth source is only partially patched." >&2
  exit 1
fi

if ! grep -q 'query\[kSecUseDataProtectionKeychain as String\] = true' "$target" ||
   ! grep -q 'let serviceName = "firebase_auth_\\(app.options.googleAppID)"' "$auth_source"; then
  echo "Firebase Auth source does not match the expected pinned version." >&2
  exit 1
fi

chmod u+w "$target"
chmod u+w "$auth_source"
(cd "$swift_source_root" && /usr/bin/patch -p0 < "$patch_file")
grep -q 'TOKEN_MIHARIBAN_UNSIGNED_BUILD' "$target"
grep -q 'unsignedBuildStorageURL' "$target"
grep -q 'token_mihariban_unsigned' "$auth_source"
