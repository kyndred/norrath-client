# Norrath — client distribution

Public mirror of the **Norrath MUD** client artifacts. The game repo is private,
so these built files live here where Mudlet's `Client.GUI` auto-install and plain
download links can fetch them without authentication.

**Do not hand-edit here** — this repo is generated. Source lives in the private
game repo under `client/`, and `client/publish_client.sh` pushes updates here.

## Contents

| File | What |
|------|------|
| `NorrathHUD.mpackage` | Mudlet HUD package (vitals/party/target/enemies/pets/abilities/map). Install via Mudlet → Package Manager, or let the server auto-install it. |
| `NorrathHUD.lua` | HUD source (readable; the `.mpackage` embeds a copy). |
| `NorrathCutscene.mpackage` | Mudlet cinematic cutscene overlay (spell FX, summons, title cards). |
| `NorrathCutscene.lua` | Cutscene source. |
| `norrath_ui.lua` | MudForge plugin (TP gauge, target bar, clickable pets/enemies/abilities). |

## Install (Mudlet)

Package Manager → Install → pick `NorrathHUD.mpackage` (and `NorrathCutscene.mpackage`).
Or connect and the server will offer to auto-install the HUD.

## Raw download URLs

```
https://raw.githubusercontent.com/kyndred/norrath-client/main/NorrathHUD.mpackage
https://raw.githubusercontent.com/kyndred/norrath-client/main/NorrathCutscene.mpackage
https://raw.githubusercontent.com/kyndred/norrath-client/main/norrath_ui.lua
```
