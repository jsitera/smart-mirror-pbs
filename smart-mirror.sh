#!/bin/bash
# SAM 3 live (se zrcadlem i laserem) jako dávková úloha v PBS MetaCentra.
# Stejný image jako v Kubernetes, spuštěný přes Singularity.
# Veřejná kopie pro frontend: https://github.com/jsitera/smart-mirror-pbs
# (zdroj je deploy/pbs/ v soukromém repu jsitera/smart-mirror).
#
# Jednou předem na frontendu (adresář na storage, token k gated facebook/sam3):
#   git clone https://github.com/jsitera/smart-mirror-pbs ~/smart-mirror-pbs
#   mkdir -p ~/smart-mirror && chmod 700 ~/smart-mirror
#   (umask 077; cat > ~/smart-mirror/hf_token)      # vložit HF token, Ctrl-D
#
# Poprvé (a po změně tagu image) převést image na SIF bez GPU, ať úloha
# na GPU nečeká na stahování (-l na příkazové řádce přebije #PBS níže):
#   qsub -v PULL_ONLY=1 -l select=1:ncpus=2:mem=16gb:scratch_local=40gb -l walltime=1:00:00 \
#     ~/smart-mirror-pbs/smart-mirror.sh
#
# Spuštění z frontendu:
#   git -C ~/smart-mirror-pbs pull && qsub ~/smart-mirror-pbs/smart-mirror.sh
#   qsub -v SM_DIR=/storage/<lokalita>/home/$USER/smart-mirror ~/smart-mirror-pbs/smart-mirror.sh
#
# Výstup úlohy je průběžně v $SM_DIR/job-<jobid>.log (soubor .o přijde až po konci).
# Až úloha poběží, v $SM_DIR/connect-<jobid>.txt je příkaz pro tunel a URL.
# Ukončení (uvolní GPU): qdel <jobid>
#
#PBS -N smart-mirror
# compute_80 = Ampere a novější (A40, L40S, A100, H100); SAM 3 běží v bf16.
#PBS -l select=1:ncpus=4:ngpus=1:gpu_mem=20gb:gpu_cap=compute_80:mem=32gb:scratch_local=40gb
#PBS -l walltime=3:00:00
#PBS -j oe

set -euo pipefail
umask 077   # log i soubor s URL obsahují token
trap 'clean_scratch' TERM EXIT

IMAGE_TAG=sha-4bb951f   # stejný tag, jaký běží v Kubernetes
SM_DIR=${SM_DIR:-$HOME/smart-mirror}
SIF=$SM_DIR/smart-mirror-$IMAGE_TAG.sif
NODE=$(hostname -f)
JOB=${PBS_JOBID%%.*}
exec > >(tee -a "$SM_DIR/job-$JOB.log") 2>&1

echo "uzel $NODE, úloha $PBS_JOBID, scratch $SCRATCHDIR"
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null || echo "bez GPU"
# Torch v image je cu128: potřebuje ovladač 570+. Se starším spadne při načtení modelu.

# Image se převede na SIF jen poprvé a pak se bere ze storage.
# Vrstvy a dočasné soubory jdou do scratche (Singularity to při $SCRATCHDIR nastaví sám).
if [ ! -f "$SIF" ]; then
    # Ne `singularity build docker://…`: ghcr.io vydává vrstvy přes odkazy do CDN
    # platné pár minut, 4GiB vrstva s torchem se nestihne stáhnout a Singularity
    # neumí navázat. Python níže stahuje s navazováním a složí docker-archive.
    echo "Stahuju ghcr.io/jsitera/smart-mirror:$IMAGE_TAG…"
    python3 - "ghcr.io/jsitera/smart-mirror:$IMAGE_TAG" "$SCRATCHDIR/image.tar" "$SCRATCHDIR/blobs" <<'PY'
"""Stáhne image z ghcr.io s navazováním a složí z něj docker-archive pro Singularity.

ghcr.io vydává vrstvy přes podepsané odkazy do CDN, které platí jen pár minut,
a vrstva s torchem (4 GiB) se za tu dobu nestihne stáhnout. `singularity build
docker://…` pak spadne a začne znovu od nuly. Tady se při přerušení vyžádá nový
odkaz a stahuje se dál od místa, kde přestalo (HTTP Range).

  python3 - ghcr.io/jsitera/smart-mirror:sha-… výstup.tar pracovní_adresář
  singularity build obraz.sif docker-archive:výstup.tar

Jen standardní knihovna, běží na čistém python3 na uzlu.
"""
import gzip
import hashlib
import http.client
import io
import json
import os
import shutil
import sys
import tarfile
import time
import urllib.error
import urllib.request

ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])
CHUNK = 1 << 20
ATTEMPTS = 30


class NoRedirect(urllib.request.HTTPRedirectHandler):
    # přesměrování na CDN chceme vidět: podepsaný odkaz nesmí dostat náš token
    def redirect_request(self, *args, **kwargs):
        return None


OPENER = urllib.request.build_opener(NoRedirect)


def token(registry: str, repo: str) -> str:
    url = f"https://{registry}/token?scope=repository:{repo}:pull"
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.load(r)["token"]


def get_json(registry: str, repo: str, ref: str) -> tuple[bytes, dict]:
    req = urllib.request.Request(
        f"https://{registry}/v2/{repo}/manifests/{ref}",
        headers={"Authorization": f"Bearer {token(registry, repo)}", "Accept": ACCEPT})
    with urllib.request.urlopen(req, timeout=60) as r:
        raw = r.read()
    return raw, json.loads(raw)


def blob_url(registry: str, repo: str, digest: str) -> str:
    """Vrátí podepsaný odkaz do CDN (platí jen pár minut, proto pokaždé nový)."""
    req = urllib.request.Request(f"https://{registry}/v2/{repo}/blobs/{digest}",
                                 headers={"Authorization": f"Bearer {token(registry, repo)}"})
    try:
        with OPENER.open(req, timeout=60) as r:
            return r.geturl()  # bez přesměrování: registry vrací blob samo
    except urllib.error.HTTPError as e:
        if e.code in (301, 302, 303, 307, 308):
            return e.headers["Location"]
        raise


def download(registry: str, repo: str, digest: str, size: int, path: str) -> None:
    """Stáhne blob do path, při přerušení pokračuje od místa, kde přestal."""
    attempt = 0
    while (have := os.path.getsize(path) if os.path.exists(path) else 0) != size:
        attempt += 1
        if attempt > ATTEMPTS:
            raise SystemExit(f"Blob {digest} se nepodařilo stáhnout ani na {ATTEMPTS}. pokus.")
        if have > size:
            os.remove(path)
            continue
        try:
            url = blob_url(registry, repo, digest)
            req = urllib.request.Request(url, headers={"Range": f"bytes={have}-"} if have else {})
            with urllib.request.urlopen(req, timeout=60) as r:
                if have and r.status != 206:
                    have = 0  # server rozsah ignoroval, začni znovu
                with open(path, "ab" if have else "wb") as f:
                    shutil.copyfileobj(r, f, CHUNK)
        except (OSError, http.client.HTTPException) as e:  # URLError je OSError
            got = os.path.getsize(path) if os.path.exists(path) else 0
            print(f"  {digest[7:19]}: přerušeno na {got / 2**20:.0f} MiB z {size / 2**20:.0f} "
                  f"({e.__class__.__name__}), pokus {attempt}/{ATTEMPTS}", flush=True)
            time.sleep(min(5 * attempt, 30))
    if sha256_file(path) != digest:
        os.remove(path)
        raise SystemExit(f"Blob {digest} nesedí na kontrolní součet, smazán.")


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(CHUNK):
            h.update(chunk)
    return "sha256:" + h.hexdigest()


def main() -> None:
    image, out, work = sys.argv[1], sys.argv[2], sys.argv[3]
    registry, rest = image.split("/", 1)
    repo, tag = rest.rsplit(":", 1)
    os.makedirs(work, exist_ok=True)

    _, index = get_json(registry, repo, tag)
    if "manifests" in index:  # index více platforem: vezmi linux/amd64
        digest = next(m["digest"] for m in index["manifests"]
                      if m.get("platform", {}).get("architecture") == "amd64"
                      and m.get("platform", {}).get("os") == "linux")
        _, manifest = get_json(registry, repo, digest)
    else:
        manifest = index

    cfg = manifest["config"]
    cfg_path = os.path.join(work, cfg["digest"][7:] + ".json")
    download(registry, repo, cfg["digest"], cfg["size"], cfg_path)
    diff_ids = json.load(open(cfg_path))["rootfs"]["diff_ids"]
    layers = manifest["layers"]
    assert len(diff_ids) == len(layers), (len(diff_ids), len(layers))
    total = sum(l["size"] for l in layers)
    print(f"{image}: {len(layers)} vrstev, {total / 2**30:.2f} GiB", flush=True)

    # docker-archive (formát `docker save`): manifest.json, config a nekomprimované vrstvy
    names = []
    with tarfile.open(out, "w") as tar:
        tar.add(cfg_path, arcname=os.path.basename(cfg_path))
        for layer, diff_id in zip(layers, diff_ids):
            gz = os.path.join(work, layer["digest"][7:] + ".gz")
            download(registry, repo, layer["digest"], layer["size"], gz)
            raw = gz[:-3] + ".tar"
            if layer["mediaType"].endswith("gzip"):
                with gzip.open(gz, "rb") as src, open(raw, "wb") as dst:
                    shutil.copyfileobj(src, dst, CHUNK)
                os.remove(gz)
            elif layer["mediaType"].endswith(".tar"):
                os.rename(gz, raw)
            else:
                raise SystemExit(f"Neznámý typ vrstvy {layer['mediaType']}.")
            if sha256_file(raw) != diff_id:
                raise SystemExit(f"Rozbalená vrstva {layer['digest']} nesedí na {diff_id}.")
            name = diff_id[7:] + "/layer.tar"
            tar.add(raw, arcname=name)
            os.remove(raw)
            names.append(name)
            print(f"  hotovo {layer['digest'][7:19]} ({layer['size'] / 2**20:.0f} MiB)", flush=True)
        meta = json.dumps([{"Config": os.path.basename(cfg_path),
                            "RepoTags": [f"{registry}/{repo}:{tag}"],
                            "Layers": names}]).encode()
        info = tarfile.TarInfo("manifest.json")
        info.size = len(meta)
        tar.addfile(info, io.BytesIO(meta))
    print(f"docker-archive: {out}", flush=True)


if __name__ == "__main__":
    main()
PY
    echo "Převádím na $SIF…"
    singularity build --force "$SIF.tmp" "docker-archive:$SCRATCHDIR/image.tar"
    rm -rf "$SCRATCHDIR/image.tar" "$SCRATCHDIR/blobs"
    mv "$SIF.tmp" "$SIF"
fi
if [ -n "${PULL_ONLY:-}" ]; then
    echo "Image je připravený: $SIF"
    exit 0
fi

# Váhy SAM 3 a Depth Anything 3 se stáhnou jednou na storage (image je jen ke čtení).
mkdir -p "$SM_DIR/hf" "$SCRATCHDIR/home" "$SCRATCHDIR/tmp"
# Token jen přes soubor ve scratchi, ať není v seznamu procesů.
printf 'HF_TOKEN=%s\n' "$(cat "$SM_DIR/hf_token")" > "$SCRATCHDIR/env"

RUN=(singularity run --nv --cleanenv --env-file "$SCRATCHDIR/env"
     --home "$SCRATCHDIR/home" -B "$SM_DIR/hf:/data" -B "$SCRATCHDIR/tmp:/tmp" "$SIF")

# Uzel sdílí víc úloh, takže pevný port 8770 může být obsazený: volný port vybere jádro.
PORT=$(singularity exec "$SIF" python -c \
    'import socket; s = socket.socket(); s.bind(("", 0)); print(s.getsockname()[1])')
TOKEN=$(singularity exec "$SIF" python -c 'import secrets; print(secrets.token_urlsafe(16))')

cat > "$SM_DIR/connect-$JOB.txt" <<EOF
Úloha $PBS_JOBID na $NODE, port $PORT (start $(date '+%F %T')).
Na notebooku (frontend libovolný, např. ten, ze kterého jsi úlohu poslal):
  ssh -N -L 8770:$NODE:$PORT $USER@<frontend>
Pak v Chrome:
  http://localhost:8770/?token=$TOKEN
Načtení modelů trvá pár minut, průběh je v $SM_DIR/server-$JOB.log.
Ukončení: qdel $PBS_JOBID
EOF
echo "Připojení: $SM_DIR/connect-$JOB.txt"

# Server poslouchá na všech rozhraních uzlu, aby na něj došel tunel z frontendu;
# bez tokenu stránka vrací 401 a WebSocket 4401.
"${RUN[@]}" --port "$PORT" --token "$TOKEN" > "$SM_DIR/server-$JOB.log" 2>&1
