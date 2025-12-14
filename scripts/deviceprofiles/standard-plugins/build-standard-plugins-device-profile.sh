#!/bin/bash

# Check if version parameter is provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <version>"
    echo "Available versions: 5.4, 5.5, 5.6"
    exit 1
fi

VERSION="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/template"

# Validate version
if [[ ! "$VERSION" =~ ^(5\.4|5\.5|5\.6)$ ]]; then
    echo "Error: Invalid version '$VERSION'. Available versions: 5.4, 5.5, 5.6"
    exit 1
fi

# Generate UUID for the device profile
UUID=$(uuidgen)

# Create temporary directory
TEMP_DIR=$(mktemp -d)
PACKAGE_NAME="TAK-NZ-Standard-Plugins-${VERSION}-${UUID}.zip"

# Copy MANIFEST directory
cp -r "${TEMPLATE_DIR}/MANIFEST" "${TEMP_DIR}/"

# Create plugins directory and copy only the required APK and plugin.xml
mkdir -p "${TEMP_DIR}/plugins"
cp "${TEMPLATE_DIR}/plugins/plugin-${VERSION}.xml" "${TEMP_DIR}/plugins/plugin.xml"

# Copy only the APK file for the selected version
case "$VERSION" in
    "5.4")
        cp "${TEMPLATE_DIR}/plugins/ATAK-Plugin-datasync-3.5.30-6fabb35e-5.4.0-civ-release.apk" "${TEMP_DIR}/plugins/"
        ;;
    "5.5")
        cp "${TEMPLATE_DIR}/plugins/ATAK-Plugin-datasync-3.5.32-7878c349-5.5.0-civ-release.apk" "${TEMP_DIR}/plugins/"
        ;;
    "5.6")
        cp "${TEMPLATE_DIR}/plugins/ATAK-Plugin-datasync-3.6.5-59da6dd5-5.6.0-civ-release.apk" "${TEMP_DIR}/plugins/"
        ;;
esac

# Calculate SHA256 hash of plugin.xml
HASH=$(sha256sum "${TEMP_DIR}/plugins/plugin.xml" | cut -d' ' -f1)

# Replace placeholders in MissionPackageManifest.xml
sed -i "s/{{UUID}}/${UUID}/g" "${TEMP_DIR}/MANIFEST/MissionPackageManifest.xml"
sed -i "s/{{HASH}}/${HASH}/g" "${TEMP_DIR}/MANIFEST/MissionPackageManifest.xml"

# Create ZIP package
cd "${TEMP_DIR}"
zip -r "${PACKAGE_NAME}" MANIFEST/ plugins/

# Move to current directory
mv "${PACKAGE_NAME}" "${OLDPWD}/"

# Cleanup
rm -rf "${TEMP_DIR}"

echo "Plugin device profile created: ${PACKAGE_NAME}"
echo "Version: ${VERSION}"
echo "UUID: ${UUID}"
echo "Hash: ${HASH}"