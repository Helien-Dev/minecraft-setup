# Servidor

Un modpack puede publicar también su server. Los mods del server salen del **standard del cliente**: el standard menos
`exclude` (mods solo de cliente) más `include` (mods solo de server). Así cliente y server comparten la misma versión de
cada mod que va en ambos lados, y cada jar existe una sola vez en `<prefix>/mods/`. La configuración del server **no**
deriva de la del cliente: es su propia base, formada por los archivos versionados en git del repo del server.

```
<prefix>/server/manifest.json   <- tag y commit, versión de NeoForge, base y lista de mods ya resuelta (nombre + sha256)
<prefix>/server/base.zip        <- los archivos versionados del repo del server (git ls-files)
```

## Publicar

```bash
./scripts/publish.py standard <modpack> <instancia-cliente>              # primero el cliente
./scripts/publish.py server   <modpack> <repo-server> <instancia-cliente>
```

Se niega a publicar si:
- el repo del server (o la instancia del cliente, si está en git) tiene cambios sin commit, el commit actual no tiene
  tag, o `mods/` no coincide con su `mods.lock`;
- cliente y server están en tags distintos;
- la instancia del cliente no es el standard publicado en R2;
- un mod está en ambos lados con jars distintos (mismo `modId`, otro archivo): hay que alinear la versión.

Genera `profiles/<prefix>/server.json` (exclude e include, para revisar en el commit). El manifest guarda la lista de mods
ya resuelta, así que publicar después un standard nuevo no cambia lo que instala el server hasta volver a publicarlo.

## Instalar o actualizar (Linux)

```bash
curl -sSL https://minecraft-data.alvaroavila.dev/install-server.sh | MODPACK=<id> sh -s <carpeta>
```

- Se niega a correr con el server de esa carpeta encendido.
- Instala Java 21 si falta (apt) y NeoForge si cambia su versión.
- Aplica la base completa (sobrescribe los archivos versionados y borra los que la versión nueva ya no trae) y deja
  `mods/` exactamente igual al manifest, verificando el sha256 de cada jar.
- Nunca toca `world/`, la whitelist, los OP, los baneos ni ningún archivo que no venga en la base.
- Escribe `.server-version` (`versión commit`), que leen las herramientas de medición del server.
- No acepta la EULA por ti: si falta `eula.txt`, avisa.
