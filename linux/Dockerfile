# Everlast dedicated server. SteamCMD downloads the server from the Everlast Dedicated Server tool app (4268160) at every
# start, unless install.sh installed it from a release archive, then runs it with its worlds in /data (entrypoint.sh).
# Settings: the data folder's appsettings.json and the world's worldsettings.json, written by install.sh.
FROM debian:12-slim

# lib32gcc-s1: SteamCMD itself is a 32-bit program. The server is 64-bit and uses SteamCMD's linux64/steamclient.so.
# libcurl4: linked by the Native AOT server. libicu72, libssl3: .NET globalization and TLS. tini forwards SIGTERM so the
# server shuts down gracefully.
RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl lib32gcc-s1 libcurl4 libicu72 libssl3 tini \
 && rm -rf /var/lib/apt/lists/*

# The container runs as the owner of the install folder (install.sh passes it), so files stay editable on the host.
ARG EVERLAST_UID=1000
ARG EVERLAST_GID=1000
COPY entrypoint.sh /usr/local/bin/everlast-entrypoint
RUN chmod 755 /usr/local/bin/everlast-entrypoint \
 && groupadd --non-unique --gid "$EVERLAST_GID" everlast \
 && useradd --non-unique --create-home --uid "$EVERLAST_UID" --gid "$EVERLAST_GID" everlast \
 && mkdir -p /steam /data \
 && chown everlast:everlast /steam /data

# /steam keeps SteamCMD, its cached login and the installed server, so a restart only downloads what changed.
USER everlast
ENV HOME=/steam
VOLUME ["/steam", "/data"]
ENTRYPOINT ["tini", "--", "everlast-entrypoint"]
CMD ["run"]
