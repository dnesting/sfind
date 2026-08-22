#!/bin/sh
# Builds a universal (x86_64 + arm64) release binary into release/sfind.
#
# Deliberately not `swift build --arch arm64 --arch x86_64`: that flag is hidden and has a
# history of multi-arch breakage (swift-package-manager#8013), and its output path is
# backend-dependent. Two --triple builds + lipo is the stable pattern (as used by
# xcbeautify). Output dirs come from --show-bin-path, never hardcoded.
set -eu

PRODUCT_NAME=sfind
SWIFT=${SWIFT:-swift}
FLAGS="--configuration release --disable-sandbox"

x86_dir=$($SWIFT build --show-bin-path $FLAGS --triple x86_64-apple-macosx)
$SWIFT build $FLAGS --triple x86_64-apple-macosx

arm_dir=$($SWIFT build --show-bin-path $FLAGS --triple arm64-apple-macosx)
$SWIFT build $FLAGS --triple arm64-apple-macosx

mkdir -p release
lipo -create -output "release/$PRODUCT_NAME" \
    "$x86_dir/$PRODUCT_NAME" "$arm_dir/$PRODUCT_NAME"
lipo -info "release/$PRODUCT_NAME"
