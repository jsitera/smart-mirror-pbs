# smart-mirror-pbs

Spuštění chytrého zrcadla (SAM 3 live s hloubkovým laserem) jako dávkové
úlohy v PBS [MetaCentra](https://docs.metacentrum.cz). Úloha pustí na GPU uzlu
přes Singularity stejný image jako v Kubernetes,
`ghcr.io/jsitera/smart-mirror`. Stránka se pak otevře v Chrome na notebooku
přes SSH tunel.

Tohle repo obsahuje jen spouštěcí část. Zdrojový kód serveru a image je
v soukromém repu, sem se kopíruje při každé změně tagu image.

## Jednou předem (na frontendu)

```bash
git clone https://github.com/jsitera/smart-mirror-pbs ~/smart-mirror-pbs
mkdir -p ~/smart-mirror && chmod 700 ~/smart-mirror
(umask 077; cat > ~/smart-mirror/hf_token)      # vložit token Hugging Face, Ctrl-D
```

Token potřebuje přístup ke gated modelu `facebook/sam3`.

Spouštěcí soubory jsou v `~/smart-mirror-pbs`. Data jsou zvlášť v `~/smart-mirror`:
- SIF image;
- váhy modelů;
- token;
- logy.

`git pull` tak nic z toho nepřepíše.

## Spuštění

```bash
git -C ~/smart-mirror-pbs pull
qsub ~/smart-mirror-pbs/smart-mirror.sh
```

Pokud `$HOME` na výpočetním uzlu neukazuje na stejnou storage jako na
frontendu, zadej adresář s daty výslovně:

```bash
qsub -v SM_DIR=/storage/<lokalita>/home/$USER/smart-mirror ~/smart-mirror-pbs/smart-mirror.sh
```

Úloha chce jednu GPU od Ampere výš (`gpu_cap=compute_80`, aspoň 20 GB). Hodí se
tedy A40, L40S, A100 i H100. Dál 4 CPU, 32 GB RAM, 40 GB scratch a 3 hodiny.
Frontu `gpu` PBS vybere sám.

První spuštění trvá déle:
- image (několik GB) se převede na SIF do `~/smart-mirror`;
- stáhnou se váhy SAM 3 a Depth Anything 3.

Další spuštění obojí vezmou ze storage.

## Připojení

Až úloha běží (`qstat -u $USER` ukáže stav `R`), najdeš příkaz pro tunel a
URL v souboru:

```bash
cat ~/smart-mirror/connect-<jobid>.txt
```

Na notebooku pak:

```bash
ssh -N -L 8770:<uzel>:<port> <login>@<frontend>
```

V Chrome otevři `http://localhost:8770/?token=…`, stiskni **Start** a povol
kameru. Adresa `localhost` je pro Chrome secure context, takže kamera funguje
i bez HTTPS. Laser zapneš zaškrtávátkem **laser**.

Načtení modelů trvá pár minut, průběh je v `~/smart-mirror/server-<jobid>.log`.
Soubor s URL i log obsahují token a mají práva jen pro tebe.

## Ukončení

```bash
qdel <jobid>
```

Úloha drží GPU, dokud nevyprší walltime nebo ji neukončíš.

## Když něco nejde

- **Starý ovladač GPU:** torch v image je pro CUDA 12.8 a potřebuje ovladač
  570+. Verzi ovladače vypíše úloha na začátku do svého výstupu (`.o` soubor
  po skončení). Se starším ovladačem server spadne při načtení modelu.
- **`qsub` odmítne `gpu_cap`:** syntaxe se liší mezi PBS Pro a OpenPBS.
  Správný tvar ukáže [qsub assembler](https://my.metacentrum.cz/qsub-assembler).
- **Port:** úloha si volný port vybere sama, protože uzel sdílí víc úloh.

## Licence

[Apache 2.0](LICENSE)
