#!/usr/bin/env python3
# Publica modpacks en R2 (uso y ejemplos en docs/publicar.md).
import argparse
import datetime
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import tomllib
import zipfile
from fnmatch import fnmatch
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUCKET = os.environ.get("R2_BUCKET", "r2:minecraft-data")
UTF8_TEXT = ["--header-upload", "Content-Type: text/plain; charset=utf-8"]

# Datos personales o regenerables: se excluyen a cualquier profundidad.
ANYWHERE = {
    "saves", "screenshots", "logs", "crash-reports", "servers.dat", "servers.dat_old", "command_history.txt",
    "downloads", "bin", "natives", ".mixin.out", "fancymenu_data", "dynamic-resource-pack-cache",
    "dynamic-data-pack-cache", "server-resource-packs", "observable_announce", "ESM", "search_index",
}
# Igual, pero solo en la raíz de la instancia (hay carpetas homónimas más adentro, p. ej. kubejs/data/gtceu).
AT_ROOT = [
    "mods", "_backup-*", "journeymap", "simplebackups", "usercache.json", "usernamecache.json", "local",
    "confluence", "blueprints", "gtceu", "cache", ".cache", "particular_cache", "patchouli_data.json",
    ".qmenu_opened.marker", "mods_disabled", "showdown", "xaero", "XaeroWaypoints_BACKUP*", "debug",
    "cobblemon-battle-logs", "zandercore", "hs_err_pid*.log", "lightspeed-cache", "Distant_Horizons_server_data",
]


def die(msg):
    sys.exit(f"[ERROR] {msg}")


def confirm(question="¿Publicar?"):
    if input(f"\n{question} [s/N] ").strip().lower() not in ("s", "si", "sí", "y"):
        sys.exit("Cancelado, no se cambió nada en R2.")


def rclone(*args, capture=False):
    result = subprocess.run(["rclone", *args], capture_output=capture, text=capture)
    if result.returncode != 0:
        die(f"falló: rclone {' '.join(args)}\n{result.stderr if capture else ''}")
    return result.stdout


def upload(src, key, *extra):
    print(f"  -> {key}")
    rclone("copyto", str(src), f"{BUCKET}/{key}", "--s3-no-check-bucket", *extra)


def read_r2_json(key):
    result = subprocess.run(["rclone", "cat", f"{BUCKET}/{key}"], capture_output=True)
    return json.loads(result.stdout) if result.returncode == 0 and result.stdout else None


def write_json(path, data):
    Path(path).write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def file_meta(path):
    return {"sha256": sha256(path), "size": Path(path).stat().st_size}


def load_catalog():
    return json.loads((ROOT / "catalog.json").read_text(encoding="utf-8"))


def load_pack(pack_id):
    packs = load_catalog()["modpacks"]
    pack = next((m for m in packs if m["id"] == pack_id), None)
    return pack or die(f"el modpack '{pack_id}' no está en catalog.json. Disponibles: {', '.join(m['id'] for m in packs)}")


def profile_path(pack, profile_id):
    return ROOT / "profiles" / pack["prefix"] / f"{profile_id}.json"


def local_mods(mods_dir):
    if not mods_dir.is_dir():
        die(f"no existe la carpeta {mods_dir}")
    return {p.name: file_meta(p) for p in sorted(mods_dir.glob("*.jar"))}


def instance_files(instance):
    def excluded(rel):
        return any(part in ANYWHERE for part in rel.parts) or any(fnmatch(rel.parts[0], p) for p in AT_ROOT)
    files = (p for p in instance.rglob("*") if p.is_file())
    return {p.relative_to(instance).as_posix(): p for p in files if not excluded(p.relative_to(instance))}


def build_zip(files, out):
    # Fecha y orden fijos: el mismo contenido da el mismo sha256 y nadie vuelve a descargarlo.
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for name in sorted(files):
            info = zipfile.ZipInfo(name, date_time=(2000, 1, 1, 0, 0, 0))
            info.compress_type, info.external_attr = zipfile.ZIP_DEFLATED, 0o644 << 16
            with open(files[name], "rb") as src, zf.open(info, "w") as dst:
                while chunk := src.read(1 << 20):
                    dst.write(chunk)
    return file_meta(out)


def mod_ids(jar):
    ids = set()
    if zipfile.is_zipfile(jar):
        with zipfile.ZipFile(jar) as zf:
            for name in (n for n in zf.namelist() if n.endswith("mods.toml")):
                try:
                    ids |= {m["modId"].lower() for m in tomllib.loads(zf.read(name).decode("utf-8", "replace")).get("mods", [])}
                except (tomllib.TOMLDecodeError, KeyError, TypeError):
                    pass  # metadatos rotos: el jar no declara nada
    return ids


def check_banned(pack, jars):
    banned = {b.lower() for b in pack.get("banned", [])}
    hits = [f"{jar.name} ({', '.join(sorted(mod_ids(jar) & banned))})" for jar in jars if mod_ids(jar) & banned]
    if hits:
        die(f"{pack['name']} prohíbe estos mods: {', '.join(hits)}")


def check_duplicates(jars):
    # Dos versiones del mismo mod en mods/ hacen que el juego no arranque.
    owners = {}
    for jar in jars:
        for mod_id in mod_ids(jar):
            owners.setdefault(mod_id, []).append(jar.name)
    dups = [f"{i}: {', '.join(names)}" for i, names in sorted(owners.items()) if len(names) > 1]
    if dups:
        die("hay mods repetidos (deja solo una versión de cada uno):\n  " + "\n  ".join(dups))


def zip_hashes(path):
    with zipfile.ZipFile(path) as zf:
        return {n: hashlib.sha256(zf.read(n)).hexdigest() for n in zf.namelist() if not n.endswith("/")}


def print_list(title, names):
    if names:
        print(f"{title} ({len(names)}):")
        for name in names:
            print(f"    {name}")


def check_profiles(pack, mods):
    # El exclude es sagrado: cada nombre debe existir en el standard, o el mod se colaría con otro nombre.
    errors = []
    for prof in pack["profiles"][1:]:
        path = profile_path(pack, prof["id"])
        if not path.exists():
            continue  # perfil todavía sin publicar: `site` no deja publicar el catálogo sin él
        missing = [n for n in json.loads(path.read_text(encoding="utf-8"))["exclude"] if n not in mods]
        if missing:
            errors.append(f"el exclude de '{prof['id']}' nombra mods que ya no están en el standard: {', '.join(missing)}")
    if errors:
        die("\n".join(errors) + "\nSi un mod excluido cambió de versión, actualiza su nombre en el exclude y vuelve a publicar.")


def cmd_standard(args):
    pack = load_pack(args.pack)
    prefix, instance = pack["prefix"], Path(args.instance).expanduser()
    print(f"Calculando hashes de {instance / 'mods'}...")
    mods = local_mods(instance / "mods")
    check_banned(pack, [instance / "mods" / n for n in mods])
    check_duplicates([instance / "mods" / n for n in mods])
    check_profiles(pack, mods)
    old = read_r2_json(f"{prefix}/manifest.json") or {"mods": {}}
    added = sorted(set(mods) - set(old["mods"]))
    updated = sorted(n for n in mods if n in old["mods"] and old["mods"][n]["sha256"] != mods[n]["sha256"])
    removed = sorted(set(old["mods"]) - set(mods))

    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp) / "base.zip"
        print("Armando base.zip (todo menos mods/ y datos personales)...")
        files = instance_files(instance)
        base_meta = build_zip(files, base)
        base_changed = old.get("base", {}).get("sha256") != base_meta["sha256"]

        print(f"\n{pack['name']} (standard): {len(mods)} mods, base de {len(files)} archivos ({base_meta['size'] / 1e6:.1f} MB)")
        print_list("  Nuevos", added)
        print_list("  Actualizados", updated)
        print_list("  Quitados", removed)
        print(f"  Base: {'cambió, se publica' if base_changed else 'sin cambios'}")
        if not (added or updated or removed or base_changed):
            print("\nNada que publicar.")
            return
        confirm()

        if added or updated:
            listing = Path(tmp) / "upload.txt"
            listing.write_text("\n".join(added + updated) + "\n", encoding="utf-8")
            print(f"  -> {prefix}/mods/ ({len(added) + len(updated)} jars)")
            rclone("copy", str(instance / "mods"), f"{BUCKET}/{prefix}/mods", "--files-from-raw", str(listing), "--s3-no-check-bucket", "--progress")
        if base_changed:
            upload(base, f"{prefix}/base.zip")
        manifest = Path(tmp) / "manifest.json"
        now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        write_json(manifest, {"generatedAt": now, "base": base_meta, "mods": mods})
        upload(manifest, f"{prefix}/manifest.json")  # al final: publica el cambio cuando todo lo que referencia ya existe
    print("\nListo. Quienes ya lo tienen lo reciben al volver a correr el instalador.")


def cmd_profile(args):
    pack = load_pack(args.pack)
    prefix, ids = pack["prefix"], [p["id"] for p in pack["profiles"]]
    if args.profile not in ids[1:]:
        die(f"'{args.profile}' no es un perfil derivado de {pack['id']}. Derivados: {', '.join(ids[1:]) or 'ninguno'} (el standard es '{ids[0]}')")
    standard = read_r2_json(f"{prefix}/manifest.json") or die(f"{prefix}/manifest.json no está en R2: publica primero el standard")
    source = Path(args.source).expanduser()

    with tempfile.TemporaryDirectory() as tmp:
        overlay = Path(tmp) / "config.zip"
        profile = {"exclude": [], "include": {}, "skip": []}
        if source.is_dir():
            mods = local_mods(source / "mods")
            names = set(mods)
            # Configuración propia: lo que difiere del base del standard va en un zip; lo que le sobra, en skip.
            rclone("copyto", f"{BUCKET}/{prefix}/base.zip", str(Path(tmp) / "base.zip"))
            standard_files = zip_hashes(Path(tmp) / "base.zip")
            files = instance_files(source)
            changed = {n: p for n, p in files.items() if standard_files.get(n) != sha256(p)}
            profile["skip"] = sorted(set(standard_files) - set(files))
            if changed:
                profile["config"] = build_zip(changed, overlay)
        else:
            mods = {}
            names = {line.strip() for line in source.read_text(encoding="utf-8").splitlines() if line.strip()}
        extra = sorted(names - set(standard["mods"]))
        if extra and not mods:
            die(f"la lista nombra mods que el standard no tiene; para agregar mods pasa la carpeta de la instancia: {', '.join(extra)}")
        profile["exclude"] = sorted(set(standard["mods"]) - names)
        profile["include"] = {n: mods[n] for n in extra}
        check_banned(pack, [source / "mods" / n for n in extra])
        check_duplicates([source / "mods" / n for n in mods])

        path = profile_path(pack, args.profile)
        old = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {"exclude": [], "include": {}, "skip": []}
        print(f"\n{pack['name']} ({args.profile}) = standard - {len(profile['exclude'])} mods + {len(profile['include'])} mods")
        print_list("  Pasan a excluirse", sorted(set(profile["exclude"]) - set(old["exclude"])))
        print_list("  Dejan de excluirse", sorted(set(old["exclude"]) - set(profile["exclude"])))
        print_list("  Agregados", sorted(set(profile["include"]) - set(old["include"])))
        print_list("  Ya no se agregan", sorted(set(old["include"]) - set(profile["include"])))
        if "config" in profile:
            print(f"  Configuración propia: {len(zipfile.ZipFile(overlay).namelist())} archivos ({profile['config']['size'] / 1e3:.0f} KB)")
        print(f"  Archivos del base del standard que no instala: {len(profile['skip'])}")
        if profile == old and read_r2_json(f"{prefix}/profiles/{args.profile}.json") == profile:
            print("\nNada que publicar.")
            return
        confirm()

        for name in profile["include"]:
            upload(source / "mods" / name, f"{prefix}/mods/{name}")
        if "config" in profile:
            upload(overlay, f"{prefix}/profiles/{args.profile}.zip")
        path.parent.mkdir(parents=True, exist_ok=True)
        write_json(path, profile)
        upload(path, f"{prefix}/profiles/{args.profile}.json")
    print(f"\nListo. {path.relative_to(ROOT)} actualizado: haz commit.")


def cmd_site(args):
    for pack in load_catalog()["modpacks"]:
        prefix = pack["prefix"]
        published = set(rclone("lsf", f"{BUCKET}/{prefix}", "--files-only", capture=True).splitlines())
        published |= {"profiles/" + n for n in rclone("lsf", f"{BUCKET}/{prefix}/profiles", "--files-only", capture=True).splitlines()}
        needed = {"base.zip", "manifest.json"} | {f"profiles/{p['id']}.json" for p in pack["profiles"][1:]}
        if needed - published:
            die(f"a {pack['id']} le falta en R2: {', '.join(sorted(needed - published))}. Publícalo antes que el catálogo.")
    print("Publicando instaladores y catálogo...")
    upload(ROOT / "install.sh", "install.sh", *UTF8_TEXT)
    upload(ROOT / "install.ps1", "install.ps1", *UTF8_TEXT)  # sin charset, `irm` rompe los acentos
    upload(ROOT / "catalog.json", "catalog.json")
    print("\nListo.")


def cmd_clean(args):
    catalog = load_catalog()
    if read_r2_json("catalog.json") != catalog:
        die("el catalog.json de R2 no es el del repo: corre primero `publish.py site`")
    keep = {"catalog.json", "install.sh", "install.ps1"}
    keep |= {l["url"] for l in catalog["launcher"].values() if "://" not in l["url"]}
    for pack in catalog["modpacks"]:
        prefix = pack["prefix"]
        manifest = read_r2_json(f"{prefix}/manifest.json") or die(f"no se pudo leer {prefix}/manifest.json; no se borra nada")
        keep |= {f"{prefix}/base.zip", f"{prefix}/manifest.json"} | {f"{prefix}/mods/{n}" for n in manifest["mods"]}
        for prof in pack["profiles"][1:]:
            key = f"{prefix}/profiles/{prof['id']}"
            profile = read_r2_json(f"{key}.json") or die(f"no se pudo leer {key}.json; no se borra nada")
            keep |= {f"{key}.json"} | {f"{prefix}/mods/{n}" for n in profile["include"]}
            keep |= {f"{key}.zip"} if "config" in profile else set()
    print("Listando R2...")
    objects = json.loads(rclone("lsjson", BUCKET, "-R", "--files-only", capture=True))
    orphans = sorted((o for o in objects if o["Path"] not in keep), key=lambda o: o["Path"])
    if not orphans:
        print("R2 está limpio.")
        return
    print(f"\nSin uso ({len(orphans)} archivos, {sum(o['Size'] for o in orphans) / 1e9:.2f} GB):")
    for o in orphans:
        print(f"    {o['Size'] / 1e6:9.1f} MB  {o['Path']}")
    confirm("¿Borrar todo esto de R2?")
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        f.write("\n".join(o["Path"] for o in orphans) + "\n")
    rclone("delete", BUCKET, "--files-from-raw", f.name)
    os.remove(f.name)
    print("Listo.")


def main():
    sys.stdout.reconfigure(line_buffering=True)  # mantiene el orden con la salida de rclone
    parser = argparse.ArgumentParser(description="Publica modpacks en R2.")
    sub = parser.add_subparsers(required=True)
    p = sub.add_parser("standard", help="publica el standard de un modpack desde una instancia local")
    p.add_argument("pack")
    p.add_argument("instance")
    p.set_defaults(run=cmd_standard)
    p = sub.add_parser("profile", help="publica un perfil derivado (instancia local o lista de mods que conserva)")
    p.add_argument("pack")
    p.add_argument("profile")
    p.add_argument("source")
    p.set_defaults(run=cmd_profile)
    sub.add_parser("site", help="publica install.sh, install.ps1 y catalog.json").set_defaults(run=cmd_site)
    sub.add_parser("clean", help="borra de R2 lo que ya nada referencia").set_defaults(run=cmd_clean)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
