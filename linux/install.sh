#!/bin/bash
# Everlast Dedicated Server installer for Linux (x86_64). The server runs in Docker, from the Dockerfile,
# docker-compose.yml and entrypoint.sh next to this script, or downloaded from the guide's repository when they are
# missing, and copied into the install folder.
# Guide: https://github.com/In-Spades/everlast-dedicated-server
# Pre-release Steam installs can use EVERLAST_STEAM_LOGIN, EVERLAST_STEAM_BRANCH and EVERLAST_STEAM_BRANCH_PASSWORD.
# They are remembered in the install folder (the branch password in secrets/, readable only by its owner).
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DOCKER_FILES=(Dockerfile docker-compose.yml entrypoint.sh)
# Where the Docker files come from when they are not next to this script. EVERLAST_REPO_RAW points it at a fork or branch.
REPO_RAW=${EVERLAST_REPO_RAW:-https://raw.githubusercontent.com/In-Spades/everlast-dedicated-server/main/linux}
YES=no
UNINSTALL=no
USE_STEAM=no
ARCHIVE=""

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

if [ "$(id -u)" -eq 0 ]; then
    DEFAULT_INSTALL=/opt/everlast-server
    DEFAULT_DATA=/var/lib/everlast-server
else
    DEFAULT_INSTALL="$HOME/everlast-server"
    DEFAULT_DATA="$HOME/.local/share/everlast-server"
fi

usage() {
cat <<'EOF'
Usage: install.sh [options]

Installs and configures an Everlast Dedicated Server in Docker on a 64-bit Linux machine.
Every option is prompted unless it is passed here or --yes is used. Run it again to change settings.

  --install-dir PATH       Install folder (Docker files, SteamCMD and the server)
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
  --install-docker yes|no  Install Docker when it is missing
  --service yes|no         Start now and keep running, also after a reboot
  --firewall yes|no        Open the ports in ufw or firewalld
  --archive FILE           Install from a linux-x64 release archive instead of Steam
  --steam                  Switch an install from a release archive to Steam downloads
  --yes                    Accept defaults for options not passed
  --uninstall              Remove the containers, the image and the install folder
  --help                   Show this help
EOF
}

OPTIONS=(INSTALL_DIR DATA_DIR WORLD SERVER_NAME PORT MAX_PLAYERS PASSWORD ADMINS DIFFICULTY WORLD_DISPLAY_NAME DESCRIPTION
    PVP DEATH_PENALTY XP_RATE GATHER_RATE LOOT_RATE MAX_CHARACTERS TRANSFERS MAX_IMPORT_LEVEL STRIP_GEAR IMPORT_ALLOWLIST
    INSTALL_DOCKER SERVICE FIREWALL)
declare -A GIVEN=()
need_value() { [ "$#" -ge 2 ] || fail "$1 needs a value."; }
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help) usage; exit 0 ;;
        --yes) YES=yes; shift ;;
        --uninstall) UNINSTALL=yes; shift ;;
        --steam) USE_STEAM=yes; shift ;;
        --archive) need_value "$@"; ARCHIVE=$(realpath -m "$2"); shift 2 ;;
        --*)
            name=${1#--}; name=${name//-/_}; name=${name^^}
            [[ " ${OPTIONS[*]} " == *" $name "* ]] || fail "Unknown option: $1. Run with --help to see all options."
            need_value "$@"
            printf -v "$name" '%s' "$2"
            GIVEN[$name]=1
            shift 2 ;;
        *) fail "Unknown argument: $1. Run with --help to see all options." ;;
    esac
done

[ "$(uname -s)" = Linux ] || fail "This installer only runs on Linux. Use the macOS or Windows installer there."
[ "$(uname -m)" = x86_64 ] || fail "The Everlast server needs a 64-bit x86 (x86_64) machine. This one is $(uname -m)."
command_exists curl || fail "curl is required. Install it with your package manager, then run this again."
command_exists tar || fail "tar is required. Install it with your package manager, then run this again."

# Only package installs, the firewall and (when the user is not in the docker group) Docker need root.
as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"
    elif command_exists sudo; then sudo "$@"
    else fail "This step needs root: $*. Run the installer as root or install sudo."
    fi
}

# ask NAME "Prompt" DEFAULT [VALIDATOR ARGS...]: a passed option is kept, --yes takes the default, a bad answer is asked
# again. The validator gets ARGS then the answer, and prints the reason when it refuses.
ask() {
    local name=$1 label=$2 default=$3 answer message
    shift 3
    if [ -n "${GIVEN[$name]:-}" ]; then
        answer=${!name}
    elif [ "$YES" = yes ]; then
        answer=$default
    else
        read -r -p "$label [$default]: " answer || fail "Input ended while reading: $label"
        [ -n "$answer" ] || answer=$default
    fi
    while [ "$#" -gt 0 ] && ! message=$("$@" "$answer"); do
        if [ "$YES" = yes ] || [ -n "${GIVEN[$name]:-}" ]; then fail "$label: $message"; fi
        info "$message"
        read -r -p "$label [$default]: " answer || fail "Input ended while reading: $label"
        [ -n "$answer" ] || answer=$default
    done
    printf -v "$name" '%s' "$answer"
}

ask_secret() {
    local name=$1 label=$2 default=$3 answer hint=none
    [ -n "${GIVEN[$name]:-}" ] && return
    if [ "$YES" = yes ]; then printf -v "$name" '%s' "$default"; return; fi
    [ -n "$default" ] && hint="Enter keeps the current one"
    read -r -s -p "$label [$hint]: " answer || { echo; fail "Input ended while reading: $label"; }
    echo
    [ -n "$answer" ] || answer=$default
    printf -v "$name" '%s' "$answer"
}

# Validators. Numbers without leading zeros, because the settings files are JSON.
yes_no() { [ "$1" = yes ] || [ "$1" = no ] || { echo "Answer yes or no."; return 1; }; }
port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && [ "$1" -le 65535 ] || { echo "Use a number from 1 to 65535."; return 1; }; }
range() { [[ $3 =~ ^(0|[1-9][0-9]*)$ ]] && [ "$3" -ge "$1" ] && [ "$3" -le "$2" ] || { echo "Use a whole number from $1 to $2."; return 1; }; }
whole() { [[ $1 =~ ^(0|[1-9][0-9]{0,8})$ ]] || { echo "Use 0 or a whole number."; return 1; }; }
rate() { [[ $1 =~ ^(0|[1-9][0-9]*)(\.[0-9]+)?$ ]] && awk -v r="$1" 'BEGIN { exit !(r >= 0.1 && r <= 10) }' || { echo "Use a number from 0.1 to 10, such as 1 or 1.5."; return 1; }; }
steam_ids() { [ -z "$1" ] || [[ $1 =~ ^[0-9]{17}(,[0-9]{17})*$ ]] || { echo "Use 17-digit SteamID64 numbers separated by commas, with no spaces."; return 1; }; }
world_name() { [[ $1 =~ ^[A-Za-z0-9_-]{1,32}$ ]] || { echo "Use 1 to 32 letters, digits, - or _."; return 1; }; }
length() { [ "${#3}" -ge "$1" ] && [ "${#3}" -le "$2" ] || { echo "Use $1 to $2 characters."; return 1; }; }
difficulty() { [[ $1 =~ ^(Hylic|Psychic|Pneumonic|Pyrrhic|Sufferer|OneShot)$ ]] || { echo "Use Hylic, Psychic, Pneumonic, Pyrrhic, Sufferer or OneShot."; return 1; }; }
death() { [ "$1" = shop ] || [ "$1" = keep ] || { echo "Answer shop or keep."; return 1; }; }
plain_path() { [[ -n $1 && $1 != *"'"* && $1 != *$'\n'* ]] || { echo "Use a folder path without ' or line breaks."; return 1; }; }
# Uninstalling removes the install folder, so the worlds must never live inside it.
outside_install() {
    plain_path "$1" || return 1
    local path; path=$(realpath -m "${1/#\~/$HOME}")
    [[ "$path/" != "$INSTALL_DIR/"* ]] || { echo "Choose a data folder outside the install folder $INSTALL_DIR, so uninstalling never removes the worlds."; return 1; }
}

# json_get FILE PATH DEFAULT: the value at a dotted path, or DEFAULT when it is missing or null.
json_get() {
    local value=""
    [ -f "$1" ] && value=$(jq -r --arg p "$2" '(try getpath($p | split(".")) catch null) | if . == null then empty else tostring end' "$1")
    if [ -n "$value" ]; then printf '%s' "$value"; else printf '%s' "$3"; fi
}

# .env values are written in single quotes, which Docker Compose reads literally.
env_get() { [ -f "$INSTALL_DIR/.env" ] && sed -n "s/^$1=//p" "$INSTALL_DIR/.env" | tail -n 1 | sed "s/^'\(.*\)'\$/\1/"; }
env_line() { printf "%s='%s'\n" "$1" "$2"; }

# jq for the settings files, Docker (with the user's consent) to run the server.
ensure_tools() {
    if ! command_exists jq; then
        info "Installing jq, which this installer uses to edit the settings files."
        if command_exists apt-get; then as_root apt-get update -qq >/dev/null && as_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install -y -qq jq >/dev/null
        elif command_exists dnf; then as_root dnf install -y -q jq
        elif command_exists yum; then as_root yum install -y -q jq
        elif command_exists zypper; then as_root zypper --non-interactive install jq
        elif command_exists pacman; then as_root pacman -S --noconfirm jq
        elif command_exists apk; then as_root apk add jq
        fi
        command_exists jq || fail "Could not install jq. Install it with your package manager, then run this again."
    fi
    if ! command_exists docker; then
        ask INSTALL_DOCKER "Docker is not installed. Install it now with Docker's official script (yes or no)" yes yes_no
        [ "$INSTALL_DOCKER" = yes ] || fail "The server runs in Docker. Install Docker, then run this again."
        curl -fsSL https://get.docker.com | as_root sh || fail "Docker's install script failed. See its output above."
    fi
    command_exists systemctl && as_root systemctl enable --now docker >/dev/null 2>&1
    if docker info >/dev/null 2>&1; then DOCKER=(docker)
    else
        as_root docker info >/dev/null 2>&1 || fail "Docker is installed but not running. Start it (systemctl start docker), then run this again."
        DOCKER=(as_root docker)
    fi
    "${DOCKER[@]}" compose version >/dev/null 2>&1 || fail "Docker Compose is missing. Install the docker-compose-plugin package, then run this again."
}

compose() { (cd "$INSTALL_DIR" && "${DOCKER[@]}" compose "$@"); }

firewall_tool() {
    if command_exists ufw && as_root ufw status 2>/dev/null | grep -q 'Status: active'; then echo ufw
    elif command_exists firewall-cmd && as_root firewall-cmd --state >/dev/null 2>&1; then echo firewalld
    else echo none; fi
}

# firewall add|remove TOOL "PORT/PROTO ..."
firewall() {
    local action=$1 tool=$2 rule
    for rule in $3; do
        case "$tool:$action" in
            ufw:add) as_root ufw allow "$rule" comment "Everlast server" >/dev/null ;;
            ufw:remove) as_root ufw delete allow "$rule" >/dev/null 2>&1 ;;
            firewalld:add) as_root firewall-cmd --quiet --permanent --add-port="$rule" ;;
            firewalld:remove) as_root firewall-cmd --quiet --permanent --remove-port="$rule" 2>/dev/null ;;
        esac
    done
    [ "$tool" = firewalld ] && as_root firewall-cmd --quiet --reload
    return 0
}

stop_server() {
    [ -f "$INSTALL_DIR/docker-compose.yml" ] && [ -f "$INSTALL_DIR/.env" ] || return 0
    if [ -n "$(compose ps -q 2>/dev/null)" ]; then
        info "Stopping the running server. Players get a 2 minute warning, then it saves."
        compose down --timeout 180 || fail "Could not stop the running server."
    fi
}

ask INSTALL_DIR "Install folder" "$DEFAULT_INSTALL" plain_path
INSTALL_DIR=$(realpath -m "${INSTALL_DIR/#\~/$HOME}")

if [ "$UNINSTALL" = yes ]; then
    [ -f "$INSTALL_DIR/.env" ] || fail "No Everlast install exists at $INSTALL_DIR (its .env is missing)."
    ensure_tools
    DATA_DIR=$(env_get DATA_DIR)
    if [ -n "$DATA_DIR" ] && [[ "$DATA_DIR/" == "$INSTALL_DIR/"* ]]; then
        fail "The data folder $DATA_DIR is inside the install folder, so removing the install would delete the worlds. Move the data folder out first. Nothing was removed."
    fi
    [ -n "$(compose ps -q 2>/dev/null)" ] && info "Stopping the server. Players get a 2 minute warning, then it saves."
    compose down --timeout 180 --rmi all || fail "Could not stop and remove the containers."
    old_tool=$(env_get FIREWALL_TOOL)
    if [ -n "$old_tool" ] && [ "$old_tool" != none ]; then
        firewall remove "$old_tool" "$(env_get FIREWALL_RULES)"
        info "Removed the $old_tool rules for $(env_get FIREWALL_RULES)."
    fi
    rm -rf "$INSTALL_DIR" || fail "Could not remove $INSTALL_DIR."
    info "Removed the containers, the image and $INSTALL_DIR."
    delete_data=no
    [ "$YES" = yes ] || { read -r -p "Delete the worlds and settings in $DATA_DIR too (yes or no) [no]: " delete_data || delete_data=no; }
    if [ "$delete_data" = yes ]; then
        # Only what the installer and the server made, so a data folder shared with other files keeps them.
        rm -rf "$DATA_DIR/Worlds" && rm -f "$DATA_DIR/appsettings.json"
        rmdir "$DATA_DIR" 2>/dev/null && info "Removed $DATA_DIR." || info "Removed the worlds and settings. $DATA_DIR still holds other files, so it was kept."
    else
        info "Kept the worlds and settings in $DATA_DIR."
    fi
    exit 0
fi

# The Docker files: next to this script (a copy of the repository, or the installed copy), else from the repository.
FILES_DIR=$SCRIPT_DIR
for file in "${DOCKER_FILES[@]}"; do
    [ -f "$SCRIPT_DIR/$file" ] && continue
    if [ "$FILES_DIR" = "$SCRIPT_DIR" ]; then
        FILES_DIR=$(mktemp -d) || fail "Could not create a temporary folder."
        trap 'rm -rf "$FILES_DIR"' EXIT
        info "Downloading the Docker files from $REPO_RAW"
    fi
done
if [ "$FILES_DIR" != "$SCRIPT_DIR" ]; then
    for file in "${DOCKER_FILES[@]}"; do
        curl -fsSL "$REPO_RAW/$file" -o "$FILES_DIR/$file" || fail "Could not download $file from $REPO_RAW. Check the internet connection, or download the whole linux folder of the guide's repository and run install.sh from it."
    done
fi
probe=$INSTALL_DIR; while [ ! -d "$probe" ]; do probe=$(dirname "$probe"); done
[ -d "$INSTALL_DIR/steam/server" ] || [ "$(df -Pk "$probe" | awk 'NR==2 { print $4 }')" -ge 6291456 ] || fail "The install disk needs about 6 GB free."
[ -z "$ARCHIVE" ] || [ -f "$ARCHIVE" ] || fail "There is no archive at $ARCHIVE."
[ -z "$ARCHIVE" ] || [ "$USE_STEAM" = no ] || fail "Choose --archive or --steam, not both."

# The server source stays as installed unless --archive or --steam changes it.
if [ -n "$ARCHIVE" ]; then SERVER_SOURCE=archive
elif [ "$USE_STEAM" = yes ]; then SERVER_SOURCE=steam
elif [ "$(env_get SERVER_SOURCE)" = archive ] && [ -x "$INSTALL_DIR/steam/server/Raptor.Game" ]; then SERVER_SOURCE=archive
else SERVER_SOURCE=steam
fi

ensure_tools

info ""
info "Install"
data_default=$(env_get DATA_DIR); [ -n "$data_default" ] || data_default=$DEFAULT_DATA
ask DATA_DIR "Data folder for worlds and settings" "$data_default" outside_install
DATA_DIR=$(realpath -m "${DATA_DIR/#\~/$HOME}")
world_default=$(env_get WORLD_NAME); [ -n "$world_default" ] || world_default=Dedicated
ask WORLD "World folder name" "$world_default" world_name

APP_FILE="$DATA_DIR/appsettings.json"
WORLD_FILE="$DATA_DIR/Worlds/$WORLD/worldsettings.json"
for file in "$APP_FILE" "$WORLD_FILE"; do
    [ ! -f "$file" ] || jq empty "$file" 2>/dev/null || fail "$file is not valid JSON. Fix or remove it, then run this again. Nothing was changed."
done
EXISTING_WORLD=no; [ -f "$WORLD_FILE" ] && EXISTING_WORLD=yes

info ""
info "Server"
ask SERVER_NAME "Server name shown in the server browser" "$(json_get "$APP_FILE" NetworkConfig.Name "Everlast Dedicated Server")" length 1 64
ask PORT "Game port (UDP)" "$(json_get "$APP_FILE" NetworkConfig.Port 9003)" port
QUERY_PORT=$((27016 + PORT % 5))
info "Players also need the query port $QUERY_PORT (UDP) for the server browser."
ask MAX_PLAYERS "Max players online at once" "$(json_get "$WORLD_FILE" MaxPlayers 100)" range 1 1000
ask_secret PASSWORD "Join password, empty means anyone can join" "$(json_get "$WORLD_FILE" ServerPassword "")"

info ""
info "Access"
info "A SteamID64 is the 17-digit number in Steam, Account details. Admins get admin commands and the Game Master role in game."
ask ADMINS "Admin Steam IDs, comma separated, empty means none" "$(json_get "$WORLD_FILE" Admins "")" steam_ids

info ""
info "World"
if [ "$EXISTING_WORLD" = yes ]; then
    DIFFICULTY=$(json_get "$WORLD_FILE" Difficulty Psychic)
    info "This world already exists. Its difficulty is $DIFFICULTY and cannot change."
else
    info "Hylic: A forgiving world for exploring at your own pace."
    info "Psychic (Standard): The intended experience. Other difficulties are measured against it."
    info "Pneumonic: Fiercer fights, faster progress."
    info "Pyrrhic: Rich rewards, ruinous deaths."
    info "The Sufferer (type Sufferer): Brutal and unforgiving. What death takes, it keeps."
    info "One Shot (type OneShot): One life. When you die, your story ends."
    info "The difficulty can never change after the world is created."
    ask DIFFICULTY "Difficulty" Psychic difficulty
fi
ask WORLD_DISPLAY_NAME "World name players see" "$(json_get "$WORLD_FILE" DisplayName "$WORLD")" length 1 64
ask DESCRIPTION "Short description for the server browser" "$(json_get "$WORLD_FILE" Description "")" length 0 120

info ""
info "Gameplay"
pvp_default=$(json_get "$WORLD_FILE" PvPEnabled true); [ "$pvp_default" = false ] && pvp_default=no || pvp_default=yes
ask PVP "Players can attack each other (yes or no)" "$pvp_default" yes_no
death_default=$(json_get "$WORLD_FILE" DeathPenalty DeathContainer); [ "$death_default" = KeepInventory ] && death_default=keep || death_default=shop
info "Death penalty: shop sends a dead player's items to Death's shop, keep lets players keep them. Some difficulties decide this themselves."
ask DEATH_PENALTY "Death penalty (shop or keep)" "$death_default" death
ask XP_RATE "XP multiplier" "$(json_get "$WORLD_FILE" XpRate 1)" rate
ask GATHER_RATE "Gathering multiplier" "$(json_get "$WORLD_FILE" GatherRate 1)" rate
ask LOOT_RATE "Loot multiplier" "$(json_get "$WORLD_FILE" LootRate 1)" rate

info ""
info "Characters"
ask MAX_CHARACTERS "Characters per Steam account" "$(json_get "$WORLD_FILE" MaxCharactersPerUser 10)" range 1 100
transfers_default=$(json_get "$WORLD_FILE" AcceptsTransfers false); [ "$transfers_default" = true ] && transfers_default=yes || transfers_default=no
ask TRANSFERS "Accept characters from other worlds (yes or no)" "$transfers_default" yes_no
ask MAX_IMPORT_LEVEL "Highest level a character can arrive with, 0 means any" "$(json_get "$WORLD_FILE" MaxImportLevel 0)" whole
strip_default=$(json_get "$WORLD_FILE" StripGearOnImport false); [ "$strip_default" = true ] && strip_default=yes || strip_default=no
ask STRIP_GEAR "Remove gear from arriving characters (yes or no)" "$strip_default" yes_no
ask IMPORT_ALLOWLIST "Steam IDs allowed to bring characters in, empty means everyone" "$(json_get "$WORLD_FILE" ImportAllowlist "")" steam_ids

STEAM_LOGIN=${EVERLAST_STEAM_LOGIN:-$(env_get STEAM_USERNAME)}; STEAM_LOGIN=${STEAM_LOGIN:-anonymous}
STEAM_BRANCH=${EVERLAST_STEAM_BRANCH:-$(env_get STEAM_BRANCH)}; STEAM_BRANCH=${STEAM_BRANCH:-public}
[[ $STEAM_LOGIN =~ ^[A-Za-z0-9_.-]+$ ]] || fail "EVERLAST_STEAM_LOGIN can only hold letters, digits, ., - and _."
[[ $STEAM_BRANCH =~ ^[A-Za-z0-9_.-]+$ ]] || fail "EVERLAST_STEAM_BRANCH can only hold letters, digits, ., - and _."

info ""
info "Running"
ask SERVICE "Start the server now and keep it running, also after a reboot (yes or no)" yes yes_no
FIREWALL_TOOL=$(firewall_tool)
if [ "$FIREWALL_TOOL" = none ]; then
    FIREWALL=no
    info "No active firewall (ufw or firewalld) was found, so no rules are needed on this machine."
else
    ask FIREWALL "Open the server's ports in $FIREWALL_TOOL (yes or no)" yes yes_no
fi

info ""
info "Summary"
info "  Install folder:  $INSTALL_DIR"
info "  Data folder:     $DATA_DIR"
info "  World:           $WORLD ($WORLD_DISPLAY_NAME), difficulty $DIFFICULTY$([ "$EXISTING_WORLD" = yes ] && echo ', existing world')"
info "  Server name:     $SERVER_NAME"
info "  Ports:           game $PORT UDP, query $QUERY_PORT UDP"
info "  Max players:     $MAX_PLAYERS"
info "  Join password:   $([ -n "$PASSWORD" ] && echo set || echo none)"
info "  Admins:          ${ADMINS:-none}"
info "  Description:     ${DESCRIPTION:-none}"
info "  PvP:             $PVP, death penalty $DEATH_PENALTY"
info "  Rates:           XP $XP_RATE, gathering $GATHER_RATE, loot $LOOT_RATE"
info "  Characters:      $MAX_CHARACTERS per account, transfers $TRANSFERS, max import level $MAX_IMPORT_LEVEL, strip gear $STRIP_GEAR"
info "  Import allowed:  ${IMPORT_ALLOWLIST:-everyone}"
if [ -n "$ARCHIVE" ]; then source_text="archive $ARCHIVE"
elif [ "$SERVER_SOURCE" = archive ]; then source_text="the release archive already installed (--steam switches to Steam)"
else source_text="Steam, branch $STEAM_BRANCH, as $STEAM_LOGIN"
fi
info "  Server source:   $source_text"
info "  Keep running:    $SERVICE"
info "  Firewall:        $([ "$FIREWALL" = yes ] && echo "open in $FIREWALL_TOOL" || echo 'no change')"
if [ "$YES" != yes ]; then
    read -r -p "Install with these settings (yes or no) [yes]: " proceed || fail "Input ended before the install started."
    [ "${proceed:-yes}" = yes ] || { info "Nothing was changed."; exit 0; }
fi

# The container runs as the owner of the install. Installed by root, that is uid 1000, as in most Docker images.
if [ "$(id -u)" -eq 0 ]; then OWNER_UID=1000; OWNER_GID=1000; else OWNER_UID=$(id -u); OWNER_GID=$(id -g); fi

stop_server
old_tool=$(env_get FIREWALL_TOOL)
[ -n "$old_tool" ] && [ "$old_tool" != none ] && firewall remove "$old_tool" "$(env_get FIREWALL_RULES)"

mkdir -p "$INSTALL_DIR/steam" "$INSTALL_DIR/secrets" "$DATA_DIR/Worlds/$WORLD" || fail "Could not create the install and data folders. Choose folders you can write to, or run as root."
for file in "${DOCKER_FILES[@]}"; do
    [ "$FILES_DIR/$file" -ef "$INSTALL_DIR/$file" ] || cp "$FILES_DIR/$file" "$INSTALL_DIR/$file" || fail "Could not copy $file into $INSTALL_DIR."
done
[ "$SCRIPT_DIR/install.sh" -ef "$INSTALL_DIR/install.sh" ] || cp "${BASH_SOURCE[0]}" "$INSTALL_DIR/install.sh" || fail "Could not copy install.sh into $INSTALL_DIR."
chmod 755 "$INSTALL_DIR/install.sh" "$INSTALL_DIR/entrypoint.sh"

if [ -n "$ARCHIVE" ]; then
    info "Installing the server from $ARCHIVE"
    rm -rf "$INSTALL_DIR/steam/server" && mkdir -p "$INSTALL_DIR/steam/server"
    tar -xzf "$ARCHIVE" -C "$INSTALL_DIR/steam/server" || fail "Could not extract $ARCHIVE. It must be a linux-x64 .tar.gz release archive."
    [ -f "$INSTALL_DIR/steam/server/Raptor.Game" ] || fail "$ARCHIVE has no Raptor.Game at its top level. Use a linux-x64 release archive."
elif [ "$SERVER_SOURCE" = archive ]; then
    info "Keeping the server installed from a release archive. Run with --steam to get it from Steam instead."
elif [ "$(env_get SERVER_SOURCE)" = archive ]; then
    info "Switching to Steam: the server comes from Steam from now on."
fi

branch_password_file="$INSTALL_DIR/secrets/steam_branch_password"
if [ "$STEAM_BRANCH" = public ]; then rm -f "$branch_password_file"
elif [ -n "${EVERLAST_STEAM_BRANCH_PASSWORD:-}" ]; then (umask 077 && printf '%s' "$EVERLAST_STEAM_BRANCH_PASSWORD" > "$branch_password_file")
fi

# Settings files: only the installer's keys change. Every other key, also ones a newer server adds, is kept.
app_json=$(if [ -f "$APP_FILE" ]; then cat "$APP_FILE"; else echo '{}'; fi)
app_json=$(jq --arg name "$SERVER_NAME" --argjson port "$PORT" '
    def drop($names): with_entries(select((.key | ascii_downcase) as $k | $names | index($k) | not));
    .NetworkConfig = ((.NetworkConfig // {}) | drop(["name", "port"])) + {Name: $name, Port: $port}' <<<"$app_json") || fail "Could not update $APP_FILE."

[ "$PVP" = yes ] && pvp_json=true || pvp_json=false
[ "$TRANSFERS" = yes ] && transfers_json=true || transfers_json=false
[ "$STRIP_GEAR" = yes ] && strip_json=true || strip_json=false
[ "$DEATH_PENALTY" = keep ] && death_json=KeepInventory || death_json=DeathContainer
[ "$EXISTING_WORLD" = yes ] && new_world=false || new_world=true
world_json=$(if [ -f "$WORLD_FILE" ]; then cat "$WORLD_FILE"; else echo '{}'; fi)
created=$(date -u '+%Y-%m-%d %H:%M:%S')
world_json=$(EVERLAST_PASSWORD="$PASSWORD" jq --argjson new "$new_world" \
    --arg displayName "$WORLD_DISPLAY_NAME" --arg description "$DESCRIPTION" --argjson maxPlayers "$MAX_PLAYERS" \
    --argjson pvp "$pvp_json" --argjson xp "$XP_RATE" --argjson gather "$GATHER_RATE" --argjson loot "$LOOT_RATE" \
    --arg death "$death_json" --arg difficulty "$DIFFICULTY" --argjson transfers "$transfers_json" \
    --argjson maxCharacters "$MAX_CHARACTERS" --argjson maxImport "$MAX_IMPORT_LEVEL" --argjson strip "$strip_json" \
    --arg allowlist "$IMPORT_ALLOWLIST" --arg admins "$ADMINS" --arg created "$created" '
    . + {DisplayName: $displayName, Description: $description, MaxPlayers: $maxPlayers, PvPEnabled: $pvp,
        XpRate: $xp, GatherRate: $gather, LootRate: $loot, DeathPenalty: $death}
    | if $new then . + {Difficulty: $difficulty} else . end
    | . + {AcceptsTransfers: $transfers, MaxCharactersPerUser: $maxCharacters, MaxImportLevel: $maxImport,
        StripGearOnImport: $strip, ImportAllowlist: $allowlist, Admins: $admins}
    | if $new then . + {OriginServerId: ""} else . end
    | . + {ServerPassword: $ENV.EVERLAST_PASSWORD}
    | if $new then . + {CreatedDate: $created, LastPlayedDate: $created} else . end' <<<"$world_json") || fail "Could not update $WORLD_FILE."

printf '%s\n' "$app_json" > "$APP_FILE" || fail "Could not write $APP_FILE."
printf '%s\n' "$world_json" > "$WORLD_FILE" || fail "Could not write $WORLD_FILE."

FIREWALL_RULES=""
[ "$FIREWALL" = yes ] && FIREWALL_RULES="$PORT/udp $QUERY_PORT/udp"
{
    echo "# Written by install.sh. Run it again to change these."
    env_line COMPOSE_PROJECT_NAME "everlast-${WORLD,,}"
    env_line WORLD_NAME "$WORLD"
    env_line DATA_DIR "$DATA_DIR"
    env_line EVERLAST_UID "$OWNER_UID"
    env_line EVERLAST_GID "$OWNER_GID"
    env_line SERVER_SOURCE "$SERVER_SOURCE"
    env_line STEAM_USERNAME "$([ "$STEAM_LOGIN" = anonymous ] || echo "$STEAM_LOGIN")"
    env_line STEAM_BRANCH "$STEAM_BRANCH"
    env_line FIREWALL_TOOL "$([ "$FIREWALL" = yes ] && echo "$FIREWALL_TOOL" || echo none)"
    env_line FIREWALL_RULES "$FIREWALL_RULES"
} > "$INSTALL_DIR/.env"
# Installed by root, hand the folders the container writes to its uid.
[ "$(id -u)" -eq 0 ] && chown -R "$OWNER_UID:$OWNER_GID" "$INSTALL_DIR/steam" "$INSTALL_DIR/secrets" "$DATA_DIR"
# The world settings hold the join password and steam/ the cached Steam login, so only their owner may read them.
chmod 700 "$INSTALL_DIR/secrets" "$INSTALL_DIR/steam" "$DATA_DIR"

[ "$FIREWALL" = yes ] && { firewall add "$FIREWALL_TOOL" "$FIREWALL_RULES" && info "Opened $FIREWALL_RULES in $FIREWALL_TOOL."; }

info "Building the Docker image."
compose build -q || fail "Docker could not build the image. See the output above."
if [ "$STEAM_LOGIN" != anonymous ] && [ "$SERVER_SOURCE" = steam ]; then
    if [ -t 0 ]; then
        info "Signing SteamCMD in as $STEAM_LOGIN. The first time it asks for the password and a Steam Guard code."
        compose run --rm -it everlast login || fail "The SteamCMD sign-in failed."
    else
        info "Skipped the SteamCMD sign-in for $STEAM_LOGIN because there is no terminal. Run it once: cd $INSTALL_DIR && docker compose run --rm -it everlast login"
    fi
fi

log_file="$DATA_DIR/Worlds/$WORLD/server.log"
if [ "$SERVICE" = yes ]; then
    log_start=$(stat -c %s "$log_file" 2>/dev/null || echo 0)
    compose up -d || fail "Docker could not start the server. Run: cd $INSTALL_DIR && docker compose logs"
    if [ "$SERVER_SOURCE" = steam ]; then
        info "Starting. The server updates from Steam first, and the first start downloads all of it, which takes a few minutes."
    else
        info "Starting the server."
    fi
    ready=no
    for _ in $(seq 1 180); do
        sleep 5
        size=$(stat -c %s "$log_file" 2>/dev/null || echo 0)
        [ "$size" -lt "$log_start" ] && log_start=0
        if tail -c +"$((log_start + 1))" "$log_file" 2>/dev/null | grep -q 'SERVER_READY'; then ready=yes; break; fi
        # A container that exited or restarted before the server was ready failed to start.
        container=$(compose ps -aq everlast 2>/dev/null)
        [ -n "$container" ] || break
        state=$("${DOCKER[@]}" inspect -f '{{.State.Status}} {{.RestartCount}}' "$container" 2>/dev/null)
        [ "$state" = "running 0" ] || break
    done
    if [ "$ready" = yes ]; then
        info "The server is running."
        # Steam lists the server a few seconds after it is ready.
        connected=no
        for _ in $(seq 1 15); do
            if tail -c +"$((log_start + 1))" "$log_file" | grep -q 'Connected to Steam master server'; then connected=yes; break; fi
            sleep 2
        done
        if [ "$connected" = yes ]; then
            info "It is connected to Steam, so it shows in the server browser."
        else
            info "It has not connected to Steam after 30 seconds. Check the server log if it does not show in the server browser."
        fi
    else
        recent=$(compose logs --tail 40 everlast 2>/dev/null)
        if grep -q "Password check for AppId 4268160 returned error" <<<"$recent"; then
            compose down --timeout 10 >/dev/null 2>&1
            info "Steam refused the password for the $STEAM_BRANCH branch, so it stopped trying."
            info "Run this again with the right EVERLAST_STEAM_BRANCH_PASSWORD, or with EVERLAST_STEAM_BRANCH=public."
        elif grep -qE "Failed to install app '4268160' \((No subscription|Missing configuration)\)" <<<"$recent"; then
            compose down --timeout 10 >/dev/null 2>&1
            info "Steam would not download the server: Everlast Dedicated Server is not available to this Steam login yet."
            info "Once it is released it downloads anonymously. Until then, run this again with --archive and a linux-x64 release archive."
            info "The settings are saved, so that run only needs: $INSTALL_DIR/install.sh --yes --install-dir $INSTALL_DIR --archive <file>"
        else
            info "The server did not start. Its last lines:"
            tail -n 15 <<<"$recent"
            info "Docker keeps trying to start it. Stop it with: cd $INSTALL_DIR && docker compose down"
        fi
        exit 1
    fi
else
    info "The server is set up but not started. Start it with: cd $INSTALL_DIR && docker compose up -d"
fi

info ""
info "Everlast Dedicated Server is installed."
info "  Server and Docker files: $INSTALL_DIR"
info "  Worlds and settings:     $DATA_DIR"
info "  Server log:              $log_file"
info "  Forward these ports in your router to this machine: $PORT UDP (game) and $QUERY_PORT UDP (server browser)."
info ""
info "Run these in $INSTALL_DIR:"
info "  Logs:     docker compose logs -f"
if [ "$SERVER_SOURCE" = archive ]; then
    info "  Restart:  docker compose restart   (to update, run the installer with a newer --archive)"
else
    info "  Restart:  docker compose restart   (updates from Steam on the way up)"
fi
info "  Stop:     docker compose down      (players get a 2 minute warning, then it saves)"
info "  Start:    docker compose up -d"
info "  Change settings: run $INSTALL_DIR/install.sh again, or edit the two settings files above and restart"
info "  Uninstall: $INSTALL_DIR/install.sh --install-dir $INSTALL_DIR --uninstall"
