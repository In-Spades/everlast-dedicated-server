# Everlast Dedicated Server installers

These installers set up an Everlast Dedicated Server on a machine that does not run the Steam client: a rented Linux server, a spare PC or a Mac. Download the one script for your system and run it. It asks about every setting, downloads the server from Steam, keeps it running and can open your firewall.

| Platform | Installer | How the server runs |
|---|---|---|
| Linux, 64-bit x86 | [`linux/install.sh`](linux/install.sh) | In Docker, restarted by Docker, also after a reboot |
| macOS, Apple Silicon | [`macos/install.sh`](macos/install.sh) | Natively, as a background service of your user account (launchd) |
| Windows, 64-bit | [`windows/install.ps1`](windows/install.ps1) | Natively, as a scheduled task that starts when you sign in |

The server comes from the Everlast Dedicated Server app on Steam (app 4268160), the same server build that the game ships with.

If anything breaks or does not work, please email [moh@inspades.net](mailto:moh@inspades.net?subject=Everlast%20Dedicated%20Server). See [Help](#help) for what to include.

## Requirements

| | Minimum | Measured |
|---|---|---|
| CPU | 2 cores, 64-bit | About half a core idle, about one core with players on, short peaks to 1.3 cores |
| Memory | 4 GB | 1.5 to 2 GB idle, up to 2.3 GB with players on |
| Disk | 6 GB free | About 1 GB for the server itself. The rest is for SteamCMD, updates and world saves |
| Network | Two UDP ports open | The game port and the query port, see [Ports](#before-you-start) |

These numbers come from the current server build with one or two players online, on Linux, Windows and macOS. More players need more CPU and memory.

Do not delete the server's `Raptor.Physics/navcache` folder. The server ships with it ready, and building it again takes far more memory and time than running the server.

## Before you start

- **Admin commands.** In-game admin roles are turned off in the released server, so the installer's admin Steam IDs grant nothing for now. To manage a running server, run the server program again with `--admin status`, `--admin say <text>`, `--admin kick <uid>` (the uid comes from `status`) or `--admin stop`, followed by the same `--LaunchConfig:DataRoot` and `--LaunchConfig:WorldName` arguments the server runs with.
- **Ports.** Players need the game port (UDP, 9003 by default) and the query port (UDP), which the server browser uses. By default the query port is 27016 plus the game port's remainder after dividing by 5, so game port 9003 means query port 27019. To pick it yourself, set `NetworkConfig.QueryPort` in `appsettings.json`, for example when several servers share one IP. Forward both in your router to the server machine if players join from outside your home network.
- **Difficulty.** Chosen once, when the world is created, and it can never change:
  - Hylic: A forgiving world for exploring at your own pace.
  - Psychic (Standard): The intended experience. Other difficulties are measured against it.
  - Pneumonic: Fiercer fights, faster progress.
  - Pyrrhic: Rich rewards, ruinous deaths.
  - The Sufferer: Brutal and unforgiving. What death takes, it keeps.
  - One Shot: One life. When you die, your story ends.

## What the installer asks

Press Enter to accept the default shown in brackets. Each question also has a command line option (run the installer with `--help`, or `Get-Help .\install.ps1 -Detailed` on Windows), and `--yes` (`-Yes`) accepts the default for everything you did not pass, which suits hosting companies and scripts.

| Group | Settings |
|---|---|
| Install | Install folder, data folder for worlds and settings, world folder name |
| Server | Server name in the server browser, game port, max players, join password (empty means anyone can join) |
| Access | Admin Steam IDs (optional, they grant nothing in the released server for now) |
| World | Difficulty (new worlds only), the world name players see, a short description |
| Gameplay | PvP, death penalty (items go to Death's shop, or players keep them), XP, gathering and loot multipliers from 0.1 to 10 |
| Characters | Characters per Steam account, whether characters from other worlds may arrive, their highest level, whether their gear is removed, who may bring them |
| Running | Keep it running, open the firewall |

Run the installer again at any time to change settings. It shows the current values as defaults, keeps the world and every setting it does not ask about, and restarts the server with a 2 minute warning to players.

## Linux (Docker)

On the server, run:

```bash
curl -fsSLO https://raw.githubusercontent.com/In-Spades/everlast-dedicated-server/main/linux/install.sh
sudo bash install.sh
```

The installer downloads the Docker files it needs from this repository, installs Docker if it is missing (with your permission) and `jq`, which it uses to edit the settings files. It then builds the image, starts the server and waits until it is ready. The first start downloads the server from Steam, which takes a few minutes.

As root it installs into `/opt/everlast-server` with the worlds in `/var/lib/everlast-server`. As a normal user it uses `~/everlast-server` and `~/.local/share/everlast-server`. Docker keeps the server running and starts it again after a crash or a reboot. If ufw or firewalld is on, the installer can open the ports in it.

Day to day, in the install folder:

| Task | Command |
|---|---|
| Logs | `docker compose logs -f` |
| Update | `docker compose restart` (players get a 2 minute warning, the server updates from Steam and starts again) |
| Stop | `docker compose down` (players get a 2 minute warning, then the world saves) |
| Start | `docker compose up -d` |
| Change settings | `sudo ./install.sh` |
| Uninstall | `sudo ./install.sh --install-dir <install folder> --uninstall` (asks before deleting the worlds) |

## macOS (Apple Silicon)

Open Terminal and run the following. Do not use sudo, the server runs as your user.

```bash
curl -fsSLO https://raw.githubusercontent.com/In-Spades/everlast-dedicated-server/main/macos/install.sh
bash install.sh
```

It downloads SteamCMD and the server into `~/EverlastServer`, keeps the worlds in `~/Library/Application Support/Everlast Dedicated Server`, and sets the server up as a background service that starts when you log in and restarts after a crash.

The Mac must stay awake while the server runs. In System Settings, set it to never sleep automatically while the display is off.

Day to day, where `<world>` is the world folder name in lowercase:

| Task | Command |
|---|---|
| Logs | `tail -f ~/Library/Application\ Support/Everlast\ Dedicated\ Server/Worlds/<World>/server.log` |
| Stop | `launchctl bootout gui/$(id -u)/net.inspades.everlast.<world>.server` (players get a 2 minute warning, then the world saves) |
| Start | `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/net.inspades.everlast.<world>.server.plist` |
| Update | Stop, then Start. The server updates from Steam each time it starts |
| Change settings | `bash ~/EverlastServer/install.sh` |
| Uninstall | `~/EverlastServer/install.sh --install-dir ~/EverlastServer --uninstall` (asks before deleting the worlds) |

## Windows

Open PowerShell (not as administrator) and run:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/In-Spades/everlast-dedicated-server/main/windows/install.ps1 -OutFile install.ps1 -UseBasicParsing
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

It downloads SteamCMD and the server into `%USERPROFILE%\EverlastServer`, keeps the worlds in `Documents\My Games\Everlast Dedicated Server`, and sets the server up as a scheduled task that starts when you sign in to Windows and restarts the server after a crash. Opening the firewall asks for administrator rights once.

The server runs while you are signed in. On a PC used only as a server, set Windows to sign in automatically and to never sleep.

Day to day, from PowerShell:

| Task | Command |
|---|---|
| Logs | `Get-Content "$([Environment]::GetFolderPath('MyDocuments'))\My Games\Everlast Dedicated Server\Worlds\<World>\server.log" -Wait -Tail 50` |
| Stop | `powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\EverlastServer\stop-server.ps1"` (players get a 2 minute warning, then the world saves) |
| Start | `powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\EverlastServer\start-server.ps1"` |
| Update | Stop, then Start. The server updates from Steam each time it starts |
| Change settings | `powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\EverlastServer\install.ps1"` |
| Uninstall | `powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\EverlastServer\install.ps1" -Uninstall` (asks before deleting the worlds) |

## Where things live

| What | Where |
|---|---|
| World save, `worldsettings.json` and `server.log` | `<data folder>/Worlds/<world>/` |
| Server name, game port and query port | `<data folder>/appsettings.json` |
| The server program, SteamCMD and the service files | The install folder |

Updates never touch the data folder, so worlds and settings stay as they are when Steam replaces the server. You can edit the two settings files by hand while the server is stopped, and the installer edits the same files.

## Settings reference

The server reads both files every time it starts, so restart it after an edit. A setting left out of a file uses its default. The installer only changes the settings it asks about and keeps every other one.

### World settings: `<data folder>/Worlds/<world>/worldsettings.json`

| Setting | Default | Values |
|---|---|---|
| `DisplayName` | the world folder name | The world name players see |
| `Description` | empty | Short description for the server browser |
| `MaxPlayers` | 100 | Players online at once. The installer accepts 1 to 1000 |
| `ServerPassword` | empty | Join password. Empty means anyone can join |
| `PvPEnabled` | `true` | `true` or `false` |
| `DeathPenalty` | `DeathContainer` | `DeathContainer` (items go to Death's shop) or `KeepInventory` |
| `XpRate`, `GatherRate`, `LootRate` | 1 | Multipliers from 0.1 to 10. Values outside that range are clamped, and the log says so |
| `Difficulty` | `Psychic` | `Hylic`, `Psychic`, `Pneumonic`, `Pyrrhic`, `Sufferer` or `OneShot`. Set it before the world's first start and never change it afterwards |
| `MaxCharactersPerUser` | 10 | Characters per Steam account. The installer accepts 1 to 100 |
| `AcceptsTransfers` | `false` | Whether characters from other worlds may arrive. One Shot worlds never accept them |
| `MaxImportLevel` | 0 | Highest level an arriving character may have. 0 means any |
| `StripGearOnImport` | `false` | Remove an arriving character's gear |
| `ImportAllowlist` | empty | SteamID64s allowed to bring characters, separated by commas. Empty means everyone |
| `Admins` | empty | SteamID64s separated by commas. Grants nothing in the released server for now |

The server manages `OriginServerId`, `CreatedDate` and `LastPlayedDate` itself. Leave them as they are.

### Server settings: `<data folder>/appsettings.json`

| Setting | Default | Values |
|---|---|---|
| `NetworkConfig.Name` | `Everlast Dedicated Server` (installer) | Server name in the server browser |
| `NetworkConfig.Port` | 9003 | Game port (UDP) |
| `NetworkConfig.QueryPort` | 27016 + game port % 5 | Query port (UDP) for the server browser. Set it when several servers share one IP |
| `NetworkConfig.Location` | `Usa` | Region shown in the server browser: `Usa`, `Eu` or `Oce` |
| `RespawnScalingConfig.Enabled` | `true` | Respawn faster when several players are near, see below |
| `RespawnScalingConfig.RadiusMeters` | 50 | How close a player must be to count, from 1 to 500 metres |
| `RespawnScalingConfig.PerPlayerSpeedup` | 0.5 | How much each player after the first speeds respawns up, from 0 to 10 |
| `RespawnScalingConfig.MinMultiplier` | 0.25 | The shortest a respawn timer can get, as a fraction of its normal length, from 0.05 to 1 |

For example, to give a server its own query port and turn respawn scaling off:

```json
{
  "NetworkConfig": { "Name": "My Everlast Server", "Port": 9003, "QueryPort": 27100 },
  "RespawnScalingConfig": { "Enabled": false }
}
```

**Respawn scaling** (server builds from 29 October 2026 on) shortens the respawn timers of monsters, NPCs, objects and gathering spots on the world map when several players stand near them, so a crowd does not run out of things to fight and gather. When a timer starts, the server counts the players within `RadiusMeters` and multiplies the timer by `1 / (1 + PerPlayerSpeedup × (players - 1))`, never going below `MinMultiplier`. With the defaults:

| Players nearby | 1 | 2 | 3 | 4 | 5 | 7 or more |
|---|---|---|---|---|---|---|
| Respawn time | normal | 67% | 50% | 40% | 33% | 25% |

### Overriding settings without editing the files

Every setting above can also be given on the command line or as an environment variable, and those win over the files. Use `:` on the command line and `__` in environment variables:

- `--NetworkConfig:QueryPort=27100` or `NetworkConfig__QueryPort=27100`
- `--WorldConfig:MaxPlayers=50` or `WorldConfig__MaxPlayers=50` (world settings go under `WorldConfig`)
- `--RespawnScalingConfig:Enabled=false` or `RespawnScalingConfig__Enabled=false`

## Troubleshooting

- **The server is not in the server browser.** Check the game and query ports are forwarded as UDP to this machine and allowed by its firewall. The server log says `Connected to Steam master server` with its public IP and both ports once Steam lists it.
- **Steam would not download the server.** The installer shows SteamCMD's own message. Check that the machine reaches Steam and has about 6 GB free, then run the installer again.

## Help

If something breaks or does not work, email [moh@inspades.net](mailto:moh@inspades.net?subject=Everlast%20Dedicated%20Server). Please include:

- Your platform (Linux, macOS or Windows) and how you installed the server
- What you did and what happened
- The installer output, if the problem happened during install
- The end of `server.log` from `<data folder>/Worlds/<world>/`
