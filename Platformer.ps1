<#
    PowerShell Platformer - engine (PowerShell + WPF, Windows only)

    Run it with:
        powershell -STA -ExecutionPolicy Bypass -File .\Platformer.ps1

    Features
      - Main menu, world browser, loading screen, world hub with 3 save slots, stats screen
      - Worlds are self-contained .zip files: images, levels, physics, stats and saves all live inside
      - Physics can be tuned per world, per level and per mount (values are checked and clamped)
      - Levels can have several areas joined by doors, pipes and tunnels (optionally locked)
      - Swimming (no power-up needed), crouching, mounts (like a horse), power-ups (fireballs,
        ice that freezes enemies into pushable blocks, flying, double jump, invincibility, speed),
        coins, collectibles, keys and lock blocks
      - Health: normal (one hit), powered up (a hit takes you back to normal), invincible (timed)
      - Rising and falling water and lava, moving platforms and crushers
      - Enemies that patrol, follow, jump, fly and swim in any combination, and can stop or
        turn into platforms when you look at them
      - Custom animations for the player, power-up forms, enemies and mounts (frames + spin)
      - Checkpoints autosave progress; "Save and quit" lets you continue later from a slot
      - Keys carry between levels; levels can have several exits and hidden levels to unlock
      - Keyboard and Xbox-style (XInput) controllers

    Worlds live in:  Documents\PSPlatformer\Worlds\*.zip
    The world format is described in README.md, and New-SampleWorld (near the bottom) builds a full example.
#>

# ---------------------------------------------------------------------------
# WPF needs an STA thread. Relaunch the script in STA mode if necessary.
# ---------------------------------------------------------------------------
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    if (-not $PSCommandPath) { Write-Error 'Save this as a .ps1 file and run it with -STA.'; return }
    $exe = (Get-Process -Id $PID).Path
    Start-Process $exe -ArgumentList '-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

# ---------------------------------------------------------------------------
# Controller support (XInput: Xbox controllers, and most others through Steam or similar)
# ---------------------------------------------------------------------------
$PadSupport = $false
try {
    if (-not ('XInputPad' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class PadState {
    public bool Connected;
    public int Index;
    public ushort Buttons;
    public short LX;
    public short LY;
    public byte LT;
    public byte RT;
}

public static class XInputPad {
    [StructLayout(LayoutKind.Sequential)]
    struct GAMEPAD { public ushort wButtons; public byte bLeftTrigger; public byte bRightTrigger; public short sThumbLX; public short sThumbLY; public short sThumbRX; public short sThumbRY; }
    [StructLayout(LayoutKind.Sequential)]
    struct STATE { public uint dwPacketNumber; public GAMEPAD Gamepad; }

    [DllImport("xinput1_4.dll", EntryPoint = "XInputGetState")]   static extern uint Get14(uint index, out STATE state);
    [DllImport("xinput9_1_0.dll", EntryPoint = "XInputGetState")] static extern uint Get91(uint index, out STATE state);

    static int dll = 0;   // 0 = try xinput1_4, 1 = use xinput9_1_0, 2 = no XInput on this PC

    static uint Get(uint index, out STATE state) {
        state = new STATE();
        if (dll == 0) {
            try { return Get14(index, out state); }
            catch (Exception) { dll = 1; }   // DLL missing or unusable: try the older one
        }
        if (dll == 1) {
            try { return Get91(index, out state); }
            catch (Exception) { dll = 2; }   // no XInput at all: controllers are simply unavailable
        }
        return 1167;   // ERROR_DEVICE_NOT_CONNECTED
    }

    public static PadState Read(int index) {
        PadState p = new PadState();
        p.Index = index;
        STATE s;
        if (Get((uint)index, out s) == 0) {
            p.Connected = true;
            p.Buttons = s.Gamepad.wButtons;
            p.LX = s.Gamepad.sThumbLX;
            p.LY = s.Gamepad.sThumbLY;
            p.LT = s.Gamepad.bLeftTrigger;
            p.RT = s.Gamepad.bRightTrigger;
        }
        return p;
    }

    public static PadState FindFirst() {
        for (int i = 0; i < 4; i++) {
            PadState p = Read(i);
            if (p.Connected) return p;
        }
        return new PadState();
    }
}
'@
    }
    $PadSupport = $true
}
catch { $PadSupport = $false }

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
$GameTitle     = 'POWERSHELL PLATFORMER'
$MaxLevels     = 11             # per chapter (a world plus its expansions can have several chapters)
$MaxChapters   = 9
$SlotCount     = 3
$InventorySize = 8              # keys held + power-ups stored
$ViewW         = 960            # game view in pixels (the window scales it)
$ViewH         = 544            # 17 rows of 32px tiles
$MaxAreaPixels = 25000000       # biggest area bitmap allowed (width x height in pixels)
$ReservedChars = 'PGC.0123456789 '

# Every physics setting a world, level or mount can change: default, minimum, maximum.
# Speeds are pixels per second, accelerations pixels per second squared, times in seconds.
$PhysicsSpec = [ordered]@{
    gravity         = @(2200, 100, 10000)
    maxFall         = @(900, 50, 3000)
    runSpeed        = @(240, 20, 2000)
    jumpSpeed       = @(800, 0, 4000)
    groundAccel     = @(2200, 50, 20000)
    airAccel        = @(1500, 0, 20000)
    groundFriction  = @(2600, 0, 20000)
    airFriction     = @(800, 0, 20000)
    shortHopGravity = @(2.5, 1, 10)       # extra gravity when jump is released early
    coyoteTime      = @(0.10, 0, 1)       # can still jump this long after leaving a ledge
    jumpBuffer      = @(0.12, 0, 1)       # a jump pressed this long before landing still counts
    stompBounce     = @(480, 0, 4000)
    airJumps        = @(0, 0, 10)         # extra jumps in mid-air
    waterGravity    = @(500, 0, 10000)
    waterMaxFall    = @(160, 10, 3000)
    swimStroke      = @(320, 0, 4000)     # upward speed of one swim stroke
    swimSpeed       = @(0.6, 0.05, 3)     # run speed multiplier in water
    waterExitJump   = @(650, 0, 4000)     # boost when jumping out of water
    crouchSpeed     = @(0.35, 0, 2)       # run speed multiplier while crouching
    lavaBounce      = @(900, 0, 4000)     # how hard lava throws you up when it can't kill you
    sandSinkSpeed   = @(45, 1, 1000)      # how fast you sink in quicksand
    sandSpeed       = @(0.35, 0, 2)       # run speed multiplier in quicksand
    sandJump        = @(420, 0, 4000)     # upward pop from each jump press in quicksand
    climbSpeed      = @(150, 0, 2000)     # speed on ladders and vines
    hurtBounce      = @(560, 0, 4000)     # how high a hit (enemy, spikes, hazard) throws you
    hurtKnockback   = @(260, 0, 4000)     # how hard a hit pushes you sideways, away from what hit you
}

# What the hero mumbles when left alone long enough to doze off (worlds can replace these)
$DefaultSleepTalk = @(
    'mmm... ravioli...'
    '...ravioli... with the little fork...'
    'no... that''s MY ravioli... zzz'
    '...one more ravioli... then I''ll save the world...'
    '...cheese ravioli... spinach ravioli... ALL the ravioli...'
    'zzz... pasta la vista... zzz'
    '...the ravioli... it''s... so square...'
)

# Spike directions (a tile can point several ways at once)
$SpikeBits = @{ up = 1; down = 2; left = 4; right = 8 }

# Controls: action -> keyboard keys and controller buttons (controller names start with Pad)
$ActionKeys = @{
    Left     = 'Left', 'A', 'PadLeft'
    Right    = 'Right', 'D', 'PadRight'
    Up       = 'Up', 'W', 'PadUp'
    Down     = 'Down', 'S', 'PadDown'
    Jump     = 'Space', 'Z', 'Up', 'W', 'PadA'
    Fire     = 'E', 'X', 'F', 'LeftCtrl', 'RightCtrl', 'PadX', 'PadB', 'PadRT'
    Dismount = 'C', 'PadY'
    Swap     = 'Tab', 'Q', 'PadBack', 'PadLB'
}

$GameDir   = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PSPlatformer'
$WorldsDir = Join-Path $GameDir 'Worlds'
New-Item -ItemType Directory -Path $WorldsDir -Force | Out-Null

$LoadingTips = @(
    'Tip: Hold jump to jump higher. Tap it for a short hop.',
    'Tip: Land on top of an enemy to defeat it. Spiky ones cannot be stomped!',
    'Tip: In water, press jump to swim upward. Hold Down to dive.',
    'Tip: Press Up at a door and Down on a pipe to go through.',
    'Tip: Touch a mount to ride it. Press C (or Y on a controller) to get off.',
    'Tip: Checkpoints save your progress automatically.',
    'Tip: A key opens every connected lock block of the same colour.',
    'Tip: Press Esc (or Start) to pause. You can save and quit from there.',
    'Tip: Plug in a controller any time. A jumps, X or B throws fireballs.',
    'Tip: Hold Down to crouch and crawl through low gaps.',
    'Tip: Freeze an enemy with the Ice Flower, then push the ice block and climb on it.',
    'Tip: Some ghosts stop when you look at them. Others turn into blocks you can stand on.',
    'Tip: Watch the water and lava - in some levels they rise and fall.',
    'Tip: Lava takes your power-up and throws you up. While invincible, hold Down to swim in it.',
    'Tip: Sinking in quicksand? Keep pressing jump to climb out. Secrets can hide at the bottom.'
)

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
function ConvertTo-Brush([string]$Hex) {
    try { (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex) }
    catch { [System.Windows.Media.Brushes]::Magenta }
}

function Get-OrDefault($Value, $Default) {
    if ($null -eq $Value -or "$Value" -eq '') { $Default } else { $Value }
}

# Reads a number from world.json, falling back to a default and clamping to a safe range
function Read-Number($Value, [double]$Default, [double]$Min, [double]$Max, [string]$Label, $Warnings) {
    if ($null -eq $Value -or "$Value" -eq '') { return $Default }
    $n = 0.0
    if (-not [double]::TryParse("$Value", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
        $Warnings.Add("$Label should be a number (got '$Value'); using $Default.")
        return $Default
    }
    if ($n -lt $Min -or $n -gt $Max) {
        $clamped = [math]::Max($Min, [math]::Min($Max, $n))
        $Warnings.Add("$Label = $n is outside $Min to $Max; using $clamped.")
        return $clamped
    }
    $n
}

# The properties of an object from world.json (nothing at all when the section is missing)
function Get-JsonProperties($Object) {
    if ($null -eq $Object -or $Object -is [string] -or $Object -is [ValueType]) { return }
    $Object.PSObject.Properties
}

function Read-Bool($Value, [bool]$Default) {
    if ($null -eq $Value) { return $Default }
    if ($Value -is [string]) { return $Value -eq 'true' }
    [bool]$Value
}

function Copy-Hashtable($Source) {
    $copy = @{}
    if ($Source) { foreach ($k in @($Source.Keys)) { $copy[$k] = $Source[$k] } }
    $copy
}

function Format-Time($Seconds) {
    if ($null -eq $Seconds) { return '--:--' }
    $s = [double]$Seconds
    '{0}:{1:00.00}' -f [int][math]::Floor($s / 60), ($s % 60)
}

function Format-Duration([double]$Seconds) {
    $span = [TimeSpan]::FromSeconds($Seconds)
    if ($span.TotalHours -ge 1)       { '{0}h {1:00}m' -f [int][math]::Floor($span.TotalHours), $span.Minutes }
    elseif ($span.TotalMinutes -ge 1) { '{0}m {1:00}s' -f $span.Minutes, $span.Seconds }
    else                              { '{0}s' -f $span.Seconds }
}

function New-Rect([double]$X, [double]$Y, [double]$Width, [double]$Height) { [System.Windows.Rect]::new($X, $Y, $Width, $Height) }
function New-Point([double]$X, [double]$Y) { [System.Windows.Point]::new($X, $Y) }

# ---------------------------------------------------------------------------
# Physics settings
# ---------------------------------------------------------------------------
function New-DefaultPhysics {
    $p = @{}
    foreach ($k in $PhysicsSpec.Keys) { $p[$k] = [double]$PhysicsSpec[$k][0] }
    $p
}

# Turns a "physics" object from world.json into checked values (only the keys that were given)
function Read-PhysicsOverrides($Source, [string]$Label, $Warnings) {
    $out = @{}
    if ($null -eq $Source) { return $out }
    foreach ($prop in @(Get-JsonProperties $Source)) {
        $name = @($PhysicsSpec.Keys) | Where-Object { $_ -eq $prop.Name } | Select-Object -First 1
        if (-not $name) { $Warnings.Add("$($Label): unknown setting '$($prop.Name)' was ignored."); continue }
        $spec = $PhysicsSpec[$name]
        $out[$name] = Read-Number $prop.Value $spec[0] $spec[1] $spec[2] "$Label $name" $Warnings
    }
    $out
}

function Merge-Physics($Base, $Overrides) {
    $p = @{}
    foreach ($k in @($Base.Keys)) { $p[$k] = $Base[$k] }
    if ($Overrides) { foreach ($k in @($Overrides.Keys)) { $p[$k] = $Overrides[$k] } }
    $p
}

# ---------------------------------------------------------------------------
# Zip helpers
# ---------------------------------------------------------------------------
# Index of every file in the zip, with forward slashes and case-insensitive names.
# If everything sits inside one top-level folder, that folder becomes the root.
function Get-ZipIndex($Zip) {
    $map = @{}
    foreach ($entry in $Zip.Entries) {
        $name = $entry.FullName.Replace('\', '/')
        if ($name.EndsWith('/')) { continue }
        $map[$name] = $entry
    }
    $worldJson = $map.Keys |
        Where-Object { $_ -eq 'world.json' -or $_ -like '*/world.json' } |
        Sort-Object { ($_ -split '/').Count } |
        Select-Object -First 1
    if (-not $worldJson) { throw 'world.json was not found in the zip.' }
    @{ Map = $map; Root = $worldJson.Substring(0, $worldJson.Length - 'world.json'.Length); WorldJsonKey = $worldJson }
}

function Get-ZipEntry($Index, [string]$RelativePath) {
    if (-not $RelativePath) { return $null }
    $Index.Map[$Index.Root + $RelativePath.Replace('\', '/').TrimStart('/')]
}

function Read-ZipText($Entry) {
    $reader = New-Object System.IO.StreamReader($Entry.Open(), [System.Text.Encoding]::UTF8)
    try { $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function ConvertTo-Bitmap([byte[]]$Bytes) {
    $ms = New-Object System.IO.MemoryStream(, $Bytes)
    $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.CacheOption  = 'OnLoad'
    $bmp.StreamSource = $ms
    $bmp.EndInit()
    $bmp.Freeze()
    $ms.Dispose()
    $bmp
}

function Read-ZipImage($Entry) {
    $ms = New-Object System.IO.MemoryStream
    $stream = $Entry.Open()
    try { $stream.CopyTo($ms) } finally { $stream.Dispose() }
    ConvertTo-Bitmap $ms.ToArray()
}

# Safely writes files into a world zip: the changes go into a copy first, and the copy
# replaces the original only when it is complete. A crash mid-save can't damage the world.
function Write-ZipEntries([string]$Path, [string]$Root, $Set, $Remove) {
    $tmp = "$Path.saving"
    Copy-Item -LiteralPath $Path -Destination $tmp -Force
    try {
        $zip = [System.IO.Compression.ZipFile]::Open($tmp, [System.IO.Compression.ZipArchiveMode]::Update)
        try {
            $targets = @(@($Set.Keys) + @($Remove) | ForEach-Object { $Root + $_ })
            @($zip.Entries | Where-Object { $targets -contains $_.FullName.Replace('\', '/') }) | ForEach-Object { $_.Delete() }
            foreach ($name in @($Set.Keys)) {
                $stream = $zip.CreateEntry($Root + $name).Open()
                try { $bytes = [byte[]]$Set[$name]; $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
            }
        }
        finally { $zip.Dispose() }
        try { [System.IO.File]::Replace($tmp, $Path, $null) }
        catch { Copy-Item -LiteralPath $tmp -Destination $Path -Force; Remove-Item -LiteralPath $tmp -Force }
    }
    catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

# ---------------------------------------------------------------------------
# Stats (stats.json, all slots together) and save slots (saves/slotN.json)
# ---------------------------------------------------------------------------
function New-EmptyStats { @{ formatVersion = 2; totalPlaySeconds = 0.0; lastSlot = 1; levels = @{} } }

function ConvertFrom-StatsJson([string]$Json) {
    $stats = New-EmptyStats
    if (-not $Json) { return $stats }
    $obj = $Json | ConvertFrom-Json
    if ($obj.totalPlaySeconds) { $stats.totalPlaySeconds = [double]$obj.totalPlaySeconds }
    if ($obj.lastSlot) { $stats.lastSlot = [int]$obj.lastSlot }
    foreach ($prop in @(Get-JsonProperties $obj.levels)) {
        $v = $prop.Value
        $stats.levels[$prop.Name] = @{
            tries       = [int]$v.tries
            deaths      = [int]$v.deaths
            completions = [int]$v.completions
            bestTime    = if ($null -ne $v.bestTime) { [double]$v.bestTime } else { $null }
        }
    }
    $stats
}

function Get-LevelStats($Stats, [int]$Number) {
    $key = "$Number"
    if (-not $Stats.levels.ContainsKey($key)) {
        $Stats.levels[$key] = @{ tries = 0; deaths = 0; completions = 0; bestTime = $null }
    }
    $Stats.levels[$key]
}

function Get-StatsTotals($Stats) {
    $totals = @{ Tries = 0; Deaths = 0 }
    foreach ($key in @($Stats.levels.Keys)) {
        $totals.Tries  += $Stats.levels[$key].tries
        $totals.Deaths += $Stats.levels[$key].deaths
    }
    $totals
}

# Everything a save has done, for the review screen
function New-Record {
    @{
        tries = 0; deaths = 0; enemies = 0; coinsCollected = 0; coinsSpent = 0; livesFound = 0; livesBought = 0
        minigamesPlayed = 0; minigameCoins = 0; levelsCompleted = 0
        bosses = New-Object System.Collections.ArrayList
        powers = @{}; powersBought = @{}; powersLost = @{}; items = @{}; deathsBy = @{}
    }
}

function New-SlotData {
    @{
        formatVersion = 1
        coins         = 0
        completed     = New-Object System.Collections.ArrayList   # level numbers finished
        taken         = @{}                                        # level -> coin/collectible ids collected for good
        power         = $null                                      # power-up key carried between levels
        shield        = $false
        keys          = @{}                                        # keys carried between levels: keyId -> count
        unlocked      = New-Object System.Collections.ArrayList   # level numbers opened up by exits
        stash         = New-Object System.Collections.ArrayList   # power-ups stored in the inventory (item symbols)
        lives         = $null                                      # lives left ($null = not set yet)
        gameOver      = $false                                     # out of lives: the save can only be reviewed
        tetrominoes   = New-Object System.Collections.ArrayList   # shh: the secret game's pieces found so far
        record        = New-Record                                 # everything that happened, for the review screen
        minigames     = @{}                                        # mini-game id -> when it was last played (UTC)
        exits         = New-Object System.Collections.ArrayList   # exits found, as "level:symbol"
        resume        = $null                                      # where "Continue" starts
        playSeconds   = 0.0
        updated       = ''
    }
}

function ConvertFrom-SlotJson([string]$Json) {
    if (-not $Json) { return $null }
    $o = $Json | ConvertFrom-Json
    $slot = New-SlotData
    $slot.coins       = [int]$o.coins
    $slot.power       = if ($o.power) { "$($o.power)" } else { $null }
    $slot.shield      = [bool]$o.shield
    $slot.playSeconds = [double]$o.playSeconds
    $slot.updated     = "$($o.updated)"
    foreach ($n in @($o.completed)) { if ($null -ne $n) { [void]$slot.completed.Add([int]$n) } }
    foreach ($n in @($o.unlocked)) { if ($null -ne $n) { [void]$slot.unlocked.Add([int]$n) } }
    foreach ($x in @($o.exits)) { if ($x) { [void]$slot.exits.Add("$x") } }
    foreach ($x in @($o.stash)) { if ($x) { [void]$slot.stash.Add("$x") } }
    if ($null -ne $o.lives) { $slot.lives = [int]$o.lives }
    $slot.gameOver = [bool]$o.gameOver
    foreach ($x in @($o.tetrominoes)) { if ($x -and -not $slot.tetrominoes.Contains("$x")) { [void]$slot.tetrominoes.Add("$x") } }
    if ($o.record) {
        foreach ($prop in @(Get-JsonProperties $o.record)) {
            $v = $prop.Value
            if ($v -is [array]) { $slot.record[$prop.Name] = New-Object System.Collections.ArrayList; foreach ($x in $v) { [void]$slot.record[$prop.Name].Add("$x") } }
            elseif ($null -ne $v -and $v -isnot [ValueType] -and $v -isnot [string]) { $h = @{}; foreach ($q in @(Get-JsonProperties $v)) { $h[$q.Name] = [int]$q.Value }; $slot.record[$prop.Name] = $h }
            elseif ($null -ne $v) { $slot.record[$prop.Name] = [double]$v }
        }
    }
    foreach ($prop in @(Get-JsonProperties $o.minigames)) { if ($prop.Value) { $slot.minigames[$prop.Name] = "$($prop.Value)" } }
    foreach ($prop in @(Get-JsonProperties $o.keys)) { if ([int]$prop.Value -gt 0) { $slot.keys[$prop.Name] = [int]$prop.Value } }
    if (-not $o.PSObject.Properties['unlocked']) { $slot.NeedsUnlockUpgrade = $true }   # saved by an older version
    foreach ($prop in @(Get-JsonProperties $o.taken)) {
        $list = New-Object System.Collections.ArrayList
        foreach ($id in @($prop.Value)) { if ($id) { [void]$list.Add("$id") } }
        $slot.taken[$prop.Name] = $list
    }
    if ($o.resume -and $o.resume.level) {
        $r = $o.resume
        $keys = @{}
        foreach ($prop in @(Get-JsonProperties $r.keys)) { $keys[$prop.Name] = [int]$prop.Value }
        $slot.resume = @{
            level        = [int]$r.level
            area         = if ($r.area) { "$($r.area)" } else { $null }
            x            = if ($null -ne $r.x) { [int]$r.x } else { $null }
            y            = if ($null -ne $r.y) { [int]$r.y } else { $null }
            power        = if ($r.power) { "$($r.power)" } else { $null }
            shield       = [bool]$r.shield
            time         = [double]$r.time
            runCommitted = @(@($r.runCommitted) | Where-Object { $_ } | ForEach-Object { "$_" })
            keys         = $keys
            stash        = if ($r.PSObject.Properties['stash']) { @(@($r.stash) | Where-Object { $_ } | ForEach-Object { "$_" }) } else { $null }
        }
    }
    $slot
}

function Get-CurrentSlot {
    $world = $script:World
    if (-not $world.Slots[$world.SlotNumber]) {
        $new = New-SlotData
        if ($world.Lives -gt 0) { $new.lives = $world.Lives }
        $world.Slots[$world.SlotNumber] = $new
    }
    $world.Slots[$world.SlotNumber]
}

# Lives left in a save ($null = no limit in this world)
function Get-SlotLives($Slot) {
    $world = $script:World
    if ($world.Lives -le 0) { return $null }
    if (-not $Slot -or $null -eq $Slot.lives) { return $world.Lives }
    [int]$Slot.lives
}

# Adds to the save's record (for the review screen). Mini-games only count where they say -Always.
function Add-Record([string]$Field, [string]$Name = '', [double]$N = 1, [switch]$Always) {
    $R = $script:Run
    if ($R -and $R.MiniGame -and -not $Always) { return }
    $slot = if ($R) { $R.Slot } else { Get-CurrentSlot }
    if (-not $slot.record) { $slot.record = New-Record }
    $rec = $slot.record
    if ($Field -eq 'bosses') {
        if (-not $rec.bosses) { $rec.bosses = New-Object System.Collections.ArrayList }
        if (-not $rec.bosses.Contains($Name)) { [void]$rec.bosses.Add($Name) }
        return
    }
    if ($Name) {
        if ($rec[$Field] -isnot [hashtable]) { $rec[$Field] = @{} }
        $rec[$Field][$Name] = [int]$rec[$Field][$Name] + [int]$N
    }
    else { $rec[$Field] = [double]$rec[$Field] + $N }
}

function Get-SlotTakenCount($Slot, [int]$Level, [string]$Prefix) {
    if (-not $Slot) { return 0 }
    $list = $Slot.taken["$Level"]
    if (-not $list) { return 0 }
    @($list | Where-Object { $_.StartsWith($Prefix) }).Count
}

# Saves stats and every save slot back into the world zip
function Save-WorldData {
    $world = $script:World
    if (-not $world) { return $false }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $world.Stats.lastSlot = $world.SlotNumber
    $current = $world.Slots[$world.SlotNumber]
    if ($current) { $current.updated = (Get-Date).ToString('yyyy-MM-dd HH:mm') }

    $set = [ordered]@{ 'stats.json' = $utf8.GetBytes(($world.Stats | ConvertTo-Json -Depth 10)) }
    $remove = New-Object System.Collections.Generic.List[string]
    for ($n = 1; $n -le $SlotCount; $n++) {
        $name = "saves/slot$n.json"
        if ($world.Slots[$n]) { $set[$name] = $utf8.GetBytes(($world.Slots[$n] | ConvertTo-Json -Depth 10)) }
        else { $remove.Add($name) }
    }
    try {
        Write-ZipEntries $world.Path $world.Root $set $remove
        $true
    }
    catch {
        $msg = "Progress could not be saved into the zip: $($_.Exception.Message)"
        if (-not $world.Warnings.Contains($msg)) { $world.Warnings.Add($msg) }
        $false
    }
}

# Quick look at a world zip for the world list and stats screen
function Get-WorldSummary([string]$Path) {
    $zip = $null
    try {
        $zip   = [System.IO.Compression.ZipFile]::OpenRead($Path)
        $index = Get-ZipIndex $zip
        $def   = Read-ZipText $index.Map[$index.WorldJsonKey] | ConvertFrom-Json
        $levelCount = [math]::Min(@($def.levels | Where-Object { $_ }).Count, $MaxLevels)
        $wname = Get-OrDefault $def.name ([IO.Path]::GetFileNameWithoutExtension($Path))
        $chapterIds = Get-ChapterList $index $def
        foreach ($cid in $chapterIds) {
            $ce = Get-ZipEntry $index "chapters/$cid/world.json"
            if ($ce) { try { $levelCount += [math]::Min(@((Read-ZipText $ce | ConvertFrom-Json).levels | Where-Object { $_ }).Count, $MaxLevels) } catch { } }
        }
        $statsEntry = Get-ZipEntry $index 'stats.json'
        $stats  = ConvertFrom-StatsJson $(if ($statsEntry) { Read-ZipText $statsEntry })
        $totals = Get-StatsTotals $stats
        $best = 0; $saves = 0
        for ($n = 1; $n -le $SlotCount; $n++) {
            $e = Get-ZipEntry $index "saves/slot$n.json"
            if ($e) {
                try { $s = ConvertFrom-SlotJson (Read-ZipText $e); $saves++; $best = [math]::Max($best, $s.completed.Count) } catch { }
            }
        }
        $thumb = $null
        $thumbEntry = Get-ZipEntry $index $def.thumbnail
        if ($thumbEntry) { try { $thumb = Read-ZipImage $thumbEntry } catch { } }
        [pscustomobject]@{
            Path        = $Path
            Id          = ConvertTo-WorldId "$(Get-OrDefault $def.id $wname)"
            ExpansionOf = if ($def.expansionOf) { ConvertTo-WorldId "$($def.expansionOf)" } else { $null }
            Chapters    = @($chapterIds)
            Name        = $wname
            Byline      = "by $(Get-OrDefault $def.author 'Unknown')   -   $(Split-Path -Leaf $Path)"
            Description = $(if ($def.expansionOf) { "EXPANSION for '$($def.expansionOf)' - load it to add it to that world.  " } else { '' }) + "$($def.description)" + $(if ($chapterIds.Count) { "  (+$($chapterIds.Count) expansion chapter$(if ($chapterIds.Count -gt 1) { 's' }))" } else { '' })
            Progress    = "Best save: $best/$levelCount levels    Saves $saves/$SlotCount    Tries $($totals.Tries)    Deaths $($totals.Deaths)    Played $(Format-Duration $stats.totalPlaySeconds)"
            Thumbnail   = $thumb
            LevelCount  = $levelCount
            Completed   = $best
            Tries       = $totals.Tries
            Deaths      = $totals.Deaths
            PlaySeconds = $stats.totalPlaySeconds
            Error       = $null
        }
    }
    catch {
        [pscustomobject]@{
            Path = $Path; Name = [IO.Path]::GetFileNameWithoutExtension($Path); Byline = Split-Path -Leaf $Path
            Description = "This world can't be loaded: $($_.Exception.Message)"; Progress = ''; Thumbnail = $null
            LevelCount = 0; Completed = 0; Tries = 0; Deaths = 0; PlaySeconds = 0; Error = $_.Exception.Message
        }
    }
    finally { if ($zip) { $zip.Dispose() } }
}

function Get-WorldFiles {
    @(Get-ChildItem -LiteralPath $WorldsDir -File | Where-Object { $_.Extension -eq '.zip' } | Sort-Object Name)
}

# Summaries for the world list. An expansion zip that has already been added to its world
# is hidden, so the combined world shows up once.
function Get-ShownWorldSummaries {
    $all = @(Get-WorldFiles | ForEach-Object { Get-WorldSummary $_.FullName })
    $added = @{}
    foreach ($s in $all) {
        if ($s.Error -or $s.ExpansionOf) { continue }
        foreach ($c in @($s.Chapters)) { if ($c) { $added["$($s.Id)|$c"] = $true } }
    }
    @($all | Where-Object { -not ($_.ExpansionOf -and $added.ContainsKey("$($_.ExpansionOf)|$($_.Id)")) })
}

# ---------------------------------------------------------------------------
# Window layout (XAML)
# ---------------------------------------------------------------------------
[xml]$MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PowerShell Platformer" Width="1000" Height="600" MinWidth="500" MinHeight="320"
        WindowStartupLocation="CenterScreen" Background="#0B0D1A" FontFamily="Segoe UI"
        UseLayoutRounding="True">
    <Window.Resources>
        <Style x:Key="MenuButton" TargetType="Button">
            <Setter Property="Foreground" Value="#EEF0FF"/>
            <Setter Property="Background" Value="#2A3060"/>
            <Setter Property="FontSize" Value="20"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Width" Value="300"/>
            <Setter Property="Margin" Value="0,6"/>
            <Setter Property="Padding" Value="18,8"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Focusable" Value="False"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="10"
                                Padding="{TemplateBinding Padding}" BorderBrush="#3D4580" BorderThickness="2">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="#FFC83D"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#FFC83D"/>
                                <Setter Property="Foreground" Value="#12152A"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.45"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="SmallButton" TargetType="Button" BasedOn="{StaticResource MenuButton}">
            <Setter Property="Width" Value="170"/>
            <Setter Property="FontSize" Value="16"/>
            <Setter Property="Margin" Value="0,0,10,0"/>
            <Setter Property="Padding" Value="12,6"/>
        </Style>
        <Style x:Key="WideButton" TargetType="Button" BasedOn="{StaticResource MenuButton}">
            <Setter Property="Width" Value="Auto"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Margin" Value="0,5,0,0"/>
            <Setter Property="Padding" Value="8,4"/>
        </Style>
        <Style x:Key="SlotButton" TargetType="Button" BasedOn="{StaticResource MenuButton}">
            <Setter Property="Width" Value="Auto"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Margin" Value="2,0"/>
            <Setter Property="Padding" Value="2,4"/>
        </Style>
        <Style x:Key="LevelButton" TargetType="Button" BasedOn="{StaticResource MenuButton}">
            <Setter Property="Width" Value="148"/>
            <Setter Property="Height" Value="112"/>
            <Setter Property="Margin" Value="0,0,8,8"/>
            <Setter Property="Padding" Value="6"/>
            <Setter Property="FontSize" Value="14"/>
        </Style>
    </Window.Resources>

    <Viewbox Stretch="Uniform">
        <Grid Width="960" Height="544" ClipToBounds="True">

            <!-- ============ GAME ============ -->
            <Grid Name="GameLayer" Visibility="Collapsed" RenderOptions.BitmapScalingMode="NearestNeighbor">
                <Rectangle Name="BgRect"/>
                <Canvas Name="WorldCanvas">
                    <Image Name="TileImage" Stretch="Fill"/>
                </Canvas>
                <Canvas Name="FrontCanvas" IsHitTestVisible="False">
                    <Image Name="FrontImage" Stretch="Fill"/>
                </Canvas>
                <Canvas Name="WeatherCanvas" IsHitTestVisible="False" ClipToBounds="True"/>
                <Rectangle Name="DarkRect" IsHitTestVisible="False" Visibility="Collapsed"/>
                <Rectangle Name="FlashRect" Fill="#FFF4F7FF" Opacity="0" IsHitTestVisible="False"/>
                <Rectangle Name="FadeRect" Fill="Black" Opacity="0" IsHitTestVisible="False"/>
                <Border VerticalAlignment="Top" Background="#88000000" Padding="14,5">
                    <StackPanel>
                        <DockPanel>
                            <TextBlock Name="HudRight" DockPanel.Dock="Right" Foreground="White" FontSize="15" FontWeight="SemiBold"/>
                            <TextBlock Name="HudLeft" Foreground="#FFC83D" FontSize="15" FontWeight="Bold" TextTrimming="CharacterEllipsis"/>
                        </DockPanel>
                        <TextBlock Name="HudPower" Foreground="#9FE6FF" FontSize="13" FontWeight="SemiBold" Visibility="Collapsed"/>
                    </StackPanel>
                </Border>
                <Border Name="ToastBox" Visibility="Collapsed" VerticalAlignment="Top" HorizontalAlignment="Center" Margin="0,70,0,0"
                        Background="#DD12152A" CornerRadius="8" Padding="16,7" BorderBrush="#FFC83D" BorderThickness="1">
                    <TextBlock Name="ToastText" Foreground="#FFC83D" FontSize="16" FontWeight="Bold"/>
                </Border>
                <TextBlock Name="DeathText" Visibility="Collapsed" FontSize="64" FontWeight="Black" Foreground="#FF5252"
                           HorizontalAlignment="Center" VerticalAlignment="Center">
                    <TextBlock.Effect><DropShadowEffect Color="Black" BlurRadius="0" ShadowDepth="5" Opacity="0.7"/></TextBlock.Effect>
                </TextBlock>
                <TextBlock Name="HelpText" VerticalAlignment="Bottom" HorizontalAlignment="Center" Margin="0,0,0,5" FontSize="12" Foreground="#CCFFFFFF"
                           Text="">
                    <TextBlock.Effect><DropShadowEffect Color="Black" BlurRadius="0" ShadowDepth="1" Opacity="0.8"/></TextBlock.Effect>
                </TextBlock>
            </Grid>

            <!-- ============ MAIN MENU ============ -->
            <Grid Name="MainMenu">
                <Grid.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                        <GradientStop Color="#1B2050" Offset="0"/>
                        <GradientStop Color="#0B0D1A" Offset="1"/>
                    </LinearGradientBrush>
                </Grid.Background>
                <Path Fill="#151A3D" Data="M0,544 L0,470 Q120,420 240,465 T480,455 T720,470 T960,450 L960,544 Z"/>
                <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                    <TextBlock Name="TitleText" FontSize="52" FontWeight="Black" Foreground="#FFC83D" HorizontalAlignment="Center">
                        <TextBlock.Effect><DropShadowEffect Color="Black" BlurRadius="0" ShadowDepth="5" Opacity="0.6"/></TextBlock.Effect>
                    </TextBlock>
                    <TextBlock Text="Choose a world. Beat its levels." Foreground="#8A90B8" FontSize="16"
                               HorizontalAlignment="Center" Margin="0,0,0,26"/>
                    <Button Name="BtnPlay"   Content="Play"                Style="{StaticResource MenuButton}"/>
                    <Button Name="BtnStats"  Content="Stats"               Style="{StaticResource MenuButton}"/>
                    <Button Name="BtnSample" Content="Create sample world" Style="{StaticResource MenuButton}"/>
                    <Button Name="BtnFolder" Content="Open worlds folder"  Style="{StaticResource MenuButton}"/>
                    <Button Name="BtnExit"   Content="Exit"                Style="{StaticResource MenuButton}"/>
                </StackPanel>
                <TextBlock Name="FolderText" VerticalAlignment="Bottom" HorizontalAlignment="Center" Margin="0,0,0,10"
                           Foreground="#5A608A" FontSize="11"/>
            </Grid>

            <!-- ============ WORLD SELECT ============ -->
            <Grid Name="WorldSelect" Visibility="Collapsed" Background="#12152A">
                <DockPanel Margin="30,22">
                    <TextBlock DockPanel.Dock="Top" Text="Choose a world" FontSize="32" FontWeight="Black" Foreground="#FFC83D"/>
                    <TextBlock DockPanel.Dock="Top" Foreground="#8A90B8" Margin="0,2,0,12"
                               Text="Worlds are .zip files in your worlds folder. Double-click one to load it."/>
                    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,12,0,0">
                        <Button Name="BtnSelectBack" Content="Back"       Style="{StaticResource SmallButton}"/>
                        <Button Name="BtnRefresh"    Content="Refresh"    Style="{StaticResource SmallButton}"/>
                        <Button Name="BtnLoadWorld"  Content="Load world" Style="{StaticResource SmallButton}"/>
                    </StackPanel>
                    <Grid>
                        <ListBox Name="WorldList" Background="Transparent" BorderThickness="0"
                                 ScrollViewer.HorizontalScrollBarVisibility="Disabled">
                            <ListBox.ItemContainerStyle>
                                <Style TargetType="ListBoxItem">
                                    <Setter Property="Template">
                                        <Setter.Value>
                                            <ControlTemplate TargetType="ListBoxItem">
                                                <Border x:Name="Bd" Background="#1E2342" CornerRadius="8" Margin="0,0,0,8"
                                                        Padding="10" BorderThickness="2" BorderBrush="Transparent">
                                                    <ContentPresenter/>
                                                </Border>
                                                <ControlTemplate.Triggers>
                                                    <Trigger Property="IsMouseOver" Value="True">
                                                        <Setter TargetName="Bd" Property="Background" Value="#283062"/>
                                                    </Trigger>
                                                    <Trigger Property="IsSelected" Value="True">
                                                        <Setter TargetName="Bd" Property="BorderBrush" Value="#FFC83D"/>
                                                    </Trigger>
                                                </ControlTemplate.Triggers>
                                            </ControlTemplate>
                                        </Setter.Value>
                                    </Setter>
                                </Style>
                            </ListBox.ItemContainerStyle>
                            <ListBox.ItemTemplate>
                                <DataTemplate>
                                    <DockPanel>
                                        <Border DockPanel.Dock="Left" Width="128" Height="72" CornerRadius="6" Background="#0D1020"
                                                Margin="0,0,14,0" ClipToBounds="True">
                                            <Image Source="{Binding Thumbnail}" Stretch="UniformToFill"/>
                                        </Border>
                                        <StackPanel>
                                            <TextBlock Text="{Binding Name}" FontSize="18" FontWeight="Bold" Foreground="#EEF0FF"/>
                                            <TextBlock Text="{Binding Byline}" FontSize="12" Foreground="#8A90B8"/>
                                            <TextBlock Text="{Binding Description}" FontSize="13" Foreground="#C9CCE8" TextWrapping="Wrap"/>
                                            <TextBlock Text="{Binding Progress}" FontSize="12" Foreground="#FFC83D" Margin="0,4,0,0"/>
                                        </StackPanel>
                                    </DockPanel>
                                </DataTemplate>
                            </ListBox.ItemTemplate>
                        </ListBox>
                        <TextBlock Name="NoWorldsText" Visibility="Collapsed" Foreground="#8A90B8" FontSize="16"
                                   TextAlignment="Center" VerticalAlignment="Center" TextWrapping="Wrap"
                                   Text="No worlds found yet.&#10;Go back and choose 'Create sample world', or copy a world .zip into the worlds folder."/>
                    </Grid>
                </DockPanel>
            </Grid>

            <!-- ============ LOADING ============ -->
            <Grid Name="LoadingScreen" Visibility="Collapsed" Background="#0B0D1A">
                <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center" Width="560">
                    <TextBlock Text="LOADING WORLD" Foreground="#8A90B8" FontSize="14" FontWeight="Bold" HorizontalAlignment="Center"/>
                    <TextBlock Name="LoadTitle" FontSize="36" FontWeight="Black" Foreground="#FFC83D" HorizontalAlignment="Center"
                               TextTrimming="CharacterEllipsis" Margin="0,4,0,22"/>
                    <ProgressBar Name="LoadBar" Height="18" Minimum="0" Maximum="100" Foreground="#FFC83D" Background="#1E2342" BorderThickness="0"/>
                    <TextBlock Name="LoadStatus" Foreground="#C9CCE8" FontSize="13" Margin="0,8,0,0" TextTrimming="CharacterEllipsis"/>
                    <TextBlock Name="LoadTip" Foreground="#5A608A" FontSize="13" Margin="0,34,0,0" TextWrapping="Wrap" TextAlignment="Center"/>
                </StackPanel>
            </Grid>

            <!-- ============ WORLD HUB ============ -->
            <Grid Name="WorldHub" Visibility="Collapsed" Background="#12152A">
                <DockPanel Margin="26,18">
                    <StackPanel DockPanel.Dock="Top">
                        <TextBlock Name="HubName" FontSize="30" FontWeight="Black" Foreground="#FFC83D" TextTrimming="CharacterEllipsis"/>
                        <TextBlock Name="HubAuthor" Foreground="#8A90B8" FontSize="13"/>
                        <TextBlock Name="HubDesc" Foreground="#C9CCE8" FontSize="13" TextWrapping="Wrap" MaxHeight="36" Margin="0,3,0,10"/>
                    </StackPanel>
                    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,8,0,0">
                        <Button Name="BtnHubBack"    Content="Back to worlds" Style="{StaticResource SmallButton}"/>
                        <Button Name="BtnResetStats" Content="Reset stats"    Style="{StaticResource SmallButton}"/>
                        <Button Name="BtnExpansions" Content="Expansions"     Style="{StaticResource SmallButton}"/>
                        <Button Name="BtnWarnings"   Content="Warnings"       Style="{StaticResource SmallButton}"/>
                    </StackPanel>
                    <Border DockPanel.Dock="Right" Width="262" Background="#1E2342" CornerRadius="10" Padding="10,8" Margin="10,0,0,0">
                        <ScrollViewer VerticalScrollBarVisibility="Auto">
                            <StackPanel>
                                <TextBlock Text="SAVE SLOT" Foreground="#FFC83D" FontWeight="Bold" FontSize="12"/>
                                <UniformGrid Columns="3" Margin="-2,4,-2,4">
                                    <Button Name="BtnSlot1" Tag="1" Content="Slot 1" Style="{StaticResource SlotButton}"/>
                                    <Button Name="BtnSlot2" Tag="2" Content="Slot 2" Style="{StaticResource SlotButton}"/>
                                    <Button Name="BtnSlot3" Tag="3" Content="Slot 3" Style="{StaticResource SlotButton}"/>
                                </UniformGrid>
                                <TextBlock Name="SlotInfo" Foreground="#EEF0FF" FontSize="12" LineHeight="16" TextWrapping="Wrap"/>
                                <Button Name="BtnContinue"   Content="Continue"         Style="{StaticResource WideButton}"/>
                                <Button Name="BtnDeleteSlot" Content="Delete this save" Style="{StaticResource WideButton}"/>
                                <UniformGrid Columns="4" Margin="-2,5,-2,0">
                                    <Button Name="BtnRecord"    Content="Log"   Style="{StaticResource SlotButton}"/>
                                    <Button Name="BtnInventory" Content="Bag"   Style="{StaticResource SlotButton}"/>
                                    <Button Name="BtnShop"      Content="Shop"  Style="{StaticResource SlotButton}"/>
                                    <Button Name="BtnMiniGames" Content="Games" Style="{StaticResource SlotButton}"/>
                                </UniformGrid>
                            </StackPanel>
                        </ScrollViewer>
                    </Border>
                    <ScrollViewer VerticalScrollBarVisibility="Auto">
                        <WrapPanel Name="LevelPanel"/>
                    </ScrollViewer>
                </DockPanel>
            </Grid>

            <!-- ============ STATS ============ -->
            <Grid Name="StatsScreen" Visibility="Collapsed" Background="#12152A">
                <DockPanel Margin="30,22">
                    <TextBlock DockPanel.Dock="Top" Text="Stats" FontSize="32" FontWeight="Black" Foreground="#FFC83D"/>
                    <TextBlock DockPanel.Dock="Top" Name="StatsSummary" Foreground="#C9CCE8" FontSize="14" Margin="0,2,0,12"/>
                    <Button DockPanel.Dock="Bottom" Name="BtnStatsBack" Content="Back" Style="{StaticResource SmallButton}"
                            HorizontalAlignment="Left" Margin="0,12,0,0"/>
                    <DataGrid Name="StatsGrid" AutoGenerateColumns="True" IsReadOnly="True" HeadersVisibility="Column"
                              CanUserAddRows="False" GridLinesVisibility="None" BorderThickness="0" FontSize="14"
                              Background="#1E2342" RowBackground="#1E2342" AlternatingRowBackground="#252B52" Foreground="#EEF0FF">
                        <DataGrid.ColumnHeaderStyle>
                            <Style TargetType="DataGridColumnHeader">
                                <Setter Property="Background" Value="#2A3060"/>
                                <Setter Property="Foreground" Value="#FFC83D"/>
                                <Setter Property="FontWeight" Value="Bold"/>
                                <Setter Property="Padding" Value="10,6"/>
                            </Style>
                        </DataGrid.ColumnHeaderStyle>
                    </DataGrid>
                </DockPanel>
            </Grid>

            <!-- ============ BLOCK DROP (secret) ============ -->
            <Grid Name="BlockScreen" Visibility="Collapsed" Background="#0B0D1A">
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
                    <Border BorderBrush="#3D4580" BorderThickness="3" Background="#12152A" CornerRadius="4">
                        <Canvas Name="BlockCanvas" Width="220" Height="440" ClipToBounds="True"/>
                    </Border>
                    <StackPanel Margin="26,0,0,0" Width="230">
                        <TextBlock Text="BLOCK DROP" FontSize="30" FontWeight="Black" Foreground="#FFC83D"/>
                        <TextBlock Text="a secret mini-game" Foreground="#8A90B8" FontSize="12" Margin="0,0,0,18"/>
                        <TextBlock Text="NEXT" Foreground="#8A90B8" FontWeight="Bold" FontSize="13"/>
                        <Canvas Name="BlockNext" Width="88" Height="88" Margin="0,6,0,18" HorizontalAlignment="Left"/>
                        <TextBlock Name="BlockInfo" Foreground="#EEF0FF" FontSize="17" FontFamily="Consolas" LineHeight="27"/>
                        <TextBlock Foreground="#5A608A" FontSize="12" Margin="0,18,0,0" TextWrapping="Wrap"
                                   Text="Left/Right move   Up or X rotate   Down drop faster   Space drop   Esc quit&#10;Controller: D-pad, A rotate, B drop, Start quit&#10;Clear lines for coins: 1 / 3 / 5 / 8"/>
                    </StackPanel>
                </StackPanel>
            </Grid>

            <!-- ============ OVERLAY (pause / level complete / errors) ============ -->
            <Grid Name="Overlay" Visibility="Collapsed" Background="#B0000000">
                <Border Background="#1E2342" CornerRadius="14" Padding="30,22" BorderBrush="#FFC83D" BorderThickness="2"
                        HorizontalAlignment="Center" VerticalAlignment="Center" MinWidth="380" MaxWidth="700">
                    <StackPanel>
                        <TextBlock Name="OverlayTitle" FontSize="32" FontWeight="Black" Foreground="#FFC83D" HorizontalAlignment="Center"/>
                        <TextBlock Name="OverlayText" FontSize="15" Foreground="#EEF0FF" TextAlignment="Center" TextWrapping="Wrap"
                                   Margin="0,8,0,14" LineHeight="23"/>
                        <WrapPanel Name="OverlayButtons" HorizontalAlignment="Center" MaxWidth="640"/>
                    </StackPanel>
                </Border>
            </Grid>
        </Grid>
    </Viewbox>
</Window>
'@

$Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $MainXaml))

# Every named control becomes a variable with the same name ($BtnPlay, $WorldCanvas, ...)
$MainXaml.SelectNodes('//*[@Name]') | ForEach-Object {
    Set-Variable -Name $_.Name -Value $Window.FindName($_.Name) -Scope Script
}

$Screens = 'MainMenu', 'WorldSelect', 'LoadingScreen', 'WorldHub', 'StatsScreen', 'GameLayer', 'BlockScreen'
$TitleText.Text  = $GameTitle
$FolderText.Text = "Worlds folder: $WorldsDir"

# Both world layers scroll with the same camera transform
$CamTransform = New-Object System.Windows.Media.TranslateTransform
$WorldCanvas.RenderTransform = $CamTransform
$FrontCanvas.RenderTransform = $CamTransform

$GlowEffect = New-Object System.Windows.Media.Effects.DropShadowEffect
$GlowEffect.Color = [System.Windows.Media.Color]::FromRgb(0xFF, 0xD6, 0x00)
$GlowEffect.ShadowDepth = 0
$GlowEffect.BlurRadius = 14

$KeyboardHelp = 'Move: Arrows/AD   Jump/Swim: Space/W   Crouch/Pipe/Drop: Down   Climb: Up/Down   Action/Fire/Throw: E   Door: Up   Swap power: Tab/Q   Get off: C   Pause: Esc   Restart: R'
$PadHelp      = 'Move: D-pad/Stick   Jump/Swim: A   Crouch/Pipe/Drop: Down   Fire: X/B/RT   Door: Up   Swap power: Back/LB   Get off: Y   Pause: Start'

# ---------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------
$script:World        = $null     # the loaded world
$script:Run          = $null     # the level being played
$script:MapCache     = @{}       # "level/area" -> built map (collision grids + bitmaps)
$script:Held         = [System.Collections.Generic.HashSet[string]]::new()
$script:Clock        = [System.Diagnostics.Stopwatch]::StartNew()
$script:LastTick     = 0.0
$script:LoopOn       = $false
$script:ToastTimer   = 0.0
$script:OverlayIndex = 0
$script:Pad          = @{ Index = -1; Down = [System.Collections.Generic.HashSet[string]]::new(); NextScan = 0.0 }
$script:RenderHandler = [EventHandler] { Update-Game }

# ---------------------------------------------------------------------------
# Screens, overlay, toast
# ---------------------------------------------------------------------------
function Show-Screen([string]$Name) {
    foreach ($s in $Screens) {
        (Get-Variable -Name $s -Scope Script -ValueOnly).Visibility = if ($s -eq $Name) { 'Visible' } else { 'Collapsed' }
    }
    $Overlay.Visibility = 'Collapsed'
}

# Runs a UI action and shows a message instead of failing silently
function Invoke-Safe([scriptblock]$Action) {
    try { & $Action }
    catch {
        [void][System.Windows.MessageBox]::Show("Something went wrong:`n`n$($_.Exception.Message)`n(line $($_.InvocationInfo.ScriptLineNumber))",
                                                'Error', 'OK', 'Error')
    }
}

# Buttons is a list of @{ Text = '...'; Action = { ... } }. Works with the mouse, arrow keys + Enter, or a controller.
function Show-Overlay([string]$Title, [string]$Text, [object[]]$Buttons) {
    $OverlayTitle.Text = $Title
    $OverlayText.Text  = $Text
    $OverlayButtons.Children.Clear()
    foreach ($b in $Buttons) {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Style   = $Window.FindResource('MenuButton')
        $btn.Margin  = '6,4'
        $btn.Content = $b.Text
        $btn.Tag     = $b.Action
        $btn.Add_Click({ param($s, $e) Invoke-Safe $s.Tag })
        [void]$OverlayButtons.Children.Add($btn)
    }
    $script:OverlayIndex = 0
    Update-OverlaySelection
    $Overlay.Visibility = 'Visible'
}

function Hide-Overlay { $Overlay.Visibility = 'Collapsed' }

function Update-OverlaySelection {
    for ($i = 0; $i -lt $OverlayButtons.Children.Count; $i++) {
        $btn = $OverlayButtons.Children[$i]
        $selected = $i -eq $script:OverlayIndex
        $btn.Background = ConvertTo-Brush $(if ($selected) { '#FFC83D' } else { '#2A3060' })
        $btn.Foreground = ConvertTo-Brush $(if ($selected) { '#12152A' } else { '#EEF0FF' })
    }
}

# Keys and controller buttons while a menu box is showing. Returns $true if used.
function Invoke-OverlayKey([string]$Key) {
    $count = $OverlayButtons.Children.Count
    if ($Key -in 'Up', 'W', 'PadUp') {
        if ($count) { $script:OverlayIndex = ($script:OverlayIndex - 1 + $count) % $count; Update-OverlaySelection }
        return $true
    }
    if ($Key -in 'Down', 'S', 'PadDown') {
        if ($count) { $script:OverlayIndex = ($script:OverlayIndex + 1) % $count; Update-OverlaySelection }
        return $true
    }
    if ($Key -in 'Return', 'Space', 'PadA') {
        if ($count) { Invoke-Safe $OverlayButtons.Children[$script:OverlayIndex].Tag }
        return $true
    }
    if ($Key -in 'Escape', 'PadStart', 'PadB') {
        if ($script:Run -and $script:Run.State -eq 'Paused') { Resume-Game }
        elseif (-not $script:Run -and -not $script:Timing) { Hide-Overlay; if ($script:World) { Show-Hub } }
        return $true
    }
    $false
}

function Show-Toast([string]$Text) {
    $ToastText.Text = $Text
    $ToastBox.Visibility = 'Visible'
    $script:ToastTimer = 2.2
}

# ---------------------------------------------------------------------------
# Input: keyboard and controller share the same path
# ---------------------------------------------------------------------------
# Called when a key or controller button goes down. Returns $true if the game used it.
function Invoke-KeyDown([string]$Key) {
    if ($script:Blocks) { return (Invoke-BlockKey $Key) }
    $R = $script:Run
    if ($Overlay.Visibility -eq 'Visible') { return (Invoke-OverlayKey $Key) }
    if (-not $R) { return $false }
    if ($Key -in 'Escape', 'PadStart') {
        if ($R.State -eq 'Playing') { Suspend-Game }
        return $true
    }
    if ($R.State -ne 'Playing') { return $false }
    if ($Key -eq 'R' -and -not $R.MiniGame) { Start-Level $R.LevelNumber $null; return $true }
    if (-not $script:Held.Add($Key)) { return $true }      # ignore keyboard auto-repeat
    $R.IdleTime = 0.0
    if ($R.Player.Sleeping) { Stop-Sleeping; return $true }  # the first press just wakes the hero up
    if ($ActionKeys.Jump -contains $Key)     { $R.JumpPressed = $true }
    if ($ActionKeys.Up -contains $Key)       { $R.UpPressed = $true }
    if ($ActionKeys.Down -contains $Key)     { $R.DownPressed = $true }
    if ($ActionKeys.Fire -contains $Key)     { $R.FirePressed = $true }
    if ($ActionKeys.Dismount -contains $Key) { $R.DismountPressed = $true }
    if ($ActionKeys.Swap -contains $Key)     { Invoke-PowerSwap }
    $true
}

# Controller buttons still held after a pause or respawn count as held again (but not as new presses)
function Sync-PadHeld {
    foreach ($k in $script:Pad.Down) { [void]$script:Held.Add($k) }
}

# Reads the controller once per frame and turns button changes into key presses
function Update-Pad {
    if (-not $PadSupport) { return }
    $pad = $script:Pad
    $now = $script:Clock.Elapsed.TotalSeconds
    if ($pad.Index -lt 0) {
        if ($now -lt $pad.NextScan) { return }         # looking for controllers is slow, so only every 2 seconds
        $pad.NextScan = $now + 2
        $state = [XInputPad]::FindFirst()
        if (-not $state.Connected) { return }
        $pad.Index = $state.Index
        $HelpText.Text = $PadHelp
        Show-Toast 'Controller connected'
    }
    else {
        $state = [XInputPad]::Read($pad.Index)
        if (-not $state.Connected) {
            $pad.Index = -1
            foreach ($k in @($pad.Down)) { [void]$script:Held.Remove($k) }
            $pad.Down.Clear()
            $HelpText.Text = $KeyboardHelp
            Suspend-Game
            Show-Toast 'Controller disconnected'
            return
        }
    }

    $b = [int]$state.Buttons
    $downNow = [System.Collections.Generic.HashSet[string]]::new()
    if (($b -band 0x0004) -or $state.LX -lt -12000) { [void]$downNow.Add('PadLeft') }
    if (($b -band 0x0008) -or $state.LX -gt 12000)  { [void]$downNow.Add('PadRight') }
    if (($b -band 0x0001) -or $state.LY -gt 16000)  { [void]$downNow.Add('PadUp') }
    if (($b -band 0x0002) -or $state.LY -lt -16000) { [void]$downNow.Add('PadDown') }
    if ($b -band 0x1000) { [void]$downNow.Add('PadA') }
    if ($b -band 0x2000) { [void]$downNow.Add('PadB') }
    if ($b -band 0x4000) { [void]$downNow.Add('PadX') }
    if ($b -band 0x8000) { [void]$downNow.Add('PadY') }
    if ($b -band 0x0010) { [void]$downNow.Add('PadStart') }
    if ($b -band 0x0020) { [void]$downNow.Add('PadBack') }
    if ($b -band 0x0100) { [void]$downNow.Add('PadLB') }
    if ($state.RT -gt 100) { [void]$downNow.Add('PadRT') }

    foreach ($k in @($pad.Down)) {
        if (-not $downNow.Contains($k)) { [void]$script:Held.Remove($k) }
    }
    $pressed = @($downNow | Where-Object { -not $pad.Down.Contains($_) })
    $pad.Down = $downNow
    foreach ($k in $pressed) {
        [void](Invoke-KeyDown $k)
        if ((-not $script:Run -and -not $script:Blocks) -or ($script:Run -and $script:Run.State -eq 'Error')) { break }
    }
}

# ---------------------------------------------------------------------------
# World select and stats screens
# ---------------------------------------------------------------------------
function Show-WorldSelect {
    Show-Screen 'WorldSelect'
    $shown = @(Get-ShownWorldSummaries)
    $WorldList.ItemsSource = $shown
    $NoWorldsText.Visibility = if ($shown.Count) { 'Collapsed' } else { 'Visible' }
    if ($shown.Count) { $WorldList.SelectedIndex = 0 }
}

function Show-StatsScreen {
    Show-Screen 'StatsScreen'
    $summaries = @(Get-ShownWorldSummaries)
    $StatsGrid.ItemsSource = @(foreach ($s in $summaries) {
        [pscustomobject]@{
            World    = $s.Name
            BestSave = if ($s.Error) { 'error' } else { "$($s.Completed) / $($s.LevelCount)" }
            Tries    = $s.Tries
            Deaths   = $s.Deaths
            Played   = Format-Duration $s.PlaySeconds
            File     = Split-Path -Leaf $s.Path
        }
    })
    $tries  = ($summaries | Measure-Object -Property Tries -Sum).Sum
    $deaths = ($summaries | Measure-Object -Property Deaths -Sum).Sum
    $secs   = ($summaries | Measure-Object -Property PlaySeconds -Sum).Sum
    $StatsSummary.Text = "$($summaries.Count) world(s)    Total tries $([int]$tries)    Total deaths $([int]$deaths)    Time played $(Format-Duration ([double]$secs))"
}

# ---------------------------------------------------------------------------
# World loading (one small step per timer tick so the window stays responsive)
# ---------------------------------------------------------------------------
$script:Loader = @{ Queue = New-Object System.Collections.Queue; Total = 0; Done = 0; Zip = $null; Index = $null; World = $null; Path = $null; Started = [DateTime]::Now }
$LoadTimer = New-Object System.Windows.Threading.DispatcherTimer
$LoadTimer.Interval = [TimeSpan]::FromMilliseconds(10)
$LoadTimer.Add_Tick({ Step-WorldLoad })

function Add-LoadStep([string]$Label, [scriptblock]$Action, $Argument) {
    $script:Loader.Queue.Enqueue(@{ Label = $Label; Action = $Action; Argument = $Argument })
    $script:Loader.Total++
}

function Close-LoaderZip {
    if ($script:Loader.Zip) { $script:Loader.Zip.Dispose(); $script:Loader.Zip = $null }
}

function Start-WorldLoad($Summary) {
    if (-not $Summary) { return }
    if ($Summary.Error) {
        [void][System.Windows.MessageBox]::Show("This world can't be loaded.`n`n$($Summary.Error)", 'World error', 'OK', 'Warning')
        return
    }
    if ($Summary.ExpansionOf) {
        # An expansion isn't played on its own: it's added to the world it expands
        $base = @(Get-WorldFiles | ForEach-Object { Get-WorldSummary $_.FullName } | Where-Object { -not $_.ExpansionOf -and $_.Id -eq $Summary.ExpansionOf })
        if (-not $base.Count) {
            [void][System.Windows.MessageBox]::Show("'$($Summary.Name)' is an expansion for the world '$($Summary.ExpansionOf)', which isn't in your worlds folder.", 'Expansion', 'OK', 'Information')
            return
        }
        $answer = [System.Windows.MessageBox]::Show("'$($Summary.Name)' is an expansion for '$($base[0].Name)'.`nAdd it to that world now? Your saves there carry into its levels.", 'Expansion', 'YesNo', 'Question')
        if ("$answer" -ne 'Yes') { return }
        try { [void](Install-Expansion $base[0].Path $Summary.Path) }
        catch { [void][System.Windows.MessageBox]::Show("Couldn't add it: $($_.Exception.Message)", 'Expansion', 'OK', 'Error'); return }
        $script:AfterLoadNote = "Added $($Summary.Name)."
        $Summary = Get-WorldSummary $base[0].Path
    }
    Close-LoaderZip
    $script:Loader.Queue.Clear()
    $script:Loader.Total   = 0
    $script:Loader.Done    = 0
    $script:Loader.World   = $null
    $script:Loader.Path    = $Summary.Path
    $script:Loader.Started = [DateTime]::Now

    Show-Screen 'LoadingScreen'
    $LoadTitle.Text  = $Summary.Name
    $LoadBar.Value   = 0
    $LoadStatus.Text = 'Opening world...'
    $LoadTip.Text    = $LoadingTips | Get-Random

    Add-LoadStep 'Reading world.json' { Read-WorldDefinition } $null
    $LoadTimer.Start()
}

function Step-WorldLoad {
    $L = $script:Loader
    if ($L.Queue.Count -gt 0) {
        $step = $L.Queue.Dequeue()
        try { & $step.Action $step.Argument }
        catch {
            $LoadTimer.Stop()
            Close-LoaderZip
            [void][System.Windows.MessageBox]::Show("Couldn't load this world.`n`nStep: $($step.Label)`n$($_.Exception.Message)",
                                                    'World load failed', 'OK', 'Error')
            Show-WorldSelect
            return
        }
        $L.Done++
        $LoadBar.Value   = 100 * $L.Done / [math]::Max(1, $L.Total)
        $LoadStatus.Text = $step.Label
        return
    }
    if (([DateTime]::Now - $L.Started).TotalSeconds -lt 0.8) { $LoadStatus.Text = 'Ready!'; return }
    $LoadTimer.Stop()
    Close-LoaderZip
    $script:World    = $L.World
    $script:MapCache = @{}
    $script:HubNote = $script:AfterLoadNote; $script:AfterLoadNote = $null
    Show-Hub
}

# Registers a one-character map symbol (tile, enemy, item, mount, platform, exit or spawner).
# A chapter starts with a copy of the main world's symbols and may replace any of them.
function Add-WorldSymbol($Ctx, [string]$Name, [string]$Kind, $Def, [string]$Section) {
    $tag = $Ctx.Tag
    if ($Name.Length -ne 1) { $Ctx.Warnings.Add("$tag$Section key '$Name' skipped: keys must be exactly one character."); return $false }
    if ($ReservedChars.Contains($Name)) { $Ctx.Warnings.Add("$tag$Section key '$Name' skipped: P, G, C, digits, '.' and space are reserved."); return $false }
    $c = [char]$Name
    if ($Ctx.Own.Contains($c)) { $Ctx.Warnings.Add("$tag$Section key '$Name' skipped: already used by a $($Ctx.Symbols[$c].Kind)."); return $false }
    [void]$Ctx.Own.Add($c)
    $Def.Key = $Name
    $Ctx.Symbols[$c] = @{ Kind = $Kind; Def = $Def }
    $true
}

function Get-Background($Value, $Fallback) {
    if ("$Value" -eq 'none') { return $null }
    if ($Value) { return (Resolve-AssetPath "$Value") }
    $Fallback
}

# Inside a chapter's folder, a path is looked up there first and then in the main world,
# so an expansion can reuse the main world's pictures without copying them.
function Resolve-AssetPath($Path) {
    if (-not $Path -or $Path -isnot [string]) { return $Path }
    $pre = $script:Loader.Prefix
    if (-not $pre -or -not $script:Loader.Index) { return $Path }
    if (Get-ZipEntry $script:Loader.Index ($pre + $Path)) { return $pre + $Path }
    if (Get-ZipEntry $script:Loader.Index $Path) { return $Path }
    $pre + $Path
}

function ConvertTo-WorldId([string]$Text) {
    $id = ($Text.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    if (-not $id) { $id = 'world' }
    $id
}

# One character from a JSON value, or $null
function Read-Symbol($Value) {
    if ($null -ne $Value -and "$Value".Length -eq 1) { return [char]"$Value" }
    $null
}

function New-AreaInfo([string]$Id, $File, $Background, $BackgroundColor, $Liquids, $Survival) {
    @{ Id = $Id; File = $File; Background = $Background; BackgroundColor = $BackgroundColor; Liquids = $Liquids; Survival = $Survival; Weather = 'day'; LevelType = 'surface'
       Rows = $null; W = 0; H = 0; Error = $null }
}

# Animations: { "run": ["a.png","b.png"], "jump": "c.png", "invincible": { "frames": [...], "fps": 12, "spin": 720 } }
function Read-Animations($Source, [string]$Label, $Warnings) {
    $out = @{}
    foreach ($prop in @(Get-JsonProperties $Source)) {
        $v = $prop.Value
        $fps = 8.0; $spin = 0.0
        if ($v -is [string]) { $frames = @($v) }
        elseif ($v -is [array]) { $frames = @($v | Where-Object { $_ } | ForEach-Object { "$_" }) }
        else {
            $frames = @(@($v.frames) + @($v.image) | Where-Object { $_ } | ForEach-Object { "$_" })
            $fps  = Read-Number $v.fps 8 0.1 60 "$Label '$($prop.Name)' fps" $Warnings
            $spin = Read-Number $v.spin 0 -7200 7200 "$Label '$($prop.Name)' spin" $Warnings
        }
        $out[$prop.Name.ToLower()] = @{ Frames = @($frames | ForEach-Object { Resolve-AssetPath $_ }); Fps = $fps; Spin = $spin; Bitmaps = $null }
    }
    $out
}

# Rising and falling water or lava: [{ "type": "lava", "level": 14, "low": 15, "high": 11, "mode": "wave", "period": 8 }]
function Read-Liquids($Source, [string]$Label, $Warnings) {
    $list = New-Object System.Collections.ArrayList
    foreach ($v in @($Source)) {
        if ($null -eq $v -or $v -is [string] -or $v -is [ValueType]) { continue }
        $kind = "$(Get-OrDefault $v.type 'water')".ToLower()
        if ($kind -notin 'water', 'lava', 'quicksand') { $Warnings.Add("$Label liquid type '$kind' is unknown; using water."); $kind = 'water' }
        if ($null -eq $v.level) { $Warnings.Add("$Label liquid needs a 'level' (the row of its surface); skipped."); continue }
        $level = Read-Number $v.level 10 -10 2000 "$Label liquid level" $Warnings
        $low   = Read-Number $v.low $level -10 2000 "$Label liquid low" $Warnings
        $high  = Read-Number $v.high $level -10 2000 "$Label liquid high" $Warnings
        if ($high -gt $low) { $t = $high; $high = $low; $low = $t }     # high is the smaller row number
        $mode = "$(Get-OrDefault $v.mode $(if ($low -ne $high) { 'wave' } else { 'still' }))".ToLower()
        if ($mode -notin 'still', 'wave', 'pingpong', 'rise') { $Warnings.Add("$Label liquid mode '$mode' is unknown; using wave."); $mode = 'wave' }
        $startOn = "$(Get-OrDefault $v.startOn 'level')".ToLower()
        if ($startOn -notin 'level', 'survival') { $Warnings.Add("$Label liquid startOn must be level or survival."); $startOn = 'level' }
        $after = "$(Get-OrDefault $v.afterSurvival 'drain')".ToLower()
        if ($after -notin 'drain', 'stay', 'keep') { $Warnings.Add("$Label liquid afterSurvival must be drain, stay or keep."); $after = 'drain' }
        [void]$list.Add(@{
            Kind = $kind; Mode = $mode; Level = $level; Low = $low; High = $high
            Period = Read-Number $v.period 8 0.5 600 "$Label liquid period" $Warnings
            Speed  = Read-Number $v.speed 0.5 0.01 50 "$Label liquid speed" $Warnings
            Pause  = Read-Number $v.pause 1 0 600 "$Label liquid pause" $Warnings
            Delay  = Read-Number $v.delay 0 0 600 "$Label liquid delay" $Warnings
            From   = $(if ($null -ne $v.from) { [int](Read-Number $v.from 0 0 100000 "$Label liquid from" $Warnings) } else { $null })
            To     = $(if ($null -ne $v.to) { [int](Read-Number $v.to 0 0 100000 "$Label liquid to" $Warnings) } else { $null })
            StartOn = $startOn; AfterSurvival = $after
            Image = Resolve-AssetPath $v.image; SurfaceImage = Resolve-AssetPath $v.surfaceImage; Color = $v.color; SurfaceColor = $v.surfaceColor
        })
    }
    , $list
}

# "survival": { "time": 60, "spawn": ["s","b"], "spawnEvery": 3, "waves": [...], "completeLevel": true, ... }
function Read-Survival($S, [string]$Label, $Warnings) {
    if ($null -eq $S -or $S -is [bool] -or $S -is [string] -or $S -is [ValueType]) { return $null }
    $sv = @{
        Time          = Read-Number $S.time 60 1 3600 "$Label survival time" $Warnings
        StartColumn   = [int](Read-Number $S.startColumn -1 -1 100000 "$Label survival startColumn" $Warnings)
        CompleteLevel = Read-Bool $S.completeLevel $false
        Exit          = "$(Get-OrDefault $S.exit 'G')"
        Spawn         = @(@($S.spawn) | Where-Object { $_ } | ForEach-Object { "$_" })
        SpawnEvery    = Read-Number $S.spawnEvery 3 0.2 600 "$Label survival spawnEvery" $Warnings
        MaxEnemies    = [int](Read-Number $S.maxEnemies 6 1 100 "$Label survival maxEnemies" $Warnings)
        Reward        = if ($S.reward) { "$($S.reward)" } else { $null }
        Message       = "$(Get-OrDefault $S.message 'SURVIVE!')"
        Waves         = New-Object System.Collections.ArrayList
    }
    foreach ($w in @($S.waves)) {
        if ($null -eq $w -or -not $w.spawn) { continue }
        [void]$sv.Waves.Add(@{
            At    = Read-Number $w.at 0 0 3600 "$Label survival wave at" $Warnings
            Spawn = "$($w.spawn)"
            Count = [int](Read-Number $w.count 1 1 100 "$Label survival wave count" $Warnings)
            Every = Read-Number $w.every 0.6 0 60 "$Label survival wave every" $Warnings
        })
    }
    $sv
}

# "requires": { "defeated": 10, "enemies": ["B"], "coins": 20, "items": { "g": 3 } }
# What must be done in the level before an exit opens
function Read-Requirement($Source, [string]$Label, $Warnings) {
    if ($null -eq $Source -or $Source -is [string] -or $Source -is [ValueType]) { return $null }
    $req = @{
        Defeated = [int](Read-Number $Source.defeated 0 0 100000 "$Label requires defeated" $Warnings)
        Coins    = [int](Read-Number $Source.coins 0 0 1000000 "$Label requires coins" $Warnings)
        Enemies  = @{}
        Items    = @{}
    }
    foreach ($e in @($Source.enemies)) { if ($e) { $k = "$e"; $req.Enemies[$k] = [int]$req.Enemies[$k] + 1 } }
    if ($Source.items -is [array] -or $Source.items -is [string]) { foreach ($e in @($Source.items)) { if ($e) { $k = "$e"; $req.Items[$k] = [int]$req.Items[$k] + 1 } } }
    else { foreach ($prop in @(Get-JsonProperties $Source.items)) { $req.Items[$prop.Name] = [int](Read-Number $prop.Value 1 1 100000 "$Label requires items" $Warnings) } }
    if ($req.Defeated -eq 0 -and $req.Coins -eq 0 -and $req.Enemies.Count -eq 0 -and $req.Items.Count -eq 0) { return $null }
    $req
}

function Merge-Requirement($A, $B) {
    if (-not $A) { return $B }
    if (-not $B) { return $A }
    $m = @{ Defeated = [math]::Max($A.Defeated, $B.Defeated); Coins = [math]::Max($A.Coins, $B.Coins); Enemies = Copy-Hashtable $A.Enemies; Items = Copy-Hashtable $A.Items }
    foreach ($k in @($B.Enemies.Keys)) { $m.Enemies[$k] = [math]::Max([int]$m.Enemies[$k], [int]$B.Enemies[$k]) }
    foreach ($k in @($B.Items.Keys)) { $m.Items[$k] = [math]::Max([int]$m.Items[$k], [int]$B.Items[$k]) }
    $m
}

# What an enemy turns into or drops: { "becomes": "K", "drop": "o" }
function Read-FormChange($Source) {
    if ($null -eq $Source) { return $null }
    if ($Source -is [string]) { return @{ Becomes = (Read-Symbol $Source); Drop = $null } }
    $fc = @{ Becomes = (Read-Symbol $Source.becomes); Drop = (Read-Symbol $Source.drop) }
    if (-not $fc.Becomes -and -not $fc.Drop) { return $null }
    $fc
}

# Every attack an enemy can mix in
function Read-EnemyAttacks($Source, [string]$Label, $Warnings) {
    $list = New-Object System.Collections.ArrayList
    foreach ($a in @($Source)) {
        if ($null -eq $a) { continue }
        if ($a -is [string]) { $a = [pscustomobject]@{ type = $a } }
        $type = "$($a.type)".ToLower()
        $l = "$Label attack '$type'"
        switch ($type) {
            'shoot' {
                $aim = "$(Get-OrDefault $a.aim 'player')".ToLower()
                if ($aim -notin 'player', 'forward', 'up', 'down', 'left', 'right') { $Warnings.Add("$l aim must be player, forward, up, down, left or right."); $aim = 'player' }
                [void]$list.Add(@{
                    Type = 'shoot'; Aim = $aim
                    Interval = Read-Number $a.interval 2 0.1 600 "$l interval" $Warnings
                    Speed    = Read-Number $a.speed 220 10 3000 "$l speed" $Warnings
                    Gravity  = Read-Bool $a.gravity $false
                    Range    = Read-Number $a.range 420 0 100000 "$l range" $Warnings
                    Element  = "$(Get-OrDefault $a.element '')"
                    Count    = [int](Read-Number $a.count 1 1 12 "$l count" $Warnings)
                    Spread   = Read-Number $a.spread 15 0 180 "$l spread" $Warnings
                    Size     = Read-Number $a.size 12 4 128 "$l size" $Warnings
                    Life     = Read-Number $a.life 3 0.2 60 "$l life" $Warnings
                    Image    = Resolve-AssetPath $a.image
                    Images   = @(@($a.images) | Where-Object { $_ } | ForEach-Object { Resolve-AssetPath "$_" })
                    Spin     = Read-Number $a.spin 0 -7200 7200 "$l spin" $Warnings
                    Color    = Get-OrDefault $a.color '#FF7043'
                    Leaves   = "$($a.leaves)" -eq 'throwable'
                })
            }
            'think' {
                [void]$list.Add(@{
                    Type = 'think'; Aim = "$(Get-OrDefault $a.aim 'player')".ToLower()
                    Interval = Read-Number $a.interval 4 0.1 600 "$l interval" $Warnings
                    Think    = Read-Number $a.think 2.5 0.2 60 "$l think" $Warnings
                    Speed    = Read-Number $a.speed 300 10 3000 "$l speed" $Warnings
                    Gravity  = Read-Bool $a.gravity $false
                    Range    = Read-Number $a.range 600 0 100000 "$l range" $Warnings
                    Element  = "$(Get-OrDefault $a.element '')"
                    Count    = 1; Spread = 0
                    Size     = Read-Number $a.size 24 4 128 "$l size" $Warnings
                    Life     = Read-Number $a.life 4 0.2 60 "$l life" $Warnings
                    Image    = Resolve-AssetPath $a.image
                    Images   = @(@($a.images) | Where-Object { $_ } | ForEach-Object { Resolve-AssetPath "$_" })
                    Spin     = Read-Number $a.spin 0 -7200 7200 "$l spin" $Warnings
                    Color    = Get-OrDefault $a.color '#FF7043'
                    Leaves   = "$($a.leaves)" -eq 'throwable'
                })
            }
            'charge' {
                [void]$list.Add(@{
                    Type = 'charge'
                    Speed    = Read-Number $a.speed 380 10 3000 "$l speed" $Warnings
                    Duration = Read-Number $a.duration 0.9 0.1 60 "$l duration" $Warnings
                    Cooldown = Read-Number $a.cooldown 2 0 600 "$l cooldown" $Warnings
                    Range    = Read-Number $a.range 300 0 100000 "$l range" $Warnings
                    Windup   = Read-Number $a.windup 0.45 0 10 "$l windup" $Warnings
                })
            }
            'drop' {
                [void]$list.Add(@{
                    Type = 'drop'
                    Range = Read-Number $a.range 40 0 100000 "$l range" $Warnings
                    Speed = Read-Number $a.speed 900 10 5000 "$l speed" $Warnings
                    Rise  = Read-Number $a.rise 120 1 5000 "$l rise" $Warnings
                    Wait  = Read-Number $a.wait 0.8 0 60 "$l wait" $Warnings
                })
            }
            'leap' {
                [void]$list.Add(@{
                    Type = 'leap'
                    Speed    = Read-Number $a.speed 650 10 5000 "$l speed" $Warnings
                    Forward  = Read-Number $a.forward 220 0 3000 "$l forward" $Warnings
                    Range    = Read-Number $a.range 240 0 100000 "$l range" $Warnings
                    Cooldown = Read-Number $a.cooldown 1.5 0 600 "$l cooldown" $Warnings
                })
            }
            default { $Warnings.Add("$Label has unknown attack '$type'. Use shoot, think, charge, drop or leap.") }
        }
    }
    , $list
}

# A power-up is a bundle of abilities. The built-in types are just ready-made bundles.
$KnownImmunities = 'lava', 'spikes', 'hazards'
function Read-PowerAbilities($V, [string]$Type, [string]$Label, $Warnings) {
    $ab = @{
        Projectile = $null; AirJumps = 0; Fly = $null; Glide = 0.0; Speed = 1.0
        Physics = Read-PhysicsOverrides $V.physics "$Label physics" $Warnings
        Immune = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        HeavyStomp = Read-Bool $V.heavyStomp $false
        BreakBlocks = Read-Bool $V.breakBlocks $false
        Hits = [int](Read-Number $V.hits 1 1 99 "$Label hits" $Warnings)
        DowngradeTo = Read-Symbol $V.downgradeTo
    }
    foreach ($i in @($V.immune)) { if ($i) { [void]$ab.Immune.Add("$i") } }
    $ab.AirJumps = [int](Read-Number $V.airJumps $(if ($Type -eq 'doubleJump') { 1 } else { 0 }) 0 10 "$Label airJumps" $Warnings)
    $ab.Glide = Read-Number $V.glide 0 0 3000 "$Label glide" $Warnings
    $ab.Speed = Read-Number $V.speed 1 0.1 5 "$Label speed" $Warnings
    if ($Type -eq 'fly' -or $V.fly) {
        $f = if ($V.fly -and $V.fly -isnot [bool]) { $V.fly } else { $V }
        $ab.Fly = @{ Thrust = Read-Number $f.thrust 3600 100 20000 "$Label thrust" $Warnings; MaxRise = Read-Number $f.maxRise 300 10 3000 "$Label maxRise" $Warnings }
    }
    # Projectiles: "projectile": {...}, or the old fireball/iceball fields at the top level
    $p = if ($V.projectile) { $V.projectile } elseif ($Type -in 'fireball', 'iceball') { $V } else { $null }
    if ($p) {
        $isIce = $Type -eq 'iceball'
        $effect = "$(Get-OrDefault $p.effect $(if ($isIce) { 'freeze' } else { 'defeat' }))".ToLower()
        if ($effect -notin 'defeat', 'freeze', 'stun', 'none') { $Warnings.Add("$Label projectile effect must be defeat, freeze, stun or none."); $effect = 'defeat' }
        $element = "$(Get-OrDefault $p.element $(if ($isIce) { 'ice' } elseif ($Type -eq 'fireball') { 'fire' } else { 'shot' }))"
        $ab.Projectile = @{
            Image      = Resolve-AssetPath $(Get-OrDefault $p.image $p.projectileImage)
            Color      = Get-OrDefault $p.color $(if ($effect -eq 'freeze') { '#9FE6FF' } elseif ($effect -eq 'stun') { '#FFF176' } else { '#FF7043' })
            Speed      = Read-Number $(Get-OrDefault $p.speed $p.projectileSpeed) 420 50 3000 "$Label projectile speed" $Warnings
            Max        = [int](Read-Number $(Get-OrDefault $p.max $p.maxProjectiles) 2 1 10 "$Label projectile max" $Warnings)
            Cooldown   = Read-Number $p.cooldown 0.25 0 5 "$Label projectile cooldown" $Warnings
            Life       = Read-Number $p.life 2 0.1 30 "$Label projectile life" $Warnings
            Size       = Read-Number $p.size 12 4 96 "$Label projectile size" $Warnings
            Gravity    = Read-Bool $p.gravity $true
            Bounce     = Read-Bool $p.bounce $true
            Pierce     = Read-Bool $p.pierce $false
            Effect     = $effect
            Element    = $element
            FreezeTime = Read-Number $p.freezeTime 8 0.5 600 "$Label freezeTime" $Warnings
            StunTime   = Read-Number $p.stunTime 3 0.1 600 "$Label stunTime" $Warnings
            IceImage   = Resolve-AssetPath $p.iceImage
            OutInWater = Read-Bool $p.goesOutInWater ($element -eq 'fire')
            MeltsInLava = Read-Bool $p.meltsInLava ($element -eq 'ice')
        }
    }
    $ab
}

# Step 1: read and check world.json (and every chapter's world.json), then queue the remaining steps
function Read-WorldDefinition {
    $L = $script:Loader
    $stale = "$($L.Path).saving"
    if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue }

    $L.Zip    = [System.IO.Compression.ZipFile]::OpenRead($L.Path)
    $L.Index  = Get-ZipIndex $L.Zip
    $L.Prefix = ''
    try { $def = Read-ZipText $L.Index.Map[$L.Index.WorldJsonKey] | ConvertFrom-Json }
    catch { throw "world.json is not valid JSON: $($_.Exception.Message)" }
    if ($null -eq $def -or -not $def.PSObject.Properties['levels']) { throw 'world.json needs a "levels" list.' }
    if ($def.expansionOf) { throw "This is an expansion for the world '$($def.expansionOf)'. Load that world and use its Expansions button to add it." }

    $warn = New-Object 'System.Collections.Generic.List[string]'
    $name = Get-OrDefault $def.name ([IO.Path]::GetFileNameWithoutExtension($L.Path))
    $world = @{
        Path           = $L.Path
        Root           = $L.Index.Root
        Id             = ConvertTo-WorldId "$(Get-OrDefault $def.id $name)"
        Name           = $name
        Author         = Get-OrDefault $def.author 'Unknown'
        Description    = "$($def.description)"
        TileSize       = [int](Read-Number $def.tileSize 32 8 128 'tileSize' $warn)
        Images         = @{}
        Levels         = New-Object System.Collections.ArrayList
        LevelByNumber  = @{}
        Chapters       = New-Object System.Collections.ArrayList
        PersistentKeys = [System.Collections.Generic.HashSet[string]]::new()
        MiniGames      = New-Object System.Collections.ArrayList
        MinutesPer2Coins = $null
        Lives          = [int](Read-Number $def.lives 3 0 99 'lives' $warn)              # 0 = no limit
        LifePrice      = [int](Read-Number $def.lifePrice 150 0 1000000 'lifePrice' $warn) # 0 = not sold
        TetroEnemy     = Read-Number $(if ($def.tetrominoChance -and $def.tetrominoChance -isnot [ValueType]) { $def.tetrominoChance.enemy } else { $def.tetrominoChance }) 0.002 0 1 'tetrominoChance.enemy' $warn  # 1 in 500
        TetroBoss      = Read-Number $(if ($def.tetrominoChance -and $def.tetrominoChance -isnot [ValueType]) { $def.tetrominoChance.boss } else { $null }) 0.02 0 1 'tetrominoChance.boss' $warn     # 1 in 50
        Warnings       = $warn
        Stats          = $null
        Slots          = @{}
        SlotNumber     = 1
    }
    $L.World = $world

    $base = Read-ChapterDefinition $def $null 0 $world.Id
    foreach ($id in (Get-ChapterList $L.Index $def)) {
        if ($world.Chapters.Count -ge $MaxChapters) { $warn.Add("Only $MaxChapters chapters can be used; chapter '$id' and any after it are skipped."); break }
        $prefix = "chapters/$id/"
        $entry = Get-ZipEntry $L.Index ($prefix + 'world.json')
        if (-not $entry) { $warn.Add("Chapter '$id' is listed but $($prefix)world.json is missing."); continue }
        try { $cdef = Read-ZipText $entry | ConvertFrom-Json }
        catch { $warn.Add("Chapter '$id': world.json is not valid JSON, so the chapter is skipped."); continue }
        $parent = $base
        if ($cdef.expansionOf) {
            $want = ConvertTo-WorldId "$($cdef.expansionOf)"
            $match = @($world.Chapters | Where-Object { $_.Id -eq $want })
            if ($match.Count) { $parent = $match[0] }
            else { $warn.Add("Chapter '$id' says it expands '$($cdef.expansionOf)', which isn't this world or one of its chapters. It's added anyway.") }
        }
        $L.Prefix = $prefix
        try { [void](Read-ChapterDefinition $cdef $parent $world.Chapters.Count $id) }
        catch { $warn.Add("Chapter '$id' skipped: $($_.Exception.Message)") }
        $L.Prefix = ''
    }

    # Level labels ("3", or "2-3" once there are chapters) and exit targets across chapters
    $multi = $world.Chapters.Count -gt 1
    foreach ($lv in $world.Levels) { $lv.Label = if ($multi) { "$($lv.Chapter.Index + 1)-$($lv.LocalNumber)" } else { "$($lv.LocalNumber)" } }
    foreach ($lv in $world.Levels) {
        foreach ($ex in @($lv.ExitRaw.Keys)) {
            $nums = New-Object System.Collections.ArrayList
            foreach ($u in $lv.ExitRaw[$ex]) {
                $target = Resolve-LevelReference $world $lv.Chapter "$u"
                if ($target) { if (-not $nums.Contains($target.Number)) { [void]$nums.Add($target.Number) } }
                elseif ("$u") { $warn.Add("Level $($lv.Label) exit '$ex': '$u' is not a level. Use a level number, or chapter:level like 'heights:2'.") }
            }
            $lv.Exits[$ex] = $nums
        }
    }
    Use-Chapter $world $base

    # ---- Queue up every image, then each level, then saves ----
    $paths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($ch in $world.Chapters) {
        foreach ($p in @($ch.Background, $ch.Player.Image, $ch.Goal.Image, $ch.Checkpoint.Image, $ch.Checkpoint.ActiveImage)) { if ($p) { [void]$paths.Add("$p") } }
        foreach ($a in $ch.Player.Anims.Values) { foreach ($f in $a.Frames) { if ($f) { [void]$paths.Add("$f") } } }
        foreach ($sym in $ch.Symbols.Values) { foreach ($p in (Get-DefImages $sym.Def)) { [void]$paths.Add($p) } }
        foreach ($t in $ch.WarpTypes.Values) { if ($t.Image) { [void]$paths.Add("$($t.Image)") } }
    }
    $miniLevels = @(foreach ($mg in $world.MiniGames) { if ($mg.Level) { $mg.Level }; if ($mg.NoFloorLevel) { $mg.NoFloorLevel } })
    foreach ($lvl in @($world.Levels) + $miniLevels) {
        foreach ($area in $lvl.Areas.Values) {
            if ($area.Background) { [void]$paths.Add("$($area.Background)") }
            foreach ($lq in $area.Liquids) { foreach ($p in @($lq.Image, $lq.SurfaceImage)) { if ($p) { [void]$paths.Add("$p") } } }
        }
    }
    foreach ($p in $paths) { Add-LoadStep "Loading $p" { param($arg1) Import-WorldImage $arg1 } $p }
    foreach ($lvl in $world.Levels) { Add-LoadStep "Reading level $($lvl.Label): $($lvl.Name)" { param($arg1) Import-WorldLevel $arg1 } $lvl }
    foreach ($lvl in $miniLevels) { Add-LoadStep "Reading mini-game: $($lvl.Name)" { param($arg1) Import-WorldLevel $arg1 } $lvl }
    Add-LoadStep 'Reading saves' { Import-WorldSaves } $null
}

# Every picture a definition uses: any "...Image" value, plus animation frames, at any depth
function Get-DefImages($Def) {
    $out = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Stack
    $stack.Push($Def)
    while ($stack.Count) {
        $o = $stack.Pop()
        if ($o -is [hashtable]) {
            foreach ($k in @($o.Keys)) {
                $v = $o[$k]
                if ($v -is [string]) { if ($v -and ($k -like '*Image' -or $k -eq 'Image')) { $out.Add($v) } }
                elseif ($k -eq 'Frames' -or $k -like '*Images') { foreach ($f in @($v)) { if ($f -is [string] -and $f) { $out.Add("$f") } } }
                elseif ($v -is [hashtable] -or $v -is [System.Collections.IList]) { $stack.Push($v) }
            }
        }
        elseif ($o -is [System.Collections.IList]) { foreach ($x in $o) { if ($x -is [hashtable] -or $x -is [System.Collections.IList]) { $stack.Push($x) } } }
    }
    , $out
}

# Chapters inside this zip, in order: those listed in world.json's "chapters", then imported ones (chapters.json)
function Get-ChapterList($Index, $Def) {
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($c in @($Def.chapters)) { if ($c) { $id = "$c".Trim('/'); if (-not $ids.Contains($id)) { $ids.Add($id) } } }
    $e = Get-ZipEntry $Index 'chapters.json'
    if ($e) {
        try { foreach ($c in @((Read-ZipText $e | ConvertFrom-Json).chapters)) { if ($c -and -not $ids.Contains("$c")) { $ids.Add("$c") } } } catch { }
    }
    , $ids
}

# "4" = level 4 of the same chapter; "heights:2" or "2:2" = level 2 of that chapter (by id or number)
function Resolve-LevelReference($World, $Chapter, [string]$Ref) {
    $Ref = $Ref.Trim()
    $ch = $Chapter; $num = 0
    if ($Ref -match '^(.+):(\d+)$') {
        $key = $Matches[1].Trim(); $num = [int]$Matches[2]
        $ch = @($World.Chapters | Where-Object { $_.Id -eq (ConvertTo-WorldId $key) -or "$($_.Index + 1)" -eq $key })[0]
        if (-not $ch) { return $null }
    }
    elseif (-not [int]::TryParse($Ref, [ref]$num)) { return $null }
    @($ch.Levels | Where-Object { $_.LocalNumber -eq $num })[0]
}

# Makes a chapter's definitions the ones in use (symbols, player, goal...) - done whenever a level starts
function Use-Chapter($World, $Chapter) {
    if (-not $World -or -not $Chapter) { return }
    $World.Chapter         = $Chapter
    $World.Symbols         = $Chapter.Symbols
    $World.Player          = $Chapter.Player
    $World.Goal            = $Chapter.Goal
    $World.Checkpoint      = $Chapter.Checkpoint
    $World.WarpTypes       = $Chapter.WarpTypes
    $World.Physics         = $Chapter.Physics
    $World.Background      = $Chapter.Background
    $World.BackgroundColor = $Chapter.BackgroundColor
}

function Get-Level([int]$Number) { $script:World.LevelByNumber[$Number] }

# Reads one world.json (the main one, or a chapter's) into a chapter. $Parent's definitions are inherited.
function Read-ChapterDefinition($def, $Parent, [int]$Index, [string]$Id) {
    $world = $script:Loader.World
    $warn = $world.Warnings
    $tag = if ($Index -gt 0) { "Chapter '$Id': " } else { '' }
    if ($Index -gt 0 -and $null -ne $def.tileSize -and [int]$def.tileSize -ne $world.TileSize) {
        $warn.Add("$($tag)tileSize must match the main world ($($world.TileSize)); the main world's size is used.")
    }
    $ch = @{
        Id            = $Id
        Index         = $Index
        Name          = Get-OrDefault $def.name $Id
        Author        = Get-OrDefault $def.author $(if ($Parent) { $Parent.Author } else { 'Unknown' })
        Description   = "$($def.description)"
        IsExpansion   = $Index -gt 0
        Levels        = New-Object System.Collections.ArrayList
        BackgroundColor = Get-OrDefault $def.backgroundColor $(if ($Parent) { $Parent.BackgroundColor } else { '#5C94FC' })
        Background    = if ($null -ne $def.background) { Get-Background $def.background $null } elseif ($Parent) { $Parent.Background } else { $null }
        Physics       = Merge-Physics $(if ($Parent) { $Parent.Physics } else { New-DefaultPhysics }) (Read-PhysicsOverrides $def.physics "$($tag)world physics" $warn)
        TimeLimit     = Read-Number $def.timeLimit $(if ($Parent) { $Parent.TimeLimit } else { 300 }) 0 100000 "$($tag)timeLimit" $warn
        Weather       = Read-Weather $def.weather $(if ($Parent) { $Parent.Weather } else { 'day' }) "$($tag)world" $warn
        LevelType     = Read-LevelType $def.levelType $(if ($Parent) { $Parent.LevelType } else { 'surface' }) "$($tag)world" $warn
        Symbols       = if ($Parent) { New-Object 'System.Collections.Generic.Dictionary[char,object]' ($Parent.Symbols) } else { New-Object 'System.Collections.Generic.Dictionary[char,object]' }
    }
    if ($def.player -or -not $Parent) {
        $playerH = Read-Number $def.player.height 30 8 256 "$($tag)player.height" $warn
        $ch.Player = @{
            Image        = Resolve-AssetPath $def.player.image
            Width        = Read-Number $def.player.width 22 8 256 "$($tag)player.width" $warn
            Height       = $playerH
            CrouchHeight = Read-Number $def.player.crouchHeight ([math]::Round($playerH * 0.6)) 8 $playerH "$($tag)player.crouchHeight" $warn
            Anims        = Read-Animations $def.player.animations "$($tag)player animation" $warn
            SleepAfter   = Read-Number $def.player.sleepAfter 120 0 100000 "$($tag)player.sleepAfter" $warn
            SleepTalk    = @(@($def.player.sleepTalk) | Where-Object { $_ } | ForEach-Object { "$_" })
        }
        if (-not $ch.Player.SleepTalk.Count) { $ch.Player.SleepTalk = $DefaultSleepTalk }
    }
    else { $ch.Player = $Parent.Player }
    $ch.Goal = if ($def.goal -or -not $Parent) { @{ Image = Resolve-AssetPath $def.goal.image } } else { $Parent.Goal }
    $ch.Checkpoint = if ($def.checkpoint -or -not $Parent) { @{ Image = Resolve-AssetPath $def.checkpoint.image; ActiveImage = Resolve-AssetPath $def.checkpoint.activeImage } } else { $Parent.Checkpoint }
    $ch.WarpTypes = @{}
    if ($Parent) { foreach ($k in @($Parent.WarpTypes.Keys)) { $ch.WarpTypes[$k] = Copy-Hashtable $Parent.WarpTypes[$k] } }
    else {
        $ch.WarpTypes.door   = @{ Name = 'door';   Enter = 'up';   Image = $null; Color = '#8D6E63' }
        $ch.WarpTypes.pipe   = @{ Name = 'pipe';   Enter = 'down'; Image = $null; Color = $null }
        $ch.WarpTypes.tunnel = @{ Name = 'tunnel'; Enter = 'auto'; Image = $null; Color = '#1A1A24' }
    }
    $ctx = @{ Symbols = $ch.Symbols; Warnings = $warn; Own = [System.Collections.Generic.HashSet[char]]::new(); Tag = $tag }

    # ---- Tiles ----
    foreach ($prop in @(Get-JsonProperties $def.tiles)) {
        $v = $prop.Value; $label = "$($tag)Tile '$($prop.Name)'"
        $lava = Read-Bool $v.lava $false
        $sand = (Read-Bool $v.quicksand $false) -and -not $lava
        $liquid = (Read-Bool $v.liquid $false) -and -not $lava -and -not $sand
        $fluid = $liquid -or $lava -or $sand
        $tile = @{
            Image       = Resolve-AssetPath $v.image
            Color       = $v.color
            Liquid      = $liquid
            Lava        = $lava
            Quicksand   = $sand
            Solid       = Read-Bool $v.solid (-not $fluid)
            Deadly      = Read-Bool $v.deadly $false
            InstantKill = Read-Bool $v.instantKill $false
            Front       = Read-Bool $v.front $fluid
            Lock        = if ($v.lock) { "$($v.lock)" } else { $null }
            Spikes      = 0
            Rotate      = 0
            OneWay      = Read-Bool $v.oneWay $false
            Bounce      = Read-Number $v.bounce 0 0 5000 "$label bounce" $warn
            Friction    = Read-Number $v.friction 1 0.02 5 "$label friction" $warn
            Conveyor    = Read-Number $v.conveyor 0 -3000 3000 "$label conveyor" $warn
            SpeedMult   = Read-Number $v.speed 1 0.05 5 "$label speed" $warn
            Climb       = Read-Bool $v.climbable $false
            SolidFor    = "$(Get-OrDefault $v.solidFor 'all')".ToLower()
            DeadlyToEnemies = Read-Bool $v.deadlyToEnemies $false
            AffectsPlayer = $true; AffectsEnemies = $true
            Breakable = $null; Bump = $null; Crumble = $null; Switch = $null; Toggle = $null; Gate = $null
        }
        if ($tile.SolidFor -notin 'all', 'player', 'enemies') { $warn.Add("$label solidFor must be all, player or enemies."); $tile.SolidFor = 'all' }
        if ($null -ne $v.affects) {
            $aff = @(@($v.affects) | ForEach-Object { "$_".ToLower() })
            $tile.AffectsPlayer = $aff -contains 'player'; $tile.AffectsEnemies = $aff -contains 'enemies'
        }
        # "spikes": "up" / ["up","left"] / "all" - a solid block that only hurts from its pointed sides
        if ($null -ne $v.spikes -and "$($v.spikes)" -ne '') {
            foreach ($d in @($v.spikes)) {
                $d = "$d".ToLower()
                if ($d -eq 'all') { $tile.Spikes = 15 }
                elseif ($SpikeBits.ContainsKey($d)) { $tile.Spikes = $tile.Spikes -bor $SpikeBits[$d] }
                else { $warn.Add("$label has unknown spike direction '$d'. Use up, down, left, right or all.") }
            }
            if ($tile.Spikes) {
                if ($fluid) { $warn.Add("$label can't be spikes and liquid, lava or quicksand; spikes ignored."); $tile.Spikes = 0 }
                else {
                    if ($v.solid -eq $false) { $warn.Add("$($label): spike tiles are always solid (their sides act like walls).") }
                    $tile.Solid = $true
                    $tile.Deadly = $false     # spikes use their own direction check, not the overlap check
                }
            }
        }
        if ($null -ne $v.rotate) {
            $rot = [int](Read-Number $v.rotate 0 0 270 "$label rotate" $warn)
            if ($rot -in 0, 90, 180, 270) { $tile.Rotate = $rot } else { $warn.Add("$label rotate must be 0, 90, 180 or 270.") }
        }
        $tile.SpikeKill = $tile.Spikes -and (Read-Bool $v.instantKill $false)

        # Blocks that change while you play
        if ($v.breakable) {
            $by = if ($v.breakable -is [bool]) { @('powerHead', 'shell', 'heavyStomp') } else { @(@($v.breakable.by) | Where-Object { $_ } | ForEach-Object { "$_" }) }
            if (-not $by.Count) { $by = @('powerHead', 'shell', 'heavyStomp') }
            $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($b in $by) { [void]$set.Add($b) }
            $tile.Breakable = @{ By = $set; Drop = $(if ($v.breakable -isnot [bool]) { Read-Symbol $v.breakable.drop }) }
        }
        if ($v.bump) {
            $b = $v.bump
            $tile.Bump = if ($b -is [string]) { @{ Gives = (Read-Symbol $b); Count = 1; Becomes = $null } }
                         else { @{ Gives = (Read-Symbol $b.gives); Count = [int](Read-Number $b.count 1 1 99 "$label bump count" $warn); Becomes = (Read-Symbol $b.becomes) } }
        }
        if ($v.crumble) {
            $c = $v.crumble
            $tile.Crumble = if ($c -is [bool] -or $c -is [ValueType]) { @{ Delay = $(if ($c -is [bool]) { 0.5 } else { Read-Number $c 0.5 0 60 "$label crumble" $warn }); Respawn = 4.0 } }
                            else { @{ Delay = Read-Number $c.delay 0.5 0 60 "$label crumble delay" $warn; Respawn = Read-Number $c.respawn 4 0 600 "$label crumble respawn" $warn } }
        }
        if ($v.switch) { $tile.Switch = "$($v.switch)" }
        if ($v.toggle) {
            $tile.Toggle = if ($v.toggle -is [string]) { @{ Group = "$($v.toggle)"; StartSolid = $true } }
                           else { @{ Group = "$($v.toggle.group)"; StartSolid = Read-Bool $v.toggle.solid $true } }
        }
        if ($v.gate) {
            $g = if ($v.gate -is [bool]) { 'during' } else { "$($v.gate)".ToLower() }
            if ($g -notin 'during', 'until') { $warn.Add("$label gate must be during or until."); $g = 'during' }
            $tile.Gate = $g
        }
        $tile.IsBlock = [bool]($tile.Lock -or $tile.Breakable -or $tile.Bump -or $tile.Crumble -or $tile.Switch -or $tile.Toggle -or $tile.Gate)
        if ($fluid -and ($tile.Solid -or $tile.IsBlock -or $tile.OneWay)) {
            $warn.Add("$label can't be both solid (or a block) and liquid, lava or quicksand; it is treated as liquid only.")
            $tile.Solid = $false; $tile.IsBlock = $false; $tile.OneWay = $false
            $tile.Breakable = $null; $tile.Bump = $null; $tile.Crumble = $null; $tile.Switch = $null; $tile.Toggle = $null; $tile.Gate = $null; $tile.Lock = $null
        }
        if ($tile.Climb) { $tile.Solid = $false }
        if ($tile.OneWay) { $tile.Solid = $false }
        if ($tile.Bump -or $tile.Switch -or $tile.Breakable -or $tile.Lock) { $tile.Solid = $true; $tile.OneWay = $false }
        if ($tile.Lock) { $tile.Liquid = $false; $tile.Lava = $false; $tile.Quicksand = $false; $tile.Front = $false }
        [void](Add-WorldSymbol $ctx $prop.Name 'tile' $tile 'Tile')
    }

    # ---- Enemies: mix and match movement, attacks, toughness and forms ----
    foreach ($prop in @(Get-JsonProperties $def.enemies)) {
        $v = $prop.Value; $label = "$($tag)Enemy '$($prop.Name)'"
        $moves = @{ Patrol = $false; Follow = $false; Jump = $false; Fly = $false; Swim = $false }
        $source = if ($v.movement) { $v.movement } elseif ($v.behavior) { $v.behavior } else { 'patrol' }
        foreach ($m in @($source)) {
            switch ("$m".ToLower()) {
                { $_ -in 'patrol', 'walk' }  { $moves.Patrol = $true }
                { $_ -in 'follow', 'chase' } { $moves.Follow = $true }
                { $_ -in 'jump', 'hop' }     { $moves.Jump = $true }
                'fly'   { $moves.Fly = $true }
                'swim'  { $moves.Swim = $true }
                'none'  { }
                default { $warn.Add("$label has unknown movement '$m'. Use patrol, follow, jump, fly, swim or none.") }
            }
        }
        if (($moves.Fly -or $moves.Swim) -and -not $moves.Patrol -and -not $moves.Follow -and "$source" -ne 'none') { $moves.Patrol = $true }
        $looked = "$($v.whenLookedAt)".ToLower()
        if ($looked -and $looked -notin 'stop', 'platform') { $warn.Add("$label whenLookedAt must be stop or platform."); $looked = '' }
        $stompable = Read-Bool $v.stompable $true
        $stompMode = "$(Get-OrDefault $v.stomp $(if ($stompable) { 'defeat' } else { 'hurt' }))".ToLower()
        if ($stompMode -notin 'defeat', 'bounce', 'hurt') { $warn.Add("$label stomp must be defeat, bounce or hurt."); $stompMode = 'defeat' }
        # What can hurt it. Without a list: everything except what the old true/false settings rule out.
        $weak = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $v.weakTo) { foreach ($w in @($v.weakTo)) { if ($w) { [void]$weak.Add("$w") } } }
        else {
            foreach ($w in 'star', 'shell', 'heavyStomp', 'block', 'hazard', '*') { [void]$weak.Add($w) }
            if (-not (Read-Bool $v.fireproof $false)) { [void]$weak.Add('fire') }
            if (Read-Bool $v.freezable $true) { [void]$weak.Add('ice') }
            if (-not (Read-Bool $v.lavaproof $false)) { [void]$weak.Add('lava') }
        }
        $contact = "$(Get-OrDefault $v.contact 'hurt')".ToLower()
        if ($contact -notin 'hurt', 'none') { $warn.Add("$label contact must be hurt or none."); $contact = 'hurt' }
        $enemy = @{
            Name         = Get-OrDefault $v.name $prop.Name
            Image        = Resolve-AssetPath $v.image
            Color        = $v.color
            Moves        = $moves
            Speed        = Read-Number $v.speed 60 0 2000 "$label speed" $warn
            Width        = Read-Number $v.width 28 4 512 "$label width" $warn
            Height       = Read-Number $v.height 24 4 512 "$label height" $warn
            TurnAtEdges  = Read-Bool $v.turnAtEdges $true
            Range        = Read-Number $v.range $(if ($moves.Fly -or $moves.Swim) { 96 } else { 0 }) 0 100000 "$label range" $warn
            Sight        = Read-Number $v.sight 320 0 100000 "$label sight" $warn
            JumpSpeed    = Read-Number $v.jumpSpeed 600 0 4000 "$label jumpSpeed" $warn
            JumpInterval = Read-Number $v.jumpInterval 1.2 0.1 60 "$label jumpInterval" $warn
            WhenLookedAt = $looked
            StompMode    = $stompMode
            Stompable    = $stompMode -ne 'hurt'
            WeakTo       = $weak
            Contact      = $contact
            Health       = [int](Read-Number $v.health 1 1 1000 "$label health" $warn)
            Boss         = Read-Bool $v.boss $false
            OnHit        = Read-FormChange $v.onHit
            OnDefeat     = Read-FormChange $v.onDefeat
            Carries      = @(@($v.carries) | Where-Object { $_ } | ForEach-Object { Read-Symbol $_ } | Where-Object { $_ })
            Kickable     = Read-Bool $v.kickable $false
            KickSpeed    = Read-Number $v.kickSpeed 480 10 3000 "$label kickSpeed" $warn
            Attacks      = Read-EnemyAttacks $v.attacks $label $warn
            Anims        = Read-Animations $v.animations "$label animation" $warn
            VulnerableWhen = "$(Get-OrDefault $v.vulnerableWhen 'always')".ToLower()
            HitEffects   = @{}
            StunTime     = Read-Number $v.stunTime 2.5 0.1 600 "$label stunTime" $warn
            Talk         = @(@($v.talk) | Where-Object { $_ } | ForEach-Object { "$_" })
            TalkEvery    = Read-Number $v.talkEvery 7 1 600 "$label talkEvery" $warn
            TalkTime     = Read-Number $v.talkTime 3 0.5 60 "$label talkTime" $warn
        }
        if ($enemy.VulnerableWhen -notin 'always', 'talking', 'stunned', 'thinking') { $warn.Add("$label vulnerableWhen must be always, talking, stunned or thinking."); $enemy.VulnerableWhen = 'always' }
        foreach ($hp in @(Get-JsonProperties $v.hitEffects)) {
            $fx = "$($hp.Value)".ToLower()
            if ($fx -in 'defeat', 'stun', 'freeze', 'none') { $enemy.HitEffects[$hp.Name] = $fx } else { $warn.Add("$label hitEffects '$($hp.Name)' must be defeat, stun, freeze or none.") }
        }
        $enemy.Freezable = Test-EnemyWeak $enemy 'ice'
        $enemy.Lavaproof = -not (Test-EnemyWeak $enemy 'lava')
        [void](Add-WorldSymbol $ctx $prop.Name 'enemy' $enemy 'Enemy')
    }

    # ---- Items: coins, collectibles, keys and power-ups ("powerups" is accepted as another name) ----
    $itemTypes = 'coin', 'collectible', 'key', 'life', 'shield', 'invincible', 'speed', 'fireball', 'iceball', 'fly', 'doubleJump', 'power'
    foreach ($prop in @(Get-JsonProperties $def.items) + @(Get-JsonProperties $def.powerups)) {
        if (-not $prop) { continue }
        $v = $prop.Value; $label = "$($tag)Item '$($prop.Name)'"
        $type = $itemTypes | Where-Object { $_ -eq "$($v.type)" } | Select-Object -First 1
        if (-not $type) { $warn.Add("$label has unknown type '$($v.type)'. Use one of: $($itemTypes -join ', ')."); continue }
        $item = @{
            Name = Get-OrDefault $v.name $type; Type = $type; Image = Resolve-AssetPath $v.image; Color = $v.color
            PlayerImage = Resolve-AssetPath $v.playerImage
            PlayerAnims = Read-Animations $v.playerAnimations "$label player animation" $warn
            IsPower = $type -in 'shield', 'fireball', 'iceball', 'fly', 'doubleJump', 'power'
            Message = "$($v.message)"
            Price = 0
        }
        # Only items that say so are sold in the shop: "shop": 20, or "shop": { "price": 20 }
        if ($null -ne $v.shop -and $v.shop -ne $false) {
            $raw = if ($v.shop -is [bool]) { $v.price } elseif ($v.shop -is [ValueType] -or $v.shop -is [string]) { $v.shop } else { $v.shop.price }
            $item.Price = [int](Read-Number $raw 10 1 1000000 "$label shop price" $warn)
            if (-not $item.IsPower) { $warn.Add("$label is marked for the shop, but only power-ups can be sold."); $item.Price = 0 }
        }
        switch ($type) {
            'coin'       { $item.Value = [int](Read-Number $v.value 1 1 1000 "$label value" $warn) }
            'key'        {
                $item.KeyId   = "$(Get-OrDefault $v.keyId $prop.Name)"
                $item.Persist = Read-Bool $v.keepBetweenLevels $true      # keys carry over to other levels unless told not to
            }
            'invincible' { $item.Duration = Read-Number $v.duration 8 0.5 600 "$label duration" $warn }
            'speed'      {
                $item.Duration   = Read-Number $v.duration 10 0.5 600 "$label duration" $warn
                $item.Multiplier = Read-Number $v.multiplier 1.5 0.1 5 "$label multiplier" $warn
            }
        }
        if ($item.IsPower) {
            $item.Duration = Read-Number $v.duration 0 0 600 "$label duration" $warn
            $item.Ability = Read-PowerAbilities $v $type $label $warn
        }
        [void](Add-WorldSymbol $ctx $prop.Name 'item' $item 'Item')
    }

    # ---- Mounts ----
    foreach ($prop in @(Get-JsonProperties $def.mounts)) {
        $v = $prop.Value; $label = "$($tag)Mount '$($prop.Name)'"
        $mount = @{
            Name    = Get-OrDefault $v.name $prop.Name
            Image   = Resolve-AssetPath $v.image
            Color   = $v.color
            Width   = Read-Number $v.width 44 8 256 "$label width" $warn
            Height  = Read-Number $v.height 30 8 256 "$label height" $warn
            RiderY  = Read-Number $v.riderY 8 -256 256 "$label riderY" $warn
            CanSwim = Read-Bool $v.canSwim $false
            Physics = Read-PhysicsOverrides $v.physics "$label physics" $warn
            Anims   = Read-Animations $v.animations "$label animation" $warn
        }
        [void](Add-WorldSymbol $ctx $prop.Name 'mount' $mount 'Mount')
    }

    # ---- Moving platforms and crushers ----
    foreach ($prop in @(Get-JsonProperties $def.platforms)) {
        $v = $prop.Value; $label = "$($tag)Platform '$($prop.Name)'"
        $move = @($v.move)
        $plat = @{
            Name        = Get-OrDefault $v.name $prop.Name
            Image       = Resolve-AssetPath $v.image
            Color       = $v.color
            Width       = [int](Read-Number $v.width 3 1 64 "$label width" $warn)
            Height      = [int](Read-Number $v.height 1 1 32 "$label height" $warn)
            MoveX       = Read-Number $(if ($move.Count -ge 1) { $move[0] }) 3 -1000 1000 "$label move x" $warn
            MoveY       = Read-Number $(if ($move.Count -ge 2) { $move[1] }) 0 -1000 1000 "$label move y" $warn
            Speed       = Read-Number $v.speed 80 1 5000 "$label speed" $warn
            PauseStart  = Read-Number $v.pauseStart 0.5 0 600 "$label pauseStart" $warn
            PauseEnd    = Read-Number $v.pauseEnd 0.5 0 600 "$label pauseEnd" $warn
            StartDelay  = Read-Number $v.startDelay 0 0 600 "$label startDelay" $warn
        }
        $plat.ReturnSpeed = Read-Number $v.returnSpeed $plat.Speed 1 5000 "$label returnSpeed" $warn
        $plat.OneWay = Read-Bool $v.oneWay ($plat.Height -eq 1)
        [void](Add-WorldSymbol $ctx $prop.Name 'platform' $plat 'Platform')
    }

    # ---- Extra exits. G is the normal goal; these are secret or alternate exits ----
    foreach ($prop in @(Get-JsonProperties $def.exits)) {
        $v = $prop.Value
        $exit = @{ Name = Get-OrDefault $v.name 'Exit'; Image = Resolve-AssetPath $v.image; Color = $v.color }
        [void](Add-WorldSymbol $ctx $prop.Name 'exit' $exit 'Exit')
    }

    # ---- Throwables: things the player can pick up and throw ----
    foreach ($prop in @(Get-JsonProperties $def.throwables)) {
        $v = $prop.Value; $label = "$($tag)Throwable '$($prop.Name)'"
        $th = @{ Name = Get-OrDefault $v.name 'Block'; Image = Resolve-AssetPath $v.image; Color = $v.color
                 Width = Read-Number $v.width 26 4 256 "$label width" $warn; Height = Read-Number $v.height 26 4 256 "$label height" $warn }
        [void](Add-WorldSymbol $ctx $prop.Name 'throwable' $th 'Throwable')
    }

    # ---- Spawners: where survival enemies appear, or (with "dispense") pipes that keep spitting things out ----
    foreach ($prop in @(Get-JsonProperties $def.spawners)) {
        $v = $prop.Value
        $label = "$($tag)Spawner '$($prop.Name)'"
        $sp = @{ Name = Get-OrDefault $v.name 'Spawner'; Image = Resolve-AssetPath $v.image; Color = $v.color; Dispense = $null }
        if ($v.dispense) {
            $list = New-Object System.Collections.ArrayList
            foreach ($k in @($v.dispense)) {
                $k = "$k"; $sym = $null
                if ($k.Length -ne 1 -or -not $ch.Symbols.TryGetValue([char]$k, [ref]$sym) -or $sym.Kind -notin 'enemy', 'item') { $warn.Add("$label dispense: '$k' isn't an enemy or item symbol."); continue }
                if ($sym.Kind -eq 'item' -and $sym.Def.Type -in 'coin', 'key', 'collectible', 'life', 'tetromino') { $warn.Add("$label dispense: '$k' is a $($sym.Def.Type); only power-ups and enemies can come out of a pipe."); continue }
                [void]$list.Add($k)
            }
            if ($list.Count) {
                $sp.Dispense = @($list)
                $sp.Every  = Read-Number $v.every 3 0.2 600 "$label every" $warn
                $sp.Launch = Read-Number $v.launch 420 0 2000 "$label launch" $warn
                $sp.Range  = Read-Number $v.range 640 32 100000 "$label range" $warn
                $sp.Solid  = if ($null -ne $v.solid) { [bool]$v.solid } else { $true }
                $walk = "$(Get-OrDefault $v.walk 'away')".ToLower()
                if ($walk -notin 'left', 'right', 'player', 'away') { $warn.Add("$label walk must be left, right, player or away."); $walk = 'away' }
                $sp.Walk = $walk
                $sp.Max = @{}
                foreach ($m in @(Get-JsonProperties $v.max)) { $sp.Max[$m.Name] = [int](Read-Number $m.Value 1 0 50 "$label max.$($m.Name)" $warn) }
            }
        }
        [void](Add-WorldSymbol $ctx $prop.Name 'spawner' $sp 'Spawner')
    }

    # Keys that carry between levels (by keyId), for every chapter together
    foreach ($sym in $ch.Symbols.Values) {
        if ($sym.Kind -eq 'item' -and $sym.Def.Type -eq 'key' -and $sym.Def.Persist) { [void]$world.PersistentKeys.Add($sym.Def.KeyId) }
    }

    # ---- Warp types (door / pipe / tunnel built in; worlds can restyle them or add more) ----
    foreach ($prop in @(Get-JsonProperties $def.warpTypes)) {
        $v = $prop.Value
        $type = if ($ch.WarpTypes.ContainsKey($prop.Name)) { Copy-Hashtable $ch.WarpTypes[$prop.Name] }
                else { @{ Name = $prop.Name; Enter = 'up'; Image = $null; Color = '#8D6E63' } }
        if ($v.enter) {
            $enter = "$($v.enter)".ToLower()
            if ($enter -in 'up', 'down', 'auto') { $type.Enter = $enter } else { $warn.Add("$($tag)Warp type '$($prop.Name)': enter must be up, down or auto.") }
        }
        if ($null -ne $v.image) { $type.Image = Resolve-AssetPath $v.image }
        if ($null -ne $v.color) { $type.Color = $v.color }
        $ch.WarpTypes[$prop.Name] = $type
    }

    # ---- Levels ----
    $levelDefs = @($def.levels | Where-Object { $_ })
    if ($levelDefs.Count -eq 0) { throw 'world.json has no levels.' }
    if ($levelDefs.Count -gt $MaxLevels) {
        $warn.Add("$($tag)world.json lists $($levelDefs.Count) levels; only the first $MaxLevels are used. Put more levels in an expansion chapter.")
        $levelDefs = $levelDefs[0..($MaxLevels - 1)]
    }
    $chStart = ($Index -eq 0) -or (Read-Bool $def.startUnlocked $false)
    for ($i = 0; $i -lt $levelDefs.Count; $i++) {
        $ld = $levelDefs[$i]; $local = $i + 1; $n = $Index * $MaxLevels + $local
        $lt = "$($tag)Level $local"
        $bg = Get-Background $ld.background $ch.Background
        $bgColor = Get-OrDefault $ld.backgroundColor $ch.BackgroundColor
        $lv = @{
            Number = $n; LocalNumber = $local; Label = "$local"; Chapter = $ch; Name = Get-OrDefault $ld.name "Level $local"
            Areas = [ordered]@{}; WarpDefs = @{}; WarpLinks = @{}; Start = $null; Collectibles = 0; Error = $null
            Hidden = Read-Bool $ld.hidden $false
            StartUnlocked = ($local -eq 1 -and $chStart) -or (Read-Bool $ld.startUnlocked $false)
            Exits = @{}                                                       # exit symbol -> level numbers it unlocks
            ExitRaw = @{}                                                     # as written, resolved once every chapter is read
            ExitRequires = @{}                                                # exit symbol -> what must be defeated first
            Requires = Read-Requirement $ld.requires $lt $warn                # applies to every exit of the level
            ExitChars = [System.Collections.Generic.HashSet[string]]::new()   # exits that are actually on the map
            Physics = Merge-Physics $ch.Physics (Read-PhysicsOverrides $ld.physics "$lt physics" $warn)
            TimeLimit = Read-Number $ld.timeLimit $ch.TimeLimit 0 100000 "$lt timeLimit" $warn
        }
        $lvWeather = Read-Weather $ld.weather $ch.Weather $lt $warn
        $lvType = Read-LevelType $ld.levelType $ch.LevelType $lt $warn
        if ($ld.areas) {
            foreach ($ap in @(Get-JsonProperties $ld.areas)) {
                $ad = $ap.Value; $al = "$lt area '$($ap.Name)'"
                $info = New-AreaInfo $ap.Name (Resolve-AssetPath $ad.file) (Get-Background $ad.background $bg) (Get-OrDefault $ad.backgroundColor $bgColor) (Read-Liquids $ad.liquids $al $warn) (Read-Survival $ad.survival $al $warn)
                $info.Weather = Read-Weather $ad.weather $lvWeather $al $warn
                $info.LevelType = Read-LevelType $ad.levelType $lvType $al $warn
                $lv.Areas[$ap.Name] = $info
            }
        }
        else {
            $info = New-AreaInfo 'main' (Resolve-AssetPath $ld.file) $bg $bgColor (Read-Liquids $ld.liquids $lt $warn) (Read-Survival $ld.survival $lt $warn)
            $info.Weather = $lvWeather; $info.LevelType = $lvType
            $lv.Areas['main'] = $info
        }
        if ($lv.Areas.Count -eq 0) { $lv.Error = 'The level has no areas.' }

        foreach ($wp in @(Get-JsonProperties $ld.warps)) {
            if ($wp.Name -notmatch '^[0-9]$') { $warn.Add("$lt warp '$($wp.Name)' skipped: warp names are single digits 0-9."); continue }
            $v = $wp.Value
            $typeName = if ($v -is [string]) { $v } else { Get-OrDefault $v.type 'door' }
            $lock = if ($v -isnot [string] -and $v.lock) { "$($v.lock)" } else { $null }
            if (-not $ch.WarpTypes.ContainsKey($typeName)) { $warn.Add("$lt warp $($wp.Name): unknown type '$typeName', using door."); $typeName = 'door' }
            $lv.WarpDefs[$wp.Name] = @{ Type = $typeName; Lock = $lock }
        }

        # Exits: which levels each exit unlocks, e.g. "exits": { "G": [2], "E": [9, "heights:1"] }
        foreach ($ep in @(Get-JsonProperties $ld.exits)) {
            $isExit = $ep.Name -ceq 'G'
            if (-not $isExit -and $ep.Name.Length -eq 1) {
                $sym = $null
                $isExit = $ch.Symbols.TryGetValue([char]$ep.Name, [ref]$sym) -and $sym.Kind -eq 'exit'
            }
            if (-not $isExit) { $warn.Add("$lt exit '$($ep.Name)' skipped: use G or a symbol from the world's exits section."); continue }
            $v = $ep.Value
            $isObj = $null -ne $v -and $v -isnot [array] -and $v -isnot [string] -and $v -isnot [ValueType]
            $list = if ($v -is [array]) { $v } elseif ($isObj) { @($v.unlocks) } else { @($v) }
            $lv.ExitRaw[$ep.Name] = @($list | Where-Object { $null -ne $_ -and "$_" -ne '' })
            if ($isObj -and $v.requires) { $lv.ExitRequires[$ep.Name] = Read-Requirement $v.requires "$lt exit '$($ep.Name)'" $warn }
        }
        [void]$ch.Levels.Add($lv)
    }
    foreach ($lv in $ch.Levels) { [void]$world.Levels.Add($lv); $world.LevelByNumber[$lv.Number] = $lv }
    [void]$world.Chapters.Add($ch)
    Read-MiniGames $def $ch
    $ch
}

function Test-EnemyWeak($Def, [string]$Attack) {
    if (-not $Attack) { return $false }
    if ($Def.WeakTo.Contains($Attack)) { return $true }
    $Def.WeakTo.Contains('*') -and ($Attack -notin 'star', 'shell', 'heavyStomp', 'block', 'hazard', 'fire', 'ice', 'lava', 'stomp')
}

function Import-WorldImage([string]$Path) {
    $world = $script:Loader.World
    $entry = Get-ZipEntry $script:Loader.Index $Path
    if (-not $entry) { $world.Warnings.Add("Missing image '$Path' (a coloured box is used instead)."); return }
    try { $world.Images[$Path] = Read-ZipImage $entry }
    catch { $world.Warnings.Add("Can't read image '$Path': $($_.Exception.Message)") }
}

function Import-WorldLevel($Level) {
    $world = $script:Loader.World
    $symbols = $Level.Chapter.Symbols
    $tag = "Level $($Level.Label) ($($Level.Name))"
    $starts = New-Object System.Collections.ArrayList
    $goals = 0
    $spots = @{}
    $unknown = [System.Collections.Generic.HashSet[char]]::new()

    foreach ($area in @($Level.Areas.Values)) {
        if (-not $area.File) { $area.Error = 'no "file" given in world.json'; continue }
        $entry = Get-ZipEntry $script:Loader.Index $area.File
        if (-not $entry) { $area.Error = "file not found: $($area.File)"; continue }
        $lines = @((Read-ZipText $entry) -split "`r?`n")
        $count = $lines.Count
        while ($count -gt 0 -and $lines[$count - 1].Trim() -eq '') { $count-- }
        if ($count -eq 0) { $area.Error = 'the level file is empty'; continue }
        $lines = @($lines[0..($count - 1)])
        $width = [int]($lines | Measure-Object -Property Length -Maximum).Maximum
        if ($width * $count * $world.TileSize * $world.TileSize -gt $MaxAreaPixels) { $area.Error = "too big ($width x $count tiles)"; continue }
        $area.Rows = [string[]]@($lines | ForEach-Object { $_.Replace("`t", ' ').PadRight($width, '.') })
        $area.W = $width
        $area.H = $count

        for ($y = 0; $y -lt $count; $y++) {
            $row = $area.Rows[$y]
            for ($x = 0; $x -lt $width; $x++) {
                $c = $row[$x]
                if ($c -ceq [char]'P') { [void]$starts.Add(@{ Area = $area.Id; X = $x; Y = $y }) }
                elseif ($c -ceq [char]'G') { $goals++; [void]$Level.ExitChars.Add('G') }
                elseif ($c -ge [char]'0' -and $c -le [char]'9') {
                    $d = "$c"
                    if (-not $spots.ContainsKey($d)) { $spots[$d] = New-Object System.Collections.ArrayList }
                    [void]$spots[$d].Add(@{ Area = $area.Id; X = $x; Y = $y })
                }
                elseif ($c -ceq [char]'C' -or $c -ceq [char]'.' -or $c -ceq [char]' ') { }
                else {
                    $sym = $null
                    if ($symbols.TryGetValue($c, [ref]$sym)) {
                        if ($sym.Kind -eq 'item' -and $sym.Def.Type -eq 'collectible') { $Level.Collectibles++ }
                        if ($sym.Kind -eq 'exit') { $goals++; [void]$Level.ExitChars.Add("$c") }
                    }
                    else { [void]$unknown.Add($c) }
                }
            }
        }
        if ($area.Survival) {
            $sv = $area.Survival
            foreach ($s in @($sv.Spawn) + @($sv.Waves | ForEach-Object { $_.Spawn })) {
                if (-not $s) { continue }
                $sym = $null
                if ($s.Length -ne 1 -or -not $symbols.TryGetValue([char]$s, [ref]$sym) -or $sym.Kind -ne 'enemy') { $world.Warnings.Add("$tag area '$($area.Id)' survival spawns '$s', which isn't an enemy.") }
            }
            if ($sv.CompleteLevel -and $sv.Exit -cne 'G' -and -not ($sv.Exit.Length -eq 1 -and $symbols.ContainsKey([char]$sv.Exit))) { $world.Warnings.Add("$tag survival exit '$($sv.Exit)' isn't an exit symbol; G is used."); $sv.Exit = 'G' }
            if ($sv.CompleteLevel) { [void]$Level.ExitChars.Add($sv.Exit); $goals++ }
        }
    }

    $broken = @($Level.Areas.Values | Where-Object { $_.Error })
    foreach ($b in $broken) { $world.Warnings.Add("$tag area '$($b.Id)': $($b.Error)") }
    if ($broken.Count) { $Level.Error = "Area '$($broken[0].Id)': $($broken[0].Error)"; return }
    if ($starts.Count -eq 0) { $Level.Error = 'No player start (P).'; $world.Warnings.Add("$tag has no player start (P), so it can't be played."); return }
    if ($starts.Count -gt 1) { $world.Warnings.Add("$tag has $($starts.Count) player starts; the first one is used.") }
    $Level.Start = $starts[0]
    if ($goals -eq 0 -and -not $Level.IsMiniGame) { $world.Warnings.Add("$tag has no goal (G) or other exit, so it can't be finished.") }
    foreach ($ec in @($Level.Exits.Keys)) {
        if (-not $Level.ExitChars.Contains($ec)) { $world.Warnings.Add("$tag sets up exit '$ec' in world.json but it isn't on the map.") }
    }
    foreach ($req in @(@($Level.Requires) + @($Level.ExitRequires.Values) | Where-Object { $_ })) {
        foreach ($k in @($req.Enemies.Keys)) {
            $sym = $null
            if ($k.Length -ne 1 -or -not $symbols.TryGetValue([char]$k, [ref]$sym) -or $sym.Kind -ne 'enemy') { $world.Warnings.Add("$tag requires defeating '$k', which isn't an enemy.") }
        }
        foreach ($k in @($req.Items.Keys)) {
            $sym = $null
            if ($k.Length -ne 1 -or -not $symbols.TryGetValue([char]$k, [ref]$sym) -or $sym.Kind -ne 'item') { $world.Warnings.Add("$tag requires collecting '$k', which isn't an item.") }
        }
    }
    foreach ($d in @($spots.Keys)) {
        $list = $spots[$d]
        if ($list.Count -eq 1) { $world.Warnings.Add("$tag warp $d appears only once, so it has nowhere to go.") }
        elseif ($list.Count -gt 2) { $world.Warnings.Add("$tag warp $d appears $($list.Count) times; only the first two are linked.") }
        $Level.WarpLinks[$d] = $list
    }
    foreach ($d in @($Level.WarpDefs.Keys)) {
        if (-not $spots.ContainsKey($d)) { $world.Warnings.Add("$tag sets up warp $d in world.json but it isn't on the map.") }
    }
    if ($unknown.Count) { $world.Warnings.Add("$tag uses unknown characters (shown as empty): $(@($unknown) -join ' ')") }
}

function Import-WorldSaves {
    $world = $script:Loader.World
    $entry = Get-ZipEntry $script:Loader.Index 'stats.json'
    try { $world.Stats = ConvertFrom-StatsJson $(if ($entry) { Read-ZipText $entry }) }
    catch { $world.Stats = New-EmptyStats; $world.Warnings.Add('stats.json could not be read, so stats start fresh.') }
    for ($n = 1; $n -le $SlotCount; $n++) {
        $e = Get-ZipEntry $script:Loader.Index "saves/slot$n.json"
        if (-not $e) { continue }
        try { $world.Slots[$n] = ConvertFrom-SlotJson (Read-ZipText $e) }
        catch { $world.Warnings.Add("Save slot $n could not be read and is shown as empty.") }
    }
    $world.SlotNumber = [int][math]::Max(1, [math]::Min($SlotCount, $world.Stats.lastSlot))
    foreach ($slot in @($world.Slots.Values)) {
        if (-not $slot -or -not $slot.NeedsUnlockUpgrade) { continue }
        foreach ($n in $slot.completed) {
            $lv = $world.LevelByNumber[[int]$n]
            if ($lv) { foreach ($u in (Get-ExitUnlocks $lv 'G' $world)) { if (-not $slot.unlocked.Contains($u)) { [void]$slot.unlocked.Add($u) } } }
        }
        $slot.Remove('NeedsUnlockUpgrade')
    }
}

# Which levels an exit opens. G with no setting opens the next level of the chapter that isn't hidden,
# or - after a chapter's last level - the first level of the next chapter.
function Get-ExitUnlocks($Level, [string]$Exit, $World = $null) {
    $w = if ($World) { $World } else { $script:World }
    $list = New-Object System.Collections.ArrayList
    if ($Level.Exits.ContainsKey($Exit) -and ($Exit -ceq 'G' -or $Level.Exits.Keys -ccontains $Exit)) {
        foreach ($n in $Level.Exits[$Exit]) { [void]$list.Add([int]$n) }
    }
    elseif ($Exit -ceq 'G') {
        $ch = $Level.Chapter
        $next = @($ch.Levels | Where-Object { $_.LocalNumber -gt $Level.LocalNumber -and -not $_.Hidden })
        if ($next.Count) { [void]$list.Add([int]$next[0].Number) }
        else {
            $later = @($w.Chapters | Where-Object { $_.Index -gt $ch.Index } | Sort-Object { $_.Index })
            foreach ($c in $later) {
                $first = @($c.Levels | Where-Object { -not $_.Hidden })
                if ($first.Count) { [void]$list.Add([int]$first[0].Number); break }
            }
        }
    }
    $list     # returned as plain numbers
}

function Test-LevelUnlocked($Slot, $Level) {
    $Level.StartUnlocked -or ($Slot -and $Slot.unlocked.Contains([int]$Level.Number))
}

# Older saves had a separate "shield" flag; it is now just a power-up like the others
function Get-SlotPowerKey($Power, $Shield) {
    if ($Power) { return "$Power" }
    if ($Shield) {
        foreach ($sym in $script:World.Symbols.Values) { if ($sym.Kind -eq 'item' -and $sym.Def.Type -eq 'shield') { return $sym.Def.Key } }
    }
    $null
}

function Get-ItemName([string]$Key) {
    if ($Key -and $Key.Length -eq 1) {
        $sym = $null
        if ($script:World.Symbols.TryGetValue([char]$Key, [ref]$sym)) { return $sym.Def.Name }
        foreach ($ch in $script:World.Chapters) { if ($ch.Symbols.TryGetValue([char]$Key, [ref]$sym)) { return $sym.Def.Name } }
    }
    $null
}

# ---------------------------------------------------------------------------
# World hub: save slots and level select
# ---------------------------------------------------------------------------
function Show-Hub {
    $world = $script:World
    Use-Chapter $world $world.Chapters[0]          # the world menu (shop, inventory) uses the main world's items
    Show-Screen 'WorldHub'
    $HubName.Text   = $world.Name
    $totals = Get-StatsTotals $world.Stats
    $HubAuthor.Text = "by $($world.Author)     $($world.Levels.Count) levels" + $(if ($world.Chapters.Count -gt 1) { " in $($world.Chapters.Count) chapters" } else { '' }) +
                      "     All saves: $($totals.Tries) tries, $($totals.Deaths) deaths, $(Format-Duration $world.Stats.totalPlaySeconds) played"
    $HubDesc.Text   = $world.Description
    if ($script:HubNote) { $HubDesc.Text = "$($script:HubNote)  $($world.Description)"; $script:HubNote = $null }
    $slot = $world.Slots[$world.SlotNumber]
    $completed = if ($slot) { $slot.completed } else { @() }

    $star = [char]0x2605
    $lock = [char]::ConvertFromUtf32(0x1F512)
    $LevelPanel.Children.Clear()
    $lastChapter = -1
    foreach ($lv in $world.Levels) {
        $st = Get-LevelStats $world.Stats $lv.Number
        $done = $completed -contains $lv.Number
        $unlocked = Test-LevelUnlocked $slot $lv
        if ($lv.Hidden -and -not $unlocked) { continue }          # hidden levels stay invisible until an exit opens them
        if ($world.Chapters.Count -gt 1 -and $lv.Chapter.Index -ne $lastChapter) {
            $lastChapter = $lv.Chapter.Index
            $head = New-Object System.Windows.Controls.TextBlock
            $head.Text = "Chapter $($lv.Chapter.Index + 1): $($lv.Chapter.Name)" + $(if ($lv.Chapter.IsExpansion) { '  (expansion)' } else { '' })
            $head.Foreground = ConvertTo-Brush '#FFC83D'; $head.FontSize = 15; $head.FontWeight = 'Bold'
            $head.Width = 620; $head.Margin = '0,4,0,6'
            [void]$LevelPanel.Children.Add($head)
        }

        $number = New-Object System.Windows.Controls.TextBlock
        $number.Text = "$($lv.Label)" + $(if ($done) { " $star" } else { '' })
        $number.FontSize = 24; $number.FontWeight = 'Black'; $number.HorizontalAlignment = 'Center'
        $name = New-Object System.Windows.Controls.TextBlock
        $name.Text = $(if ($lv.Hidden) { "$([char]0x2726) $($lv.Name)" } else { $lv.Name }); $name.FontSize = 13; $name.TextTrimming = 'CharacterEllipsis'; $name.HorizontalAlignment = 'Center'
        $info = New-Object System.Windows.Controls.TextBlock
        $info.FontSize = 11; $info.Opacity = 0.85; $info.HorizontalAlignment = 'Center'; $info.TextAlignment = 'Center'; $info.Margin = '0,3,0,0'
        $info.Text = if ($lv.Error) { 'Broken - see warnings' }
                     elseif (-not $unlocked) { "$lock Locked" }
                     else {
                         $lines = @($(if ($null -ne $st.bestTime) { "Best $(Format-Time $st.bestTime)" } else { "$($st.tries) tries" }))
                         if ($lv.Collectibles) { $lines += "Found $(Get-SlotTakenCount $slot $lv.Number 'collectible|')/$($lv.Collectibles)" }
                         if ($lv.ExitChars.Count -gt 1) {
                             $found = @($lv.ExitChars | Where-Object { $slot -and $slot.exits.Contains("$($lv.Number):$_") }).Count
                             $lines += "Exits $found/$($lv.ExitChars.Count)"
                         }
                         if ($lines.Count -lt 2) { $lines += "$($st.deaths) deaths" }
                         $lines -join "`n"
                     }
        $panel = New-Object System.Windows.Controls.StackPanel
        [void]$panel.Children.Add($number); [void]$panel.Children.Add($name); [void]$panel.Children.Add($info)

        $btn = New-Object System.Windows.Controls.Button
        $btn.Style     = $Window.FindResource('LevelButton')
        $btn.Content   = $panel
        $btn.Tag       = $lv.Number
        $btn.IsEnabled = $unlocked -and -not $lv.Error
        $btn.Add_Click({ param($s, $e) $n = [int]$s.Tag; Invoke-Safe { Start-Level $n $null } })
        [void]$LevelPanel.Children.Add($btn)
    }

    for ($n = 1; $n -le $SlotCount; $n++) {
        $b = Get-Variable -Name "BtnSlot$n" -Scope Script -ValueOnly
        $selected = $n -eq $world.SlotNumber
        $b.Background = ConvertTo-Brush $(if ($selected) { '#FFC83D' } else { '#2A3060' })
        $b.Foreground = ConvertTo-Brush $(if ($selected) { '#12152A' } else { '#EEF0FF' })
        $b.Content = "Slot $n" + $(if ($world.Slots[$n]) { '' } else { ' -' })
    }
    if ($slot) {
        $powerName = Get-OrDefault (Get-ItemName (Get-SlotPowerKey $slot.power $slot.shield)) 'normal'
        $keyText = (@($slot.keys.Keys | Sort-Object | ForEach-Object { if ($slot.keys[$_] -gt 1) { "$_ x$($slot.keys[$_])" } else { "$_" } }) -join ', ')
        $livesLeft = Get-SlotLives $slot
        $SlotInfo.Text = $(if ($slot.gameOver) { "GAME OVER (review only)`n" } else { '' }) +
                         "Levels done $($slot.completed.Count)    Lives $(if ($null -eq $livesLeft) { [char]0x221E } else { $livesLeft })    Coins $($slot.coins)`n" +
                         "Wearing: $powerName`n" +
                         $(if ((Get-TetroCollection $slot).Count -gt 0) { "Tetrominoes: $((Get-TetroCollection $slot).Count)/$($TetroNames.Count)" + $(if ((Get-TetroCollection $slot).Count -ge $TetroNames.Count) { ' - a secret game awaits!' } else { '' }) + "`n" } else { '' }) +
                         "Bag $(Get-SlotInventoryCount $slot)/$($InventorySize): " + $(Get-OrDefault ((@(foreach ($k in $slot.stash) { Get-OrDefault (Get-ItemName $k) $k }) + @($(if ($keyText) { "keys: $keyText" }))) -join ', ') 'empty') + "`n" +
                         "Played $(Format-Duration $slot.playSeconds)    Saved $(if ("$($slot.updated)" -match '^\d{4}-(.+)$') { $Matches[1] } else { Get-OrDefault $slot.updated 'not yet' })"
    }
    else { $SlotInfo.Text = "Empty slot.`nPick level 1 to start a new game here." + $(if ($world.Lives -gt 0) { "`nYou get $($world.Lives) lives." } else { '' }) }
    $BtnContinue.IsEnabled = [bool]($slot -and $slot.resume)
    $BtnContinue.Content = if ($slot -and $slot.resume) {
        $where = if ($null -ne $slot.resume.x) { 'checkpoint' } else { 'start' }
        $rl = $world.LevelByNumber[[int]$slot.resume.level]
        "Continue level $(if ($rl) { $rl.Label } else { $slot.resume.level }) ($where)"
    } else { 'Continue' }
    $BtnDeleteSlot.IsEnabled = [bool]$slot

    $over = [bool]($slot -and $slot.gameOver)
    $BtnShop.IsEnabled = -not $over -and ((Get-ShopItems).Count -gt 0 -or ($world.Lives -gt 0 -and $world.LifePrice -gt 0))
    $BtnInventory.IsEnabled = -not $over
    $BtnRecord.IsEnabled = [bool]$slot
    if ($over) {
        foreach ($c in $LevelPanel.Children) { if ($c -is [System.Windows.Controls.Button]) { $c.IsEnabled = $false } }
        $BtnContinue.IsEnabled = $true
        $BtnContinue.Content = 'GAME OVER - review this save'
    }
    $BtnMiniGames.IsEnabled = ($world.MiniGames.Count -gt 0 -or ($slot -and (Get-TetroCollection $slot).Count -ge $TetroNames.Count)) -and -not $over
    $BtnWarnings.Content = "Warnings ($($world.Warnings.Count))"
    $BtnWarnings.Visibility = if ($world.Warnings.Count -gt 0) { 'Visible' } else { 'Collapsed' }
}

# ---------------------------------------------------------------------------
# Mini-games (defined in world.json "minigames"): pick a box, a timing bar, or a challenge level
# ---------------------------------------------------------------------------
$AllTwists = 'reverse', 'waterSwap', 'noFloor', 'popSpikes'

function Read-MiniGames($def, $Chapter) {
    $world = $script:Loader.World; $warn = $world.Warnings
    $per2 = Read-Number $def.minigameMinutesPer2Coins $(if ($null -ne $world.MinutesPer2Coins) { $world.MinutesPer2Coins } else { 10 }) 0 100000 'minigameMinutesPer2Coins' $warn
    if ($Chapter.Index -eq 0) { $world.MinutesPer2Coins = $per2 }
    foreach ($m in @($def.minigames)) {
        if ($null -eq $m) { continue }
        $type = "$($m.type)".ToLower()
        $name = Get-OrDefault $m.name 'Mini-game'
        $label = "Mini-game '$name'"
        if ($type -notin 'pick', 'timing', 'level') { $warn.Add("$label type must be pick, timing or level."); continue }
        $id = ConvertTo-WorldId "$(Get-OrDefault $m.id $name)"
        if (@($world.MiniGames | Where-Object { $_.Id -eq $id }).Count) { $warn.Add("$label skipped: another mini-game already uses the id '$id'."); continue }
        $mg = @{ Id = $id; Name = $name; Type = $type; Description = "$($m.description)"; Chapter = $Chapter }
        switch ($type) {
            'pick' {
                $mg.Choices = [int](Read-Number $m.choices 3 2 9 "$label choices" $warn)
                $prizes = @(@($m.prizes) | Where-Object { $null -ne $_ } | ForEach-Object { [int](Read-Number $_ 0 0 100000 "$label prize" $warn) })
                if (-not $prizes.Count) { $prizes = @(0, 2, 6) }
                while ($prizes.Count -lt $mg.Choices) { $prizes += 0 }
                $mg.Prizes = @($prizes[0..($mg.Choices - 1)])
                $mg.MaxCoins = [int](($mg.Prizes | Measure-Object -Maximum).Maximum)
            }
            'timing' {
                $mg.MaxCoins = [int](Read-Number $m.maxCoins 6 1 100000 "$label maxCoins" $warn)
                $mg.Speed = Read-Number $m.speed 0.8 0.05 10 "$label speed" $warn
                $mg.Zone = Read-Number $m.zone 0.18 0.02 0.9 "$label zone" $warn
            }
            'level' {
                $mg.MaxCoins = [int](Read-Number $m.maxCoins 20 1 100000 "$label maxCoins" $warn)
                $mg.Time = Read-Number $m.time 30 5 3600 "$label time" $warn
                $mg.SwapEvery = Read-Number $m.swapEvery 4 1 120 "$label swapEvery" $warn
                $tw = @(@($m.twists) | Where-Object { $_ } | ForEach-Object { "$_" })
                if (-not $tw.Count) { $tw = @($AllTwists) }
                $mg.Twists = @($tw | Where-Object { $_ -in $AllTwists -or $_ -eq 'none' })
                foreach ($t in $tw) { if ($t -notin $AllTwists -and $t -ne 'none') { $warn.Add("$label twist '$t' is unknown. Use $($AllTwists -join ', ') or none.") } }
                if (-not $mg.Twists.Count) { $mg.Twists = @('none') }
                $n = 100000 + $world.MiniGames.Count * 2
                $mg.Level = New-MiniGameLevel $m $m.file $n $Chapter $label
                $mg.NoFloorLevel = if ($m.noFloorFile) { New-MiniGameLevel $m $m.noFloorFile ($n + 1) $Chapter "$label noFloorFile" } else { $null }
            }
        }
        $cd = if ($null -ne $m.cooldown) { Read-Number $m.cooldown 0 0 100000 "$label cooldown" $warn } else { $per2 * [math]::Ceiling($mg.MaxCoins / 2) }
        $mg.CooldownMinutes = $cd
        [void]$world.MiniGames.Add($mg)
    }
}

function New-MiniGameLevel($m, $File, [int]$Number, $Chapter, [string]$Label) {
    $warn = $script:Loader.World.Warnings
    $bg = Get-Background $m.background $Chapter.Background
    $lv = @{
        Number = $Number; LocalNumber = 0; Label = 'mini'; Chapter = $Chapter; Name = Get-OrDefault $m.name 'Mini-game'
        Areas = [ordered]@{}; WarpDefs = @{}; WarpLinks = @{}; Start = $null; Collectibles = 0; Error = $null
        Hidden = $true; StartUnlocked = $false; Exits = @{}; ExitRaw = @{}; ExitRequires = @{}; Requires = $null
        ExitChars = [System.Collections.Generic.HashSet[string]]::new()
        Physics = Merge-Physics $Chapter.Physics (Read-PhysicsOverrides $m.physics "$Label physics" $warn)
        TimeLimit = 0; IsMiniGame = $true; NoCache = $true
    }
    $lv.Areas['main'] = New-AreaInfo 'main' (Resolve-AssetPath $File) $bg (Get-OrDefault $m.backgroundColor $Chapter.BackgroundColor) (New-Object System.Collections.ArrayList) $null
    $lv
}

function Get-MiniGameWait($Mg) {
    $slot = $script:World.Slots[$script:World.SlotNumber]
    if (-not $slot -or -not $slot.minigames[$Mg.Id]) { return 0 }
    $last = [datetime]::MinValue
    if (-not [datetime]::TryParse($slot.minigames[$Mg.Id], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$last)) { return 0 }
    [math]::Max(0.0, ($last.AddMinutes($Mg.CooldownMinutes) - [datetime]::UtcNow).TotalMinutes)
}

function Show-MiniGames([string]$Note = '') {
    $world = $script:World
    $buttons = @()
    $lines = @()
    foreach ($mg in $world.MiniGames) {
        $wait = Get-MiniGameWait $mg
        $what = switch ($mg.Type) { 'pick' { 'pick a box' } 'timing' { 'timing' } 'level' { "$([int]$mg.Time)s challenge" } }
        $lines += "$($mg.Name) - $what, up to $($mg.MaxCoins) coins" + $(if ($wait -gt 0) { "  (ready in $([math]::Ceiling($wait)) min)" } else { '  (ready!)' })
        $buttons += @{ Text = $(if ($wait -gt 0) { "$($mg.Name) ($([math]::Ceiling($wait))m)" } else { "Play $($mg.Name)" }); Action = [scriptblock]::Create("Start-MiniGame '$($mg.Id)'") }
    }
    $slot = $world.Slots[$world.SlotNumber]
    if ($slot -and (Get-TetroCollection $slot).Count -ge $TetroNames.Count) {
        $buttons = @(@{ Text = "$([char]0x2605) Block Drop (secret!)"; Action = { Start-BlockGame } }) + $buttons
        $lines = @("$([char]0x2605) Block Drop - you found all seven tetrominoes! Two minutes, coins for every line.") + $lines
    }
    $buttons += @{ Text = 'Close'; Action = { Hide-Overlay; Show-Hub } }
    $text = if ($lines.Count) { $lines -join "`n" } else { 'This world has no mini-games.' }
    if ($Note) { $text = "$Note`n`n$text" }
    Show-Overlay 'MINI-GAMES' $text $buttons
}

function Start-MiniGame([string]$Id) {
    $world = $script:World
    $mg = @($world.MiniGames | Where-Object { $_.Id -eq $Id })[0]
    if (-not $mg) { return }
    $wait = Get-MiniGameWait $mg
    if ($wait -gt 0) { Show-MiniGames "$($mg.Name) can be played again in $([math]::Ceiling($wait)) minutes."; return }
    if ($mg.Type -eq 'level' -and ($mg.Level.Error -or ($mg.NoFloorLevel -and $mg.NoFloorLevel.Error))) { Show-MiniGames "$($mg.Name) is broken: $($mg.Level.Error)"; return }
    $slot = Get-CurrentSlot
    $slot.minigames[$mg.Id] = [datetime]::UtcNow.ToString('o')     # starting it counts as playing it
    Add-Record 'minigamesPlayed' -Always
    [void](Save-WorldData)
    switch ($mg.Type) {
        'pick'   { Start-PickGame $mg }
        'timing' { Start-TimingGame $mg }
        'level'  { Start-ChallengeLevel $mg }
    }
}

function Add-SlotCoins([int]$Coins) {
    $slot = Get-CurrentSlot
    $slot.coins += $Coins
    Add-Record 'minigameCoins' '' $Coins -Always
    [void](Save-WorldData)
}

# ---- Pick a box ----
function Start-PickGame($Mg) {
    $script:PickPrizes = @($Mg.Prizes | Get-Random -Count $Mg.Prizes.Count)
    $script:PickGame = $Mg
    $buttons = @(for ($i = 0; $i -lt $Mg.Choices; $i++) { @{ Text = "Box $($i + 1)"; Action = [scriptblock]::Create("Complete-PickGame $i") } })
    Show-Overlay $Mg.Name.ToUpper() "$(Get-OrDefault $Mg.Description 'Pick a box. One of them holds the big prize!')" $buttons
}

function Complete-PickGame([int]$Index) {
    $mg = $script:PickGame
    $won = [int]$script:PickPrizes[$Index]
    Add-SlotCoins $won
    $reveal = (@(for ($i = 0; $i -lt $script:PickPrizes.Count; $i++) { "Box $($i + 1): $($script:PickPrizes[$i])" + $(if ($i -eq $Index) { '  <- yours' } else { '' }) }) -join "`n")
    Show-Overlay $(if ($won -gt 0) { "YOU WON $won COINS!" } else { 'EMPTY!' }) $reveal @(
        @{ Text = 'Back to mini-games'; Action = { Show-MiniGames } }
        @{ Text = 'World menu'; Action = { Hide-Overlay; Show-Hub } }
    )
}

# ---- Timing: stop the marker inside the zone ----
$TimingTimer = New-Object System.Windows.Threading.DispatcherTimer
$TimingTimer.Interval = [TimeSpan]::FromMilliseconds(16)
$TimingTimer.Add_Tick({ Update-TimingGame })

function Start-TimingGame($Mg) {
    $center = 0.2 + (Get-Random -Minimum 0.0 -Maximum 1.0) * 0.6
    $script:Timing = @{ Def = $Mg; Pos = 0.0; Dir = 1; Center = $center; Last = $script:Clock.Elapsed.TotalSeconds }
    Show-Overlay $Mg.Name.ToUpper() '' @(@{ Text = 'STOP!'; Action = { Complete-TimingGame } })
    try { $OverlayText.FontFamily = New-Object System.Windows.Media.FontFamily 'Consolas' } catch { }
    Update-TimingGame
    $TimingTimer.Start()
}

function Update-TimingGame {
    $t = $script:Timing
    if (-not $t) { $TimingTimer.Stop(); return }
    $now = $script:Clock.Elapsed.TotalSeconds
    $dt = [math]::Min(0.05, $now - $t.Last); $t.Last = $now
    $t.Pos += $t.Dir * $t.Def.Speed * $dt
    if ($t.Pos -ge 1) { $t.Pos = 1.0; $t.Dir = -1 } elseif ($t.Pos -le 0) { $t.Pos = 0.0; $t.Dir = 1 }
    $n = 41
    $bar = New-Object System.Text.StringBuilder
    $half = $t.Def.Zone / 2
    $mark = [int][math]::Round($t.Pos * ($n - 1))
    for ($i = 0; $i -lt $n; $i++) {
        $f = $i / ($n - 1)
        $ch = if ($i -eq $mark) { [char]0x25C6 } elseif ([math]::Abs($f - $t.Center) -le $half) { '=' } else { '-' }
        [void]$bar.Append($ch)
    }
    $OverlayText.Text = "Stop the marker inside the === zone!`nDead centre wins $($t.Def.MaxCoins) coins.`n`n[$($bar.ToString())]"
}

function Complete-TimingGame {
    $TimingTimer.Stop()
    $t = $script:Timing
    if (-not $t) { return }
    $script:Timing = $null
    try { $OverlayText.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe UI' } catch { }
    $half = $t.Def.Zone / 2
    $dist = [math]::Abs($t.Pos - $t.Center)
    $won = if ($dist -le $half) { [int][math]::Max(1, [math]::Round($t.Def.MaxCoins * (1 - 0.5 * $dist / $half))) } else { 0 }
    Add-SlotCoins $won
    Show-Overlay $(if ($won -gt 0) { "YOU WON $won COINS!" } else { 'MISSED!' }) $(if ($won -gt 0) { 'Nice timing.' } else { 'So close. Try again when it cools down.' }) @(
        @{ Text = 'Back to mini-games'; Action = { Show-MiniGames } }
        @{ Text = 'World menu'; Action = { Hide-Overlay; Show-Hub } }
    )
}

# ---- Challenge level with a random twist ----
function Start-ChallengeLevel($Mg) {
    $twist = $Mg.Twists | Get-Random
    $lv = if ($twist -eq 'noFloor' -and $Mg.NoFloorLevel) { $Mg.NoFloorLevel } else { $Mg.Level }
    if ($twist -eq 'noFloor' -and -not $Mg.NoFloorLevel) { $lv = New-NoFloorLevel $lv }
    $names = @{ reverse = 'Reversed controls'; waterSwap = 'Water / dry swap'; noFloor = 'No floor'; popSpikes = 'Pop-up spikes'; none = 'None' }
    Hide-Overlay
    Start-Level 0 $null @{ Def = $Mg; Name = $Mg.Name; Time = $Mg.Time; MaxCoins = $Mg.MaxCoins; Level = $lv; Twist = $twist; TwistName = $names[$twist] }
}

# The challenge level with its floor taken away (moving platforms are added when it starts)
function New-NoFloorLevel($Level) {
    $lv = Copy-Hashtable $Level
    $lv.Areas = [ordered]@{}
    $lv.NoFloor = $true
    $world = $script:World
    foreach ($k in @($Level.Areas.Keys)) {
        $area = Copy-Hashtable $Level.Areas[$k]
        $rows = [string[]]@($area.Rows)
        $sx = if ($Level.Start.Area -eq $k) { $Level.Start.X } else { -100 }
        for ($y = [math]::Max(0, $area.H - 3); $y -lt $area.H; $y++) {
            $chars = $rows[$y].ToCharArray()
            for ($x = 0; $x -lt $chars.Length; $x++) {
                if ([math]::Abs($x - $sx) -le 2) { continue }
                $sym = $null
                if ($world.Symbols.TryGetValue($chars[$x], [ref]$sym) -and $sym.Kind -eq 'tile' -and $sym.Def.Solid) { $chars[$x] = '.' }
            }
            $rows[$y] = -join $chars
        }
        $area.Rows = $rows
        $lv.Areas[$k] = $area
    }
    $lv
}

# Called at the start of a mini-game's life: sets the twist up in the area
function Initialize-Twist {
    $R = $script:Run; $A = $R.A; $ts = $R.T
    $mg = $R.MiniGame
    $R.Twist = @{ Kind = $mg.Twist; Name = $mg.TwistName; Timer = $mg.Def.SwapEvery; Water = $false; Tint = $null }
    switch ($mg.Twist) {
        'noFloor' {
            if (-not $R.Level.NoFloor) { break }        # the world gave its own no-floor map
            $img = $null
            foreach ($sym in $script:World.Symbols.Values) { if ($sym.Kind -eq 'platform' -and $sym.Def.Image) { $img = $sym.Def.Image; break } }
            $y = $A.Map.H - 3
            $k = 0
            for ($x = $R.Level.Start.X + 3; $x -lt $A.Map.W - 2; $x += 6) {
                $def = @{ Name = 'Platform'; Image = $img; Color = '#8D6E63'; Width = 3; Height = 1; MoveX = $(if ($k % 2) { -2 } else { 2 }); MoveY = 0
                          Speed = 70 + 15 * ($k % 3); ReturnSpeed = 70 + 15 * ($k % 3); PauseStart = 0.4; PauseEnd = 0.4; StartDelay = 0.0; OneWay = $true }
                $px = $(if ($k % 2) { $x + 1 } else { $x - 1 }) * $ts
                $pf = @{ Def = $def; X = $px; Y = $y * $ts; W = 3 * $ts; H = $ts; StartX = $px; StartY = $y * $ts
                         Length = 2 * $ts; UX = [math]::Sign($def.MoveX); UY = 0; Progress = 0.0; Phase = 'out'; Pause = 0.0; Delay = ($k % 3) * 0.5; DX = 0.0; DY = 0.0
                         SolidOn = $true; OneWay = $true; Pushable = $false }
                $pf.Sprite = New-BoxSprite (Get-WorldImage $img) (3 * $ts) $ts '#8D6E63' $ts $false
                [void]$A.Platforms.Add($pf); Add-Sprite $pf.Sprite; Set-ElementAt $pf.Sprite $pf.X $pf.Y
                $k++
            }
            Update-SolidList
        }
        'popSpikes' {
            $img = $null
            foreach ($sym in $script:World.Symbols.Values) { if ($sym.Kind -eq 'tile' -and ($sym.Def.Spikes -band 1)) { $img = Get-TileBitmap $sym.Def; break } }
            $x = $R.Level.Start.X + 4
            while ($x -lt $A.Map.W - 1) {
                for ($y = 1; $y -lt $A.Map.H - 1; $y++) {
                    if (-not $A.Solid[$x, $y] -and $A.Solid[$x, ($y + 1)] -and -not $A.Map.Liquid[$x, $y]) {
                        $ps = @{ CellX = $x; CellY = $y; X = $x * $ts; Y = $y * $ts; W = $ts; H = $ts; Phase = 'in'; Timer = 0.5 + (Get-Random -Minimum 0.0 -Maximum 2.0) }
                        $ps.Sprite = New-Sprite $img $ts $ts '#CFD8DC'
                        $ps.Sprite.Width = $ts; $ps.Sprite.Height = $ts
                        [void]$A.PopSpikes.Add($ps); Add-Sprite $ps.Sprite; Set-PopSpikeLook $ps
                        break
                    }
                }
                $x += 3 + (Get-Random -Minimum 0 -Maximum 3)
            }
        }
        'waterSwap' {
            $tint = New-BoxSprite $null $A.Map.WidthPx $A.Map.HeightPx '#443FA9F5' $ts $false
            $tint.IsHitTestVisible = $false; $tint.Visibility = 'Collapsed'
            [void]$FrontCanvas.Children.Add($tint); Set-ElementAt $tint 0 0
            $R.Twist.Tint = $tint
        }
    }
    Show-Toast "Twist: $($R.Twist.Name)!  Grab coins for $([int]$mg.Time)s."
}

function Update-Twist([double]$dt) {
    $R = $script:Run; $tw = $R.Twist
    if (-not $tw) { return }
    if ($tw.Kind -eq 'waterSwap') {
        $tw.Timer -= $dt
        if ($tw.Timer -le 0) {
            $tw.Timer = $R.MiniGame.Def.SwapEvery
            $tw.Water = -not $tw.Water
            if ($tw.Tint) { $tw.Tint.Visibility = if ($tw.Water) { 'Visible' } else { 'Collapsed' } }
            Show-Toast $(if ($tw.Water) { 'Water physics!' } else { 'Dry again!' })
        }
    }
    foreach ($ps in $R.A.PopSpikes) {
        $ps.Timer -= $dt
        if ($ps.Timer -gt 0) { continue }
        switch ($ps.Phase) {
            'in'   { $ps.Phase = 'warn'; $ps.Timer = 0.5 }
            'warn' { $ps.Phase = 'out';  $ps.Timer = 1.2; $R.Hazard[$ps.CellX, $ps.CellY] = 1 }
            'out'  { $ps.Phase = 'in';   $ps.Timer = 1.6; $R.Hazard[$ps.CellX, $ps.CellY] = 0 }
        }
    }
}

function Set-PopSpikeLook($Ps) {
    $s = $Ps.Sprite
    switch ($Ps.Phase) {
        'in'   { $s.Opacity = 0.0 }
        'warn' { $s.Opacity = 0.6; Set-ElementAt $s $Ps.X ($Ps.Y + $Ps.H * 0.65) }
        'out'  { $s.Opacity = 1.0; Set-ElementAt $s $Ps.X $Ps.Y }
    }
}

# The challenge is over: time ran out or the goal was reached (keep everything), or you died (keep half)
function Complete-MiniGameLevel([string]$Message, [bool]$Died = $false) {
    $R = $script:Run
    if ($R.State -notin 'Playing', 'Paused') { return }
    $R.State = 'Complete'
    $got = 0
    foreach ($p in $R.Pending) { if ($p.Kind -eq 'coin') { $got += $p.Value } }
    $won = if ($Died) { [int][math]::Floor($got / 2) } else { $got }
    $capped = $won -gt $R.MiniGame.MaxCoins
    $won = [math]::Min($won, $R.MiniGame.MaxCoins)
    $R.Pending.Clear()
    $R.Slot.coins += $won
    Add-Record 'minigameCoins' '' $won -Always
    [void](Save-WorldData)
    $text = "$Message`nCoins grabbed: $got" +
            $(if ($Died) { "`nYou didn't last, so you keep half." } else { '' }) +
            "`nYou won $won coin$(if ($won -ne 1) { 's' })!" +
            $(if ($capped) { " (the most this game pays is $($R.MiniGame.MaxCoins))" } else { '' })
    Show-Overlay $(if ($Died) { 'GAME OVER' } else { 'TIME!' }) $text @(@{ Text = 'Back to world menu'; Action = { Exit-Level } })
}

# ---------------------------------------------------------------------------
# Inventory and shop (in the world menu)
# ---------------------------------------------------------------------------
function Get-SlotInventoryCount($Slot) {
    if (-not $Slot) { return 0 }
    $n = $Slot.stash.Count
    foreach ($k in @($Slot.keys.Keys)) { $n += [int]$Slot.keys[$k] }
    $n
}

function Get-InventoryText($Slot) {
    if (-not $Slot) { return 'Empty slot.' }
    $wearing = Get-OrDefault (Get-ItemName (Get-SlotPowerKey $Slot.power $Slot.shield)) 'nothing'
    $items = @(foreach ($k in $Slot.stash) { Get-OrDefault (Get-ItemName $k) $k })
    $keys = @(foreach ($k in @($Slot.keys.Keys | Sort-Object)) { "$k key" + $(if ($Slot.keys[$k] -gt 1) { " x$($Slot.keys[$k])" } else { '' }) })
    "Wearing: $wearing`nBag ($(Get-SlotInventoryCount $Slot)/$InventorySize): " + $(if ($items.Count + $keys.Count) { (@($items) + @($keys)) -join ', ' } else { 'empty' })
}

# Gives the save slot a power-up from the shop: worn if you have none, stored if there's room, else swapped
function Grant-PowerToSlot($Slot, $Def) {
    $Slot.shield = $false
    if (-not $Slot.power) { $Slot.power = [string]$Def.Key; return "You're wearing the $($Def.Name). It lasts until you're hit." }
    if ((Get-SlotInventoryCount $Slot) -lt $InventorySize) { [void]$Slot.stash.Add([string]$Def.Key); return "The $($Def.Name) went into your bag." }
    $old = Get-OrDefault (Get-ItemName $Slot.power) 'old power-up'
    $Slot.power = [string]$Def.Key
    "Bag full - you swapped your $old for the $($Def.Name)."
}

function Show-Inventory([string]$Note = '') {
    $slot = Get-CurrentSlot
    $buttons = @()
    for ($i = 0; $i -lt $slot.stash.Count; $i++) {
        $buttons += @{ Text = "Wear $(Get-OrDefault (Get-ItemName $slot.stash[$i]) $slot.stash[$i])"; Action = [scriptblock]::Create("Use-StashedPower $i") }
    }
    if ($slot.power -and (Get-SlotInventoryCount $slot) -lt $InventorySize) { $buttons += @{ Text = 'Take off and store'; Action = { Use-StashedPower -1 } } }
    if ($slot.stash.Count) { $buttons += @{ Text = 'Throw one away...'; Action = { Show-Discard } } }
    $buttons += @{ Text = 'Close'; Action = { Hide-Overlay; Show-Hub } }
    $text = (Get-InventoryText $slot) + "`n`nThe power-up you wear is the one you start your next level with.`nKeys are used up when they open something."
    if ($Note) { $text = "$Note`n`n$text" }
    Show-Overlay 'INVENTORY' $text $buttons
}

# Wear stored power-up number $Index (what you wore goes back in the bag). -1 = take off what you wear.
function Use-StashedPower([int]$Index) {
    $slot = Get-CurrentSlot
    $current = Get-SlotPowerKey $slot.power $slot.shield
    $slot.shield = $false
    if ($Index -lt 0) {
        if ($current) { [void]$slot.stash.Add("$current"); $slot.power = $null }
        [void](Save-WorldData); Show-Inventory 'Stored.'; return
    }
    $key = $slot.stash[$Index]
    $slot.stash.RemoveAt($Index)
    if ($current) { $slot.stash.Insert([math]::Min($Index, $slot.stash.Count), "$current") }
    $slot.power = "$key"
    [void](Save-WorldData)
    Show-Inventory "You'll start the next level with the $(Get-ItemName $key)."
}

function Show-Discard {
    $slot = Get-CurrentSlot
    $buttons = @(for ($i = 0; $i -lt $slot.stash.Count; $i++) { @{ Text = "Throw away $(Get-OrDefault (Get-ItemName $slot.stash[$i]) $slot.stash[$i])"; Action = [scriptblock]::Create("Remove-StashedPower $i") } })
    $buttons += @{ Text = 'Back'; Action = { Show-Inventory } }
    Show-Overlay 'THROW AWAY' 'Pick a power-up to throw away. This can''t be undone.' $buttons
}

function Remove-StashedPower([int]$Index) {
    $slot = Get-CurrentSlot
    $name = Get-ItemName $slot.stash[$Index]
    $slot.stash.RemoveAt($Index)
    [void](Save-WorldData)
    Show-Inventory "Threw away the $name."
}

function Show-Review {
    $world = $script:World
    $slot = $world.Slots[$world.SlotNumber]
    if (-not $slot) { return }
    $rec = if ($slot.record) { $slot.record } else { New-Record }
    $done = @($slot.completed | ForEach-Object { $world.LevelByNumber[[int]$_] } | Where-Object { $_ } | Sort-Object { $_.Number })
    $furthest = if ($done.Count) { "$($done[-1].Label). $($done[-1].Name)" } else { 'no levels finished' }
    $visible = @($world.Levels | Where-Object { -not $_.Hidden }).Count
    $secretExits = @($slot.exits | Where-Object { $_ -notmatch ':G$' }).Count
    $hiddenFound = @($world.Levels | Where-Object { $_.Hidden -and (Test-LevelUnlocked $slot $_) }).Count
    $fmt = { param($h) if ($h -and $h.Count) { (@($h.Keys | Sort-Object | ForEach-Object { if ($h[$_] -gt 1) { "$_ x$($h[$_])" } else { "$_" } })) -join ', ' } else { 'none' } }
    $lives = Get-SlotLives $slot
    $text = @(
        $(if ($slot.gameOver) { 'GAME OVER - out of lives.' } else { "Still going$(if ($null -ne $lives) { " - $lives lives left" })." })
        "Furthest: $furthest   ($($slot.completed.Count) levels done; $visible in the world)"
        "Played: $(Format-Duration $slot.playSeconds)   Tries: $([int]$rec.tries)   Deaths: $([int]$rec.deaths)"
        "Deaths by: $(& $fmt $rec.deathsBy)"
        "Enemies defeated: $([int]$rec.enemies)   Bosses beaten: $(if ($rec.bosses -and $rec.bosses.Count) { $rec.bosses -join ', ' } else { 'none' })"
        "Power-ups found: $(& $fmt $rec.powers)"
        "Power-ups bought: $(& $fmt $rec.powersBought)   lost: $(& $fmt $rec.powersLost)"
        "Items found: $(& $fmt $rec.items)"
        "Secret exits: $secretExits   Hidden levels opened: $hiddenFound"
        "Coins: $([int]$rec.coinsCollected) collected, $([int]$rec.coinsSpent) spent, $([int]$rec.minigameCoins) won in $([int]$rec.minigamesPlayed) mini-games, $($slot.coins) left"
        "Extra lives: $([int]$rec.livesFound) found, $([int]$rec.livesBought) bought" + $(if ([int]$rec.naps -gt 0) { "   Naps taken: $([int]$rec.naps)" } else { '' }) + $(if ([int]$rec.tetrominoes -gt 0) { "`nTetrominoes found: $([int]$rec.tetrominoes)   Block Drop games: $([int]$rec.blockGames)" } else { '' })
    ) -join "`n"
    Show-Overlay 'SAVE REVIEW' $text @(@{ Text = 'Close'; Action = { Hide-Overlay; Show-Hub } })
}

# Everything for sale, from the main world and every chapter
function Get-ShopItems {
    $seen = @{}
    $list = @()
    foreach ($ch in $script:World.Chapters) {
        foreach ($sym in $ch.Symbols.Values) {
            $d = $sym.Def
            if ($sym.Kind -eq 'item' -and $d.IsPower -and $d.Price -gt 0 -and -not $seen.ContainsKey($d.Key)) { $seen[$d.Key] = $true; $list += $d }
        }
    }
    @($list | Sort-Object { $_.Price })
}

function Show-Shop([string]$Note = '') {
    $slot = Get-CurrentSlot
    $buttons = @(foreach ($d in (Get-ShopItems)) { @{ Text = "$($d.Name) - $($d.Price) coins"; Action = [scriptblock]::Create("Invoke-ShopBuy '$($d.Key -replace "'", "''")'") } })
    if ($script:World.Lives -gt 0 -and $script:World.LifePrice -gt 0) { $buttons += @{ Text = "Extra life - $($script:World.LifePrice) coins"; Action = { Invoke-ShopBuy 'LIFE' } } }
    $buttons += @{ Text = 'Close'; Action = { Hide-Overlay; Show-Hub } }
    $lives = Get-SlotLives $slot
    $text = "You have $($slot.coins) coins." + $(if ($null -ne $lives) { "   Lives: $lives" }) + "`n" + (Get-InventoryText $slot)
    if ((Get-ShopItems).Count -eq 0 -and -not ($script:World.Lives -gt 0 -and $script:World.LifePrice -gt 0)) { $text += "`n`nNothing is for sale in this world." }
    if ($Note) { $text = "$Note`n`n$text" }
    Show-Overlay 'SHOP' $text $buttons
}

function Invoke-ShopBuy([string]$Key) {
    $slot = Get-CurrentSlot
    if ($Key -eq 'LIFE') {
        $price = $script:World.LifePrice
        if ($slot.coins -lt $price) { Show-Shop "Not enough coins for an extra life (you need $($price - $slot.coins) more)."; return }
        $slot.coins -= $price
        $slot.lives = (Get-SlotLives $slot) + 1
        Add-Record 'coinsSpent' '' $price; Add-Record 'livesBought'
        [void](Save-WorldData)
        Show-Shop "Bought an extra life! Lives: $($slot.lives)"
        return
    }
    $def = Find-PowerDef $Key
    if (-not $def -or $def.Price -le 0) { Show-Shop "That isn't for sale."; return }
    if ($slot.coins -lt $def.Price) { Show-Shop "Not enough coins for the $($def.Name) (you need $($def.Price - $slot.coins) more)."; return }
    $slot.coins -= $def.Price
    Add-Record 'coinsSpent' '' $def.Price; Add-Record 'powersBought' $def.Name
    $msg = Grant-PowerToSlot $slot $def
    [void](Save-WorldData)
    Show-Shop "Bought the $($def.Name)! $msg"
}

# ---------------------------------------------------------------------------
# Expansions: other world zips that add chapters (more levels) to this one
# ---------------------------------------------------------------------------
function Get-ZipDefinition([string]$Path) {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $index = Get-ZipIndex $zip
        $def = Read-ZipText $index.Map[$index.WorldJsonKey] | ConvertFrom-Json
        @{ Def = $def; Root = $index.Root; Names = @($index.Map.Keys) }
    }
    finally { $zip.Dispose() }
}

function Get-ExpansionFiles {
    $out = @()
    foreach ($f in Get-WorldFiles) {
        try {
            $z = Get-ZipDefinition $f.FullName
            if (-not $z.Def.expansionOf) { continue }
            $name = Get-OrDefault $z.Def.name ([IO.Path]::GetFileNameWithoutExtension($f.Name))
            $out += @{ Path = $f.FullName; Name = $name; Id = ConvertTo-WorldId "$(Get-OrDefault $z.Def.id $name)"; ExpansionOf = ConvertTo-WorldId "$($z.Def.expansionOf)"; Levels = @($z.Def.levels | Where-Object { $_ }).Count }
        }
        catch { }
    }
    $out
}

# Copies an expansion zip into a world zip as chapters/<id>/ and lists it in chapters.json
function Install-Expansion([string]$WorldPath, [string]$ExpansionPath) {
    $base = Get-ZipDefinition $WorldPath
    $exp = Get-ZipDefinition $ExpansionPath
    $name = Get-OrDefault $exp.Def.name ([IO.Path]::GetFileNameWithoutExtension($ExpansionPath))
    $id = ConvertTo-WorldId "$(Get-OrDefault $exp.Def.id $name)"
    $set = [ordered]@{}
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ExpansionPath)
    try {
        $index = Get-ZipIndex $zip
        foreach ($k in @($index.Map.Keys)) {
            if (-not $k.StartsWith($index.Root)) { continue }
            $rel = $k.Substring($index.Root.Length)
            if ($rel -like 'saves/*' -or $rel -in 'stats.json', 'chapters.json' -or $rel -like 'chapters/*') { continue }
            $ms = New-Object System.IO.MemoryStream
            $st = $index.Map[$k].Open(); try { $st.CopyTo($ms) } finally { $st.Dispose() }
            $set["chapters/$id/$rel"] = $ms.ToArray()
        }
    }
    finally { $zip.Dispose() }
    $old = @($base.Names | Where-Object { $_.StartsWith("$($base.Root)chapters/$id/") } | ForEach-Object { $_.Substring($base.Root.Length) } | Where-Object { -not $set.Contains($_) })
    $list = @(Get-InstalledChapterIds $WorldPath)
    if ($list -notcontains $id) { $list += $id }
    $set['chapters.json'] = (New-Object System.Text.UTF8Encoding $false).GetBytes((@{ chapters = $list } | ConvertTo-Json -Depth 4))
    Write-ZipEntries $WorldPath $base.Root $set $old
    $name
}

function Get-InstalledChapterIds([string]$WorldPath) {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($WorldPath)
    try {
        $index = Get-ZipIndex $zip
        $e = Get-ZipEntry $index 'chapters.json'
        if (-not $e) { return @() }
        @(@((Read-ZipText $e | ConvertFrom-Json).chapters) | Where-Object { $_ } | ForEach-Object { "$_" })
    }
    catch { @() }
    finally { $zip.Dispose() }
}

function Uninstall-Expansion([string]$WorldPath, [string]$Id) {
    $base = Get-ZipDefinition $WorldPath
    $remove = @($base.Names | Where-Object { $_.StartsWith("$($base.Root)chapters/$Id/") } | ForEach-Object { $_.Substring($base.Root.Length) })
    $list = @(Get-InstalledChapterIds $WorldPath | Where-Object { $_ -ne $Id })
    $set = [ordered]@{ 'chapters.json' = (New-Object System.Text.UTF8Encoding $false).GetBytes((@{ chapters = $list } | ConvertTo-Json -Depth 4)) }
    Write-ZipEntries $WorldPath $base.Root $set $remove
}

function Show-Expansions([string]$Note = '') {
    $world = $script:World
    $ids = @($world.Id) + @($world.Chapters | ForEach-Object { $_.Id })
    $installed = @($world.Chapters | Where-Object { $_.Index -gt 0 })
    $imported = @(Get-InstalledChapterIds $world.Path)
    $available = @(Get-ExpansionFiles | Where-Object { $ids -contains $_.ExpansionOf })
    $lines = @()
    $buttons = @()
    foreach ($c in $installed) {
        $lines += "Chapter $($c.Index + 1): $($c.Name) ($($c.Levels.Count) levels)"
        if ($imported -contains $c.Id) { $buttons += @{ Text = "Remove $($c.Name)"; Action = [scriptblock]::Create("Invoke-ExpansionChange remove '$($c.Id)'") } }
    }
    foreach ($x in $available) {
        $has = $installed | Where-Object { $_.Id -eq $x.Id }
        $buttons += @{ Text = "$(if ($has) { 'Update' } else { 'Add' }) $($x.Name)"; Action = [scriptblock]::Create("Invoke-ExpansionChange add '$($x.Path -replace "'", "''")'") }
    }
    $buttons += @{ Text = 'Close'; Action = { Hide-Overlay; Show-Hub } }
    $text = if ($lines.Count) { "Added:`n" + ($lines -join "`n") } else { 'No expansions added yet.' }
    $text += "`n`n" + $(if ($available.Count) { "Expansion zips for this world in your worlds folder: $(@($available | ForEach-Object { $_.Name }) -join ', ')." } else { 'Put an expansion .zip for this world in your worlds folder to add it here.' })
    $text += "`nAdding one copies it into this world, so your saves, coins, keys and power-ups carry into its levels."
    if ($Note) { $text = "$Note`n`n$text" }
    Show-Overlay 'EXPANSIONS' $text $buttons
}

function Invoke-ExpansionChange([string]$What, [string]$Arg) {
    $world = $script:World
    [void](Save-WorldData)
    try {
        if ($What -eq 'add') { $name = Install-Expansion $world.Path $Arg; $note = "Added $name." }
        else { Uninstall-Expansion $world.Path $Arg; $note = 'Removed.' }
    }
    catch { Show-Expansions "That didn't work: $($_.Exception.Message)"; return }
    Hide-Overlay
    $script:AfterLoadNote = $note
    Start-WorldLoad (Get-WorldSummary $world.Path)
}

# ---------------------------------------------------------------------------
# Easter egg: Block Drop. Defeating an enemy has a small chance of popping out a tetromino.
# Find all seven and a secret two-minute falling-block game appears in the world menu's Games.
# Built into the engine, so it's in every world (worlds can change the odds with "tetrominoChance").
# ---------------------------------------------------------------------------
$TetroShapes = [ordered]@{
    I = @{ Size = 4; Color = '#29B6F6'; Cells = @(@(0, 1), @(1, 1), @(2, 1), @(3, 1)) }
    O = @{ Size = 2; Color = '#FFEE58'; Cells = @(@(0, 0), @(1, 0), @(0, 1), @(1, 1)) }
    T = @{ Size = 3; Color = '#AB47BC'; Cells = @(@(1, 0), @(0, 1), @(1, 1), @(2, 1)) }
    S = @{ Size = 3; Color = '#66BB6A'; Cells = @(@(1, 0), @(2, 0), @(0, 1), @(1, 1)) }
    Z = @{ Size = 3; Color = '#EF5350'; Cells = @(@(0, 0), @(1, 0), @(1, 1), @(2, 1)) }
    J = @{ Size = 3; Color = '#3F51B5'; Cells = @(@(0, 0), @(0, 1), @(1, 1), @(2, 1)) }
    L = @{ Size = 3; Color = '#FF9800'; Cells = @(@(2, 0), @(0, 1), @(1, 1), @(2, 1)) }
}
$TetroNames = @($TetroShapes.Keys)
$BlockCols = 10; $BlockRows = 20; $BlockCell = 22
$BlockGameSeconds = 120

# The cells of a piece turned clockwise $Rot times, inside its box
function Get-TetroCells([string]$Shape, [int]$Rot) {
    $def = $TetroShapes[$Shape]
    $cells = $def.Cells
    for ($r = 0; $r -lt ($Rot % 4); $r++) {
        $cells = @(foreach ($c in $cells) { , @(($def.Size - 1 - $c[1]), $c[0]) })
    }
    , $cells
}

function Get-TetroBitmap([string]$Shape) {
    if (-not $script:TetroBitmaps) { $script:TetroBitmaps = @{} }
    if ($script:TetroBitmaps.ContainsKey($Shape)) { return $script:TetroBitmaps[$Shape] }
    $bmp = $null
    try {
        $s = 7
        $v = New-Object System.Windows.Media.DrawingVisual
        $dc = $v.RenderOpen()
        foreach ($c in $TetroShapes[$Shape].Cells) {
            $dc.DrawRectangle((ConvertTo-Brush $TetroShapes[$Shape].Color), (New-Pen '#FFFFFF' 1), (New-Rect ($c[0] * $s + 1) ($c[1] * $s + 1) $s $s))
        }
        $dc.Close()
        $bmp = Convert-VisualToBitmap $v 30 16
    }
    catch { }
    $script:TetroBitmaps[$Shape] = $bmp
    $bmp
}

function Get-TetroCollection($Slot) {
    if (-not $Slot) { return @() }
    if (-not $Slot.tetrominoes) { $Slot.tetrominoes = New-Object System.Collections.ArrayList }
    , $Slot.tetrominoes
}

# Called when an enemy is defeated: once in a while a tetromino pops out (1 in 500, bosses 1 in 50)
function Invoke-TetrominoChance($En) {
    $R = $script:Run
    $world = $script:World
    $chance = if ($En.Def.Boss) { $world.TetroBoss } else { $world.TetroEnemy }
    if ($R.MiniGame -or $chance -le 0 -or $En.Y -gt $R.HeightPx) { return }
    $have = Get-TetroCollection $R.Slot
    $missing = @($TetroNames | Where-Object { -not $have.Contains($_) })
    foreach ($it in $R.A.Items) { if ($it.Def.Type -eq 'tetromino' -and -not $it.Taken) { return } }   # one at a time
    if (-not $missing.Count) { return }
    if ((Get-Random -Minimum 0.0 -Maximum 1.0) -ge $chance) { return }
    $shape = $missing | Get-Random
    $def = @{ Type = 'tetromino'; Name = "$shape tetromino"; Shape = $shape; Key = $null; Image = $null; Color = $TetroShapes[$shape].Color }
    $cx = $En.X + $En.W / 2
    $item = New-ItemRuntime $def "tetro|$shape|$([int]($R.Time * 1000))" $cx ($En.Y + $En.H - $R.T)
    $bmp = Get-TetroBitmap $shape
    if ($bmp) { Remove-Sprite $item.Sprite; $item.Sprite = New-Sprite $bmp 30 16 $def.Color; $item.W = 30; $item.H = 16; $item.X = $cx - 15; $item.BaseY = $item.Y }
    Add-ItemNow $item
    Show-Toast 'Something strange popped out...'
}

function Add-Tetromino([string]$Shape) {
    $R = $script:Run
    $have = Get-TetroCollection $R.Slot
    if (-not $have.Contains($Shape)) { [void]$have.Add($Shape) }
    Add-Record 'tetrominoes'
    if ($have.Count -ge $TetroNames.Count) { Show-Toast 'All 7 tetrominoes! A secret game is waiting in the world menu (Games).' }
    else { Show-Toast "A $Shape tetromino! ($($have.Count)/$($TetroNames.Count))" }
}

# ---- The game itself ----
$BlockTimer = New-Object System.Windows.Threading.DispatcherTimer
$BlockTimer.Interval = [TimeSpan]::FromMilliseconds(16)
$BlockTimer.Add_Tick({ Invoke-Safe { Update-BlockGame } })

function New-BlockState {
    $g = @{
        Grid = New-Object 'int[,]' $BlockCols, $BlockRows
        Bag = New-Object System.Collections.ArrayList
        Piece = $null; Next = $null
        Score = 0; Lines = 0; Coins = 0; Time = [double]$BlockGameSeconds; Fall = 0.0
        Over = $false; Reason = ''; Last = 0.0; Repeat = @{}
    }
    $g.Next = Get-NextTetro $g
    $g
}

# Random order, but every shape once per round of seven (no long droughts)
function Get-NextTetro($G) {
    if ($G.Bag.Count -eq 0) { foreach ($s in ($TetroNames | Get-Random -Count $TetroNames.Count)) { [void]$G.Bag.Add($s) } }
    $s = $G.Bag[0]; $G.Bag.RemoveAt(0); $s
}

function Test-TetroFits($G, [string]$Shape, [int]$Rot, [int]$X, [int]$Y) {
    foreach ($c in (Get-TetroCells $Shape $Rot)) {
        $cx = $X + $c[0]; $cy = $Y + $c[1]
        if ($cx -lt 0 -or $cx -ge $BlockCols -or $cy -ge $BlockRows) { return $false }
        if ($cy -ge 0 -and $G.Grid[$cx, $cy] -ne 0) { return $false }
    }
    $true
}

function New-BlockPiece($G) {
    $shape = $G.Next
    $G.Next = Get-NextTetro $G
    $G.Piece = @{ Shape = $shape; Rot = 0; X = $(if ($shape -eq 'O') { 4 } else { 3 }); Y = $(if ($shape -eq 'I') { -1 } else { 0 }) }
    if (-not (Test-TetroFits $G $shape 0 $G.Piece.X $G.Piece.Y)) { $G.Over = $true; $G.Reason = 'The blocks reached the top!' }
}

function Move-BlockPiece($G, [int]$DX, [int]$DY) {
    $p = $G.Piece
    if ($G.Over -or -not $p) { return $false }
    if (Test-TetroFits $G $p.Shape $p.Rot ($p.X + $DX) ($p.Y + $DY)) { $p.X += $DX; $p.Y += $DY; return $true }
    $false
}

# Turn clockwise; if it doesn't fit, try nudging it sideways (or up, for the long piece)
function Invoke-BlockRotate($G) {
    $p = $G.Piece
    if ($G.Over -or -not $p) { return }
    $rot = ($p.Rot + 1) % 4
    foreach ($k in @(@(0, 0), @(-1, 0), @(1, 0), @(-2, 0), @(2, 0), @(0, -1))) {
        if (Test-TetroFits $G $p.Shape $rot ($p.X + $k[0]) ($p.Y + $k[1])) { $p.Rot = $rot; $p.X += $k[0]; $p.Y += $k[1]; return }
    }
}

function Invoke-BlockLock($G) {
    $p = $G.Piece
    $color = $TetroNames.IndexOf($p.Shape) + 1
    foreach ($c in (Get-TetroCells $p.Shape $p.Rot)) {
        $cx = $p.X + $c[0]; $cy = $p.Y + $c[1]
        if ($cy -lt 0) { $G.Over = $true; $G.Reason = 'The blocks reached the top!'; continue }
        $G.Grid[$cx, $cy] = $color
    }
    # Clear full rows
    $cleared = 0
    for ($y = $BlockRows - 1; $y -ge 0; $y--) {
        $full = $true
        for ($x = 0; $x -lt $BlockCols; $x++) { if ($G.Grid[$x, $y] -eq 0) { $full = $false; break } }
        if (-not $full) { continue }
        $cleared++
        for ($yy = $y; $yy -gt 0; $yy--) { for ($x = 0; $x -lt $BlockCols; $x++) { $G.Grid[$x, $yy] = $G.Grid[$x, ($yy - 1)] } }
        for ($x = 0; $x -lt $BlockCols; $x++) { $G.Grid[$x, 0] = 0 }
        $y++          # check the same row again (it now holds the row above)
    }
    if ($cleared) {
        $G.Lines += $cleared
        $G.Score += @(0, 100, 300, 500, 800)[$cleared]
        $G.Coins += @(0, 1, 3, 5, 8)[$cleared]
    }
    $G.Piece = $null
    if (-not $G.Over) { New-BlockPiece $G }
    $cleared
}

function Invoke-BlockHardDrop($G) {
    if ($G.Over -or -not $G.Piece) { return }
    while (Move-BlockPiece $G 0 1) { $G.Score += 2 }
    [void](Invoke-BlockLock $G)
    $G.Fall = 0.0
}

# Gravity: one row every 0.8 s, getting quicker every 5 lines
function Step-BlockGame($G, [double]$dt) {
    if ($G.Over) { return }
    $G.Time -= $dt
    if ($G.Time -le 0) { $G.Time = 0; $G.Over = $true; $G.Reason = "Time's up!"; return }
    $interval = [math]::Max(0.08, 0.8 - [math]::Floor($G.Lines / 5) * 0.08)
    $G.Fall += $dt
    while ($G.Fall -ge $interval -and -not $G.Over) {
        $G.Fall -= $interval
        if (-not (Move-BlockPiece $G 0 1)) { [void](Invoke-BlockLock $G) }
    }
}

function Start-BlockGame {
    $slot = Get-CurrentSlot
    $have = Get-TetroCollection $slot
    if ($have.Count -lt $TetroNames.Count) { return }
    $have.Clear()                                     # the pieces are used up: collect them again for another game
    Add-Record 'blockGames' -Always
    [void](Save-WorldData)
    Hide-Overlay
    $g = New-BlockState
    New-BlockPiece $g
    $g.Last = $script:Clock.Elapsed.TotalSeconds
    $script:Blocks = $g
    $script:Held.Clear()
    Initialize-BlockCanvas
    Show-Screen 'BlockScreen'
    Update-BlockView
    $BlockTimer.Start()
}

function Update-BlockGame {
    $g = $script:Blocks
    if (-not $g) { $BlockTimer.Stop(); return }
    Update-Pad
    $now = $script:Clock.Elapsed.TotalSeconds
    $dt = [math]::Min(0.05, $now - $g.Last); $g.Last = $now
    # Holding left, right or down repeats the move
    foreach ($act in 'Left', 'Right', 'Down') {
        $held = $false
        foreach ($k in $ActionKeys[$act]) { if ($script:Held.Contains($k)) { $held = $true } }
        if (-not $held) { $g.Repeat[$act] = $null; continue }
        if ($null -eq $g.Repeat[$act]) { $g.Repeat[$act] = 0.17; continue }
        $g.Repeat[$act] -= $dt
        if ($g.Repeat[$act] -le 0) {
            $g.Repeat[$act] = 0.05
            switch ($act) { 'Left' { [void](Move-BlockPiece $g -1 0) } 'Right' { [void](Move-BlockPiece $g 1 0) } 'Down' { if (Move-BlockPiece $g 0 1) { $g.Score++; $g.Fall = 0.0 } } }
        }
    }
    Step-BlockGame $g $dt
    Update-BlockView
    if ($g.Over) { Complete-BlockGame }
}

function Invoke-BlockKey([string]$Key) {
    $g = $script:Blocks
    if (-not $script:Held.Add($Key)) { return $true }          # ignore keyboard auto-repeat
    if ($Key -in 'Escape', 'PadStart') { $g.Over = $true; $g.Reason = 'You quit.'; Complete-BlockGame; return $true }
    if ($ActionKeys.Left -contains $Key)       { [void](Move-BlockPiece $g -1 0) }
    elseif ($ActionKeys.Right -contains $Key)  { [void](Move-BlockPiece $g 1 0) }
    elseif ($Key -in 'Space', 'PadB')          { Invoke-BlockHardDrop $g }
    elseif ($ActionKeys.Down -contains $Key)   { if (Move-BlockPiece $g 0 1) { $g.Score++; $g.Fall = 0.0 } }
    elseif ($Key -in 'Up', 'W', 'X', 'Z', 'PadUp', 'PadA', 'PadX') { Invoke-BlockRotate $g }
    if ($g.Over) { Complete-BlockGame }
    $true
}

function Complete-BlockGame {
    $g = $script:Blocks
    if (-not $g) { return }
    $BlockTimer.Stop()
    $script:Blocks = $null
    $won = [math]::Min($g.Coins, 40)
    $slot = Get-CurrentSlot
    $slot.coins += $won
    Add-Record 'minigameCoins' '' $won -Always
    [void](Save-WorldData)
    Show-Hub
    Show-Overlay 'BLOCK DROP' "$($g.Reason)`nLines: $($g.Lines)    Score: $($g.Score)`nYou won $won coin$(if ($won -ne 1) { 's' })!`n`nFind all seven tetrominoes again to play another round." @(
        @{ Text = 'Back to world menu'; Action = { Hide-Overlay; Show-Hub } }
    )
}

# ---- Drawing ----
function Initialize-BlockCanvas {
    if ($script:BlockRects) { return }
    $script:BlockRects = New-Object 'object[,]' $BlockCols, $BlockRows
    $script:BlockShown = New-Object 'string[,]' $BlockCols, $BlockRows
    for ($y = 0; $y -lt $BlockRows; $y++) {
        for ($x = 0; $x -lt $BlockCols; $x++) {
            $r = New-Object System.Windows.Shapes.Rectangle
            $r.Width = $BlockCell - 2; $r.Height = $BlockCell - 2; $r.RadiusX = 3; $r.RadiusY = 3
            [System.Windows.Controls.Canvas]::SetLeft($r, $x * $BlockCell + 1)
            [System.Windows.Controls.Canvas]::SetTop($r, $y * $BlockCell + 1)
            [void]$BlockCanvas.Children.Add($r)
            $script:BlockRects[$x, $y] = $r
        }
    }
    $script:NextRects = @(for ($i = 0; $i -lt 16; $i++) {
        $r = New-Object System.Windows.Shapes.Rectangle
        $r.Width = 20; $r.Height = 20; $r.RadiusX = 3; $r.RadiusY = 3
        [System.Windows.Controls.Canvas]::SetLeft($r, ($i % 4) * 22); [System.Windows.Controls.Canvas]::SetTop($r, [math]::Floor($i / 4) * 22)
        [void]$BlockNext.Children.Add($r)
        $r
    })
}

function Update-BlockView {
    $g = $script:Blocks
    if (-not $g -or -not $script:BlockRects) { return }
    # What each cell should show: settled blocks, the falling piece, and its landing shadow
    $view = New-Object 'string[,]' $BlockCols, $BlockRows
    for ($y = 0; $y -lt $BlockRows; $y++) { for ($x = 0; $x -lt $BlockCols; $x++) {
        $v = $g.Grid[$x, $y]
        $view[$x, $y] = if ($v -gt 0) { $TetroShapes[$TetroNames[$v - 1]].Color } else { '#1A1E3A' }
    } }
    $p = $g.Piece
    if ($p) {
        $gy = $p.Y
        while (Test-TetroFits $g $p.Shape $p.Rot $p.X ($gy + 1)) { $gy++ }
        foreach ($c in (Get-TetroCells $p.Shape $p.Rot)) {
            $cx = $p.X + $c[0]; $cy = $gy + $c[1]
            if ($cy -ge 0 -and $view[$cx, $cy] -eq '#1A1E3A') { $view[$cx, $cy] = '#3A4170' }
        }
        foreach ($c in (Get-TetroCells $p.Shape $p.Rot)) {
            $cx = $p.X + $c[0]; $cy = $p.Y + $c[1]
            if ($cy -ge 0) { $view[$cx, $cy] = $TetroShapes[$p.Shape].Color }
        }
    }
    for ($y = 0; $y -lt $BlockRows; $y++) { for ($x = 0; $x -lt $BlockCols; $x++) {
        if ($script:BlockShown[$x, $y] -ne $view[$x, $y]) { $script:BlockRects[$x, $y].Fill = ConvertTo-Brush $view[$x, $y]; $script:BlockShown[$x, $y] = $view[$x, $y] }
    } }
    $next = $TetroShapes[$g.Next]
    for ($i = 0; $i -lt 16; $i++) { $script:NextRects[$i].Fill = ConvertTo-Brush '#00000000' }
    foreach ($c in $next.Cells) { $script:NextRects[$c[1] * 4 + $c[0]].Fill = ConvertTo-Brush $next.Color }
    $BlockInfo.Text = "Time   $([math]::Ceiling($g.Time))s`nLines  $($g.Lines)`nScore  $($g.Score)`nCoins  $([math]::Min($g.Coins, 40))"
}

# ---------------------------------------------------------------------------
# Throwables: blocks, pots, rocks... Fire picks one up, Fire again throws it (hold Up to throw it upward).
# They come from the map ("throwables" section) or from enemy shots with "leaves": "throwable".
# ---------------------------------------------------------------------------
function New-Throwable($Def, [double]$CX, [double]$FeetY, [double]$Life) {
    $img = Get-WorldImage $Def.Image
    $w = if ($img) { $img.PixelWidth } else { $Def.Width }
    $h = if ($img) { $img.PixelHeight } else { $Def.Height }
    $t = @{
        Def = $Def; X = $CX - $Def.Width / 2; Y = $FeetY - $Def.Height; W = $Def.Width; H = $Def.Height
        VX = 0.0; VY = 0.0; State = 'ground'; Life = $Life; OnGround = $false; HitX = $false; HitTop = $false; GroundSolid = $null
        Hit = New-Object System.Collections.ArrayList; Gone = $false
    }
    $t.Sprite = New-Sprite $img $w $h (Get-OrDefault $Def.Color '#8D6E63')
    $t
}

function Add-ThrowableNow($T) {
    $R = $script:Run
    [void]$R.A.Throwables.Add($T)
    Add-Sprite $T.Sprite
    Set-SpritePosition $T
}

function Remove-Throwable($T) {
    $T.Gone = $true
    Remove-Sprite $T.Sprite
    $R = $script:Run
    if ([object]::ReferenceEquals($R.Carrying, $T)) { $R.Carrying = $null }
}

# Fire while touching a throwable picks it up; Fire while carrying throws it
function Invoke-GrabOrThrow([bool]$Up) {
    $R = $script:Run; $pl = $R.Player
    if ($R.Carrying) {
        $t = $R.Carrying
        $R.Carrying = $null
        $t.State = 'flying'
        $t.X = $pl.X + $pl.W / 2 - $t.W / 2; $t.Y = $pl.Y - $t.H
        if ($Up) { $t.VX = $pl.VX * 0.4; $t.VY = -760.0 }
        else { $t.VX = $pl.Facing * 430 + $pl.VX * 0.3; $t.VY = -200.0 }
        $t.Hit.Clear()
        return $true
    }
    foreach ($t in $R.A.Throwables) {
        if ($t.Gone -or $t.State -ne 'ground') { continue }
        if (($pl.X - 8 -lt $t.X + $t.W) -and ($pl.X + $pl.W + 8 -gt $t.X) -and ($pl.Y -lt $t.Y + $t.H) -and ($pl.Y + $pl.H + 4 -gt $t.Y)) {
            $t.State = 'carried'
            $R.Carrying = $t
            return $true
        }
    }
    $false
}

# Drops whatever the player is carrying (when hit, or entering a pipe)
function Invoke-DropCarried {
    $R = $script:Run
    if (-not $R.Carrying) { return }
    $t = $R.Carrying; $R.Carrying = $null
    $t.State = 'ground'; $t.VX = 0.0; $t.VY = -150.0
}

function Update-Throwables([double]$dt) {
    $R = $script:Run; $pl = $R.Player; $ph = $R.Phys
    foreach ($t in @($R.A.Throwables)) {
        if ($t.Gone) { continue }
        switch ($t.State) {
            'carried' {
                $t.X = $pl.X + $pl.W / 2 - $t.W / 2; $t.Y = $pl.Y - $t.H - 2
            }
            'ground' {
                if ($t.Life -gt 0) {
                    $t.Life -= $dt
                    if ($t.Life -le 0) { Remove-Throwable $t; continue }
                    $t.Sprite.Opacity = if ($t.Life -lt 3 -and ([int]($t.Life * 8) % 2) -eq 1) { 0.4 } else { 1.0 }
                }
                if (-not $t.OnGround -or $t.VY -ne 0) {
                    $t.VY = [math]::Min($ph.maxFall, $t.VY + $ph.gravity * $dt)
                    Move-Entity $t 0 ($t.VY * $dt)
                    if ($t.OnGround) { $t.VY = 0.0 }
                    if ($t.Y -gt $R.HeightPx + 64) { Remove-Throwable $t; continue }
                }
            }
            'flying' {
                $t.VY = [math]::Min($ph.maxFall, $t.VY + $ph.gravity * $dt)
                Move-Entity $t ($t.VX * $dt) ($t.VY * $dt)
                if ($t.Y -gt $R.HeightPx + 64) { Remove-Throwable $t; continue }
                # Into an enemy's thought bubble: what it was thinking about lands on its head
                foreach ($en in $R.A.Enemies) {
                    if ($en.Dead -or $en.Mode -ne 'think' -or -not $en.ThinkRect) { continue }
                    $b = $en.ThinkRect
                    if (($t.X -lt $b.X + $b.W) -and ($t.X + $t.W -gt $b.X) -and ($t.Y -lt $b.Y + $b.H) -and ($t.Y + $t.H -gt $b.Y)) {
                        Invoke-ThoughtDrop $en
                        $t.VX = -$t.VX * 0.3
                    }
                }
                # Into enemies
                foreach ($en in $R.A.Enemies) {
                    if ($en.Dead -or -not $en.Active -or $t.Hit.Contains($en)) { continue }
                    if (Test-Overlap $t $en) {
                        [void]$t.Hit.Add($en)
                        # It bounces off things it affects; anything else it just sails past
                        if (Invoke-EnemyHit $en 'thrown') { $t.VX = -$t.VX * 0.25; if ($t.VY -lt 0) { $t.VY = 0.0 } }
                    }
                }
                if ($t.HitX) { $t.VX = -$t.VX * 0.25 }
                if ($t.OnGround) { $t.State = 'ground'; $t.VX = 0.0; $t.VY = 0.0 }
            }
        }
        Set-SpritePosition $t
    }
}

# ---- Thinking: an enemy pictures a shot in a thought bubble before throwing it ----
function Show-ThoughtBubble($En, $Image) {
    $R = $script:Run
    $w = 54; $h = 44
    $En.ThinkRect = @{ X = $En.X + $En.W / 2 - $w / 2 + 18; Y = $En.Y - $h - 14; W = $w; H = $h }
    if (-not $En.Thought) {
        try {
            $grid = New-Object System.Windows.Controls.Grid
            $cloud = New-Object System.Windows.Shapes.Ellipse
            $cloud.Fill = ConvertTo-Brush '#F2FFFFFF'; $cloud.Stroke = ConvertTo-Brush '#9FA8DA'; $cloud.StrokeThickness = 2
            [void]$grid.Children.Add($cloud)
            $img = New-Object System.Windows.Controls.Image
            $img.Width = 30; $img.Height = 30
            [void]$grid.Children.Add($img)
            $grid.Width = $w; $grid.Height = $h; $grid.IsHitTestVisible = $false
            $dots = New-Object System.Windows.Shapes.Ellipse
            $dots.Width = 10; $dots.Height = 8; $dots.Fill = ConvertTo-Brush '#F2FFFFFF'; $dots.Stroke = ConvertTo-Brush '#9FA8DA'
            $En.ThoughtDot = $dots
            Add-Sprite $dots
            Add-Sprite $grid
            $En.Thought = $grid
            $En.ThoughtImage = $img
        }
        catch { $En.Thought = $null }
    }
    if ($En.Thought) {
        $En.ThoughtImage.Source = Get-WorldImage $Image
        Set-ElementAt $En.Thought $En.ThinkRect.X $En.ThinkRect.Y
        Set-ElementAt $En.ThoughtDot ($En.ThinkRect.X + 2) ($En.ThinkRect.Y + $h + 2)
    }
}

function Hide-ThoughtBubble($En) {
    if ($En.Thought) { Remove-Sprite $En.Thought; Remove-Sprite $En.ThoughtDot; $En.Thought = $null; $En.ThoughtDot = $null }
    $En.ThinkRect = $null
}

# Something hit the thought bubble: the piece it was picturing falls on its own head
function Invoke-ThoughtDrop($En) {
    $R = $script:Run
    if ($En.Mode -ne 'think') { return }
    $b = $En.ThinkRect
    $a = $En.Def.Attacks[$En.ModeIndex]
    $s = $a.Size
    $shot = @{ X = $b.X + $b.W / 2 - $s / 2; Y = $b.Y + $b.H / 2 - $s / 2; W = $s; H = $s; VX = 0.0; VY = 260.0; Life = 3.0; Def = $a
               Spin = 400; HitsOwner = $En }
    $shot.Sprite = New-Sprite (Get-WorldImage $En.ThinkImage) $s $s $a.Color
    Add-Sprite $shot.Sprite
    [void]$R.EnemyShots.Add($shot)
    $En.Mode = ''
    $En.AttackTimers[$En.ModeIndex] = $a.Interval
    Hide-ThoughtBubble $En
    Show-Toast 'Bonk!'
}

# ---------------------------------------------------------------------------
# Weather and level types (set per world, level or area)
#   weather:   day | night | rain | snow
#   levelType: surface | underground (cave, tunnel, tomb) | clouds
# ---------------------------------------------------------------------------
$WeatherKinds = 'day', 'night', 'rain', 'snow'
$LevelTypes = @{ surface = 'surface'; underground = 'underground'; cave = 'underground'; tunnel = 'underground'; tomb = 'underground'; clouds = 'clouds'; cloud = 'clouds'; sky = 'clouds' }

function Read-Weather($Value, $Fallback, [string]$Label, $Warnings) {
    if ($null -eq $Value -or "$Value" -eq '') { return $Fallback }
    $w = "$Value".ToLower()
    if ($w -in $WeatherKinds) { return $w }
    $Warnings.Add("$Label weather '$Value' is unknown. Use day, night, rain or snow."); $Fallback
}

function Read-LevelType($Value, $Fallback, [string]$Label, $Warnings) {
    if ($null -eq $Value -or "$Value" -eq '') { return $Fallback }
    $t = "$Value".ToLower()
    if ($LevelTypes.ContainsKey($t)) { return $LevelTypes[$t] }
    $Warnings.Add("$Label levelType '$Value' is unknown. Use surface, underground (cave, tunnel, tomb) or clouds."); $Fallback
}

# What the sky and ground do for an area: darkness, light around the hero, particles, physics changes
function Get-Atmosphere([string]$Weather, [string]$LevelType) {
    $at = @{ Weather = $Weather; LevelType = $LevelType; Dark = $null; Radius = 0; Lightning = $false; Particles = ''; Tint = $null; Physics = @{}; Sky = $null }
    if ($LevelType -eq 'underground') {
        $at.Weather = 'day'                                   # no weather underground
        $at.Dark = '#E8000000'; $at.Radius = 170              # torchlight
        return $at
    }
    switch ($Weather) {
        'night' { $at.Dark = '#B4060A24'; $at.Radius = 260 }              # moonlight
        'rain'  { $at.Dark = '#F5000000'; $at.Radius = 95; $at.Lightning = $true; $at.Particles = 'rain' }
        'snow'  { $at.Tint = '#3CFFFFFF'; $at.Particles = 'snow'; $at.Physics = @{ groundFriction = 0.12; groundAccel = 0.4 } }
    }
    if ($LevelType -eq 'clouds') {
        $at.Sky = '#BFE6FF'
        $at.Physics['gravity'] = 0.82; $at.Physics['maxFall'] = 0.8
    }
    $at
}

# Level physics changed by the area's atmosphere (multipliers)
function Get-AtmospherePhysics($Base, $At) {
    if (-not $At -or $At.Physics.Count -eq 0) { return $Base }
    $p = Merge-Physics $Base @{}
    foreach ($k in @($At.Physics.Keys)) { $p[$k] = $p[$k] * $At.Physics[$k] }
    $p
}

# Called when an area is entered: sets physics and the overlays
function Enter-Atmosphere($Area) {
    $R = $script:Run
    $at = Get-Atmosphere $Area.Weather $Area.LevelType
    $R.Atmos = $at
    $R.BasePhys = Get-AtmospherePhysics $R.Level.Physics $at
    Update-Physics
    $R.Lightning = @{ Timer = 2.5 + (Get-Random -Minimum 0.0 -Maximum 3.0); Flash = 0.0; Second = $false }
    Show-Atmosphere $at
}

function Update-Weather([double]$dt) {
    $R = $script:Run; $at = $R.Atmos
    if (-not $at) { return }
    if ($at.Lightning) {
        $L = $R.Lightning
        $L.Timer -= $dt
        if ($L.Flash -gt 0) { $L.Flash = [math]::Max(0.0, $L.Flash - $dt) }
        if ($L.Timer -le 0) {
            $L.Flash = 0.9
            if (-not $L.Second -and (Get-Random -Minimum 0 -Maximum 3) -eq 0) { $L.Timer = 0.25; $L.Second = $true }   # a quick double flash
            else { $L.Timer = 3.5 + (Get-Random -Minimum 0.0 -Maximum 4.5); $L.Second = $false }
        }
    }
    Update-AtmosphereVisuals $dt
}

# ---- Drawing (screen-space overlays above the level, below the HUD) ----
function Show-Atmosphere($At) {
    try {
        $WeatherCanvas.Children.Clear()
        $script:WeatherBits = New-Object System.Collections.ArrayList
        $DarkRect.Visibility = 'Collapsed'; $FlashRect.Opacity = 0
        if ($At.Dark) {
            $brush = New-Object System.Windows.Media.RadialGradientBrush
            $brush.MappingMode = 'Absolute'
            $brush.RadiusX = $At.Radius; $brush.RadiusY = $At.Radius
            $dark = [System.Windows.Media.ColorConverter]::ConvertFromString($At.Dark)
            $clear = [System.Windows.Media.Color]::FromArgb(0, $dark.R, $dark.G, $dark.B)
            $brush.GradientStops.Add((New-Object System.Windows.Media.GradientStop $clear, 0.0))
            $brush.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb([byte]($dark.A * 0.45), $dark.R, $dark.G, $dark.B)), 0.55))
            $brush.GradientStops.Add((New-Object System.Windows.Media.GradientStop $dark, 1.0))
            $DarkRect.Fill = $brush
            $DarkRect.Visibility = 'Visible'
            $script:DarkBrush = $brush
        }
        elseif ($At.Tint) { $DarkRect.Fill = ConvertTo-Brush $At.Tint; $DarkRect.Visibility = 'Visible'; $script:DarkBrush = $null; $DarkRect.Opacity = 1 }
        $n = switch ($At.Particles) { 'rain' { 90 } 'snow' { 70 } default { 0 } }
        for ($i = 0; $i -lt $n; $i++) {
            if ($At.Particles -eq 'rain') {
                $el = New-Object System.Windows.Shapes.Line
                $el.X1 = 0; $el.Y1 = 0; $el.X2 = -3; $el.Y2 = 14
                $el.Stroke = ConvertTo-Brush '#99B3D4FF'; $el.StrokeThickness = 1.4
                $p = @{ El = $el; X = (Get-Random -Minimum 0 -Maximum $ViewW); Y = (Get-Random -Minimum 0 -Maximum $ViewH); VX = -60.0; VY = 900.0 + (Get-Random -Minimum 0 -Maximum 300) }
            }
            else {
                $el = New-Object System.Windows.Shapes.Ellipse
                $sz = 2 + (Get-Random -Minimum 0 -Maximum 4)
                $el.Width = $sz; $el.Height = $sz; $el.Fill = ConvertTo-Brush '#E6FFFFFF'
                $p = @{ El = $el; X = (Get-Random -Minimum 0 -Maximum $ViewW); Y = (Get-Random -Minimum 0 -Maximum $ViewH); VX = 0.0; VY = 40.0 + $sz * 12; Phase = (Get-Random -Minimum 0.0 -Maximum 6.28) }
            }
            [void]$WeatherCanvas.Children.Add($el)
            [void]$script:WeatherBits.Add($p)
        }
    }
    catch { }
}

function Update-AtmosphereVisuals([double]$dt) {
    $R = $script:Run; $at = $R.Atmos
    try {
        if ($script:DarkBrush) {
            $pl = $R.Player
            $c = New-Point ($pl.X + $pl.W / 2 - $R.CamX) ($pl.Y + $pl.H / 2 - $R.CamY)
            $script:DarkBrush.Center = $c; $script:DarkBrush.GradientOrigin = $c
            $f = if ($at.Lightning) { $R.Lightning.Flash } else { 0 }
            $DarkRect.Opacity = if ($f -gt 0) { [math]::Max(0.0, 1 - $f * 1.4) } else { 1.0 }     # lightning lights everything up
            $FlashRect.Opacity = if ($f -gt 0.6) { ($f - 0.6) * 1.6 } else { 0 }
        }
        foreach ($p in $script:WeatherBits) {
            if ($at.Particles -eq 'snow') { $p.Phase += $dt; $p.X += [math]::Sin($p.Phase * 1.3) * 25 * $dt }
            $p.X += $p.VX * $dt; $p.Y += $p.VY * $dt
            if ($p.Y -gt $ViewH) { $p.Y -= $ViewH + 20; $p.X = Get-Random -Minimum 0 -Maximum $ViewW }
            if ($p.X -lt -10) { $p.X += $ViewW + 10 } elseif ($p.X -gt $ViewW + 10) { $p.X -= $ViewW + 10 }
            [System.Windows.Controls.Canvas]::SetLeft($p.El, $p.X)
            [System.Windows.Controls.Canvas]::SetTop($p.El, $p.Y)
        }
    }
    catch { }
}

function Clear-Atmosphere {
    try { $WeatherCanvas.Children.Clear(); $DarkRect.Visibility = 'Collapsed'; $FlashRect.Opacity = 0; $script:DarkBrush = $null; $script:WeatherBits = $null } catch { }
}

# ---------------------------------------------------------------------------
# Building areas
# ---------------------------------------------------------------------------
function Get-WorldImage([string]$Path) {
    if ($Path) { $script:World.Images[$Path] }
}

function Convert-VisualToBitmap($Visual, [int]$Width, [int]$Height) {
    $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($Width, $Height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($Visual)
    $bmp.Freeze()
    $bmp
}

# Collision and behaviour grids for one area (no drawing, so it can be tested on its own)
function New-AreaGrids($Area) {
    $world = $script:World
    $mw = $Area.W; $mh = $Area.H
    $g = @{
        Solid      = New-Object 'bool[,]' $mw, $mh      # blocks the player
        EnemySolid = New-Object 'bool[,]' $mw, $mh      # blocks enemies
        OneWay     = New-Object 'bool[,]' $mw, $mh      # can be stood on, jumped up through
        Climb      = New-Object 'bool[,]' $mw, $mh      # ladders and vines
        Cell       = New-Object 'object[,]' $mw, $mh    # tiles with a special behaviour (bounce, ice, conveyor...)
        Hazard     = New-Object 'byte[,]' $mw, $mh      # 0 safe, 1 hurts, 2 kills
        EnemyHazard = New-Object 'bool[,]' $mw, $mh     # tiles that are deadly to enemies
        Spikes     = New-Object 'byte[,]' $mw, $mh      # SpikeBits, plus 16 = kills instantly
        Liquid     = New-Object 'bool[,]' $mw, $mh
        Lava       = New-Object 'bool[,]' $mw, $mh
        Sand       = New-Object 'bool[,]' $mw, $mh
        W = $mw; H = $mh; WidthPx = $mw * $world.TileSize; HeightPx = $mh * $world.TileSize
    }
    for ($y = 0; $y -lt $mh; $y++) {
        $row = $Area.Rows[$y]
        for ($x = 0; $x -lt $mw; $x++) {
            $sym = $null
            if (-not $world.Symbols.TryGetValue($row[$x], [ref]$sym) -or $sym.Kind -ne 'tile') { continue }
            $t = $sym.Def
            if ($t.IsBlock) { continue }             # blocks are separate objects so they can change
            if ($t.Solid) {
                if ($t.SolidFor -ne 'enemies') { $g.Solid[$x, $y] = $true }
                if ($t.SolidFor -ne 'player')  { $g.EnemySolid[$x, $y] = $true }
            }
            $g.OneWay[$x, $y] = $t.OneWay
            $g.Climb[$x, $y]  = $t.Climb
            $g.Liquid[$x, $y] = $t.Liquid
            $g.Lava[$x, $y]   = $t.Lava
            $g.Sand[$x, $y]   = $t.Quicksand
            $g.EnemyHazard[$x, $y] = $t.DeadlyToEnemies
            if ($t.Bounce -gt 0 -or $t.Friction -ne 1 -or $t.Conveyor -ne 0 -or $t.SpeedMult -ne 1) { $g.Cell[$x, $y] = $t }
            if ($t.Deadly) { $g.Hazard[$x, $y] = if ($t.InstantKill) { 2 } else { 1 } }
            if ($t.Spikes) { $g.Spikes[$x, $y] = $t.Spikes -bor $(if ($t.SpikeKill) { 16 } else { 0 }) }
        }
    }
    # The top of a ladder or vine can be stood on (Down climbs back down)
    for ($y = 0; $y -lt $mh; $y++) {
        for ($x = 0; $x -lt $mw; $x++) {
            if ($g.Climb[$x, $y] -and ($y -eq 0 -or -not $g.Climb[$x, ($y - 1)]) -and -not $g.Solid[$x, $y]) { $g.OneWay[$x, $y] = $true }
        }
    }
    Complete-LiquidCells $Area $g.Liquid
    Complete-LiquidCells $Area $g.Lava
    Complete-LiquidCells $Area $g.Sand
    $g
}

# Draws one tile into a drawing context (handles rotation and the no-picture colour)
function Write-TileImage($dc, $t, [double]$X, [double]$Y, [double]$Size) {
    $rect = [System.Windows.Rect]::new($X, $Y, $Size, $Size)
    if ($t.Rotate) { $dc.PushTransform([System.Windows.Media.RotateTransform]::new($t.Rotate, $X + $Size / 2, $Y + $Size / 2)) }
    $img = Get-WorldImage $t.Image
    if ($img) { $dc.DrawImage($img, $rect) }
    else { $dc.DrawRectangle((ConvertTo-Brush (Get-OrDefault $t.Color $(if ($t.Liquid) { '#663FA9F5' } elseif ($t.Lava -or $t.Deadly -or $t.Spikes) { '#FF5722' } elseif ($t.Quicksand) { '#F0C2A15A' } elseif ($t.Climb) { '#8D6E63' } else { '#FF00FF' }))), $null, $rect) }
    if ($t.Rotate) { $dc.Pop() }
}

# Collision grids plus two pictures of the area: tiles behind the action and tiles in front (like water)
function Build-AreaMap($Area) {
    $world = $script:World
    $ts = $world.TileSize
    $map = New-AreaGrids $Area
    $back  = New-Object System.Windows.Media.DrawingVisual
    $front = New-Object System.Windows.Media.DrawingVisual
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($back, 'NearestNeighbor')
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($front, 'NearestNeighbor')
    $dcBack = $back.RenderOpen(); $dcFront = $front.RenderOpen()
    $hasFront = $false
    for ($y = 0; $y -lt $Area.H; $y++) {
        $row = $Area.Rows[$y]
        for ($x = 0; $x -lt $Area.W; $x++) {
            $sym = $null
            if (-not $world.Symbols.TryGetValue($row[$x], [ref]$sym) -or $sym.Kind -ne 'tile' -or $sym.Def.IsBlock) { continue }
            $dc = if ($sym.Def.Front) { $hasFront = $true; $dcFront } else { $dcBack }
            Write-TileImage $dc $sym.Def ($x * $ts) ($y * $ts) $ts
        }
    }
    $dcBack.Close(); $dcFront.Close()
    $map.Bitmap      = Convert-VisualToBitmap $back $map.WidthPx $map.HeightPx
    $map.FrontBitmap = if ($hasFront) { Convert-VisualToBitmap $front $map.WidthPx $map.HeightPx } else { $null }
    $map
}

# A block tile's picture as its own small bitmap (blocks are sprites, not part of the area picture)
function Get-TileBitmap($t) {
    if (-not $t) { return $null }
    if ($t.ContainsKey('Bitmap')) { return $t.Bitmap }
    $ts = $script:World.TileSize
    $img = Get-WorldImage $t.Image
    $bmp = $null
    if ($img -and -not $t.Rotate) { $bmp = $img }
    elseif ($img) {
        $v = New-Object System.Windows.Media.DrawingVisual
        $dc = $v.RenderOpen(); Write-TileImage $dc $t 0 0 $ts; $dc.Close()
        $bmp = Convert-VisualToBitmap $v $ts $ts
    }
    $t.Bitmap = $bmp
    $bmp
}

# A coin, key, enemy or other object placed inside water (or lava, or quicksand) should be inside it too,
# not leave a hole. An object's cell counts when the cell above it, or the cells on both sides, do.
function Complete-LiquidCells($Area, $Liquid) {
    $world = $script:World
    for ($y = 0; $y -lt $Area.H; $y++) {
        $row = $Area.Rows[$y]
        for ($x = 0; $x -lt $Area.W; $x++) {
            $c = $row[$x]
            if ($c -ceq [char]'.' -or $c -ceq [char]' ' -or $Liquid[$x, $y]) { continue }
            $sym = $null
            if ($world.Symbols.TryGetValue($c, [ref]$sym) -and $sym.Kind -eq 'tile') { continue }
            $above = $y -gt 0 -and $Liquid[$x, ($y - 1)]
            $sides = $x -gt 0 -and $x -lt $Area.W - 1 -and $Liquid[($x - 1), $y] -and $Liquid[($x + 1), $y]
            if ($above -or $sides) { $Liquid[$x, $y] = $true }
        }
    }
}

function Get-AreaMap($Level, $Area) {
    if ($Level.NoCache) { return (Build-AreaMap $Area) }        # mini-game maps get changed by their twists
    $key = "$($Level.Number)/$($Area.Id)"
    if (-not $script:MapCache.ContainsKey($key)) { $script:MapCache[$key] = Build-AreaMap $Area }
    $script:MapCache[$key]
}

# Every sprite gets a flip (scale) and a spin (rotate) transform, kept in its Tag
function Add-SpriteTransforms($El, [bool]$IsImage) {
    $scale  = New-Object System.Windows.Media.ScaleTransform
    $rotate = New-Object System.Windows.Media.RotateTransform
    $group  = New-Object System.Windows.Media.TransformGroup
    $group.Children.Add($scale)
    $group.Children.Add($rotate)
    $El.RenderTransformOrigin = New-Point 0.5 0.5
    $El.RenderTransform = $group
    $El.Tag = @{ Scale = $scale; Rotate = $rotate; IsImage = $IsImage }
    $El
}

# An image sprite, or a coloured box when there is no image. Not added to the canvas yet.
function New-Sprite($Bitmap, [double]$Width, [double]$Height, [string]$Color) {
    if ($Bitmap) {
        $el = New-Object System.Windows.Controls.Image
        $el.Source = $Bitmap
        $el.Width  = $Bitmap.PixelWidth
        $el.Height = $Bitmap.PixelHeight
        $el.Stretch = 'Fill'
        return (Add-SpriteTransforms $el $true)
    }
    $el = New-Object System.Windows.Shapes.Rectangle
    $el.Width = $Width; $el.Height = $Height
    $el.Fill = ConvertTo-Brush (Get-OrDefault $Color '#E53935')
    $el.RadiusX = [math]::Min(6, $Width / 2); $el.RadiusY = [math]::Min(6, $Height / 2)
    Add-SpriteTransforms $el $false
}

# A box of a fixed size filled with a repeating tile image (platforms, crushers, ice blocks, liquids)
function New-BoxSprite($Bitmap, [double]$Width, [double]$Height, [string]$Color, [double]$Tile, [bool]$Stretch) {
    $el = New-Object System.Windows.Shapes.Rectangle
    $el.Width = $Width; $el.Height = $Height
    if ($Bitmap) {
        $brush = New-Object System.Windows.Media.ImageBrush $Bitmap
        if (-not $Stretch) {
            $brush.TileMode = 'Tile'
            $brush.ViewportUnits = 'Absolute'
            $brush.Viewport = New-Rect 0 0 $Tile ($Tile * $Bitmap.PixelHeight / [math]::Max(1, $Bitmap.PixelWidth))
        }
        $el.Fill = $brush
    }
    else { $el.Fill = ConvertTo-Brush (Get-OrDefault $Color '#8D6E63') }
    Add-SpriteTransforms $el $false
}

function Add-Sprite($Sprite) { if ($Sprite) { [void]$WorldCanvas.Children.Add($Sprite) } }
function Remove-Sprite($Sprite) { if ($Sprite) { $WorldCanvas.Children.Remove($Sprite) } }

function Set-ElementAt($El, [double]$X, [double]$Y) {
    [System.Windows.Controls.Canvas]::SetLeft($El, [math]::Round($X))
    [System.Windows.Controls.Canvas]::SetTop($El, [math]::Round($Y))
}

# Sprites are drawn centred on their hitbox, standing on its bottom edge.
# Squash < 1 shrinks the sprite toward its feet (used for crouching when there is no crouch picture).
function Set-SpritePosition($Ent, [double]$Squash = 1.0) {
    $s = $Ent.Sprite
    [System.Windows.Controls.Canvas]::SetLeft($s, [math]::Round($Ent.X + $Ent.W / 2 - $s.Width / 2))
    [System.Windows.Controls.Canvas]::SetTop($s,  [math]::Round($Ent.Y + $Ent.H - $s.Height / 2 - $Squash * $s.Height / 2))
}

function Set-CheckpointLook($Cp) {
    $world = $script:World
    $el = $Cp.Sprite
    if ($el.Tag.IsImage) {
        $active = Get-WorldImage $world.Checkpoint.ActiveImage
        $normal = Get-WorldImage $world.Checkpoint.Image
        if ($Cp.Active -and $active) { $el.Source = $active; $el.Opacity = 1 }
        elseif ($normal) { $el.Source = $normal; $el.Opacity = if ($Cp.Active -or $active) { 1 } else { 0.6 } }
    }
    else { $el.Fill = ConvertTo-Brush $(if ($Cp.Active) { '#43A047' } else { '#90A4AE' }) }
}

# ---- Animations ----
# If a state has no animation, the next one in this chain is tried (then the plain image)
$AnimFallback = @{
    run = 'idle'; jump = 'idle'; fall = 'jump'; swim = 'jump'; crouch = 'idle'; ride = 'idle'; dead = 'fall'
    move = 'idle'; fly = 'move'; shy = 'idle'; platform = 'idle'
    climb = 'jump'; sleep = 'crouch'; think = 'move'; attack = 'move'; windup = 'idle'; charge = 'move'; stunned = 'idle'; drop = 'idle'
}

function Find-Anim([object[]]$Sets, [string]$State, [switch]$Exact) {
    $s = $State
    for ($guard = 0; $s -and $guard -lt 8; $guard++) {
        foreach ($set in $Sets) { if ($set -and $set.ContainsKey($s)) { return $set[$s] } }
        if ($Exact) { return $null }
        $s = $AnimFallback[$s]
    }
    $null
}

# Picks the right frame for an entity's state and applies any spin
function Update-Animation($Ent, [string]$State, [object[]]$Sets, [double]$dt, [double]$Facing) {
    if ($Ent.AnimState -ne $State) { $Ent.AnimState = $State; $Ent.AnimTime = 0.0 } else { $Ent.AnimTime += $dt }
    $el = $Ent.Sprite
    $tag = $el.Tag
    $bmp = $Ent.BaseBitmap
    $angle = 0.0
    $anim = Find-Anim $Sets $State
    if ($anim) {
        if ($null -eq $anim.Bitmaps) {
            $anim.Bitmaps = @(foreach ($f in $anim.Frames) { $b = Get-WorldImage $f; if ($b) { $b } })
        }
        $frames = $anim.Bitmaps
        if ($frames.Count) { $bmp = $frames[[int][math]::Floor($Ent.AnimTime * $anim.Fps) % $frames.Count] }
        if ($anim.Spin) { $angle = ($Ent.AnimTime * $anim.Spin * $Facing) % 360 }
    }
    if ($tag.IsImage -and $bmp -and -not [object]::ReferenceEquals($el.Source, $bmp)) {
        $el.Source = $bmp
        $el.Width = $bmp.PixelWidth
        $el.Height = $bmp.PixelHeight
    }
    $tag.Rotate.Angle = $angle
}

# The first picture available for something that may only have animation frames
function Get-FirstBitmap([string]$Image, $Anims) {
    $b = Get-WorldImage $Image
    if ($b) { return $b }
    foreach ($state in 'idle', 'move', 'fly', 'swim', 'run') {
        if ($Anims -and $Anims.ContainsKey($state)) {
            foreach ($f in $Anims[$state].Frames) { $b = Get-WorldImage $f; if ($b) { return $b } }
        }
    }
    if ($Anims) { foreach ($a in $Anims.Values) { foreach ($f in $a.Frames) { $b = Get-WorldImage $f; if ($b) { return $b } } } }
    $null
}

# A live enemy from its definition, standing with its feet at FeetY and centred on CX
function New-EnemyRuntime($Def, [double]$CX, [double]$FeetY, [string]$Origin) {
    $en = @{
        X = $CX - $Def.Width / 2; Y = $FeetY - $Def.Height; W = $Def.Width; H = $Def.Height
        VX = 0.0; VY = 0.0; DX = 0.0; DY = 0.0; Dir = -1; Def = $Def; IsEnemy = $true
        Active = $false; Dead = $false; OnGround = $false; HitX = $false; HitTop = $false; Clock = ($CX * 0.011)
        JumpTimer = $Def.JumpInterval * (0.4 + ([int]($CX / 32) % 5) * 0.15); State = 'move'
        Frozen = $false; FreezeTimer = 0.0; IceSprite = $null; AsPlatform = $false
        SolidOn = $false; OneWay = $false; Pushable = $false; GroundSolid = $null
        Health = $Def.Health; HurtTimer = 0.0; StunTimer = 0.0; Kicked = $false; KickGrace = 0.0
        Hunt = $false; Origin = $Origin; Mode = ''; ModeTimer = 0.0; AttackAnim = 0.0; LeapVX = 0.0; HomeY = 0.0
        TalkTimer = 2.0; TalkLeft = 0.0; TalkIndex = 0; Line = ''; Bubble = $null
        AttackTimers = [double[]]@(foreach ($a in $Def.Attacks) { if ($a.Type -eq 'shoot') { 0.6 + ($CX % 97) / 97 } else { 0.25 } })
    }
    $en.SpawnX = $en.X
    $en.BaseBitmap = Get-FirstBitmap $Def.Image $Def.Anims
    $en.Sprite = New-Sprite $en.BaseBitmap $Def.Width $Def.Height (Get-OrDefault $Def.Color '#E53935')
    $en
}

# A live item (placed on the map, dropped by an enemy, or popped out of a block)
function New-ItemRuntime($Def, [string]$Id, [double]$CX, [double]$CY) {
    $img = Get-WorldImage $Def.Image
    $iw = if ($img) { $img.PixelWidth } elseif ($Def.Type -eq 'coin') { 16 } else { 22 }
    $ih = if ($img) { $img.PixelHeight } elseif ($Def.Type -eq 'coin') { 16 } else { 22 }
    $item = @{ Id = $Id; Def = $Def; X = $CX - $iw / 2; Y = $CY - $ih / 2; W = $iw; H = $ih; Taken = $false; Clock = ($CX * 0.02) }
    $item.BaseY = $item.Y
    $color = switch ($Def.Type) { 'coin' { '#FFC83D' } 'key' { '#FF7043' } 'collectible' { '#26C6DA' } default { '#AB47BC' } }
    $item.Sprite = New-Sprite $img $iw $ih (Get-OrDefault $Def.Color $color)
    $item
}

function Get-SymbolDef([string]$Key, [string]$Kind) {
    if (-not $Key -or $Key.Length -ne 1) { return $null }
    $sym = $null
    if ($script:World.Symbols.TryGetValue([char]$Key, [ref]$sym) -and $sym.Kind -eq $Kind) { return $sym.Def }
    $null
}

# Has this one-off thing (key, lock, broken block, survived arena...) already been used up?
function Test-Used([string]$Id) {
    $R = $script:Run
    $R.SlotTaken.Contains($Id) -or $R.RunCommitted.Contains($Id)
}

# Creates the live objects for one area of the current level
function New-AreaRuntime([string]$AreaId) {
    $R = $script:Run
    $world = $script:World
    $lv = $R.Level
    $ts = $world.TileSize
    $area = $lv.Areas[$AreaId]
    $map = Get-AreaMap $lv $area
    $A = @{
        Id = $AreaId; Area = $area; Map = $map
        Solid       = $map.Solid.Clone()       # own copies, because blocks change them
        EnemySolid  = $map.EnemySolid.Clone()
        BlockAt     = New-Object 'object[,]' $map.W, $map.H
        Goals       = New-Object System.Collections.ArrayList
        Checkpoints = New-Object System.Collections.ArrayList
        Warps       = New-Object System.Collections.ArrayList
        Locks       = New-Object System.Collections.ArrayList
        Blocks      = New-Object System.Collections.ArrayList
        Items       = New-Object System.Collections.ArrayList
        Mounts      = New-Object System.Collections.ArrayList
        Enemies     = New-Object System.Collections.ArrayList
        Platforms   = New-Object System.Collections.ArrayList
        Liquids     = New-Object System.Collections.ArrayList
        Spawners    = New-Object System.Collections.ArrayList
        Dispensers  = New-Object System.Collections.ArrayList
        PopSpikes   = New-Object System.Collections.ArrayList
        Throwables  = New-Object System.Collections.ArrayList
        Survival    = $null
    }

    # Rising / falling liquids (all heights in pixels)
    foreach ($lq in $area.Liquids) {
        $x0 = if ($null -ne $lq.From) { $lq.From * $ts } else { 0 }
        $x1 = if ($null -ne $lq.To) { ($lq.To + 1) * $ts } else { $map.WidthPx }
        $low = $lq.Low * $ts; $high = $lq.High * $ts; $level = $lq.Level * $ts
        $mid = ($low + $high) / 2; $amp = ($low - $high) / 2
        $phase = if ($amp -gt 0) { [math]::Acos([math]::Max(-1, [math]::Min(1, ($level - $mid) / $amp))) } else { 0 }
        $rt = @{
            Def = $lq; Kind = $lq.Kind; Mode = $lq.Mode; X0 = $x0; X1 = $x1
            Level = $level; Low = $low; High = $high; Mid = $mid; Amp = $amp; Phase = $phase; Start = $level
            Speed = $lq.Speed * $ts; Time = 0.0; Dir = -1; PauseLeft = 0.0; Body = $null; Surface = $null
            Waiting = ($lq.StartOn -eq 'survival'); Draining = $false
        }
        New-LiquidVisual $rt
        [void]$A.Liquids.Add($rt)
    }

    # Survival arena: starts when you enter (or pass a column), unless already survived this run
    if ($area.Survival) {
        $A.Survival = @{ Def = $area.Survival; State = 'waiting'; Timer = 0.0; SpawnTimer = 0.0; Spawned = 0
                         Waves = @(foreach ($w in $area.Survival.Waves) { @{ Def = $w; Left = $w.Count; Timer = 0.0 } }) }
        if (Test-Used "survived|$AreaId") { $A.Survival.State = 'done' }
    }

    for ($y = 0; $y -lt $area.H; $y++) {
        $row = $area.Rows[$y]
        for ($x = 0; $x -lt $area.W; $x++) {
            $c = $row[$x]
            if ($c -ceq [char]'G') { [void]$A.Goals.Add((New-ExitObject 'G' $x $y (Get-WorldImage $world.Goal.Image) '#FFC83D')) }
            elseif ($c -ceq [char]'C') {
                $img = Get-WorldImage $world.Checkpoint.Image
                $cp = @{ CellX = $x; CellY = $y; X = $x * $ts; Y = $y * $ts; W = $ts; H = $ts }
                $cp.Active = [bool]($R.Checkpoint -and $R.Checkpoint.Area -eq $AreaId -and $R.Checkpoint.X -eq $x -and $R.Checkpoint.Y -eq $y)
                $cp.Sprite = New-Sprite $img 8 ($ts * 2) '#90A4AE'
                Set-CheckpointLook $cp
                [void]$A.Checkpoints.Add($cp)
            }
            elseif ($c -ge [char]'0' -and $c -le [char]'9') {
                $d = "$c"
                $wd = if ($lv.WarpDefs.ContainsKey($d)) { $lv.WarpDefs[$d] } else { @{ Type = 'door'; Lock = $null } }
                $type = $world.WarpTypes[$wd.Type]
                $partner = $null
                $links = $lv.WarpLinks[$d]
                if ($links -and $links.Count -ge 2) {
                    $partner = @($links[0..1] | Where-Object { -not ($_.Area -eq $AreaId -and $_.X -eq $x -and $_.Y -eq $y) })[0]
                }
                $wp = @{ Digit = $d; Enter = $type.Enter; LockId = $wd.Lock; Partner = $partner; CellX = $x; CellY = $y
                         X = $x * $ts; Y = $y * $ts; W = $ts; H = $ts; Armed = $true; Sprite = $null }
                $img = Get-WorldImage $type.Image
                if ($img -or $type.Color) {
                    $wp.Sprite = New-Sprite $img $ts $(if ($type.Enter -eq 'auto') { $ts * 1.5 } else { $ts * 2 }) $type.Color
                }
                [void]$A.Warps.Add($wp)
            }
            else {
                $sym = $null
                if (-not $world.Symbols.TryGetValue($c, [ref]$sym)) { continue }
                $def = $sym.Def
                switch ($sym.Kind) {
                    'exit' { [void]$A.Goals.Add((New-ExitObject "$c" $x $y (Get-WorldImage $def.Image) (Get-OrDefault $def.Color '#AB47BC'))) }
                    'throwable' {
                        [void]$A.Throwables.Add((New-Throwable $def ($x * $ts + $ts / 2) (($y + 1) * $ts) 0))
                    }
                    'spawner' {
                        $spn = @{ X = $x * $ts; Y = $y * $ts; W = $ts; H = $ts; CellX = $x; CellY = $y; Sprite = $null }
                        $img = Get-WorldImage $def.Image
                        if ($img -or $def.Color) { $spn.Sprite = New-Sprite $img $ts $ts $def.Color }
                        if ($def.Dispense) {
                            $spn.Def = $def; $spn.Timer = 1.0; $spn.Next = 0
                            if ($def.Solid) { $A.Solid[$x, $y] = $true; $A.EnemySolid[$x, $y] = $true }
                            [void]$A.Dispensers.Add($spn)
                        }
                        else { [void]$A.Spawners.Add($spn) }
                    }
                    'tile' {
                        if (-not $def.IsBlock) { break }
                        if ($def.Lock) {
                            $id = "lock|$AreaId|$x|$y"
                            if (Test-Used $id) { break }   # already opened
                            $A.Solid[$x, $y] = $true; $A.EnemySolid[$x, $y] = $true
                            $lk = @{ Id = $id; LockId = $def.Lock; CellX = $x; CellY = $y; X = $x * $ts; Y = $y * $ts; W = $ts; H = $ts; Open = $false }
                            $lk.Sprite = New-Sprite (Get-TileBitmap $def) $ts $ts (Get-OrDefault $def.Color '#C62828')
                            $lk.Sprite.Width = $ts; $lk.Sprite.Height = $ts
                            [void]$A.Locks.Add($lk)
                            break
                        }
                        $blk = New-Block $A $def $x $y
                        if ($blk) { [void]$A.Blocks.Add($blk); $A.BlockAt[$x, $y] = $blk }
                    }
                    'enemy' {
                        $en = New-EnemyRuntime $def ($x * $ts + $ts / 2) (($y + 1) * $ts) "$AreaId|$x|$y"
                        [void]$A.Enemies.Add($en)
                    }
                    'item' {
                        $id = "$($def.Type)|$AreaId|$x|$y"
                        if (Test-Used $id) { break }
                        [void]$A.Items.Add((New-ItemRuntime $def $id ($x * $ts + $ts / 2) ($y * $ts + $ts / 2)))
                    }
                    'mount' {
                        $mo = @{
                            X = $x * $ts + ($ts - $def.Width) / 2; Y = ($y + 1) * $ts - $def.Height; W = $def.Width; H = $def.Height
                            VX = 0.0; VY = 0.0; Dir = 1; Def = $def; OnGround = $false; HitX = $false; HitTop = $false; State = 'idle'
                        }
                        $mo.BaseBitmap = Get-FirstBitmap $def.Image $def.Anims
                        $mo.Sprite = New-Sprite $mo.BaseBitmap $def.Width $def.Height (Get-OrDefault $def.Color '#8D5524')
                        [void]$A.Mounts.Add($mo)
                    }
                    'platform' {
                        $w = $def.Width * $ts; $h = $def.Height * $ts
                        $mx = $def.MoveX * $ts; $my = $def.MoveY * $ts
                        $len = [math]::Sqrt($mx * $mx + $my * $my)
                        $pf = @{
                            Def = $def; X = $x * $ts; Y = $y * $ts; W = $w; H = $h; StartX = $x * $ts; StartY = $y * $ts
                            Length = $len; UX = $(if ($len) { $mx / $len } else { 0 }); UY = $(if ($len) { $my / $len } else { 0 })
                            Progress = 0.0; Phase = 'out'; Pause = 0.0; Delay = $def.StartDelay; DX = 0.0; DY = 0.0
                            SolidOn = $true; OneWay = $def.OneWay; Pushable = $false
                        }
                        $pf.Sprite = New-BoxSprite (Get-WorldImage $def.Image) $w $h (Get-OrDefault $def.Color '#8D6E63') $ts $false
                        [void]$A.Platforms.Add($pf)
                    }
                }
            }
        }
    }
    foreach ($b in $A.Blocks) { if ($b.Kind -eq 'toggle') { Update-ToggleBlock $A $b } }
    $A
}

# A goal flag or any other exit, standing on the bottom of its cell
function New-ExitObject([string]$Exit, [int]$CellX, [int]$CellY, $Bitmap, [string]$Color) {
    $ts = $script:World.TileSize
    $gw = if ($Bitmap) { $Bitmap.PixelWidth } else { $ts }
    $gh = if ($Bitmap) { $Bitmap.PixelHeight } else { $ts * 2 }
    $goal = @{ Exit = $Exit; X = $CellX * $ts + ($ts - $gw) / 2; Y = ($CellY + 1) * $ts - $gh; W = $gw; H = $gh }
    $goal.Sprite = New-Sprite $Bitmap $gw $gh $Color
    $goal
}

# Water or lava body + its surface strip, drawn in front of everything
function New-LiquidVisual($Lq) {
    $ts = $script:World.TileSize
    $lava = $Lq.Kind -eq 'lava'
    $sand = $Lq.Kind -eq 'quicksand'
    $Lq.Body = New-BoxSprite (Get-WorldImage $Lq.Def.Image) 10 10 (Get-OrDefault $Lq.Def.Color $(if ($lava) { '#E6E64A19' } elseif ($sand) { '#F0C2A15A' } else { '#663FA9F5' })) $ts $false
    $Lq.Surface = New-BoxSprite (Get-WorldImage $Lq.Def.SurfaceImage) 10 6 (Get-OrDefault $Lq.Def.SurfaceColor $(if ($lava) { '#FFFFAB40' } elseif ($sand) { '#FFD7B98A' } else { '#99E3F2FD' })) $ts $false
    $Lq.Body.IsHitTestVisible = $false
    $Lq.Surface.IsHitTestVisible = $false
}

function Set-LiquidVisual($Lq) {
    $R = $script:Run
    $Lq.Body.Width = $Lq.X1 - $Lq.X0
    $Lq.Body.Height = [math]::Max(0.0, $R.HeightPx + 64 - $Lq.Level)
    Set-ElementAt $Lq.Body $Lq.X0 $Lq.Level
    $Lq.Surface.Width = $Lq.X1 - $Lq.X0
    $sh = if ($Lq.Surface.Fill -is [System.Windows.Media.ImageBrush]) { $Lq.Surface.Fill.ImageSource.PixelHeight } else { 6 }
    $Lq.Surface.Height = $sh
    Set-ElementAt $Lq.Surface $Lq.X0 ($Lq.Level - $sh / 2)
}

# Puts an area's objects on screen
function Show-AreaVisuals($A) {
    $R = $script:Run
    $world = $script:World
    $WorldCanvas.Children.Clear()
    $TileImage.Source = $A.Map.Bitmap
    $TileImage.Width  = $A.Map.WidthPx
    $TileImage.Height = $A.Map.HeightPx
    [void]$WorldCanvas.Children.Add($TileImage)
    foreach ($list in $A.Spawners, $A.Dispensers, $A.Goals, $A.Checkpoints, $A.Warps, $A.Locks, $A.Blocks, $A.Items, $A.Mounts, $A.Enemies, $A.Platforms, $A.Throwables) {
        foreach ($ent in $list) {
            if (-not $ent.Sprite -or $ent.Dead -or $ent.Taken -or $ent.Open -or $ent.Gone) { continue }
            Add-Sprite $ent.Sprite
            Set-SpritePosition $ent
            if ($ent.IceSprite) { Add-Sprite $ent.IceSprite; Set-ElementAt $ent.IceSprite $ent.X $ent.Y }
        }
    }
    if ($R.Mount) { Add-Sprite $R.Mount.Sprite }
    Add-Sprite $R.Player.Sprite

    $FrontCanvas.Children.Clear()
    $FrontImage.Source = $A.Map.FrontBitmap
    $FrontImage.Width  = $A.Map.WidthPx
    $FrontImage.Height = $A.Map.HeightPx
    [void]$FrontCanvas.Children.Add($FrontImage)
    foreach ($lq in $A.Liquids) {
        [void]$FrontCanvas.Children.Add($lq.Body)
        [void]$FrontCanvas.Children.Add($lq.Surface)
        Set-LiquidVisual $lq
    }

    # Background: an image tiled sideways with parallax, or a plain colour
    $bg = Get-WorldImage $A.Area.Background
    if ($bg) {
        $R.BgWidth = $bg.PixelWidth * $ViewH / $bg.PixelHeight
        $brush = New-Object System.Windows.Media.ImageBrush $bg
        $brush.TileMode = 'Tile'
        $brush.ViewportUnits = 'Absolute'
        $brush.Viewport = New-Rect 0 0 $R.BgWidth $ViewH
        $BgRect.Fill = $brush
        $R.BgBrush = $brush
    }
    else { $BgRect.Fill = ConvertTo-Brush (Get-OrDefault $A.Area.BackgroundColor $world.BackgroundColor); $R.BgBrush = $null }

    $areaText = if ($R.Level.Areas.Count -gt 1 -and $A.Id -ne $R.Level.Start.Area) { "  ($($A.Id))" } else { '' }
    $HudLeft.Text = if ($R.MiniGame) { "$($world.Name)   -   Mini-game: $($R.MiniGame.Name)" } else { "$($world.Name)   -   $($R.Level.Label). $($R.Level.Name)$areaText" }
}

function Set-Fade([double]$Opacity) { $FadeRect.Opacity = $Opacity }

# ---------------------------------------------------------------------------
# Level flow: start, lives, areas, warps
# ---------------------------------------------------------------------------
function Start-Level([int]$Number, $Resume, $MiniGame = $null) {
    $world = $script:World
    $lv = if ($MiniGame) { $MiniGame.Level } else { Get-Level $Number }
    if (-not $lv) { throw "Level $Number doesn't exist in this world." }
    if ($lv.Error) { throw "Level $($lv.Label) is broken: $($lv.Error)" }
    Use-Chapter $world $lv.Chapter
    $slot = Get-CurrentSlot
    if ($slot.gameOver -and -not $MiniGame) { throw 'This save is out of lives and can only be reviewed. Start a new game in another slot.' }

    $slotTaken = [System.Collections.Generic.HashSet[string]]::new()
    if (-not $MiniGame) { foreach ($id in @($slot.taken["$Number"])) { if ($id) { [void]$slotTaken.Add("$id") } } }

    $R = @{
        State = 'Starting'; Level = $lv; LevelNumber = $lv.Number; Slot = $slot
        Stats = $(if ($MiniGame) { @{ tries = 0; deaths = 0; completions = 0; bestTime = $null } } else { Get-LevelStats $world.Stats $lv.Number })
        T = $world.TileSize; Areas = @{}; AreaId = $null; A = $null
        Player = $null; Mount = $null; Projectiles = New-Object System.Collections.ArrayList
        EnemyShots = New-Object System.Collections.ArrayList; NewEnemies = New-Object System.Collections.ArrayList
        SolidList = New-Object System.Collections.ArrayList
        SlotTaken = $slotTaken
        RunCommitted = [System.Collections.Generic.HashSet[string]]::new()   # keys taken / locks opened before the checkpoint
        Pending = New-Object System.Collections.ArrayList                    # picked up since the checkpoint
        Inv = @{}; InvAtCheckpoint = $(if ($MiniGame) { @{} } else { Copy-Hashtable $slot.keys })   # keys held: keyId -> count
        Stash = New-Object System.Collections.ArrayList                      # power-ups stored in the inventory
        StashAtCheckpoint = @($(if (-not $MiniGame) { @($slot.stash) }))
        Checkpoint = $null; PowerKey = $(if ($MiniGame) { $null } else { Get-SlotPowerKey $slot.power $slot.shield }); Power = $null; PowerTimer = 0.0; PowerHits = 0
        BasePhys = $lv.Physics; Phys = $lv.Physics
        Time = 0.0; LifeTime = 0.0; TimeLimit = $(if ($MiniGame) { $MiniGame.Time } else { $lv.TimeLimit })
        CamX = 0.0; CamY = 0.0; BgBrush = $null; BgWidth = 0.0; LastDt = 0.0
        JumpPressed = $false; UpPressed = $false; DownPressed = $false; FirePressed = $false; DismountPressed = $false
        DeadTimer = 0.0; DeathHop = $false; Warp = $null; WarpPhase = ''; WarpTimer = 0.0; GlowOn = $false
        InvulnTimer = 0.0; InvincibleTimer = 0.0; SpeedTimer = 0.0; SpeedMult = 1.0; FireCooldown = 0.0; MountCooldown = 0.0
        CollectiblesFound = 0; Defeated = 0; DefeatedBy = @{}; Switches = @{}; ReqToast = 0.0; FullToast = 0.0
        MiniGame = $MiniGame
    }
    if ($Resume) {
        if ($null -ne $Resume.x -and $Resume.area -and $lv.Areas.Contains("$($Resume.area)")) {
            $R.Checkpoint = @{ Area = "$($Resume.area)"; X = [int]$Resume.x; Y = [int]$Resume.y }
        }
        foreach ($id in @($Resume.runCommitted)) { if ($id) { [void]$R.RunCommitted.Add("$id") } }
        if ($Resume.keys) { $R.InvAtCheckpoint = @{}; foreach ($k in @($Resume.keys.Keys)) { $R.InvAtCheckpoint[$k] = [int]$Resume.keys[$k] } }
        if ($null -ne $Resume.stash) { $R.StashAtCheckpoint = @($Resume.stash) }
        $R.PowerKey = Get-SlotPowerKey $Resume.power $Resume.shield
        $R.Time     = [double]$Resume.time
    }
    $script:Run = $R
    Show-Screen 'GameLayer'
    Start-Life
    Start-GameLoop
}

# Starts (or restarts after dying) from the last checkpoint, or the level start
function Start-Life {
    $R = $script:Run
    $world = $script:World
    $R.Stats.tries++
    Add-Record 'tries'
    $R.Areas = @{}
    $R.Pending.Clear()
    $R.Projectiles.Clear()
    $R.SolidList.Clear()
    $R.Inv = Copy-Hashtable $R.InvAtCheckpoint
    $R.Stash.Clear(); foreach ($k in @($R.StashAtCheckpoint)) { if ($k) { [void]$R.Stash.Add("$k") } }
    $R.EnemyShots.Clear(); $R.NewEnemies.Clear(); $R.Carrying = $null
    $R.LifeTime = 0.0; $R.Defeated = 0; $R.DefeatedBy = @{}; $R.Switches = @{}
    $R.Mount = $null
    $R.Phys = $R.BasePhys
    $R.InvulnTimer = 0.0; $R.InvincibleTimer = 0.0; $R.SpeedTimer = 0.0; $R.FireCooldown = 0.0; $R.MountCooldown = 0.0
    $R.GlowOn = $false
    Set-Power $R.PowerKey
    $R.CollectiblesFound = @($R.SlotTaken | Where-Object { $_.StartsWith('collectible|') }).Count

    $R.Player = @{
        X = 0.0; Y = 0.0; W = $world.Player.Width; H = $world.Player.Height
        VX = 0.0; VY = 0.0; Facing = 1; OnGround = $false; HitX = $false; HitTop = $false; GroundSolid = $null
        Coyote = 0.0; Buffer = 0.0; AirJumpsUsed = 0; Crouching = $false; InWater = $false; AnimState = ''; AnimTime = 0.0
        Launched = $false; KnockTimer = 0.0; LavaSwim = $false
        Climbing = $false; DropTimer = 0.0; DropThrough = $false; GroundDef = $null
        Sleeping = $false; TalkTimer = 0.0; Bubble = $null
    }
    $R.IdleTime = 0.0
    $R.PlayerBase = Get-FirstBitmap $world.Player.Image $world.Player.Anims
    $R.Player.BaseBitmap = $R.PlayerBase
    $R.Player.Sprite = New-Sprite $R.PlayerBase $world.Player.Width $world.Player.Height '#3D7BFF'

    $spawn = if ($R.Checkpoint) { $R.Checkpoint } else { $R.Level.Start }
    Enter-Area $spawn.Area
    Set-PlayerAtCell $spawn.X $spawn.Y
    $R.Twist = $null
    if ($R.MiniGame) { Initialize-Twist }
    $R.State = 'Playing'
    $DeathText.Visibility = 'Collapsed'
    Set-Fade 0
    Clear-Presses
    $script:Held.Clear()
    Sync-PadHeld
    Update-Camera 1.0
    Update-Sprites 0
    Update-Hud
}

function Enter-Area([string]$AreaId) {
    $R = $script:Run
    if (-not $R.Areas.ContainsKey($AreaId)) { $R.Areas[$AreaId] = New-AreaRuntime $AreaId }
    $A = $R.Areas[$AreaId]
    $R.AreaId = $AreaId
    $R.A = $A
    $R.Solid = $A.Solid; $R.EnemySolid = $A.EnemySolid; $R.OneWayGrid = $A.Map.OneWay; $R.Climb = $A.Map.Climb; $R.Cell = $A.Map.Cell
    $R.Hazard = $A.Map.Hazard; $R.EnemyHazard = $A.Map.EnemyHazard; $R.Liquid = $A.Map.Liquid; $R.LavaGrid = $A.Map.Lava; $R.Sand = $A.Map.Sand; $R.Spikes = $A.Map.Spikes
    $R.W = $A.Map.W; $R.H = $A.Map.H; $R.WidthPx = $A.Map.WidthPx; $R.HeightPx = $A.Map.HeightPx
    $R.Projectiles.Clear(); $R.EnemyShots.Clear()
    Update-Gates $A
    $R.Player.GroundSolid = $null
    Update-SolidList
    Show-AreaVisuals $A
    Enter-Atmosphere $A.Area
}

function Set-PlayerAtCell([int]$CellX, [int]$CellY) {
    $R = $script:Run; $pl = $R.Player; $ts = $R.T
    $pl.X = $CellX * $ts + ($ts - $pl.W) / 2
    $pl.Y = ($CellY + 1) * $ts - $pl.H
    $pl.VX = 0.0; $pl.VY = 0.0
}

function Clear-Presses {
    $R = $script:Run
    $R.JumpPressed = $false; $R.UpPressed = $false; $R.DownPressed = $false; $R.FirePressed = $false; $R.DismountPressed = $false
}

function Test-Unlocked([string]$Id) {
    $R = $script:Run
    if ($R.SlotTaken.Contains($Id) -or $R.RunCommitted.Contains($Id)) { return $true }
    foreach ($p in $R.Pending) { if ($p.Id -eq $Id) { return $true } }
    $false
}

# Uses a key if the player has one. Returns $true when the lock is (or already was) open.
function Use-Key([string]$LockId, [string]$Id) {
    $R = $script:Run
    if (Test-Unlocked $Id) { return $true }
    if ([int]$R.Inv[$LockId] -le 0) { return $false }
    $R.Inv[$LockId] = [int]$R.Inv[$LockId] - 1
    [void]$R.Pending.Add(@{ Id = $Id; Kind = 'lock' })
    Show-Toast 'Unlocked!'
    $true
}

function Start-Warp($Warp) {
    $R = $script:Run
    if ($Warp.LockId) {
        if (-not (Use-Key $Warp.LockId "warp|$($Warp.Digit)")) {
            Show-Toast "Locked. You need the $($Warp.LockId) key."
            $Warp.Armed = $false
            return
        }
    }
    Invoke-DropCarried
    $R.State = 'Warping'
    $R.Warp = $Warp.Partner
    $R.WarpPhase = 'out'
    $R.WarpTimer = 0.0
    $R.Player.VX = 0.0; $R.Player.VY = 0.0
    Clear-Presses
}

function Update-Warping([double]$dt) {
    $R = $script:Run
    $R.WarpTimer += $dt
    $duration = 0.22
    if ($R.WarpPhase -eq 'out') {
        Set-Fade ([math]::Min(1, $R.WarpTimer / $duration))
        if ($R.WarpTimer -ge $duration) {
            $target = $R.Warp
            if ($target.Area -ne $R.AreaId) { Enter-Area $target.Area }
            Set-PlayerAtCell $target.X $target.Y
            foreach ($wp in $R.A.Warps) { if ($wp.CellX -eq $target.X -and $wp.CellY -eq $target.Y) { $wp.Armed = $false } }
            Update-Camera 1.0
            Update-Sprites 0
            $R.WarpPhase = 'in'
            $R.WarpTimer = 0.0
        }
    }
    else {
        Set-Fade ([math]::Max(0.0, 1 - $R.WarpTimer / $duration))
        if ($R.WarpTimer -ge $duration) { Set-Fade 0; $R.State = 'Playing' }
    }
}

# ---------------------------------------------------------------------------
# Game loop
# ---------------------------------------------------------------------------
function Start-GameLoop {
    $script:LastTick = $script:Clock.Elapsed.TotalSeconds
    if (-not $script:LoopOn) {
        [System.Windows.Media.CompositionTarget]::add_Rendering($script:RenderHandler)
        $script:LoopOn = $true
    }
}

function Stop-GameLoop {
    if ($script:LoopOn) {
        [System.Windows.Media.CompositionTarget]::remove_Rendering($script:RenderHandler)
        $script:LoopOn = $false
    }
}

# Runs once per screen refresh (usually 60 times a second)
function Update-Game {
    $R = $script:Run
    if (-not $R) { return }
    $now = $script:Clock.Elapsed.TotalSeconds
    $dt = $now - $script:LastTick
    $script:LastTick = $now
    if ($dt -le 0) { return }
    if ($dt -gt 0.034) { $dt = 0.034 }
    try {
        Update-Pad
        $R = $script:Run
        if (-not $R) { return }
        if ($script:ToastTimer -gt 0) {
            $script:ToastTimer -= $dt
            if ($script:ToastTimer -le 0) { $ToastBox.Visibility = 'Collapsed' }
        }
        switch ($R.State) {
            'Playing' { Update-Playing $dt }
            'Dead'    { Update-Dead $dt }
            'Warping' { Update-Warping $dt }
        }
    }
    catch {
        # Never let an error crash the window: stop and offer a way out
        Stop-GameLoop
        $R.State = 'Error'
        Show-Overlay 'SOMETHING WENT WRONG' "$($_.Exception.Message)`n(line $($_.InvocationInfo.ScriptLineNumber))" @(
            @{ Text = 'Restart the level';  Action = { Hide-Overlay; Start-Level $script:Run.LevelNumber $null } }
            @{ Text = 'Back to world menu'; Action = { Exit-Level } }
        )
    }
}

# Things that move but block like walls: moving platforms, crushers, ice blocks, enemies acting as platforms
function Update-SolidList {
    $R = $script:Run
    $R.SolidList.Clear()
    if (-not $R.A) { return }
    foreach ($p in $R.A.Platforms) { [void]$R.SolidList.Add($p) }
    foreach ($en in $R.A.Enemies) { if ($en.SolidOn -and -not $en.Dead) { [void]$R.SolidList.Add($en) } }
}

# Moves anything with a hitbox and stops it at solid tiles and moving solids. X and Y are handled
# separately (so things slide along walls), and big moves are split into steps so nothing tunnels through.
# One-way platforms only stop things landing on them from above. $Ignore is a solid to pass through.
function Move-Entity($Ent, [double]$DX, [double]$DY, $Ignore = $null) {
    $R = $script:Run
    $ts = $R.T; $mw = $R.W; $mh = $R.H
    $grid = $R.Solid
    if ($Ent.IsEnemy) { $grid = $R.EnemySolid }       # some tiles only block the player, or only enemies
    $ow = $R.OneWayGrid
    $drop = [bool]$Ent.DropThrough
    $solids = $R.SolidList
    $useSolids = $solids.Count -gt 0
    $Ent.HitX = $false; $Ent.OnGround = $false; $Ent.HitTop = $false; $Ent.GroundSolid = $null
    $steps = [int][math]::Ceiling([math]::Max([math]::Abs($DX), [math]::Abs($DY)) / ($ts * 0.45))
    if ($steps -lt 1) { $steps = 1 }
    $sx = $DX / $steps; $sy = $DY / $steps

    for ($i = 0; $i -lt $steps; $i++) {
        if ($sx -ne 0) {
            $Ent.X += $sx
            $ty0 = [int][math]::Floor($Ent.Y / $ts)
            $ty1 = [int][math]::Floor(($Ent.Y + $Ent.H - 0.001) / $ts)
            $tx  = if ($sx -gt 0) { [int][math]::Floor(($Ent.X + $Ent.W - 0.001) / $ts) } else { [int][math]::Floor($Ent.X / $ts) }
            for ($ty = $ty0; $ty -le $ty1; $ty++) {
                $hit = ($tx -lt 0) -or ($tx -ge $mw) -or ($ty -ge 0 -and $ty -lt $mh -and $grid[$tx, $ty])
                if ($hit) {
                    $Ent.X = if ($sx -gt 0) { $tx * $ts - $Ent.W } else { ($tx + 1) * $ts }
                    $Ent.HitX = $true; $sx = 0
                    break
                }
            }
            if ($sx -ne 0 -and $useSolids) {
                foreach ($s in $solids) {
                    if ($s.OneWay -or [object]::ReferenceEquals($s, $Ent) -or [object]::ReferenceEquals($s, $Ignore)) { continue }
                    if (($Ent.X -lt $s.X + $s.W) -and ($Ent.X + $Ent.W -gt $s.X) -and ($Ent.Y -lt $s.Y + $s.H) -and ($Ent.Y + $Ent.H -gt $s.Y)) {
                        $Ent.X = if ($sx -gt 0) { $s.X - $Ent.W } else { $s.X + $s.W }
                        $Ent.HitX = $true; $sx = 0
                        break
                    }
                }
            }
        }
        if ($sy -ne 0) {
            $prevBottom = $Ent.Y + $Ent.H
            $Ent.Y += $sy
            $tx0 = [int][math]::Floor($Ent.X / $ts)
            $tx1 = [int][math]::Floor(($Ent.X + $Ent.W - 0.001) / $ts)
            $ty  = if ($sy -gt 0) { [int][math]::Floor(($Ent.Y + $Ent.H - 0.001) / $ts) } else { [int][math]::Floor($Ent.Y / $ts) }
            if ($ty -ge 0 -and $ty -lt $mh) {
                for ($tx = $tx0; $tx -le $tx1; $tx++) {
                    if ($tx -ge 0 -and $tx -lt $mw -and ($grid[$tx, $ty] -or ($sy -gt 0 -and -not $drop -and $ow[$tx, $ty] -and $prevBottom -le $ty * $ts + 0.5))) {
                        if ($sy -gt 0) { $Ent.Y = $ty * $ts - $Ent.H; $Ent.OnGround = $true }
                        else           { $Ent.Y = ($ty + 1) * $ts;    $Ent.HitTop = $true }
                        $sy = 0
                        break
                    }
                }
            }
            if ($sy -ne 0 -and $useSolids) {
                foreach ($s in $solids) {
                    if ([object]::ReferenceEquals($s, $Ent) -or [object]::ReferenceEquals($s, $Ignore)) { continue }
                    if (($Ent.X -lt $s.X + $s.W) -and ($Ent.X + $Ent.W -gt $s.X) -and ($Ent.Y -lt $s.Y + $s.H) -and ($Ent.Y + $Ent.H -gt $s.Y)) {
                        if ($sy -gt 0) {
                            if ($s.OneWay -and $prevBottom -gt $s.Y + 1) { continue }
                            $Ent.Y = $s.Y - $Ent.H; $Ent.OnGround = $true; $Ent.GroundSolid = $s
                        }
                        else {
                            if ($s.OneWay) { continue }
                            $Ent.Y = $s.Y + $s.H; $Ent.HitTop = $true
                        }
                        $sy = 0
                        break
                    }
                }
            }
        }
    }
}

function Test-Overlap($A, $B) {
    ($A.X -lt $B.X + $B.W) -and ($A.X + $A.W -gt $B.X) -and ($A.Y -lt $B.Y + $B.H) -and ($A.Y + $A.H -gt $B.Y)
}

# Is this rectangle blocked by solid tiles or (non one-way) moving solids?
function Test-RectSolid([double]$X, [double]$Y, [double]$W, [double]$H, $Exclude = $null) {
    $R = $script:Run; $ts = $R.T
    for ($ty = [int][math]::Floor($Y / $ts); $ty -le [int][math]::Floor(($Y + $H - 0.001) / $ts); $ty++) {
        for ($tx = [int][math]::Floor($X / $ts); $tx -le [int][math]::Floor(($X + $W - 0.001) / $ts); $tx++) {
            if ($tx -lt 0 -or $tx -ge $R.W) { return $true }
            if ($ty -ge 0 -and $ty -lt $R.H -and $R.Solid[$tx, $ty]) { return $true }
        }
    }
    foreach ($s in $R.SolidList) {
        if ($s.OneWay -or [object]::ReferenceEquals($s, $Exclude)) { continue }
        if (($X -lt $s.X + $s.W) -and ($X + $W -gt $s.X) -and ($Y -lt $s.Y + $s.H) -and ($Y + $H -gt $s.Y)) { return $true }
    }
    $false
}

# Water: tiles, plus rising/falling water layers
function Test-PointLiquid([double]$PX, [double]$PY) {
    $R = $script:Run
    $tx = [int][math]::Floor($PX / $R.T); $ty = [int][math]::Floor($PY / $R.T)
    if ($tx -ge 0 -and $tx -lt $R.W -and $ty -ge 0 -and $ty -lt $R.H -and $R.Liquid[$tx, $ty]) { return $true }
    foreach ($lq in $R.A.Liquids) {
        if ($lq.Kind -eq 'water' -and $PY -ge $lq.Level -and $PX -ge $lq.X0 -and $PX -lt $lq.X1) { return $true }
    }
    $false
}

function Test-PointLava([double]$PX, [double]$PY) {
    $R = $script:Run
    $tx = [int][math]::Floor($PX / $R.T); $ty = [int][math]::Floor($PY / $R.T)
    if ($tx -ge 0 -and $tx -lt $R.W -and $ty -ge 0 -and $ty -lt $R.H -and $R.LavaGrid[$tx, $ty]) { return $true }
    foreach ($lq in $R.A.Liquids) {
        if ($lq.Kind -eq 'lava' -and $PY -ge $lq.Level -and $PX -ge $lq.X0 -and $PX -lt $lq.X1) { return $true }
    }
    $false
}

function Test-PointSand([double]$PX, [double]$PY) {
    $R = $script:Run
    $tx = [int][math]::Floor($PX / $R.T); $ty = [int][math]::Floor($PY / $R.T)
    if ($tx -ge 0 -and $tx -lt $R.W -and $ty -ge 0 -and $ty -lt $R.H -and $R.Sand[$tx, $ty]) { return $true }
    foreach ($lq in $R.A.Liquids) {
        if ($lq.Kind -eq 'quicksand' -and $PY -ge $lq.Level -and $PX -ge $lq.X0 -and $PX -lt $lq.X1) { return $true }
    }
    $false
}

# Lava can't kill you while you're powered up, riding, invincible or still flashing from a hit:
# it takes your mount or power-up (if you're not invincible) and throws you into the air.
function Invoke-LavaTouch {
    $R = $script:Run; $pl = $R.Player
    if ($R.InvincibleTimer -le 0 -and $R.InvulnTimer -le 0) {
        if (-not $R.Mount -and -not $R.Power) { Invoke-PlayerDeath 'BURNED!' $true; return }
        [void](Invoke-PlayerHurt $false)
        Show-Toast 'Too hot! Lost your power-up.'
    }
    Invoke-Knockback ([double]::NaN) (-$R.Phys.lavaBounce) 0
}

# Throws the player. NaN = leave that speed alone. Lock = seconds the push can't be steered against.
function Invoke-Knockback([double]$VX, [double]$VY, [double]$Lock) {
    $R = $script:Run; $pl = $R.Player
    if (-not [double]::IsNaN($VX)) { $pl.VX = $VX }
    if (-not [double]::IsNaN($VY)) {
        $pl.VY = $VY
        if ($VY -lt 0) {
            $pl.Launched = $true          # full height even if jump isn't held
            $pl.OnGround = $false
            if (-not (Test-RectSolid $pl.X ($pl.Y - 2) $pl.W $pl.H)) { $pl.Y -= 2 }
        }
    }
    $pl.KnockTimer = [math]::Max($pl.KnockTimer, $Lock)
    if ($pl.Crouching) {
        $standH = $script:World.Player.Height
        $newY = $pl.Y + $pl.H - $standH
        if (-not (Test-RectSolid $pl.X $newY $pl.W $standH)) { $pl.Y = $newY; $pl.H = $standH; $pl.Crouching = $false }
    }
}

# Which pointed side of a spike block is the player pressed against? 'up' means the player is
# standing on spikes that point up, 'left' means the player's right side touches spikes pointing left...
# Returns @(direction, kills) or $null. Blunt sides are just walls. The outer 4px of each edge are safe.
function Get-SpikeContact($Ent) {
    $R = $script:Run; $g = $R.Spikes
    if ($null -eq $g) { return $null }
    $ts = $R.T; $m = 4
    $checks = @(
        @('up',    1, [int][math]::Floor(($Ent.X + $m) / $ts), [int][math]::Floor(($Ent.X + $Ent.W - $m) / $ts), [int][math]::Floor(($Ent.Y + $Ent.H + 0.5) / $ts), $null),
        @('down',  2, [int][math]::Floor(($Ent.X + $m) / $ts), [int][math]::Floor(($Ent.X + $Ent.W - $m) / $ts), [int][math]::Floor(($Ent.Y - 0.5) / $ts), $null),
        @('left',  4, [int][math]::Floor(($Ent.X + $Ent.W + 0.5) / $ts), $null, [int][math]::Floor(($Ent.Y + $m) / $ts), [int][math]::Floor(($Ent.Y + $Ent.H - $m) / $ts)),
        @('right', 8, [int][math]::Floor(($Ent.X - 0.5) / $ts), $null, [int][math]::Floor(($Ent.Y + $m) / $ts), [int][math]::Floor(($Ent.Y + $Ent.H - $m) / $ts))
    )
    foreach ($c in $checks) {
        $bit = $c[1]
        if ($null -eq $c[5]) { $xs = $c[2]..$c[3]; $ys = @($c[4]) } else { $xs = @($c[2]); $ys = $c[4]..$c[5] }
        foreach ($ty in $ys) {
            if ($ty -lt 0 -or $ty -ge $R.H) { continue }
            foreach ($tx in $xs) {
                if ($tx -lt 0 -or $tx -ge $R.W) { continue }
                $v = $g[$tx, $ty]
                if ($v -band $bit) { return , @($c[0], [bool]($v -band 16)) }
            }
        }
    }
    $null
}

# Spikes: hurt (or kill) unless you're invincible or still flashing - either way they throw you off.
function Invoke-SpikeTouch([string]$Dir, [bool]$Kills) {
    $R = $script:Run; $ph = $R.Phys
    if ($R.InvincibleTimer -le 0 -and $R.InvulnTimer -le 0) {
        if ($Kills) { Invoke-PlayerDeath 'SPIKED!' $true; return }
        [void](Invoke-PlayerHurt $false)
        if ($R.State -ne 'Playing') { return }
    }
    switch ($Dir) {
        'up'    { Invoke-Knockback ([double]::NaN) (-$ph.hurtBounce) 0 }
        'down'  { Invoke-Knockback ([double]::NaN) ($ph.hurtBounce * 0.4) 0 }
        'left'  { Invoke-Knockback (-$ph.hurtKnockback) (-$ph.hurtBounce * 0.6) 0.25 }
        'right' { Invoke-Knockback ($ph.hurtKnockback) (-$ph.hurtBounce * 0.6) 0.25 }
    }
}

function Test-InLiquid($Ent) { Test-PointLiquid ($Ent.X + $Ent.W / 2) ($Ent.Y + $Ent.H / 2) }

# 0 = safe, 1 = touching something that hurts, 2 = touching something that kills.
# The outer 6px of a hazard tile are safe so grazing an edge feels fair.
function Get-HazardLevel($Ent) {
    $R = $script:Run; $ts = $R.T; $m = 6; $worst = 0
    $x0 = [int][math]::Floor($Ent.X / $ts); $x1 = [int][math]::Floor(($Ent.X + $Ent.W) / $ts)
    $y0 = [int][math]::Floor($Ent.Y / $ts); $y1 = [int][math]::Floor(($Ent.Y + $Ent.H) / $ts)
    for ($y = $y0; $y -le $y1; $y++) {
        if ($y -lt 0 -or $y -ge $R.H) { continue }
        for ($x = $x0; $x -le $x1; $x++) {
            if ($x -lt 0 -or $x -ge $R.W) { continue }
            $h = $R.Hazard[$x, $y]
            if ($h -le $worst) { continue }
            if ($Ent.X -lt ($x + 1) * $ts - $m -and $Ent.X + $Ent.W -gt $x * $ts + $m -and
                $Ent.Y -lt ($y + 1) * $ts - $m -and $Ent.Y + $Ent.H -gt $y * $ts + $m) { $worst = $h }
        }
    }
    $worst
}

function Test-Held([string]$Action) {
    foreach ($k in $ActionKeys[$Action]) { if ($script:Held.Contains($k)) { return $true } }
    $false
}

function Get-AirJumps {
    $R = $script:Run
    $n = $R.Phys.airJumps
    if ($R.Power) { $n += $R.Power.Ability.AirJumps }
    $n
}

# ---- Moving things that aren't characters ----
function Update-Liquids([double]$dt) {
    $R = $script:Run
    foreach ($lq in $R.A.Liquids) {
        if ($lq.Waiting) { continue }               # waits for a survival fight to start
        if ($lq.Draining) {
            # After a survival fight: back to where it started
            $old = $lq.Level
            $step = [math]::Max($lq.Speed, $R.T) * $dt
            if ([math]::Abs($lq.Start - $lq.Level) -le $step) { $lq.Level = $lq.Start; $lq.Draining = $false; $lq.Waiting = $true }
            else { $lq.Level += [math]::Sign($lq.Start - $lq.Level) * $step }
            Set-LiquidVisual $lq
            continue
        }
        $lq.Time += $dt
        $t = $lq.Time - $lq.Def.Delay
        if ($t -le 0 -or $lq.Mode -eq 'still') { continue }
        $old = $lq.Level
        switch ($lq.Mode) {
            'wave' { $lq.Level = $lq.Mid + $lq.Amp * [math]::Cos($lq.Phase + 2 * [math]::PI * $t / $lq.Def.Period) }
            'rise' { $lq.Level = [math]::Max($lq.High, $lq.Start - $lq.Speed * $t) }
            'pingpong' {
                if ($lq.PauseLeft -gt 0) { $lq.PauseLeft -= $dt }
                else {
                    $lq.Level += $lq.Dir * $lq.Speed * $dt
                    if ($lq.Level -le $lq.High) { $lq.Level = $lq.High; $lq.Dir = 1; $lq.PauseLeft = $lq.Def.Pause }
                    elseif ($lq.Level -ge $lq.Low) { $lq.Level = $lq.Low; $lq.Dir = -1; $lq.PauseLeft = $lq.Def.Pause }
                }
            }
        }
        if ([math]::Abs($lq.Level - $old) -gt 0.01) { Set-LiquidVisual $lq }
    }
}

# Platforms go out along their path, pause, come back, pause, and so on
function Update-Platforms([double]$dt) {
    $R = $script:Run
    foreach ($p in $R.A.Platforms) {
        $ox = $p.X; $oy = $p.Y
        if ($p.Delay -gt 0) { $p.Delay -= $dt }
        elseif ($p.Pause -gt 0) { $p.Pause -= $dt }
        elseif ($p.Length -gt 0) {
            if ($p.Phase -eq 'out') {
                $p.Progress += $p.Def.Speed * $dt
                if ($p.Progress -ge $p.Length) { $p.Progress = $p.Length; $p.Phase = 'back'; $p.Pause = $p.Def.PauseEnd }
            }
            else {
                $p.Progress -= $p.Def.ReturnSpeed * $dt
                if ($p.Progress -le 0) { $p.Progress = 0.0; $p.Phase = 'out'; $p.Pause = $p.Def.PauseStart }
            }
            $p.X = $p.StartX + $p.UX * $p.Progress
            $p.Y = $p.StartY + $p.UY * $p.Progress
        }
        $p.DX = $p.X - $ox; $p.DY = $p.Y - $oy
    }
}

# Rides the player along on whatever moved under them, and checks for being squashed
function Update-Carry {
    $R = $script:Run; $pl = $R.Player
    $gs = $pl.GroundSolid
    if ($gs -and $R.SolidList.Contains($gs) -and ($gs.DX -ne 0 -or $gs.DY -ne 0)) {
        $wasOnGround = $pl.OnGround
        Move-Entity $pl $gs.DX $gs.DY $gs
        $pl.OnGround = $wasOnGround
        $pl.GroundSolid = $gs
    }
    foreach ($s in $R.SolidList) {
        if ($s.OneWay -or ($s.DX -eq 0 -and $s.DY -eq 0)) { continue }
        if (-not (Test-Overlap $pl $s)) { continue }
        # Something moved into the player: push them out the way it was moving...
        if ([math]::Abs($s.DY) -ge [math]::Abs($s.DX)) {
            if ($s.DY -gt 0) { $pl.Y = $s.Y + $s.H } else { $pl.Y = $s.Y - $pl.H }
        }
        else {
            if ($s.DX -gt 0) { $pl.X = $s.X + $s.W } else { $pl.X = $s.X - $pl.W }
        }
        # ...and if there's no room there, they're crushed
        if (Test-RectSolid $pl.X $pl.Y $pl.W $pl.H $s) { Invoke-PlayerDeath 'CRUSHED!' $false; return }
    }
}

# ---- The player, every frame ----
function Update-Playing([double]$dt) {
    $R = $script:Run
    $pl = $R.Player
    $ph = $R.Phys
    $A = $R.A
    $world = $script:World
    $R.Time += $dt
    $R.LastDt = $dt
    $world.Stats.totalPlaySeconds += $dt
    $R.Slot.playSeconds += $dt
    if (-not ($A.Survival -and $A.Survival.State -eq 'active') -and -not $pl.Sleeping) { $R.LifeTime += $dt }    # the clock stops during a survival fight (and naps)
    Update-PlayerTimers $dt

    # ---- Time limit: 0 = no limit ----
    if ($R.TimeLimit -gt 0 -and $R.LifeTime -ge $R.TimeLimit) {
        if ($R.MiniGame) { Complete-MiniGameLevel "Time's up!"; return }
        Invoke-PlayerDeath 'TIME UP!' $true; return
    }

    Update-Liquids $dt
    Update-Platforms $dt
    Update-SolidList
    Update-Carry
    if ($R.State -ne 'Playing') { return }
    Update-Survival $dt
    if ($R.State -ne 'Playing') { return }
    Update-Twist $dt
    $ph = $R.Phys

    $left     = Test-Held 'Left'
    $right    = Test-Held 'Right'
    if ($R.Twist -and $R.Twist.Kind -eq 'reverse') { $t = $left; $left = $right; $right = $t }
    $up       = Test-Held 'Up'
    $down     = Test-Held 'Down'
    $jumpHeld = Test-Held 'Jump'
    $inWater  = Test-InLiquid $pl
    $feetY    = $pl.Y + $pl.H - 4
    $cx       = $pl.X + $pl.W / 2
    $inLava   = Test-PointLava $cx $feetY
    $ab       = if ($R.Power) { $R.Power.Ability } else { $null }
    Update-Sleep $dt

    # Lava works like water while you're invincible and holding Down (until you leave it or the time runs out),
    # or always with a power-up that's immune to lava
    $lavaSafe = Test-PowerImmune 'lava'
    if (-not $inLava -or ($R.InvincibleTimer -le 0 -and -not $lavaSafe)) { $pl.LavaSwim = $false }
    if ($inLava -and -not $pl.LavaSwim -and (($R.InvincibleTimer -gt 0 -and $down) -or $lavaSafe)) { $pl.LavaSwim = $true }
    if ($pl.LavaSwim) { $inWater = $true }
    if ($R.Twist -and $R.Twist.Water) { $inWater = $true }                  # mini-game twist: water physics everywhere
    $inSand = -not $inWater -and -not $inLava -and ((Test-PointSand $cx ($pl.Y + $pl.H + 1)) -or (Test-PointSand $cx $feetY))
    $pl.InWater = $inWater
    $pl.InSand = $inSand

    # ---- Doors, pipes and tunnels ----
    $touching = $null
    foreach ($wp in $A.Warps) {
        $over = ($cx -ge $wp.X) -and ($cx -lt $wp.X + $wp.W) -and ($pl.Y + $pl.H -gt $wp.Y) -and ($pl.Y -lt $wp.Y + $wp.H)
        if (-not $over) { $wp.Armed = $true; continue }   # re-arms once the player steps off
        $touching = $wp
    }
    if ($touching -and $touching.Partner) {
        $go = switch ($touching.Enter) {
            'up'    { $R.UpPressed }
            'down'  { $R.DownPressed -and ($pl.OnGround -or $inWater) }
            default { $touching.Armed }
        }
        if ($go) { Start-Warp $touching; if ($R.State -eq 'Warping') { return } }
    }

    # ---- Ladders and vines: Up or Down to grab on, jump to let go ----
    $onLadder = (Test-ClimbAt $cx ($pl.Y + $pl.H - 2)) -or (Test-ClimbAt $cx ($pl.Y + $pl.H / 2))
    $ladderBelow = $pl.OnGround -and (Test-ClimbAt $cx ($pl.Y + $pl.H + 4))
    if ($pl.Climbing -and (-not $onLadder -or $R.Mount -or $inWater)) { $pl.Climbing = $false }
    if (-not $pl.Climbing -and -not $R.Mount -and -not $inWater -and (($onLadder -and ($up -or ($down -and -not $pl.OnGround))) -or ($ladderBelow -and $down))) {
        $pl.Climbing = $true; $pl.Buffer = 0; $R.JumpPressed = $false; $pl.VX = 0.0; $pl.VY = 0.0
        if ($pl.Crouching) { $pl.Crouching = $false; $pl.Y -= $world.Player.Height - $pl.H; $pl.H = $world.Player.Height }
    }

    # ---- Crouch (hold Down on the ground). You stay crouched until there is room to stand. ----
    $standH = $world.Player.Height
    if (-not $R.Mount -and -not $pl.Climbing) {
        if (-not $pl.Crouching -and $down -and $pl.OnGround -and -not $inWater -and -not $ladderBelow) {
            $pl.Y += $pl.H - $world.Player.CrouchHeight
            $pl.H = $world.Player.CrouchHeight
            $pl.Crouching = $true
        }
        elseif ($pl.Crouching -and (-not $down -or $inWater)) {
            $newY = $pl.Y + $pl.H - $standH
            if (-not (Test-RectSolid $pl.X $newY $pl.W $standH)) { $pl.Y = $newY; $pl.H = $standH; $pl.Crouching = $false }
        }
    }

    # ---- Run ----
    $gd = $pl.GroundDef
    if ($gd -and -not $gd.AffectsPlayer) { $gd = $null }
    $speedMult = 1.0
    if ($R.SpeedTimer -gt 0) { $speedMult *= $R.SpeedMult }
    if ($ab) { $speedMult *= $ab.Speed }
    if ($inWater) { $speedMult *= $ph.swimSpeed }
    if ($inSand) { $speedMult *= $ph.sandSpeed }
    if ($pl.Crouching -and $pl.OnGround) { $speedMult *= $ph.crouchSpeed }
    if ($gd -and $pl.OnGround) { $speedMult *= $gd.SpeedMult }
    $runSpeed = $ph.runSpeed * $speedMult
    $target = 0.0
    if ($left -and -not $right)     { $target = -$runSpeed; $pl.Facing = -1 }
    elseif ($right -and -not $left) { $target =  $runSpeed; $pl.Facing =  1 }
    $grounded = $pl.OnGround -and -not $inWater
    if ($target -ne 0) { $accel = if ($grounded) { $ph.groundAccel } else { $ph.airAccel } }
    else               { $accel = if ($grounded) { $ph.groundFriction } else { $ph.airFriction } }
    if ($grounded -and $gd) { $accel *= $gd.Friction }                   # ice is slippery, mud is grippy
    if ($pl.KnockTimer -gt 0) { $pl.KnockTimer -= $dt }                  # being thrown: can't steer yet
    elseif ($pl.Climbing) { $pl.VX = [math]::Sign($target) * $ph.climbSpeed * 0.7 }
    elseif ($pl.VX -lt $target) { $pl.VX = [math]::Min($target, $pl.VX + $accel * $dt) }
    elseif ($pl.VX -gt $target) { $pl.VX = [math]::Max($target, $pl.VX - $accel * $dt) }

    # ---- Pushing ice blocks ----
    if ($pl.OnGround -and -not $inSand -and [math]::Abs($pl.VX) -gt 1) {
        $sgn = [math]::Sign($pl.VX)
        foreach ($s in $R.SolidList) {
            if (-not $s.Pushable) { continue }
            $touchSide = if ($sgn -gt 0) { [math]::Abs($s.X - ($pl.X + $pl.W)) -lt 3 } else { [math]::Abs(($s.X + $s.W) - $pl.X) -lt 3 }
            if ($touchSide -and ($pl.Y + $pl.H -gt $s.Y + 4) -and ($pl.Y -lt $s.Y + $s.H)) {
                $pl.VX = $sgn * [math]::Min([math]::Abs($pl.VX), 120)
                Move-Entity $s ($pl.VX * $dt) 0
            }
        }
    }

    # ---- Jump, swim, climb and fly ----
    if ($R.JumpPressed) { $pl.Buffer = $ph.jumpBuffer; $R.JumpPressed = $false } else { $pl.Buffer -= $dt }
    if ($pl.OnGround) { $pl.Coyote = $ph.coyoteTime; $pl.AirJumpsUsed = 0 } else { $pl.Coyote -= $dt }
    if ($pl.DropTimer -gt 0) { $pl.DropTimer -= $dt }

    # Down + jump on a one-way tile drops through it
    if ($pl.Buffer -gt 0 -and $down -and $pl.OnGround -and -not $pl.GroundSolid) {
        $ty = [int][math]::Floor(($pl.Y + $pl.H + 1) / $R.T); $tx = [int][math]::Floor($cx / $R.T)
        if ($tx -ge 0 -and $ty -ge 0 -and $tx -lt $R.W -and $ty -lt $R.H -and $R.OneWayGrid[$tx, $ty] -and -not $R.Solid[$tx, $ty]) {
            $pl.DropTimer = 0.25; $pl.Buffer = 0; $pl.Coyote = 0; $pl.OnGround = $false
        }
    }

    $vyBefore = $pl.VY
    if ($pl.Climbing) {
        $grav = 0.0; $maxFall = 100000.0
        $pl.VY = $(if ($up -and -not $down) { -$ph.climbSpeed } elseif ($down -and -not $up) { $ph.climbSpeed } else { 0.0 })
        if ($pl.Buffer -gt 0 -and -not $up) {
            $pl.Climbing = $false; $pl.VY = -$ph.jumpSpeed * 0.8; $pl.Buffer = 0
        }
        elseif ($pl.Buffer -gt 0) { $pl.Buffer = 0 }        # Up is also a jump key; on a ladder it climbs
        $pl.AirJumpsUsed = 0
    }
    elseif ($inWater) {
        # Swimming needs no power-up: each jump press is a stroke, Down dives
        if ($pl.Buffer -gt 0) { $pl.VY = -$ph.swimStroke; $pl.Buffer = 0 }
        $grav    = $ph.waterGravity * $(if ($down) { 2.5 } else { 1 })
        $maxFall = $ph.waterMaxFall * $(if ($down) { 2 } else { 1 })
        $pl.AirJumpsUsed = 0
    }
    elseif ($inSand) {
        # Quicksand: you slowly sink; each jump press pops you up. Near the top it's a normal(ish) jump.
        if ($pl.Buffer -gt 0) {
            $shallow = -not (Test-PointSand $cx ($feetY - 12))
            $pl.VY = if ($shallow) { -$ph.jumpSpeed * 0.8 } else { -$ph.sandJump }
            $pl.Buffer = 0
        }
        $grav = $ph.gravity
        $maxFall = $ph.sandSinkSpeed
        $pl.AirJumpsUsed = 0
    }
    else {
        $maxFall = $ph.maxFall
        if ($pl.Buffer -gt 0) {
            if ($pl.Coyote -gt 0) {
                $pl.VY = -$ph.jumpSpeed; $pl.Buffer = 0; $pl.Coyote = 0
            }
            elseif ($pl.AirJumpsUsed -lt (Get-AirJumps)) {
                $pl.VY = -$ph.jumpSpeed * 0.9; $pl.Buffer = 0; $pl.AirJumpsUsed++
            }
        }
        $grav = $ph.gravity
        if ($ab -and $ab.Fly -and $jumpHeld -and -not $pl.OnGround) {
            $pl.VY = [math]::Max(-$ab.Fly.MaxRise, $pl.VY - $ab.Fly.Thrust * $dt)
        }
        elseif ($pl.VY -lt 0 -and -not $jumpHeld -and -not $pl.Launched) { $grav *= $ph.shortHopGravity }
        if ($ab -and $ab.Glide -gt 0 -and $jumpHeld -and $pl.VY -gt 0) { $maxFall = [math]::Min($maxFall, $ab.Glide) }
    }
    $pl.VY = [math]::Min($maxFall, $pl.VY + $grav * $dt)
    if ($pl.VY -ge 0) { $pl.Launched = $false }

    $pl.DropThrough = $pl.Climbing -or $pl.DropTimer -gt 0
    $wasOnGround = $pl.OnGround
    Move-Entity $pl ($pl.VX * $dt) ($pl.VY * $dt)
    $hitHead = $pl.HitTop -and $pl.VY -lt 0
    if ($pl.HitX) { $pl.VX = 0 }
    if ($pl.OnGround -or $pl.HitTop) { $pl.VY = 0 }
    if ($pl.Climbing -and $pl.OnGround -and $down) { $pl.Climbing = $false }

    # ---- Hitting blocks: with your head from below, or by landing hard with a heavy-stomp power ----
    if ($hitHead) {
        $hy = $pl.Y - 2; $best = $null; $bestDist = 1e9
        foreach ($hx in @($cx, ($pl.X + 2), ($pl.X + $pl.W - 2))) {
            $b = Get-BlockAtPoint $hx $hy
            if ($b -and [math]::Abs(($b.X + $b.W / 2) - $cx) -lt $bestDist) { $best = $b; $bestDist = [math]::Abs(($b.X + $b.W / 2) - $cx) }
        }
        if ($best) { [void](Invoke-BlockHit $best $(if ($ab -and $ab.BreakBlocks) { 'powerHead' } else { 'head' })) }
    }
    if ($pl.OnGround -and -not $wasOnGround -and $ab -and $ab.HeavyStomp -and $vyBefore -gt 250) {
        foreach ($hx in @(($pl.X + 3), ($pl.X + $pl.W - 3))) {
            $b = Get-BlockAtPoint $hx ($pl.Y + $pl.H + 2)
            if ($b) { [void](Invoke-BlockHit $b 'heavyStomp') }
        }
    }

    # ---- Springs and conveyors under your feet ----
    $pl.GroundDef = Get-GroundCellDef $pl
    $gd = $pl.GroundDef
    if ($gd -and $gd.AffectsPlayer -and -not $pl.Climbing) {
        if ($gd.Bounce -gt 0 -and $pl.OnGround) {
            $pl.VY = -$gd.Bounce * $(if ($jumpHeld) { 1.12 } else { 1.0 })
            $pl.Launched = $true; $pl.OnGround = $false
            if ($pl.Crouching) { Invoke-Knockback ([double]::NaN) $pl.VY 0 }
        }
        elseif ($gd.Conveyor -ne 0) { Move-Along $pl ($gd.Conveyor * $dt) }
    }

    # Jumping out of the water gives a boost so you can climb onto the shore
    $stillIn = if ($pl.LavaSwim) { Test-PointLava $cx ($pl.Y + $pl.H / 2) } else { Test-InLiquid $pl }
    if ($inWater -and $pl.VY -lt 0 -and $jumpHeld -and -not $stillIn) {
        $pl.VY = [math]::Min($pl.VY, -$ph.waterExitJump)
    }

    # ---- Actions ----
    if ($R.FirePressed -and (Invoke-GrabOrThrow $up)) { }                      # pick up / throw comes first
    elseif ($R.Carrying) { }
    elseif ($R.FirePressed -and $ab -and $ab.Projectile -and $R.FireCooldown -le 0) { New-Projectile }
    if ($R.DismountPressed -and $R.Mount) { Invoke-Dismount $false }
    if ($R.Mount -and -not $R.Mount.Def.CanSwim -and (Test-InLiquid $pl)) {
        Show-Toast "The $($R.Mount.Def.Name) can't swim!"
        Invoke-Dismount $false
    }

    # ---- Hazards ----
    $cx = $pl.X + $pl.W / 2
    if ($pl.Y -gt $R.HeightPx + 64) {
        if ($R.MiniGame) { Complete-MiniGameLevel 'You fell!' $true; return }
        Invoke-PlayerDeath 'YOU FELL!' $false; return
    }
    if (-not $pl.LavaSwim -and (Test-PointLava $cx ($pl.Y + $pl.H - 6))) {
        if (($R.InvincibleTimer -gt 0 -and $down) -or $lavaSafe) { $pl.LavaSwim = $true }
        else { Invoke-LavaTouch; if ($R.State -ne 'Playing') { return } }
    }
    if (-not (Test-PowerImmune 'spikes')) {
        $spike = Get-SpikeContact $pl
        if ($spike) { Invoke-SpikeTouch $spike[0] $spike[1]; if ($R.State -ne 'Playing') { return } }
    }
    $hz = Get-HazardLevel $pl
    if ($hz -eq 2) { Invoke-PlayerDeath 'OUCH!' $true; return }
    if ($hz -eq 1 -and -not (Test-PowerImmune 'hazards')) {
        # Thorns and other overlap hazards: hurt you, and always throw you out (even when invincible)
        if (-not (Invoke-PlayerHurt $true)) { Invoke-Knockback ([double]::NaN) (-$ph.hurtBounce) 0 }
        if ($R.State -ne 'Playing') { return }
    }

    # ---- Enemies (they wake up when they come near the screen) ----
    $wakeLeft = $R.CamX - 160; $wakeRight = $R.CamX + $ViewW + 160
    foreach ($en in $A.Enemies) {
        if ($en.Dead) { continue }
        if (-not $en.Active) {
            if ($en.X + $en.W -ge $wakeLeft -and $en.X -le $wakeRight) { $en.Active = $true } else { continue }
        }
        Update-Enemy $en $dt
        if ($en.Dead -or $en.SolidOn) { continue }       # ice blocks and enemy-platforms don't hurt
        if ($pl.Sleeping) { continue }                   # shh... everyone tiptoes past a sleeping hero
        if (-not (Test-Overlap $pl $en)) { continue }
        if ($R.InvincibleTimer -gt 0) { [void](Invoke-EnemyHit $en 'star'); continue }
        if ($en.Def.Contact -eq 'none') { continue }
        $stunned = $en.StunTimer -gt 0
        $prevBottom = $pl.Y + $pl.H - $pl.VY * $dt
        $fromAbove = -not $inWater -and -not $pl.Climbing -and $pl.VY -ge 0 -and $prevBottom -le $en.Y + 10
        if ($stunned -and -not $fromAbove) { continue }          # a stunned enemy is harmless to touch
        if ($en.Def.Kickable) {
            # Shells: stomp or touch a still one to kick it, stomp a moving one to stop it
            if ($fromAbove) {
                if ($en.Kicked) { $en.Kicked = $false } else { Invoke-Kick $en }
                Invoke-StompBounce $en $jumpHeld
                continue
            }
            if (-not $en.Kicked) { Invoke-Kick $en; continue }
            if ($en.KickGrace -gt 0) { continue }
        }
        elseif ($fromAbove) {
            if ($ab -and $ab.HeavyStomp -and (Test-EnemyWeak $en.Def 'heavyStomp')) {
                [void](Invoke-EnemyHit $en 'heavyStomp'); Invoke-StompBounce $en $jumpHeld; continue
            }
            switch ($en.Def.StompMode) {
                'defeat' { [void](Invoke-EnemyHit $en 'stomp'); Invoke-StompBounce $en $jumpHeld }
                'bounce' { Invoke-StompBounce $en $jumpHeld }
                default  { if ($stunned) { Invoke-StompBounce $en $jumpHeld } else { [void](Invoke-PlayerHurt $true) } }   # spiky, unless it's dizzy
            }
            if ($R.State -ne 'Playing') { return }
            continue
        }
        if ($en.HurtTimer -gt 0) { continue }
        # Bumped into it: knocked up and away from it
        [void](Invoke-PlayerHurt $true ($en.X + $en.W / 2))
        if ($R.State -ne 'Playing') { return }
    }
    Add-PendingEnemies
    Update-EnemyShots $dt
    if ($R.State -ne 'Playing') { return }

    Update-Projectiles $dt
    Update-Throwables $dt
    Add-PendingEnemies
    Update-Blocks $dt

    # ---- Items ----
    Update-Dispensers $dt
    foreach ($it in @($A.Items)) {
        if ($it.Taken) { continue }
        if ($it.Falling) {
            # Popped out of a pipe: arcs up, falls and settles on the ground
            $it.VY = [math]::Min($R.Phys.maxFall, $it.VY + $R.Phys.gravity * $dt)
            Move-Entity $it ($it.VX * $dt) ($it.VY * $dt)
            if ($it.HitX) { $it.VX = 0.0 }
            if ($it.HitTop -and $it.VY -lt 0) { $it.VY = 0.0 }
            if ($it.Y -gt $R.HeightPx + 64 -or (Test-PointLava ($it.X + $it.W / 2) ($it.Y + $it.H - 2))) { $it.Taken = $true; Remove-Sprite $it.Sprite; continue }
            if ($it.OnGround) { $it.Falling = $false; $it.VX = 0.0; $it.VY = 0.0; $it.BaseY = $it.Y - 3; $it.Clock = 0.0 }
            Set-SpritePosition $it
        }
        elseif ($it.Def.Type -ne 'coin') {
            $it.Clock += $dt
            $it.Y = $it.BaseY + [math]::Sin($it.Clock * 3) * 3
            Set-SpritePosition $it
        }
        if (($pl.X -lt $it.X + $it.W) -and ($pl.X + $pl.W -gt $it.X) -and ($pl.Y -lt $it.Y + $it.H) -and ($pl.Y + $pl.H -gt $it.Y)) {
            Invoke-Collect $it
        }
    }

    # ---- Lock blocks: touching one with the right key opens it ----
    foreach ($lk in $A.Locks) {
        if ($lk.Open) { continue }
        if (($pl.X - 3 -lt $lk.X + $lk.W) -and ($pl.X + $pl.W + 3 -gt $lk.X) -and ($pl.Y - 3 -lt $lk.Y + $lk.H) -and ($pl.Y + $pl.H + 3 -gt $lk.Y)) {
            if ([int]$R.Inv[$lk.LockId] -gt 0) { Open-Lock $lk; break }
            elseif ($script:ToastTimer -le 0) { Show-Toast "Locked. You need the $($lk.LockId) key." }
        }
    }

    # ---- Mounts waiting to be ridden ----
    $toRide = $null
    foreach ($mo in $A.Mounts) {
        if ($mo.X + $mo.W -lt $wakeLeft -or $mo.X -gt $wakeRight) { continue }
        if (-not $mo.OnGround -or $mo.VY -ne 0 -or $mo.VX -ne 0) {
            $mo.VY = [math]::Min($ph.maxFall, $mo.VY + $ph.gravity * $dt)
            Move-Entity $mo ($mo.VX * $dt) ($mo.VY * $dt)
            if ($mo.OnGround) { $mo.VY = 0.0 }
            if ($mo.HitX) { $mo.VX = 0.0 }
            # Momentum from a jump-off fades away: slowly in the air, quickly once it's on the ground
            if ($mo.VX -ne 0) {
                $slow = $(if ($mo.OnGround) { 900.0 } else { 250.0 }) * $dt
                $mo.VX = [math]::Sign($mo.VX) * [math]::Max(0.0, [math]::Abs($mo.VX) - $slow)
            }
        }
        if ($mo.Y -gt $R.HeightPx + 64) { $mo.Gone = $true; Remove-Sprite $mo.Sprite; continue }   # fell out of the level
        if (Test-PointLava ($mo.X + $mo.W / 2) ($mo.Y + $mo.H - 4)) { $mo.Gone = $true; Remove-Sprite $mo.Sprite; continue }
        if (-not $R.Mount -and $R.MountCooldown -le 0 -and -not $pl.Crouching -and -not $pl.Climbing -and (Test-Overlap $pl $mo)) {
            if ($mo.Def.CanSwim -or -not (Test-InLiquid $mo)) { $toRide = $mo }
        }
    }
    foreach ($gone in @($A.Mounts | Where-Object { $_.Gone })) { [void]$A.Mounts.Remove($gone) }
    if ($toRide) { Invoke-Mount $toRide }

    # ---- Checkpoints and goal ----
    foreach ($cp in $A.Checkpoints) {
        if (-not $cp.Active -and ($cx -ge $cp.X) -and ($cx -lt $cp.X + $cp.W) -and ($pl.Y + $pl.H -gt $cp.Y - $R.T) -and ($pl.Y -lt $cp.Y + $cp.H)) {
            Enable-Checkpoint $cp
        }
    }
    foreach ($goal in $A.Goals) {
        if (-not (Test-Overlap $pl $goal)) { continue }
        if ($R.MiniGame) { Complete-MiniGameLevel 'Made it!'; return }
        $gap = Get-RequirementGap (Get-ExitRequirement $goal.Exit)
        if ($gap) {
            if ($R.ReqToast -le 0) { Show-Toast "This exit is shut. You need to $gap."; $R.ReqToast = 2.5 }
            continue
        }
        Complete-Level $goal.Exit; return
    }

    Clear-Presses
    Update-Camera $dt
    Update-Weather $dt
    Update-Sprites $dt
    Update-Hud
}

# ---- Easter egg: leave the hero alone long enough and he dozes off, mumbling about ravioli ----
function Update-Sleep([double]$dt) {
    $R = $script:Run; $pl = $R.Player
    $after = $script:World.Player.SleepAfter
    if ($pl.Sleeping) {
        $pl.TalkTimer -= $dt
        if ($pl.TalkTimer -le 0) {
            $pl.TalkTimer = 6.0
            $pl.Line = $script:World.Player.SleepTalk | Get-Random
        }
        $z = @('z', 'zZ', 'zZz')[[int]($R.Time * 1.5) % 3]
        Set-SleepBubble "$z`n$($pl.Line)"
        return
    }
    $calm = $script:Held.Count -eq 0 -and $pl.OnGround -and -not $pl.InWater -and -not $pl.Climbing -and -not $R.Mount -and
            [math]::Abs($pl.VX) -lt 1 -and -not $R.MiniGame -and -not ($R.A.Survival -and $R.A.Survival.State -eq 'active')
    if (-not $calm -or $after -le 0) { $R.IdleTime = 0.0; return }
    $R.IdleTime += $dt
    if ($R.IdleTime -ge $after) {
        $pl.Sleeping = $true
        $pl.TalkTimer = 2.5
        $pl.Line = '...'
        Add-Record 'naps'
    }
}

function Stop-Sleeping {
    $R = $script:Run; $pl = $R.Player
    $pl.Sleeping = $false
    $R.IdleTime = 0.0
    if ($pl.Bubble) { Remove-Sprite $pl.Bubble; $pl.Bubble = $null }
    Show-Toast '*yawn* ...huh? Where did the ravioli go?'
}

# A speech bubble (sleep talk, enemies talking). Created once per speaker and moved around.
function New-SpeechBubble {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.FontSize = 12; $tb.FontStyle = 'Italic'; $tb.TextAlignment = 'Center'; $tb.TextWrapping = 'Wrap'; $tb.MaxWidth = 220
    $tb.Foreground = ConvertTo-Brush '#2B2B40'
    $border = New-Object System.Windows.Controls.Border
    $border.Background = ConvertTo-Brush '#EEFFFFFF'; $border.CornerRadius = 8; $border.Padding = '7,3'
    $border.BorderBrush = ConvertTo-Brush '#9FA8DA'; $border.BorderThickness = 1; $border.IsHitTestVisible = $false
    $border.Child = $tb
    Add-Sprite $border
    $border
}

# Puts text in a bubble and centres it above a point (the speaker's head)
function Set-SpeechBubble($Bubble, [string]$Text, [double]$CX, [double]$TopY) {
    $Bubble.Child.Text = $Text
    $Bubble.UpdateLayout()
    Set-ElementAt $Bubble ($CX - $Bubble.ActualWidth / 2) ($TopY - $Bubble.ActualHeight - 8)
}

function Set-SleepBubble([string]$Text) {
    $pl = $script:Run.Player
    if (-not $pl.Bubble) { $pl.Bubble = New-SpeechBubble }
    Set-SpeechBubble $pl.Bubble $Text ($pl.X + $pl.W / 2) $pl.Y
}

# Enemies with "talk" lines say one every so often, pausing their attacks while they speak
function Update-EnemyTalk($En, [double]$dt) {
    $def = $En.Def
    if ($def.Talk.Count -eq 0) { return }
    if ($En.TalkLeft -gt 0) {
        $En.TalkLeft -= $dt
        if ($En.TalkLeft -le 0) { if ($En.Bubble) { Remove-Sprite $En.Bubble; $En.Bubble = $null } }
        else { Show-EnemyTalk $En }
        return
    }
    $En.TalkTimer -= $dt
    if ($En.TalkTimer -gt 0 -or $En.Mode) { return }
    $En.TalkTimer = $def.TalkEvery
    $En.TalkLeft = $def.TalkTime
    $En.Line = $def.Talk[$En.TalkIndex % $def.Talk.Count]
    $En.TalkIndex++
    Show-EnemyTalk $En
}

function Show-EnemyTalk($En) {
    if (-not $En.Bubble) { $En.Bubble = New-SpeechBubble }
    Set-SpeechBubble $En.Bubble $En.Line ($En.X + $En.W / 2) $En.Y
}

function Invoke-StompBounce($En, [bool]$JumpHeld) {
    $R = $script:Run; $pl = $R.Player
    $pl.Y = [math]::Min($pl.Y, $En.Y - $pl.H)
    $pl.VY = if ($JumpHeld) { -$R.Phys.jumpSpeed * 0.85 } else { -$R.Phys.stompBounce }
    $pl.OnGround = $false
}

function Update-PlayerTimers([double]$dt) {
    $R = $script:Run
    if ($R.InvulnTimer -gt 0)   { $R.InvulnTimer -= $dt }
    if ($R.FullToast -gt 0)     { $R.FullToast -= $dt }
    if ($R.ReqToast -gt 0)      { $R.ReqToast -= $dt }
    if ($R.FireCooldown -gt 0)  { $R.FireCooldown -= $dt }
    if ($R.MountCooldown -gt 0) { $R.MountCooldown -= $dt }
    if ($R.SpeedTimer -gt 0)    { $R.SpeedTimer -= $dt }
    if ($R.InvincibleTimer -gt 0) {
        $R.InvincibleTimer -= $dt
        if ($R.InvincibleTimer -le 0) {
            # Back to whatever you had before: powered up or normal
            $form = if ($R.Power) { $R.Power.Name } else { 'normal' }
            Show-Toast "Invincibility wore off ($form)"
        }
    }
    if ($R.Power -and $R.PowerTimer -gt 0) {
        $R.PowerTimer -= $dt
        if ($R.PowerTimer -le 0) { Show-Toast "$($R.Power.Name) wore off"; Set-Power $null }
    }
}

# ---------------------------------------------------------------------------
# Enemies: mix-and-match movement
# ---------------------------------------------------------------------------
function Test-GroundAhead($En) {
    $R = $script:Run
    $fx = if ($En.Dir -gt 0) { $En.X + $En.W + 1 } else { $En.X - 1 }
    $tx = [int][math]::Floor($fx / $R.T)
    $ty = [int][math]::Floor(($En.Y + $En.H + 1) / $R.T)
    if ($tx -ge 0 -and $tx -lt $R.W -and $ty -ge 0 -and $ty -lt $R.H -and ($R.EnemySolid[$tx, $ty] -or $R.OneWayGrid[$tx, $ty])) { return $true }
    foreach ($s in $R.SolidList) {
        if ([object]::ReferenceEquals($s, $En)) { continue }
        if ($fx -ge $s.X -and $fx -lt $s.X + $s.W -and ($En.Y + $En.H + 1) -ge $s.Y -and ($En.Y + $En.H + 1) -lt $s.Y + $s.H) { return $true }
    }
    $false
}

function Update-Enemy($En, [double]$dt) {
    $R = $script:Run
    $def = $En.Def
    $mv = $def.Moves
    $pl = $R.Player
    $ph = $R.Phys
    $ox = $En.X; $oy = $En.Y
    if ($En.HurtTimer -gt 0)  { $En.HurtTimer -= $dt }
    if ($En.KickGrace -gt 0)  { $En.KickGrace -= $dt }
    if ($En.AttackAnim -gt 0) { $En.AttackAnim -= $dt }

    if ($En.Frozen) { Update-FrozenEnemy $En $dt; $En.DX = $En.X - $ox; $En.DY = $En.Y - $oy; return }

    # Stunned: it just sits there (and falls, unless it flies)
    if ($En.StunTimer -gt 0) {
        $En.StunTimer -= $dt
        if (-not $mv.Fly) {
            $En.VY = [math]::Min($ph.maxFall, $En.VY + $ph.gravity * $dt)
            Move-Entity $En 0 ($En.VY * $dt)
            if ($En.OnGround) { $En.VY = 0.0 }
        }
        $En.State = 'stunned'
        $En.DX = $En.X - $ox; $En.DY = $En.Y - $oy
        return
    }

    $dx = ($pl.X + $pl.W / 2) - ($En.X + $En.W / 2)
    $dy = ($pl.Y + $pl.H / 2) - ($En.Y + $En.H / 2)
    $sees = $En.Hunt -or (([math]::Abs($dx) -le $def.Sight) -and ([math]::Abs($dy) -le $def.Sight))
    $follows = $mv.Follow -or $En.Hunt

    # Reacting to being looked at (the player is facing toward it)
    if ($def.WhenLookedAt -and -not $En.Kicked) {
        $looked = $sees -and (([math]::Abs($dx) -lt 16) -or (($dx -lt 0) -eq ($pl.Facing -gt 0)))
        if ($def.WhenLookedAt -eq 'platform') {
            # Becomes a block you can stand on; only changes back once you're off it
            $standing = [object]::ReferenceEquals($pl.GroundSolid, $En)
            $inside = $En.AsPlatform -and (($pl.X -lt $En.X + $En.W + 2) -and ($pl.X + $pl.W -gt $En.X - 2) -and ($pl.Y -lt $En.Y + $En.H + 2) -and ($pl.Y + $pl.H -gt $En.Y - 2))
            if ($looked -or $standing -or $inside) {
                $En.AsPlatform = $true; $En.SolidOn = $true; $En.State = 'platform'; $En.DX = 0.0; $En.DY = 0.0
                return
            }
            if ($En.AsPlatform) { $En.AsPlatform = $false; $En.SolidOn = $false }
        }
        elseif ($looked) { $En.State = 'shy'; $En.DX = 0.0; $En.DY = 0.0; return }
    }

    if ($sees -and -not $pl.Sleeping) { Update-EnemyTalk $En $dt }
    elseif ($En.Bubble) { Remove-Sprite $En.Bubble; $En.Bubble = $null; $En.TalkLeft = 0.0 }
    # Attacks: a charge or a drop takes over movement while it lasts (nobody attacks a sleeping hero or while talking)
    if (-not $En.Kicked -and -not $pl.Sleeping -and $En.TalkLeft -le 0 -and (Update-EnemyAttacks $En $dt $dx $dy $sees)) {
        Test-EnemySurroundings $En
        $En.DX = $En.X - $ox; $En.DY = $En.Y - $oy
        return
    }

    $inLiquid = Test-InLiquid $En
    if (($mv.Fly -or ($mv.Swim -and $inLiquid)) -and -not $En.Kicked) {
        $chase = $follows -and $sees -and ($mv.Fly -or $pl.InWater)
        if ($chase) {
            # Head straight for the player
            $len = [math]::Max(1, [math]::Sqrt($dx * $dx + $dy * $dy))
            $mx = $dx / $len * $def.Speed * $dt
            $my = $dy / $len * $def.Speed * $dt
            if (-not $mv.Fly -and -not (Test-PointLiquid ($En.X + $En.W / 2 + $mx) ($En.Y + $En.H / 2 + $my))) { $my = 0.0 }   # stay in the water
            if ([math]::Abs($dx) -gt 2) { $En.Dir = [math]::Sign($dx) }
            Move-Entity $En $mx $my
        }
        else {
            # Drift side to side and bob
            $En.Clock += $dt
            $bob = ([math]::Sin($En.Clock * 3.0) - [math]::Sin(($En.Clock - $dt) * 3.0)) * $(if ($mv.Fly) { 10 } else { 6 })
            Move-Entity $En ($En.Dir * $def.Speed * $dt) $bob
            $turn = $En.HitX
            if (-not $mv.Fly) {
                $front = if ($En.Dir -gt 0) { $En.X + $En.W + 2 } else { $En.X - 2 }
                if (-not (Test-PointLiquid $front ($En.Y + $En.H / 2))) { $turn = $true }
            }
            if ($def.Range -gt 0) {
                $off = $En.X - $En.SpawnX
                if (($off -gt $def.Range -and $En.Dir -gt 0) -or ($off -lt -$def.Range -and $En.Dir -lt 0)) { $turn = $true }
            }
            if ($turn) { $En.Dir = -$En.Dir }
        }
        $En.VY = 0.0
        $En.State = if ($En.AttackAnim -gt 0) { 'attack' } elseif ($mv.Fly) { 'fly' } else { 'swim' }
    }
    else {
        # On the ground (a swimmer out of water just flops). Quicksand slows and sinks them.
        $enSand = Test-PointSand ($En.X + $En.W / 2) ($En.Y + $En.H - 2)
        $En.VY = [math]::Min($(if ($enSand) { $ph.sandSinkSpeed } else { $ph.maxFall }), $En.VY + $ph.gravity * $dt)
        $chasing = $follows -and $sees -and [math]::Abs($dx) -gt 6 -and -not $En.Kicked
        $speedX = 0.0
        if ($En.Kicked) { $speedX = $def.KickSpeed }
        elseif ($En.LeapVX -gt 0 -and -not $En.OnGround) { $speedX = $En.LeapVX }
        elseif ($chasing) { $En.Dir = [math]::Sign($dx); $speedX = $def.Speed }
        elseif ($mv.Patrol) { $speedX = $def.Speed }
        if ($mv.Swim -and -not $En.Kicked) { $speedX = 0.0 }
        if ($enSand) { $speedX *= $ph.sandSpeed }
        if ($pl.Sleeping -and -not $En.Kicked) { $speedX *= 0.35; $chasing = $false }   # tiptoeing
        $gd = Get-GroundCellDef $En
        if ($gd -and $gd.AffectsEnemies) { $speedX *= $gd.SpeedMult }
        if ($speedX -gt 0 -and $def.TurnAtEdges -and $En.OnGround -and -not $mv.Jump -and -not $En.Kicked -and $En.LeapVX -le 0 -and -not (Test-GroundAhead $En)) {
            if ($chasing) { $speedX = 0.0 } else { $En.Dir = -$En.Dir }
        }
        if ($mv.Jump -and $En.OnGround -and -not $En.Kicked) {
            $En.JumpTimer -= $dt
            if ($En.JumpTimer -le 0) { $En.VY = -$def.JumpSpeed; $En.JumpTimer = $def.JumpInterval }
        }
        Move-Entity $En ($En.Dir * $speedX * $dt) ($En.VY * $dt)
        if ($En.OnGround -or $En.HitTop) { $En.VY = 0.0 }
        if ($En.OnGround) { $En.LeapVX = 0.0 }
        if ($En.HitX) {
            if ($En.Kicked) {
                $blk = Get-BlockAtPoint $(if ($En.Dir -gt 0) { $En.X + $En.W + 2 } else { $En.X - 2 }) ($En.Y + $En.H / 2)
                if ($blk) { [void](Invoke-BlockHit $blk 'shell') }
            }
            if (-not $chasing) { $En.Dir = -$En.Dir }
        }
        if ($mv.Patrol -and -not $chasing -and -not $En.Kicked -and $def.Range -gt 0) {
            $off = $En.X - $En.SpawnX
            if (($off -gt $def.Range -and $En.Dir -gt 0) -or ($off -lt -$def.Range -and $En.Dir -lt 0)) { $En.Dir = -$En.Dir }
        }
        # Springs and conveyors under its feet
        $gd = Get-GroundCellDef $En
        if ($gd -and $gd.AffectsEnemies) {
            if ($gd.Bounce -gt 0) { $En.VY = -$gd.Bounce; $En.OnGround = $false }
            elseif ($gd.Conveyor -ne 0) { Move-Along $En ($gd.Conveyor * $dt) }
        }
        $En.State = if ($En.AttackAnim -gt 0) { 'attack' } elseif (-not $En.OnGround) { 'jump' } elseif ($speedX -gt 0) { 'move' } else { 'idle' }
    }
    # A kicked shell knocks out every enemy it runs into
    if ($En.Kicked) {
        foreach ($other in $R.A.Enemies) {
            if ($other.Dead -or [object]::ReferenceEquals($other, $En) -or -not $other.Active -or $other.SolidOn) { continue }
            if (Test-Overlap $En $other) { [void](Invoke-EnemyHit $other 'shell') }
        }
    }
    Test-EnemySurroundings $En
    $En.DX = $En.X - $ox; $En.DY = $En.Y - $oy
}

# Falling off the map, lava and enemy-deadly tiles
function Test-EnemySurroundings($En) {
    $R = $script:Run
    if ($En.Dead) { return }
    if ($En.Y -gt $R.HeightPx + 64) { Invoke-EnemyDefeat $En; return }
    $cx = $En.X + $En.W / 2
    if ((Test-PointLava $cx ($En.Y + $En.H - 4)) -and (Test-EnemyWeak $En.Def 'lava')) { [void](Invoke-EnemyHit $En 'lava'); return }
    $tx = [int][math]::Floor($cx / $R.T)
    foreach ($py in @(($En.Y + $En.H - 4), ($En.Y + $En.H + 1))) {
        $ty = [int][math]::Floor($py / $R.T)
        if ($tx -ge 0 -and $ty -ge 0 -and $tx -lt $R.W -and $ty -lt $R.H -and $R.EnemyHazard[$tx, $ty]) { [void](Invoke-EnemyHit $En 'hazard'); return }
    }
}

# ---- Ice blocks ----
function Invoke-Freeze($En, $Power) {
    if ($En.Frozen -or $En.Dead -or -not $En.Def.Freezable) { return $false }
    $R = $script:Run; $ts = $R.T
    $bw = [math]::Max($En.W, $ts); $bh = [math]::Max($En.H, $ts)
    $nx = $En.X + $En.W / 2 - $bw / 2; $ny = $En.Y + $En.H - $bh
    if (Test-RectSolid $nx $ny $bw $bh $En) { $bw = $En.W; $bh = $En.H; $nx = $En.X; $ny = $En.Y }   # no room to grow
    $En.OrigW = $En.W; $En.OrigH = $En.H
    $En.X = $nx; $En.Y = $ny; $En.W = $bw; $En.H = $bh
    $En.Frozen = $true; $En.FreezeTimer = $Power.FreezeTime
    $En.SolidOn = $true; $En.Pushable = $true; $En.AsPlatform = $false
    $En.VX = 0.0; $En.VY = 0.0
    $En.IceSprite = New-BoxSprite (Get-WorldImage $Power.IceImage) $bw $bh '#AA9FE6FF' $bw $true
    $En.IceSprite.Opacity = 0.85
    Add-Sprite $En.IceSprite
    Set-ElementAt $En.IceSprite $En.X $En.Y
    $true
}

function Invoke-Thaw($En) {
    $cx = $En.X + $En.W / 2; $bottom = $En.Y + $En.H
    $En.W = $En.OrigW; $En.H = $En.OrigH
    $En.X = $cx - $En.W / 2; $En.Y = $bottom - $En.H
    $En.Frozen = $false; $En.SolidOn = $false; $En.Pushable = $false; $En.VY = 0.0
    Remove-Sprite $En.IceSprite
    $En.IceSprite = $null
}

function Update-FrozenEnemy($En, [double]$dt) {
    $R = $script:Run; $pl = $R.Player
    $En.VY = [math]::Min($R.Phys.maxFall, $En.VY + $R.Phys.gravity * $dt)
    Move-Entity $En 0 ($En.VY * $dt)
    if ($En.OnGround) { $En.VY = 0.0 }
    if ($En.Y -gt $R.HeightPx + 64) { Invoke-EnemyDefeat $En; return }
    if (Test-PointLava ($En.X + $En.W / 2) ($En.Y + $En.H - 4)) { Invoke-EnemyDefeat $En; return }    # melts
    $En.FreezeTimer -= $dt
    if ($En.FreezeTimer -le 0) {
        # Only thaws once the player is off it and not touching it
        $busy = [object]::ReferenceEquals($pl.GroundSolid, $En) -or
                (($pl.X -lt $En.X + $En.W + 2) -and ($pl.X + $pl.W -gt $En.X - 2) -and ($pl.Y -lt $En.Y + $En.H + 2) -and ($pl.Y + $pl.H -gt $En.Y - 2))
        if (-not $busy) { Invoke-Thaw $En }
    }
}

# ---------------------------------------------------------------------------
# Blocks: breakable, ? blocks, crumbling, switches, switch-controlled blocks and survival gates
# ---------------------------------------------------------------------------
function New-Block($A, $Def, [int]$X, [int]$Y) {
    $R = $script:Run; $ts = $R.T
    $kind = if ($Def.Breakable) { 'break' } elseif ($Def.Bump) { 'bump' } elseif ($Def.Switch) { 'switch' }
            elseif ($Def.Crumble) { 'crumble' } elseif ($Def.Toggle) { 'toggle' } else { 'gate' }
    $id = "block|$($A.Id)|$X|$Y"
    $b = @{ Id = $id; Def = $Def; Kind = $kind; CellX = $X; CellY = $Y; X = $X * $ts; Y = $Y * $ts; W = $ts; H = $ts
            IsSolid = $false; Want = $false; Timer = 0.0; State = ''; Used = 0; Gone = $false; BumpTime = 0.0 }
    if ($kind -eq 'bump') {
        for ($i = 0; $i -lt $Def.Bump.Count; $i++) { if (Test-Used "$id|$i") { $b.Used++ } }
    }
    $color = switch ($kind) { 'toggle' { '#E53935' } 'gate' { '#7E57C2' } 'switch' { '#FFB300' } 'bump' { '#FFC83D' } default { '#B5653A' } }
    $b.Sprite = New-Sprite (Get-TileBitmap $Def) $ts $ts (Get-OrDefault $Def.Color $color)
    $b.Sprite.Width = $ts; $b.Sprite.Height = $ts
    if ($kind -eq 'bump' -and $b.Used -ge $Def.Bump.Count) { Set-BlockUsedLook $b }
    $start = switch ($kind) {
        'toggle' { $false }                                      # set right after the area is built
        'gate'   { $Def.Gate -eq 'until' -and -not ($A.Survival -and $A.Survival.State -eq 'done') }
        default  { $true }
    }
    Set-BlockSolid $A $b $start $true
    $b
}

function Set-BlockUsedLook($Blk) {
    $Blk.State = 'used'
    $becomes = Get-SymbolDef "$($Blk.Def.Bump.Becomes)" 'tile'
    $bmp = Get-TileBitmap $becomes
    if ($bmp -and $Blk.Sprite.Tag.IsImage) { $Blk.Sprite.Source = $bmp }
    elseif (-not $Blk.Sprite.Tag.IsImage) { $Blk.Sprite.Fill = ConvertTo-Brush $(if ($becomes -and $becomes.Color) { $becomes.Color } else { '#8D6E63' }) }
    else { $Blk.Sprite.Opacity = 0.6 }
}

# Turns a block on or off. A block that would close on the player waits until they've moved away.
function Set-BlockSolid($A, $Blk, [bool]$On, [bool]$Force = $false) {
    if ($On -and -not $Force) {
        $pl = $script:Run.Player
        if ($pl -and (Test-Overlap $pl $Blk)) { $Blk.Want = $true; return }
    }
    $Blk.Want = $false
    $Blk.IsSolid = $On
    $for = $Blk.Def.SolidFor
    if ($for -ne 'enemies') { $A.Solid[$Blk.CellX, $Blk.CellY] = $On }
    if ($for -ne 'player')  { $A.EnemySolid[$Blk.CellX, $Blk.CellY] = $On }
    $Blk.Sprite.Opacity = if ($On) { 1.0 } elseif ($Blk.Kind -eq 'toggle') { 0.28 } else { 0.0 }
}

function Update-ToggleBlock($A, $Blk) {
    $R = $script:Run
    $want = $Blk.Def.Toggle.StartSolid -xor [bool]$R.Switches[$Blk.Def.Toggle.Group]
    if ($want -ne $Blk.IsSolid -or ($Blk.Want -and -not $want)) { Set-BlockSolid $A $Blk $want }
}

# Gates close while a survival fight is on ("during") or stay shut until it has been survived ("until")
function Update-Gates($A) {
    $state = if ($A.Survival) { $A.Survival.State } else { '' }
    foreach ($b in $A.Blocks) {
        if ($b.Kind -ne 'gate') { continue }
        $want = if ($b.Def.Gate -eq 'during') { $state -eq 'active' } else { $state -ne 'done' }
        if ($want -ne $b.IsSolid) { Set-BlockSolid $A $b $want }
    }
}

# Something hit a block. How: head, powerHead, heavyStomp, shell, or projectile (with Element).
function Invoke-BlockHit($Blk, [string]$How, [string]$Element = '') {
    $R = $script:Run; $A = $R.A
    if ($Blk.Gone -or -not $Blk.IsSolid) { return $false }
    $def = $Blk.Def
    $bumped = $How -in 'head', 'powerHead', 'shell'
    switch ($Blk.Kind) {
        'break' {
            $by = $def.Breakable.By
            $breaks = switch ($How) {
                'head'       { $by.Contains('head') }
                'powerHead'  { $by.Contains('head') -or $by.Contains('powerHead') }
                'heavyStomp' { $by.Contains('heavyStomp') -or $by.Contains('stomp') }
                'shell'      { $by.Contains('shell') }
                'projectile' { $by.Contains('projectile') -or ($Element -and $by.Contains($Element)) }
                default      { $false }
            }
            if ($breaks) { Invoke-BlockBreak $A $Blk; return $true }
        }
        'bump' {
            if ($bumped -and $Blk.Used -lt $def.Bump.Count) {
                $i = $Blk.Used; $Blk.Used++
                $id = "$($Blk.Id)|$i"
                $give = Get-SymbolDef "$($def.Bump.Gives)" 'item'
                if ($give -and $give.Type -eq 'coin') { [void]$R.Pending.Add(@{ Id = $id; Kind = 'coin'; Value = $give.Value; Sym = $give.Key }); Show-Toast "+$($give.Value) coin" }
                else {
                    [void]$R.Pending.Add(@{ Id = $id; Kind = 'bumped' })
                    if ($give) { Add-ItemNow (New-ItemRuntime $give "$id|item" ($Blk.X + $Blk.W / 2) ($Blk.Y - $R.T / 2)) }
                }
                if ($Blk.Used -ge $def.Bump.Count) { Set-BlockUsedLook $Blk }
            }
        }
        'switch' {
            if ($bumped) {
                $g = $def.Switch
                $R.Switches[$g] = -not [bool]$R.Switches[$g]
                foreach ($areaRt in $R.Areas.Values) { foreach ($b in $areaRt.Blocks) { if ($b.Kind -eq 'toggle' -and $b.Def.Toggle.Group -eq $g) { Update-ToggleBlock $areaRt $b } } }
                Show-Toast "Switch! ($g)"
            }
        }
    }
    if ($bumped) {
        $Blk.BumpTime = 0.15
        # Enemies standing on a block that gets bumped from below are knocked out
        foreach ($en in $A.Enemies) {
            if ($en.Dead -or -not $en.Active) { continue }
            if ([math]::Abs(($en.Y + $en.H) - $Blk.Y) -lt 3 -and $en.X -lt $Blk.X + $Blk.W -and $en.X + $en.W -gt $Blk.X) { [void](Invoke-EnemyHit $en 'block') }
        }
        return $true
    }
    $false
}

function Invoke-BlockBreak($A, $Blk) {
    $R = $script:Run
    Set-BlockSolid $A $Blk $false $true
    $Blk.Gone = $true
    Remove-Sprite $Blk.Sprite
    $A.BlockAt[$Blk.CellX, $Blk.CellY] = $null
    $drop = Get-SymbolDef "$($Blk.Def.Breakable.Drop)" 'item'
    if ($drop) {
        $id = "$($Blk.Id)|drop"
        if (-not (Test-Used $id)) { Add-ItemNow (New-ItemRuntime $drop $id ($Blk.X + $Blk.W / 2) ($Blk.Y + $Blk.H / 2)) }
    }
}

# The block at a pixel position, if any
function Get-BlockAtPoint([double]$PX, [double]$PY) {
    $R = $script:Run
    $tx = [int][math]::Floor($PX / $R.T); $ty = [int][math]::Floor($PY / $R.T)
    if ($tx -lt 0 -or $ty -lt 0 -or $tx -ge $R.W -or $ty -ge $R.H) { return $null }
    $R.A.BlockAt[$tx, $ty]
}

# Crumbling blocks, blocks waiting for room to close, and the little bump hop
function Update-Blocks([double]$dt) {
    $R = $script:Run; $A = $R.A; $pl = $R.Player
    foreach ($b in $A.Blocks) {
        if ($b.Gone) { continue }
        if ($b.Want -and -not (Test-Overlap $pl $b)) { Set-BlockSolid $A $b $true $true }
        if ($b.Kind -eq 'crumble') {
            $standing = $b.IsSolid -and $pl.OnGround -and [math]::Abs(($pl.Y + $pl.H) - $b.Y) -lt 2 -and $pl.X -lt $b.X + $b.W -and $pl.X + $pl.W -gt $b.X
            switch ($b.State) {
                '' { if ($standing) { $b.State = 'shaking'; $b.Timer = $b.Def.Crumble.Delay } }
                'shaking' {
                    $b.Timer -= $dt
                    Set-ElementAt $b.Sprite ($b.X + [math]::Sin($R.Time * 70) * 2) $b.Y
                    if ($b.Timer -le 0) {
                        Set-BlockSolid $A $b $false $true
                        $b.State = 'gone'; $b.Timer = $b.Def.Crumble.Respawn
                        Set-ElementAt $b.Sprite $b.X $b.Y
                    }
                }
                'gone' {
                    if ($b.Def.Crumble.Respawn -le 0) { break }
                    $b.Timer -= $dt
                    if ($b.Timer -le 0) { Set-BlockSolid $A $b $true; if ($b.IsSolid -or $b.Want) { $b.State = '' } }
                }
            }
        }
        if ($b.BumpTime -gt 0) {
            $b.BumpTime -= $dt
            Set-ElementAt $b.Sprite $b.X ($b.Y - $(if ($b.BumpTime -gt 0) { 6 * [math]::Sin($b.BumpTime / 0.15 * [math]::PI) } else { 0 }))
        }
    }
}

# Adds an item while the game runs (from a block, an enemy or a survival reward)
function Add-ItemNow($Item) {
    $R = $script:Run
    if (Test-Used $Item.Id) { return }
    foreach ($p in $R.Pending) { if ($p.Id -eq $Item.Id) { return } }
    [void]$R.A.Items.Add($Item)
    Add-Sprite $Item.Sprite
    Set-SpritePosition $Item
}

# ---------------------------------------------------------------------------
# Ground under an entity, ladders, one-way tiles
# ---------------------------------------------------------------------------
# The special tile (ice, spring, conveyor...) something is standing on, if any
function Get-GroundCellDef($Ent) {
    if (-not $Ent.OnGround -or $Ent.GroundSolid) { return $null }
    $R = $script:Run
    $ty = [int][math]::Floor(($Ent.Y + $Ent.H + 1) / $R.T)
    if ($ty -lt 0 -or $ty -ge $R.H) { return $null }
    foreach ($px in @(($Ent.X + $Ent.W / 2), ($Ent.X + 2), ($Ent.X + $Ent.W - 2))) {
        $tx = [int][math]::Floor($px / $R.T)
        if ($tx -lt 0 -or $tx -ge $R.W) { continue }
        $d = $R.Cell[$tx, $ty]
        if ($d) { return $d }
        if ($R.Solid[$tx, $ty] -or $R.OneWayGrid[$tx, $ty]) { if ($px -eq ($Ent.X + $Ent.W / 2)) { return $null } }
    }
    $null
}

function Test-ClimbAt([double]$PX, [double]$PY) {
    $R = $script:Run
    $tx = [int][math]::Floor($PX / $R.T); $ty = [int][math]::Floor($PY / $R.T)
    $tx -ge 0 -and $ty -ge 0 -and $tx -lt $R.W -and $ty -lt $R.H -and $R.Climb[$tx, $ty]
}

# Moves something sideways with whatever it's standing on (conveyors), keeping it on the ground
function Move-Along($Ent, [double]$DX) {
    $on = $Ent.OnGround; $gs = $Ent.GroundSolid
    Move-Entity $Ent $DX 0
    $Ent.OnGround = $on; $Ent.GroundSolid = $gs
}

# ---------------------------------------------------------------------------
# Hitting enemies
# ---------------------------------------------------------------------------
# Attack: stomp, heavyStomp, star, shell, block, hazard, lava, or a projectile's element (fire, ice, ...)
# Effect: defeat (one hit point), freeze, stun or none. Returns $true if the enemy was affected.
function Invoke-EnemyHit($En, [string]$Attack, [string]$Effect = 'defeat', $Shot = $null) {
    if ($En.Dead) { return $false }
    $def = $En.Def
    if ($En.Frozen) {
        if ($Effect -eq 'freeze' -or $Attack -eq 'stomp') { return $false }
        Invoke-EnemyDefeat $En; return $true                     # the ice block shatters
    }
    if ($Attack -ne 'stomp' -and -not (Test-EnemyWeak $def $Attack)) { return $false }
    if ($def.HitEffects.ContainsKey($Attack)) { $Effect = $def.HitEffects[$Attack] }   # e.g. thrown blocks only stun it
    switch ($Effect) {
        'freeze' { return (Invoke-Freeze $En $Shot) }
        'stun'   {
            $En.StunTimer = if ($Shot -and $Shot.StunTime) { $Shot.StunTime } else { $def.StunTime }
            $En.Kicked = $false; $En.Mode = ''; Hide-ThoughtBubble $En
            return $true
        }
        'none'   { return $false }
    }
    # Some enemies (bosses) can only be hurt at certain moments
    if ($Attack -notin 'lava', 'hazard') {
        $open = switch ($def.VulnerableWhen) {
            'talking'  { $En.TalkLeft -gt 0 }
            'stunned'  { $En.StunTimer -gt 0 }
            'thinking' { $En.Mode -eq 'think' }
            default    { $true }
        }
        if (-not $open) { return $false }
    }
    $instant = $Attack -in 'lava', 'hazard' -or ($Attack -eq 'star' -and -not $def.Boss)
    if ($En.HurtTimer -gt 0 -and -not $instant) { return $false }
    $En.Health -= $(if ($instant) { $En.Health } else { 1 })
    $En.StunTimer = 0.0                                          # a hit wakes it up: stun it again for the next one
    if ($En.Health -gt 0) {
        $En.HurtTimer = 0.6
        if ($En.TalkLeft -gt 0) { $En.TalkLeft = 0.01 }          # a hit cuts it off mid-sentence
        if ($def.OnHit) { Invoke-EnemyChange $En $def.OnHit }
        return $true
    }
    Invoke-EnemyDefeat $En
    $true
}

# Out of hit points (or fell, or melted): drops what it carries, then vanishes or changes form
function Invoke-EnemyDefeat($En) {
    $R = $script:Run
    if ($En.Dead) { return }
    $def = $En.Def
    $R.Defeated++
    $R.DefeatedBy[$def.Key] = [int]$R.DefeatedBy[$def.Key] + 1
    Add-Record 'enemies'
    if ($def.Boss -and -not ($def.OnDefeat -and $def.OnDefeat.Becomes)) { Add-Record 'bosses' $def.Name }
    if (-not $En.Dispenser) { Invoke-TetrominoChance $En }
    $fell = $En.Y -gt $R.HeightPx
    $k = 0
    foreach ($c in $(if ($En.Dispenser) { @() } else { @($def.Carries) + @($(if ($def.OnDefeat) { $def.OnDefeat.Drop })) })) {
        if (-not $c) { continue }
        $item = Get-SymbolDef "$c" 'item'
        if (-not $item) { continue }
        $id = "drop|$($En.Origin)|$($def.Key)|$k"; $k++
        $cx = $En.X + $En.W / 2; $cy = $En.Y + $En.H / 2
        if ($fell -and $En.Origin -match '^[^|]+\|(\d+)\|(\d+)$') { $cx = ([int]$Matches[1] + 0.5) * $R.T; $cy = ([int]$Matches[2] + 0.5) * $R.T }
        Add-ItemNow (New-ItemRuntime $item $id $cx ($cy - 4 * $k))
    }
    if ($def.Boss) { Show-Toast $(if ($def.OnDefeat -and $def.OnDefeat.Becomes) { "$($def.Name) isn't done yet!" } else { "$($def.Name) defeated!" }) }
    if ($def.OnDefeat -and $def.OnDefeat.Becomes -and -not $fell) { [void](Invoke-EnemyChange $En @{ Becomes = $def.OnDefeat.Becomes; Drop = $null }) }
    else { Remove-Enemy $En }
}

# Drops an item and/or turns the enemy into another kind (a knight losing its armour, a turtle into a shell...)
function Invoke-EnemyChange($En, $Change) {
    $R = $script:Run
    if ($Change.Drop -and -not $En.Dispenser) {          # things from a pipe never drop loot (no farming)
        $item = Get-SymbolDef "$($Change.Drop)" 'item'
        if ($item) { Add-ItemNow (New-ItemRuntime $item "drop|$($En.Origin)|$($En.Def.Key)|hit$($En.Health)" ($En.X + $En.W / 2) ($En.Y - 6)) }
    }
    $newDef = Get-SymbolDef "$($Change.Becomes)" 'enemy'
    if (-not $newDef) { return $null }
    $new = New-EnemyRuntime $newDef ($En.X + $En.W / 2) ($En.Y + $En.H) $En.Origin
    $new.Dir = $En.Dir; $new.Active = $true; $new.Hunt = $En.Hunt; $new.HurtTimer = 0.4; $new.KickGrace = 0.3
    Remove-Enemy $En
    [void]$R.NewEnemies.Add($new)
    Add-Sprite $new.Sprite
    Set-SpritePosition $new
    $new
}

function Remove-Enemy($En) {
    $En.Dead = $true
    $En.SolidOn = $false
    Remove-Sprite $En.Sprite
    if ($En.Bubble) { Remove-Sprite $En.Bubble; $En.Bubble = $null }
    Hide-ThoughtBubble $En
    if ($En.IceSprite) { Remove-Sprite $En.IceSprite; $En.IceSprite = $null }
}

# New enemies (form changes, survival spawns) join the list once the frame's enemy loop is done
function Add-PendingEnemies {
    $R = $script:Run
    if ($R.NewEnemies.Count -eq 0) { return }
    foreach ($e in $R.NewEnemies) { [void]$R.A.Enemies.Add($e) }
    $R.NewEnemies.Clear()
    if ($R.A.Enemies.Count -gt 150) { foreach ($d in @($R.A.Enemies | Where-Object { $_.Dead })) { [void]$R.A.Enemies.Remove($d) } }
}

function Invoke-Kick($En) {
    $R = $script:Run; $pl = $R.Player
    $side = [math]::Sign(($En.X + $En.W / 2) - ($pl.X + $pl.W / 2))
    if ($side -eq 0) { $side = $pl.Facing }
    $En.Dir = $side; $En.Kicked = $true; $En.KickGrace = 0.3; $En.Active = $true
}

# ---------------------------------------------------------------------------
# Enemy attacks
# ---------------------------------------------------------------------------
# Returns $true when an attack (a charge or a drop) is moving the enemy this frame
function Update-EnemyAttacks($En, [double]$dt, [double]$dx, [double]$dy, [bool]$Sees) {
    $def = $En.Def
    if ($def.Attacks.Count -eq 0) { return $false }
    $R = $script:Run; $ph = $R.Phys
    if ($En.Mode) {
        $a = $def.Attacks[$En.ModeIndex]
        switch ($En.Mode) {
            'windup' {
                $En.ModeTimer -= $dt; $En.State = 'windup'
                if (-not $def.Moves.Fly) { $En.VY = [math]::Min($ph.maxFall, $En.VY + $ph.gravity * $dt); Move-Entity $En 0 ($En.VY * $dt); if ($En.OnGround) { $En.VY = 0.0 } }
                if ($En.ModeTimer -le 0) { $En.Mode = 'charge'; $En.ModeTimer = $a.Duration }
            }
            'charge' {
                $En.ModeTimer -= $dt; $En.State = 'charge'
                $vy = 0.0
                if (-not $def.Moves.Fly) { $En.VY = [math]::Min($ph.maxFall, $En.VY + $ph.gravity * $dt); $vy = $En.VY * $dt }
                Move-Entity $En ($En.Dir * $a.Speed * $dt) $vy
                if ($En.OnGround) { $En.VY = 0.0 }
                if ($En.HitX) {
                    $blk = Get-BlockAtPoint $(if ($En.Dir -gt 0) { $En.X + $En.W + 2 } else { $En.X - 2 }) ($En.Y + $En.H / 2)
                    if ($blk) { [void](Invoke-BlockHit $blk 'shell') }
                }
                if ($En.HitX -or $En.ModeTimer -le 0) { $En.Mode = ''; $En.AttackTimers[$En.ModeIndex] = $a.Cooldown }
            }
            'fall' {
                $En.State = 'drop'
                Move-Entity $En 0 ($a.Speed * $dt)
                if ($En.OnGround -or $En.Y -gt $R.HeightPx) { $En.Mode = 'wait'; $En.ModeTimer = $a.Wait }
            }
            'wait' { $En.State = 'idle'; $En.ModeTimer -= $dt; if ($En.ModeTimer -le 0) { $En.Mode = 'rise' } }
            'think' {
                $En.State = 'think'
                $En.ModeTimer -= $dt
                Show-ThoughtBubble $En $En.ThinkImage
                if ($En.ModeTimer -le 0) {
                    $b = $En.ThinkRect
                    New-EnemyShot $En $a ($b.X + $b.W / 2) ($b.Y + $b.H / 2) $En.ThinkImage
                    Hide-ThoughtBubble $En
                    $En.Mode = ''; $En.AttackTimers[$En.ModeIndex] = $a.Interval; $En.AttackAnim = 0.3
                }
                return $false        # it keeps moving while it thinks
            }
            'rise' {
                $En.State = 'idle'
                $step = [math]::Min($a.Rise * $dt, $En.Y - $En.HomeY)
                Move-Entity $En 0 (-$step)
                if ($En.Y -le $En.HomeY + 0.5 -or $En.HitTop) { $En.Mode = ''; $En.AttackTimers[$En.ModeIndex] = 0.4 }
            }
        }
        return $true
    }
    $dist = [math]::Sqrt($dx * $dx + $dy * $dy)
    for ($i = 0; $i -lt $def.Attacks.Count; $i++) {
        $a = $def.Attacks[$i]
        if ($En.AttackTimers[$i] -gt 0) { $En.AttackTimers[$i] -= $dt; continue }
        switch ($a.Type) {
            'shoot' {
                if ($Sees -and $dist -le $a.Range) { New-EnemyShot $En $a; $En.AttackTimers[$i] = $a.Interval; $En.AttackAnim = 0.3 }
            }
            'think' {
                if ($Sees -and $dist -le $a.Range) {
                    $En.Mode = 'think'; $En.ModeIndex = $i; $En.ModeTimer = $a.Think
                    $En.ThinkImage = if ($a.Images.Count) { $a.Images | Get-Random } else { $a.Image }
                    Show-ThoughtBubble $En $En.ThinkImage
                    return $false
                }
            }
            'charge' {
                if ($Sees -and [math]::Abs($dx) -le $a.Range -and [math]::Abs($dy) -lt $En.H + 24 -and ($En.OnGround -or $def.Moves.Fly)) {
                    $En.Mode = 'windup'; $En.ModeIndex = $i; $En.ModeTimer = $a.Windup
                    if ([math]::Abs($dx) -gt 2) { $En.Dir = [math]::Sign($dx) }
                    return $true
                }
            }
            'drop' {
                if ($dy -gt 0 -and [math]::Abs($dx) -le $a.Range + $En.W / 2) {
                    $En.Mode = 'fall'; $En.ModeIndex = $i; $En.HomeY = $En.Y
                    return $true
                }
            }
            'leap' {
                if ($Sees -and $En.OnGround -and [math]::Abs($dx) -le $a.Range) {
                    $En.VY = -$a.Speed; $En.LeapVX = $a.Forward; $En.OnGround = $false
                    if ([math]::Abs($dx) -gt 2) { $En.Dir = [math]::Sign($dx) }
                    $En.AttackTimers[$i] = $a.Cooldown
                }
            }
        }
    }
    $false
}

function New-EnemyShot($En, $A, [double]$FromX = [double]::NaN, [double]$FromY = [double]::NaN, [string]$Image = '') {
    $R = $script:Run; $pl = $R.Player
    $cx = $En.X + $En.W / 2; $cy = $En.Y + $En.H * 0.4
    if (-not [double]::IsNaN($FromX)) { $cx = $FromX; $cy = $FromY }
    $base = switch ($A.Aim) {
        'player'  { [math]::Atan2(($pl.Y + $pl.H / 2) - $cy, ($pl.X + $pl.W / 2) - $cx) }
        'forward' { if ($En.Dir -gt 0) { 0.0 } else { [math]::PI } }
        'up'      { -[math]::PI / 2 }
        'down'    { [math]::PI / 2 }
        'left'    { [math]::PI }
        default   { 0.0 }
    }
    if ($A.Aim -eq 'player') { $En.Dir = if ([math]::Cos($base) -lt 0) { -1 } else { 1 } }
    for ($k = 0; $k -lt $A.Count; $k++) {
        $ang = $base + ($k - ($A.Count - 1) / 2) * $A.Spread * [math]::PI / 180
        $s = $A.Size
        $shot = @{ X = $cx - $s / 2; Y = $cy - $s / 2; W = $s; H = $s; VX = [math]::Cos($ang) * $A.Speed; VY = [math]::Sin($ang) * $A.Speed
                   Life = $A.Life; Def = $A }
        $img = if ($Image) { $Image } elseif ($A.Images.Count) { $A.Images | Get-Random } else { $A.Image }
        $shot.Image = $img
        $bmp = Get-WorldImage $img
        $shot.Spin = $A.Spin
        $shot.Sprite = New-Sprite $bmp $s $s $A.Color
        if ($bmp) { $shot.W = [math]::Max($s, $bmp.PixelWidth * 0.8); $shot.H = [math]::Max($s, $bmp.PixelHeight * 0.8); $shot.X = $cx - $shot.W / 2; $shot.Y = $cy - $shot.H / 2 }
        Add-Sprite $shot.Sprite
        [void]$R.EnemyShots.Add($shot)
    }
}

function Update-EnemyShots([double]$dt) {
    $R = $script:Run; $pl = $R.Player
    for ($i = $R.EnemyShots.Count - 1; $i -ge 0; $i--) {
        $s = $R.EnemyShots[$i]
        if ($s.HitsOwner) {
            # A piece falling out of its own thought bubble onto its head
            $s.VY += $R.Phys.gravity * 0.5 * $dt; $s.Y += $s.VY * $dt; $s.Life -= $dt
            $o = $s.HitsOwner
            $done = $s.Life -le 0 -or $o.Dead -or $s.Y -gt $o.Y + $o.H
            if (-not $done -and $s.Y + $s.H -ge $o.Y) { [void](Invoke-EnemyHit $o 'thought'); $done = $true }
            if ($done) { Remove-Sprite $s.Sprite; $R.EnemyShots.RemoveAt($i) }
            else { Set-ElementAt $s.Sprite $s.X $s.Y; $s.Sprite.Tag.Rotate.Angle = ($s.Sprite.Tag.Rotate.Angle + 400 * $dt) % 360 }
            continue
        }
        if ($s.Def.Gravity) { $s.VY = [math]::Min(900, $s.VY + $R.Phys.gravity * $dt) }
        $s.X += $s.VX * $dt; $s.Y += $s.VY * $dt; $s.Life -= $dt
        $hitWall = Test-RectSolid ($s.X + 2) ($s.Y + 2) ([math]::Max(1, $s.W - 4)) ([math]::Max(1, $s.H - 4))
        $gone = $s.Life -le 0 -or $s.X -lt -64 -or $s.X -gt $R.WidthPx + 64 -or $s.Y -gt $R.HeightPx + 64 -or $hitWall
        # Shots that "leave" a throwable turn into one where they land
        if ($hitWall -and $s.Def.Leaves -and @($R.A.Throwables | Where-Object { -not $_.Gone }).Count -lt 10) {
            $tdef = @{ Name = 'Block'; Image = $s.Image; Color = $s.Def.Color; Width = [math]::Max(16, $s.W * 0.9); Height = [math]::Max(16, $s.H * 0.9) }
            $bx = $s.X + $s.W / 2 - $s.VX * $dt; $by = $s.Y + $s.H / 2 - $s.VY * $dt
            $th = New-Throwable $tdef $bx ($by + $tdef.Height / 2) 15
            if (-not (Test-RectSolid $th.X $th.Y $th.W $th.H)) { Add-ThrowableNow $th }
        }
        if (-not $gone -and $R.State -eq 'Playing' -and ($pl.X -lt $s.X + $s.W - 2) -and ($pl.X + $pl.W -gt $s.X + 2) -and ($pl.Y -lt $s.Y + $s.H - 2) -and ($pl.Y + $pl.H -gt $s.Y + 2)) {
            $gone = $true
            $immune = $R.InvincibleTimer -gt 0 -or ($s.Def.Element -and (Test-PowerImmune $s.Def.Element))
            if (-not $immune) { [void](Invoke-PlayerHurt $true ($s.X + $s.W / 2)) }
        }
        if ($gone) { Remove-Sprite $s.Sprite; $R.EnemyShots.RemoveAt($i) }
        else {
            Set-ElementAt $s.Sprite ($s.X + $s.W / 2 - $s.Sprite.Width / 2) ($s.Y + $s.H / 2 - $s.Sprite.Height / 2)
            if ($s.Spin) { $s.Sprite.Tag.Rotate.Angle = ($s.Sprite.Tag.Rotate.Angle + $s.Spin * $dt) % 360 }
        }
    }
}

# ---------------------------------------------------------------------------
# Survival: hold out until the timer runs down while enemies pour in
# ---------------------------------------------------------------------------
function Update-Survival([double]$dt) {
    $R = $script:Run; $A = $R.A; $S = $A.Survival
    if (-not $S) { return }
    $def = $S.Def
    if ($S.State -eq 'waiting') {
        $go = $def.StartColumn -lt 0 -or ($R.Player.X + $R.Player.W / 2) -ge $def.StartColumn * $R.T
        if (-not $go) { return }
        $S.State = 'active'; $S.Timer = $def.Time; $S.SpawnTimer = 0.8
        foreach ($lq in $A.Liquids) { if ($lq.Waiting) { $lq.Waiting = $false; $lq.Time = 0.0 } }
        Update-Gates $A
        Show-Toast "$($def.Message)  ($([math]::Ceiling($def.Time))s)"
        return
    }
    if ($S.State -ne 'active') { return }
    $S.Timer -= $dt
    $elapsed = $def.Time - $S.Timer
    $alive = @($A.Enemies | Where-Object { $_.Hunt -and -not $_.Dead }).Count + $R.NewEnemies.Count
    if ($def.Spawn.Count) {
        $S.SpawnTimer -= $dt
        if ($S.SpawnTimer -le 0 -and $alive -lt $def.MaxEnemies) {
            New-SurvivalEnemy ($def.Spawn | Get-Random); $alive++
            $S.SpawnTimer = $def.SpawnEvery
        }
    }
    foreach ($w in $S.Waves) {
        if ($w.Left -le 0 -or $elapsed -lt $w.Def.At) { continue }
        $w.Timer -= $dt
        if ($w.Timer -le 0) { New-SurvivalEnemy $w.Def.Spawn; $w.Left--; $w.Timer = $w.Def.Every }
    }
    if ($S.Timer -le 0) { Complete-Survival }
}

function Complete-Survival {
    $R = $script:Run; $A = $R.A; $S = $A.Survival; $def = $S.Def
    $S.State = 'done'
    [void]$R.Pending.Add(@{ Id = "survived|$($A.Id)"; Kind = 'survived' })
    foreach ($en in $A.Enemies) { if ($en.Hunt -and -not $en.Dead) { Remove-Enemy $en } }       # the horde retreats
    foreach ($lq in $A.Liquids) {
        if ($lq.Def.StartOn -ne 'survival') { continue }
        switch ($lq.Def.AfterSurvival) { 'drain' { $lq.Draining = $true } 'stay' { $lq.Waiting = $true } }
    }
    Update-Gates $A
    $reward = Get-SymbolDef "$($def.Reward)" 'item'
    if ($reward) { Add-ItemNow (New-ItemRuntime $reward "reward|$($A.Id)" ($R.Player.X + $R.Player.W / 2) ($R.Player.Y - $R.T)) }
    Show-Toast 'SURVIVED!'
    if ($def.CompleteLevel) { Complete-Level $def.Exit }
}

# ---------------------------------------------------------------------------
# Dispensers: spawners with "dispense" keep spitting out enemies and power-ups (one kind at a time, in turn)
# while the player is near, but only while fewer than "max" of that kind are out. Stops soft locks
# (an enemy you needed fell in the lava, you lost the power-up a puzzle needs).
# ---------------------------------------------------------------------------
function Get-DispensedCount($D, [string]$Key) {
    $R = $script:Run; $n = 0
    foreach ($en in @($R.A.Enemies) + @($R.NewEnemies)) {
        if ($en -and -not $en.Dead -and [object]::ReferenceEquals($en.Dispenser, $D) -and "$($en.Def.Key)" -eq $Key) { $n++ }
    }
    foreach ($it in $R.A.Items) {
        if (-not $it.Taken -and [object]::ReferenceEquals($it.Dispenser, $D) -and "$($it.Def.Key)" -eq $Key) { $n++ }
    }
    $n
}

function Get-DispenseMax($D, [string]$Key) {
    if ($D.Def.Max.ContainsKey($Key)) { return $D.Def.Max[$Key] }
    if (Get-SymbolDef $Key 'enemy') { 3 } else { 1 }
}

function Update-Dispensers([double]$dt) {
    $R = $script:Run; $pl = $R.Player
    foreach ($d in $R.A.Dispensers) {
        $cx = $d.X + $d.W / 2
        if ([math]::Abs($cx - ($pl.X + $pl.W / 2)) -gt $d.Def.Range) { continue }
        $d.Timer -= $dt
        if ($d.Timer -gt 0) { continue }
        $d.Timer = $d.Def.Every
        $list = $d.Def.Dispense; $n = $list.Count
        for ($i = 0; $i -lt $n; $i++) {
            $k = $list[($d.Next + $i) % $n]
            if ((Get-DispensedCount $d $k) -lt (Get-DispenseMax $d $k)) {
                Invoke-Dispense $d $k
                $d.Next = ($d.Next + $i + 1) % $n
                break
            }
        }
    }
}

function Invoke-Dispense($D, [string]$Key) {
    $R = $script:Run; $pl = $R.Player
    $script:DispenseSerial = [int]$script:DispenseSerial + 1
    $id = "dispense|$($script:DispenseSerial)"
    $cx = $D.X + $D.W / 2
    $toPlayer = if (($pl.X + $pl.W / 2) -lt $cx) { -1 } else { 1 }
    $dir = switch ($D.Def.Walk) { 'left' { -1 } 'right' { 1 } 'player' { $toPlayer } default { -$toPlayer } }
    $edef = Get-SymbolDef $Key 'enemy'
    if ($edef) {
        $en = New-EnemyRuntime $edef $cx $D.Y $id
        $en.Active = $true; $en.Dispenser = $D; $en.Dir = $dir
        $en.VY = -$D.Def.Launch; $en.LeapVX = 150.0         # hops clear of the pipe, then walks once it lands
        [void]$R.NewEnemies.Add($en)
        Add-Sprite $en.Sprite
        Set-SpritePosition $en
        return
    }
    $idef = Get-SymbolDef $Key 'item'
    if ($idef) {
        $it = New-ItemRuntime $idef $id $cx ($D.Y - 14)
        $it.Dispenser = $D; $it.Falling = $true
        $it.VX = $dir * 130.0; $it.VY = -$D.Def.Launch * 0.85
        $it.OnGround = $false; $it.HitX = $false; $it.HitTop = $false; $it.GroundSolid = $null
        Add-ItemNow $it
    }
}

function New-SurvivalEnemy([string]$Key) {
    $R = $script:Run; $A = $R.A; $ts = $R.T
    $def = Get-SymbolDef $Key 'enemy'
    if (-not $def) { return }
    $cx = 0.0; $feet = 0.0
    if ($A.Spawners.Count) {
        $sp = $A.Spawners[$A.Survival.Spawned % $A.Spawners.Count]
        $cx = $sp.X + $ts / 2; $feet = $sp.Y + $ts
    }
    else {
        # No spawners: drop in from the top of the screen, somewhere with room
        for ($try = 0; $try -lt 12; $try++) {
            $cx = $R.CamX + 48 + (Get-Random -Minimum 0.0 -Maximum 1.0) * ($ViewW - 96)
            $feet = $R.CamY + 24 + $def.Height
            if (-not (Test-RectSolid ($cx - $def.Width / 2) ($feet - $def.Height) $def.Width $def.Height)) { break }
        }
    }
    $A.Survival.Spawned++
    $en = New-EnemyRuntime $def $cx $feet "spawn|$($A.Survival.Spawned)"
    $en.Active = $true; $en.Hunt = $true
    $en.Dir = if (($R.Player.X + $R.Player.W / 2) -lt $cx) { -1 } else { 1 }
    [void]$R.NewEnemies.Add($en)
    Add-Sprite $en.Sprite
    Set-SpritePosition $en
}

# ---------------------------------------------------------------------------
# Exit requirements
# ---------------------------------------------------------------------------
function Get-ExitRequirement([string]$Exit) {
    $lv = $script:Run.Level
    Merge-Requirement $lv.Requires $lv.ExitRequires[$Exit]
}

# Which item symbol an id like "coin|main|12|5" (or a ? block's "block|main|3|4|0") stands for
function Get-IdSymbol([string]$Id) {
    $R = $script:Run
    $p = $Id -split '\|'
    if ($p.Count -lt 4) { return $null }
    $area = $R.Level.Areas[$p[1]]
    if (-not $area -or -not $area.Rows) { return $null }
    $x = 0; $y = 0
    if (-not [int]::TryParse($p[2], [ref]$x) -or -not [int]::TryParse($p[3], [ref]$y)) { return $null }
    if ($y -lt 0 -or $x -lt 0 -or $y -ge $area.H -or $x -ge $area.W) { return $null }
    $c = "$($area.Rows[$y][$x])"
    if ($p[0] -eq 'block') {
        $t = Get-SymbolDef $c 'tile'
        if ($t -and $t.Bump -and $p.Count -eq 5) { return "$($t.Bump.Gives)" }
        return $null
    }
    if ($p.Count -eq 4) { return $c }
    $null
}

# Items and coins collected in this level so far (saved earlier, plus picked up on this try)
function Get-CollectedCounts {
    $R = $script:Run
    $counts = @{}; $coins = 0
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($id in @($R.SlotTaken) + @($R.RunCommitted)) {
        if (-not $id -or -not $seen.Add($id)) { continue }
        $c = Get-IdSymbol $id
        if (-not $c) { continue }
        $d = Get-SymbolDef $c 'item'
        if (-not $d) { continue }
        $counts[$c] = [int]$counts[$c] + 1
        if ($d.Type -eq 'coin') { $coins += $d.Value }
    }
    foreach ($p in $R.Pending) {
        if (-not $p.Sym -or -not $seen.Add("$($p.Id)")) { continue }
        $counts[$p.Sym] = [int]$counts[$p.Sym] + 1
        if ($p.Kind -eq 'coin') { $coins += $p.Value }
    }
    @{ Items = $counts; Coins = $coins }
}

# $null when the exit is open, otherwise what's still missing
function Get-RequirementGap($Req) {
    if (-not $Req) { return $null }
    $R = $script:Run
    $parts = New-Object System.Collections.Generic.List[string]
    if ($R.Defeated -lt $Req.Defeated) { $n = $Req.Defeated - $R.Defeated; $parts.Add("defeat $n more enem$(if ($n -eq 1) { 'y' } else { 'ies' })") }
    foreach ($k in @($Req.Enemies.Keys)) {
        $need = [int]$Req.Enemies[$k] - [int]$R.DefeatedBy[$k]
        if ($need -gt 0) {
            $d = Get-SymbolDef $k 'enemy'
            $parts.Add("defeat the $(if ($d) { $d.Name } else { $k })" + $(if ($need -gt 1) { " (x$need)" } else { '' }))
        }
    }
    if ($Req.Coins -gt 0 -or $Req.Items.Count -gt 0) {
        $got = Get-CollectedCounts
        if ($got.Coins -lt $Req.Coins) { $parts.Add("collect $($Req.Coins - $got.Coins) more coins") }
        foreach ($k in @($Req.Items.Keys)) {
            $need = [int]$Req.Items[$k] - [int]$got.Items[$k]
            if ($need -gt 0) { $d = Get-SymbolDef $k 'item'; $parts.Add("find $need more $(if ($d) { $d.Name } else { $k })") }
        }
    }
    if ($parts.Count) { return ($parts -join ', ') }
    $null
}

# ---------------------------------------------------------------------------
# Health, power-ups, items, keys, mounts
# ---------------------------------------------------------------------------
# Health works in three steps:
#   normal     - one hit and you're out
#   powered    - holding a power-up (fire, ice, wings, feather, mushroom...); a hit takes you back to normal
#   invincible - a timer on top of either; when it runs out you're back to whatever you had
# A mount takes a hit for you before any of that.
# A power-up by symbol: from the chapter being played, or else from any chapter (so bought or carried
# power-ups keep working in every chapter)
function Find-PowerDef([string]$Key) {
    $def = Get-SymbolDef $Key 'item'
    if ($def) { return $def }
    if (-not $Key -or $Key.Length -ne 1) { return $null }
    foreach ($ch in $script:World.Chapters) {
        $sym = $null
        if ($ch.Symbols.TryGetValue([char]$Key, [ref]$sym) -and $sym.Kind -eq 'item' -and $sym.Def.IsPower) { return $sym.Def }
    }
    $null
}

function Set-Power([string]$Key) {
    $R = $script:Run
    $def = Find-PowerDef $Key
    if ($def -and -not $def.IsPower) { $def = $null }
    $R.Power = $def
    $R.PowerKey = if ($def) { $def.Key } else { $null }
    $R.PowerTimer = if ($def -and $def.Duration) { [double]$def.Duration } else { 0.0 }
    $R.PowerHits = if ($def) { $def.Ability.Hits } else { 0 }
    $R.PipePower = $false
    Update-Physics
}

# Level physics, changed by the power-up (if it has physics) and then the mount (if riding)
function Update-Physics {
    $R = $script:Run
    $p = $R.BasePhys
    if ($R.Power -and $R.Power.Ability.Physics.Count) { $p = Merge-Physics $p $R.Power.Ability.Physics }
    if ($R.Mount) { $p = Merge-Physics $p $R.Mount.Def.Physics }
    $R.Phys = $p
}

function Test-PowerImmune([string]$What) {
    $R = $script:Run
    [bool]($R.Power -and $R.Power.Ability.Immune.Contains($What))
}

# Keys held plus power-ups stored
function Get-InventoryCount {
    $R = $script:Run
    $n = $R.Stash.Count
    foreach ($k in @($R.Inv.Keys)) { if ([int]$R.Inv[$k] -gt 0) { $n += [int]$R.Inv[$k] } }
    $n
}

# Swap key: wear the first power-up in the bag; the one you wore goes to the back of the bag
function Invoke-PowerSwap {
    $R = $script:Run
    if (-not $R -or $R.State -ne 'Playing') { return }
    if ($R.Stash.Count -eq 0) { Show-Toast 'Your bag has no power-ups to swap to.'; return }
    $next = "$($R.Stash[0])"
    $R.Stash.RemoveAt(0)
    if ($R.PowerKey -and -not $R.PipePower) { [void]$R.Stash.Add("$($R.PowerKey)") }      # a pipe's power-up is just dropped
    Set-Power $next
    Show-Toast "Now wearing: $($R.Power.Name)"
}

function Get-PowerHint($Def) {
    if ($Def.Message) { return $Def.Message }
    $ab = $Def.Ability
    $hints = New-Object System.Collections.Generic.List[string]
    if ($ab.Projectile) { $hints.Add($(switch ($ab.Projectile.Effect) { 'freeze' { 'Press E (or X) to freeze enemies.' } 'stun' { 'Press E (or X) to stun enemies.' } default { 'Press E (or X) to shoot.' } })) }
    if ($ab.Fly) { $hints.Add('Hold jump to fly.') }
    if ($ab.AirJumps -gt 0) { $hints.Add('Jump again in mid-air.') }
    if ($ab.Glide -gt 0) { $hints.Add('Hold jump to glide.') }
    if ($ab.HeavyStomp) { $hints.Add('Your stomps are heavy.') }
    if ($ab.BreakBlocks) { $hints.Add('Break blocks with your head.') }
    if ($ab.Immune.Count) { $hints.Add("Safe from $(@($ab.Immune) -join ', ').") }
    if (-not $hints.Count) { $hints.Add('You can take a hit.') }
    $hints -join ' '
}

# A power-up you picked up (or bought): wear it if you have none, otherwise store it;
# with a full inventory you swap the one you're wearing for it.
function Grant-Power($Def) {
    $R = $script:Run
    if (-not $R.Power) { Set-Power $Def.Key; Show-Toast "$($Def.Name)! $(Get-PowerHint $Def)"; return }
    if ((Get-InventoryCount) -lt $InventorySize) {
        [void]$R.Stash.Add([string]$Def.Key)
        Show-Toast "$($Def.Name) went into your inventory ($(Get-InventoryCount)/$InventorySize)"
        return
    }
    $old = $R.Power.Name
    Set-Power $Def.Key
    Show-Toast "Inventory full - swapped your $old for the $($Def.Name)"
}

# A power-up from a pipe: you always wear it straight away (what you wore goes in the bag if there's room).
# It never goes into the bag itself, and swapping it out throws it away, so a pipe can't be used to farm power-ups.
function Grant-PipePower($Def) {
    $R = $script:Run
    $note = ''
    if ($R.PowerKey -and -not $R.PipePower) {
        if ((Get-InventoryCount) -lt $InventorySize) { [void]$R.Stash.Add("$($R.PowerKey)"); $note = " (your $($R.Power.Name) went into your bag)" }
        else { $note = " (bag full - your $($R.Power.Name) is gone)" }
    }
    Set-Power $Def.Key
    $R.PipePower = $true
    Show-Toast "$($Def.Name)!$note $(Get-PowerHint $Def)"
}

function Invoke-Collect($Item) {
    $R = $script:Run
    $def = $Item.Def
    if ($def.Type -eq 'key' -and (Get-InventoryCount) -ge $InventorySize) {
        if ($R.FullToast -le 0) { Show-Toast "Inventory full ($InventorySize). Use something up first."; $R.FullToast = 2.5 }
        return
    }
    if ($Item.Dispenser -and $R.PowerKey -and "$($R.PowerKey)" -eq "$($def.Key)") { return }   # already wearing it: leave it there
    $Item.Taken = $true
    Remove-Sprite $Item.Sprite
    if ($def.Type -eq 'tetromino') { Add-Tetromino $def.Shape; return }
    switch ($def.Type) {
        'coin'        { [void]$R.Pending.Add(@{ Id = $Item.Id; Kind = 'coin'; Value = $def.Value; Sym = $def.Key }); Add-Record 'coinsCollected' '' $def.Value }
        'life'        {
            [void]$R.Pending.Add(@{ Id = $Item.Id; Kind = 'item'; Sym = $def.Key })
            if ($script:World.Lives -gt 0 -and -not $R.MiniGame) { $R.Slot.lives = (Get-SlotLives $R.Slot) + 1; Add-Record 'livesFound'; Show-Toast "1-UP! Lives: $($R.Slot.lives)" }
            else { Show-Toast "$($def.Name)! (no lives to count here)" }
        }
        'collectible' {
            [void]$R.Pending.Add(@{ Id = $Item.Id; Kind = 'collectible'; Sym = $def.Key })
            $R.CollectiblesFound++
            Add-Record 'items' $def.Name
            Show-Toast "$($def.Name) found!  ($($R.CollectiblesFound)/$($R.Level.Collectibles))"
        }
        'key'         {
            [void]$R.Pending.Add(@{ Id = $Item.Id; Kind = 'key'; KeyId = $def.KeyId; Sym = $def.Key })
            $R.Inv[$def.KeyId] = [int]$R.Inv[$def.KeyId] + 1
            Add-Record 'items' $def.Name
            Show-Toast "Got the $($def.Name)!"
        }
        'invincible'  { [void]$R.Pending.Add(@{ Id = $Item.Id; Kind = 'item'; Sym = $def.Key }); Add-Record 'powers' $def.Name; $R.InvincibleTimer = $def.Duration; Show-Toast "$($def.Name)! You're invincible!" }
        'speed'       { [void]$R.Pending.Add(@{ Id = $Item.Id; Kind = 'item'; Sym = $def.Key }); $R.SpeedTimer = $def.Duration; $R.SpeedMult = $def.Multiplier; Show-Toast "$($def.Name)! Speed up!" }
        default       {
            if ($Item.Dispenser) { Grant-PipePower $def; return }          # free refills aren't recorded or stored
            [void]$R.Pending.Add(@{ Id = $Item.Id; Kind = 'item'; Sym = $def.Key }); Add-Record 'powers' $def.Name; Grant-Power $def
        }
    }
}

# A key opens the touched lock block and every lock block of the same colour connected to it
function Open-Lock($Lock) {
    $R = $script:Run
    $A = $R.A
    $R.Inv[$Lock.LockId] = [int]$R.Inv[$Lock.LockId] - 1
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($Lock)
    $Lock.Open = $true
    while ($queue.Count -gt 0) {
        $lk = $queue.Dequeue()
        $A.Solid[$lk.CellX, $lk.CellY] = $false
        Remove-Sprite $lk.Sprite
        [void]$R.Pending.Add(@{ Id = $lk.Id; Kind = 'lock' })
        foreach ($other in $A.Locks) {
            if ($other.Open -or $other.LockId -ne $lk.LockId) { continue }
            if ([math]::Abs($other.CellX - $lk.CellX) + [math]::Abs($other.CellY - $lk.CellY) -eq 1) { $other.Open = $true; $queue.Enqueue($other) }
        }
    }
    Show-Toast 'Unlocked!'
}

# Whatever the power-up shoots (fireballs, iceballs, or anything a world defines)
function New-Projectile {
    $R = $script:Run; $pl = $R.Player
    $P = $R.Power.Ability.Projectile
    if ($R.Projectiles.Count -ge $P.Max) { return }
    $sz = $P.Size
    $pr = @{
        X = $pl.X + $pl.W / 2 - $sz / 2 + $pl.Facing * ($pl.W / 2); Y = $pl.Y + [math]::Min(12, $pl.H * 0.3); W = $sz; H = $sz
        VX = $pl.Facing * $P.Speed + $pl.VX * 0.3; VY = 0.0; Life = $P.Life; Dir = $pl.Facing; P = $P
        Hit = New-Object System.Collections.ArrayList
        OnGround = $false; HitX = $false; HitTop = $false; GroundSolid = $null
    }
    if (Test-RectSolid $pr.X $pr.Y $pr.W $pr.H) { return }
    $pr.Sprite = New-Sprite (Get-WorldImage $P.Image) $sz $sz $P.Color
    Add-Sprite $pr.Sprite
    [void]$R.Projectiles.Add($pr)
    $R.FireCooldown = $P.Cooldown
}

function Update-Projectiles([double]$dt) {
    $R = $script:Run
    for ($i = $R.Projectiles.Count - 1; $i -ge 0; $i--) {
        $pr = $R.Projectiles[$i]; $P = $pr.P
        $pr.Life -= $dt
        if ($P.Gravity) { $pr.VY = [math]::Min(900, $pr.VY + $R.Phys.gravity * $dt) }
        Move-Entity $pr ($pr.VX * $dt) ($pr.VY * $dt)
        $gone = $pr.Life -le 0 -or $pr.Y -gt $R.HeightPx
        if ($pr.OnGround) { if ($P.Bounce) { $pr.VY = -320.0 } else { $gone = $true } }   # bounce along the floor
        if ($pr.HitTop) { $pr.VY = 0.0 }
        $pcx = $pr.X + $pr.W / 2; $pcy = $pr.Y + $pr.H / 2
        if ($P.OutInWater -and (Test-PointLiquid $pcx $pcy)) { $gone = $true }    # fire goes out in water
        if ($P.MeltsInLava -and (Test-PointLava $pcx $pcy)) { $gone = $true }     # ice melts in lava
        if (-not $gone) {
            foreach ($en in $R.A.Enemies) {
                if ($en.Dead -or -not $en.Active -or $pr.Hit.Contains($en)) { continue }
                # A small margin so shots that stop against an ice block still count
                if (($pr.X - 3 -lt $en.X + $en.W) -and ($pr.X + $pr.W + 3 -gt $en.X) -and ($pr.Y - 3 -lt $en.Y + $en.H) -and ($pr.Y + $pr.H + 3 -gt $en.Y)) {
                    [void](Invoke-EnemyHit $en $P.Element $P.Effect $P)
                    if ($P.Pierce) { [void]$pr.Hit.Add($en) } else { $gone = $true; break }
                }
            }
        }
        if ($pr.HitX) {
            $blk = Get-BlockAtPoint $(if ($pr.Dir -gt 0) { $pr.X + $pr.W + 2 } else { $pr.X - 2 }) ($pr.Y + $pr.H / 2)
            if ($blk) { [void](Invoke-BlockHit $blk 'projectile' $P.Element) }
            $gone = $true
        }
        if ($gone) { Remove-Sprite $pr.Sprite; $R.Projectiles.RemoveAt($i) }
    }
}

function Invoke-Mount($Mount) {
    $R = $script:Run; $pl = $R.Player; $def = $Mount.Def
    $newX = $pl.X + $pl.W / 2 - $def.Width / 2
    $newY = $pl.Y + $pl.H - $def.Height
    if (Test-RectSolid $newX $newY $def.Width $def.Height) { return }   # no room to get on here
    [void]$R.A.Mounts.Remove($Mount)
    $pl.X = $newX; $pl.Y = $newY; $pl.W = $def.Width; $pl.H = $def.Height; $pl.Crouching = $false
    $R.Mount = $Mount
    Update-Physics
    Remove-Sprite $pl.Sprite          # re-add so the rider is drawn above the mount
    Add-Sprite $pl.Sprite
    Show-Toast "Riding the $($def.Name)!  Press C or Y to get off."
}

# Lost = the mount ran away after a hit
function Invoke-Dismount([bool]$Lost) {
    $R = $script:Run; $pl = $R.Player; $world = $script:World
    $mo = $R.Mount
    if (-not $mo) { return }
    $R.Mount = $null
    Update-Physics
    # The mount keeps half the speed it had and slows to a stop on its own
    $mo.X = $pl.X; $mo.Y = $pl.Y; $mo.W = $mo.Def.Width; $mo.H = $mo.Def.Height; $mo.VX = $pl.VX * 0.5; $mo.VY = 0.0; $mo.OnGround = $false
    $newW = $world.Player.Width; $newH = $world.Player.Height
    $pl.X = $pl.X + $pl.W / 2 - $newW / 2
    $pl.Y = $pl.Y + $pl.H - $newH
    $pl.W = $newW; $pl.H = $newH
    if ($Lost) {
        Remove-Sprite $mo.Sprite
        Show-Toast "The $($mo.Def.Name) ran away!"
    }
    else {
        $mo.Dir = $pl.Facing
        [void]$R.A.Mounts.Add($mo)
        $pl.VY = -$R.Phys.jumpSpeed * 0.6
    }
    $R.MountCooldown = 0.6
}

# Getting hit. Returns $true if the hit counted.
# Bounce throws you into the air, away from FromX (the middle of whatever hit you; NaN = straight up).
function Invoke-PlayerHurt([bool]$Bounce, [double]$FromX = [double]::NaN) {
    $R = $script:Run; $pl = $R.Player
    if ($R.InvulnTimer -gt 0 -or $R.InvincibleTimer -gt 0) { return $false }
    if ($R.Mount)     { Invoke-Dismount $true }
    elseif ($R.Power) {
        $down = Get-SymbolDef "$($R.Power.Ability.DowngradeTo)" 'item'
        if ($R.PowerHits -gt 1) { $R.PowerHits--; Show-Toast "Hit! The $($R.Power.Name) can take $($R.PowerHits) more." }
        elseif ($down -and $down.IsPower) { $old = $R.Power.Name; Add-Record 'powersLost' $old; Set-Power $down.Key; Show-Toast "Hit! $old -> $($down.Name)" }
        else { Add-Record 'powersLost' $R.Power.Name; Show-Toast "Hit! Lost the $($R.Power.Name) - back to normal."; Set-Power $null }
    }
    else { Invoke-PlayerDeath 'OUCH!' $true; return $true }
    $R.InvulnTimer = 1.5
    Invoke-DropCarried
    if ($Bounce) {
        $vx = [double]::NaN; $lock = 0
        if (-not [double]::IsNaN($FromX)) {
            $side = [math]::Sign(($pl.X + $pl.W / 2) - $FromX)
            if ($side -eq 0) { $side = -$pl.Facing }
            $vx = $side * $R.Phys.hurtKnockback; $lock = 0.25
        }
        Invoke-Knockback $vx (-$R.Phys.hurtBounce) $lock
    }
    $true
}

function Invoke-PlayerDeath([string]$Message, [bool]$Hop) {
    $R = $script:Run
    if ($R.State -ne 'Playing') { return }
    if ($R.MiniGame) { Complete-MiniGameLevel $Message $true; return }
    $R.State = 'Dead'
    Add-Record 'deaths'
    Add-Record 'deathsBy' $Message
    if ($script:World.Lives -gt 0) {
        $slot = $R.Slot
        $slot.lives = (Get-SlotLives $slot) - 1
        if ($slot.lives -le 0) { $slot.lives = 0; $slot.gameOver = $true; $slot.resume = $null; $R.GameOver = $true }
        [void](Save-WorldData)
        $script:LastTick = $script:Clock.Elapsed.TotalSeconds
    }
    $R.DeadTimer = 1.1
    $R.DeathHop = $Hop
    $R.Stats.deaths++
    $R.PowerKey = $null          # power-ups are lost when you die
    $pl = $R.Player
    $pl.VX = 0
    if ($Hop) { $pl.VY = -520; $pl.Sprite.Tag.Scale.ScaleY = -1 }
    $DeathText.Text = $Message
    $DeathText.Visibility = 'Visible'
    Update-Hud
}

function Show-GameOver {
    $R = $script:Run
    $R.State = 'GameOver'
    Stop-GameLoop
    Show-Overlay 'GAME OVER' "You're out of lives.`nThis save can now only be reviewed - start a new game in another slot (or delete this one)." @(
        @{ Text = 'Review this save'; Action = { Exit-Level; Show-Review } }
        @{ Text = 'World menu';       Action = { Exit-Level } }
    )
}

function Update-Dead([double]$dt) {
    $R = $script:Run; $pl = $R.Player
    $R.DeadTimer -= $dt
    if ($R.DeathHop) {
        $pl.VY += $R.Phys.gravity * $dt
        $pl.Y  += $pl.VY * $dt
        Set-SpritePosition $pl
    }
    if ($R.DeadTimer -le 0) {
        if ($R.GameOver) { Show-GameOver } else { Start-Life }
    }
}

# ---------------------------------------------------------------------------
# Progress: checkpoints, saving, completing levels
# ---------------------------------------------------------------------------
# Makes everything picked up since the last checkpoint permanent
function Save-PendingProgress {
    $R = $script:Run
    if ($R.MiniGame) { return }          # nothing in a mini-game is kept
    $slot = $R.Slot
    $key = "$($R.LevelNumber)"
    if (-not $slot.taken.ContainsKey($key)) { $slot.taken[$key] = New-Object System.Collections.ArrayList }
    foreach ($p in $R.Pending) {
        switch ($p.Kind) {
            'coin'        { $slot.coins += $p.Value; [void]$slot.taken[$key].Add($p.Id); [void]$R.SlotTaken.Add($p.Id) }
            'collectible' { [void]$slot.taken[$key].Add($p.Id); [void]$R.SlotTaken.Add($p.Id) }
            'lock'        { [void]$slot.taken[$key].Add($p.Id); [void]$R.SlotTaken.Add($p.Id) }     # opened for good
            'key'         {
                if ($script:World.PersistentKeys.Contains($p.KeyId)) { [void]$slot.taken[$key].Add($p.Id); [void]$R.SlotTaken.Add($p.Id) }
                else { [void]$R.RunCommitted.Add($p.Id) }                                              # this-level-only key
            }
            default       { [void]$R.RunCommitted.Add($p.Id) }
        }
    }
    $R.Pending.Clear()
    $R.InvAtCheckpoint = Copy-Hashtable $R.Inv
    $R.StashAtCheckpoint = @($R.Stash)
    $slot.stash = New-Object System.Collections.ArrayList
    foreach ($k in $R.Stash) { [void]$slot.stash.Add("$k") }
    # Keys that carry between levels go into the save slot
    $slot.keys = @{}
    foreach ($k in @($R.Inv.Keys)) {
        if ([int]$R.Inv[$k] -gt 0 -and $script:World.PersistentKeys.Contains($k)) { $slot.keys[$k] = [int]$R.Inv[$k] }
    }
}

function Get-ResumeData {
    $R = $script:Run
    $cp = $R.Checkpoint
    @{
        level        = $R.LevelNumber
        area         = if ($cp) { $cp.Area } else { $null }
        x            = if ($cp) { $cp.X } else { $null }
        y            = if ($cp) { $cp.Y } else { $null }
        power        = $R.PowerKey
        time         = [math]::Round($R.Time, 2)
        runCommitted = @($R.RunCommitted)
        keys         = Copy-Hashtable $R.InvAtCheckpoint
        stash        = @($R.StashAtCheckpoint)
    }
}

function Enable-Checkpoint($Cp) {
    $R = $script:Run
    foreach ($areaRt in $R.Areas.Values) {
        foreach ($other in $areaRt.Checkpoints) {
            if ($other.Active) { $other.Active = $false; Set-CheckpointLook $other }
        }
    }
    $Cp.Active = $true
    Set-CheckpointLook $Cp
    $R.Checkpoint = @{ Area = $R.AreaId; X = $Cp.CellX; Y = $Cp.CellY }
    if ($R.MiniGame) { Show-Toast 'Checkpoint!'; return }
    Save-PendingProgress
    $R.Slot.resume = Get-ResumeData
    $ok = Save-WorldData
    $script:LastTick = $script:Clock.Elapsed.TotalSeconds     # saving takes a moment; don't count it as game time
    Show-Toast $(if ($ok) { 'Checkpoint! Progress saved.' } else { 'Checkpoint! (progress could not be saved)' })
}

function Complete-Level([string]$Exit = 'G') {
    $R = $script:Run
    $world = $script:World
    $lv = $R.Level
    $R.State = 'Complete'
    Save-PendingProgress
    $slot = $R.Slot
    if (-not ($slot.completed -contains $R.LevelNumber)) { [void]$slot.completed.Add($R.LevelNumber) }
    $exitId = "$($R.LevelNumber):$Exit"
    $firstTime = -not $slot.exits.Contains($exitId)
    if ($firstTime) { [void]$slot.exits.Add($exitId) }

    # Open up whatever this exit leads to
    $targets = @(Get-ExitUnlocks $lv $Exit)
    $opened = New-Object System.Collections.Generic.List[string]
    foreach ($n in $targets) {
        if (-not $slot.unlocked.Contains($n)) {
            [void]$slot.unlocked.Add($n)
            $t = Get-Level $n
            $opened.Add("Level $($t.Label) - $($t.Name)" + $(if ($t.Hidden) { '  (secret level!)' } else { '' }) + $(if ($t.Chapter.Index -ne $lv.Chapter.Index) { "  [$($t.Chapter.Name)]" } else { '' }))
        }
    }
    $slot.power  = $R.PowerKey          # your power-up carries into the next level
    $slot.shield = $false
    $slot.resume = $null
    $st = $R.Stats
    $st.completions++
    $isBest = ($null -eq $st.bestTime) -or ($R.Time -lt $st.bestTime)
    if ($isBest) { $st.bestTime = [math]::Round($R.Time, 2) }
    $saved = Save-WorldData

    $exitName = if ($Exit -ceq 'G') { 'the goal' } else { $world.Symbols[[char]$Exit].Def.Name }
    $title = if ($Exit -cne 'G' -and $firstTime) { 'SECRET EXIT FOUND!' }
             elseif ($targets.Count -eq 0 -and -not $lv.Hidden) { 'WORLD COMPLETE!' }
             else { 'LEVEL COMPLETE!' }
    $text = "Time  $(Format-Time $R.Time)" + $(if ($isBest) { '    NEW BEST!' } else { "    (best $(Format-Time $st.bestTime))" }) +
            "`nCoins $($slot.coins)    Deaths $($st.deaths)" +
            $(if ($R.Level.Collectibles) { "`nFound $($R.CollectiblesFound) of $($R.Level.Collectibles) collectibles" } else { '' }) +
            $(if ($lv.ExitChars.Count -gt 1) { "`nLeft through $exitName" } else { '' }) +
            $(if ($opened.Count) { "`nUnlocked: " + ($opened -join ', ') } else { '' }) +
            $(if (-not $saved) { "`n(Progress could not be saved - see warnings)" } else { '' })

    $buttons = @()
    foreach ($n in $targets) {
        if ((Get-Level $n).Error) { continue }
        $buttons += @{ Text = "Play level $((Get-Level $n).Label)"; Action = [scriptblock]::Create("Hide-Overlay; Start-Level $n `$null") }
    }
    $buttons += @{ Text = 'Play again'; Action = { Hide-Overlay; Start-Level $script:Run.LevelNumber $null } }
    $buttons += @{ Text = 'World menu'; Action = { Exit-Level } }
    Show-Overlay $title $text $buttons
}

function Suspend-Game {
    $R = $script:Run
    if (-not $R -or $R.State -ne 'Playing') { return }
    $R.State = 'Paused'
    $script:Held.Clear()
    if ($R.MiniGame) {
        Show-Overlay 'PAUSED' "Mini-game: $($R.MiniGame.Name)`nGiving up ends the game and you keep half the coins you've grabbed." @(
            @{ Text = 'Resume';  Action = { Resume-Game } }
            @{ Text = 'Give up'; Action = { $script:Run.State = 'Playing'; Hide-Overlay; Complete-MiniGameLevel 'You gave up.' $true } }
        )
        return
    }
    $where = if ($R.Checkpoint) { 'your last checkpoint' } else { 'the start of this level' }
    $buttons = @(
        @{ Text = 'Resume'; Action = { Resume-Game } }
    )
    if ($R.Checkpoint) { $buttons += @{ Text = 'Restart from checkpoint'; Action = { Hide-Overlay; Start-Life } } }
    $buttons += @{ Text = 'Restart level';       Action = { Hide-Overlay; Start-Level $script:Run.LevelNumber $null } }
    $buttons += @{ Text = 'Save and quit';       Action = { Save-AndQuit } }
    $buttons += @{ Text = 'Quit without saving'; Action = { Exit-Level } }
    Show-Overlay 'PAUSED' "$($script:World.Name)`nLevel $($R.Level.Label): $($R.Level.Name)`n'Save and quit' lets you continue from $where." $buttons
}

function Resume-Game {
    Hide-Overlay
    $script:Run.State = 'Playing'
    $script:LastTick = $script:Clock.Elapsed.TotalSeconds
    Sync-PadHeld
}

function Save-AndQuit {
    $script:Run.Slot.resume = Get-ResumeData
    Exit-Level
}

function Exit-Level {
    Hide-Overlay
    Clear-Atmosphere
    Stop-GameLoop
    Set-Fade 0
    $ToastBox.Visibility = 'Collapsed'
    $script:Run = $null
    [void](Save-WorldData)
    Show-Hub
}

# ---------------------------------------------------------------------------
# Camera, sprites, animation, HUD
# ---------------------------------------------------------------------------
function Update-Camera([double]$dt) {
    $R = $script:Run; $pl = $R.Player
    $targetX = $pl.X + $pl.W / 2 - $ViewW / 2 + $pl.Facing * 48
    $targetY = $pl.Y + $pl.H / 2 - $ViewH * 0.55
    $k = [math]::Min(1.0, $dt * 6)
    $R.CamX += ($targetX - $R.CamX) * $k
    $R.CamY += ($targetY - $R.CamY) * $k
    $R.CamX = [math]::Max(0.0, [math]::Min($R.CamX, $R.WidthPx - $ViewW))
    $R.CamY = [math]::Max(0.0, [math]::Min($R.CamY, $R.HeightPx - $ViewH))
    $CamTransform.X = -[math]::Round($R.CamX)
    $CamTransform.Y = -[math]::Round($R.CamY)
    if ($R.BgBrush) {
        $off = -(($R.CamX * 0.35) % $R.BgWidth)       # the background scrolls slower (parallax)
        $R.BgBrush.Viewport = [System.Windows.Rect]::new($off, 0, $R.BgWidth, $ViewH)
    }
}

function Get-PlayerAnimState($Sets) {
    $R = $script:Run; $pl = $R.Player
    if ($R.InvincibleTimer -gt 0 -and (Find-Anim $Sets 'invincible' -Exact)) { return 'invincible' }
    if ($R.Mount) { return 'ride' }
    if ($pl.Sleeping) { return 'sleep' }
    if ($pl.Climbing) { return 'climb' }
    if ($pl.Crouching) { return 'crouch' }
    if ($pl.InWater) { return 'swim' }
    if (-not $pl.OnGround) { if ($pl.VY -lt 0) { return 'jump' } else { return 'fall' } }
    if ([math]::Abs($pl.VX) -gt 20) { return 'run' }
    'idle'
}

function Update-Sprites([double]$dt) {
    $R = $script:Run
    $world = $script:World
    $pl = $R.Player
    $ps = $pl.Sprite

    # Player: the powered-up form's pictures (if any) come first, then the normal ones
    $sets = @($(if ($R.Power) { $R.Power.PlayerAnims }), $world.Player.Anims)
    $pl.BaseBitmap = $R.PlayerBase
    if ($R.Power -and $R.Power.PlayerImage) { $b = Get-WorldImage $R.Power.PlayerImage; if ($b) { $pl.BaseBitmap = $b } }
    $state = Get-PlayerAnimState $sets
    Update-Animation $pl $state $sets $dt $pl.Facing
    $squash = 1.0
    if ($pl.Crouching -and -not (Find-Anim $sets 'crouch' -Exact)) { $squash = $world.Player.CrouchHeight / $world.Player.Height }

    if ($R.Mount) {
        $mo = $R.Mount
        $mo.X = $pl.X; $mo.Y = $pl.Y; $mo.W = $pl.W; $mo.H = $pl.H
        $mstate = if (-not $pl.OnGround) { 'jump' } elseif ([math]::Abs($pl.VX) -gt 20) { 'run' } else { 'idle' }
        Update-Animation $mo $mstate @($mo.Def.Anims) $dt $pl.Facing
        Set-SpritePosition $mo
        $mo.Sprite.Tag.Scale.ScaleX = $pl.Facing
        [System.Windows.Controls.Canvas]::SetLeft($ps, [math]::Round($pl.X + $pl.W / 2 - $ps.Width / 2))
        [System.Windows.Controls.Canvas]::SetTop($ps,  [math]::Round($pl.Y + $mo.Def.RiderY - $ps.Height))
    }
    else { Set-SpritePosition $pl $squash }
    $ps.Tag.Scale.ScaleX = $pl.Facing                 # sprites are drawn facing right
    $ps.Tag.Scale.ScaleY = $squash

    # Flash after being hit; glow while invincible
    $opacity = if ($R.InvulnTimer -gt 0 -and ([int]($R.Time * 15) % 2) -eq 1) { 0.3 } else { 1.0 }
    $ps.Opacity = $opacity
    if ($R.Mount) { $R.Mount.Sprite.Opacity = $opacity }
    $glow = $R.InvincibleTimer -gt 0
    if ($glow -ne $R.GlowOn) { $ps.Effect = if ($glow) { $GlowEffect } else { $null }; $R.GlowOn = $glow }

    $A = $R.A
    foreach ($en in $A.Enemies) {
        if (-not $en.Active -or $en.Dead) { continue }
        if (-not $en.Frozen) { Update-Animation $en $en.State @($en.Def.Anims) $dt $en.Dir }
        $en.Sprite.Opacity = if ($en.HurtTimer -gt 0 -and ([int]($R.Time * 20) % 2) -eq 1) { 0.35 } elseif ($en.StunTimer -gt 0) { 0.7 } else { 1.0 }
        Set-SpritePosition $en
        $en.Sprite.Tag.Scale.ScaleX = $en.Dir
        if ($en.IceSprite) { Set-ElementAt $en.IceSprite $en.X $en.Y }
    }
    foreach ($mo in $A.Mounts) {
        Update-Animation $mo 'idle' @($mo.Def.Anims) $dt $mo.Dir
        Set-SpritePosition $mo
        $mo.Sprite.Tag.Scale.ScaleX = $mo.Dir
    }
    foreach ($p in $A.Platforms) { if ($p.DX -ne 0 -or $p.DY -ne 0) { Set-ElementAt $p.Sprite $p.X $p.Y } }
    foreach ($pr in $R.Projectiles) { Set-SpritePosition $pr; $pr.Sprite.Tag.Rotate.Angle = ($R.Time * 720 * $pr.Dir) % 360 }
    foreach ($goal in $A.Goals) {
        $shut = [bool](Get-RequirementGap (Get-ExitRequirement $goal.Exit))
        $goal.Sprite.Opacity = if ($shut) { 0.4 } else { 1.0 }
    }
    foreach ($ps2 in $A.PopSpikes) { Set-PopSpikeLook $ps2 }
}

function Update-Hud {
    $R = $script:Run
    $coins = $R.Slot.coins
    $here = 0
    foreach ($p in $R.Pending) { if ($p.Kind -eq 'coin') { $coins += $p.Value; $here += $p.Value } }
    $clock = if ($R.TimeLimit -gt 0) { "Time left $([math]::Max(0, [math]::Ceiling($R.TimeLimit - $R.LifeTime)))" } else { "Time $(Format-Time $R.Time)" }
    $livesLeft = Get-SlotLives $R.Slot
    $HudRight.Text = if ($R.MiniGame) { "Coins won $here     $clock" }
                     else { "Coins $coins     $clock     " + $(if ($null -ne $livesLeft) { "Lives $livesLeft     " } else { '' }) + "Deaths $($R.Stats.deaths)" }

    $parts = New-Object System.Collections.Generic.List[string]
    $health = if ($R.Power) {
        "Health: Powered ($($R.Power.Name)" + $(if ($R.PowerHits -gt 1) { " x$($R.PowerHits)" } else { '' }) + $(if ($R.PowerTimer -gt 0) { " $([math]::Ceiling($R.PowerTimer))s" } else { '' }) + ')'
    } else { 'Health: Normal' }
    if ($R.InvincibleTimer -gt 0) { $health += "  +  Invincible $([math]::Ceiling($R.InvincibleTimer))s" }
    $parts.Add($health)
    if ($R.Mount) { $parts.Add("Riding: $($R.Mount.Def.Name)") }
    if ($R.SpeedTimer -gt 0) { $parts.Add("Speed $([math]::Ceiling($R.SpeedTimer))s") }
    foreach ($k in @($R.Inv.Keys)) {
        $n = [int]$R.Inv[$k]
        if ($n -gt 0) { $parts.Add("$k key" + $(if ($n -gt 1) { " x$n" } else { '' })) }
    }
    if ($R.Stash.Count) { $parts.Add("Bag $(Get-InventoryCount)/$InventorySize") }
    if ($R.Level.Collectibles -and -not $R.MiniGame) { $parts.Add("Found $($R.CollectiblesFound)/$($R.Level.Collectibles)") }
    if ($R.Twist) { $parts.Add("Twist: $($R.Twist.Name)") }
    $tet = Get-TetroCollection $R.Slot
    if ($tet.Count -gt 0 -and -not $R.MiniGame) { $parts.Add("Tetrominoes $($tet.Count)/$($TetroNames.Count)") }
    $S = if ($R.A) { $R.A.Survival } else { $null }
    if ($S -and $S.State -eq 'active') { $parts.Add("SURVIVE $([math]::Ceiling($S.Timer))s") }
    foreach ($en in $R.A.Enemies) {
        if ($en.Def.Boss -and -not $en.Dead -and $en.Active) { $parts.Add("$($en.Def.Name) $([string][char]0x2665 * [math]::Max(0, $en.Health))"); break }
    }
    $req = Get-ExitRequirement 'G'
    if ($req -and -not $R.MiniGame) {
        $gap = Get-RequirementGap $req
        $parts.Add($(if ($gap) { "Exit: $gap" } else { 'Exit open!' }))
    }
    $text = $parts -join '      '
    if ($HudPower.Text -ne $text) {
        $HudPower.Text = $text
        $HudPower.Visibility = 'Visible'
    }
}

# ---------------------------------------------------------------------------
# Sample world (shows every feature of the zip format)
# ---------------------------------------------------------------------------
function New-Png([int]$Width, [int]$Height, [scriptblock]$Draw) {
    $visual = New-Object System.Windows.Media.DrawingVisual
    $dc = $visual.RenderOpen()
    & $Draw $dc
    $dc.Close()
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($Width, $Height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($visual)
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $ms = New-Object System.IO.MemoryStream
    $encoder.Save($ms)
    return , $ms.ToArray()      # the comma stops PowerShell unrolling the byte array
}

function Get-Geo([string]$Path) { [System.Windows.Media.Geometry]::Parse($Path) }
function New-Pen([string]$Color, [double]$Width) { New-Object System.Windows.Media.Pen((ConvertTo-Brush $Color), $Width) }

function Get-HillGeometry([double]$Base, [double]$Amp, [int]$K1, [int]$K2, [double]$Phase) {
    # Whole-number wave counts make the edges match, so the image tiles seamlessly
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('M0,544 ')
    for ($x = 0; $x -le 960; $x += 16) {
        $y = $Base + $Amp * [math]::Sin(2 * [math]::PI * $K1 * $x / 960 + $Phase) + $Amp * 0.4 * [math]::Sin(2 * [math]::PI * $K2 * $x / 960)
        [void]$sb.Append("L$x,$([int][math]::Round($y)) ")
    }
    [void]$sb.Append('L960,544 Z')
    Get-Geo $sb.ToString()
}

function Draw-SampleBackground($dc) {
    $sky = New-Object System.Windows.Media.LinearGradientBrush(
        [System.Windows.Media.Color]::FromRgb(0x7E, 0xC8, 0xF2), [System.Windows.Media.Color]::FromRgb(0xD8, 0xF1, 0xFF), 90.0)
    $dc.DrawRectangle($sky, $null, (New-Rect 0 0 960 544))
    $dc.DrawEllipse((ConvertTo-Brush '#FFF6C2'), $null, (New-Point 780 120), 46, 46)
    $cloud = ConvertTo-Brush '#EEFFFFFF'
    foreach ($c in @(@(140, 90), @(470, 150), @(640, 70))) {
        $dc.DrawEllipse($cloud, $null, (New-Point $c[0] $c[1]), 42, 20)
        $dc.DrawEllipse($cloud, $null, (New-Point ($c[0] + 34) ($c[1] - 10)), 30, 20)
        $dc.DrawEllipse($cloud, $null, (New-Point ($c[0] - 32) ($c[1] + 4)), 26, 14)
    }
    $dc.DrawGeometry((ConvertTo-Brush '#A7D9A0'), $null, (Get-HillGeometry 370 30 2 5 0.5))
    $dc.DrawGeometry((ConvertTo-Brush '#74C365'), $null, (Get-HillGeometry 450 24 3 7 1.7))
}

function Draw-SpaceBackground($dc) {
    $sky = New-Object System.Windows.Media.LinearGradientBrush(
        [System.Windows.Media.Color]::FromRgb(0x0B, 0x10, 0x30), [System.Windows.Media.Color]::FromRgb(0x2A, 0x33, 0x6B), 90.0)
    $dc.DrawRectangle($sky, $null, (New-Rect 0 0 960 544))
    $rng = New-Object System.Random 7
    $star = ConvertTo-Brush '#DDFFFFFF'
    for ($i = 0; $i -lt 90; $i++) {
        $r = 0.6 + $rng.NextDouble() * 1.4
        $dc.DrawEllipse($star, $null, (New-Point ($rng.Next(4, 956)) ($rng.Next(4, 380))), $r, $r)
    }
    $dc.DrawEllipse((ConvertTo-Brush '#7FA6C8FF'), $null, (New-Point 200 130), 60, 60)
    $dc.DrawEllipse((ConvertTo-Brush '#E8EEF7'), $null, (New-Point 200 130), 54, 54)
    $dc.DrawEllipse((ConvertTo-Brush '#C9D3E3'), $null, (New-Point 182 112), 11, 11)
    $dc.DrawEllipse((ConvertTo-Brush '#C9D3E3'), $null, (New-Point 220 150), 8, 8)
    $dc.DrawGeometry((ConvertTo-Brush '#3B4680'), $null, (Get-HillGeometry 430 26 2 6 0.3))
    $dc.DrawGeometry((ConvertTo-Brush '#2B3466'), $null, (Get-HillGeometry 480 18 3 5 2.1))
}

# The sample hero (32 wide, 44 tall) in a few poses, used for the animation demo
function Draw-Hero($dc, [string]$Pose) {
    $black = [System.Windows.Media.Brushes]::Black
    $skin = ConvertTo-Brush '#FFD7B0'; $shirt = ConvertTo-Brush '#3D7BFF'; $pants = ConvertTo-Brush '#1E2A5A'
    $scarf = ConvertTo-Brush '#E53935'; $hair = ConvertTo-Brush '#5D4037'
    switch ($Pose) {
        'sleep' {
            # 32 x 28: curled up, head nodding, eyes shut
            $dc.DrawRectangle($pants, $null, (New-Rect 5 23 10 5)); $dc.DrawRectangle($pants, $null, (New-Rect 15 24 10 4))
            $dc.DrawRoundedRectangle($shirt, $null, (New-Rect 5 13 20 12), 6, 6)
            $dc.DrawRectangle($scarf, $null, (New-Rect 5 14 20 3)); $dc.DrawRectangle($scarf, $null, (New-Rect 1 16 5 3))
            $dc.DrawEllipse($skin, $null, (New-Point 19 11), 8, 7.5)
            $dc.DrawGeometry($hair, $null, (Get-Geo 'M11,11 C11,2 27,2 27,8 L20,7 L15,11 Z'))
            $dc.DrawGeometry($null, (New-Pen '#3E2723' 1.4), (Get-Geo 'M20,12 Q22.5,14 25,12'))
            $dc.DrawEllipse((ConvertTo-Brush '#AAFFFFFF'), (New-Pen '#81D4FA' 1), (New-Point 26.5 15.5), 2, 2)
        }
        'crouch' {
            # 32 x 28
            $dc.DrawRectangle($pants, $null, (New-Rect 7 23 8 5)); $dc.DrawRectangle($pants, $null, (New-Rect 17 23 8 5))
            $dc.DrawRoundedRectangle($shirt, $null, (New-Rect 6 12 20 12), 5, 5)
            $dc.DrawRectangle($scarf, $null, (New-Rect 6 13 20 3)); $dc.DrawRectangle($scarf, $null, (New-Rect 2 14 5 3))
            $dc.DrawEllipse($skin, $null, (New-Point 17 8), 8, 7.5)
            $dc.DrawGeometry($hair, $null, (Get-Geo 'M9,8 C9,-1 25,-1 25,5 L18,4 L13,8 Z'))
            $dc.DrawEllipse($black, $null, (New-Point 20.5 8.5), 1.6, 2.2)
        }
        'ball' {
            # 26 x 26, spun by the animation
            $dc.DrawEllipse($shirt, (New-Pen '#1E2A5A' 2), (New-Point 13 13), 12, 12)
            $dc.DrawRectangle($scarf, $null, (New-Rect 3 11 20 4))
            $dc.DrawEllipse($skin, $null, (New-Point 17 7), 4, 3.5)
            $dc.DrawEllipse((ConvertTo-Brush '#80FFFFFF'), $null, (New-Point 8 7), 3, 2)
        }
        default {
            # 32 x 44: idle, run1, run2, jump
            $legs = switch ($Pose) {
                'run1' { @(@(7, 31, 5, 9), @(20, 30, 5, 9)) }
                'run2' { @(@(12, 31, 5, 10), @(15, 31, 5, 10)) }
                'jump' { @(@(9, 30, 5, 7), @(19, 28, 5, 7)) }
                default { @(@(10, 31, 5, 10), @(18, 31, 5, 10)) }
            }
            foreach ($l in $legs) {
                $dc.DrawRectangle($pants, $null, (New-Rect $l[0] $l[1] $l[2] $l[3]))
                $dc.DrawRectangle($pants, $null, (New-Rect ($l[0] - 1) ($l[1] + $l[3]) ($l[2] + 2) 3))
            }
            $dc.DrawRoundedRectangle($shirt, $null, (New-Rect 7 16 18 17), 5, 5)
            $dc.DrawRectangle($scarf, $null, (New-Rect 7 18 18 3))
            $dc.DrawRectangle($scarf, $null, (New-Rect $(if ($Pose -eq 'idle') { 3 } else { 1 }) 19 5 3))
            $dc.DrawEllipse($skin, $null, (New-Point 16 9), 8, 8)
            $dc.DrawGeometry($hair, $null, (Get-Geo 'M8,9 C8,-1 24,-1 24,5 L17,4 L12,9 Z'))
            $dc.DrawEllipse($black, $null, (New-Point 19.5 9.5), 1.6, 2.2)
        }
    }
}

function Draw-Ghost($dc, [bool]$Shy, [string]$Color) {
    $body = ConvertTo-Brush $Color
    $dc.DrawGeometry($body, (New-Pen '#B0BEC5' 1), (Get-Geo 'M3,28 L3,13 C3,4 9,1 16,1 C23,1 29,4 29,13 L29,28 L24,24 L20,28 L16,24 L12,28 L8,24 Z'))
    if ($Shy) {
        $dc.DrawEllipse((ConvertTo-Brush '#F8BBD0'), $null, (New-Point 9 15), 3, 2)
        $dc.DrawEllipse((ConvertTo-Brush '#F8BBD0'), $null, (New-Point 23 15), 3, 2)
        $dc.DrawRoundedRectangle($body, (New-Pen '#B0BEC5' 1), (New-Rect 6 8 9 7), 3, 3)
        $dc.DrawRoundedRectangle($body, (New-Pen '#B0BEC5' 1), (New-Rect 17 8 9 7), 3, 3)
    }
    else {
        $dc.DrawEllipse([System.Windows.Media.Brushes]::Black, $null, (New-Point 11 12), 2.5, 3.5)
        $dc.DrawEllipse([System.Windows.Media.Brushes]::Black, $null, (New-Point 21 12), 2.5, 3.5)
        $dc.DrawGeometry((ConvertTo-Brush '#E57373'), $null, (Get-Geo 'M11,19 Q16,24 21,19 Z'))
    }
}

function Add-NewSampleAssets($files) {
    $black = [System.Windows.Media.Brushes]::Black
    $white = [System.Windows.Media.Brushes]::White

    foreach ($pose in 'idle', 'run1', 'run2', 'jump') {
        $p = $pose
        $name = if ($pose -eq 'idle') { 'player/player.png' } else { "player/$pose.png" }
        $files[$name] = New-Png 32 44 { param($dc) Draw-Hero $dc $p }
    }
    $files['player/crouch.png'] = New-Png 32 28 { param($dc) Draw-Hero $dc 'crouch' }
    $files['player/sleep.png']  = New-Png 32 28 { param($dc) Draw-Hero $dc 'sleep' }
    $files['player/ball.png']   = New-Png 26 26 { param($dc) Draw-Hero $dc 'ball' }

    $files['enemies/slime2.png'] = New-Png 32 24 { param($dc)
        $dc.DrawGeometry((ConvertTo-Brush '#66D17A'), (New-Pen '#2E8B57' 2), (Get-Geo 'M1,23 C1,12 7,7 16,7 C25,7 31,12 31,23 Z'))
        foreach ($ex in 13, 21) {
            $dc.DrawEllipse($white, $null, (New-Point $ex 15), 3.5, 3.5)
            $dc.DrawEllipse($black, $null, (New-Point ($ex + 1) 16), 1.8, 2)
        }
    }
    $files['enemies/bat2.png'] = New-Png 32 24 { param($dc)
        $wing = ConvertTo-Brush '#7E57C2'
        $dc.DrawGeometry($wing, $null, (Get-Geo 'M16,12 L2,18 L6,13 L1,10 L8,11 L11,7 L16,10 Z'))
        $dc.DrawGeometry($wing, $null, (Get-Geo 'M16,12 L30,18 L26,13 L31,10 L24,11 L21,7 L16,10 Z'))
        $dc.DrawGeometry((ConvertTo-Brush '#5E35B1'), $null, (Get-Geo 'M11,8 L12,2 L15,7 Z M21,8 L20,2 L17,7 Z'))
        $dc.DrawEllipse((ConvertTo-Brush '#5E35B1'), $null, (New-Point 16 13), 6, 7)
        $dc.DrawEllipse((ConvertTo-Brush '#FFEB3B'), $null, (New-Point 14 11), 1.5, 1.5)
        $dc.DrawEllipse((ConvertTo-Brush '#FFEB3B'), $null, (New-Point 18 11), 1.5, 1.5)
    }
    $files['enemies/eel.png'] = New-Png 38 16 { param($dc)
        $dc.DrawGeometry((ConvertTo-Brush '#26A69A'), (New-Pen '#00695C' 1.5), (Get-Geo 'M1,8 C6,1 12,13 18,6 C24,1 30,3 36,7 C30,13 24,15 18,11 C12,15 6,13 1,8 Z'))
        $dc.DrawEllipse($white, $null, (New-Point 31 6), 2.2, 2.2)
        $dc.DrawEllipse($black, $null, (New-Point 32 6), 1.1, 1.1)
    }
    $files['enemies/ghost.png']     = New-Png 32 30 { param($dc) Draw-Ghost $dc $false '#F5F7FA' }
    $files['enemies/ghost-shy.png'] = New-Png 32 30 { param($dc) Draw-Ghost $dc $true '#F5F7FA' }
    $files['enemies/shy-ghost.png'] = New-Png 32 32 { param($dc) Draw-Ghost $dc $false '#D1C4E9' }
    $files['objects/shy-block.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRoundedRectangle((ConvertTo-Brush '#7E57C2'), (New-Pen '#4527A0' 2), (New-Rect 1 1 30 30), 5, 5)
        $dc.DrawRectangle((ConvertTo-Brush '#9575CD'), $null, (New-Rect 4 4 24 4))
        $dc.DrawGeometry($null, (New-Pen '#311B92' 2), (Get-Geo 'M8,17 Q11,20 14,17 M18,17 Q21,20 24,17'))
    }
    $files['enemies/frog.png'] = New-Png 32 24 { param($dc)
        $dc.DrawEllipse((ConvertTo-Brush '#7CB342'), (New-Pen '#33691E' 1.5), (New-Point 16 16), 13, 8)
        foreach ($ex in 11, 21) { $dc.DrawEllipse((ConvertTo-Brush '#7CB342'), (New-Pen '#33691E' 1.5), (New-Point $ex 7), 4, 4); $dc.DrawEllipse($black, $null, (New-Point ($ex + 1) 7), 1.6, 1.6) }
        $dc.DrawRectangle((ConvertTo-Brush '#33691E'), $null, (New-Rect 4 21 8 3)); $dc.DrawRectangle((ConvertTo-Brush '#33691E'), $null, (New-Rect 20 21 8 3))
    }
    $files['enemies/frog-jump.png'] = New-Png 32 30 { param($dc)
        $dc.DrawEllipse((ConvertTo-Brush '#7CB342'), (New-Pen '#33691E' 1.5), (New-Point 16 13), 10, 10)
        foreach ($ex in 11, 21) { $dc.DrawEllipse((ConvertTo-Brush '#7CB342'), (New-Pen '#33691E' 1.5), (New-Point $ex 4), 4, 4); $dc.DrawEllipse($black, $null, (New-Point ($ex + 1) 4), 1.6, 1.6) }
        $dc.DrawGeometry((ConvertTo-Brush '#33691E'), $null, (Get-Geo 'M8,20 L3,30 L7,30 L12,22 Z M24,20 L29,30 L25,30 L20,22 Z'))
    }

    $files['tiles/platform.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#A1887F'), (New-Pen '#4E342E' 1.5), (New-Rect 0 1 32 14))
        $dc.DrawRectangle((ConvertTo-Brush '#D7CCC8'), $null, (New-Rect 2 3 28 3))
        $dc.DrawRectangle((ConvertTo-Brush '#6D4C41'), $null, (New-Rect 15 1 2 14))
        $dc.DrawRectangle((ConvertTo-Brush '#00000000'), $null, (New-Rect 0 15 32 17))
    }
    $files['tiles/crusher.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#607D8B'), (New-Pen '#263238' 2), (New-Rect 1 1 30 30))
        $dc.DrawRectangle((ConvertTo-Brush '#90A4AE'), $null, (New-Rect 3 3 26 4))
        foreach ($p in @(@(6, 10), @(26, 10), @(6, 26), @(26, 26))) { $dc.DrawEllipse((ConvertTo-Brush '#CFD8DC'), $null, (New-Point $p[0] $p[1]), 2, 2) }
    }
    $files['tiles/quicksand.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#F2C9A35E'), $null, (New-Rect 0 0 32 32))
        foreach ($d in @(@(5, 6), @(19, 4), @(12, 15), @(26, 13), @(7, 24), @(21, 27), @(29, 22))) {
            $dc.DrawEllipse((ConvertTo-Brush '#C0A07A40'), $null, (New-Point $d[0] $d[1]), 1.6, 1.2)
        }
        $dc.DrawGeometry($null, (New-Pen '#80E0C48A' 1), (Get-Geo 'M2,10 Q8,8 14,10 M18,20 Q24,18 30,20'))
    }
    $files['tiles/lava.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#E6D84315'), $null, (New-Rect 0 0 32 32))
        $dc.DrawEllipse((ConvertTo-Brush '#CCFF9800'), $null, (New-Point 9 10), 4, 3)
        $dc.DrawEllipse((ConvertTo-Brush '#CCFFC107'), $null, (New-Point 23 22), 3, 2)
    }
    $files['tiles/lava-surface.png'] = New-Png 32 8 { param($dc)
        $dc.DrawGeometry((ConvertTo-Brush '#FFFFB74D'), $null, (Get-Geo 'M0,4 Q8,0 16,4 T32,4 L32,8 L0,8 Z'))
    }
    $files['tiles/water-surface.png'] = New-Png 32 8 { param($dc)
        $dc.DrawGeometry((ConvertTo-Brush '#B0E3F2FD'), $null, (Get-Geo 'M0,4 Q8,0 16,4 T32,4 L32,8 L0,8 Z'))
    }
    $files['objects/ice-block.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRoundedRectangle((ConvertTo-Brush '#A0B3E5FC'), (New-Pen '#4FC3F7' 2), (New-Rect 1 1 30 30), 3, 3)
        $dc.DrawGeometry((ConvertTo-Brush '#D0FFFFFF'), $null, (Get-Geo 'M5,5 L13,5 L5,13 Z'))
        $dc.DrawGeometry($null, (New-Pen '#E1F5FE' 1), (Get-Geo 'M20,24 L26,18'))
    }
    $files['objects/iceball.png'] = New-Png 12 12 { param($dc)
        $dc.DrawEllipse((ConvertTo-Brush '#81D4FA'), $null, (New-Point 6 6), 6, 6)
        $dc.DrawEllipse($white, $null, (New-Point 6 6), 2.5, 2.5)
    }
    $files['items/ice-flower.png'] = New-Png 24 24 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#43A047'), $null, (New-Rect 11 12 2 12))
        foreach ($p in @(@(12, 4), @(18, 9), @(6, 9), @(12, 13))) { $dc.DrawEllipse((ConvertTo-Brush '#4FC3F7'), $null, (New-Point $p[0] $p[1]), 4.5, 4.5) }
        $dc.DrawEllipse($white, $null, (New-Point 12 8.5), 3.5, 3.5)
    }
}

# The Block Golem, built from coloured blocks
function Draw-Golem($dc, [string]$Mood) {
    $cols = '#29B6F6', '#FFEE58', '#AB47BC', '#66BB6A', '#EF5350', '#3F51B5', '#FF9800'
    $body = @(@(2, 0), @(3, 0), @(1, 1), @(2, 1), @(3, 1), @(4, 1), @(1, 2), @(2, 2), @(3, 2), @(4, 2),
              @(0, 3), @(1, 3), @(2, 3), @(3, 3), @(4, 3), @(5, 3), @(0, 4), @(1, 4), @(2, 4), @(3, 4), @(4, 4), @(5, 4),
              @(1, 5), @(2, 5), @(3, 5), @(4, 5), @(1, 6), @(4, 6))
    foreach ($b in $body) {
        $dc.DrawRectangle((ConvertTo-Brush $cols[($b[0] * 3 + $b[1] * 5) % 7]), (New-Pen '#55000000' 1), (New-Rect ($b[0] * 9 + 1) ($b[1] * 8 + 3) 9 8))
    }
    $white = [System.Windows.Media.Brushes]::White; $black = [System.Windows.Media.Brushes]::Black
    switch ($Mood) {
        'dizzy' {
            foreach ($ex in 21, 32) { $dc.DrawRectangle($white, $null, (New-Rect $ex 13 6 6)); $dc.DrawGeometry($null, (New-Pen '#000000' 1.5), (Get-Geo "M$ex,13 L$($ex + 6),19 M$($ex + 6),13 L$ex,19")) }
            $dc.DrawEllipse($null, (New-Pen '#000000' 2), (New-Point 29 25), 4, 2.5)
            foreach ($st in @(@(8, 2), @(46, 4), @(27, 0))) { $dc.DrawGeometry((ConvertTo-Brush '#FFEB3B'), (New-Pen '#F57F17' 1), (Get-Geo "M$($st[0]),$($st[1] + 3) L$($st[0] + 2),$($st[1]) L$($st[0] + 4),$($st[1] + 3) L$($st[0] + 2),$($st[1] + 6) Z")) }
        }
        'angry' {
            foreach ($ex in 21, 32) { $dc.DrawRectangle($white, $null, (New-Rect $ex 13 6 6)); $dc.DrawRectangle((ConvertTo-Brush '#D50000'), $null, (New-Rect ($ex + 2) 15 3 3)) }
            $dc.DrawGeometry($null, (New-Pen '#000000' 2), (Get-Geo 'M20,11 L27,14 M38,11 L31,14'))
            $dc.DrawRectangle($black, $null, (New-Rect 22 23 14 3))
        }
        default {
            foreach ($ex in 21, 32) { $dc.DrawRectangle($white, $null, (New-Rect $ex 13 6 6)); $dc.DrawRectangle($black, $null, (New-Rect ($ex + 2) 15 3 3)) }
            $dc.DrawRectangle($black, $null, (New-Rect 22 23 14 3))
        }
    }
}

# Pictures for the gadget level, the arena, the mini-games and the sample expansion
function Add-GadgetAssets($files) {
    $black = [System.Windows.Media.Brushes]::Black
    $white = [System.Windows.Media.Brushes]::White

    # ---- Tiles ----
    $files['tiles/ladder.png'] = New-Png 32 32 { param($dc)
        $wood = ConvertTo-Brush '#A1662F'
        $dc.DrawRectangle($wood, $null, (New-Rect 5 0 4 32)); $dc.DrawRectangle($wood, $null, (New-Rect 23 0 4 32))
        foreach ($y in 4, 14, 24) { $dc.DrawRectangle((ConvertTo-Brush '#C68642'), $null, (New-Rect 5 $y 22 4)) }
    }
    $files['tiles/spring.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#546E7A'), $null, (New-Rect 0 26 32 6))
        $dc.DrawGeometry($null, (New-Pen '#B0BEC5' 3), (Get-Geo 'M6,26 L26,21 L6,16 L26,11'))
        $dc.DrawRoundedRectangle((ConvertTo-Brush '#E53935'), (New-Pen '#8E0000' 1.5), (New-Rect 1 3 30 8), 3, 3)
    }
    $files['tiles/ice.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#B3E5FC'), (New-Pen '#4FC3F7' 1), (New-Rect 0.5 0.5 31 31))
        $dc.DrawGeometry($null, (New-Pen '#FFFFFF' 2), (Get-Geo 'M4,8 L12,4 M18,20 L28,14 M6,26 L10,24'))
    }
    $files['tiles/conveyor.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#37474F'), $null, (New-Rect 0 0 32 32))
        $dc.DrawRectangle((ConvertTo-Brush '#263238'), $null, (New-Rect 0 0 32 7))
        $dc.DrawGeometry((ConvertTo-Brush '#FFC83D'), $null, (Get-Geo 'M6,12 L16,18 L6,24 Z M18,12 L28,18 L18,24 Z'))
    }
    $files['tiles/oneway.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#8D6E63'), (New-Pen '#4E342E' 1.5), (New-Rect 0.5 0.5 31 9))
        $dc.DrawRectangle((ConvertTo-Brush '#6D4C41'), $null, (New-Rect 6 10 3 6)); $dc.DrawRectangle((ConvertTo-Brush '#6D4C41'), $null, (New-Rect 23 10 3 6))
    }
    $files['tiles/cracked.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#B5653A'), $null, (New-Rect 0 0 32 32))
        foreach ($r in @(@(0, 15, 32, 2), @(0, 30, 32, 2), @(15, 0, 2, 15), @(7, 17, 2, 13), @(23, 17, 2, 13))) { $dc.DrawRectangle((ConvertTo-Brush '#6D3418'), $null, (New-Rect $r[0] $r[1] $r[2] $r[3])) }
        $dc.DrawGeometry($null, (New-Pen '#3E1C0A' 1.5), (Get-Geo 'M9,3 L13,9 L10,13 M20,19 L24,24 L21,29'))
    }
    $files['tiles/qblock.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRoundedRectangle((ConvertTo-Brush '#FFB300'), (New-Pen '#8D5A00' 2), (New-Rect 1 1 30 30), 4, 4)
        $txt = New-Object System.Windows.Media.FormattedText('?', [Globalization.CultureInfo]::InvariantCulture, 'LeftToRight', (New-Object System.Windows.Media.Typeface 'Segoe UI Black'), 24, $white, 1.0)
        $dc.DrawText($txt, (New-Point 9 -1))
    }
    $files['tiles/used.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRoundedRectangle((ConvertTo-Brush '#8D6E63'), (New-Pen '#4E342E' 2), (New-Rect 1 1 30 30), 4, 4)
        foreach ($p in @(@(5, 5), @(25, 5), @(5, 25), @(25, 25))) { $dc.DrawEllipse((ConvertTo-Brush '#4E342E'), $null, (New-Point $p[0] $p[1]), 1.6, 1.6) }
    }
    $files['tiles/crumble.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#BCAAA4'), (New-Pen '#795548' 1.5), (New-Rect 0.5 0.5 31 31))
        $dc.DrawGeometry($null, (New-Pen '#795548' 1.5), (Get-Geo 'M3,10 L12,14 L9,22 L16,30 M20,2 L18,12 L28,18'))
    }
    $files['tiles/switch.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRoundedRectangle((ConvertTo-Brush '#E53935'), (New-Pen '#7F0000' 2), (New-Rect 1 1 30 30), 4, 4)
        $dc.DrawEllipse($white, $null, (New-Point 16 16), 8, 8)
        $dc.DrawEllipse((ConvertTo-Brush '#E53935'), $null, (New-Point 16 16), 4, 4)
    }
    $files['tiles/toggle.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#EF5350'), (New-Pen '#B71C1C' 2), (New-Rect 1 1 30 30))
        $dc.DrawGeometry($null, (New-Pen '#FFCDD2' 2), (Get-Geo 'M6,6 L26,26 M26,6 L6,26'))
    }
    $files['tiles/gate.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#4527A0'), $null, (New-Rect 0 0 32 32))
        foreach ($x in 4, 13, 22) { $dc.DrawRectangle((ConvertTo-Brush '#9575CD'), $null, (New-Rect $x 0 6 32)) }
    }
    $files['tiles/cloud.png'] = New-Png 32 32 { param($dc)
        $dc.DrawGeometry($white, (New-Pen '#B3E5FC' 1.5), (Get-Geo 'M2,12 C2,4 10,2 14,6 C17,1 26,2 27,8 C32,8 32,15 28,15 L4,15 C1,15 1,13 2,12 Z'))
    }
    $files['objects/spawner.png'] = New-Png 32 32 { param($dc)
        $dc.DrawEllipse((ConvertTo-Brush '#66311B92'), (New-Pen '#7E57C2' 2), (New-Point 16 16), 13, 13)
        $dc.DrawEllipse((ConvertTo-Brush '#AA000000'), $null, (New-Point 16 16), 7, 7)
    }

    # ---- Items ----
    $files['items/helmet.png'] = New-Png 26 22 { param($dc)
        $dc.DrawGeometry((ConvertTo-Brush '#90A4AE'), (New-Pen '#37474F' 2), (Get-Geo 'M2,18 C2,6 8,2 13,2 C18,2 24,6 24,18 Z'))
        $dc.DrawRectangle((ConvertTo-Brush '#546E7A'), $null, (New-Rect 0 17 26 4))
        $dc.DrawEllipse((ConvertTo-Brush '#CFD8DC'), $null, (New-Point 9 8), 2.5, 2)
    }
    $files['items/wand.png'] = New-Png 22 26 { param($dc)
        $dc.DrawLine((New-Pen '#8D6E63' 3), (New-Point 4 24), (New-Point 15 10))
        $dc.DrawEllipse((ConvertTo-Brush '#8081D4FA'), (New-Pen '#0288D1' 1.5), (New-Point 15 8), 6, 6)
        $dc.DrawEllipse($white, $null, (New-Point 13 6), 1.5, 1.5)
    }
    $files['objects/bubble.png'] = New-Png 16 16 { param($dc)
        $dc.DrawEllipse((ConvertTo-Brush '#6681D4FA'), (New-Pen '#0288D1' 1.5), (New-Point 8 8), 7, 7)
        $dc.DrawEllipse($white, $null, (New-Point 5.5 5.5), 1.8, 1.8)
    }
    $files['items/oneup.png'] = New-Png 22 22 { param($dc)
        $dc.DrawGeometry((ConvertTo-Brush '#43A047'), (New-Pen '#1B5E20' 1.5), (Get-Geo 'M11,20 C2,14 0,8 4,4 C7,1 10,3 11,6 C12,3 15,1 18,4 C22,8 20,14 11,20 Z'))
        $txt = New-Object System.Windows.Media.FormattedText('1', [Globalization.CultureInfo]::InvariantCulture, 'LeftToRight', (New-Object System.Windows.Media.Typeface 'Segoe UI Black'), 10, $white, 1.0)
        $dc.DrawText($txt, (New-Point 8 4))
    }
    $files['items/cape.png'] = New-Png 24 24 { param($dc)
        $dc.DrawGeometry((ConvertTo-Brush '#7E57C2'), (New-Pen '#4527A0' 1.5), (Get-Geo 'M6,2 L18,2 L22,22 L12,18 L2,22 Z'))
        $dc.DrawRectangle((ConvertTo-Brush '#FFC83D'), $null, (New-Rect 6 2 12 3))
    }
    $files['objects/seed.png'] = New-Png 12 12 { param($dc)
        $dc.DrawEllipse((ConvertTo-Brush '#FF7043'), (New-Pen '#BF360C' 1.5), (New-Point 6 6), 5, 5)
    }
    $files['objects/goo.png'] = New-Png 14 14 { param($dc)
        $dc.DrawEllipse((ConvertTo-Brush '#66D17A'), (New-Pen '#2E8B57' 1.5), (New-Point 7 7), 6, 6)
    }

    # ---- Enemies ----
    $files['enemies/turtle.png'] = New-Png 32 28 { param($dc)
        $dc.DrawEllipse((ConvertTo-Brush '#FFE082'), (New-Pen '#8D6E00' 1.5), (New-Point 27 13), 5, 5)
        $dc.DrawEllipse($black, $null, (New-Point 28 12), 1.2, 1.4)
        $dc.DrawRectangle((ConvertTo-Brush '#FFE082'), $null, (New-Rect 8 21 5 7)); $dc.DrawRectangle((ConvertTo-Brush '#FFE082'), $null, (New-Rect 19 21 5 7))
        $dc.DrawGeometry((ConvertTo-Brush '#43A047'), (New-Pen '#1B5E20' 2), (Get-Geo 'M2,22 C2,8 8,4 15,4 C22,4 26,10 26,22 Z'))
        $dc.DrawGeometry($null, (New-Pen '#A5D6A7' 1.5), (Get-Geo 'M8,12 L14,8 L20,12 L14,17 Z'))
    }
    $files['enemies/shell.png'] = New-Png 28 20 { param($dc)
        $dc.DrawGeometry((ConvertTo-Brush '#43A047'), (New-Pen '#1B5E20' 2), (Get-Geo 'M1,18 C1,5 7,1 14,1 C21,1 27,5 27,18 Z'))
        $dc.DrawRectangle((ConvertTo-Brush '#FFF59D'), $null, (New-Rect 2 15 24 4))
        $dc.DrawGeometry($null, (New-Pen '#A5D6A7' 1.5), (Get-Geo 'M8,9 L14,5 L20,9 L14,13 Z'))
    }
    $files['enemies/plant.png'] = New-Png 30 40 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#2E7D32'), $null, (New-Rect 13 18 4 22))
        $dc.DrawGeometry((ConvertTo-Brush '#66BB6A'), $null, (Get-Geo 'M15,30 C8,24 3,28 2,32 C8,32 12,32 15,30 Z M15,30 C22,24 27,28 28,32 C22,32 18,32 15,30 Z'))
        $dc.DrawEllipse((ConvertTo-Brush '#E53935'), (New-Pen '#8E0000' 1.5), (New-Point 15 11), 11, 10)
        foreach ($p in @(@(9, 7), @(19, 6), @(14, 15), @(21, 13))) { $dc.DrawEllipse($white, $null, (New-Point $p[0] $p[1]), 1.8, 1.8) }
        $dc.DrawGeometry($black, $null, (Get-Geo 'M20,10 L28,8 L28,14 Z'))
    }
    $files['enemies/boar.png'] = New-Png 40 28 { param($dc)
        foreach ($x in 8, 14, 25, 31) { $dc.DrawRectangle((ConvertTo-Brush '#4E342E'), $null, (New-Rect $x 20 4 8)) }
        $dc.DrawEllipse((ConvertTo-Brush '#795548'), (New-Pen '#3E2723' 1.5), (New-Point 19 15), 16, 9)
        $dc.DrawEllipse((ConvertTo-Brush '#8D6E63'), (New-Pen '#3E2723' 1.5), (New-Point 34 15), 6, 6)
        $dc.DrawGeometry($white, $null, (Get-Geo 'M37,17 L40,12 L38,18 Z'))
        $dc.DrawEllipse($black, $null, (New-Point 34 12), 1.4, 1.4)
    }
    $files['enemies/boar-charge.png'] = New-Png 40 28 { param($dc)
        foreach ($x in 4, 12, 24, 34) { $dc.DrawRectangle((ConvertTo-Brush '#4E342E'), $null, (New-Rect $x 21 4 7)) }
        $dc.DrawEllipse((ConvertTo-Brush '#A1887F'), (New-Pen '#3E2723' 1.5), (New-Point 19 15), 17, 8)
        $dc.DrawEllipse((ConvertTo-Brush '#BCAAA4'), (New-Pen '#3E2723' 1.5), (New-Point 34 15), 6, 6)
        $dc.DrawGeometry($white, $null, (Get-Geo 'M37,17 L40,12 L38,18 Z'))
        $dc.DrawEllipse((ConvertTo-Brush '#E53935'), $null, (New-Point 34 12), 1.6, 1.6)
    }
    $files['enemies/stoneface.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#78909C'), (New-Pen '#37474F' 2), (New-Rect 1 1 30 30))
        $dc.DrawGeometry((ConvertTo-Brush '#37474F'), $null, (Get-Geo 'M6,10 L13,13 L6,14 Z M26,10 L19,13 L26,14 Z M8,22 L24,22 L24,25 L8,25 Z'))
        foreach ($x in 3, 27) { $dc.DrawGeometry((ConvertTo-Brush '#B0BEC5'), $null, (Get-Geo "M$x,31 L$($x + 1),27 L$($x + 2),31 Z")) }
    }
    # The Block Golem (Greenwood Heights boss) and the pieces it throws
    $tetro = [ordered]@{
        i = @('#29B6F6', @(@(0, 1), @(1, 1), @(2, 1), @(3, 1))); o = @('#FFEE58', @(@(0, 0), @(1, 0), @(0, 1), @(1, 1)))
        t = @('#AB47BC', @(@(1, 0), @(0, 1), @(1, 1), @(2, 1))); s = @('#66BB6A', @(@(1, 0), @(2, 0), @(0, 1), @(1, 1)))
        z = @('#EF5350', @(@(0, 0), @(1, 0), @(1, 1), @(2, 1))); j = @('#3F51B5', @(@(0, 0), @(0, 1), @(1, 1), @(2, 1)))
        l = @('#FF9800', @(@(2, 0), @(0, 1), @(1, 1), @(2, 1)))
    }
    foreach ($k in $tetro.Keys) {
        $col = $tetro[$k][0]; $cells = $tetro[$k][1]
        $draw = { param($dc)
            $w = 7
            $minx = ($cells | ForEach-Object { $_[0] } | Measure-Object -Maximum).Maximum + 1
            $miny = ($cells | ForEach-Object { $_[1] } | Measure-Object -Maximum).Maximum + 1
            $ox = (32 - $minx * $w) / 2; $oy = (32 - $miny * $w) / 2
            foreach ($c in $cells) {
                $dc.DrawRectangle((ConvertTo-Brush $col), (New-Pen '#22000000' 1), (New-Rect ($ox + $c[0] * $w) ($oy + $c[1] * $w) $w $w))
                $dc.DrawRectangle((ConvertTo-Brush '#55FFFFFF'), $null, (New-Rect ($ox + $c[0] * $w + 1) ($oy + $c[1] * $w + 1) 3 2))
            }
        }
        $files["objects/tetro-$k.png"] = New-Png 32 32 $draw      # runs right away, so it sees this loop's $col and $cells
    }
    $files['enemies/golem.png']       = New-Png 56 60 { param($dc) Draw-Golem $dc 'calm' }
    $files['enemies/golem-angry.png'] = New-Png 56 60 { param($dc) Draw-Golem $dc 'angry' }
    $files['enemies/golem-dizzy.png'] = New-Png 56 60 { param($dc) Draw-Golem $dc 'dizzy' }
    $files['objects/stone-block.png'] = New-Png 26 26 { param($dc)
        $dc.DrawRoundedRectangle((ConvertTo-Brush '#90A4AE'), (New-Pen '#455A64' 2), (New-Rect 1 1 24 24), 3, 3)
        $dc.DrawGeometry($null, (New-Pen '#607D8B' 1.5), (Get-Geo 'M5,9 L12,7 M14,18 L21,16 M6,19 L9,20'))
    }
    $files['enemies/kingslime.png'] = New-Png 68 52 { param($dc)
        $dc.DrawGeometry((ConvertTo-Brush '#43A047'), (New-Pen '#1B5E20' 3), (Get-Geo 'M3,51 C3,22 16,12 34,12 C52,12 65,22 65,51 Z'))
        $dc.DrawGeometry((ConvertTo-Brush '#FFC83D'), (New-Pen '#8D5A00' 1.5), (Get-Geo 'M20,14 L22,2 L28,9 L34,0 L40,9 L46,2 L48,14 Z'))
        foreach ($ex in 26, 44) {
            $dc.DrawEllipse($white, $null, (New-Point $ex 30), 6, 7)
            $dc.DrawEllipse($black, $null, (New-Point ($ex + 2) 31), 3, 3.5)
        }
        $dc.DrawGeometry($null, (New-Pen '#1B5E20' 2.5), (Get-Geo 'M26,42 Q35,47 44,42'))
    }
}

function New-SampleWorld {
    $path = Join-Path $WorldsDir 'Greenwood Hills.zip'
    if (Test-Path -LiteralPath $path) {
        $answer = [System.Windows.MessageBox]::Show("'Greenwood Hills.zip' already exists. Replace it?`nIts saves and stats will be reset.",
                                                    'Sample world', 'YesNo', 'Question')
        if ("$answer" -ne 'Yes') { return }
    }
    $files = [ordered]@{}
    $black = [System.Windows.Media.Brushes]::Black
    $white = [System.Windows.Media.Brushes]::White

    # ---- Tiles ----
    $files['tiles/grass.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#7A4A26'), $null, (New-Rect 0 0 32 32))
        foreach ($d in @(@(5, 16), @(21, 22), @(12, 27), @(26, 14), @(3, 26))) { $dc.DrawRectangle((ConvertTo-Brush '#5E3719'), $null, (New-Rect $d[0] $d[1] 3 3)) }
        $dc.DrawRectangle((ConvertTo-Brush '#2E7D32'), $null, (New-Rect 0 0 32 11))
        $dc.DrawRectangle((ConvertTo-Brush '#4CAF50'), $null, (New-Rect 0 0 32 8))
        foreach ($x in 2, 9, 17, 25) { $dc.DrawRectangle((ConvertTo-Brush '#81C784'), $null, (New-Rect $x 2 3 3)) }
    }
    $files['tiles/dirt.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#7A4A26'), $null, (New-Rect 0 0 32 32))
        foreach ($d in @(@(4, 5), @(19, 9), @(10, 18), @(26, 24), @(6, 27), @(22, 1))) { $dc.DrawRectangle((ConvertTo-Brush '#5E3719'), $null, (New-Rect $d[0] $d[1] 3 3)) }
    }
    $files['tiles/brick.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#B5653A'), $null, (New-Rect 0 0 32 32))
        foreach ($r in @(@(0, 15, 32, 2), @(0, 30, 32, 2), @(15, 0, 2, 15), @(7, 17, 2, 13), @(23, 17, 2, 13))) { $dc.DrawRectangle((ConvertTo-Brush '#6D3418'), $null, (New-Rect $r[0] $r[1] $r[2] $r[3])) }
        foreach ($r in @(@(1, 1, 13, 2), @(18, 1, 13, 2), @(1, 18, 5, 2), @(10, 18, 12, 2), @(26, 18, 5, 2))) { $dc.DrawRectangle((ConvertTo-Brush '#D88A5A'), $null, (New-Rect $r[0] $r[1] $r[2] $r[3])) }
    }
    $files['tiles/stone.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#5D6470'), $null, (New-Rect 0 0 32 32))
        foreach ($r in @(@(0, 0, 32, 1), @(0, 16, 32, 1), @(0, 0, 1, 16), @(16, 16, 1, 16))) { $dc.DrawRectangle((ConvertTo-Brush '#454B55'), $null, (New-Rect $r[0] $r[1] $r[2] $r[3])) }
        foreach ($r in @(@(2, 2, 10, 2), @(18, 18, 10, 2), @(3, 19, 6, 2))) { $dc.DrawRectangle((ConvertTo-Brush '#7A818C'), $null, (New-Rect $r[0] $r[1] $r[2] $r[3])) }
    }
    $files['tiles/spikes.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#455A64'), $null, (New-Rect 0 24 32 8))
        $dc.DrawGeometry((ConvertTo-Brush '#CFD8DC'), (New-Pen '#546E7A' 1.5), (Get-Geo 'M0,25 L5,1 L11,25 Z M11,25 L16,1 L21,25 Z M21,25 L27,1 L32,25 Z'))
    }
    $files['tiles/water-top.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#703FA9F5'), $null, (New-Rect 0 5 32 27))
        $dc.DrawGeometry((ConvertTo-Brush '#A0BBDEFB'), $null, (Get-Geo 'M0,6 Q8,1 16,6 T32,6 L32,10 Q24,13 16,10 T0,10 Z'))
    }
    $files['tiles/water.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#803FA9F5'), $null, (New-Rect 0 0 32 32))
        $dc.DrawEllipse((ConvertTo-Brush '#40FFFFFF'), $null, (New-Point 9 12), 2, 2)
        $dc.DrawEllipse((ConvertTo-Brush '#40FFFFFF'), $null, (New-Point 23 24), 1.5, 1.5)
    }
    $files['tiles/pipe-top.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#388E3C'), (New-Pen '#1B5E20' 2), (New-Rect 4 12 24 20))
        $dc.DrawRectangle((ConvertTo-Brush '#81C784'), $null, (New-Rect 7 12 4 20))
        $dc.DrawRectangle((ConvertTo-Brush '#43A047'), (New-Pen '#1B5E20' 2), (New-Rect 1 1 30 12))
        $dc.DrawRectangle((ConvertTo-Brush '#A5D6A7'), $null, (New-Rect 4 3 4 8))
    }
    $files['tiles/pipe.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#388E3C'), $null, (New-Rect 4 0 24 32))
        $dc.DrawRectangle((ConvertTo-Brush '#1B5E20'), $null, (New-Rect 4 0 2 32))
        $dc.DrawRectangle((ConvertTo-Brush '#1B5E20'), $null, (New-Rect 26 0 2 32))
        $dc.DrawRectangle((ConvertTo-Brush '#81C784'), $null, (New-Rect 8 0 4 32))
    }
    $files['tiles/lock-red.png'] = New-Png 32 32 { param($dc)
        $dc.DrawRoundedRectangle((ConvertTo-Brush '#C62828'), (New-Pen '#7F0000' 2), (New-Rect 1 1 30 30), 4, 4)
        $dc.DrawEllipse((ConvertTo-Brush '#FFE082'), $null, (New-Point 16 13), 4, 4)
        $dc.DrawRectangle((ConvertTo-Brush '#FFE082'), $null, (New-Rect 14 14 4 9))
    }

    # ---- Characters ----
    $files['enemies/slime.png'] = New-Png 32 24 { param($dc)
        $dc.DrawGeometry((ConvertTo-Brush '#66D17A'), (New-Pen '#2E8B57' 2), (Get-Geo 'M2,23 C2,9 8,3 16,3 C24,3 30,9 30,23 Z'))
        $dc.DrawEllipse((ConvertTo-Brush '#B9F6CA'), $null, (New-Point 9 8), 2.5, 1.5)
        foreach ($ex in 13, 21) {
            $dc.DrawEllipse($white, $null, (New-Point $ex 13), 3.5, 4)
            $dc.DrawEllipse($black, $null, (New-Point ($ex + 1) 14), 1.8, 2.2)
        }
    }
    $files['enemies/bat.png'] = New-Png 32 24 { param($dc)
        $wing = ConvertTo-Brush '#7E57C2'
        $dc.DrawGeometry($wing, $null, (Get-Geo 'M16,12 L1,5 L5,11 L0,15 L7,14 L10,18 L16,15 Z'))
        $dc.DrawGeometry($wing, $null, (Get-Geo 'M16,12 L31,5 L27,11 L32,15 L25,14 L22,18 L16,15 Z'))
        $dc.DrawGeometry((ConvertTo-Brush '#5E35B1'), $null, (Get-Geo 'M11,8 L12,2 L15,7 Z M21,8 L20,2 L17,7 Z'))
        $dc.DrawEllipse((ConvertTo-Brush '#5E35B1'), $null, (New-Point 16 13), 6, 7)
        $dc.DrawEllipse((ConvertTo-Brush '#FFEB3B'), $null, (New-Point 14 11), 1.5, 1.5)
        $dc.DrawEllipse((ConvertTo-Brush '#FFEB3B'), $null, (New-Point 18 11), 1.5, 1.5)
    }
    $files['enemies/fish.png'] = New-Png 30 20 { param($dc)
        $dc.DrawGeometry((ConvertTo-Brush '#FF8A65'), $null, (Get-Geo 'M8,10 L0,2 L2,10 L0,18 Z'))
        $dc.DrawEllipse((ConvertTo-Brush '#FF7043'), (New-Pen '#BF360C' 1.5), (New-Point 17 10), 11, 7)
        $dc.DrawGeometry((ConvertTo-Brush '#FFAB91'), $null, (Get-Geo 'M13,4 L17,0 L20,4 Z'))
        $dc.DrawEllipse($white, $null, (New-Point 23 8), 2.6, 2.6)
        $dc.DrawEllipse($black, $null, (New-Point 24 8), 1.3, 1.3)
    }
    $files['enemies/spiky.png'] = New-Png 32 24 { param($dc)
        $dc.DrawGeometry((ConvertTo-Brush '#ECEFF1'), (New-Pen '#90A4AE' 1), (Get-Geo 'M3,16 L5,4 L9,13 L12,1 L15,12 L19,1 L21,12 L25,3 L27,13 L31,8 L29,18 Z'))
        $dc.DrawGeometry((ConvertTo-Brush '#795548'), (New-Pen '#4E342E' 1.5), (Get-Geo 'M2,23 C2,12 9,8 17,8 C25,8 30,13 30,23 Z'))
        $dc.DrawEllipse($white, $null, (New-Point 24 15), 3, 3)
        $dc.DrawEllipse($black, $null, (New-Point 25 15), 1.4, 1.6)
        $dc.DrawEllipse((ConvertTo-Brush '#3E2723'), $null, (New-Point 30 18), 2, 1.6)
    }
    $files['mounts/horse.png'] = New-Png 52 40 { param($dc)
        $leg = ConvertTo-Brush '#6D3B14'
        foreach ($lx in 10, 16, 31, 37) { $dc.DrawRectangle($leg, $null, (New-Rect $lx 26 4 14)) }
        $dc.DrawGeometry((ConvertTo-Brush '#3E2723'), $null, (Get-Geo 'M7,16 C0,18 1,30 4,34 C5,27 6,22 9,20 Z'))
        $dc.DrawEllipse((ConvertTo-Brush '#8D5524'), $null, (New-Point 24 21), 18, 9)
        $dc.DrawGeometry((ConvertTo-Brush '#8D5524'), $null, (Get-Geo 'M34,16 L40,3 L47,4 L51,11 L48,14 L42,12 L40,22 Z'))
        $dc.DrawGeometry((ConvertTo-Brush '#3E2723'), $null, (Get-Geo 'M33,15 L39,2 L42,3 L37,17 Z'))
        $dc.DrawEllipse($black, $null, (New-Point 45 7), 1.3, 1.3)
        $dc.DrawRectangle((ConvertTo-Brush '#C62828'), $null, (New-Rect 17 11 13 5))
        $dc.DrawRectangle((ConvertTo-Brush '#FFC83D'), $null, (New-Rect 22 16 3 5))
    }

    # ---- Objects ----
    $files['objects/goal.png'] = New-Png 32 64 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#78909C'), $null, (New-Rect 8 58 16 6))
        $dc.DrawRectangle((ConvertTo-Brush '#ECEFF1'), $null, (New-Rect 14 6 4 53))
        $dc.DrawEllipse((ConvertTo-Brush '#FFC83D'), $null, (New-Point 16 6), 4, 4)
        $dc.DrawGeometry((ConvertTo-Brush '#FF5252'), $null, (Get-Geo 'M18,9 L32,15 L18,21 Z'))
    }
    foreach ($state in @(@('checkpoint.png', '#90A4AE'), @('checkpoint-active.png', '#43A047'))) {
        $flagColor = $state[1]
        $files["objects/$($state[0])"] = New-Png 32 64 { param($dc)
            $dc.DrawRectangle((ConvertTo-Brush '#78909C'), $null, (New-Rect 9 60 14 4))
            $dc.DrawRectangle((ConvertTo-Brush '#B0BEC5'), $null, (New-Rect 14 20 3 41))
            $dc.DrawGeometry((ConvertTo-Brush $flagColor), $null, (Get-Geo 'M17,21 L31,26 L17,32 Z'))
        }
    }
    $files['objects/secret-goal.png'] = New-Png 32 64 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#78909C'), $null, (New-Rect 8 58 16 6))
        $dc.DrawRectangle((ConvertTo-Brush '#ECEFF1'), $null, (New-Rect 14 6 4 53))
        $dc.DrawEllipse((ConvertTo-Brush '#E1BEE7'), $null, (New-Point 16 6), 4, 4)
        $dc.DrawGeometry((ConvertTo-Brush '#AB47BC'), $null, (Get-Geo 'M18,9 L32,15 L18,21 Z'))
        $dc.DrawGeometry((ConvertTo-Brush '#FFF59D'), $null, (Get-Geo 'M23,12 L24,14.5 L26.5,15 L24,15.5 L23,18 L22,15.5 L19.5,15 L22,14.5 Z'))
    }
    $files['objects/door.png'] = New-Png 32 64 { param($dc)
        $dc.DrawGeometry((ConvertTo-Brush '#8D6E63'), (New-Pen '#4E342E' 2), (Get-Geo 'M3,64 L3,18 Q3,5 16,5 Q29,5 29,18 L29,64 Z'))
        $dc.DrawRectangle((ConvertTo-Brush '#6D4C41'), $null, (New-Rect 11 10 2 54))
        $dc.DrawRectangle((ConvertTo-Brush '#6D4C41'), $null, (New-Rect 19 10 2 54))
        $dc.DrawEllipse((ConvertTo-Brush '#FFC83D'), $null, (New-Point 24 40), 2.5, 2.5)
    }
    $files['objects/tunnel.png'] = New-Png 32 48 { param($dc)
        $dc.DrawGeometry((ConvertTo-Brush '#15131C'), (New-Pen '#6D4C41' 3), (Get-Geo 'M2,48 L2,18 Q2,2 16,2 Q30,2 30,18 L30,48 Z'))
    }
    $files['objects/fireball.png'] = New-Png 12 12 { param($dc)
        $dc.DrawEllipse((ConvertTo-Brush '#FF7043'), $null, (New-Point 6 6), 6, 6)
        $dc.DrawEllipse((ConvertTo-Brush '#FFEB3B'), $null, (New-Point 6 6), 3, 3)
    }

    # ---- Items ----
    $files['items/coin.png'] = New-Png 16 16 { param($dc)
        $dc.DrawEllipse((ConvertTo-Brush '#FFC83D'), (New-Pen '#B8860B' 1.5), (New-Point 8 8), 7, 7)
        $dc.DrawRectangle((ConvertTo-Brush '#FFE9A8'), $null, (New-Rect 7 4 2 8))
    }
    $files['items/gem.png'] = New-Png 22 22 { param($dc)
        $dc.DrawGeometry((ConvertTo-Brush '#26C6DA'), (New-Pen '#00838F' 1.5), (Get-Geo 'M5,2 L17,2 L21,8 L11,21 L1,8 Z'))
        $dc.DrawGeometry((ConvertTo-Brush '#B2EBF2'), $null, (Get-Geo 'M6,4 L10,4 L8,8 L4,8 Z'))
    }
    foreach ($k in @(@('key-red.png', '#E53935'), @('key-blue.png', '#1E88E5'), @('key-gold.png', '#FFC107'))) {
        $keyColor = $k[1]
        $files["items/$($k[0])"] = New-Png 24 24 { param($dc)
            $pen = New-Pen '#3E2723' 1
            $dc.DrawEllipse((ConvertTo-Brush $keyColor), $pen, (New-Point 7 12), 6, 6)
            $dc.DrawEllipse((ConvertTo-Brush '#00000000'), (New-Pen '#3E2723' 1.5), (New-Point 7 12), 2, 2)
            $dc.DrawRectangle((ConvertTo-Brush $keyColor), $pen, (New-Rect 12 10.5 11 3.5))
            $dc.DrawRectangle((ConvertTo-Brush $keyColor), $pen, (New-Rect 18 14 3 4))
        }
    }
    $files['items/mushroom.png'] = New-Png 24 24 { param($dc)
        $dc.DrawRoundedRectangle((ConvertTo-Brush '#FFE0B2'), $null, (New-Rect 7 12 10 11), 3, 3)
        $dc.DrawGeometry((ConvertTo-Brush '#1E88E5'), (New-Pen '#0D47A1' 1), (Get-Geo 'M1,14 C1,3 23,3 23,14 Z'))
        $dc.DrawEllipse($white, $null, (New-Point 8 8), 2.5, 2.5)
        $dc.DrawEllipse($white, $null, (New-Point 16 9), 2, 2)
    }
    $files['items/fire-flower.png'] = New-Png 24 24 { param($dc)
        $dc.DrawRectangle((ConvertTo-Brush '#43A047'), $null, (New-Rect 11 12 2 12))
        $dc.DrawGeometry((ConvertTo-Brush '#66BB6A'), $null, (Get-Geo 'M12,19 Q5,14 3,18 Q7,21 12,20 Z'))
        foreach ($p in @(@(12, 4), @(18, 9), @(6, 9), @(12, 13))) { $dc.DrawEllipse((ConvertTo-Brush '#FF5722'), $null, (New-Point $p[0] $p[1]), 4.5, 4.5) }
        $dc.DrawEllipse((ConvertTo-Brush '#FFEB3B'), $null, (New-Point 12 8.5), 3.5, 3.5)
    }
    $files['items/wings.png'] = New-Png 24 24 { param($dc)
        $pen = New-Pen '#90A4AE' 1
        $dc.DrawGeometry($white, $pen, (Get-Geo 'M11,14 C6,3 1,5 1,9 C4,9 2,13 5,13 C4,16 8,17 11,14 Z'))
        $dc.DrawGeometry($white, $pen, (Get-Geo 'M13,14 C18,3 23,5 23,9 C20,9 22,13 19,13 C20,16 16,17 13,14 Z'))
        $dc.DrawEllipse((ConvertTo-Brush '#FFC83D'), $null, (New-Point 12 15), 2.5, 2.5)
    }
    $files['items/star.png'] = New-Png 24 24 { param($dc)
        $dc.DrawGeometry((ConvertTo-Brush '#FFD600'), (New-Pen '#F57F17' 1.2), (Get-Geo 'M12,1 L15,9 L23,9 L16.5,14 L19,22 L12,17 L5,22 L7.5,14 L1,9 L9,9 Z'))
        $dc.DrawEllipse($black, $null, (New-Point 10 11), 1, 1.6)
        $dc.DrawEllipse($black, $null, (New-Point 14 11), 1, 1.6)
    }
    $files['items/feather.png'] = New-Png 24 24 { param($dc)
        $dc.DrawGeometry((ConvertTo-Brush '#4FC3F7'), (New-Pen '#0277BD' 1), (Get-Geo 'M4,22 C4,12 10,3 21,2 C20,12 13,19 4,22 Z'))
        $dc.DrawGeometry($null, (New-Pen '#0277BD' 1), (Get-Geo 'M4,22 L17,7'))
    }
    $files['items/boots.png'] = New-Png 24 24 { param($dc)
        $dc.DrawGeometry((ConvertTo-Brush '#8D6E63'), (New-Pen '#4E342E' 1), (Get-Geo 'M7,4 L14,4 L14,15 L22,17 L22,22 L5,22 L5,15 Z'))
        $dc.DrawGeometry($white, (New-Pen '#90A4AE' 1), (Get-Geo 'M7,9 C1,6 0,10 2,12 C3,10 5,12 7,12 Z'))
    }

    Add-NewSampleAssets $files
    Add-GadgetAssets $files

    # ---- Backgrounds and thumbnail ----
    $files['backgrounds/hills.png'] = New-Png 960 544 { param($dc) Draw-SampleBackground $dc }
    $files['backgrounds/space.png'] = New-Png 960 544 { param($dc) Draw-SpaceBackground $dc }
    $playerBmp = ConvertTo-Bitmap $files['player/player.png']
    $horseBmp  = ConvertTo-Bitmap $files['mounts/horse.png']
    $files['thumbnail.png'] = New-Png 160 90 { param($dc)
        $dc.PushTransform((New-Object System.Windows.Media.ScaleTransform (160 / 960), (90 / 544)))
        Draw-SampleBackground $dc
        $dc.Pop()
        $dc.DrawRectangle((ConvertTo-Brush '#7A4A26'), $null, (New-Rect 0 76 160 14))
        $dc.DrawRectangle((ConvertTo-Brush '#4CAF50'), $null, (New-Rect 0 74 160 4))
        $dc.DrawImage($horseBmp, (New-Rect 30 48 34 26))
        $dc.DrawImage($playerBmp, (New-Rect 38 25 20 28))
    }

    $worldJson = @'
{
  "formatVersion": 6,
  "name": "Greenwood Hills",
  "author": "Sample World",
  "description": "Eleven levels showing everything a world zip can do: swimming, tides, lava, quicksand, a horse, power-ups, ice blocks, crushers, keys that carry between levels, secret exits, a hidden level, gadget blocks, new enemies, a survival arena, a boss, and rain, night and caves. Has a shop and mini-games, and an expansion (Greenwood Heights) you can add.",
  "thumbnail": "thumbnail.png",
  "tileSize": 32,
  "backgroundColor": "#87CEEB",
  "background": "backgrounds/hills.png",
  "lives": 3,
  "lifePrice": 150,
  "physics": {
    "runSpeed": 240,
    "jumpSpeed": 800,
    "gravity": 2200,
    "swimStroke": 320,
    "crouchSpeed": 0.35
  },
  "player": {
    "image": "player/player.png",
    "width": 22,
    "height": 40,
    "crouchHeight": 24,
    "animations": {
      "run": {
        "frames": [
          "player/run1.png",
          "player/run2.png"
        ],
        "fps": 10
      },
      "jump": "player/jump.png",
      "crouch": "player/crouch.png",
      "invincible": {
        "frames": [
          "player/ball.png"
        ],
        "spin": 900
      },
      "sleep": "player/sleep.png"
    },
    "sleepAfter": 120
  },
  "goal": {
    "image": "objects/goal.png"
  },
  "checkpoint": {
    "image": "objects/checkpoint.png",
    "activeImage": "objects/checkpoint-active.png"
  },
  "warpTypes": {
    "door": {
      "image": "objects/door.png",
      "enter": "up"
    },
    "pipe": {
      "enter": "down"
    },
    "tunnel": {
      "image": "objects/tunnel.png",
      "enter": "auto"
    }
  },
  "tiles": {
    "#": {
      "image": "tiles/grass.png"
    },
    "d": {
      "image": "tiles/dirt.png"
    },
    "=": {
      "image": "tiles/brick.png"
    },
    "x": {
      "image": "tiles/stone.png"
    },
    "^": {
      "image": "tiles/spikes.png",
      "spikes": "up"
    },
    "v": {
      "image": "tiles/spikes.png",
      "spikes": "down",
      "rotate": 180
    },
    "<": {
      "image": "tiles/spikes.png",
      "spikes": "left",
      "rotate": 270
    },
    ">": {
      "image": "tiles/spikes.png",
      "spikes": "right",
      "rotate": 90
    },
    "~": {
      "image": "tiles/water-top.png",
      "liquid": true
    },
    "%": {
      "image": "tiles/water.png",
      "liquid": true
    },
    "T": {
      "image": "tiles/pipe-top.png"
    },
    "I": {
      "image": "tiles/pipe.png"
    },
    "L": {
      "image": "tiles/lock-red.png",
      "lock": "red"
    },
    "&": {
      "image": "tiles/quicksand.png",
      "quicksand": true
    },
    "H": {
      "image": "tiles/ladder.png",
      "climbable": true
    },
    "J": {
      "image": "tiles/spring.png",
      "bounce": 1150
    },
    "K": {
      "image": "tiles/ice.png",
      "friction": 0.12
    },
    "M": {
      "image": "tiles/conveyor.png",
      "conveyor": 110
    },
    "O": {
      "image": "tiles/oneway.png",
      "oneWay": true
    },
    "B": {
      "image": "tiles/cracked.png",
      "breakable": {
        "by": [
          "powerHead",
          "shell",
          "heavyStomp",
          "fire"
        ]
      }
    },
    "Q": {
      "image": "tiles/qblock.png",
      "bump": {
        "gives": "o",
        "count": 3,
        "becomes": "U"
      }
    },
    "U": {
      "image": "tiles/used.png"
    },
    "Y": {
      "image": "tiles/crumble.png",
      "crumble": {
        "delay": 0.45,
        "respawn": 3
      }
    },
    "S": {
      "image": "tiles/switch.png",
      "switch": "red"
    },
    "Z": {
      "image": "tiles/toggle.png",
      "toggle": {
        "group": "red",
        "solid": true
      }
    },
    "F": {
      "image": "tiles/gate.png",
      "gate": "during"
    },
    "|": {
      "image": "tiles/gate.png",
      "gate": "until"
    },
    "!": {
      "color": "#00000000",
      "solidFor": "enemies"
    },
    "?": {
      "image": "tiles/qblock.png",
      "bump": {
        "gives": "m",
        "becomes": "U"
      }
    },
    "N": {
      "image": "tiles/toggle.png",
      "toggle": {
        "group": "red",
        "solid": false
      }
    }
  },
  "enemies": {
    "s": {
      "name": "Slime",
      "movement": [
        "patrol"
      ],
      "speed": 50,
      "width": 28,
      "height": 20,
      "image": "enemies/slime.png",
      "animations": {
        "move": {
          "frames": [
            "enemies/slime.png",
            "enemies/slime2.png"
          ],
          "fps": 4
        }
      }
    },
    "b": {
      "name": "Bat",
      "movement": [
        "fly",
        "patrol"
      ],
      "speed": 70,
      "width": 26,
      "height": 18,
      "range": 96,
      "image": "enemies/bat.png",
      "animations": {
        "fly": {
          "frames": [
            "enemies/bat.png",
            "enemies/bat2.png"
          ],
          "fps": 8
        }
      }
    },
    "q": {
      "name": "Fish",
      "movement": [
        "swim",
        "patrol"
      ],
      "speed": 60,
      "width": 26,
      "height": 16,
      "range": 160,
      "image": "enemies/fish.png"
    },
    "l": {
      "name": "Eel",
      "movement": [
        "swim",
        "follow"
      ],
      "speed": 70,
      "sight": 220,
      "width": 34,
      "height": 14,
      "image": "enemies/eel.png"
    },
    "k": {
      "name": "Spiky",
      "movement": [
        "patrol"
      ],
      "speed": 40,
      "width": 28,
      "height": 20,
      "stompable": false,
      "image": "enemies/spiky.png"
    },
    "e": {
      "name": "Ghost",
      "movement": [
        "fly",
        "follow"
      ],
      "speed": 55,
      "sight": 420,
      "width": 28,
      "height": 26,
      "whenLookedAt": "stop",
      "stompable": false,
      "fireproof": true,
      "lavaproof": true,
      "image": "enemies/ghost.png",
      "animations": {
        "shy": "enemies/ghost-shy.png"
      }
    },
    "a": {
      "name": "Shy Block",
      "movement": [
        "fly",
        "follow"
      ],
      "speed": 45,
      "sight": 360,
      "width": 32,
      "height": 32,
      "whenLookedAt": "platform",
      "stompable": false,
      "freezable": false,
      "fireproof": true,
      "lavaproof": true,
      "image": "enemies/shy-ghost.png",
      "animations": {
        "platform": "objects/shy-block.png"
      }
    },
    "y": {
      "name": "Hopper",
      "movement": [
        "follow",
        "jump"
      ],
      "speed": 70,
      "sight": 260,
      "jumpSpeed": 650,
      "jumpInterval": 1.4,
      "width": 28,
      "height": 22,
      "image": "enemies/frog.png",
      "animations": {
        "jump": "enemies/frog-jump.png"
      }
    },
    "t": {
      "name": "Turtle",
      "movement": [
        "patrol"
      ],
      "speed": 45,
      "width": 28,
      "height": 26,
      "image": "enemies/turtle.png",
      "onDefeat": {
        "becomes": "c"
      }
    },
    "c": {
      "name": "Shell",
      "movement": "none",
      "speed": 0,
      "width": 26,
      "height": 18,
      "image": "enemies/shell.png",
      "kickable": true,
      "kickSpeed": 460
    },
    "p": {
      "name": "Fire Plant",
      "movement": "none",
      "width": 28,
      "height": 38,
      "stomp": "hurt",
      "image": "enemies/plant.png",
      "attacks": [
        {
          "type": "shoot",
          "aim": "player",
          "interval": 2.2,
          "speed": 200,
          "element": "fire",
          "image": "objects/seed.png",
          "size": 12,
          "range": 380
        }
      ]
    },
    "(": {
      "name": "Stone Face",
      "movement": [
        "fly"
      ],
      "speed": 0,
      "width": 32,
      "height": 32,
      "stomp": "hurt",
      "weakTo": [
        "star",
        "heavyStomp"
      ],
      "image": "enemies/stoneface.png",
      "attacks": [
        {
          "type": "drop",
          "range": 28,
          "speed": 900,
          "rise": 110,
          "wait": 0.9
        }
      ]
    },
    "]": {
      "name": "King Slime",
      "boss": true,
      "movement": [
        "follow",
        "jump"
      ],
      "speed": 55,
      "sight": 700,
      "jumpSpeed": 650,
      "jumpInterval": 2.4,
      "width": 64,
      "height": 48,
      "health": 5,
      "image": "enemies/kingslime.png",
      "carries": [
        "+"
      ],
      "onHit": {
        "drop": "o"
      },
      "attacks": [
        {
          "type": "shoot",
          "aim": "forward",
          "count": 3,
          "spread": 25,
          "interval": 3,
          "speed": 230,
          "element": "goo",
          "image": "objects/goo.png",
          "size": 14,
          "gravity": true,
          "range": 700
        }
      ]
    },
    "}": {
      "name": "Boar",
      "movement": [
        "patrol"
      ],
      "speed": 40,
      "width": 38,
      "height": 26,
      "health": 2,
      "image": "enemies/boar.png",
      "animations": {
        "charge": "enemies/boar-charge.png",
        "windup": "enemies/boar-charge.png"
      },
      "attacks": [
        {
          "type": "charge",
          "speed": 380,
          "range": 260,
          "duration": 1.0,
          "cooldown": 2,
          "windup": 0.5
        }
      ]
    }
  },
  "items": {
    "o": {
      "type": "coin",
      "name": "Coin",
      "image": "items/coin.png"
    },
    "g": {
      "type": "collectible",
      "name": "Gem",
      "image": "items/gem.png"
    },
    "r": {
      "type": "key",
      "name": "Red Key",
      "keyId": "red",
      "image": "items/key-red.png",
      "keepBetweenLevels": false
    },
    "u": {
      "type": "key",
      "name": "Blue Key",
      "keyId": "blue",
      "image": "items/key-blue.png",
      "keepBetweenLevels": false
    },
    "$": {
      "type": "key",
      "name": "Gold Key",
      "keyId": "gold",
      "image": "items/key-gold.png",
      "keepBetweenLevels": true
    },
    "m": {
      "type": "shield",
      "name": "Super Mushroom",
      "image": "items/mushroom.png",
      "shop": 15
    },
    "f": {
      "type": "fireball",
      "name": "Fire Flower",
      "image": "items/fire-flower.png",
      "projectileImage": "objects/fireball.png",
      "shop": 30,
      "downgradeTo": "m"
    },
    "i": {
      "type": "iceball",
      "name": "Ice Flower",
      "image": "items/ice-flower.png",
      "projectileImage": "objects/iceball.png",
      "iceImage": "objects/ice-block.png",
      "freezeTime": 10,
      "shop": 30
    },
    "w": {
      "type": "fly",
      "name": "Wings",
      "image": "items/wings.png",
      "duration": 15
    },
    "*": {
      "type": "invincible",
      "name": "Star",
      "image": "items/star.png",
      "duration": 8
    },
    "j": {
      "type": "doubleJump",
      "name": "Feather",
      "image": "items/feather.png",
      "shop": 25
    },
    "z": {
      "type": "speed",
      "name": "Speed Boots",
      "image": "items/boots.png",
      "duration": 12,
      "multiplier": 1.5
    },
    "n": {
      "type": "power",
      "name": "Bubble Wand",
      "image": "items/wand.png",
      "shop": 40,
      "projectile": {
        "image": "objects/bubble.png",
        "effect": "stun",
        "stunTime": 3,
        "element": "bubble",
        "gravity": false,
        "bounce": false,
        "speed": 330,
        "size": 16,
        "life": 1.2
      }
    },
    "+": {
      "type": "life",
      "name": "1-Up Heart",
      "image": "items/oneup.png"
    },
    "{": {
      "type": "power",
      "name": "Rock Helmet",
      "image": "items/helmet.png",
      "heavyStomp": true,
      "breakBlocks": true,
      "immune": [
        "spikes"
      ],
      "hits": 2,
      "message": "Rock Helmet! Break bricks with your head, stomp anything, walk on spikes. Takes 2 hits."
    }
  },
  "mounts": {
    "h": {
      "name": "Horse",
      "image": "mounts/horse.png",
      "width": 44,
      "height": 30,
      "riderY": 10,
      "canSwim": false,
      "physics": {
        "runSpeed": 360,
        "jumpSpeed": 900,
        "groundAccel": 1600
      }
    }
  },
  "platforms": {
    "-": {
      "name": "Raft",
      "image": "tiles/platform.png",
      "width": 3,
      "move": [
        3,
        0
      ],
      "speed": 70,
      "pauseStart": 0.6,
      "pauseEnd": 0.6
    },
    "V": {
      "name": "Crusher",
      "image": "tiles/crusher.png",
      "width": 2,
      "height": 2,
      "move": [
        0,
        4
      ],
      "speed": 700,
      "returnSpeed": 90,
      "pauseStart": 1.2,
      "pauseEnd": 0.6
    },
    "W": {
      "name": "Crusher (late)",
      "image": "tiles/crusher.png",
      "width": 2,
      "height": 2,
      "move": [
        0,
        4
      ],
      "speed": 700,
      "returnSpeed": 90,
      "pauseStart": 1.2,
      "pauseEnd": 0.6,
      "startDelay": 1.0
    }
  },
  "exits": {
    "E": {
      "name": "Secret Exit",
      "image": "objects/secret-goal.png"
    }
  },
  "spawners": {
    "@": {
      "name": "Slime hole",
      "image": "objects/spawner.png"
    },
    "/": {
      "name": "Slime pipe",
      "image": "tiles/pipe-top.png",
      "dispense": [
        "s",
        "i"
      ],
      "max": {
        "s": 3,
        "i": 1
      },
      "every": 3,
      "walk": "right"
    }
  },
  "minigames": [
    {
      "id": "chests",
      "type": "pick",
      "name": "Treasure Chests",
      "description": "Three chests: one holds 6 coins, one holds 2, one is empty. Pick one!",
      "choices": 3,
      "prizes": [
        0,
        2,
        6
      ]
    },
    {
      "id": "star-stopper",
      "type": "timing",
      "name": "Star Stopper",
      "maxCoins": 4,
      "speed": 0.9,
      "zone": 0.16
    },
    {
      "id": "coin-rush",
      "type": "level",
      "name": "Coin Rush",
      "file": "minigames/coin-rush.txt",
      "time": 25,
      "maxCoins": 10,
      "twists": [
        "reverse",
        "waterSwap",
        "noFloor",
        "popSpikes"
      ]
    }
  ],
  "levels": [
    {
      "name": "First Steps",
      "areas": {
        "main": {
          "file": "levels/level01.txt"
        },
        "secret": {
          "file": "levels/level01-secret.txt",
          "background": "none",
          "backgroundColor": "#1D1530"
        }
      },
      "warps": {
        "1": {
          "type": "door",
          "lock": "gold"
        }
      },
      "exits": {
        "G": [
          2
        ],
        "E": [
          8
        ]
      }
    },
    {
      "name": "Pipe Dreams",
      "areas": {
        "main": {
          "file": "levels/level02.txt"
        },
        "bonus": {
          "file": "levels/level02-bonus.txt",
          "background": "none",
          "backgroundColor": "#14121E",
          "levelType": "underground"
        }
      },
      "warps": {
        "1": "pipe",
        "2": "pipe"
      }
    },
    {
      "name": "Lagoon",
      "areas": {
        "main": {
          "file": "levels/level03.txt"
        },
        "cave": {
          "file": "levels/level03-cave.txt",
          "background": "none",
          "backgroundColor": "#1B1726",
          "levelType": "cave"
        }
      },
      "warps": {
        "1": {
          "type": "door",
          "lock": "blue"
        },
        "2": "tunnel"
      }
    },
    {
      "name": "Horse Trail",
      "file": "levels/level04.txt"
    },
    {
      "name": "Moon Hop",
      "file": "levels/level05.txt",
      "background": "backgrounds/space.png",
      "physics": {
        "gravity": 900,
        "maxFall": 500,
        "jumpSpeed": 520,
        "airAccel": 900
      },
      "weather": "night"
    },
    {
      "name": "Tide Pools",
      "file": "levels/level06.txt",
      "liquids": [
        {
          "type": "water",
          "level": 16,
          "low": 16,
          "high": 11,
          "mode": "wave",
          "period": 14,
          "image": "tiles/water.png",
          "surfaceImage": "tiles/water-surface.png"
        }
      ],
      "weather": "night"
    },
    {
      "name": "Lava Works",
      "areas": {
        "main": {
          "file": "levels/level07.txt",
          "background": "none",
          "backgroundColor": "#2A1215",
          "liquids": [
            {
              "type": "lava",
              "level": 15,
              "low": 15,
              "high": 12,
              "mode": "wave",
              "period": 8,
              "image": "tiles/lava.png",
              "surfaceImage": "tiles/lava-surface.png"
            }
          ]
        },
        "vault": {
          "file": "levels/level07-vault.txt",
          "background": "none",
          "backgroundColor": "#3A1A10"
        }
      },
      "warps": {
        "1": "door"
      },
      "exits": {
        "E": [
          8
        ]
      }
    },
    {
      "name": "Secret Grotto",
      "file": "levels/level08.txt",
      "hidden": true,
      "background": "none",
      "backgroundColor": "#102A2A",
      "levelType": "underground"
    },
    {
      "name": "Gadget Works",
      "file": "levels/level09.txt"
    },
    {
      "name": "Slime Arena",
      "background": "none",
      "backgroundColor": "#1E1430",
      "timeLimit": 240,
      "requires": {
        "enemies": [
          "]"
        ]
      },
      "areas": {
        "main": {
          "file": "levels/level10.txt",
          "liquids": [
            {
              "type": "lava",
              "level": 16,
              "low": 16,
              "high": 13.5,
              "mode": "pingpong",
              "speed": 0.6,
              "pause": 1.5,
              "from": 26,
              "to": 29,
              "startOn": "survival",
              "afterSurvival": "drain",
              "image": "tiles/lava.png",
              "surfaceImage": "tiles/lava-surface.png"
            }
          ],
          "survival": {
            "time": 30,
            "startColumn": 13,
            "spawn": [
              "s",
              "b"
            ],
            "spawnEvery": 3,
            "maxEnemies": 5,
            "waves": [
              {
                "at": 10,
                "spawn": "y",
                "count": 2,
                "every": 1.5
              },
              {
                "at": 18,
                "spawn": "t",
                "count": 2,
                "every": 2
              }
            ],
            "reward": "+",
            "message": "SURVIVE THE SLIMES!"
          }
        }
      }
    },
    {
      "name": "Thunder Road",
      "file": "levels/level11.txt",
      "weather": "rain",
      "backgroundColor": "#1C2733"
    }
  ]
}
'@

    $levels = [ordered]@{}
    $levels['levels/level01.txt'] = @'
............................................................................................
............................................................................................
............................................................................................
............................................................................................
............................................................................................
............................................................................................
.....................................g......................................................
....................................oooo....................................................
....................................====....................................................
............................................................................................
.............................ooooo..........................................................
.............................=====..........................................................
....................ooo.......vvv............ooo............................................
..................................................................<=..........o.o.o.........
..P.....m..1...s........................s.........C...^^....s.....<=.......s............G...
####################...######################...############################################
dddddddddddddddddddd...dddddddddddddddddddddd...dddddddddddddddddddddddddddddddddddddddddddd
'@
    $levels['levels/level01-secret.txt'] = @'
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
x..............................x
x..............................x
x..............................x
x..............................x
x..............................x
x..............................x
x..............................x
x..............................x
x..............g...............x
x...........=======............x
x.....o.o.o.o.o.o.o.o.o.o......x
x..............................x
x.1.........................E..x
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
'@
    $levels['levels/level02.txt'] = @'
................................................................................................................
................................................................................................................
................................................................................................................
................................................................................................................
................................................................................................................
................................................................................................................
................................................................................................................
................................................................................................................
.......................................................====.....................................................
................................................................................................................
.................................b.............oooooo.........b.................................................
..........f....................................======...........................=====.............=====.........
........====...oooo...................................................1.........L...=.....2.....................
......................................................................T.........L...=.....T.....................
..P........................s.................C.........s..............I....s....L.g.=.....I.....s...........G...
###############....############....####....##################....###############################################
ddddddddddddddd....dddddddddddd....dddd....dddddddddddddddddd....ddddddddddddddddddddddddddddddddddddddddddddddd
'@
    $levels['levels/level02-bonus.txt'] = @'
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
x......................................x
x......................................x
x......................................x
x...................r..................x
x..............oooooooooo..............x
x.............xxxxxxxxxxxx.............x
x......................................x
x......................................x
x........o.o.o.o.o.o.o.o.o.o.o.........x
x......................................x
x........o.o.o.o.o.o.o.o.o.o.o.........x
x...................................2..x
x..1................................T..x
x..T................s...............I..x
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
'@
    $levels['levels/level03.txt'] = @'
..............................................................................................................
..............................................................................................................
.......................................................................xx.....................................
.......................................................................xx.....................................
..............................................................oooooooo.xx.....................................
.......................................................................xx.....................................
.......................................................................xx.....................................
.......................................................................xx.....................................
..P..................................................C....w.......1....xx...2........s.........s..........G...
#####################..............................####################xx#####################################
ddddddddddddddddddddd~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ddddddddddddddddddddxxddddddddddddddddddddddddddddddddddddd
ddddddddddddddddddddd%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%ddddddddddddddddddddxxddddddddddddddddddddddddddddddddddddd
ddddddddddddddddddddd%%%%%%%q%%%%%%%%%%%%%%%%%q%%%%ddddddddddddddddddddxxddddddddddddddddddddddddddddddddddddd
ddddddddddddddddddddd%%%o%%o%%o%%o%%o%%o%%o%%o%%%%%ddddddddddddddddddddxxddddddddddddddddddddddddddddddddddddd
ddddddddddddddddddddd%%%%%%%%%%%%%%%%%l%%%%%%%%%%%%ddddddddddddddddddddxxddddddddddddddddddddddddddddddddddddd
ddddddddddddddddddddd%%%%%%%%%%%%%%u%%%%%%%%%%%%%%%ddddddddddddddddddddxxddddddddddddddddddddddddddddddddddddd
dddddddddddddddddddddxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxddddddddddddddddddddxxddddddddddddddddddddddddddddddddddddd
'@
    $levels['levels/level03-cave.txt'] = @'
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
x........................................x
x........................................x
x........................................x
x........................................x
x........................................x
x........................................x
x........................................x
x........................g...............x
x.......................ooo..............x
x...........ooo..........................x
x.......................xxx..............x
x...........xxx.........xxx..............x
x..1........xxx....k....xxx....s......2..x
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
'@
    $levels['levels/level04.txt'] = @'
....................................................................................................................................
....................................................................................................................................
....................................................................................................................................
....................................................................................................................................
....................................................................................................................................
....................................................................................................................................
....................................................................................................................................
....................................................................................................................................
....................................................................................................................................
....................................................................................................................................
....................oooooo...................oooooo...................oooooo......*............oooooo...............................
..........................................k.........................................................................................
..........................########&&&&&######.......................................................................................
..........................dddddddd&&&&&dddddd.......................................................................................
..P...h.....j.............dddddddd&o&o&dddddd.........C...h.....k.....................k.........................k.......k.......G...
####################......dddddddd&&g&&dddddd......###################......###################......###############################
dddddddddddddddddddd......ddddddddddddddddddd......ddddddddddddddddddd......ddddddddddddddddddd......ddddddddddddddddddddddddddddddd
'@
    $levels['levels/level05.txt'] = @'
..........................................................................................................................
..........................................................................................................................
..........................................................................................................................
..........................................................................................................................
..........................................................................................................................
..........................................................................................................................
..........................................................................................................................
..........................................................................................................................
......................................b........................b........................b.................................
..........................................................................g...............................................
...............ooooooo....ooooo.............................ooooooo.....ooooo.............................................
..........................xxxxx.........................................xxxxx.............................................
..........................................................................................................................
..........................................................................................................................
..P.....z.....................s...............s...C.............................s........................s............G...
xxxxxxxxxxxxxxx.......xxxxxxxxxxxxx.......xxxxxxxxxxxxxxxxxx.......xxxxxxxxxxxxxxxxxx.......xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxx.......xxxxxxxxxxxxx.......xxxxxxxxxxxxxxxxxx.......xxxxxxxxxxxxxxxxxx.......xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
'@
    $levels['levels/level06.txt'] = @'
..............................................................................................................
..............................................................................................................
..............................................................................................................
..............................................................................................................
..............................................................................................................
..............................................................................................................
..............................................................................................................
..............................................................................................................
..............................................................................................................
.........................................................g..$.................................................
....................................................===========...............................................
...................ooooo............................===========..............ooooo............................
.........................................-..........===========...............................................
..................-.................................===========.............-.................................
..P...........................s.....s...........C....o.o.o.o.o............................s.......s.......G...
##################......#################......#############################......############################
dddddddddddddddddd......ddddddddddddddddd......ddddddddddddddddddddddddddddd......dddddddddddddddddddddddddddd
'@
    $levels['levels/level07.txt'] = @'
............................................................................................................................
............................................................................................................................
............................................................................................................................
............................................................................................................................
..................................................xxxxxxxxxxxxxxxxx.........................................................
....................................g...............V....W....V.............................................................
....................................xx......................................................................................
....................................xx....................................................e.................................
....................................xx......................................................................................
.......................ooooooo......xx....................................a.....oooooooo....................................
..P.....i............/....s.........xx.*.......C...............................................y................y.......G...
xxxxxxxxxxxxxxx....xxxxxxxxxxxxxxxxxxxxxx....xxxxxxxxxxxxxxxxxxxxxxxxxx.......xxxxxxxxxxxxxxxxxxxxxxx....xxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxx....xxxxxxxxxxxxxxxxxxxxxx....xxxxxxxxxxxxxxxxxxxxxxxxxx.......xxxxxxxxxxxxxxxxxxxxxxx....xxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxx....xxxxxxxxxxxxxxxxxxxxxx....xxxxxxxxxxxxxxxxxxxxxxxxxx.......xxxxxxxxxxxxxxxxxxxxxxx....xxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxx....xxxxxxxxxxxxxxxxxxxxxx....xxxxxxxxxxxxxxxxxxxxxxxxxx.......xxxxxxxxxxxxxxxxxxxxxxx....xxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxx....xxxxxxxxxxxxxxxxxxxxxx.1..xxxxxxxxxxxxxxxxxxxxxxxxxx.......xxxxxxxxxxxxxxxxxxxxxxx....xxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxx....xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx.......xxxxxxxxxxxxxxxxxxxxxxx....xxxxxxxxxxxxxxxxxxx
'@
    $levels['levels/level07-vault.txt'] = @'
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
x............................x
x............................x
x............................x
x............................x
x............................x
x............................x
x............................x
x............................x
x............................x
x.......o.o.o.o.o.o.o........x
x............................x
x............................x
x.1..o.o.o.o.o.o.o.o.o.o..E..x
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
'@
    $levels['levels/level08.txt'] = @'
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
x....................................................................x
x....................................................................x
x....................................................................x
x....................................................................x
x....................................................................x
x....................................................................x
x...............................g....................................x
x.............................ooooo..................................x
x.............................=====..................................x
x.............ooooo.............................*....................x
x.............=====......===..................=====..................x
x....................................................................x
x.P..o.o.o.o.o.o.o.o.o.oso.o.o.o.o.o.o.oso.o.o.o.o.o.o.oso.o.o.o..G..x
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
'@

    $levels['levels/level09.txt'] = @'
............................................................................................................................................
............................................................................................................................................
............................................................................................................................................
.....................................................................................................................(......................
............................................................................................................................................
....................................................oo......................................................................................
................................oo{.oo.............H==......................................................................................
................................======.............H==......................................................................................
...................................................H==...........................................................ooo........................
...................................................H==....................................Z......................OOO........................
...................................................H==......g.............................Z.....................................+...........
........?.Q........................................H==....BBBBB.......................S...Z...................ooo..............OOO..........
......................................o.o.o....n...H==....................................Z...................OOO...........................
...................................................H==....................................Z.................................................
..P...................s............................H==..........t...C.......p.............Z.............................!....}.....!.....G..
###############KKKKKKKKKKK#J########MMMMMMMM################################################NNNNN####YYYYYYY################################
dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd.....dddd.......dddddddddddddddddddddddddddddddd
'@
    $levels['levels/level10.txt'] = @'
..........xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx........................
..........xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx........................
..........F..................................|........................
..........F......@....................@......|........................
..........F..................................|........................
..........F..................................|........................
..........F..................................|........................
..........F..................................|........................
..........F..................................|........................
..........F..................................|........................
..........F.....o.o..................o.o.....|........................
..........F....OOOOO................OOOOO....|........................
..........F..................................|........................
..........F..................................|........................
..P..C....F..................................|..C.........]........G..
##########################....########################################
ddddddddddddddddddddddddddxxxxdddddddddddddddddddddddddddddddddddddddd
'@
    $levels['levels/level11.txt'] = @'
..............................................................................................................
..............................................................................................................
..............................................................................................................
..............................................................................................................
..............................................................................................................
..............................................................................................................
..............................................................................................................
..............................................................................................................
............................................................b.................................................
...................................b....................................................b.....................
.........................oo..................og........................oo.....................................
........................====................OOOO......................====....................................
..............................................................................................................
..............................................................................................................
..P.........s.................^^........s.........y.............C...s.......^.........o..o..o..o..o..o....G...
#################...##############...################..####...###################...##########################
ddddddddddddddddd...dddddddddddddd...dddddddddddddddd..dddd...ddddddddddddddddddd...dddddddddddddddddddddddddd
'@
    $levels['minigames/coin-rush.txt'] = @'
x................................................x
x................................................x
x................................................x
x................................................x
x................................................x
x................................................x
x................................................x
x................................................x
x................o...........o...........o.......x
x................................................x
x.........oooo........oooo........oooo...........x
x.........OOOO........OOOO........OOOO...........x
x................................................x
x................................................x
x.P..o..o..o..o..o..o..o..o..o..o..o..o..o..o....x
##################################################
dddddddddddddddddddddddddddddddddddddddddddddddddd
'@

    $utf8 = New-Object System.Text.UTF8Encoding $false
    $files['world.json'] = $utf8.GetBytes($worldJson)
    foreach ($name in $levels.Keys) { $files[$name] = $utf8.GetBytes($levels[$name]) }

    # ---- The sample expansion: its own zip, added to Greenwood Hills from the Expansions button ----
    $expansionJson = @'
{
  "formatVersion": 6,
  "name": "Greenwood Heights",
  "id": "greenwood-heights",
  "expansionOf": "greenwood-hills",
  "author": "Sample World",
  "description": "A two-level expansion for Greenwood Hills: cloud platforms, a new power-up, a secret exit back into the main world and the Block Golem at the summit. Bring a Gold Key!",
  "startUnlocked": true,
  "backgroundColor": "#9FD8F5",
  "tiles": {
    ":": {
      "image": "tiles/cloud.png",
      "oneWay": true
    }
  },
  "items": {
    ",": {
      "type": "power",
      "name": "Sky Cape",
      "image": "items/cape.png",
      "glide": 90,
      "airJumps": 1,
      "shop": 45
    }
  },
  "levels": [
    {
      "name": "Cloud Steps",
      "areas": {
        "main": {
          "file": "levels/heights1.txt"
        },
        "cape": {
          "file": "levels/heights1-cape.txt",
          "background": "none",
          "backgroundColor": "#2B2140"
        }
      },
      "warps": {
        "1": {
          "type": "door",
          "lock": "gold"
        }
      },
      "levelType": "clouds"
    },
    {
      "name": "Summit",
      "file": "levels/heights2.txt",
      "exits": {
        "G": [],
        "E": [
          "greenwood-hills:8"
        ]
      },
      "requires": {
        "enemies": [
          ")"
        ]
      },
      "weather": "snow"
    }
  ],
  "enemies": {
    ";": {
      "name": "Block Golem",
      "boss": true,
      "movement": [
        "follow"
      ],
      "sight": 600,
      "width": 56,
      "height": 60,
      "health": 3,
      "speed": 30,
      "image": "enemies/golem.png",
      "stomp": "bounce",
      "weakTo": [
        "thrown"
      ],
      "vulnerableWhen": "talking",
      "onDefeat": {
        "becomes": "["
      },
      "talkEvery": 5,
      "talkTime": 3.5,
      "talk": [
        "Heh... you've seen my blocks before. They're EVERYWHERE, if you look.",
        "Throw something at me while I'm talking? I'd like to see you try!",
        "Every foe you topple might be hiding one...",
        "Seven shapes. Find them all and something wonderful happens."
      ],
      "attacks": [
        {
          "type": "shoot",
          "aim": "player",
          "interval": 1.6,
          "speed": 300,
          "size": 24,
          "spin": 260,
          "element": "block",
          "images": [
            "objects/tetro-i.png",
            "objects/tetro-o.png",
            "objects/tetro-t.png",
            "objects/tetro-s.png",
            "objects/tetro-z.png",
            "objects/tetro-j.png",
            "objects/tetro-l.png"
          ],
          "range": 600,
          "leaves": "throwable"
        },
        {
          "type": "shoot",
          "aim": "up",
          "count": 3,
          "spread": 45,
          "interval": 3.4,
          "speed": 560,
          "gravity": true,
          "size": 24,
          "spin": -220,
          "element": "block",
          "images": [
            "objects/tetro-i.png",
            "objects/tetro-o.png",
            "objects/tetro-t.png",
            "objects/tetro-s.png",
            "objects/tetro-z.png",
            "objects/tetro-j.png",
            "objects/tetro-l.png"
          ],
          "range": 600,
          "leaves": "throwable"
        }
      ]
    },
    "[": {
      "name": "Block Golem",
      "boss": true,
      "movement": [
        "follow"
      ],
      "sight": 600,
      "width": 56,
      "height": 60,
      "health": 3,
      "speed": 40,
      "image": "enemies/golem-angry.png",
      "stomp": "bounce",
      "weakTo": [
        "thought"
      ],
      "onDefeat": {
        "becomes": ")"
      },
      "talkEvery": 9,
      "talkTime": 3,
      "talk": [
        "Hmm... which piece next? Let me THINK about it...",
        "Bigger foes drop them more often. Bosses like ME, for instance!",
        "Don't you DARE throw anything into my thoughts!"
      ],
      "attacks": [
        {
          "type": "think",
          "interval": 1.0,
          "think": 2.2,
          "speed": 340,
          "size": 26,
          "spin": 300,
          "element": "block",
          "images": [
            "objects/tetro-i.png",
            "objects/tetro-o.png",
            "objects/tetro-t.png",
            "objects/tetro-s.png",
            "objects/tetro-z.png",
            "objects/tetro-j.png",
            "objects/tetro-l.png"
          ],
          "range": 600,
          "leaves": "throwable"
        }
      ]
    },
    ")": {
      "name": "Block Golem",
      "boss": true,
      "movement": [
        "follow"
      ],
      "sight": 600,
      "width": 56,
      "height": 60,
      "health": 3,
      "speed": 55,
      "image": "enemies/golem-angry.png",
      "animations": {
        "stunned": "enemies/golem-dizzy.png"
      },
      "stomp": "defeat",
      "weakTo": [
        "thrown"
      ],
      "hitEffects": {
        "thrown": "stun"
      },
      "vulnerableWhen": "stunned",
      "stunTime": 3,
      "talkEvery": 10,
      "talkTime": 3,
      "talk": [
        "It's all about clearing lines, little hero. Lines!",
        "Ugh... my head's still spinning from that last one...",
        "Seven of them, hidden in every world. Have you found yours?"
      ],
      "attacks": [
        {
          "type": "shoot",
          "aim": "up",
          "count": 3,
          "spread": 50,
          "interval": 2.6,
          "speed": 580,
          "gravity": true,
          "size": 24,
          "spin": -260,
          "element": "block",
          "images": [
            "objects/tetro-i.png",
            "objects/tetro-o.png",
            "objects/tetro-t.png",
            "objects/tetro-s.png",
            "objects/tetro-z.png",
            "objects/tetro-j.png",
            "objects/tetro-l.png"
          ],
          "range": 600,
          "leaves": "throwable"
        },
        {
          "type": "shoot",
          "aim": "player",
          "interval": 2.2,
          "speed": 320,
          "size": 24,
          "spin": 260,
          "element": "block",
          "images": [
            "objects/tetro-i.png",
            "objects/tetro-o.png",
            "objects/tetro-t.png",
            "objects/tetro-s.png",
            "objects/tetro-z.png",
            "objects/tetro-j.png",
            "objects/tetro-l.png"
          ],
          "range": 600,
          "leaves": "throwable"
        }
      ]
    }
  },
  "throwables": {
    "_": {
      "name": "Stone block",
      "image": "objects/stone-block.png",
      "width": 26,
      "height": 26
    }
  }
}
'@
    $expLevels = [ordered]@{}
    $expLevels['levels/heights1.txt'] = @'
......................................................................
......................................................................
......................................................................
......................................................................
......................................................................
......................................................................
......................................................................
......................................................................
......................................................................
.....................oo...............................................
....................::::..............................................
...............o...........o..........................................
..............::::........::::........................................
..............................................:::.....................
..P................................s....1...........C.......y......G..
#############..................###############...#####################
ddddddddddddd..................ddddddddddddddd...ddddddddddddddddddddd
'@
    $expLevels['levels/heights1-cape.txt'] = @'
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
x............................x
x............................x
x............................x
x............................x
x............................x
x............................x
x............................x
x............................x
x............................x
x............................x
x..............,.............x
x...........=======..........x
x.1..o..o..o..o..o..o..o..o..x
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
'@
    $expLevels['levels/heights2.txt'] = @'
............................................................
............................................................
............................................................
............................................................
............................................................
..............................E.............................
............................=====...........................
............................................................
............................................................
............................................................
............................................................
............................................................
............................................................
........o..o..o..o..o..o....................................
..P............k....................C...t._._.......;....G..
##########################J#################################
dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
'@
    $xfiles = [ordered]@{}
    foreach ($k in @('tiles/cloud.png', 'items/cape.png', 'enemies/golem.png', 'enemies/golem-angry.png', 'enemies/golem-dizzy.png', 'objects/stone-block.png') + @('i', 'o', 't', 's', 'z', 'j', 'l' | ForEach-Object { "objects/tetro-$_.png" })) { $xfiles[$k] = $files[$k]; $files.Remove($k) }
    $xfiles['world.json'] = $utf8.GetBytes($expansionJson)
    foreach ($name in $expLevels.Keys) { $xfiles[$name] = $utf8.GetBytes($expLevels[$name]) }
    $xpath = Join-Path $WorldsDir 'Greenwood Heights.zip'
    if (Test-Path -LiteralPath $xpath) { Remove-Item -LiteralPath $xpath -Force }
    $fs2 = [System.IO.File]::Open($xpath, [System.IO.FileMode]::Create)
    $zip2 = New-Object System.IO.Compression.ZipArchive($fs2, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $xfiles.Keys) {
            $stream = $zip2.CreateEntry($name).Open()
            $bytes = [byte[]]$xfiles[$name]
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Dispose()
        }
    }
    finally { $zip2.Dispose(); $fs2.Dispose() }

    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Create)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $files.Keys) {
            $stream = $zip.CreateEntry($name).Open()
            $bytes = [byte[]]$files[$name]
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Dispose()
        }
    }
    finally { $zip.Dispose(); $fs.Dispose() }

    [void][System.Windows.MessageBox]::Show("Created:`n$path`n$xpath`n`nPick Greenwood Hills from the world list to play. Greenwood Heights is an expansion: add it from Greenwood Hills' Expansions button.", 'Sample world')
    Show-WorldSelect
}

# ---------------------------------------------------------------------------
# Wire up events
# ---------------------------------------------------------------------------
$BtnPlay.Add_Click({ Invoke-Safe { Show-WorldSelect } })
$BtnStats.Add_Click({ Invoke-Safe { Show-StatsScreen } })
$BtnSample.Add_Click({ Invoke-Safe { New-SampleWorld } })
$BtnFolder.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$WorldsDir`"" })
$BtnExit.Add_Click({ $Window.Close() })

$BtnSelectBack.Add_Click({ Show-Screen 'MainMenu' })
$BtnRefresh.Add_Click({ Invoke-Safe { Show-WorldSelect } })
$BtnLoadWorld.Add_Click({ Start-WorldLoad $WorldList.SelectedItem })
$WorldList.Add_MouseDoubleClick({ Start-WorldLoad $WorldList.SelectedItem })

$BtnHubBack.Add_Click({
    [void](Save-WorldData)
    $script:World = $null
    $script:MapCache = @{}
    Show-WorldSelect
})
$BtnResetStats.Add_Click({
    $answer = [System.Windows.MessageBox]::Show("Reset the tries, deaths and best times for '$($script:World.Name)'?`nSave slots are not affected.",
                                                'Reset stats', 'YesNo', 'Warning')
    if ("$answer" -eq 'Yes') {
        $last = $script:World.Stats.lastSlot
        $script:World.Stats = New-EmptyStats
        $script:World.Stats.lastSlot = $last
        [void](Save-WorldData)
        Show-Hub
    }
})
foreach ($n in 1..$SlotCount) {
    (Get-Variable -Name "BtnSlot$n" -Scope Script -ValueOnly).Add_Click({
        param($s, $e)
        $script:World.SlotNumber = [int]$s.Tag
        Show-Hub
    })
}
$BtnContinue.Add_Click({
    Invoke-Safe {
        $slot = $script:World.Slots[$script:World.SlotNumber]
        if ($slot -and $slot.gameOver) { Show-Review; return }
        if (-not $slot -or -not $slot.resume) { return }
        $n = $slot.resume.level
        $lv = $script:World.LevelByNumber[[int]$n]
        if (-not $lv -or $lv.Error) {
            [void][System.Windows.MessageBox]::Show('That saved level no longer exists in this world, so the saved spot was cleared.', 'Continue')
            $slot.resume = $null
            Show-Hub
            return
        }
        Start-Level $n $slot.resume
    }
})
$BtnDeleteSlot.Add_Click({
    $n = $script:World.SlotNumber
    $answer = [System.Windows.MessageBox]::Show("Delete save slot $n? This can't be undone.", 'Delete save', 'YesNo', 'Warning')
    if ("$answer" -eq 'Yes') {
        $script:World.Slots[$n] = $null
        [void](Save-WorldData)
        Show-Hub
    }
})
$BtnInventory.Add_Click({ Invoke-Safe { Show-Inventory } })
$BtnRecord.Add_Click({ Invoke-Safe { Show-Review } })
$BtnShop.Add_Click({ Invoke-Safe { Show-Shop } })
$BtnMiniGames.Add_Click({ Invoke-Safe { Show-MiniGames } })
$BtnExpansions.Add_Click({ Invoke-Safe { Show-Expansions } })
$BtnWarnings.Add_Click({
    [void][System.Windows.MessageBox]::Show(($script:World.Warnings | ForEach-Object { "- $_" }) -join "`n", "Warnings for $($script:World.Name)")
})
$BtnStatsBack.Add_Click({ Show-Screen 'MainMenu' })

# Keyboard: same path as the controller
$Window.Add_PreviewKeyDown({
    param($s, $e)
    $key = $e.Key.ToString()
    if ($key -eq 'System') { return }
    if (Invoke-Safe { Invoke-KeyDown $key }) { $e.Handled = $true }
})
$Window.Add_PreviewKeyUp({ param($s, $e) [void]$script:Held.Remove($e.Key.ToString()) })

# Pause automatically when switching to another window
$Window.Add_Deactivated({ Suspend-Game; $script:Held.Clear() })

$Window.Add_Closing({
    $LoadTimer.Stop()
    Stop-GameLoop
    $TimingTimer.Stop(); $BlockTimer.Stop()
    if ($script:Run -and $script:Run.MiniGame -and $script:Run.State -in 'Playing', 'Paused', 'Dead', 'Warping') { Complete-MiniGameLevel 'The window was closed.' $true }
    elseif ($script:Run -and $script:Run.State -in 'Playing', 'Paused', 'Dead', 'Warping') {
        $script:Run.Slot.resume = Get-ResumeData            # closing mid-level = save and quit
    }
    if ($script:World) { [void](Save-WorldData) }
})

# ---------------------------------------------------------------------------
# Go
# ---------------------------------------------------------------------------
$HelpText.Text = $KeyboardHelp
Show-Screen 'MainMenu'
[void]$Window.ShowDialog()
