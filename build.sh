#!/bin/bash
# Build script for TallBar standalone app

set -e

APP_NAME="TallBar"
BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "=== Building ${APP_NAME} standalone app ==="

rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS}"
mkdir -p "${RESOURCES}"

cp Info.plist "${CONTENTS}/Info.plist"

ARCHS="${ARCHS:-arm64}"
DEPLOY_TARGET="12.0"
SLICES=""

for ARCH in ${ARCHS}; do
    TARGET="${ARCH}-apple-macosx${DEPLOY_TARGET}"

    echo "Compiling Objective-C for ${ARCH}..."
    clang -c \
        -target ${TARGET} \
        -fobjc-arc \
        -framework Foundation \
        -framework CoreGraphics \
        -framework AppKit \
        -framework IOKit \
        Sources/TallBarDisplayManager.m \
        -o "${BUILD_DIR}/TallBarDisplayManager-${ARCH}.o"

    echo "Compiling Swift and linking for ${ARCH}..."
    swiftc \
        -target ${TARGET} \
        -parse-as-library \
        Sources/AppDelegate.swift \
        "${BUILD_DIR}/TallBarDisplayManager-${ARCH}.o" \
        -import-objc-header Sources/BridgingHeader.h \
        -framework Foundation \
        -framework AppKit \
        -framework CoreGraphics \
        -framework IOKit \
        -o "${BUILD_DIR}/${APP_NAME}-${ARCH}"

    SLICES="${SLICES} ${BUILD_DIR}/${APP_NAME}-${ARCH}"
done

echo "Creating binary..."
if [ $(echo "${ARCHS}" | wc -w) -gt 1 ]; then
    lipo -create ${SLICES} -output "${MACOS}/${APP_NAME}"
else
    cp "${BUILD_DIR}/${APP_NAME}-${ARCHS}" "${MACOS}/${APP_NAME}"
fi
chmod +x "${MACOS}/${APP_NAME}"

echo "Codesigning..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "=== Build complete: ${APP_BUNDLE} ==="
echo "To run:"
echo "  open \"${APP_BUNDLE}\""
