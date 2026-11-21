#!/usr/bin/env bash
# grind-refresh runner v2 — Netlify Path-C self-chaining draft build (0-credit).
# Runs on branch `run` of the PUBLIC bootstrap repo; carries NO secrets:
#   - state snapshot (seen-ids gz) committed by the agent-side sync (runner_state_sync.sh)
#   - haul egress = publish dir (dist/) served at the draft URL; agent-side import
#     (runner_haul_import.py) pulls deploys via the Netlify API and unions into git.
#   - self-chain via site build hook; cadence controlled by CHAIN_SLEEP.
# Laws: never --prod (non-default branch => draft); bounded lanes; the agent-side
# import re-triggers the hook if the chain stalls (>2h stale) — it is the supervisor.
set -uo pipefail
TS=$(date -u +%Y%m%dT%H%M%SZ)
echo "[runner] v2 start ts=$TS"
HOOK_URL="${HOOK_URL:-}"
CHAIN_SLEEP="${CHAIN_SLEEP:-780}"
LANE_IMAGES="${LANE_IMAGES:-150}"

python3 -m venv /tmp/venv 2>/dev/null || true
PY=/tmp/venv/bin/python3
$PY -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true
$PY -m pip install --quiet curl_cffi || { echo "[runner] FATAL curl_cffi"; exit 1; }

REPO=$PWD
WS=/tmp/ws
mkdir -p $WS/sketchfab/records $WS/civitai-images/records $WS/civitai/records
for pair in "sketchfab sketchfab-seen-ids.txt.gz" "civitai-images civitai-images-seen-ids.txt.gz" "civitai civitai-seen-ids.txt.gz"; do
  set -- $pair; site=$1; gz=$2
  : > $WS/$site/seen-ids.txt
  zcat "$REPO/state-snapshot/$gz" >> $WS/$site/seen-ids.txt 2>/dev/null || true
  [ -f "$REPO/state-snapshot/civitai-models-seen-ids.txt.gz" ] && [ "$site" = civitai ] && zcat "$REPO/state-snapshot/civitai-models-seen-ids.txt.gz" >> $WS/$site/seen-ids.txt 2>/dev/null || true
  sort -u $WS/$site/seen-ids.txt -o $WS/$site/seen-ids.txt
done
cp $REPO/state-snapshot/sketchfab-state.json $WS/sketchfab/state.json 2>/dev/null || true
cp $REPO/state-snapshot/civitai-images-state.json $WS/civitai-images/state.json 2>/dev/null || true
cp $REPO/state-snapshot/civitai-state.json $WS/civitai/state.json 2>/dev/null || true

# --- lanes (sketchfab FIRST: irreversible-loss site) ---
cd $REPO
timeout 150 $PY scripts/walkers/sketchfab_models_walk.py 40 --state-dir $WS/sketchfab --fresh --stop-seen-pages 3 || echo "[runner] lane skfb-unfiltered rc=$?"
timeout 200 $PY scripts/walkers/sketchfab_models_walk.py 120 --state-dir $WS/sketchfab --downloadable true --fresh --stop-seen-pages 3 || echo "[runner] lane skfb-dl rc=$?"
timeout 60  $PY scripts/walkers/civitai_models_walk.py 12 --state-dir $WS/civitai --fresh --stop-seen-pages 3 || echo "[runner] lane cvt-models rc=$?"
timeout 320 $PY scripts/walkers/civitai_images_walk.py $LANE_IMAGES --state-dir $WS/civitai-images --fresh --stop-seen-pages 2 || echo "[runner] lane cvt-images rc=$?"

# --- haul into publish dir (draft URL serves these; agent import pulls) ---
DIST=$REPO/dist
mkdir -p $DIST/hauls/$TS $DIST/seen
manifest="{\"ts\":\"$TS\",\"files\":["
first=1
for site in sketchfab civitai civitai-images; do
  d=$WS/$site/records
  [ -d "$d" ] || continue
  for f in $(ls -t $d 2>/dev/null | head -60); do
    [ -s "$d/$f" ] || continue
    mkdir -p $DIST/hauls/$TS/$site
    cp "$d/$f" $DIST/hauls/$TS/$site/
    sz=$(stat -c%s "$d/$f")
    [ $first = 1 ] || manifest+=","
    manifest+="{\"site\":\"$site\",\"file\":\"$f\",\"bytes\":$sz}"
    first=0
  done
done
manifest+="]}"
echo "$manifest" > $DIST/manifest.json
for site in sketchfab civitai-images civitai; do
  gzip -c $WS/$site/seen-ids.txt > $DIST/seen/$site-seen-ids.txt.gz 2>/dev/null || true
done
echo "[runner] haul manifest: $manifest"
echo "grind-refresh-runner $TS" > $DIST/index.html

# --- self-chain (sleep for cadence, then fire hook; import job supervises stalls) ---
echo "[runner] sleeping $CHAIN_SLEEP s for cadence..."
sleep $CHAIN_SLEEP
if [ -n "$HOOK_URL" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -d '{}' "$HOOK_URL" || echo ERR)
  echo "[runner] self-chain hook POST -> $code"
else
  echo "[runner] no HOOK_URL — chain OFF (first boot)"
fi
echo "[runner] done ts=$TS"
