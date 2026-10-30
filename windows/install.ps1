<#
.SYNOPSIS
Installs and manages an Everlast dedicated server on 64-bit Windows.

.DESCRIPTION
Installs SteamCMD and the native win-x64 server, writes world settings, and can
keep the server running with a Windows scheduled task.
Guide: https://github.com/In-Spades/everlast-dedicated-server
For a Steam branch other than public, set EVERLAST_STEAM_BRANCH and
EVERLAST_STEAM_BRANCH_PASSWORD before running this script. The password is
never written to the install record.

.PARAMETER InstallDir
Folder for the installer, SteamCMD, server, and helper scripts.
.PARAMETER DataDir
Folder for worlds and server settings.
.PARAMETER World
World folder name.
.PARAMETER ServerName
Name shown in the server browser.
.PARAMETER Port
UDP game port.
.PARAMETER QueryPort
UDP query port for the server browser.
.PARAMETER Region
Region shown in the server browser. Use Usa, Eu, or Oce.
.PARAMETER MaxPlayers
Maximum players from 1 to 1000.
.PARAMETER Password
Join password. Empty allows anyone to join.
.PARAMETER Admins
Comma-separated SteamID64 values.
.PARAMETER Difficulty
Hylic, Psychic, Pneumonic, Pyrrhic, Sufferer, or OneShot. New worlds only.
.PARAMETER WorldDisplayName
World name shown to players.
.PARAMETER Description
Server browser description of up to 120 characters.
.PARAMETER PvP
Whether players can attack each other. Use yes or no.
.PARAMETER DeathPenalty
Use shop or keep.
.PARAMETER XpRate
Experience multiplier from 0.1 to 10.
.PARAMETER GatherRate
Gathering multiplier from 0.1 to 10.
.PARAMETER LootRate
Loot multiplier from 0.1 to 10.
.PARAMETER RespawnScaling
Whether monsters and resources respawn faster near several players. Use yes or no.
.PARAMETER RespawnRadius
Distance in metres from 1 to 500 for nearby players.
.PARAMETER RespawnSpeedup
Speedup per extra nearby player from 0 to 10.
.PARAMETER RespawnFloor
Shortest respawn time as a fraction of normal from 0.05 to 1.
.PARAMETER MaxCharacters
Characters per Steam account from 1 to 100.
.PARAMETER Transfers
Whether character transfers are accepted. Use yes or no.
.PARAMETER MaxImportLevel
Highest import level, where 0 allows any level.
.PARAMETER StripGear
Whether arriving characters lose their gear. Use yes or no.
.PARAMETER ImportAllowlist
Comma-separated SteamID64 values allowed to import.
.PARAMETER Service
Whether to start at logon and keep running. Use yes or no.
.PARAMETER Firewall
Whether to add Windows Firewall rules. Use yes or no.
.PARAMETER Archive
Install from a win-x64 release zip instead of Steam.
.PARAMETER Steam
Switch an existing archive install to Steam downloads.
.PARAMETER Yes
Accept defaults for options that were not passed and skip confirmation.
.PARAMETER Uninstall
Remove tasks, firewall rules, and the install folder. World data is kept by default.
.PARAMETER Help
Show this help.
#>
[CmdletBinding()]
param(
    [string]$InstallDir,
    [string]$DataDir,
    [string]$World,
    [string]$ServerName,
    [Nullable[int]]$Port,
    [Nullable[int]]$QueryPort,
    [string]$Region,
    [Nullable[int]]$MaxPlayers,
    [AllowEmptyString()][string]$Password,
    [AllowEmptyString()][string]$Admins,
    [string]$Difficulty,
    [string]$WorldDisplayName,
    [AllowEmptyString()][string]$Description,
    [string]$PvP,
    [string]$DeathPenalty,
    [Nullable[decimal]]$XpRate,
    [Nullable[decimal]]$GatherRate,
    [Nullable[decimal]]$LootRate,
    [string]$RespawnScaling,
    [Nullable[decimal]]$RespawnRadius,
    [Nullable[decimal]]$RespawnSpeedup,
    [Nullable[decimal]]$RespawnFloor,
    [Nullable[int]]$MaxCharacters,
    [string]$Transfers,
    [Nullable[int]]$MaxImportLevel,
    [string]$StripGear,
    [AllowEmptyString()][string]$ImportAllowlist,
    [string]$Service,
    [string]$Firewall,
    [string]$Archive,
    [switch]$Steam,
    [switch]$Yes,
    [switch]$Uninstall,
    [switch]$Help
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $encoding = New-Object Text.UTF8Encoding $false
    [IO.File]::WriteAllText($Path, $Text, $encoding)
}

function ConvertTo-ReadableJson($Value, [int]$Depth) {
    return (($Value | ConvertTo-Json -Depth $Depth) -replace '\\u0027', "'")
}

function Set-JsonProperty($Object, [string]$Name, $Value) {
    $matches = @($Object.PSObject.Properties | Where-Object { $_.Name.Equals($Name, [StringComparison]::OrdinalIgnoreCase) })
    foreach ($property in $matches) {
        if (-not $property.Name.Equals($Name, [StringComparison]::Ordinal)) {
            $Object.PSObject.Properties.Remove($property.Name)
        }
    }
    if ($null -ne $Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    }
    else {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-FirewallScript([string]$Code) {
    if (Test-Elevated) {
        & ([ScriptBlock]::Create($Code))
        return
    }
    $bytes = [Text.Encoding]::Unicode.GetBytes($Code)
    $encoded = [Convert]::ToBase64String($bytes)
    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
    if ($process.ExitCode -ne 0) {
        throw "Windows Firewall setup failed with exit code $($process.ExitCode)."
    }
}

function Get-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Cannot read JSON file '$Path'. $($_.Exception.Message)"
    }
}

function Get-Property($Object, [string]$Name, $Fallback) {
    if ($null -ne $Object) {
        $property = $Object.PSObject.Properties | Where-Object { $_.Name.Equals($Name, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if ($null -ne $property) { return $property.Value }
    }
    return $Fallback
}

function Test-PathInside([string]$Path, [string]$Parent) {
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $fullParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    return $fullPath.Equals($fullParent, [StringComparison]::OrdinalIgnoreCase) -or $fullPath.StartsWith($fullParent + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Invoke-SteamRunscript([string]$Executable, [string[]]$Commands, [string]$Secret) {
    $scriptPath = [IO.Path]::GetTempFileName()
    try {
        Write-Utf8NoBom $scriptPath (($Commands -join [Environment]::NewLine) + [Environment]::NewLine)
        & icacls.exe $scriptPath /inheritance:r /grant:r "${env:USERNAME}:(F)" | Out-Null
        $output = (& $Executable '+@sSteamCmdForcePlatformType' 'windows' '+runscript' $scriptPath 2>&1 | Out-String)
        if (-not [string]::IsNullOrEmpty($Secret)) {
            $output = $output.Replace($Secret, '***')
        }
        return $output
    }
    finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

function Read-Plain([string]$Prompt, [string]$Default) {
    $shown = if ([string]::IsNullOrEmpty($Default)) { 'empty' } else { $Default }
    $answer = Read-Host "$Prompt [$shown]"
    if ([string]::IsNullOrEmpty($answer)) {
        return $Default
    }
    return $answer
}

function Read-Secret([string]$Prompt, [string]$Default) {
    $state = if ([string]::IsNullOrEmpty($Default)) { 'empty' } else { 'set' }
    $secure = Read-Host "$Prompt [$state, press Enter to keep it]" -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $answer = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
    if ([string]::IsNullOrEmpty($answer)) {
        return $Default
    }
    return $answer
}

function Get-TextOption([string]$Value, [bool]$WasPassed, [string]$Prompt, [string]$Default, [ScriptBlock]$Validate, [string]$Reason, [switch]$Secret) {
    if ($WasPassed) {
        if (-not (& $Validate $Value)) {
            throw "$Prompt is invalid. $Reason"
        }
        return $Value
    }
    if ($Yes) {
        return $Default
    }
    while ($true) {
        $answer = if ($Secret) { Read-Secret $Prompt $Default } else { Read-Plain $Prompt $Default }
        if (& $Validate $answer) {
            return $answer
        }
        Write-Host $Reason -ForegroundColor Yellow
    }
}

function Get-IntOption($Value, [bool]$WasPassed, [string]$Prompt, [int]$Default, [int]$Minimum, [int]$Maximum) {
    if ($WasPassed) {
        if ($Value -lt $Minimum -or $Value -gt $Maximum) {
            throw "$Prompt must be from $Minimum to $Maximum."
        }
        return [int]$Value
    }
    if ($Yes) {
        return $Default
    }
    while ($true) {
        $answer = Read-Plain $Prompt ([string]$Default)
        $parsed = 0
        if ([int]::TryParse($answer, [ref]$parsed) -and $parsed -ge $Minimum -and $parsed -le $Maximum) {
            return $parsed
        }
        Write-Host "Enter a whole number from $Minimum to $Maximum." -ForegroundColor Yellow
    }
}

function Get-DecimalOption($Value, [bool]$WasPassed, [string]$Prompt, [decimal]$Default, [decimal]$Minimum = 0.1, [decimal]$Maximum = 10) {
    if ($WasPassed) {
        if ($Value -lt $Minimum -or $Value -gt $Maximum) {
            throw "$Prompt must be from $Minimum to $Maximum."
        }
        return [decimal]$Value
    }
    if ($Yes) {
        return $Default
    }
    while ($true) {
        $defaultText = $Default.ToString([Globalization.CultureInfo]::InvariantCulture)
        $answer = Read-Plain $Prompt $defaultText
        $parsed = [decimal]0
        if ([decimal]::TryParse($answer, [Globalization.NumberStyles]::Number, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and $parsed -ge $Minimum -and $parsed -le $Maximum) {
            return $parsed
        }
        Write-Host "Enter a number from $Minimum to $Maximum. Use a period for the decimal point." -ForegroundColor Yellow
    }
}

function Convert-YesNo([string]$Value, [string]$Name) {
    if ($Value -match '^(?i:y|yes|true|1)$') { return $true }
    if ($Value -match '^(?i:n|no|false|0)$') { return $false }
    throw "$Name must be yes or no."
}

function Get-YesNoOption([string]$Value, [bool]$WasPassed, [string]$Prompt, [bool]$Default) {
    $defaultText = if ($Default) { 'yes' } else { 'no' }
    if ($WasPassed) {
        return Convert-YesNo $Value $Prompt
    }
    if ($Yes) {
        return $Default
    }
    while ($true) {
        $answer = Read-Plain $Prompt $defaultText
        try { return Convert-YesNo $answer $Prompt }
        catch { Write-Host 'Enter yes or no.' -ForegroundColor Yellow }
    }
}

function Test-SteamIds([string]$Value) {
    return [string]::IsNullOrWhiteSpace($Value) -or $Value -match '^\s*\d{17}(\s*,\s*\d{17})*\s*$'
}

function Normalize-SteamIds([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return (($Value -split ',') | ForEach-Object { $_.Trim() }) -join ','
}

function Get-TaskNames([string]$WorldName) {
    return ,@("Everlast $WorldName server")
}

function Remove-EverlastTasks([string]$WorldName, [string]$Root) {
    $names = Get-TaskNames $WorldName
    $serverTask = Get-ScheduledTask -TaskName $names[0] -ErrorAction SilentlyContinue
    if ($null -ne $serverTask) {
        if (Test-Path -LiteralPath (Join-Path $Root 'stop-server.ps1')) {
            try {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'stop-server.ps1')
            }
            catch {
                Write-Warning "The server did not finish its graceful stop. The scheduled task will be stopped now. $($_.Exception.Message)"
            }
        }
        Stop-ScheduledTask -TaskName $names[0] -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Get-CimInstance Win32_Process -Filter "Name = 'Raptor.Game.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith((Join-Path $Root 'server'), [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
        Unregister-ScheduledTask -TaskName $names[0] -Confirm:$false
    }
}

if ($Help) {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    exit 0
}
if ($env:OS -ne 'Windows_NT') {
    throw 'This installer runs only on Windows.'
}
if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'Everlast Dedicated Server requires 64-bit Windows.'
}

$defaultInstall = Join-Path $env:USERPROFILE 'EverlastServer'
# Run from an install folder (to change settings or uninstall), that install is the default.
if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'install.json'))) { $defaultInstall = $PSScriptRoot }
$defaultData = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games\Everlast Dedicated Server'
$installWasPassed = $PSBoundParameters.ContainsKey('InstallDir')
$InstallDir = if ($installWasPassed) { [IO.Path]::GetFullPath($InstallDir) } elseif ($Uninstall -or $Yes) { $defaultInstall } else { [IO.Path]::GetFullPath((Read-Plain 'Install folder' $defaultInstall)) }
$recordPath = Join-Path $InstallDir 'install.json'
$record = Get-JsonFile $recordPath

if ($Uninstall) {
    $recordWorld = if ($null -ne $record) { [string](Get-Property $record 'World' 'Dedicated') } elseif ($PSBoundParameters.ContainsKey('World')) { $World } else { 'Dedicated' }
    $recordData = if ($null -ne $record) { [string](Get-Property $record 'DataDir' $defaultData) } elseif ($PSBoundParameters.ContainsKey('DataDir')) { $DataDir } else { $defaultData }
    if (Test-PathInside $recordData $InstallDir) {
        Write-Host "The data folder '$recordData' is inside the install folder. Move the data folder out before uninstalling. Nothing was removed."
        exit 1
    }
    Write-Host "Stopping and removing Everlast tasks for $recordWorld."
    Remove-EverlastTasks $recordWorld $InstallDir
    $rulePrefix = "Everlast $recordWorld"
    $removeRules = "Get-NetFirewallRule -DisplayName '$($rulePrefix.Replace("'", "''"))*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule"
    Invoke-FirewallScript $removeRules
    if (Test-Path -LiteralPath $InstallDir) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
    }
    $deleteData = $false
    if (-not $Yes -and (Test-Path -LiteralPath $recordData)) {
        $deleteData = Get-YesNoOption '' $false "Delete world data at $recordData" $false
    }
    if ($deleteData) {
        $ownedWorlds = Join-Path $recordData 'Worlds'
        $ownedSettings = Join-Path $recordData 'appsettings.json'
        if (Test-Path -LiteralPath $ownedWorlds) { Remove-Item -LiteralPath $ownedWorlds -Recurse -Force }
        if (Test-Path -LiteralPath $ownedSettings) { Remove-Item -LiteralPath $ownedSettings -Force }
        if ((Test-Path -LiteralPath $recordData) -and @(Get-ChildItem -LiteralPath $recordData -Force).Count -eq 0) {
            Remove-Item -LiteralPath $recordData -Force
        }
        Write-Host "Removed Everlast world data from $recordData."
    }
    else {
        Write-Host "Kept world data at $recordData."
    }
    Write-Host 'Everlast Dedicated Server was uninstalled.'
    exit 0
}

Write-Host ''
Write-Host 'Install' -ForegroundColor Cyan
$dataDefaultFromRecord = if ($null -ne $record) { [string](Get-Property $record 'DataDir' $defaultData) } else { $defaultData }
if ($PSBoundParameters.ContainsKey('DataDir')) {
    $DataDir = [IO.Path]::GetFullPath($DataDir)
}
elseif ($Yes) {
    $DataDir = [IO.Path]::GetFullPath($dataDefaultFromRecord)
}
else {
    $DataDir = [IO.Path]::GetFullPath((Read-Plain 'Data folder for worlds and settings' $dataDefaultFromRecord))
}
if (Test-PathInside $DataDir $InstallDir) {
    if ($Yes -or $PSBoundParameters.ContainsKey('DataDir')) {
        throw 'The data folder must be outside the install folder so uninstall cannot delete worlds.'
    }
    do {
        Write-Host 'The data folder must be outside the install folder so uninstall cannot delete worlds.' -ForegroundColor Yellow
        $DataDir = [IO.Path]::GetFullPath((Read-Plain 'Data folder for worlds and settings' $defaultData))
    } while (Test-PathInside $DataDir $InstallDir)
}
$worldDefault = if ($null -ne $record) { [string](Get-Property $record 'World' 'Dedicated') } else { 'Dedicated' }
$World = Get-TextOption $World ($PSBoundParameters.ContainsKey('World')) 'World folder name' $worldDefault { param($v) $v -match '^[A-Za-z0-9_-]{1,32}$' } 'Use 1 to 32 letters, digits, hyphens, or underscores.'

$worldDir = Join-Path (Join-Path $DataDir 'Worlds') $World
$worldSettingsPath = Join-Path $worldDir 'worldsettings.json'
$appSettingsPath = Join-Path $DataDir 'appsettings.json'
$existingWorld = Get-JsonFile $worldSettingsPath
$existingApp = Get-JsonFile $appSettingsPath
$isExistingWorld = $null -ne $existingWorld
$existingNetwork = if ($null -ne $existingApp) { Get-Property $existingApp 'NetworkConfig' $null } else { $null }

Write-Host ''
Write-Host 'Server' -ForegroundColor Cyan
$ServerName = Get-TextOption $ServerName ($PSBoundParameters.ContainsKey('ServerName')) 'Server name shown in the server browser' ([string](Get-Property $existingNetwork 'Name' 'Everlast Dedicated Server')) { param($v) -not [string]::IsNullOrWhiteSpace($v) -and $v.Length -le 64 } 'Enter 1 to 64 characters.'
$Port = Get-IntOption $Port ($PSBoundParameters.ContainsKey('Port')) 'Game port, UDP' ([int](Get-Property $existingNetwork 'Port' 9003)) 1 65535
$derivedQueryPort = 27016 + ($Port % 5)
$existingQueryPort = [int](Get-Property $existingNetwork 'QueryPort' 0)
$queryPortDefault = if ($existingQueryPort -gt 0 -and $existingQueryPort -le 65535 -and $existingQueryPort -ne $Port) { $existingQueryPort } else { $derivedQueryPort }
$QueryPort = Get-IntOption $QueryPort ($PSBoundParameters.ContainsKey('QueryPort')) 'Query port (UDP) for the server browser' $queryPortDefault 1 65535
if ($QueryPort -eq $Port) {
    if ($PSBoundParameters.ContainsKey('QueryPort') -or $Yes) { throw 'Query port must be different from the game port.' }
    do {
        Write-Host 'Query port must be different from the game port.' -ForegroundColor Yellow
        $QueryPort = Get-IntOption $null $false 'Query port (UDP) for the server browser' $queryPortDefault 1 65535
    } while ($QueryPort -eq $Port)
}
$existingRegion = [string](Get-Property $existingNetwork 'Location' 'Usa')
$regionDefault = switch ($existingRegion.ToLowerInvariant()) { '0' { 'Usa' } 'usa' { 'Usa' } '1' { 'Eu' } 'eu' { 'Eu' } '2' { 'Oce' } 'oce' { 'Oce' } default { 'Usa' } }
$Region = Get-TextOption $Region ($PSBoundParameters.ContainsKey('Region')) 'Region shown in the server browser (Usa, Eu or Oce)' $regionDefault { param($v) $v -match '^(?i:usa|eu|oce)$' } 'Enter Usa, Eu or Oce.'
$Region = switch ($Region.ToLowerInvariant()) { 'usa' { 'Usa' } 'eu' { 'Eu' } 'oce' { 'Oce' } }
$MaxPlayers = Get-IntOption $MaxPlayers ($PSBoundParameters.ContainsKey('MaxPlayers')) 'Max players online at once' ([int](Get-Property $existingWorld 'MaxPlayers' 100)) 1 1000

Write-Host ''
Write-Host 'Access' -ForegroundColor Cyan
$Password = Get-TextOption $Password ($PSBoundParameters.ContainsKey('Password')) 'Join password, empty allows anyone to join' ([string](Get-Property $existingWorld 'ServerPassword' '')) { param($v) $null -ne $v } 'Enter a password or leave it empty.' -Secret
$Admins = Get-TextOption $Admins ($PSBoundParameters.ContainsKey('Admins')) 'Admin Steam IDs for admin commands in game, comma separated' ([string](Get-Property $existingWorld 'Admins' '')) { param($v) Test-SteamIds $v } 'Enter 17-digit SteamID64 values separated by commas.'
$Admins = Normalize-SteamIds $Admins

Write-Host ''
Write-Host 'World' -ForegroundColor Cyan
if ($isExistingWorld) {
    $Difficulty = [string](Get-Property $existingWorld 'Difficulty' 'Psychic')
    Write-Host "This world already exists. Its difficulty is $Difficulty and can never change."
}
else {
    if (-not $Yes -and -not $PSBoundParameters.ContainsKey('Difficulty')) {
        Write-Host 'Hylic: A forgiving world for exploring at your own pace.'
        Write-Host 'Psychic (Standard): The intended experience. Other difficulties are measured against it.'
        Write-Host 'Pneumonic: Fiercer fights, faster progress.'
        Write-Host 'Pyrrhic: Rich rewards, ruinous deaths.'
        Write-Host 'The Sufferer: Brutal and unforgiving. What death takes, it keeps.'
        Write-Host 'One Shot: One life. When you die, your story ends.'
        Write-Host 'Difficulty can never change after the world is created.' -ForegroundColor Yellow
    }
    $Difficulty = Get-TextOption $Difficulty ($PSBoundParameters.ContainsKey('Difficulty')) 'Difficulty' 'Psychic' { param($v) $v -in @('Hylic', 'Psychic', 'Pneumonic', 'Pyrrhic', 'Sufferer', 'OneShot') } 'Choose Hylic, Psychic, Pneumonic, Pyrrhic, Sufferer, or OneShot.'
}
$WorldDisplayName = Get-TextOption $WorldDisplayName ($PSBoundParameters.ContainsKey('WorldDisplayName')) 'World name players see' ([string](Get-Property $existingWorld 'DisplayName' $World)) { param($v) -not [string]::IsNullOrWhiteSpace($v) } 'Enter a world display name.'
$Description = Get-TextOption $Description ($PSBoundParameters.ContainsKey('Description')) 'Short description for the server browser' ([string](Get-Property $existingWorld 'Description' '')) { param($v) $null -ne $v -and $v.Length -le 120 } 'Enter no more than 120 characters.'

Write-Host ''
Write-Host 'Gameplay' -ForegroundColor Cyan
$PvPEnabled = Get-YesNoOption $PvP ($PSBoundParameters.ContainsKey('PvP')) 'Players can attack each other' ([bool](Get-Property $existingWorld 'PvPEnabled' $true))
$existingPenalty = [string](Get-Property $existingWorld 'DeathPenalty' 'DeathContainer')
$penaltyDefault = if ($existingPenalty -eq 'KeepInventory') { 'keep' } else { 'shop' }
$DeathPenalty = Get-TextOption $DeathPenalty ($PSBoundParameters.ContainsKey('DeathPenalty')) "Death penalty, shop sends items to Death's shop and keep keeps items. Some difficulties decide this themselves" $penaltyDefault { param($v) $v -in @('shop', 'keep') } 'Enter shop or keep.'
$deathPenaltyValue = if ($DeathPenalty -eq 'keep') { 'KeepInventory' } else { 'DeathContainer' }
$XpRate = Get-DecimalOption $XpRate ($PSBoundParameters.ContainsKey('XpRate')) 'Experience multiplier' ([decimal](Get-Property $existingWorld 'XpRate' 1))
$GatherRate = Get-DecimalOption $GatherRate ($PSBoundParameters.ContainsKey('GatherRate')) 'Gathering multiplier' ([decimal](Get-Property $existingWorld 'GatherRate' 1))
$LootRate = Get-DecimalOption $LootRate ($PSBoundParameters.ContainsKey('LootRate')) 'Loot multiplier' ([decimal](Get-Property $existingWorld 'LootRate' 1))

$existingRespawn = if ($null -ne $existingApp) { Get-Property $existingApp 'RespawnScalingConfig' $null } else { $null }
Write-Host ''
Write-Host 'Respawn scaling' -ForegroundColor Cyan
$RespawnScalingEnabled = Get-YesNoOption $RespawnScaling ($PSBoundParameters.ContainsKey('RespawnScaling')) 'Respawn monsters and resources faster when several players are nearby' ([bool](Get-Property $existingRespawn 'Enabled' $true))
if ($RespawnScalingEnabled) {
    $RespawnRadius = Get-DecimalOption $RespawnRadius ($PSBoundParameters.ContainsKey('RespawnRadius')) 'How close players must be to count, in metres (1 to 500)' ([decimal](Get-Property $existingRespawn 'RadiusMeters' 50)) 1 500
    $RespawnSpeedup = Get-DecimalOption $RespawnSpeedup ($PSBoundParameters.ContainsKey('RespawnSpeedup')) 'Speedup each extra nearby player adds (0 to 10)' ([decimal](Get-Property $existingRespawn 'PerPlayerSpeedup' 0.5)) 0 10
    $RespawnFloor = Get-DecimalOption $RespawnFloor ($PSBoundParameters.ContainsKey('RespawnFloor')) 'Shortest respawn time as a fraction of normal (0.05 to 1)' ([decimal](Get-Property $existingRespawn 'MinMultiplier' 0.25)) 0.05 1
}

Write-Host ''
Write-Host 'Characters' -ForegroundColor Cyan
$MaxCharacters = Get-IntOption $MaxCharacters ($PSBoundParameters.ContainsKey('MaxCharacters')) 'Characters per Steam account' ([int](Get-Property $existingWorld 'MaxCharactersPerUser' 10)) 1 100
$TransfersEnabled = Get-YesNoOption $Transfers ($PSBoundParameters.ContainsKey('Transfers')) 'Accept characters from other worlds' ([bool](Get-Property $existingWorld 'AcceptsTransfers' $false))
$MaxImportLevel = Get-IntOption $MaxImportLevel ($PSBoundParameters.ContainsKey('MaxImportLevel')) 'Highest level allowed in, where 0 allows any level' ([int](Get-Property $existingWorld 'MaxImportLevel' 0)) 0 2147483647
$StripGearEnabled = Get-YesNoOption $StripGear ($PSBoundParameters.ContainsKey('StripGear')) 'Remove gear from arriving characters' ([bool](Get-Property $existingWorld 'StripGearOnImport' $false))
$ImportAllowlist = Get-TextOption $ImportAllowlist ($PSBoundParameters.ContainsKey('ImportAllowlist')) 'Steam IDs allowed to bring characters in, empty allows everyone' ([string](Get-Property $existingWorld 'ImportAllowlist' '')) { param($v) Test-SteamIds $v } 'Enter 17-digit SteamID64 values separated by commas.'
$ImportAllowlist = Normalize-SteamIds $ImportAllowlist

Write-Host ''
Write-Host 'Running' -ForegroundColor Cyan
$ServiceEnabled = Get-YesNoOption $Service ($PSBoundParameters.ContainsKey('Service')) 'Start at logon and keep running' $true
$FirewallEnabled = Get-YesNoOption $Firewall ($PSBoundParameters.ContainsKey('Firewall')) 'Open the game and query ports in Windows Firewall' $true

if ($PSBoundParameters.ContainsKey('Archive') -and $Steam) {
    throw 'Use either -Archive or -Steam, not both.'
}
$archiveWasPassed = $PSBoundParameters.ContainsKey('Archive')
$archiveMode = if ($archiveWasPassed) { $true } elseif ($Steam) { $false } else { $null -ne $record -and [bool](Get-Property $record 'ArchiveMode' $false) }
$keepArchiveServer = $archiveMode -and -not $archiveWasPassed
if ($archiveWasPassed) {
    if (-not (Test-Path -LiteralPath $Archive -PathType Leaf)) { throw "Archive file '$Archive' does not exist." }
    $Archive = [IO.Path]::GetFullPath($Archive)
}
elseif ($archiveMode) {
    $Archive = [string](Get-Property $record 'ArchivePath' '')
    Write-Host 'Keeping the installed archive server. Use -Steam to switch this install to Steam downloads.'
}
$steamBranch = if ([string]::IsNullOrWhiteSpace($env:EVERLAST_STEAM_BRANCH)) { [string](Get-Property $record 'SteamBranch' 'public') } else { $env:EVERLAST_STEAM_BRANCH }

Write-Host ''
Write-Host 'Install summary' -ForegroundColor Cyan
Write-Host "Install folder: $InstallDir"
Write-Host "Data folder: $DataDir"
Write-Host "World: $World ($WorldDisplayName)"
Write-Host "Server: $ServerName"
Write-Host "Region: $Region"
Write-Host "Game and query ports: $Port UDP, $QueryPort UDP"
Write-Host "Players and difficulty: $MaxPlayers, $Difficulty"
Write-Host "Join password: $(if ([string]::IsNullOrEmpty($Password)) { 'empty' } else { 'set' })"
Write-Host "Admins: $(if ([string]::IsNullOrEmpty($Admins)) { 'empty' } else { $Admins })"
Write-Host "Rates: XP $XpRate, gather $GatherRate, loot $LootRate"
Write-Host "Respawn scaling: $(if ($RespawnScalingEnabled) { "yes, radius $RespawnRadius m, speedup $RespawnSpeedup, floor $RespawnFloor" } else { 'no' })"
Write-Host "Transfers: $TransfersEnabled"
Write-Host "Start at logon: $ServiceEnabled"
Write-Host "Windows Firewall: $FirewallEnabled"
Write-Host "Install source: $(if ($archiveMode) { 'release archive' } else { "Steam branch $steamBranch" })"
if (-not $Yes) {
    $continue = Get-YesNoOption '' $false 'Continue with this installation' $true
    if (-not $continue) {
        Write-Host 'Installation cancelled.'
        exit 0
    }
}

# Stop the running server before changing its files, because Windows refuses to replace a DLL it has loaded. Players
# get the 2 minute warning. The recorded world is the one running, also when this run changes the world name.
$runningWorld = if ($null -ne $record) { [string](Get-Property $record 'World' $World) } else { $World }
if ($null -ne (Get-ScheduledTask -TaskName (Get-TaskNames $runningWorld)[0] -ErrorAction SilentlyContinue)) {
    Write-Host 'Stopping the running server. Players get a 2 minute warning, then it saves.'
    Remove-EverlastTasks $runningWorld $InstallDir
}

$rootPath = [IO.Path]::GetPathRoot($InstallDir)
$drive = New-Object IO.DriveInfo $rootPath
if ($drive.AvailableFreeSpace -lt 6GB) {
    throw "The drive containing '$InstallDir' needs at least 6 GB free."
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
New-Item -ItemType Directory -Path $worldDir -Force | Out-Null
$serverDir = Join-Path $InstallDir 'server'
$steamCmdDir = Join-Path $InstallDir 'steamcmd'
New-Item -ItemType Directory -Path $serverDir -Force | Out-Null

if ($null -eq (Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue)) {
    throw 'PowerShell Invoke-WebRequest is required to download SteamCMD.'
}
New-Item -ItemType Directory -Path $steamCmdDir -Force | Out-Null
$steamCmdExe = Join-Path $steamCmdDir 'steamcmd.exe'
if (-not (Test-Path -LiteralPath $steamCmdExe)) {
    $steamZip = Join-Path $env:TEMP 'everlast-steamcmd.zip'
    Write-Host 'Downloading SteamCMD for Windows.'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip' -OutFile $steamZip
    Expand-Archive -LiteralPath $steamZip -DestinationPath $steamCmdDir -Force
    Remove-Item -LiteralPath $steamZip -Force
}

$passwordPath = Join-Path $InstallDir 'steam-branch-password.txt'
if ($steamBranch -eq 'public') {
    Remove-Item -LiteralPath $passwordPath -Force -ErrorAction SilentlyContinue
}
elseif (-not [string]::IsNullOrWhiteSpace($env:EVERLAST_STEAM_BRANCH_PASSWORD)) {
    $protectedPassword = ConvertTo-SecureString $env:EVERLAST_STEAM_BRANCH_PASSWORD -AsPlainText -Force | ConvertFrom-SecureString
    Write-Utf8NoBom $passwordPath ($protectedPassword + [Environment]::NewLine)
    & icacls.exe $passwordPath /inheritance:r /grant:r "${env:USERNAME}:(F)" | Out-Null
}
Write-Host 'Preparing the Steam game server libraries.'
& $steamCmdExe +quit | Out-Host

if ($archiveMode -and $archiveWasPassed) {
    Write-Host "Installing the win-x64 server from $Archive."
    Expand-Archive -LiteralPath $Archive -DestinationPath $serverDir -Force
}
elseif ($archiveMode) {
    if (-not (Test-Path -LiteralPath (Join-Path $serverDir 'Raptor.Game.exe'))) {
        throw "The recorded archive server is missing from '$serverDir'. Pass -Archive with a win-x64 release zip."
    }
}
else {
    $steamCommands = @("force_install_dir `"$serverDir`"", 'login anonymous')
    $branchPassword = $env:EVERLAST_STEAM_BRANCH_PASSWORD
    if (-not [string]::IsNullOrWhiteSpace($branchPassword)) {
        $steamCommands += "app_update 4268160 -beta $steamBranch -betapassword $branchPassword validate"
    }
    elseif ($steamBranch -ne 'public') {
        $steamCommands += "app_update 4268160 -beta $steamBranch validate"
    }
    else {
        $steamCommands += 'app_update 4268160 validate'
    }
    $steamCommands += 'quit'
    $steamOutput = Invoke-SteamRunscript $steamCmdExe $steamCommands $branchPassword
    Write-Host $steamOutput
    if ($steamOutput -notmatch "Success! App '4268160' (fully installed|already up to date)") {
        throw 'Steam could not download Everlast Dedicated Server. Check the SteamCMD output above, and the branch and branch password if you set them, or use -Archive with a win-x64 release zip.'
    }
}

$serverExe = Join-Path $serverDir 'Raptor.Game.exe'
if (-not (Test-Path -LiteralPath $serverExe -PathType Leaf)) {
    throw "The server executable was not found at '$serverExe'. Check that this is a win-x64 server archive."
}

$now = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')
if ($null -eq $existingWorld) {
    $worldSettings = [PSCustomObject][ordered]@{}
}
else {
    $worldSettings = $existingWorld
}
$worldValues = [ordered]@{
    DisplayName = $WorldDisplayName
    Description = $Description
    MaxPlayers = $MaxPlayers
    PvPEnabled = $PvPEnabled
    XpRate = $XpRate
    GatherRate = $GatherRate
    LootRate = $LootRate
    DeathPenalty = $deathPenaltyValue
    Difficulty = $Difficulty
    AcceptsTransfers = $TransfersEnabled
    MaxCharactersPerUser = $MaxCharacters
    MaxImportLevel = $MaxImportLevel
    StripGearOnImport = $StripGearEnabled
    ImportAllowlist = $ImportAllowlist
    Admins = $Admins
    OriginServerId = [string](Get-Property $existingWorld 'OriginServerId' '')
    ServerPassword = $Password
    CreatedDate = [string](Get-Property $existingWorld 'CreatedDate' $now)
    LastPlayedDate = [string](Get-Property $existingWorld 'LastPlayedDate' $now)
}
foreach ($entry in $worldValues.GetEnumerator()) {
    Set-JsonProperty $worldSettings $entry.Key $entry.Value
}
Write-Utf8NoBom $worldSettingsPath ((ConvertTo-ReadableJson $worldSettings 20) + [Environment]::NewLine)

if ($null -eq $existingApp) {
    $appSettings = [PSCustomObject][ordered]@{}
}
else {
    $appSettings = $existingApp
}
$networkSettings = Get-Property $appSettings 'NetworkConfig' $null
if ($null -eq $networkSettings) {
    $networkSettings = [PSCustomObject][ordered]@{}
    Set-JsonProperty $appSettings 'NetworkConfig' $networkSettings
}
Set-JsonProperty $networkSettings 'Name' $ServerName
Set-JsonProperty $networkSettings 'Port' $Port
Set-JsonProperty $networkSettings 'QueryPort' $QueryPort
Set-JsonProperty $networkSettings 'Location' $Region
$respawnSettings = Get-Property $appSettings 'RespawnScalingConfig' $null
if ($null -eq $respawnSettings) {
    $respawnSettings = [PSCustomObject][ordered]@{}
    Set-JsonProperty $appSettings 'RespawnScalingConfig' $respawnSettings
}
Set-JsonProperty $respawnSettings 'Enabled' $RespawnScalingEnabled
if ($RespawnScalingEnabled) {
    Set-JsonProperty $respawnSettings 'RadiusMeters' $RespawnRadius
    Set-JsonProperty $respawnSettings 'PerPlayerSpeedup' $RespawnSpeedup
    Set-JsonProperty $respawnSettings 'MinMultiplier' $RespawnFloor
}
Write-Utf8NoBom $appSettingsPath ((ConvertTo-ReadableJson $appSettings 20) + [Environment]::NewLine)

$installedScriptPath = Join-Path $InstallDir 'install.ps1'
$currentScriptPath = [IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
if (-not $currentScriptPath.Equals([IO.Path]::GetFullPath($installedScriptPath), [StringComparison]::OrdinalIgnoreCase)) {
    Copy-Item -LiteralPath $currentScriptPath -Destination $installedScriptPath -Force
}

$installRecord = [ordered]@{
    InstallDir = $InstallDir
    DataDir = $DataDir
    World = $World
    ArchiveMode = $archiveMode
    ArchivePath = if ($archiveMode) { $Archive } else { '' }
    SteamBranch = $steamBranch
}
Write-Utf8NoBom $recordPath (($installRecord | ConvertTo-Json -Depth 4) + [Environment]::NewLine)
& icacls.exe $recordPath /inheritance:r /grant:r "${env:USERNAME}:(F)" | Out-Null

$runServer = @'
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$record = Get-Content -LiteralPath (Join-Path $root 'install.json') -Raw | ConvertFrom-Json
$serverDir = Join-Path $root 'server'
$exe = Join-Path $serverDir 'Raptor.Game.exe'
$stopFlag = Join-Path $root 'stop.flag'
$args = @('--environment', 'standalone', "--LaunchConfig:DataRoot=$($record.DataDir)", "--LaunchConfig:WorldName=$($record.World)", '--LaunchConfig:SinglePlayerMode=false')
$env:DOTNET_ENVIRONMENT = 'standalone'
function Copy-SteamLibraries {
    $steamRoot = Join-Path $root 'steamcmd'
    foreach ($name in @('steamclient64.dll', 'tier0_s64.dll', 'vstdlib_s64.dll')) {
        $source = Get-ChildItem -LiteralPath $steamRoot -Recurse -File -Filter $name -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } | Select-Object -First 1
        if ($null -ne $source) { Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $serverDir $name) -Force }
    }
}
function Update-Server {
    if ($record.ArchiveMode) {
        Copy-SteamLibraries
        return
    }
    $steam = Join-Path $root 'steamcmd\steamcmd.exe'
    $passwordPath = Join-Path $root 'steam-branch-password.txt'
    $password = ''
    if (Test-Path -LiteralPath $passwordPath) {
        $secure = Get-Content -LiteralPath $passwordPath -Raw | ConvertTo-SecureString
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    }
    $commands = @("force_install_dir `"$serverDir`"", 'login anonymous')
    if (-not [string]::IsNullOrWhiteSpace($password)) {
        $commands += "app_update 4268160 -beta $($record.SteamBranch) -betapassword $password validate"
    }
    elseif ($record.SteamBranch -ne 'public') {
        $commands += "app_update 4268160 -beta $($record.SteamBranch) validate"
    }
    else {
        $commands += 'app_update 4268160 validate'
    }
    $commands += 'quit'
    $scriptPath = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($scriptPath, (($commands -join [Environment]::NewLine) + [Environment]::NewLine), (New-Object Text.UTF8Encoding $false))
        & icacls.exe $scriptPath /inheritance:r /grant:r "${env:USERNAME}:(F)" | Out-Null
        $output = (& $steam '+@sSteamCmdForcePlatformType' 'windows' '+runscript' $scriptPath 2>&1 | Out-String)
        if (-not [string]::IsNullOrEmpty($password)) { $output = $output.Replace($password, '***') }
    }
    finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
    if ($output -notmatch "Success! App '4268160' (fully installed|already up to date)") {
        if (Test-Path -LiteralPath $exe) { Write-Warning 'SteamCMD update failed. Starting the installed server.' }
        else { throw 'SteamCMD update failed and no installed server is available.' }
    }
    Copy-SteamLibraries
}
while (-not (Test-Path -LiteralPath $stopFlag)) {
    try {
        Update-Server
        if (-not (Test-Path -LiteralPath $exe)) { throw "Server executable not found at '$exe'." }
        Push-Location $serverDir
        try { & $exe @args }
        finally { Pop-Location }
    }
    catch { Write-Error $_ }
    if (-not (Test-Path -LiteralPath $stopFlag)) { Start-Sleep -Seconds 5 }
}
'@
Write-Utf8NoBom (Join-Path $InstallDir 'run-server.ps1') $runServer


$stopServer = @'
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$record = Get-Content -LiteralPath (Join-Path $root 'install.json') -Raw | ConvertFrom-Json
$serverDir = Join-Path $root 'server'
$exe = Join-Path $serverDir 'Raptor.Game.exe'
$stopFlag = Join-Path $root 'stop.flag'
New-Item -ItemType File -Path $stopFlag -Force | Out-Null
$args = @('--admin', 'stop', '--environment', 'standalone', "--LaunchConfig:DataRoot=$($record.DataDir)", "--LaunchConfig:WorldName=$($record.World)", '--LaunchConfig:SinglePlayerMode=false')
if (Test-Path -LiteralPath $exe) {
    Push-Location $serverDir
    try { & $exe @args }
    catch { Write-Warning "The graceful stop command failed. $($_.Exception.Message)" }
    finally { Pop-Location }
}
$deadline = [DateTime]::UtcNow.AddSeconds(180)
do {
    $running = @(Get-CimInstance Win32_Process -Filter "Name = 'Raptor.Game.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($serverDir, [StringComparison]::OrdinalIgnoreCase) })
    if ($running.Count -eq 0) { exit 0 }
    Start-Sleep -Seconds 2
} while ([DateTime]::UtcNow -lt $deadline)
throw 'The server did not stop within 180 seconds.'
'@
Write-Utf8NoBom (Join-Path $InstallDir 'stop-server.ps1') $stopServer

$startServer = @'
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$record = Get-Content -LiteralPath (Join-Path $root 'install.json') -Raw | ConvertFrom-Json
$flag = Join-Path $root 'stop.flag'
if (Test-Path -LiteralPath $flag) { Remove-Item -LiteralPath $flag -Force }
Start-ScheduledTask -TaskName "Everlast $($record.World) server"
'@
Write-Utf8NoBom (Join-Path $InstallDir 'start-server.ps1') $startServer

$steamRoot = Join-Path $InstallDir 'steamcmd'
$copiedSteamClient = $false
foreach ($name in @('steamclient64.dll', 'tier0_s64.dll', 'vstdlib_s64.dll')) {
    $source = Get-ChildItem -LiteralPath $steamRoot -Recurse -File -Filter $name -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } | Select-Object -First 1
    if ($null -ne $source) {
        Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $serverDir $name) -Force
        if ($name -eq 'steamclient64.dll') { $copiedSteamClient = $true }
    }
}
if (-not $copiedSteamClient) {
    throw "SteamCMD did not install steamclient64.dll under '$steamRoot'."
}

$taskNames = Get-TaskNames $World
if (Test-Path -LiteralPath (Join-Path $InstallDir 'stop.flag')) { Remove-Item -LiteralPath (Join-Path $InstallDir 'stop.flag') -Force }
if ($ServiceEnabled) {
    $quotedRun = '"' + (Join-Path $InstallDir 'run-server.ps1') + '"'
    $serverAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $quotedRun"
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    $serverSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $taskNames[0] -Action $serverAction -Trigger $trigger -Principal $principal -Settings $serverSettings -Force | Out-Null
}

$rulePrefix = "Everlast $World"
if ($FirewallEnabled) {
    $firewallCode = @"
Get-NetFirewallRule -DisplayName '$($rulePrefix.Replace("'", "''"))*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName '$($rulePrefix.Replace("'", "''")) game' -Direction Inbound -Action Allow -Protocol UDP -LocalPort $Port | Out-Null
New-NetFirewallRule -DisplayName '$($rulePrefix.Replace("'", "''")) query' -Direction Inbound -Action Allow -Protocol UDP -LocalPort $QueryPort | Out-Null
"@
    Write-Host 'Adding Windows Firewall rules.'
    Invoke-FirewallScript $firewallCode
}
else {
    $removeFirewall = "Get-NetFirewallRule -DisplayName '$($rulePrefix.Replace("'", "''"))*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule"
    Invoke-FirewallScript $removeFirewall
}

# The server log while the server writes it. Opened with ReadWrite sharing, so it never blocks the server.
function Read-LogFrom([string]$Path, [long]$Offset) {
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
        try {
            if ($stream.Length -lt $Offset) { $Offset = 0 }
            [void]$stream.Seek($Offset, [IO.SeekOrigin]::Begin)
            return (New-Object IO.StreamReader($stream)).ReadToEnd()
        }
        finally { $stream.Dispose() }
    }
    catch { return '' }
}

if ($ServiceEnabled) {
    $serverLog = Join-Path $worldDir 'server.log'
    $logStart = if (Test-Path -LiteralPath $serverLog) { (Get-Item -LiteralPath $serverLog).Length } else { 0 }
    Start-ScheduledTask -TaskName $taskNames[0]
    Write-Host 'Starting the server. A Steam install updates first, which can take a few minutes.'
    $deadline = [DateTime]::UtcNow.AddMinutes(15)
    $ready = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        if ((Read-LogFrom $serverLog $logStart) -match 'SERVER_READY') { $ready = $true; break }
        Start-Sleep -Seconds 5
    }
    if ($ready) {
        Write-Host 'The server is running.'
        # Steam lists the server a few seconds after it is ready.
        $connected = $false
        for ($i = 0; $i -lt 15; $i++) {
            if ((Read-LogFrom $serverLog $logStart) -match 'Connected to Steam master server') { $connected = $true; break }
            Start-Sleep -Seconds 2
        }
        if ($connected) { Write-Host 'It is connected to Steam, so it shows in the server browser.' }
        else { Write-Host 'It has not connected to Steam after 30 seconds. Check the server log if it does not show in the server browser.' -ForegroundColor Yellow }
    }
    else {
        Write-Host 'The server did not report ready within 15 minutes. Its last lines:' -ForegroundColor Yellow
        (Read-LogFrom $serverLog 0) -split "`r?`n" | Select-Object -Last 15 | ForEach-Object { Write-Host $_ }
        Write-Host "The scheduled task keeps trying to start it. Stop it with: powershell -ExecutionPolicy Bypass -File `"$(Join-Path $InstallDir 'stop-server.ps1')`""
        exit 1
    }
}


Write-Host ''
Write-Host 'Everlast Dedicated Server is installed.' -ForegroundColor Green
Write-Host "Server files: $serverDir"
Write-Host "World data: $DataDir"
Write-Host "Forward $Port UDP and $QueryPort UDP in your router."
if ($ServiceEnabled) {
    Write-Host "Stop: powershell -ExecutionPolicy Bypass -File `"$(Join-Path $InstallDir 'stop-server.ps1')`""
    Write-Host "Start: powershell -ExecutionPolicy Bypass -File `"$(Join-Path $InstallDir 'start-server.ps1')`""
    Write-Host 'Update: run Stop, then Start. Steam installs update before starting.'
}
else {
    Write-Host "Start by hand: powershell -ExecutionPolicy Bypass -File `"$(Join-Path $InstallDir 'run-server.ps1')`""
}
Write-Host "Change settings: powershell -ExecutionPolicy Bypass -File `"$installedScriptPath`" -InstallDir `"$InstallDir`""
Write-Host "Uninstall: powershell -ExecutionPolicy Bypass -File `"$installedScriptPath`" -InstallDir `"$InstallDir`" -Uninstall -Yes"
Write-Host "Server log: $(Join-Path $worldDir 'server.log')"
