# Changelog

## 2026-09-29

- **Nuevo formato en R2:** cada modpack tiene un `base.zip` (la instancia sin mods), un `manifest.json` y sus mods
  una sola vez en `<prefix>/mods/`. Los perfiles derivados son el standard menos y/o más mods, con configuración
  propia opcional. El bucket bajó de 8,7 GB a 3,8 GB.
- **Instaladores:** un solo proceso para instalar y actualizar. La configuración (`config/`, `kubejs/`...) llega a
  todos cada vez que cambia, los mods se bajan en paralelo y se verifican por sha256, y el exclude se verifica al
  instalar.
- **Launcher de Linux:** se baja del beta oficial en GitHub (4.0.54).
- **`scripts/publish.py`** reemplaza a `package-instance.sh`: `standard`, `profile`, `site` y `clean`.
- **Mods prohibidos por modpack** (`banned` en `catalog.json`): NeoCozy prohíbe HT's TreeChop.
- **NeoCozy:** 11 mods nuevos (Apothic Attributes, Puzzles Lib, Wild Battle API, Cobblemon Size Variation,
  FallingTree, Overweight Farming, Cobblemon Battle Tower, Infuser Apotheosis Compat, Extra Move Animations,
  Catch Indicator y CullLeaves).
- **Pruebas:** `scripts/test-linux.sh` (de punta a punta, sin internet) y las de Windows adaptadas al formato nuevo.
