#!/bin/bash
set -euxo pipefail
NAME="openapi-to-d-$(git describe --always --dirty)"
docker build --rm -t "$NAME" .
CONTAINER=$(docker create "$NAME")
docker cp "$CONTAINER":/tmp/build/openapi-to-d .
docker rm -v "$CONTAINER"
