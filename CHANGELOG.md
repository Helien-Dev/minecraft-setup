# Changelog

## 2026-09-29

- **Nuevo formato en R2:** cada modpack tiene un `base.zip` (la instancia sin mods), un `manifest.json` y sus mods
  una sola vez en `<prefix>/mods/`. Los perfiles derivados son el standard menos y/o más mods, con configuración
  propia opcional. El bucket bajó de 8,7 GB a 3,8 GB.
- **Instaladores:** un solo proceso para instalar y actualizar. La configuración (`config/`, `kubejs/`...) llega a
  todos cada vez que cambia, los mods se bajan en paralelo y se verifican por sha256, y el exclude se verifica al
  instalar.
- **Windows:** detecta el SKLauncher oficial aunque esté instalado en otra carpeta (por su acceso del Menú Inicio) y
  agrega la instancia a ese, sin instalar el portable.
- **Windows:** respeta la carpeta de instancias del SKLauncher oficial aunque esté en otra unidad (la deduce de
  `instances.json` y la propone), y reutiliza la ruta de una instancia ya registrada.
- **config/ del jugador intocable:** al actualizar, los archivos de `config/` que ya existen no se reemplazan; solo
  llegan los nuevos. `kubejs/` y el resto del base sí se actualizan.
- **Launcher de Linux:** se baja del beta oficial en GitHub (4.0.54).
- **`scripts/publish.py`** reemplaza a `package-instance.sh`: `standard`, `profile`, `site` y `clean`.
- **Mods prohibidos por modpack** (`banned` en `catalog.json`): NeoCozy prohíbe HT's TreeChop.
- **NeoCozy:** 11 mods nuevos (Apothic Attributes, Puzzles Lib, Wild Battle API, Cobblemon Size Variation,
  FallingTree, Overweight Farming, Cobblemon Battle Tower, Infuser Apotheosis Compat, Extra Move Animations,
  Catch Indicator y CullLeaves).
- **NeoCozy sin duplicados:** se quitaron Apothic Attributes 2.10.1 y Puzzles Lib 21.1.60 (quedan 2.11.0 y 21.1.62).
  `publish.py` ahora se niega a publicar si dos jars declaran el mismo `modId`.
- **Pruebas:** `scripts/test-linux.sh` (de punta a punta, sin internet) y las de Windows adaptadas al formato nuevo.
