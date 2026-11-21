#!/usr/bin/env python3
"""civitai images metadata walk — harvest Phase B enumerator.

Walks GET https://civitai.com/api/v1/images?limit=100&sort=<sort>&cursor=<c>
cursor-paginated, resumable via state.json, seen-ids dedup persisted per page,
records -> run jsonl. Sibling of civitai_models_walk.py (Phase A, completed
2026-11-10 with 385,315 models / 0 err).

Laws honored: foreground bounded process (one Bash call = one leg), ~1 req/s
anti-ban envelope, err>20 -> stop, records stay in workspace.

Usage:
  python3 civitai_images_walk.py <pages> [--state-dir DIR] [--sort Newest]
                                 [--fresh] [--stop-seen-pages N]
  (run again to resume from saved cursor; --fresh = start from feed top
   [refresh mode], --stop-seen-pages N = stop after N consecutive fully-seen
   pages [window edge reached])
Exit: 0 ok | 11 repeated HTTP failures | 12 err>20 | 2 bad args
"""
import argparse, json, os, random, sys, time, urllib.parse, urllib.request
from datetime import datetime, timezone

API = "https://civitai.com/api/v1/images"
DEFAULT_STATE_DIR = "/tmp/my-project/s32-ws/meshenum-fresh/scrapes/civitai-images"
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (grind-engine research walker)"
SLEEP_RANGE = (1.0, 1.5)   # anti-ban envelope (~0.8 req/s effective)
HTTP_RETRIES = 2
ERR_LIMIT = 20

def now_utc():
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")

def load_state(d):
    p = os.path.join(d, "state.json")
    if os.path.exists(p):
        try:
            return json.load(open(p))
        except json.JSONDecodeError:
            print(f"[civitai-img-walk] WARN corrupt state.json, starting fresh")
    return {"cursor": None, "pages_done": 0, "records_total": 0, "dups_total": 0,
            "errors_total": 0, "sort": None, "last_utc": None, "watermark": None}

def save_state(d, st):
    st["last_utc"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    tmp = os.path.join(d, "state.json.tmp")
    import time as _t
    with open(tmp, "w") as f:          # explicit close before rename (PolarFS-safe)
        json.dump(st, f, indent=1)
    for _i in range(3):                # transient rename hiccups observed 2026-11-21
        try:
            os.replace(tmp, os.path.join(d, "state.json"))
            break
        except FileNotFoundError:
            _t.sleep(0.05 * (_i + 1))

def load_seen(d):
    p = os.path.join(d, "seen-ids.txt")
    seen = set()
    if os.path.exists(p):
        with open(p) as f:
            for line in f:
                line = line.strip()
                if line:
                    seen.add(line)
    return seen, p

def fetch(url):
    """One API GET with retry/backoff. Returns payload bytes or raises."""
    last_exc = None
    for attempt in range(HTTP_RETRIES + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            last_exc = e
            if e.code in (429, 500, 502, 503, 504) and attempt < HTTP_RETRIES:
                time.sleep(15 * (attempt + 1))
                continue
            raise
        except Exception as e:  # network flap
            last_exc = e
            if attempt < HTTP_RETRIES:
                time.sleep(10)
                continue
            raise
    raise last_exc

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pages", type=int)
    ap.add_argument("--state-dir", default=DEFAULT_STATE_DIR)
    ap.add_argument("--sort", default=None, choices=["Newest", "Oldest", "Most Reactions", "Most Comments"])
    ap.add_argument("--limit", type=int, default=100)
    ap.add_argument("--fresh", action="store_true",
                    help="refresh mode: ignore saved cursor, walk from feed top")
    ap.add_argument("--stop-seen-pages", type=int, default=0,
                    help="stop after N consecutive fully-seen pages (0 = never)")
    args = ap.parse_args()

    d = args.state_dir
    os.makedirs(os.path.join(d, "records"), exist_ok=True)
    st = load_state(d)
    if args.fresh:
        st["cursor"] = None
    if args.sort:
        st["sort"] = args.sort
    if not st["sort"]:
        st["sort"] = "Newest"
    seen, seen_path = load_seen(d)
    run_path = os.path.join(d, "records", f"run-{now_utc()}.jsonl")

    print(f"[civitai-img-walk] start pages={args.pages} sort={st['sort']} "
          f"resume_cursor={bool(st['cursor'])} seen={len(seen)} run={os.path.basename(run_path)}")
    errors = 0
    new_total = 0
    dup_total = 0
    seen_streak = 0

    for page in range(1, args.pages + 1):
        params = f"limit={args.limit}&sort={urllib.parse.quote(st['sort'])}"
        if st["cursor"]:
            params += f"&cursor={urllib.parse.quote(st['cursor'], safe='')}"
        url = f"{API}?{params}"
        t0 = time.time()
        try:
            raw = fetch(url)
        except Exception as e:
            errors += 1
            st["errors_total"] = st.get("errors_total", 0) + 1
            print(f"[civitai-img-walk] page {page} HTTP FAIL: {e}")
            if errors >= 3:
                save_state(d, st)
                print("[civitai-img-walk] rc=11 (repeated HTTP failure)")
                sys.exit(11)
            time.sleep(15)
            continue
        dt = time.time() - t0
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            errors += 1
            print(f"[civitai-img-walk] page {page} JSON decode fail ({len(raw)}b)")
            if errors >= 3:
                save_state(d, st)
                print("[civitai-img-walk] rc=11")
                sys.exit(11)
            continue
        items = data.get("items", [])
        meta = data.get("metadata", {})
        page_new_ids = []
        page_dup = 0
        with open(run_path, "a") as out:
            for it in items:
                iid = str(it.get("id", ""))
                if not iid:
                    continue
                if iid in seen:
                    page_dup += 1
                    continue
                seen.add(iid)
                page_new_ids.append(iid)
                out.write(json.dumps(it, ensure_ascii=False, separators=(",", ":")) + "\n")
        if page_new_ids:
            with open(seen_path, "a") as sf:
                sf.write("\n".join(page_new_ids) + "\n")
        new_total += len(page_new_ids)
        dup_total += page_dup
        st["pages_done"] += 1
        st["records_total"] = st.get("records_total", 0) + len(page_new_ids)
        st["dups_total"] = st.get("dups_total", 0) + page_dup
        st["cursor"] = meta.get("nextCursor")
        save_state(d, st)
        print(f"[civitai-img-walk] page {page}: {dt:.1f}s items={len(items)} new={len(page_new_ids)} "
              f"dup={page_dup} cursor={'yes' if st['cursor'] else 'END'} state.saved")
        if not st["cursor"]:
            print("[civitai-img-walk] feed exhausted (no nextCursor)")
            break
        if args.stop_seen_pages > 0 and items and page_dup == len(items):
            seen_streak += 1
            if seen_streak >= args.stop_seen_pages:
                print(f"[civitai-img-walk] window edge reached "
                      f"({seen_streak}x fully-seen pages) - refresh watermark")
                break
        else:
            seen_streak = 0
        if errors > ERR_LIMIT:
            save_state(d, st)
            print("[civitai-img-walk] rc=12 (err limit)")
            sys.exit(12)
        time.sleep(random.uniform(*SLEEP_RANGE))

    print(f"[civitai-img-walk] DONE pages={st['pages_done']} new_total={new_total} dup_total={dup_total} "
          f"errors={errors} records_file={run_path}")

if __name__ == "__main__":
    main()
