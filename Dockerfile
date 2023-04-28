FROM ubuntu:16.04 AS build

RUN apt-get update

RUN apt-get install -y gcc curl xz-utils

RUN curl https://downloads.dlang.org/releases/2.x/2.099.1/dmd.2.099.1.linux.tar.xz -o dmd.2.099.1.linux.tar.xz && \
  tar xf dmd.2.099.1.linux.tar.xz

COPY . /tmp/build

RUN sh -c 'cd /tmp/build && PATH=/dmd2/linux/bin64:$PATH dub build'

FROM scratch AS export
COPY --from=build /tmp/build/openapi-to-d .
