#!/bin/bash
set -u

# Everlast Dedicated Server installer for Apple Silicon Macs.
# Pre-release Steam installs can use EVERLAST_STEAM_LOGIN, EVERLAST_STEAM_BRANCH,
# and EVERLAST_STEAM_BRANCH_PASSWORD. The password is never saved by this script.
# Guide: https://github.com/In-Spades/everlast-dedicated-server

STEAM_APP_ID=4268160
STEAMCMD_URL="https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz"
DEFAULT_INSTALL="$HOME/EverlastServer"
# Run from an install folder (to change settings or uninstall), that install is the default.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
[ -f "$SCRIPT_DIR/install.conf" ] && DEFAULT_INSTALL=$SCRIPT_DIR
DEFAULT_DATA="$HOME/Library/Application Support/Everlast Dedicated Server"
DOMAIN="gui/$(id -u)"
YES=no
UNINSTALL=no
ARCHIVE=""
STEAM=no

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

usage() {
cat <<'EOF'
Usage: install.sh [options]

Installs and configures an Everlast Dedicated Server on an Apple Silicon Mac.
Every option is prompted unless it is passed here or --yes is used.

  --install-dir PATH       Install folder
  --data-dir PATH          Data folder for worlds and settings
  --world NAME             World folder name
  --server-name NAME       Name shown in the server browser
  --port PORT              UDP game port
  --max-players NUMBER     Maximum players from 1 to 1000
  --password PASSWORD      Join password
  --admins IDS             Comma-separated SteamID64 admin IDs
  --difficulty VALUE       Hylic, Psychic, Pneumonic, Pyrrhic, Sufferer, or OneShot
  --world-display-name NAME
  --description TEXT       Server browser description, at most 120 characters
  --pvp yes|no
  --death-penalty shop|keep
  --xp-rate NUMBER         Multiplier from 0.1 to 10
  --gather-rate NUMBER     Multiplier from 0.1 to 10
  --loot-rate NUMBER       Multiplier from 0.1 to 10
  --max-characters NUMBER  Characters per Steam account from 1 to 100
  --transfers yes|no
  --max-import-level NUMBER
  --strip-gear yes|no
  --import-allowlist IDS   Comma-separated SteamID64 IDs
  --service yes|no         Start at login and keep running
  --firewall yes|no        Add the server to the macOS application firewall
  --archive FILE           Install from an osx-arm64 release archive
  --steam                  Switch this install to Steam downloads
  --yes                    Accept defaults for options not passed
  --uninstall              Remove services and the install folder
  --help                    Show this help
EOF
}

# Mark flag values separately so an explicitly empty value is still respected.
for key in INSTALL_DIR DATA_DIR WORLD SERVER_NAME PORT MAX_PLAYERS PASSWORD ADMINS DIFFICULTY WORLD_DISPLAY_NAME DESCRIPTION PVP DEATH_PENALTY XP_RATE GATHER_RATE LOOT_RATE MAX_CHARACTERS TRANSFERS MAX_IMPORT_LEVEL STRIP_GEAR IMPORT_ALLOWLIST SERVICE FIREWALL; do
    eval "${key}_SET=no"
done

need_value() { [ "$#" -ge 2 ] || fail "$1 needs a value."; }
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help) usage; exit 0 ;;
        --yes) YES=yes; shift ;;
        --uninstall) UNINSTALL=yes; shift ;;
        --archive) need_value "$@"; ARCHIVE=$2; shift 2 ;;
        --steam) STEAM=yes; shift ;;
        --install-dir) need_value "$@"; INSTALL_DIR=$2; INSTALL_DIR_SET=yes; shift 2 ;;
        --data-dir) need_value "$@"; DATA_DIR=$2; DATA_DIR_SET=yes; shift 2 ;;
        --world) need_value "$@"; WORLD=$2; WORLD_SET=yes; shift 2 ;;
        --server-name) need_value "$@"; SERVER_NAME=$2; SERVER_NAME_SET=yes; shift 2 ;;
        --port) need_value "$@"; PORT=$2; PORT_SET=yes; shift 2 ;;
        --max-players) need_value "$@"; MAX_PLAYERS=$2; MAX_PLAYERS_SET=yes; shift 2 ;;
        --password) need_value "$@"; PASSWORD=$2; PASSWORD_SET=yes; shift 2 ;;
        --admins) need_value "$@"; ADMINS=$2; ADMINS_SET=yes; shift 2 ;;
        --difficulty) need_value "$@"; DIFFICULTY=$2; DIFFICULTY_SET=yes; shift 2 ;;
        --world-display-name) need_value "$@"; WORLD_DISPLAY_NAME=$2; WORLD_DISPLAY_NAME_SET=yes; shift 2 ;;
        --description) need_value "$@"; DESCRIPTION=$2; DESCRIPTION_SET=yes; shift 2 ;;
        --pvp) need_value "$@"; PVP=$2; PVP_SET=yes; shift 2 ;;
        --death-penalty) need_value "$@"; DEATH_PENALTY=$2; DEATH_PENALTY_SET=yes; shift 2 ;;
        --xp-rate) need_value "$@"; XP_RATE=$2; XP_RATE_SET=yes; shift 2 ;;
        --gather-rate) need_value "$@"; GATHER_RATE=$2; GATHER_RATE_SET=yes; shift 2 ;;
        --loot-rate) need_value "$@"; LOOT_RATE=$2; LOOT_RATE_SET=yes; shift 2 ;;
        --max-characters) need_value "$@"; MAX_CHARACTERS=$2; MAX_CHARACTERS_SET=yes; shift 2 ;;
        --transfers) need_value "$@"; TRANSFERS=$2; TRANSFERS_SET=yes; shift 2 ;;
        --max-import-level) need_value "$@"; MAX_IMPORT_LEVEL=$2; MAX_IMPORT_LEVEL_SET=yes; shift 2 ;;
        --strip-gear) need_value "$@"; STRIP_GEAR=$2; STRIP_GEAR_SET=yes; shift 2 ;;
        --import-allowlist) need_value "$@"; IMPORT_ALLOWLIST=$2; IMPORT_ALLOWLIST_SET=yes; shift 2 ;;
        --service) need_value "$@"; SERVICE=$2; SERVICE_SET=yes; shift 2 ;;
        --firewall) need_value "$@"; FIREWALL=$2; FIREWALL_SET=yes; shift 2 ;;
        *) fail "Unknown option: $1. Run with --help to see all options." ;;
    esac
done
[ -n "$ARCHIVE" ] && [ "$STEAM" = yes ] && fail "Use either --archive or --steam, not both."

[ "$(uname -s)" = Darwin ] || fail "This installer only runs on macOS."
[ "$(uname -m)" = arm64 ] || fail "This installer needs an Apple Silicon arm64 Mac."
command_exists curl || fail "curl is required to download SteamCMD."
command_exists plutil || fail "plutil is required to read settings."
command_exists launchctl || fail "launchctl is required to manage the server."
command_exists osascript || fail "osascript is required to update JSON settings."

prompt_value() {
    pv_name=$1; pv_label=$2; pv_default=$3
    # Remembered so a re-ask after a bad answer shows the same question and default.
    eval "${pv_name}_LABEL=\$pv_label; ${pv_name}_DEFAULT=\$pv_default"
    eval "pv_set=\$${pv_name}_SET"
    [ "$pv_set" = yes ] && return
    if [ "$YES" = yes ]; then eval "$pv_name=\$pv_default"; return; fi
    printf '%s [%s]: ' "$pv_label" "$pv_default"
    IFS= read -r pv_answer || fail "Input ended while reading $pv_label."
    [ -n "$pv_answer" ] || pv_answer=$pv_default
    eval "$pv_name=\$pv_answer"
}

prompt_secret() {
    ps_name=$1; ps_label=$2; ps_default=$3
    eval "ps_set=\$${ps_name}_SET"
    [ "$ps_set" = yes ] && return
    if [ "$YES" = yes ]; then eval "$ps_name=\$ps_default"; return; fi
    if [ -n "$ps_default" ]; then ps_hint=set; else ps_hint=empty; fi
    printf '%s [%s]: ' "$ps_label" "$ps_hint"
    if [ -t 0 ]; then stty -echo; fi
    IFS= read -r ps_answer || { if [ -t 0 ]; then stty echo; fi; fail "Input ended while reading $ps_label."; }
    if [ -t 0 ]; then stty echo; fi
    printf '\n'
    [ -n "$ps_answer" ] || ps_answer=$ps_default
    eval "$ps_name=\$ps_answer"
}

json_get() {
    jg_file=$1; jg_key=$2; jg_default=$3
    if [ -f "$jg_file" ]; then
        jg_value=$(plutil -extract "$jg_key" raw -o - "$jg_file" 2>/dev/null) && { printf '%s' "$jg_value"; return; }
    fi
    printf '%s' "$jg_default"
}

validate_yes_no() { [ "$1" = yes ] || [ "$1" = no ]; }
validate_port() { case "$1" in ''|*[!0-9]*) return 1;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
validate_uint_range() { case "$1" in ''|*[!0-9]*) return 1;; esac; [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }
validate_rate() { awk 'BEGIN { exit !(ARGV[1] ~ /^[0-9]+([.][0-9]+)?$/ && ARGV[1] >= 0.1 && ARGV[1] <= 10) }' "$1"; }
validate_ids() {
    [ -z "$1" ] && return 0
    oldifs=$IFS; IFS=,
    for id in $1; do case "$id" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;; *) IFS=$oldifs; return 1;; esac; done
    IFS=$oldifs
}
validate_world() { case "$1" in ''|*[!A-Za-z0-9_-]*) return 1;; esac; [ ${#1} -le 32 ]; }
validate_server_name() { [ ${#1} -ge 1 ] && [ ${#1} -le 64 ]; }
validate_nonempty() { [ ${#1} -ge 1 ]; }
validate_description() { [ ${#1} -le 120 ]; }
validate_difficulty() { case "$1" in Hylic|Psychic|Pneumonic|Pyrrhic|Sufferer|OneShot) return 0;; *) return 1;; esac; }
validate_death_penalty() { [ "$1" = shop ] || [ "$1" = keep ]; }
validate_uint() { case "$1" in ''|*[!0-9]*) return 1;; esac; }
validate_json_file() {
    vjf_file=$1
    [ ! -f "$vjf_file" ] && return
    SETTINGS_FILE=$vjf_file osascript -l JavaScript <<'JXA' >/dev/null 2>&1 || fail "Existing JSON is invalid: $vjf_file"
ObjC.import('Foundation');
function env(name) { return ObjC.unwrap($.NSProcessInfo.processInfo.environment.objectForKey(name)); }
var file = env('SETTINGS_FILE');
var text = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(file, $.NSUTF8StringEncoding, null));
var root = JSON.parse(text);
if (!root || typeof root !== 'object' || Array.isArray(root)) throw new Error('JSON root is not an object');
JXA
}
reprompt() {
    rp_name=$1; rp_message=$2; rp_validator=$3; shift 3
    while :; do
        eval "rp_value=\$$rp_name"
        "$rp_validator" "$rp_value" "$@" && return
        [ "$YES" = yes ] && fail "$rp_message"
        info "$rp_message"
        eval "${rp_name}_SET=no"
        eval "rp_label=\${${rp_name}_LABEL-}; rp_default=\${${rp_name}_DEFAULT-}"
        prompt_value "$rp_name" "$rp_label" "$rp_default"
    done
}
canonical_path() {
    cp_path=${1/#\~/$HOME}
    cp_parent=$(dirname "$cp_path")
    cp_base=$(basename "$cp_path")
    if [ -d "$cp_parent" ]; then cp_parent=$(cd "$cp_parent" 2>/dev/null && pwd -P) || return 1; fi
    printf '%s/%s' "${cp_parent%/}" "$cp_base"
}
path_inside() {
    pi_child=$(canonical_path "$1") || return 1
    pi_parent=$(canonical_path "$2") || return 1
    [ "$pi_child" = "$pi_parent" ] || case "$pi_child" in "$pi_parent"/*) return 0;; *) return 1;; esac
}
validate_data_dir() { ! path_inside "$1" "$INSTALL_DIR"; }

stop_launch_agent() {
    sla_domain=$1; sla_label=$2
    launchctl bootout "$sla_domain/$sla_label" >/dev/null 2>&1 || true
    sla_waited=0
    while launchctl print "$sla_domain/$sla_label" >/dev/null 2>&1 && [ "$sla_waited" -lt 190 ]; do
        sleep 1
        sla_waited=$((sla_waited + 1))
    done
    launchctl print "$sla_domain/$sla_label" >/dev/null 2>&1 && fail "$sla_label did not stop within 190 seconds."
}

prompt_value INSTALL_DIR "Install folder" "$DEFAULT_INSTALL"
INSTALL_DIR=${INSTALL_DIR/#\~/$HOME}
INSTALL_RECORD="$INSTALL_DIR/install.conf"
EXISTING_SOURCE=""
record_login=anonymous
record_branch=public
if [ -f "$INSTALL_RECORD" ]; then
    record_archive=$(plutil -extract ArchiveMode raw -o - "$INSTALL_RECORD" 2>/dev/null) || fail "Could not read ArchiveMode from $INSTALL_RECORD."
    record_data=$(plutil -extract DataDir raw -o - "$INSTALL_RECORD" 2>/dev/null) || fail "Could not read DataDir from $INSTALL_RECORD."
    record_world=$(plutil -extract World raw -o - "$INSTALL_RECORD" 2>/dev/null) || fail "Could not read World from $INSTALL_RECORD."
    record_login=$(plutil -extract SteamLogin raw -o - "$INSTALL_RECORD" 2>/dev/null) || fail "Could not read SteamLogin from $INSTALL_RECORD."
    record_branch=$(plutil -extract SteamBranch raw -o - "$INSTALL_RECORD" 2>/dev/null) || fail "Could not read SteamBranch from $INSTALL_RECORD."
    [ "$DATA_DIR_SET" = yes ] || DEFAULT_DATA=$record_data
    if [ "$record_archive" = true ]; then EXISTING_SOURCE=archive; else EXISTING_SOURCE=steam; fi
fi

if [ -n "$ARCHIVE" ]; then
    SOURCE_MODE=archive-install
elif [ "$STEAM" = yes ]; then
    SOURCE_MODE=steam
elif [ "$EXISTING_SOURCE" = archive ]; then
    SOURCE_MODE=archive-reuse
elif [ "$EXISTING_SOURCE" = steam ]; then
    SOURCE_MODE=steam
else
    SOURCE_MODE=steam
fi

if [ "$UNINSTALL" = yes ]; then
    [ -f "$INSTALL_DIR/install.conf" ] || fail "No Everlast install record exists at $INSTALL_DIR/install.conf."
    DATA_DIR=$(plutil -extract DataDir raw -o - "$INSTALL_DIR/install.conf" 2>/dev/null || true)
    if path_inside "$DATA_DIR" "$INSTALL_DIR"; then
        fail "The recorded data folder is inside the install folder. Move it outside $INSTALL_DIR before uninstalling. Nothing was removed."
    fi
    WORLD=$(plutil -extract World raw -o - "$INSTALL_DIR/install.conf" 2>/dev/null || true)
    WORLD_LOWER=$(printf '%s' "$WORLD" | tr '[:upper:]' '[:lower:]')
    SERVER_LABEL="net.inspades.everlast.$WORLD_LOWER.server"
    stop_launch_agent "$DOMAIN" "$SERVER_LABEL"
    rm -f "$HOME/Library/LaunchAgents/$SERVER_LABEL.plist"
    rm -rf "$INSTALL_DIR"
    info "Removed the services and $INSTALL_DIR."
    delete_data=no
    if [ "$YES" != yes ]; then
        printf 'Delete the world data too? [no]: '
        IFS= read -r delete_data || delete_data=no
        [ -n "$delete_data" ] || delete_data=no
    fi
    if [ "$delete_data" = yes ]; then
        rm -rf "$DATA_DIR/Worlds"
        rm -f "$DATA_DIR/appsettings.json"
        if rmdir "$DATA_DIR" 2>/dev/null; then info "Removed the owned world data and the empty folder $DATA_DIR."; else info "Removed the owned world data. Kept $DATA_DIR because it contains other files."; fi
    else
        info "Kept world data at $DATA_DIR."
    fi
    exit 0
fi

if [ ! -d "$INSTALL_DIR" ]; then
    available_kb=$(df -Pk "$(dirname "$INSTALL_DIR")" 2>/dev/null | awk 'NR==2 { print $4 }')
    [ -n "$available_kb" ] || available_kb=0
    [ "$available_kb" -ge 6291456 ] || fail "The install disk needs about 6 GB free."
fi

info ""
info "Install"
prompt_value DATA_DIR "Data folder for worlds and settings" "$DEFAULT_DATA"
DATA_DIR=${DATA_DIR/#\~/$HOME}
reprompt DATA_DIR "Data folder must be outside the install folder so uninstall cannot remove worlds." validate_data_dir
prompt_value WORLD "World folder name" "${record_world-Dedicated}"
reprompt WORLD "World folder name must contain only letters, digits, - and _, with at most 32 characters." validate_world

WORLD_FILE="$DATA_DIR/Worlds/$WORLD/worldsettings.json"
APP_FILE="$DATA_DIR/appsettings.json"
EXISTING_WORLD=no
[ -f "$WORLD_FILE" ] && EXISTING_WORLD=yes
validate_json_file "$APP_FILE"
validate_json_file "$WORLD_FILE"

server_name_default=$(json_get "$APP_FILE" NetworkConfig.Name "Everlast Dedicated Server")
port_default=$(json_get "$APP_FILE" NetworkConfig.Port 9003)

info ""
info "Server"
prompt_value SERVER_NAME "Server name shown in the server browser" "$server_name_default"
reprompt SERVER_NAME "Server name must be 1 to 64 characters." validate_server_name
prompt_value PORT "Game port (UDP)" "$port_default"
reprompt PORT "Game port must be a number from 1 to 65535." validate_port
QUERY_PORT=$((27016 + PORT % 5))
info "The query port is $QUERY_PORT UDP."
prompt_value MAX_PLAYERS "Max players online at once" "$(json_get "$WORLD_FILE" MaxPlayers 100)"
reprompt MAX_PLAYERS "Max players must be a number from 1 to 1000." validate_uint_range 1 1000
prompt_secret PASSWORD "Join password, empty means anyone can join" "$(json_get "$WORLD_FILE" ServerPassword "")"

info ""
info "Access"
prompt_value ADMINS "Admin Steam IDs for in-game admin commands, comma separated" "$(json_get "$WORLD_FILE" Admins "")"
reprompt ADMINS "Admin IDs must be 17-digit SteamID64 values separated by commas." validate_ids

info ""
info "World"
if [ "$EXISTING_WORLD" = yes ]; then
    DIFFICULTY=$(json_get "$WORLD_FILE" Difficulty Psychic)
    info "Difficulty is $DIFFICULTY. It cannot change after a world is created."
else
    info "Hylic: A forgiving world for exploring at your own pace."
    info "Psychic (Standard): The intended experience. Other difficulties are measured against it."
    info "Pneumonic: Fiercer fights, faster progress."
    info "Pyrrhic: Rich rewards, ruinous deaths."
    info "The Sufferer: Brutal and unforgiving. What death takes, it keeps."
    info "One Shot: One life. When you die, your story ends."
    info "Difficulty can never change after this world is created."
    prompt_value DIFFICULTY "Difficulty" Psychic
    reprompt DIFFICULTY "Difficulty must be Hylic, Psychic, Pneumonic, Pyrrhic, Sufferer, or OneShot." validate_difficulty
fi
prompt_value WORLD_DISPLAY_NAME "World name players see" "$(json_get "$WORLD_FILE" DisplayName "$WORLD")"
reprompt WORLD_DISPLAY_NAME "World display name cannot be empty." validate_nonempty
prompt_value DESCRIPTION "Short description for the server browser" "$(json_get "$WORLD_FILE" Description "")"
reprompt DESCRIPTION "Description must be at most 120 characters." validate_description

info ""
info "Gameplay"
pvp_default=$(json_get "$WORLD_FILE" PvPEnabled true); [ "$pvp_default" = true ] && pvp_default=yes || pvp_default=no
prompt_value PVP "Players can attack each other (yes or no)" "$pvp_default"
reprompt PVP "PvP must be yes or no." validate_yes_no
death_default=$(json_get "$WORLD_FILE" DeathPenalty DeathContainer); [ "$death_default" = KeepInventory ] && death_default=keep || death_default=shop
prompt_value DEATH_PENALTY "Death penalty, shop or keep. Some difficulties decide this themselves" "$death_default"
reprompt DEATH_PENALTY "Death penalty must be shop or keep." validate_death_penalty
prompt_value XP_RATE "XP multiplier from 0.1 to 10" "$(json_get "$WORLD_FILE" XpRate 1)"
reprompt XP_RATE "XP multiplier must be a number from 0.1 to 10." validate_rate
prompt_value GATHER_RATE "Gather multiplier from 0.1 to 10" "$(json_get "$WORLD_FILE" GatherRate 1)"
reprompt GATHER_RATE "Gather multiplier must be a number from 0.1 to 10." validate_rate
prompt_value LOOT_RATE "Loot multiplier from 0.1 to 10" "$(json_get "$WORLD_FILE" LootRate 1)"
reprompt LOOT_RATE "Loot multiplier must be a number from 0.1 to 10." validate_rate

info ""
info "Characters"
prompt_value MAX_CHARACTERS "Characters per Steam account" "$(json_get "$WORLD_FILE" MaxCharactersPerUser 10)"
reprompt MAX_CHARACTERS "Characters must be a number from 1 to 100." validate_uint_range 1 100
transfers_default=$(json_get "$WORLD_FILE" AcceptsTransfers false); [ "$transfers_default" = true ] && transfers_default=yes || transfers_default=no
prompt_value TRANSFERS "Accept characters from other worlds (yes or no)" "$transfers_default"
reprompt TRANSFERS "Transfers must be yes or no." validate_yes_no
prompt_value MAX_IMPORT_LEVEL "Highest import level, 0 means any" "$(json_get "$WORLD_FILE" MaxImportLevel 0)"
reprompt MAX_IMPORT_LEVEL "Max import level must be zero or a positive whole number." validate_uint
strip_default=$(json_get "$WORLD_FILE" StripGearOnImport false); [ "$strip_default" = true ] && strip_default=yes || strip_default=no
prompt_value STRIP_GEAR "Remove gear from arriving characters (yes or no)" "$strip_default"
reprompt STRIP_GEAR "Strip gear must be yes or no." validate_yes_no
prompt_value IMPORT_ALLOWLIST "Steam IDs allowed to import, empty means everyone" "$(json_get "$WORLD_FILE" ImportAllowlist "")"
reprompt IMPORT_ALLOWLIST "Import allowlist must contain 17-digit SteamID64 values separated by commas." validate_ids


info ""
info "Running"
prompt_value SERVICE "Start at login and keep running (yes or no)" yes
reprompt SERVICE "Service must be yes or no." validate_yes_no
prompt_value FIREWALL "Open the server in the macOS application firewall (yes or no)" yes
reprompt FIREWALL "Firewall must be yes or no." validate_yes_no

info ""
info "Install summary"
printf 'Install folder: %s\nData folder: %s\nWorld: %s\nServer name: %s\nGame port: %s UDP\nQuery port: %s UDP\nMax players: %s\nPassword: ' "$INSTALL_DIR" "$DATA_DIR" "$WORLD" "$SERVER_NAME" "$PORT" "$QUERY_PORT" "$MAX_PLAYERS"
[ -n "$PASSWORD" ] && info set || info empty
printf 'Admins: %s\nDifficulty: %s\nWorld display name: %s\nDescription: %s\nPvP: %s\nDeath penalty: %s\nXP rate: %s\nGather rate: %s\nLoot rate: %s\nMax characters: %s\nTransfers: %s\nMax import level: %s\nStrip gear: %s\nImport allowlist: %s\nService: %s\nFirewall: %s\n' "$ADMINS" "$DIFFICULTY" "$WORLD_DISPLAY_NAME" "$DESCRIPTION" "$PVP" "$DEATH_PENALTY" "$XP_RATE" "$GATHER_RATE" "$LOOT_RATE" "$MAX_CHARACTERS" "$TRANSFERS" "$MAX_IMPORT_LEVEL" "$STRIP_GEAR" "$IMPORT_ALLOWLIST" "$SERVICE" "$FIREWALL"
if [ "$YES" != yes ]; then
    printf 'Continue with the install? [yes]: '
    IFS= read -r proceed || fail "Input ended before confirmation."
    [ -n "$proceed" ] || proceed=yes
    [ "$proceed" = yes ] || { info "Install cancelled."; exit 0; }
fi

WORLD_LOWER=$(printf '%s' "$WORLD" | tr '[:upper:]' '[:lower:]')
SERVER_LABEL="net.inspades.everlast.$WORLD_LOWER.server"
stop_launch_agent "$DOMAIN" "$SERVER_LABEL"

mkdir -p "$INSTALL_DIR/server" "$INSTALL_DIR/logs" "$DATA_DIR/Worlds/$WORLD" "$HOME/Library/LaunchAgents"

# SteamCMD is needed in both modes: it downloads the server, and its first run
# puts steamclient.dylib, the library the server signs in to Steam with, in its folder.
mkdir -p "$INSTALL_DIR/steamcmd"
if [ ! -x "$INSTALL_DIR/steamcmd/steamcmd.sh" ]; then
    curl -fL "$STEAMCMD_URL" -o "$INSTALL_DIR/steamcmd/steamcmd_osx.tar.gz" || fail "Could not download SteamCMD from $STEAMCMD_URL."
    tar -xzf "$INSTALL_DIR/steamcmd/steamcmd_osx.tar.gz" -C "$INSTALL_DIR/steamcmd" || fail "Could not extract SteamCMD."
    rm -f "$INSTALL_DIR/steamcmd/steamcmd_osx.tar.gz"
fi

if [ "$SOURCE_MODE" = archive-install ]; then
    [ -f "$ARCHIVE" ] || fail "Archive does not exist: $ARCHIVE"
    case "$ARCHIVE" in *.tar.gz|*.tgz) tar -xzf "$ARCHIVE" -C "$INSTALL_DIR/server" || fail "Could not extract $ARCHIVE.";; *) fail "The macOS archive must be a .tar.gz or .tgz file.";; esac
    xattr -dr com.apple.quarantine "$INSTALL_DIR" 2>/dev/null || true
    ARCHIVE_MODE=true
    "$INSTALL_DIR/steamcmd/steamcmd.sh" +quit >"$INSTALL_DIR/logs/steamcmd-install.log" 2>&1 || info "SteamCMD reported an error on its first run. See $INSTALL_DIR/logs/steamcmd-install.log."
elif [ "$SOURCE_MODE" = archive-reuse ]; then
    ARCHIVE_MODE=true
    info "Kept the installed archive server. Use --steam to switch this install to Steam downloads."
    "$INSTALL_DIR/steamcmd/steamcmd.sh" +quit >"$INSTALL_DIR/logs/steamcmd-install.log" 2>&1 || info "SteamCMD reported an error. See $INSTALL_DIR/logs/steamcmd-install.log."
else
    ARCHIVE_MODE=false
    steam_login=${EVERLAST_STEAM_LOGIN:-$record_login}
    steam_branch=${EVERLAST_STEAM_BRANCH:-$record_branch}
    steam_password=${EVERLAST_STEAM_BRANCH_PASSWORD:-}
    password_file="$INSTALL_DIR/steam-branch-password"
    if [ "$steam_branch" = public ]; then
        rm -f "$password_file"
        steam_password=""
    elif [ -n "$steam_password" ]; then
        umask 077
        printf '%s' "$steam_password" > "$password_file" || fail "Could not save the Steam branch password."
        chmod 600 "$password_file"
    elif [ -f "$password_file" ]; then
        steam_password=$(cat "$password_file")
    fi
    if [ "$steam_login" != anonymous ]; then "$INSTALL_DIR/steamcmd/steamcmd.sh" +login "$steam_login" +quit || fail "Steam login failed for $steam_login."; fi
    steam_log="$INSTALL_DIR/logs/steamcmd-install.log"
    umask 077
    steam_script=$(mktemp "$INSTALL_DIR/steamcmd/install.XXXXXX") || fail "Could not create a private SteamCMD script."
    awk -v dir="$INSTALL_DIR/server" -v login="$steam_login" -v app="$STEAM_APP_ID" -v branch="$steam_branch" -v secretfile="$password_file" 'BEGIN {
        quote=sprintf("%c",34); secret=""; if ((getline secret < secretfile) < 0) secret=""; close(secretfile)
        printf "force_install_dir %s%s%s\nlogin %s%s%s\napp_update %s", quote, dir, quote, quote, login, quote, app
        if (branch != "public") { printf " -beta %s%s%s", quote, branch, quote; if (secret != "") printf " -betapassword %s%s%s", quote, secret, quote }
        printf " validate\nquit\n"
    }' > "$steam_script"
    steam_raw=$(mktemp "$INSTALL_DIR/logs/steamcmd-install.XXXXXX") || { rm -f "$steam_script"; fail "Could not create a private SteamCMD log."; }
    "$INSTALL_DIR/steamcmd/steamcmd.sh" +@sSteamCmdForcePlatformType macos +runscript "$steam_script" +quit > "$steam_raw" 2>&1 || true
    rm -f "$steam_script"
    # Literal replacement: gsub would read the password as a regular expression.
    awk -v secretfile="$password_file" 'BEGIN { if ((getline secret < secretfile) < 0) secret=""; close(secretfile) } { if (secret != "") { out=""; while ((i = index($0, secret)) > 0) { out = out substr($0, 1, i - 1) "***"; $0 = substr($0, i + length(secret)) } $0 = out $0 } print }' "$steam_raw" | tee "$steam_log"
    rm -f "$steam_raw"
    /usr/bin/grep -Eq "Success! App '$STEAM_APP_ID' (fully installed|already up to date)" "$steam_log" || fail "Steam could not download Everlast Dedicated Server. The app may not be released yet. Use --archive with an osx-arm64 release archive, or wait for its Steam release."
fi
[ -x "$INSTALL_DIR/server/Raptor.Game" ] || fail "Raptor.Game is missing or not executable after installation."

# The server loads steamclient.dylib from its own folder when the Steam client is not running. It must be a link to
# SteamCMD's copy: a copy fails to load, because the library loads its neighbours (libtier0_s.dylib, libvstdlib_s.dylib,
# Frameworks/Breakpad.framework and others) from the folder it really lives in.
steamclient="$INSTALL_DIR/steamcmd/steamclient.dylib"
[ -f "$steamclient" ] || steamclient=$(find "$INSTALL_DIR/steamcmd" -type f -name steamclient.dylib 2>/dev/null | awk 'NR==1 { print; exit }')
[ -n "$steamclient" ] || fail "SteamCMD did not provide steamclient.dylib, which the server needs to connect to Steam. See $INSTALL_DIR/logs/steamcmd-install.log, then run the installer again."
ln -sf "$steamclient" "$INSTALL_DIR/server/steamclient.dylib" || fail "Could not link $steamclient next to the server."
if [ "$ARCHIVE_MODE" = true ]; then
    steam_login=${EVERLAST_STEAM_LOGIN:-$record_login}
    steam_branch=${EVERLAST_STEAM_BRANCH:-$record_branch}
fi
[ "$0" -ef "$INSTALL_DIR/install.sh" ] || cp "$0" "$INSTALL_DIR/install.sh" || fail "Could not copy install.sh into $INSTALL_DIR."
chmod +x "$INSTALL_DIR/install.sh"

json_escape() {
    # Shell variables cannot hold NUL. Escape every other JSON control character.
    printf '%s' "$1" | awk 'BEGIN { ORS="" } { if (NR > 1) printf "\\n"; for (i=1;i<=length($0);i++) { c=substr($0,i,1); if (c=="\\") printf "\\\\"; else if (c=="\"") printf "\\\""; else { code=-1; for (j=1;j<32;j++) if (c==sprintf("%c",j)) code=j; if (code==8) printf "\\b"; else if (code==9) printf "\\t"; else if (code==12) printf "\\f"; else if (code==13) printf "\\r"; else if (code>=0) printf "\\u%04x",code; else printf "%s",c } } }'
}
jqstr() { printf '"'; json_escape "$1"; printf '"'; }
[ "$PVP" = yes ] && PVP_JSON=true || PVP_JSON=false
[ "$TRANSFERS" = yes ] && TRANSFERS_JSON=true || TRANSFERS_JSON=false
[ "$STRIP_GEAR" = yes ] && STRIP_JSON=true || STRIP_JSON=false
[ "$DEATH_PENALTY" = keep ] && DEATH_JSON=KeepInventory || DEATH_JSON=DeathContainer
CREATED=$(json_get "$WORLD_FILE" CreatedDate "$(date -u '+%Y-%m-%d %H:%M:%S')")
LAST_PLAYED=$(json_get "$WORLD_FILE" LastPlayedDate "$CREATED")
ORIGIN=$(json_get "$WORLD_FILE" OriginServerId "")

merge_json_settings() {
    SETTINGS_FILE=$APP_FILE SERVER_NAME=$SERVER_NAME PORT=$PORT \
    osascript -l JavaScript <<'JXA' >/dev/null || fail "Could not merge settings into $APP_FILE."
ObjC.import('Foundation');
function env(name) { return ObjC.unwrap($.NSProcessInfo.processInfo.environment.objectForKey(name)); }
function objectOrEmpty(value) { return value && typeof value === 'object' && !Array.isArray(value) ? value : {}; }
var file = env('SETTINGS_FILE');
var root = {};
if ($.NSFileManager.defaultManager.fileExistsAtPath(file)) {
    var text = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(file, $.NSUTF8StringEncoding, null));
    try { root = JSON.parse(text); } catch (error) { throw new Error('Existing JSON is invalid: ' + file); }
    if (!root || typeof root !== 'object' || Array.isArray(root)) throw new Error('Existing JSON root is not an object: ' + file);
}
root.NetworkConfig = objectOrEmpty(root.NetworkConfig);
root.NetworkConfig.Name = env('SERVER_NAME'); root.NetworkConfig.Port = Number(env('PORT'));
var output = JSON.stringify(root, null, 2) + '\n';
if (!$(output).writeToFileAtomicallyEncodingError(file, true, $.NSUTF8StringEncoding, null)) throw new Error('Could not write ' + file);
JXA
}

merge_json_world() {
    SETTINGS_FILE=$WORLD_FILE WORLD_DISPLAY_NAME=$WORLD_DISPLAY_NAME DESCRIPTION=$DESCRIPTION MAX_PLAYERS=$MAX_PLAYERS PVP_JSON=$PVP_JSON XP_RATE=$XP_RATE GATHER_RATE=$GATHER_RATE LOOT_RATE=$LOOT_RATE DEATH_JSON=$DEATH_JSON DIFFICULTY=$DIFFICULTY TRANSFERS_JSON=$TRANSFERS_JSON MAX_CHARACTERS=$MAX_CHARACTERS MAX_IMPORT_LEVEL=$MAX_IMPORT_LEVEL STRIP_JSON=$STRIP_JSON IMPORT_ALLOWLIST=$IMPORT_ALLOWLIST ADMINS=$ADMINS ORIGIN=$ORIGIN PASSWORD=$PASSWORD CREATED=$CREATED LAST_PLAYED=$LAST_PLAYED \
    osascript -l JavaScript <<'JXA' >/dev/null || fail "Could not merge world settings into $WORLD_FILE."
ObjC.import('Foundation');
function env(name) { return ObjC.unwrap($.NSProcessInfo.processInfo.environment.objectForKey(name)); }
var file = env('SETTINGS_FILE');
var root = {};
if ($.NSFileManager.defaultManager.fileExistsAtPath(file)) {
    var text = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(file, $.NSUTF8StringEncoding, null));
    try { root = JSON.parse(text); } catch (error) { throw new Error('Existing JSON is invalid: ' + file); }
    if (!root || typeof root !== 'object' || Array.isArray(root)) throw new Error('Existing JSON root is not an object: ' + file);
}
root.DisplayName=env('WORLD_DISPLAY_NAME'); root.Description=env('DESCRIPTION'); root.MaxPlayers=Number(env('MAX_PLAYERS')); root.PvPEnabled=env('PVP_JSON')==='true';
root.XpRate=Number(env('XP_RATE')); root.GatherRate=Number(env('GATHER_RATE')); root.LootRate=Number(env('LOOT_RATE')); root.DeathPenalty=env('DEATH_JSON'); root.Difficulty=env('DIFFICULTY');
root.AcceptsTransfers=env('TRANSFERS_JSON')==='true'; root.MaxCharactersPerUser=Number(env('MAX_CHARACTERS')); root.MaxImportLevel=Number(env('MAX_IMPORT_LEVEL')); root.StripGearOnImport=env('STRIP_JSON')==='true';
root.ImportAllowlist=env('IMPORT_ALLOWLIST'); root.Admins=env('ADMINS'); root.OriginServerId=env('ORIGIN'); root.ServerPassword=env('PASSWORD'); root.CreatedDate=env('CREATED'); root.LastPlayedDate=env('LAST_PLAYED');
var output = JSON.stringify(root, null, 2) + '\n';
if (!$(output).writeToFileAtomicallyEncodingError(file, true, $.NSUTF8StringEncoding, null)) throw new Error('Could not write ' + file);
JXA
}

merge_json_settings
merge_json_world

cat > "$INSTALL_DIR/install.conf" <<EOF
{
  "InstallDir": $(jqstr "$INSTALL_DIR"),
  "DataDir": $(jqstr "$DATA_DIR"),
  "World": $(jqstr "$WORLD"),
  "ArchiveMode": $ARCHIVE_MODE,
  "SteamLogin": $(jqstr "$steam_login"),
  "SteamBranch": $(jqstr "$steam_branch")
}
EOF
chmod 600 "$INSTALL_DIR/install.conf"

cat > "$INSTALL_DIR/start-server.sh" <<'WRAPPER'
#!/bin/bash
set -u
INSTALL_DIR=$(cd "$(dirname "$0")" && pwd)
DATA_DIR=$(plutil -extract DataDir raw -o - "$INSTALL_DIR/install.conf")
WORLD=$(plutil -extract World raw -o - "$INSTALL_DIR/install.conf")
ARCHIVE_MODE=$(plutil -extract ArchiveMode raw -o - "$INSTALL_DIR/install.conf")
STEAM_LOGIN=$(plutil -extract SteamLogin raw -o - "$INSTALL_DIR/install.conf")
STEAM_BRANCH=$(plutil -extract SteamBranch raw -o - "$INSTALL_DIR/install.conf")
if [ "$ARCHIVE_MODE" = false ]; then
    LOG="$INSTALL_DIR/logs/steamcmd-update.log"
    PASSWORD_FILE="$INSTALL_DIR/steam-branch-password"
    umask 077
    SCRIPT=$(mktemp "$INSTALL_DIR/steamcmd/update.XXXXXX") || exit 1
    RAW=$(mktemp "$INSTALL_DIR/logs/steamcmd-update.XXXXXX") || { rm -f "$SCRIPT"; exit 1; }
    awk -v dir="$INSTALL_DIR/server" -v login="$STEAM_LOGIN" -v branch="$STEAM_BRANCH" -v secretfile="$PASSWORD_FILE" 'BEGIN {
        quote=sprintf("%c",34); secret=""; if ((getline secret < secretfile) < 0) secret=""; close(secretfile)
        printf "force_install_dir %s%s%s\nlogin %s%s%s\napp_update 4268160", quote, dir, quote, quote, login, quote
        if (branch != "public") { printf " -beta %s%s%s", quote, branch, quote; if (secret != "") printf " -betapassword %s%s%s", quote, secret, quote }
        printf "\nquit\n"
    }' > "$SCRIPT"
    "$INSTALL_DIR/steamcmd/steamcmd.sh" +@sSteamCmdForcePlatformType macos +runscript "$SCRIPT" +quit > "$RAW" 2>&1 || true
    rm -f "$SCRIPT"
    awk -v secretfile="$PASSWORD_FILE" 'BEGIN { if ((getline secret < secretfile) < 0) secret=""; close(secretfile) } { if (secret != "") { out=""; while ((i = index($0, secret)) > 0) { out = out substr($0, 1, i - 1) "***"; $0 = substr($0, i + length(secret)) } $0 = out $0 } print }' "$RAW" > "$LOG"
    rm -f "$RAW"
    if ! /usr/bin/grep -Eq "Success! App '4268160' (fully installed|already up to date)" "$LOG"; then
        printf 'Warning: Steam update failed. Starting the installed server. See %s\n' "$LOG"
    fi
fi
cd "$INSTALL_DIR/server" || exit 1
export DOTNET_ENVIRONMENT=standalone
exec ./Raptor.Game --environment standalone "--LaunchConfig:DataRoot=$DATA_DIR" "--LaunchConfig:WorldName=$WORLD" --LaunchConfig:SinglePlayerMode=false
WRAPPER

chmod +x "$INSTALL_DIR/start-server.sh"

xml_escape() { printf '%s' "$1" | awk 'BEGIN { ORS="" } { if (NR>1) printf "&#10;"; gsub(/&/,"\\&amp;"); gsub(/</,"\\&lt;"); gsub(/>/,"\\&gt;"); gsub(/\"/,"\\&quot;"); gsub(/\047/,"\\&apos;"); printf "%s",$0 }'; }
WORLD_LOWER=$(printf '%s' "$WORLD" | tr '[:upper:]' '[:lower:]')
SERVER_LABEL="net.inspades.everlast.$WORLD_LOWER.server"
SERVER_PLIST="$HOME/Library/LaunchAgents/$SERVER_LABEL.plist"
write_plist() {
    wp_file=$1; wp_label=$2; wp_program=$3; wp_log=$4
    {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>\n'
    printf '<key>Label</key><string>'; xml_escape "$wp_label"; printf '</string>\n<key>ProgramArguments</key><array><string>'; xml_escape "$wp_program"; printf '</string></array>\n'
    printf '<key>RunAtLoad</key><true/>\n<key>KeepAlive</key><true/>\n<key>ExitTimeOut</key><integer>180</integer>\n<key>ThrottleInterval</key><integer>10</integer>\n'
    printf '<key>WorkingDirectory</key><string>'; xml_escape "$INSTALL_DIR/server"; printf '</string>\n<key>StandardOutPath</key><string>'; xml_escape "$wp_log"; printf '</string>\n<key>StandardErrorPath</key><string>'; xml_escape "$wp_log"; printf '</string>\n'
    printf '<key>EnvironmentVariables</key><dict><key>DOTNET_ENVIRONMENT</key><string>standalone</string>'
    printf '</dict>\n</dict></plist>\n'
    } > "$wp_file"
    plutil -lint "$wp_file" >/dev/null || fail "Could not create a valid launchd file at $wp_file."
}

if [ "$SERVICE" = yes ]; then
    write_plist "$SERVER_PLIST" "$SERVER_LABEL" "$INSTALL_DIR/start-server.sh" "$INSTALL_DIR/logs/server-launchd.log"
    log_file="$DATA_DIR/Worlds/$WORLD/server.log"
    log_start=$(stat -f %z "$log_file" 2>/dev/null || echo 0)
    launchctl bootstrap "$DOMAIN" "$SERVER_PLIST" || fail "Could not load $SERVER_LABEL with launchd."
else
    rm -f "$SERVER_PLIST"
fi

firewall_state=$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null || true)
case "$firewall_state" in *enabled*)
    if [ "$FIREWALL" = yes ]; then
        sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "$INSTALL_DIR/server/Raptor.Game" || fail "Could not add Raptor.Game to the macOS firewall."
        sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp "$INSTALL_DIR/server/Raptor.Game" || fail "Could not unblock Raptor.Game in the macOS firewall."
        info "Added and unblocked Raptor.Game in the macOS application firewall."
    fi;;
*) info "The macOS application firewall is off. No firewall change is needed.";;
esac


if [ "$SERVICE" = yes ]; then
    info "Starting the server. A Steam install updates first, which can take a few minutes."
    ready=no
    waited=0
    while [ "$waited" -lt 900 ]; do
        size=$(stat -f %z "$log_file" 2>/dev/null || echo 0)
        [ "$size" -lt "$log_start" ] && log_start=0
        if tail -c +"$((log_start + 1))" "$log_file" 2>/dev/null | /usr/bin/grep -q 'SERVER_READY'; then ready=yes; break; fi
        sleep 5
        waited=$((waited + 5))
    done
    if [ "$ready" = yes ]; then
        info "The server is running."
        # Steam lists the server a few seconds after it is ready.
        connected=no
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
            if tail -c +"$((log_start + 1))" "$log_file" | /usr/bin/grep -q 'Connected to Steam master server'; then connected=yes; break; fi
            sleep 2
        done
        if [ "$connected" = yes ]; then
            info "It is connected to Steam, so it shows in the server browser."
        else
            info "It has not connected to Steam after 30 seconds. Check the server log if it does not show in the server browser."
        fi
    else
        info "The server did not report ready within 15 minutes. Its last lines:"
        tail -n 15 "$INSTALL_DIR/logs/server-launchd.log" 2>/dev/null
        info "launchd keeps trying to start it. Stop it with: launchctl bootout $DOMAIN/$SERVER_LABEL"
        exit 1
    fi
fi

info ""
info "Everlast Dedicated Server is installed."
info "Server files: $INSTALL_DIR/server"
info "World data: $DATA_DIR"
info "Forward $PORT UDP and $QUERY_PORT UDP in your router."
info "Logs: $DATA_DIR/Worlds/$WORLD/server.log"
if [ "$SERVICE" = yes ]; then
    info "Stop: launchctl bootout $DOMAIN/$SERVER_LABEL"
    info "Start: launchctl bootstrap $DOMAIN $SERVER_PLIST"
    info "Update: launchctl bootout $DOMAIN/$SERVER_LABEL && launchctl bootstrap $DOMAIN $SERVER_PLIST"
else
    info "Start by hand: $INSTALL_DIR/start-server.sh"
fi
info "Uninstall: $INSTALL_DIR/install.sh --install-dir \"$INSTALL_DIR\" --uninstall"
