# AGENTS.md

Instalador de un comando de SKLauncher + modpacks (`install.sh` para Linux, `install.ps1` para Windows).
Los binarios viven en Cloudflare R2 (bucket `minecraft-data`, remote de rclone `r2`); `catalog.json` describe
qué hay publicado. Todo cambio de comportamiento se aplica a **ambos** instaladores.

## Reglas

### 1. Comentarios
- Solo comentarios de **una línea**. Nada de bloques multilínea ni varias líneas de comentario seguidas.
- Precisos y concisos: explican el *por qué*, no repiten lo que el código ya dice.

### 2. Idioma
- **Código 100 % en inglés**: variables, funciones, claves JSON, nombres de archivo.
- **Comentarios en español.**
- **Todo lo que ve el usuario** (salida de la terminal, menús, mensajes de error) en **español neutro**: sin voseo
  ni regionalismos ("elige", no "elegí"; "computadora", no "ordenador").

### 3. Simplicidad (KISS + DRY)
- El código más simple que funcione. Nada de abstracciones, opciones o capas "por si acaso".
- Una sola fuente de verdad para cada dato y cada lógica: si algo se repite, se extrae; si ya existe, se reutiliza.
- Legible a la primera por alguien que no escribió el código.

### 4. Documentación
- `README.md` explica **solo** qué hace el script y cómo usarlo (instalar, elegir modpack/perfil).
- Todo lo demás (publicar en R2, empaquetar, formato del catálogo, tracking de mods...) va en `docs/`, un archivo
  por tema, enlazado desde el README.

### 5. Perfiles: STANDARD como base
- Cada modpack tiene un perfil **standard**: el primero en `catalog.json` (o el único). Es el **único** con
  `base.zip` + `manifest.json`. Su id puede ser otro (`high`, `default`) para no romper instancias ya instaladas.
- Cualquier otro perfil instala el standard y luego **quita y/o agrega mods** según `profiles/<prefix>/<perfil>.json`;
  si su configuración difiere, redefine solo esos archivos (`config`) y omite los que no quiere (`skip`).
  Nunca tiene paquete propio.
- Todo se publica con `scripts/publish.py` (ver `docs/publicar.md`).

### 6. Espacio en R2
- Minimizar lo almacenado: cada `.jar` existe **una sola vez** por modpack (`<prefix>/mods/`), sin duplicados entre
  perfiles ni paquetes redundantes.
- Borrar de R2 lo que ya no referencia ningún catálogo/manifest (paquetes viejos, jars huérfanos, archivos sueltos),
  **previa confirmación del usuario**.

### 7. Subir mods nuevos
- El usuario indica la ruta local de la instancia y el modpack/perfil de destino.
- Comparar la carpeta `mods/` local contra el `manifest.json` publicado (nombre + sha256), **sin descargar jars**
  de R2. Subir solo los jars nuevos o cambiados, luego el manifest/paquete, y al final `catalog.json`.
- Nunca usar `rclone sync` sobre `mods/` (los perfiles lo comparten); solo `copy`/`copyto`.
- Antes de publicar, mostrar al usuario el resumen (agregados, actualizados, quitados) y pedir confirmación.

### 8. El exclude es sagrado
- Ningún mod listado en el exclude de un perfil puede terminar en la instancia instalada de ese perfil.
- **Doble verificación obligatoria**: al publicar (el manifest efectivo del perfil no contiene nada del exclude)
  y al instalar (tras extraer/actualizar, `mods/` no contiene nada del exclude; si queda algo, se borra y se avisa).
- Si un mod excluido cambia de versión en el standard, el exclude se actualiza en la misma publicación.
- Mods prohibidos: `banned` (por `modId`) en el modpack de `catalog.json`. `publish.py` se niega a publicar si alguno
  aparece, aunque el jar se llame distinto.
- Los instaladores **nunca** reemplazan un archivo de `config/` que el jugador ya tenga (ni `options.txt` ni
  `servers.dat`): solo agregan los nuevos. Decisión del usuario, para que nadie tenga que reconfigurar.
