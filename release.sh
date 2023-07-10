#!/usr/bin/env bash
set -euxo pipefail
if [ $# -ne 1 ]
then
    echo "Usage: $0 <tag>"
    exit 1
fi
./build.sh
strip openapi-to-d
FOLDER="openapi-to-d-$1"
ZIPFILE="openapi-to-d-$1.zip"
rm "$ZIPFILE" || true
mkdir "$FOLDER"
mv openapi-to-d "$FOLDER"
zip -r "$ZIPFILE" "$FOLDER"
rm -rf "$FOLDER"
