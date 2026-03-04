#!/bin/bash
# Extract TAK Server dependencies for plugin compilation
set -euo pipefail

TAK_ZIP=$1
LIBS_DIR="${2:-/tmp/tak-plugin-libs}"

if [ -z "$TAK_ZIP" ]; then
    echo "Usage: $0 <takserver-zip> [libs-dir]"
    exit 1
fi

mkdir -p "$LIBS_DIR"

echo "Extracting core JARs from $TAK_ZIP"
unzip -j "$TAK_ZIP" "*/tak/takserver-pm.jar" -d "$LIBS_DIR" 2>/dev/null || true
unzip -j "$TAK_ZIP" "*/tak/db-utils/SchemaManager.jar" -d "$LIBS_DIR" 2>/dev/null || true
unzip -j "$TAK_ZIP" "*/tak/utils/UserManager.jar" -d "$LIBS_DIR" 2>/dev/null || true
unzip -j "$TAK_ZIP" "*/tak/takserver.war" -d "$LIBS_DIR" 2>/dev/null || true

if [ -f "$LIBS_DIR/takserver.war" ]; then
    echo "Extracting internal libraries from WAR"
    cd "$LIBS_DIR"
    unzip -j takserver.war 'WEB-INF/lib/dom4j-*.jar' 2>/dev/null || true
    unzip -j takserver.war 'WEB-INF/lib/takserver-protobuf-*.jar' 2>/dev/null || true
    unzip -j takserver.war 'WEB-INF/lib/takserver-common-*.jar' 2>/dev/null || true
    unzip -j takserver.war 'WEB-INF/lib/takserver-plugins-*.jar' 2>/dev/null || true
    unzip -j takserver.war 'WEB-INF/lib/guava-*.jar' 2>/dev/null || true
    rm -f takserver.war
fi

echo "Dependencies extracted to $LIBS_DIR"
