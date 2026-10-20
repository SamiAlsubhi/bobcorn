#!/usr/bin/env python3
"""Builds docs/api: an example catalog API of public-domain films and TV from
the Internet Archive, served by GitHub Pages at
https://samialsubhi.github.io/bobcorn/api.

Pages serves static files, so each endpoint is a file: /movies/1, /shows/1,
/movie/<imdb_id> and /show/<imdb_id>. The sort, genre and keyword parameters
are ignored. Every title points at the Archive's own .torrent, which carries
the Archive's servers as web seeds, so it streams without other peers.

    python3 scripts/make-example-source.py
"""
import json
import os
import re
import shutil
import sys
import time
import urllib.parse
import urllib.request

FILMS = [
    ("Night of the Living Dead", 1968), ("His Girl Friday", 1940), ("Charade", 1963), ("The General", 1926),
    ("Nosferatu", 1922), ("Metropolis", 1927), ("The Kid", 1921), ("Detour", 1945), ("D.O.A.", 1949),
    ("The Little Shop of Horrors", 1960), ("Plan 9 from Outer Space", 1957), ("House on Haunted Hill", 1959),
    ("Carnival of Souls", 1962), ("The Last Man on Earth", 1964), ("Royal Wedding", 1951), ("McLintock!", 1963),
    ("Meet John Doe", 1941), ("The Stranger", 1946), ("Scarlet Street", 1945), ("Nothing Sacred", 1937),
    ("The Hitch-Hiker", 1953), ("Sita Sings the Blues", 2008), ("Jungle Book", 1942), ("Things to Come", 1936),
    ("The Phantom of the Opera", 1925), ("Sherlock Jr.", 1924), ("Safety Last!", 1923),
]
# Bonanza's public-domain episodes, all in one Archive item.
SHOW = {"title": "Bonanza", "year": 1959, "item": "Bonanza_pd"}

# Uploads of commercial discs, whatever their label says.
RIP = re.compile(r"bdrip|blu-?ray|x26[45]|hevc|dts|1080p|2160p|4k|remux", re.I)
OUT = os.path.join(os.path.dirname(__file__), "..", "docs", "api")
AGENT = {"User-Agent": "Bobcorn example source builder"}


def get(url):
    for attempt in range(3):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=AGENT), timeout=30) as r:
                return json.load(r)
        except Exception:
            if attempt == 2:
                raise
            time.sleep(2)


def archive_search(q, rows=10):
    url = "https://archive.org/advancedsearch.php?" + urllib.parse.urlencode(
        [("q", q), ("rows", rows), ("output", "json"), ("sort[]", "downloads desc")]
        + [("fl[]", f) for f in ["identifier", "title", "year", "avg_rating", "num_reviews", "description", "subject"]])
    return get(url)["response"]["docs"]


def one(v):
    return v[0] if isinstance(v, list) else v


def imdb_id(title, year):
    """The IMDb ID from IMDb's search suggestions: the feature with this title
    and year."""
    slug = re.sub(r"[^a-z0-9 ]", "", title.lower()).strip()
    data = get(f"https://v2.sg.media-imdb.com/suggestion/{slug[0]}/{urllib.parse.quote(slug)}.json")
    want = re.sub(r"[^a-z0-9]", "", title.lower())
    for d in data.get("d", []):
        if d.get("id", "").startswith("tt") and re.sub(r"[^a-z0-9]", "", d.get("l", "").lower()) == want and d.get("y") == year:
            return d["id"]
    return None


def summary(text):
    """The first two sentences of an Archive description, without its HTML."""
    text = re.sub(r"<[^>]+>", " ", text or "")
    text = re.sub(r"\s+", " ", text).strip()
    sentences = re.split(r"(?<=[.!?])\s+", text)
    return " ".join(sentences[:2])[:400]


def torrent(item, quality="480p"):
    return {quality: {"url": f"https://archive.org/download/{item}/{item}_archive.torrent"}}


def write(path, data):
    path = os.path.join(OUT, path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, separators=(",", ":"))


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    movies = []
    for title, year in FILMS:
        words = " AND ".join(re.sub(r"[^A-Za-z0-9 ]", " ", title).split())
        docs = archive_search(f"collection:feature_films AND mediatype:movies AND title:({words}) AND licenseurl:*publicdomain*", 25)
        # Only a copy the Archive marks public domain and titles as this film,
        # the most watched one, from the right year when the Archive says.
        want = re.sub(r"[^a-z0-9]", "", title.lower())
        named = [d for d in docs if re.sub(r"[^a-z0-9]", "", str(one(d.get("title")) or "").lower()).startswith(want)
                 and str(one(d.get("year")) or year) == str(year) and not RIP.search(d["identifier"])]
        doc = (named or [None])[0]
        imdb = imdb_id(title, year)
        if not doc or not imdb:
            print(f"skipped {title} ({year}): {'no public-domain Archive copy' if not doc else 'no IMDb match'}", file=sys.stderr)
            continue
        item = doc["identifier"]
        rating = float(doc.get("avg_rating") or 0)
        movie = {
            "_id": imdb, "imdb_id": imdb, "title": title, "year": str(year),
            "synopsis": summary(one(doc.get("description"))),
            "rating": {"percentage": round(rating * 20), "votes": int(doc.get("num_reviews") or 0)} if rating else {},
            "images": {"poster": f"https://archive.org/services/img/{item}", "fanart": f"https://archive.org/services/img/{item}"},
            "genres": [], "torrents": {"en": torrent(item)},
        }
        movies.append(movie)
        write(f"movie/{imdb}", movie)
        print(f"{title} ({year}): {imdb}, archive.org/details/{item} \"{one(doc.get('title'))}\"")

    shows = []
    show_imdb = imdb_id(SHOW["title"], SHOW["year"])
    meta = get(f"https://archive.org/metadata/{SHOW['item']}")
    episodes = []
    for f in meta.get("files", []):
        m = re.search(r"[sS](\d+)\s*[eE](\d+)", f["name"])
        if m and f["name"].lower().endswith(".mp4"):
            episodes.append({"season": int(m.group(1)), "episode": int(m.group(2)), "title": "", "overview": "",
                             "first_aired": 0, "torrents": torrent(SHOW["item"])})
    episodes.sort(key=lambda e: (e["season"], e["episode"]))
    if show_imdb and episodes:
        show = {
            "_id": show_imdb, "imdb_id": show_imdb, "title": SHOW["title"], "year": str(SHOW["year"]),
            "num_seasons": len({e["season"] for e in episodes}),
            "synopsis": summary(one(meta.get("metadata", {}).get("description"))),
            "images": {"poster": f"https://archive.org/services/img/{SHOW['item']}"},
            "genres": ["western"], "rating": {},
        }
        shows.append(show)
        write(f"show/{show_imdb}", dict(show, episodes=episodes))
        print(f"{SHOW['title']}: {show_imdb}, {len(episodes)} episodes")

    write("movies/1", movies)
    write("shows/1", shows)
    print(f"wrote {len(movies)} films and {len(shows)} shows to docs/api", file=sys.stderr)


if __name__ == "__main__":
    main()
