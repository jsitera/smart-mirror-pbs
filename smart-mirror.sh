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
# Spuštění z frontendu:
#   git -C ~/smart-mirror-pbs pull && qsub ~/smart-mirror-pbs/smart-mirror.sh
#   qsub -v SM_DIR=/storage/<lokalita>/home/$USER/smart-mirror ~/smart-mirror-pbs/smart-mirror.sh
#
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

echo "uzel $NODE, úloha $PBS_JOBID, scratch $SCRATCHDIR"
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader || true
# Torch v image je cu128: potřebuje ovladač 570+. Se starším spadne při načtení modelu.

# Image se převede na SIF jen poprvé a pak se bere ze storage.
# Vrstvy a dočasné soubory jdou do scratche (Singularity to při $SCRATCHDIR nastaví sám).
if [ ! -f "$SIF" ]; then
    echo "Převádím docker://ghcr.io/jsitera/smart-mirror:$IMAGE_TAG na $SIF…"
    singularity build "$SIF.tmp" "docker://ghcr.io/jsitera/smart-mirror:$IMAGE_TAG"
    mv "$SIF.tmp" "$SIF"
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
