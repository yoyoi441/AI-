#!/bin/bash
set -euo pipefail

derived_data_path=${1:?"usage: $0 DERIVED_DATA_PATH"}
target="$derived_data_path/SourcePackages/checkouts/firebase-ios-sdk/FirebaseAuth/Sources/Swift/Storage/AuthKeychainServices.swift"
patch_file="$(cd "$(dirname "$0")" && pwd)/firebase-auth-unsigned-macos-keychain.patch"

if grep -q 'TOKEN_MIHARIBAN_UNSIGNED_BUILD' "$target"; then
  exit 0
fi

if ! grep -q 'query\[kSecUseDataProtectionKeychain as String\] = true' "$target"; then
  echo "Firebase Auth source does not match the expected pinned version." >&2
  exit 1
fi

chmod u+w "$target"
(cd "$(dirname "$target")" && /usr/bin/patch AuthKeychainServices.swift "$patch_file")
grep -q 'TOKEN_MIHARIBAN_UNSIGNED_BUILD' "$target"
