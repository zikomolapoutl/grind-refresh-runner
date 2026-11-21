#!/usr/bin/env bash
# grind-refresh runner — Netlify Path-C cloud build (self-chaining, 0-credit draft).
# Runs on branch `run` of the PUBLIC bootstrap repo (grind-refresh-runner);
# clones the private grind-engine via GHPAT env, walks bounded refresh lanes,
# pushes haul records to state/runner-hauls/<ts>/ (conflict-free unique paths),
# maintains runner-namespace seen-ids, self-chains via build hook (GEN_MAX/day).
# Laws: never --prod (bind is non-default branch => draft), never force-push,
# unique-path hauls only (no shared-file mutation), pull --rebase before push.
set -uo pipefail
export NETLIFY=True
TS=$(date -u +%Y%m%dT%H%M%SZ)
echo "[runner] gen start ts=$TS"

# --- env (injected at site level BEFORE repo bind) ---
GHPAT="${GHPAT:?GHPAT env missing}"
HOOK_URL="${HOOK_URL:-}"
GEN_MAX="${GEN_MAX:-24}"     # chained builds per UTC day

# --- venv + deps (PEP 668-safe) ---
python3 -m venv /tmp/venv 2>/dev/null || true
PY=/tmp/venv/bin/python3
$PY -m pip install --quiet --upgrade pip >/dev/null 2>&1
$PY -m pip install --quiet curl_cffi || { echo "[runner] FATAL curl_cffi install"; exit 1; }
git --version >/dev/null || { echo "[runner] FATAL no git"; exit 1; }

# --- clone grind-engine (private, PAT auth) ---
rm -rf /tmp/ge
git clone --quiet "https://${GHPAT}@github.com/wesisad5/grind-engine.git" /tmp/ge || { echo "[runner] FATAL clone"; exit 1; }
cd /tmp/ge
git config user.name "grind-refresh-runner"
git config user.email "runner@netlify.local"
git pull --rebase --quiet origin main 2>/dev/null || true

# --- restore refresh state (repo-synced watermarks + runner-namespace seen) ---
WS=/tmp/ws
mkdir -p $WS/sketchfab/records $WS/civitai-images/records $WS/civitai/records
rest() {  # site_dir gz1 [gz2]
  site=$1; shift
  : > $WS/$site/seen-ids.txt
  for gz in "$@"; do zcat state/$gz >> $WS/$site/seen-ids.txt 2>/dev/null || true; done
  if [ -f state/runner-seen/$site-seen-ids.txt.gz ]; then
    zcat state/runner-seen/$site-seen-ids.txt.gz >> $WS/$site/seen-ids.txt 2>/dev/null || true
  fi
  sort -u $WS/$site/seen-ids.txt -o $WS/$site/seen-ids.txt
}
rest sketchfab sketchfab-seen-ids.txt.gz
rest civitai-images civitai-images-seen-ids.txt.gz
rest civitai civitai-seen-ids.txt.gz civitai-models-seen-ids.txt.gz
cp state/sketchfab-state.json $WS/sketchfab/state.json 2>/dev/null || true
cp state/civitai-images-state.json $WS/civitai-images/state.json 2>/dev/null || true
cp state/civitai-state.json $WS/civitai/state.json 2>/dev/null || true

HAUL=/tmp/ge/state/runner-hauls/$TS
mkdir -p $HAUL

# --- lanes (sketchfab FIRST: irreversible-loss site; bounded phases) ---
cd /tmp/ge
timeout 150 $PY scripts/sketchfab_models_walk.py 40 --state-dir $WS/sketchfab --fresh --stop-seen-pages 3 || echo "[runner] lane skfb-unfiltered rc=$?"
timeout 200 $PY scripts/sketchfab_models_walk.py 120 --state-dir $WS/sketchfab --downloadable true --fresh --stop-seen-pages 3 || echo "[runner] lane skfb-dl rc=$?"
timeout 60  $PY scripts/civitai_models_walk.py 12 --state-dir $WS/civitai --fresh --stop-seen-pages 3 || echo "[runner] lane cvt-models rc=$?"
timeout 300 $PY scripts/civitai_images_walk.py 900 --state-dir $WS/civitai-images --fresh --stop-seen-pages 2 || echo "[runner] lane cvt-images rc=$?"

# --- collect haul ---
n=0
for site in sketchfab civitai civitai-images; do
  d=$WS/$site/records
  [ -d "$d" ] || continue
  for f in $(ls -t $d 2>/dev/null | head -50); do
    [ -s "$d/$f" ] || continue
    mkdir -p $HAUL/$site
    cp "$d/$f" $HAUL/$site/
    n=$((n+1))
  done
done
# runner-namespace seen snapshots (union'd)
mkdir -p state/runner-seen
for site in sketchfab civitai-images civitai; do
  gzip -c $WS/$site/seen-ids.txt > state/runner-seen/$site-seen-ids.txt.gz
done
# chain ledger
mkdir -p state/runner
python3 - <<'EOF'
import json, datetime
try:
    ch = json.load(open('state/runner/chain.json'))
except Exception:
    ch = {"today": "", "count": 0}
today = datetime.datetime.utcnow().strftime("%Y-%m-%d")
if ch.get("today") != today:
    ch = {"today": today, "count": 0}
ch["count"] += 1
ch["last"] = datetime.datetime.utcnow().isoformat() + "Z"
ch["hook"] = bool(__import__('os').environ.get('HOOK_URL'))
json.dump(ch, open('state/runner/chain.json', 'w'), indent=1)
print("[runner] chain today:", ch["count"])
EOF

# --- commit + push (unique paths; pull --rebase; retry 3) ---
git add -A
git commit --quiet -m "netlify-runner $TS: refresh lanes (haul files + runner-seen + chain)" || echo "[runner] nothing to commit"
ok=0
for i in 1 2 3; do
  git pull --rebase --quiet origin main 2>/dev/null || true
  if git push --quiet "https://${GHPAT}@github.com/wesisad5/grind-engine.git" main; then ok=1; echo "[runner] PUSH OK"; break; fi
  echo "[runner] push retry $i"; sleep 10
done
[ $ok = 1 ] || echo "[runner] PUSH FAILED (haul rides next build? NO - lost; check creds)"

# --- self-chain (build-hook fires next draft build of `run`) ---
GEN=$(python3 -c "import json; print(json.load(open('state/runner/chain.json'))['count'])" 2>/dev/null || echo 999)
echo "[runner] gen=$GEN max=$GEN_MAX haul_files=$n"
if [ -n "$HOOK_URL" ] && [ "$GEN" -lt "$GEN_MAX" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -d '{}' "$HOOK_URL")
  echo "[runner] self-chain hook POST -> HTTP $code"
else
  echo "[runner] chain stopped (gen $GEN >= max $GEN_MAX or no hook)"
fi
mkdir -p dist && echo "grind-refresh-runner build $TS haul=$n gen=$GEN" > dist/index.html
echo "[runner] done ts=$TS"
