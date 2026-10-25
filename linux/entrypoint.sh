#!/bin/bash
# Everlast dedicated server entrypoint. Commands:
#   run     (default) update the server from Steam, then start it. Extra arguments go to Raptor.Game.
#   update  update the server from Steam and exit.
#   login   log SteamCMD in once, interactively (password and Steam Guard code). The login is cached in /steam.
# Settings come from the environment (docker-compose.yml and .env) and the settings files in /data.
# SERVER_SOURCE=archive: install.sh put a release archive in /steam/server, so it is never updated from Steam.
set -euo pipefail

APP_ID=4268160
STEAMCMD_DIR=/steam/steamcmd
STEAMCMD="$STEAMCMD_DIR/steamcmd.sh"
INSTALL_DIR=/steam/server
LOGIN="${STEAM_USERNAME:-anonymous}"
BRANCH_PASSWORD_FILE=/secrets/steam_branch_password

log() { echo "[everlast] $*"; }

# SteamCMD downloads the server, and its first run also provides linux64/steamclient.so, which the server signs in to
# Steam with. Archive installs need it for that too.
install_steamcmd() {
  if [ ! -x "$STEAMCMD" ]; then
    log "Installing SteamCMD into $STEAMCMD_DIR"
    mkdir -p "$STEAMCMD_DIR"
    curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar -xz -C "$STEAMCMD_DIR"
  fi
  if [ ! -f "$STEAMCMD_DIR/linux64/steamclient.so" ]; then
    log "Running SteamCMD once to get steamclient.so"
    "$STEAMCMD" +quit < /dev/null > /dev/null 2>&1 || true
  fi
}

# Returns 0 only when SteamCMD reports the app installed or already up to date. SteamCMD's own exit code is not reliable.
# The commands go through a script file only this user can read, so a branch password never shows in a process list.
update_server() {
  local update="app_update $APP_ID" password=""
  if [ -n "${STEAM_BRANCH:-}" ] && [ "$STEAM_BRANCH" != public ]; then
    update+=" -beta $STEAM_BRANCH"
    if [ -s "$BRANCH_PASSWORD_FILE" ]; then
      password=$(cat "$BRANCH_PASSWORD_FILE")
      update+=" -betapassword $password"
    fi
  fi
  [ "${STEAM_VALIDATE:-0}" = 1 ] && update+=" validate"

  local script output
  script=$(mktemp)
  output=$(mktemp)
  printf '%s\n' "force_install_dir $INSTALL_DIR" "login $LOGIN" "$update" quit > "$script"
  log "Updating app $APP_ID, branch ${STEAM_BRANCH:-public}, as $LOGIN"
  "$STEAMCMD" +@sSteamCmdForcePlatformType linux +@NoPromptForPassword 1 +runscript "$script" < /dev/null 2>&1 | while IFS= read -r line; do
    [ -n "$password" ] && line=${line//"$password"/***}
    printf '%s\n' "$line"
  done | tee "$output" || true
  rm -f "$script"
  if grep -Eq "Success! App '$APP_ID' (fully installed|already up to date)" "$output"; then
    rm -f "$output"
    return 0
  fi
  rm -f "$output"
  log "ERROR: SteamCMD did not report app $APP_ID as installed or up to date"
  return 1
}

# The arguments the server needs. Everything else is in the settings files.
server_args() {
  args=(--environment standalone
    --LaunchConfig:WorldName="${WORLD_NAME:?WORLD_NAME is required}"
    --LaunchConfig:SinglePlayerMode=false
    --LaunchConfig:DataRoot=/data)
}

run_server() {
  if [ "${SERVER_SOURCE:-steam}" = archive ]; then
    if [ ! -x "$INSTALL_DIR/Raptor.Game" ]; then
      log "ERROR: SERVER_SOURCE is archive but no server is installed in $INSTALL_DIR. Run install.sh with --archive again"
      exit 1
    fi
    log "Installed from a release archive, so no Steam update"
  elif ! update_server; then
    if [ -x "$INSTALL_DIR/Raptor.Game" ]; then
      log "WARNING: the Steam update failed, so the server already installed starts instead"
    else
      log "ERROR: the Steam update failed and no server is installed"
      exit 1
    fi
  fi

  # Steam's game server API loads the 64-bit steamclient.so from ~/.steam/sdk64.
  if [ ! -f "$STEAMCMD_DIR/linux64/steamclient.so" ]; then
    log "ERROR: SteamCMD did not provide linux64/steamclient.so, so the server cannot connect to Steam"
    exit 1
  fi
  mkdir -p /steam/.steam/sdk64
  ln -sf "$STEAMCMD_DIR/linux64/steamclient.so" /steam/.steam/sdk64/steamclient.so

  cd "$INSTALL_DIR"
  [ -f version.json ] && log "Server build: $(tr -d '\n' < version.json | head -c 400)"
  server_args
  export DOTNET_ENVIRONMENT=standalone
  exec ./Raptor.Game "${args[@]}" "$@"
}

command="${1:-run}"
[ $# -gt 0 ] && shift
case "$command" in
  run) install_steamcmd; run_server "$@" ;;
  update)
    if [ "${SERVER_SOURCE:-steam}" = archive ]; then
      log "This server was installed from a release archive. Run install.sh with a newer --archive to update it"
      exit 1
    fi
    install_steamcmd; update_server ;;
  login) install_steamcmd; exec "$STEAMCMD" +login "${STEAM_USERNAME:?STEAM_USERNAME is required}" +quit ;;
  *) exec "$command" "$@" ;;
esac
