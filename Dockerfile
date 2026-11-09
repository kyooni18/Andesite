# andesite-server for Linux, serving one Vault over HTTP.
#
# The server only listens on the container's loopback (by design); nginx
# forwards the container's port 8790 to it. Publish that port to the host's
# loopback only (-p 127.0.0.1:8790:8790): the sync client accepts plain HTTP
# only to loopback, and anything wider needs a TLS-terminating proxy.
#
# Notes live in /data/vaults/main (set ANDESITE_VAULT for another name);
# mount a host folder on /data/vaults to see them. Server state stays in /data.
#
#   docker build -t andesite-server .          (or: container build -t andesite-server .)
#   docker run -d --name andesite -p 127.0.0.1:8790:8790 \
#     -e ANDESITE_API_TOKEN=$(openssl rand -hex 32) \
#     -v andesite:/data -v "$PWD/vaults:/data/vaults" andesite-server

FROM swift:6.2-noble AS build
RUN apt-get update -qq && apt-get install -y -qq libsqlite3-dev >/dev/null
WORKDIR /src
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY Sources Sources
COPY Tests Tests
RUN swift build -c release --product andesite-server --static-swift-stdlib \
 && cp "$(swift build -c release --show-bin-path)/andesite-server" /andesite-server

FROM ubuntu:noble
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends libsqlite3-0 libcurl4 libxml2 nginx-light ca-certificates >/dev/null \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --create-home --home-dir /home/andesite andesite
COPY --from=build /andesite-server /usr/local/bin/andesite-server
COPY deploy/nginx.conf /etc/nginx/andesite.conf
COPY deploy/entrypoint.sh /usr/local/bin/andesite-entrypoint
EXPOSE 8790
VOLUME /data
ENTRYPOINT ["/usr/local/bin/andesite-entrypoint"]
