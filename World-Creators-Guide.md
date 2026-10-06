# PowerShell Platformer — World Creator's Guide

A world is one .zip file holding a world.json, plain-text level maps and PNG pictures. You build everything (levels, tiles, enemies, power-ups, bosses, shops, mini-games, expansions) by editing text, with no code. Drop the zip in the worlds folder and it shows up in the game.

## Quick start

You need a text editor and any way to make a zip. No pictures are required: anything without a picture is drawn as a coloured box, so you can design first and add art later.

1. Make a folder called `My First World`.
2. Inside it, create `world.json` with the text below.
3. Create a folder `levels` and inside it a file `level01.txt` with the map below.
4. Zip the **contents** of the folder (world.json at the top of the zip, or inside one top-level folder; both work).
5. Put the zip in the worlds folder (main menu → **Open worlds folder**), then **Play** → pick your world.

```json
{
  "name": "My First World",
  "author": "Your Name",
  "tiles": {
    "#": { "color": "#4CAF50" },
    "d": { "color": "#7A4A26" }
  },
  "enemies": {
    "s": { "name": "Slime", "movement": "patrol", "color": "#66D17A" }
  },
  "items": {
    "o": { "type": "coin" },
    "m": { "type": "shield", "name": "Mushroom" }
  },
  "levels": [
    { "name": "Hello World", "file": "levels/level01.txt" }
  ]
}
```

```text
..........................................
..........................................
...................ooo....................
..................#####...................
..........................................
.P...m..........s..........ooo.........G..
##########################....############
dddddddddddddddddddddddddd....dddddddddddd
```

`P` is where you start, `G` is the goal, and every other character is something you defined in world.json. When the world loads, the world menu's **Warnings** button lists anything it didn't understand, with the exact field and the fix. The quickest way to learn is to open the sample world (main menu → **Create sample world**), unzip a copy and change things.

## Inside a world zip

Only world.json and the level files are required. Folder names are up to you; world.json refers to every file by its path inside the zip.

```text
My World.zip
├─ world.json            the whole definition (required)
├─ thumbnail.png         picture in the world list (optional)
├─ levels/level01.txt    one text file per level area
├─ minigames/rush.txt    maps for challenge mini-games
├─ tiles/ enemies/ items/ player/ backgrounds/ objects/   PNG pictures
├─ stats.json            written by the game: tries, deaths, best times
├─ saves/slot1-3.json    written by the game: the three save slots
├─ chapters.json         written by the game: expansions you added
└─ chapters/<id>/...      each added expansion, a full world folder
```

| What | Notes |
| --- | --- |
| Pictures | PNG with transparency. Tiles are drawn at `tileSize` (default 32 px). Everything else is drawn at its own pixel size, centred on its hitbox and standing on its bottom edge. Draw characters **facing right**; the game flips them. |
| Level files | Plain text, one character per tile, rows of any length (short rows are padded with empty space). Tabs count as spaces. |
| Saves | The game writes saves into the zip itself, so a world carries its progress with it. Saving is crash-safe: the zip is copied, changed, then swapped in. Delete stats.json and saves/ to share a clean copy. |
| Size | One area can be up to 25 million pixels (for example 780 × 30 tiles at 32 px). |

## world.json settings

Only `levels` is required; everything else has a sensible default. Numbers out of range are clamped and listed under Warnings rather than breaking the world.

| Field | Default | What it does |
| --- | --- | --- |
| `name`, `author`, `description` | file name, Unknown, empty | Shown in the world list and world menu |
| `id` | name in lowercase-with-dashes | Stable id used by expansions (`expansionOf`) and cross-chapter exits. Set it once and never change it. |
| `thumbnail` | none | Picture for the world list (about 160 × 90) |
| `tileSize` | 32 | Pixel size of one map cell (8 to 128) |
| `background`, `backgroundColor` | none, `#5C94FC` | Picture tiled sideways with parallax, or a plain colour. `"none"` turns an inherited picture off. |
| `lives` | 3 | Lives per save. 0 = unlimited. A save that runs out becomes review-only. |
| `lifePrice` | 150 | Shop price of an extra life. 0 = not sold. |
| `timeLimit` | 300 | Seconds per life in every level. 0 = no limit (the clock just counts). |
| `minigameMinutesPer2Coins` | 10 | Mini-game cooldown: minutes of wait per 2 coins a game can pay out |
| `physics` | see Physics | World-wide movement settings |
| `player` | 22 × 30 blue box | `image`, `width`, `height`, `crouchHeight`, `animations` (see below) |
| `goal` | yellow flag | `{ "image": "..." }` for the G exit |
| `checkpoint` | grey post | `{ "image": "...", "activeImage": "..." }` |
| `warpTypes` | door, pipe, tunnel | Restyle or add warp kinds: `{ "image", "color", "enter": "up" \| "down" \| "auto" }` |
| `tiles`, `enemies`, `items` (or `powerups`), `mounts`, `platforms`, `exits`, `spawners` | none | Your map symbols, one section per kind |
| `minigames` | none | List of mini-games for the world menu |
| `levels` | required | Up to 11 levels, in order |
| `chapters` | none | Ids of chapters bundled in this zip under `chapters/<id>/` |
| `expansionOf`, `startUnlocked` | none | Only in an expansion's world.json (see Expansions) |

### Player and animations

```json
"player": {
  "image": "player/idle.png", "width": 22, "height": 40, "crouchHeight": 24,
  "animations": {
    "run":        ["player/run1.png", "player/run2.png"],
    "jump":       "player/jump.png",
    "invincible": { "frames": ["player/ball.png"], "fps": 12, "spin": 900 }
  }
}
```

An animation is a picture, a list of frames, or `{ "frames", "fps" (default 8), "spin" (degrees per second) }`. Missing states fall back to a similar one, then the plain `image`.

**The sleepy hero:** leave the player standing still for `sleepAfter` seconds (default 120; 0 turns it off) and they doze off, mumbling a random line from `sleepTalk` every few seconds, by default about ravioli. While they sleep, enemies tiptoe past without attacking and the level clock pauses. Any key wakes them. Use the `sleep` animation state for the picture, and set your own lines in the `player` section: `"sleepTalk": ["...five more minutes...", "...not the spiders..."]`.

| Who | States |
| --- | --- |
| Player | `idle`, `run`, `jump`, `fall`, `swim`, `climb`, `crouch`, `ride`, `invincible` |
| Enemies | `idle`, `move`, `jump`, `fly`, `swim`, `attack`, `windup`, `charge`, `drop`, `stunned`, `shy`, `platform` |
| Mounts | `idle`, `run`, `jump` |
| Power-ups | `playerImage` and `playerAnimations` change the player's look while worn |

## Drawing levels

Each character in a level file is one cell of the map. Every symbol you define in world.json (tile, enemy, item, mount, platform, exit, spawner) is a single character, and a character can only mean one thing in a world.

| Character | Meaning |
| --- | --- |
| `.` or space | Empty |
| `P` | Player start (exactly one per level, in any area) |
| `G` | The normal goal. Extra exits use symbols from `exits`. |
| `C` | Checkpoint: saves progress and is where you come back after dying |
| `0`–`9` | Warps. The two cells with the same digit in a level are linked (doors, pipes, tunnels, even between areas). |
| anything else | Whatever you defined in world.json |

Rules that save headaches:

- **Don't use two keys that differ only by case in the same section** (`x` and `X` in `tiles`). PowerShell's JSON reader can't tell them apart and the whole world fails to load. Different sections may reuse a letter's other case (tile `S`, enemy `s`).
- Punctuation makes good symbols: `? ! ( ) [ ] { } | : ; , + @ ~ ^ < > = & % $ *` are all usable.
- Enemies, mounts and items placed in a cell stand on the bottom of that cell. Put them on the row just above the ground.
- Objects placed inside water, lava or quicksand count as being in it, so they don't leave a gap in the liquid.
- Standard layout: 17 rows tall at 32 px fills the screen exactly (544 px). Taller maps scroll up and down.
- Falling below the bottom row kills the player, so a pit is just a gap in the ground.

A typical row plan for a 17-row level: rows 0–13 open air, row 14 where things stand, row 15 the ground surface, row 16 the ground below.

## Levels, areas, warps and exits

A level is one map (`file`) or several connected maps (`areas`). Up to 11 levels per world; more go in expansion chapters.

| Level field | Default | What it does |
| --- | --- | --- |
| `name` | Level N | Shown in the menu and HUD |
| `file` | — | The map, when the level has one area |
| `areas` | — | `{ "main": {...}, "cave": {...} }`, each with `file`, `background`, `backgroundColor`, `liquids`, `survival`. The area holding `P` is where you start. |
| `warps` | all doors | `{ "1": "pipe", "2": { "type": "door", "lock": "gold" } }` (digit → warp type, optionally locked by a key id) |
| `exits` | G opens the next level | Which levels each exit unlocks (below) |
| `hidden` | false | Not shown in the menu until an exit unlocks it |
| `startUnlocked` | level 1 only | Playable from the start |
| `requires` | none | What must be done before any exit of this level opens (below) |
| `timeLimit` | world's | Seconds per life; 0 = none |
| `physics` | world's | Physics changes for this level only (low gravity, slippery...) |
| `background`, `backgroundColor`, `liquids`, `survival` | world's / none | For single-area levels; multi-area levels set these per area |

### Weather and level types

Set `weather` and `levelType` at the top of world.json (the default for every level), on a level, or on one area (a cave area inside a sunny level).

| `weather` | What it does |
| --- | --- |
| `day` (default) | Nothing changes |
| `night` | Dim blue moonlight with a soft glow around the hero |
| `rain` | Nearly pitch black, with rain falling and a small glow around the hero. Lightning every few seconds lights up the whole level for a moment. |
| `snow` | A white haze and falling snow; every floor is slippery |

| `levelType` | What it does |
| --- | --- |
| `surface` (default) | Nothing changes |
| `underground` (also `cave`, `tunnel`, `tomb`) | Dark, with torchlight around the hero. Weather never reaches underground. |
| `clouds` | Floatier: gravity × 0.82, falling speed × 0.8. Pair it with a sky `backgroundColor`. |

Example: `{ "name": "Thunder Road", "file": "levels/l11.txt", "weather": "rain" }`. In the dark, keep pits and hazards fair: put coins or a lit landmark near them, or leave enough space between dangers for the hero's glow to reach.

### Exits and secret levels

```json
"exits": { "E": { "name": "Secret Exit", "image": "objects/secret.png" } },
"levels": [
  { "name": "First Steps", "file": "levels/l1.txt",
    "exits": { "G": [2], "E": [9, "heights:1"] } },
  ...
  { "name": "Secret Grotto", "file": "levels/l9.txt", "hidden": true }
]
```

- An exit with no `exits` entry: `G` opens the next level that isn't hidden; after a chapter's last level it opens the next chapter. Other exits open nothing unless listed.
- A target is a level number in the same chapter, or `"chapterId:level"` (or `"2:3"` by chapter number) to reach into another chapter.
- `"G": []` makes a final exit that opens nothing ("WORLD COMPLETE").
- The world menu shows how many of a level's exits each save has found.

### Exit requirements

```json
"requires": { "defeated": 10, "enemies": ["]"], "coins": 30, "items": { "g": 3 } }
```

| Key | Meaning |
| --- | --- |
| `defeated` | Defeat at least this many enemies (this life) |
| `enemies` | Defeat these enemy symbols; list one twice to need two |
| `coins` | Collect this many coins' worth in this level (coins collected on earlier visits count) |
| `items` | Collect these item symbols in this level: `{ "g": 3 }` or `["g", "g", "g"]` |

Put `requires` on the level (all exits) or on one exit: `"exits": { "E": { "unlocks": [9], "requires": { "coins": 50 } } }`. A shut exit looks faded, and touching it says what's missing. The HUD shows what the G exit still needs.

### Keys and locks

Keys (`"type": "key", "keyId": "gold"`) open lock tiles (`"lock": "gold"`) and locked warps. Keys carry between levels and chapters unless `"keepBetweenLevels": false`, take a bag slot each and are used up when they open something. A key taken from a level stays taken in that save, so you can carry a level-6 key back to level 1.

## Physics

Set these in the world's `physics`, a level's `physics`, a mount's `physics` or a power-up's `physics`. Later ones layer on top: world → level → power-up → mount. Speeds are pixels per second, accelerations pixels per second squared, times seconds. A jump's height is about jumpSpeed² ÷ (2 × gravity): 800² ÷ 4400 ≈ 145 px, about 4.5 tiles.

| Setting | Default | Range | What it does |
| --- | --- | --- | --- |
| `gravity` | 2200 | 100–10000 | Pull downward |
| `maxFall` | 900 | 50–3000 | Fastest falling speed |
| `runSpeed` | 240 | 20–2000 | Top running speed |
| `jumpSpeed` | 800 | 0–4000 | Upward speed of a jump |
| `groundAccel`, `airAccel` | 2200, 1500 | 0–20000 | How fast you speed up on the ground / in the air |
| `groundFriction`, `airFriction` | 2600, 800 | 0–20000 | How fast you slow down when you let go |
| `shortHopGravity` | 2.5 | 1–10 | Extra gravity when jump is released early (lower = floatier) |
| `coyoteTime` | 0.10 | 0–1 | You can still jump this long after running off a ledge |
| `jumpBuffer` | 0.12 | 0–1 | A jump pressed this long before landing still counts |
| `airJumps` | 0 | 0–10 | Extra jumps in mid-air for everyone |
| `stompBounce` | 480 | 0–4000 | Bounce after stomping an enemy (holding jump bounces higher) |
| `waterGravity`, `waterMaxFall` | 500, 160 |  | Sinking in water |
| `swimStroke` | 320 |  | Upward speed of one swim stroke |
| `swimSpeed` | 0.6 | 0.05–3 | Run speed multiplier in water |
| `waterExitJump` | 650 |  | Boost when jumping out of water |
| `crouchSpeed` | 0.35 | 0–2 | Run speed multiplier while crouching |
| `climbSpeed` | 150 | 0–2000 | Speed on ladders and vines |
| `lavaBounce` | 900 | 0–4000 | How hard lava throws you when it can't kill you |
| `sandSinkSpeed`, `sandSpeed`, `sandJump` | 45, 0.35, 420 |  | Quicksand: sinking speed, run multiplier, pop per jump press |
| `hurtBounce`, `hurtKnockback` | 560, 260 | 0–4000 | How high and how far a hit throws you |

Try `{ "gravity": 900, "maxFall": 500, "jumpSpeed": 520 }` for a moon level, or `{ "groundFriction": 150, "groundAccel": 500 }` for a whole level on ice.

## Tiles

A tile is a map cell with a picture and rules. Mix any fields below; a plain `{ "image": "tiles/grass.png" }` is a solid block.

### Basic fields

| Field | Default | What it does |
| --- | --- | --- |
| `image`, `color` | magenta box | Picture (drawn at tileSize) or colour. `"#00000000"` is invisible. |
| `rotate` | 0 | Turn the picture 90, 180 or 270° clockwise (one spike picture, four directions) |
| `solid` | true | Blocks movement |
| `solidFor` | `all` | `player` = only blocks the player (ghost walls enemies drift through), `enemies` = invisible fences that keep enemies in |
| `front` | true for liquids | Drawn in front of characters (hides secrets) |
| `liquid`, `lava`, `quicksand` | false | Water you swim in; lava (burns, or throws you if you're powered up); quicksand you sink in and hop out of |
| `deadly` | false | Hurts on overlap from any side (thorns, electricity). Outer 6 px are safe. |
| `spikes` | none | `"up"`, `"down"`, `"left"`, `"right"`, `"all"` or a list. Always solid; hurts only from the pointed side, blunt sides are walls. |
| `instantKill` | false | With `deadly` or `spikes`: kills instead of hurting |
| `deadlyToEnemies` | false | Enemies touching it are defeated (if weak to `hazard`) |
| `lock` | none | A lock block opened by a key with that `keyId`; touching groups open together |

### Movement tiles

| Field | Example | What it does |
| --- | --- | --- |
| `oneWay` | `true` | Jump up through it, land on top. Down + jump drops through. |
| `climbable` | `true` | Ladder or vine. Up/Down to grab, jump to let go. The top cell can be stood on. |
| `bounce` | `1150` | Spring: anything landing on it is thrown up at this speed (holding jump adds 12%) |
| `friction` | `0.12` | Ice below 1, grippy mud above 1: multiplies acceleration and slowing down |
| `conveyor` | `110` / `-110` | Carries whatever stands on it right / left (px per second) |
| `speed` | `0.5` | Run speed multiplier while standing on it (mud, sticky goo) |
| `affects` | `["player", "enemies"]` | Who bounce, conveyor, friction and speed apply to |

### Blocks that change while you play

These become live objects. They reset when you die, except what's been saved (coins from ? blocks stay collected).

| Field | Example | What it does |
| --- | --- | --- |
| `breakable` | `true` or `{ "by": ["powerHead", "shell", "fire"], "drop": "o" }` | Breaks when hit the listed ways, optionally leaving an item. `by` options: `head` (anyone's head), `powerHead` (a power-up with `breakBlocks`), `heavyStomp` (landing with a heavy-stomp power-up), `shell` (a kicked shell), `projectile` (any shot), or a projectile element like `fire`. Default: powerHead, shell, heavyStomp. |
| `bump` | `"o"` or `{ "gives": "m", "count": 3, "becomes": "U" }` | A ? block: hit from below (or by a shell) to get an item. Coins go straight in your pocket; anything else pops out on top. `becomes` = tile whose picture it shows once empty. |
| `crumble` | `0.5` or `{ "delay": 0.45, "respawn": 3 }` | Falls away this long after you stand on it; comes back after `respawn` seconds (0 = never) |
| `switch` | `"red"` | Hit from below (or by a shell) to flip every `toggle` block of that group |
| `toggle` | `"red"` or `{ "group": "red", "solid": false }` | Solid or see-through, flipped by its switch. `solid` = how it starts. |
| `gate` | `"during"` or `"until"` | Survival gates: `during` shuts while a survival fight is on; `until` stays shut until the fight is survived |

Anything standing on a block that's bumped from below is knocked out. Blocks never close on top of the player: they wait until there's room.

## Enemies

An enemy is a movement style, a toughness, a list of weaknesses, optional attacks and optional forms. Everything is mix-and-match.

```json
"t": { "name": "Turtle", "movement": ["patrol"], "speed": 45, "width": 28, "height": 26,
       "image": "enemies/turtle.png", "onDefeat": { "becomes": "c" } },
"c": { "name": "Shell", "movement": "none", "kickable": true, "kickSpeed": 460,
       "width": 26, "height": 18, "image": "enemies/shell.png" }
```

### Movement and senses

| Field | Default | What it does |
| --- | --- | --- |
| `movement` | `patrol` | Any mix of `patrol` (walk, turn at walls and edges), `follow` (chase when it sees you), `jump` (hop every `jumpInterval`), `fly` (ignores gravity), `swim` (moves only in water), or `none` |
| `speed` | 60 | Pixels per second |
| `width`, `height` | 28 × 24 | Hitbox; the picture is centred on it |
| `sight` | 320 | How far away (px) it notices you, for follow and attacks |
| `range` | 0 (96 for fliers) | How far it wanders from its start before turning |
| `turnAtEdges` | true | Patrollers turn instead of walking off ledges |
| `jumpSpeed`, `jumpInterval` | 600, 1.2 | For `jump` movement |
| `whenLookedAt` | none | `stop` freezes while you face it; `platform` turns into a solid block you can stand on (changes back only once you've left it) |

### Toughness and weaknesses

| Field | Default | What it does |
| --- | --- | --- |
| `health` | 1 | Hits to defeat. Each hit gives it a short flashing break. |
| `stomp` | `defeat` | Jumping on it: `defeat` (one hit), `bounce` (you bounce, it's fine: a helmet), `hurt` (it's spiky; you get thrown up) |
| `weakTo` | everything | What can hurt it (list below). Leave it out for "everything". |
| `contact` | `hurt` | `none` = harmless to touch (friendly or decorative) |
| `kickable` | false | A shell: touch or stomp it while still to kick it; stomp a moving one to stop it. A kicked shell knocks out enemies, breaks blocks and bumps ? blocks it hits, and hurts you if it hits you. |
| `kickSpeed` | 480 | Speed of a kicked shell |
| `boss` | false | Shows a health bar in the HUD and is listed in a save's review when beaten |

**Attack names for `weakTo`:** `star` (invincible player), `heavyStomp` (heavy-stomp power-up landing on it), `shell`, `block` (bumped from below), `hazard` (deadly tiles), `lava`, `fire`, `ice` (= can be frozen), any custom projectile `element` such as `bubble`, and `*` = any custom element. Stomping is controlled by `stomp`, not `weakTo`. Older worlds' `fireproof`, `freezable`, `lavaproof` and `stompable` still work.

Example, a stone guardian only stars and heavy stomps can beat: `"stomp": "hurt", "weakTo": ["star", "heavyStomp"]`.

### Forms and drops

| Field | Example | What it does |
| --- | --- | --- |
| `onHit` | `{ "becomes": "K", "drop": "o" }` | On every hit it survives: turn into another enemy and/or drop an item (a knight losing its armour) |
| `onDefeat` | `{ "becomes": "c", "drop": "m" }` | When defeated: turn into another enemy (turtle → shell) and/or drop an item |
| `carries` | `["$"]` | Items it holds and drops when defeated: keys, power-ups, 1-ups. A carried key is taken for good once picked up, so it's never duplicated. If the enemy falls off the map, what it carried appears where it started. |

### Attacks

`"attacks": [ {...}, {...} ]`: any mix, each with its own timer.

| Type | Fields (defaults) | What it does |
| --- | --- | --- |
| `shoot` | `interval` 2, `speed` 220, `aim` `player` (or `forward`, `up`, `down`, `left`, `right`), `count` 1, `spread` 15°, `gravity` false, `range` 420, `size` 12, `life` 3, `element`, `image`, `color` | Fires shots when you're in range. Shots stop at walls; a power-up immune to their `element` ignores them. |
| `charge` | `range` 300, `windup` 0.45, `speed` 380, `duration` 0.9, `cooldown` 2 | Stops, winds up, then rushes at you. A charging enemy breaks blocks it slams into. |
| `drop` | `range` 40, `speed` 900, `wait` 0.8, `rise` 120 | Falls on you when you pass underneath, waits, rises back. Give it `"movement": ["fly"], "speed": 0` so it hangs in the air. |
| `leap` | `range` 240, `speed` 650, `forward` 220, `cooldown` 1.5 | Jumps at you |

Animation states `attack`, `windup`, `charge`, `drop` and `stunned` let attacks look different.

**Shots with style:** `"images": ["objects/rock1.png", "objects/rock2.png"]` picks a random picture for each shot, and `"spin": 260` spins them (degrees per second; negative spins the other way).

**Talking enemies:** `"talk": ["You'll never reach the top!", "..."]` makes an enemy say its lines in turn, in a speech bubble, while it can see you. It pauses its attacks while it talks, so lines land between attacks. `talkEvery` (7 s) sets the gap between lines and `talkTime` (3 s) how long each stays up. Great for bosses with personality.

### Boss mechanics

| Field | Example | What it does |
| --- | --- | --- |
| `vulnerableWhen` | `"talking"` | Can only be hurt at certain moments: `always` (default), `talking` (while its speech bubble is up), `stunned`, or `thinking` |
| `hitEffects` | `{ "thrown": "stun" }` | Changes what an attack does to it: `defeat`, `stun`, `freeze` or `none` |
| `stunTime` | `3` | Seconds a stun lasts. A stunned enemy can't hurt you by touch, and even spiky ones can be stomped. A damaging hit ends the stun. |

Two more attack names for `weakTo`: `thrown` (a throwable block thrown by the player) and `thought` (see the `think` attack).

| Attack | Fields (defaults) | What it does |
| --- | --- | --- |
| `think` | `interval` 4, `think` 2.5 s, `speed` 300, `size` 24, `images`, `spin`, `gravity`, `range` 600, `leaves` | Pictures a shot in a thought bubble above its head, then throws it from there. A block thrown into the bubble drops the shot on its own head: a `thought` hit. |

Add `"leaves": "throwable"` to a `shoot` or `think` attack and its shots turn into blocks the player can pick up where they land (they fade after 15 s, at most 10 at a time).

**Stages:** chain enemies with `onDefeat` `becomes`, each with its own health, weaknesses and attacks. The sample world's Block Golem (Greenwood Heights, Summit) works like this:

1. **Stage 1** (3 hits): `"weakTo": ["thrown"], "vulnerableWhen": "talking"`. Throw his own blocks back at him while he talks.
2. **Stage 2** (3 hits): `"weakTo": ["thought"]` and a `think` attack. Throw a block into his thought bubble.
3. **Stage 3** (3 hits): `"hitEffects": { "thrown": "stun" }, "vulnerableWhen": "stunned", "stomp": "defeat"`. Stun him with a block, then stomp his head.

## Items and power-ups

Every item has a `type`, plus `name`, `image` (or `color`) and an optional pickup `message`.

| `type` | Extra fields | What it does |
| --- | --- | --- |
| `coin` | `value` (1) | Money for the shop. Collected coins never come back. |
| `collectible` |  | Gems or stars to find; the world menu shows found/total per level |
| `key` | `keyId`, `keepBetweenLevels` (true) | Opens locks and locked warps of the same id; takes a bag slot |
| `life` |  | +1 life (when the world counts lives) |
| `invincible` | `duration` (8) | Instant star power: defeats enemies by touch, safe from hits, lava dive with Down |
| `speed` | `duration` (10), `multiplier` (1.5) | Instant speed boost |
| `power` | ability fields below | A custom power-up |
| `shield`, `fireball`, `iceball`, `fly`, `doubleJump` |  | Ready-made power-ups (a plain shield, fire shots, freezing shots, flying, one extra air jump). They accept every ability field too. |

### How health works

Normal: one hit and you're out. Wearing a power-up: a hit takes it away (or one of its `hits`, or downgrades it). Invincible: nothing hurts, and when it ends you're back to whatever you wore. A mount takes a hit for you first. Every non-fatal hit throws you up and away from what hit you.

### The power-up ability kit

| Field | Example | What it does |
| --- | --- | --- |
| `projectile` | see below | Press the action button (E) to shoot |
| `airJumps` | `1` | Extra jumps in mid-air |
| `fly` | `true` or `{ "thrust": 3600, "maxRise": 300 }` | Hold jump to fly upward |
| `glide` | `90` | Hold jump while falling to fall no faster than this |
| `speed` | `1.3` | Run speed multiplier |
| `physics` | `{ "jumpSpeed": 950 }` | Any physics change while worn |
| `immune` | `["lava", "spikes", "hazards", "fire"]` | `lava` = swim in lava like water, `spikes` = spikes are just walls, `hazards` = deadly tiles don't hurt, any other word = enemy shots of that `element` can't hurt you |
| `heavyStomp` | `true` | Stomps defeat enemies weak to `heavyStomp` (even spiky ones) and break `heavyStomp` blocks you land on |
| `breakBlocks` | `true` | Your head breaks `powerHead` blocks |
| `hits` | `2` | Hits it absorbs before it's lost |
| `downgradeTo` | `"m"` | When hit, turn into this power-up instead of losing everything (Fire Flower → Mushroom → normal) |
| `duration` | `15` | Wears off after this many seconds (0 = lasts until hit) |
| `playerImage`, `playerAnimations` |  | How the player looks while wearing it |
| `shop` | `30` or `{ "price": 30 }` | Sold in the world menu's shop at this price. Without it the item can only be found. |

**Projectile fields:** `image`, `color`, `speed` (420), `max` on screen (2), `cooldown` (0.25 s), `life` (2 s), `size` (12), `gravity` (true), `bounce` along the floor (true), `pierce` through enemies (false), `effect` (`defeat`, `freeze`, `stun` or `none`), `element` (the attack name enemies are weak to: `fire`, `ice`, or your own word), `freezeTime` (8), `stunTime` (3), `iceImage`, `goesOutInWater` (true for fire), `meltsInLava` (true for ice). Shots also break blocks whose `breakable.by` lists `projectile` or the shot's element.

```json
"{": { "type": "power", "name": "Rock Helmet", "image": "items/helmet.png",
       "heavyStomp": true, "breakBlocks": true, "immune": ["spikes"], "hits": 2 },
"n": { "type": "power", "name": "Bubble Wand", "image": "items/wand.png", "shop": 40,
       "projectile": { "image": "objects/bubble.png", "effect": "stun", "stunTime": 3,
                       "element": "bubble", "gravity": false, "bounce": false, "speed": 330, "life": 1.2 } }
```

### Wearing, the bag and swapping

- You wear one power-up. Picking up another while wearing one puts the new one in your bag (8 slots, shared with keys). With a full bag you swap: you wear the new one and lose the old.
- **Tab / Q** (controller Back or LB) swaps to the next power-up in the bag during a level.
- In the world menu, **Bag** chooses what you'll wear into the next level, or throws things away.
- Power-ups carry between levels and chapters until you're hit or die. Invincibility and speed boosts start immediately and never go in the bag.

## Mounts, platforms and moving liquids

### Mounts

```json
"h": { "name": "Horse", "image": "mounts/horse.png", "width": 44, "height": 30, "riderY": 10,
       "canSwim": false, "physics": { "runSpeed": 360, "jumpSpeed": 900 } }
```

Touch a mount to ride it; C (controller Y) gets off, even in mid-air; the mount keeps half its speed and slows to a stop. It uses its own `physics`, takes one hit for you (then runs away), and stays behind at water unless `canSwim`. `riderY` moves the rider up or down on its back. Animation states: `idle`, `run`, `jump`.

### Moving platforms and crushers

```json
"-": { "name": "Raft", "image": "tiles/platform.png", "width": 3, "move": [3, 0], "speed": 70 },
"V": { "name": "Crusher", "width": 2, "height": 2, "move": [0, 4], "speed": 700,
       "returnSpeed": 90, "pauseStart": 1.2, "pauseEnd": 0.6, "startDelay": 1.0 }
```

The symbol marks the platform's top-left cell. `move` is how far it travels in tiles `[x, y]` before coming back. `width`/`height` are in tiles. One-tile-high platforms are one-way (`oneWay`) by default; taller ones are solid. Anything solid that moves into you pushes you, and with no room to be pushed you're crushed.

### Rising and falling water, lava or quicksand

```json
"liquids": [ { "type": "lava", "level": 15, "low": 15, "high": 11, "mode": "wave", "period": 8,
               "from": 20, "to": 35, "image": "tiles/lava.png", "surfaceImage": "tiles/lava-surface.png" } ]
```

| Field | Default | What it does |
| --- | --- | --- |
| `type` | `water` | `water`, `lava` or `quicksand` |
| `level` | required | Row of the surface at the start (decimals allowed) |
| `low`, `high` | `level` | Lowest and highest rows it moves between |
| `mode` | `wave` if low ≠ high | `still`, `wave` (smooth up and down every `period` seconds), `pingpong` (steady at `speed` rows/s, pausing `pause` s at each end), `rise` (keeps rising to `high` at `speed`) |
| `delay` | 0 | Seconds before it starts moving |
| `from`, `to` | whole width | Columns it covers (a pool instead of a flood) |
| `startOn` | `level` | `survival` = stays put until the area's survival fight starts |
| `afterSurvival` | `drain` | After the fight: `drain` (back to the start), `stay` (freeze where it is), `keep` (keep moving) |
| `image`, `surfaceImage`, `color`, `surfaceColor` |  | Looks |

Lava burns a normal player; if you're powered up or riding it takes that and throws you into the air. Invincible + holding Down lets you dive into lava and swim in it: a good way to hide a secret door.

### Throwables

```json
"throwables": { "_": { "name": "Stone block", "image": "objects/stone-block.png", "width": 26, "height": 26 } }
```

Place the symbol in a map and the player can pick it up with the action button (E on the keyboard, X on a controller) and throw it with the same button again: forward, or straight up while holding Up. Thrown blocks hurt enemies weak to `thrown` (most are, by default), bounce off what they hit, can be picked up again where they land, and fall from your hands when you're hit. Enemy shots can leave throwables too (`"leaves": "throwable"`).

## Survival arenas and bosses

A survival fight is a timer you must outlast while enemies pour in and the water or lava moves. It belongs to an area: make the whole level one area for a survival level, or put the arena in its own area behind a door or pipe for a survival section inside a normal level.

```json
"areas": { "main": { "file": "levels/arena.txt",
  "liquids": [ { "type": "lava", "level": 16, "low": 16, "high": 13.5, "mode": "pingpong",
                 "from": 26, "to": 29, "startOn": "survival", "afterSurvival": "drain" } ],
  "survival": { "time": 30, "startColumn": 13, "message": "SURVIVE THE SLIMES!",
                "spawn": ["s", "b"], "spawnEvery": 3, "maxEnemies": 5,
                "waves": [ { "at": 10, "spawn": "y", "count": 2, "every": 1.5 } ],
                "reward": "+" } } }
```

| Survival field | Default | What it does |
| --- | --- | --- |
| `time` | 60 | Seconds to survive. The level's own time limit pauses meanwhile. |
| `startColumn` | when you enter | The fight starts when you pass this column |
| `message` | SURVIVE! | Shown when it starts |
| `spawn`, `spawnEvery`, `maxEnemies` | none, 3, 6 | A steady stream: one random enemy from the list every few seconds, while fewer than the maximum are alive |
| `waves` | none | Set pieces: at `at` seconds, `count` enemies of `spawn`, one every `every` seconds |
| `reward` | none | Item that appears beside you when you survive |
| `completeLevel`, `exit` | false, `G` | Surviving finishes the level through that exit (a pure survival level) |

- **Where enemies appear:** add `"spawners": { "@": { "name": "Slime hole", "image": "objects/spawner.png" } }` and place `@` in the map. Enemies come out of them in turn. With no spawners they drop in from the top of the screen.
- Spawned enemies hunt you anywhere in the area, whatever their movement says. When time's up they retreat.
- **Gates:** tiles with `"gate": "during"` let you in and shut behind you when the fight starts; `"gate": "until"` keeps the way on blocked until you've survived.
- A survived fight is saved with your progress at the next checkpoint or the level's end; die before that and you fight again.

**Pipes that keep things coming (dispensers).** Give a spawner a `dispense` list and it becomes a pipe that spits out enemies and power-ups in turn, in any level, not just survival arenas. Use one wherever a player could otherwise get stuck: an enemy a puzzle needs fell in the lava, or the power-up you need was lost. It only spits out a kind while fewer than its `max` are out (defeated enemies and picked-up power-ups free up a spot), and only while the player is within `range` pixels.

```json
"spawners": {
  "/": { "name": "Slime pipe", "image": "tiles/pipe-top.png",
         "dispense": ["s", "i"], "max": { "s": 3, "i": 1 },
         "every": 3, "walk": "right" }
}
```

| Field | Default | What it does |
| --- | --- | --- |
| `dispense` | (none) | Enemy and power-up symbols to spit out, taking turns. Coins, keys, collectibles and lives aren't allowed (no farming). |
| `max` | 3 per enemy, 1 per power-up | How many of each symbol can be out at once. |
| `every` | 3 | Seconds between spits. |
| `walk` | `away` | Which way enemies walk once they land: `left`, `right`, `player` (toward the player) or `away` (away from the player). |
| `launch` | 420 | How hard things pop up out of the pipe. |
| `range` | 640 | Only works while the player is this close (pixels). |
| `solid` | true | The pipe cell is solid, so you can stand on it. |

Things from a pipe never drop loot. A pipe power-up is worn straight away (what you wore goes into your bag if there's room). It never goes into the bag itself, and swapping away from it throws it out. If you're already wearing that power-up, it stays where it landed. The sample world's Lava Works has one by the ice-block climb.

### Bosses

A boss is an enemy with `"boss": true`, more `health` and some attacks. Lock the exit until it's beaten with `requires`, or let it `carry` the key to the exit door.

```json
"]": { "name": "King Slime", "boss": true, "health": 5, "width": 64, "height": 48,
       "movement": ["follow", "jump"], "speed": 55, "sight": 700, "jumpInterval": 2.4,
       "image": "enemies/kingslime.png", "carries": ["+"], "onHit": { "drop": "o" },
       "attacks": [ { "type": "shoot", "aim": "forward", "count": 3, "spread": 25,
                      "interval": 3, "gravity": true, "element": "goo" } ] }
```

Ideas: make a two-phase boss with two symbols, where phase one has `"onDefeat": { "becomes": "<phase two>" }` and phase two is faster with its own `health` (list phase two in `requires`); add `"stomp": "bounce"` plus `"weakTo": ["fire"]` so it can only be beaten with a fire power-up from the shop; put a survival fight right before the boss room.

## Lives, shop, bag and mini-games

All four live in the world menu, next to the save slots.

### Lives and game over

- `"lives": 3` at the top of world.json (0 = unlimited). Each death in a level costs one; mini-games never do.
- Extra lives: `life` items in levels, or the shop (`"lifePrice": 150`, 0 = not sold).
- Out of lives: the save becomes **review-only**. It can't be played, but **Log** shows how far it got, play time, tries and deaths (and what caused them), enemies and bosses beaten, power-ups found, bought and lost, items found, secret exits and hidden levels, and coins earned, spent and won. Start again in another slot, or delete it.

### Shop

Only power-ups that say so are sold: add `"shop": 30` to the item. Buying while wearing nothing puts it on you; otherwise it goes in the bag (or swaps with what you wear when the bag is full). Items without `shop` can only be found, which keeps exploring worthwhile. Expansions' shop items show up in the same shop.

### Mini-games

```json
"minigames": [
  { "id": "chests", "type": "pick", "name": "Treasure Chests", "choices": 3, "prizes": [0, 2, 6] },
  { "id": "star-stopper", "type": "timing", "name": "Star Stopper", "maxCoins": 4, "speed": 0.9, "zone": 0.16 },
  { "id": "coin-rush", "type": "level", "name": "Coin Rush", "file": "minigames/coin-rush.txt",
    "time": 25, "maxCoins": 10, "twists": ["reverse", "waterSwap", "noFloor", "popSpikes"] }
]
```

| Type | Fields | How it plays |
| --- | --- | --- |
| `pick` | `choices` (3), `prizes` (shuffled each play), `description` | Pick a box, win what's inside |
| `timing` | `maxCoins` (6), `speed` (0.8 sweeps/s), `zone` (0.18 of the bar) | Stop the marker in the zone; dead centre pays the most, the zone's edge half |
| `level` | `file`, `time` (30), `maxCoins` (20), `twists`, `swapEvery` (4 s), `noFloorFile`, `physics`, `background` | A short challenge map. The coins you grab are your winnings, up to `maxCoins`. Last until time runs out (or touch a G) to keep them all; die or give up and you keep half. |

Each play of a `level` mini-game picks one random twist from its list:

| Twist | Effect |
| --- | --- |
| `reverse` | Left and right are swapped |
| `waterSwap` | Water physics and normal physics take turns every `swapEvery` seconds |
| `noFloor` | The bottom three rows' solid tiles vanish and moving platforms appear, or the map in `noFloorFile` is used instead |
| `popSpikes` | Spikes pop out of the ground and pull back in, all over the map |
| `none` | No twist |

**Cooldowns:** starting a mini-game counts as playing it. Each one can be played again after `minigameMinutesPer2Coins` (10) minutes for every 2 coins it can pay out: a 10-coin game every 50 minutes, a 4-coin game every 20. Set `"cooldown": <minutes>` on a mini-game to override. Mini-game maps don't need a P-to-G route; they can be an open playground with walls at both ends.

## Expansions and chapters

A world holds 11 levels per chapter and up to 9 chapters (99 levels). Every chapter shares the world's save slots, so coins, keys, power-ups, the bag and lives carry straight across. Levels are labelled by chapter in the menu: 1-4, 2-1 and so on.

### Making an expansion (for someone else's world, or your own)

An expansion is an ordinary world zip whose world.json says which world it extends:

```json
{
  "name": "Greenwood Heights",
  "id": "greenwood-heights",
  "expansionOf": "greenwood-hills",
  "startUnlocked": true,
  "tiles": { ":": { "image": "tiles/cloud.png", "oneWay": true } },
  "items": { ",": { "type": "power", "name": "Sky Cape", "glide": 90, "airJumps": 1, "shop": 45 } },
  "levels": [
    { "name": "Cloud Steps", "file": "levels/heights1.txt" },
    { "name": "Summit", "file": "levels/heights2.txt", "exits": { "G": [], "E": ["greenwood-hills:8"] } }
  ]
}
```

- `expansionOf` is the main world's `id` (its name in lowercase with dashes if it has no `id`).
- It **inherits everything**: every tile, enemy, item, mount, platform, the player, goal, physics and warp types. Define only what's new, or redefine a symbol to change it in your chapter only.
- Pictures are looked up in the expansion first, then in the main world, so `"image": "enemies/slime.png"` reuses the main world's art.
- Give new items new symbols. A power-up from any chapter works in every chapter, so a Sky Cape bought in the shop works in chapter 1 too.
- Without `startUnlocked`, the chapter's first level opens when the previous chapter's last level is finished. Exits can point either way between chapters with `"chapterId:level"`.
- `tileSize` must match the main world.

### Adding one to a world

Players put the expansion zip in their worlds folder, open the main world and press **Expansions → Add**, or pick the expansion in the world list and say yes. The game copies it into the main world's zip under `chapters/<id>/` and lists it in chapters.json, so it travels with the world and its saves. **Update** re-copies a newer version; **Remove** takes it out (saves are kept). The Expansions window closes as soon as it's done. Once added, the expansion's own zip no longer shows in the world list, because it now lives inside the main world; Remove brings it back.

### Bundling chapters yourself

To ship a big world as one zip, put each chapter in `chapters/<id>/` (its own world.json, levels and art) and list them in the main world.json: `"chapters": ["heights", "caverns"]`. Order matters for level numbers, so add new chapters at the end.

## Cookbook

Copy, rename the symbols to ones you haven't used, and adjust.

**Classic three-tier power-ups** (Fire Flower → Mushroom → normal):

```json
"m": { "type": "shield", "name": "Mushroom", "image": "items/mushroom.png", "shop": 15 },
"f": { "type": "fireball", "name": "Fire Flower", "image": "items/flower.png",
       "projectileImage": "objects/fireball.png", "downgradeTo": "m", "shop": 30 }
```

**? blocks** (one with three coins, one with a mushroom) and the used-up look:

```json
"Q": { "image": "tiles/qblock.png", "bump": { "gives": "o", "count": 3, "becomes": "U" } },
"?": { "image": "tiles/qblock.png", "bump": { "gives": "m", "becomes": "U" } },
"U": { "image": "tiles/used.png" }
```

**A secret room behind breakable bricks with a reward inside:** `"B": { "image": "tiles/cracked.png", "breakable": { "by": ["powerHead", "fire"], "drop": "g" } }`, then wall the room with `B`.

**Switch puzzle:** a wall that opens and a bridge that appears from one switch:

```json
"S": { "image": "tiles/switch.png", "switch": "red" },
"Z": { "image": "tiles/red.png", "toggle": { "group": "red", "solid": true } },
"N": { "image": "tiles/red.png", "toggle": { "group": "red", "solid": false } }
```

**Defeat 10 enemies to open the exit:** on the level, `"requires": { "defeated": 10 }`.

**Boss holds the key to the exit door:** boss `"carries": ["$"]` where `$` is a key with `"keyId": "boss"`; the exit sits behind lock tiles `{ "lock": "boss" }` or a door warp `{ "type": "door", "lock": "boss" }`.

**Key from a later level opens a hidden level:** put the key in level 6, a locked door in level 1 leading to an area with a secret exit `E`, `"exits": { "E": [9] }` on level 1, and `"hidden": true` on level 9.

**Secret under the lava:** a door or exit at the bottom of a lava pool, plus a Star nearby. Invincible + Down dives in.

**Tide level:** `"liquids": [{ "type": "water", "level": 16, "low": 16, "high": 11, "mode": "wave", "period": 14 }]`.

**Ice cave:** level `"physics": { "groundFriction": 150, "groundAccel": 500 }`, or just some `"friction": 0.12` tiles.

**Ghost that becomes a step when you look at it:** `"movement": ["fly", "follow"], "whenLookedAt": "platform", "stomp": "hurt"`.

**Enemy pen:** an invisible tile `{ "color": "#00000000", "solidFor": "enemies" }` at each end keeps a patroller in place without stopping the player.

**Spring tower:** `"J": { "image": "tiles/spring.png", "bounce": 1150 }` under a column of one-way ledges `{ "oneWay": true }` four rows apart.

**No soft locks on an ice-block climb:** a pipe next to the wall that keeps one Ice Flower and up to three slimes around, with the slimes walking toward the wall: `"/": { "image": "tiles/pipe-top.png", "dispense": ["s", "i"], "max": { "s": 3, "i": 1 }, "walk": "right" }` in `spawners`.

## Testing and fixing

The game never crashes on a bad world: it skips what it can't use and lists each problem under the world menu's **Warnings** button (at the bottom of the world menu; it only shows up when there's something to fix), naming the field and the fix. Check it after every change.

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| "world.json is not valid JSON" | A missing comma or quote, or two keys differing only by case (`x` and `X`) in one section | Paste world.json into any JSON validator; rename one of the clashing keys |
| A level button says "Broken" | A missing level file, or no `P` | Warnings names the area and the file it looked for |
| Coloured boxes instead of pictures | Image path wrong (paths are relative to world.json; letter case doesn't matter) | Warnings lists every missing image |
| "uses unknown characters" | A map character not defined in world.json | Define it, or replace it with `.` |
| "warp N appears only once" | Each warp digit needs exactly two spots in the level | Add the partner, or remove it |
| Can't finish a level | No `G` or exit, or `requires` can't be met | Warnings flags missing goals; check the HUD's "Exit:" line in play |
| An expansion is ignored | `expansionOf` doesn't match the main world's `id`, or tileSize differs | Set `id` on the main world and copy it exactly |
| A power-up does nothing | Missing `type`, or a `projectile` with `effect: "none"` | Check Warnings; start from a cookbook recipe |
| Enemies ignore a weakness | An explicit `weakTo` replaces the default list | List every attack it should be weak to |

### A quick playtest routine

1. Load the world and read Warnings until it's empty ("Missing image" lines are fine while you're still using coloured boxes).
2. Play each level start to finish in a fresh save slot. **R** restarts the level; **Esc** pauses.
3. Try to break it: skip the intended route, die at each checkpoint, quit and Continue mid-level.
4. Set `"lives": 0` while designing, then put lives back for the real thing.
5. Before sharing, delete `stats.json`, `saves/` and `chapters.json` (unless you're bundling chapters) from the zip.

The built-in sample world (main menu → **Create sample world**) uses every feature in this guide: Gadget Works (level 9) shows each tile and enemy type, Lava Works (level 7) has a refill pipe by its ice-block climb, Slime Arena (level 10) shows survival and a boss, and Greenwood Heights is a ready-made expansion to add from the Expansions button.
