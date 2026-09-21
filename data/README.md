# data/

Tracking del estado de los mods a lo largo del tiempo — para no tener que
reconstruir a mano "qué se agregó" o "qué hay que subir al server" cada vez.

## `mods-state.json`

Foto del estado **actual** de la instancia local. Se regenera a mano por
ahora (no automático todavía). Cada mod tiene un `scope`:

- `shared` — ya estaba en el servidor desde el último baseline confirmado.
  No hace falta tocarlo.
- `server_added` — nuevo desde el baseline, y ya identificado como
  necesario en el servidor (gameplay, librería compartida, u optimización
  de servidor). Debería estar (o ya está) subido al server.
- `client_only` — nuevo desde el baseline, pero puramente cliente
  (rendimiento, renderizado, loading screen, etc.). No se sube al server.

## `mods-history.json`

Un array de eventos en orden cronológico. Cada entrada documenta un
"corte": cuántos mods había en total, y qué cambió respecto al evento
anterior (`added_client_only`, `added_server`, `updated` — pares
`{old, new}` cuando un mod cambia de versión/nombre de archivo—, y
`removed`).

El primer evento (`baseline_servidor_confirmado`) es el punto de partida
verificado contra el servidor real; los siguientes son incrementales desde
ahí.

## Cómo actualizar esto

Por ahora es manual: cuando agregues/actualices mods en la instancia local
y decidas qué va al servidor, agregá una entrada nueva a
`mods-history.json` con la fecha y las listas correspondientes, y
regenerá `mods-state.json` reclasificando los mods nuevos.

## `neofresh-profiles.json`

Qué mods de NeoFresh lleva cada perfil y por qué. La gama baja es un
subconjunto de la alta: debe tener todo mod que corra en servidor o en ambos
lados, para no crear discrepancias, y los de cliente puro no son obligatorios.
Cuando agregues mods a la alta, revísalos contra esa regla (Modrinth
`client_side`/`server_side`) y actualiza este archivo.
