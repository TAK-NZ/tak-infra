#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/template"

# Generate UUID for the device profile
UUID=$(uuidgen)

# Create temporary directory
TEMP_DIR=$(mktemp -d)
PACKAGE_NAME="TAK-NZ-ATAK-Standard-Settings-${UUID}.zip"

# Copy template to temporary directory
cp -r "${TEMPLATE_DIR}"/* "${TEMP_DIR}/"

# Calculate SHA256 hash of config.pref
HASH=$(sha256sum "${TEMP_DIR}/prefs/config.pref" | cut -d' ' -f1)

# Replace placeholders in MissionPackageManifest.xml
sed -i "s/{{UUID}}/${UUID}/g" "${TEMP_DIR}/MANIFEST/MissionPackageManifest.xml"
sed -i "s/{{HASH}}/${HASH}/g" "${TEMP_DIR}/MANIFEST/MissionPackageManifest.xml"

# Create ZIP package
cd "${TEMP_DIR}"
zip -r "${PACKAGE_NAME}" MANIFEST/ prefs/

# Move to current directory
mv "${PACKAGE_NAME}" "${OLDPWD}/"

# Cleanup
rm -rf "${TEMP_DIR}"

echo "Device profile created: ${PACKAGE_NAME}"
echo "UUID: ${UUID}"
echo "Hash: ${HASH}"