#!/usr/bin/env bash
# cs_refresh_runner.sh — grind-engine refresh runner inside the zai-codespaces box.
# Deployed as a `cs svc` (survives local sandbox death; dies at the 12h hard cap;
# resurrected by future rounds' `cs ensure` or the public-repo keeper workflow).
# Duty: CYCLES cycles per resurrection (quota law: ~2 cycles/day keeps burn ~2 core-hr/day),
# then self-stops the box.
# Each cycle: pull grind-engine -> restore seen (repo gz + runner-seen union) ->
# walk lanes (sketchfab FIRST) -> push haul + runner-seen (unique haul paths,
# runner-seen single-writer) -> pull-rebase retry push.
set -uo pipefail
GHPAT="${GHPAT:?GHPAT required}"
CSSTOP_PAT="${CSSTOP_PAT:-$GHPAT}"
CSNAME="${GH_CODESPACE_NAME:-}"
CYCLES="${CYCLES:-2}"
GE=/workspaces/grind-engine
PY=/usr/local/bin/python3; [ -x "$PY" ] || PY=python3
PIP="$PY -m pip install --quiet"

mkdir -p /workspaces/.zai/svc 2>/dev/null || true
sudo $PIP curl_cffi 2>/dev/null || $PIP curl_cffi 2>/dev/null || { $PIP --break-system-packages curl_cffi 2>/dev/null || true; }
$PY -c "import curl_cffi" 2>/dev/null || { echo "[cs-runner] FATAL no curl_cffi"; exit 1; }

for c in $(seq 1 $CYCLES); do
  TS=$(date -u +%Y%m%dT%H%M%SZ)
  echo "[cs-runner] cycle $c/$CYCLES ts=$TS"
  if [ ! -d $GE/.git ]; then
    git clone --quiet "https://${GHPAT}@github.com/wesisad5/grind-engine.git" $GE || { echo "[cs-runner] clone FAIL"; exit 1; }
  fi
  cd $GE
  git config user.name grind-cs-runner
  git config user.email cs-runner@codespace.local
  git pull --rebase --quiet origin main 2>/dev/null || git pull --rebase --quiet "https://${GHPAT}@github.com/wesisad5/grind-engine.git" main 2>/dev/null || true

  WS=/tmp/ws
  rm -rf $WS && mkdir -p $WS/sketchfab/records $WS/civitai-images/records $WS/civitai/records
  for site in sketchfab civitai-images civitai; do
    : > $WS/$site/seen-ids.txt
    zcat state/$site-seen-ids.txt.gz >> $WS/$site/seen-ids.txt 2>/dev/null || true
    cat state/runner-seen/$site.txt >> $WS/$site/seen-ids.txt 2>/dev/null || true
    sort -u $WS/$site/seen-ids.txt -o $WS/$site/seen-ids.txt
  done
  cp state/sketchfab-state.json $WS/sketchfab/state.json 2>/dev/null || true
  cp state/civitai-images-state.json $WS/civitai-images/state.json 2>/dev/null || true
  cp state/civitai-state.json $WS/civitai/state.json 2>/dev/null || true

  timeout 150 $PY scripts/sketchfab_models_walk.py 40 --state-dir $WS/sketchfab --fresh --stop-seen-pages 3 || echo "[cs-runner] lane skfb-unf rc=$?"
  timeout 200 $PY scripts/sketchfab_models_walk.py 120 --state-dir $WS/sketchfab --downloadable true --fresh --stop-seen-pages 3 || echo "[cs-runner] lane skfb-dl rc=$?"
  timeout 60  $PY scripts/civitai_models_walk.py 12 --state-dir $WS/civitai --fresh --stop-seen-pages 3 || echo "[cs-runner] lane cvt-mod rc=$?"
  timeout 500 $PY scripts/civitai_images_walk.py 900 --state-dir $WS/civitai-images --fresh --stop-seen-pages 2 || echo "[cs-runner] lane cvt-img rc=$?"

  HAUL=$GE/state/runner-hauls/$TS
  mkdir -p $HAUL $GE/state/runner-seen
  for site in sketchfab civitai civitai-images; do
    d=$WS/$site/records
    [ -d "$d" ] || continue
    for f in $(ls -t $d 2>/dev/null | head -60); do
      [ -s "$d/$f" ] || continue
      mkdir -p $HAUL/$site
      cp "$d/$f" $HAUL/$site/
    done
  done
  for site in sketchfab civitai-images civitai; do
    cp $WS/$site/seen-ids.txt $GE/state/runner-seen/$site.txt 2>/dev/null || true
  done

  git add -A
  if git commit --quiet -m "cs-runner $TS: refresh lanes cycle $c (hauls + runner-seen)"; then
    for i in 1 2 3; do
      git pull --rebase --quiet "https://${GHPAT}@github.com/wesisad5/grind-engine.git" main 2>/dev/null || true
      if git push --quiet "https://${GHPAT}@github.com/wesisad5/grind-engine.git" main; then
        echo "[cs-runner] PUSH OK cycle $c"
        break
      fi
      echo "[cs-runner] push retry $i"; sleep 8
    done
  else
    echo "[cs-runner] cycle $c: nothing new to commit"
  fi
  [ "$c" -lt "$CYCLES" ] && sleep 120
done

echo "[cs-runner] duty complete — self-stopping the box ($CSNAME)"
if [ -n "$CSNAME" ]; then
  # POST /stop is the real endpoint (PATCH state=Stopped is a silent no-op — validated 2026-11-21)
  curl -s -X POST -H "Authorization: Bearer $CSSTOP_PAT" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/user/codespaces/$CSNAME/stop" >/dev/null 2>&1 || true
fi
