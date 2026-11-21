#!/usr/bin/env python3
"""sketchfab models metadata walk — harvest-initial enumerator (Phase A).

Walks GET https://api.sketchfab.com/v3/search?type=models&archived=false
        &sort_by=-publishedAt&count=24
Cursor = the `next` URL returned per page (opaque, stored verbatim in
state.json). Resumable, seen-ids dedup, records -> run jsonl.

REQUIRES curl_cffi with browser-TLS impersonation: sketchfab sits behind a
fingerprinting CDN that kills raw urllib/curl ClientHello (validated
2026-11-10). Keep the ~1 req/s anti-ban envelope.

Feed is LIVE and huge (millions of models, ~2.7K/day): Phase A is
window-scoped (7-day sliding window ~800 pages at 24/page), NOT full-feed —
the walker stops at the page budget per leg; there is no near-term "feed
exhausted".

Usage:
  python3 sketchfab_models_walk.py <pages> [--state-dir DIR] [--fresh]
                                   [--stop-seen-pages N] [--published-at YYYY-MM-DD]
                                   [--downloadable {true,false}]
Exit: 0 ok | 11 repeated HTTP failures | 12 err>20 | 2 bad args

Lanes (each param change resets the cursor — cursors embed the filter
verbatim, so each lane is its own offset space): --published-at day-slices,
--downloadable true|false partition lanes. The downloadable lanes each carry
their OWN ~10K ES result window (validated 2026-11-10), extending total reach:
dl=true ~7.5 days deep, dl=false ~16 days (at ~1.97K/day, ~68% downloadable).
"""
import argparse, json, os, random, sys, time
from datetime import datetime, timezone

API = ("https://api.sketchfab.com/v3/search?type=models&archived=false"
       "&sort_by=-publishedAt&count=24")
# published_at=YYYY-MM-DD is an UNDOCUMENTED but validated day-filter: each
# day-slice carries its own ES result window (~10K cap is PER QUERY), so day
# slices (~113 pages at ~2.7K records/day) walk the full depth of any single
# day. This defeats the plain-walk depth cap (discovery 2026-11-10).
DEFAULT_STATE_DIR = "/tmp/my-project/s32-ws/meshenum-fresh/scrapes/sketchfab"
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
            print("[skfb-walk] WARN corrupt state.json, starting fresh")
    return {"cursor": None, "pages_done": 0, "records_total": 0, "dups_total": 0,
            "errors_total": 0, "last_utc": None}

def save_state(d, st):
    st["last_utc"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    tmp = os.path.join(d, "state.json.tmp")
    with open(tmp, "w") as f:          # explicit close before rename (PolarFS-safe)
        json.dump(st, f, indent=1)
    for i in range(3):                 # transient rename hiccups observed 2026-11-21
        try:
            os.replace(tmp, os.path.join(d, "state.json"))
            return
        except FileNotFoundError:
            time.sleep(0.05 * (i + 1))
    raise RuntimeError(f"save_state: replace failed after retries in {d}")

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
    """One API GET with retry/backoff via curl_cffi. Returns payload bytes or raises."""
    from curl_cffi import requests as cr
    last_exc = None
    for attempt in range(HTTP_RETRIES + 1):
        try:
            r = cr.get(url, impersonate="chrome", timeout=30)
            if r.status_code in (429, 500, 502, 503, 504) and attempt < HTTP_RETRIES:
                time.sleep(15 * (attempt + 1))
                continue
            if r.status_code != 200:
                raise RuntimeError(f"HTTP {r.status_code}")
            return r.content
        except Exception as e:
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
    ap.add_argument("--fresh", action="store_true",
                    help="refresh mode: ignore saved cursor, walk from feed top")
    ap.add_argument("--stop-seen-pages", type=int, default=0,
                    help="stop after N consecutive fully-seen pages (0 = never)")
    ap.add_argument("--published-at", default=None, metavar="YYYY-MM-DD",
                    help="day-slice mode: walk only models published this day")
    ap.add_argument("--downloadable", default=None, choices=("true", "false"),
                    help="partition lane: downloadable=true|false (own ES window)")
    args = ap.parse_args()

    d = args.state_dir
    os.makedirs(os.path.join(d, "records"), exist_ok=True)
    st = load_state(d)
    if args.fresh:
        st["cursor"] = None
    if (args.published_at, args.downloadable) != (st.get("published_at"), st.get("downloadable")):
        st["cursor"] = None            # lane switch -> cursor space restarts
        st["published_at"] = args.published_at
        st["downloadable"] = args.downloadable
    seen, seen_path = load_seen(d)
    run_path = os.path.join(d, "records", f"run-{now_utc()}.jsonl")

    print(f"[skfb-walk] start pages={args.pages} day={args.published_at or 'ALL'} "
          f"dl={args.downloadable or 'any'} resume_cursor={bool(st['cursor'])} "
          f"seen={len(seen)} run={os.path.basename(run_path)}")
    errors = 0
    new_total = 0
    dup_total = 0
    seen_streak = 0

    for page in range(1, args.pages + 1):
        if st["cursor"]:
            url = st["cursor"]          # lane cursors embed their filter verbatim
        else:
            url = API
            if args.published_at:
                url += f"&published_at={args.published_at}"
            if args.downloadable:
                url += f"&downloadable={args.downloadable}"
        t0 = time.time()
        try:
            raw = fetch(url)
        except Exception as e:
            errors += 1
            st["errors_total"] = st.get("errors_total", 0) + 1
            print(f"[skfb-walk] page {page} HTTP FAIL: {e}")
            if errors >= 3:
                save_state(d, st)
                print("[skfb-walk] rc=11 (repeated HTTP failure)")
                sys.exit(11)
            time.sleep(15)
            continue
        dt = time.time() - t0
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            errors += 1
            print(f"[skfb-walk] page {page} JSON decode fail ({len(raw)}b)")
            if errors >= 3:
                save_state(d, st)
                print("[skfb-walk] rc=11")
                sys.exit(11)
            continue
        items = data.get("results", [])
        page_new_ids = []
        page_dup = 0
        with open(run_path, "a") as out:
            for it in items:
                mid = str(it.get("uid", ""))
                if not mid:
                    continue
                if mid in seen:
                    page_dup += 1
                    continue
                seen.add(mid)
                page_new_ids.append(mid)
                out.write(json.dumps(it, ensure_ascii=False, separators=(",", ":")) + "\n")
        if page_new_ids:
            with open(seen_path, "a") as sf:
                sf.write("\n".join(page_new_ids) + "\n")
        new_total += len(page_new_ids)
        dup_total += page_dup
        st["pages_done"] += 1
        st["records_total"] = st.get("records_total", 0) + len(page_new_ids)
        st["dups_total"] = st.get("dups_total", 0) + page_dup
        st["cursor"] = data.get("next")
        save_state(d, st)
        print(f"[skfb-walk] page {page}: {dt:.1f}s items={len(items)} new={len(page_new_ids)} "
              f"dup={page_dup} next={'yes' if st['cursor'] else 'END'} state.saved")
        if not st["cursor"]:
            print("[skfb-walk] feed exhausted (no next) - unexpected for live feed; check sort")
            break
        if args.stop_seen_pages > 0 and items and page_dup == len(items):
            seen_streak += 1
            if seen_streak >= args.stop_seen_pages:
                print(f"[skfb-walk] watermark reached "
                      f"({seen_streak}x fully-seen pages) - refresh done")
                break
        else:
            seen_streak = 0
        if errors > ERR_LIMIT:
            save_state(d, st)
            print("[skfb-walk] rc=12 (err limit)")
            sys.exit(12)
        time.sleep(random.uniform(*SLEEP_RANGE))

    print(f"[skfb-walk] DONE pages={st['pages_done']} new_total={new_total} dup_total={dup_total} "
          f"errors={errors} records_file={run_path}")

if __name__ == "__main__":
    main()
