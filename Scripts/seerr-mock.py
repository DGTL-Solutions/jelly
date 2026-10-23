#!/usr/bin/env python3
"""A stand-in Jellyseerr for simulator tests of "Erkunden": discover rows, wishes and downloads that move.

Never test against a real Jellyseerr: its Jellyfin sign-in opens a Jellyfin session that is never closed and can use
up an account's session limit. Start this, then launch the Debug build with
  SIMCTL_CHILD_JELLY_SEERR_SERVER=http://127.0.0.1:15055 SIMCTL_CHILD_JELLY_SEERR_PASSWORD=x
Usage: seerr-mock.py [PORT]   (default 15055, clear of a real Jellyseerr on 5055; any name and password sign in)
"""
import json, re, sys, time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

START = time.time()
GB = 1024 ** 3

# tmdb id, type, title, year, poster, media status (2 pending, 3 processing, 4 partial, 5 available), downloads
TITLES = [
    (693134, "movie", "Dune: Part Two", "2024-02-27", "/1pdfLvkbY9ohJlCjQH2CZjjYVvJ.jpg", 3, "movie-running"),
    (100088, "tv", "The Last of Us", "2023-01-15", "/uKvVjHNqB5VmOrdxqAt2F7J78ED.jpg", 4, "season-pack"),
    (872585, "movie", "Oppenheimer", "2023-07-19", "/8Gxv8gSFCU0XGDykEGv7zR1n2ua.jpg", 3, "queued"),
    (27205, "movie", "Inception", "2010-07-15", "/oYuLEt3zVCKq57qu2F8dT7NIa6f.jpg", 3, "paused"),
    (157336, "movie", "Interstellar", "2014-11-05", "/gEU2QniE6E77NI6lCU6MxlNBvIx.jpg", 3, None),
    (1396, "tv", "Breaking Bad", "2008-01-20", "/ztkUQFLlC19CCMYHW9o1zWhJRNq.jpg", 5, None),
    (603, "movie", "Matrix", "1999-03-31", "/f89U3ADr1oiB1s9GkdPOEpXUk5H.jpg", None, None),
    (1399, "tv", "Game of Thrones", "2011-04-17", "/1XS1oqL89opfnbLl8WnZY1O1uJx.jpg", 2, None),
]


def iso(seconds_from_now):
    return (datetime.now(timezone.utc) + timedelta(seconds=seconds_from_now)).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def clock(seconds):
    seconds = int(max(seconds, 0))
    days, rest = divmod(seconds, 86400)
    text = f"{rest // 3600:02d}:{rest % 3600 // 60:02d}:{rest % 60:02d}"
    return f"{days}.{text}" if days else text


def item(size, done, status, rate, download_id, episode=None):
    """A queue entry; `done` is the share already there, `rate` bytes per second while downloading."""
    left = size * (1 - done)
    running = status == "downloading" and left > 0
    entry = {"mediaType": "tv" if episode else "movie", "externalId": 1, "size": size, "sizeLeft": round(left),
             "status": status if left > 0 or status != "downloading" else "completed",
             "timeLeft": clock(left / rate) if running else None,
             "estimatedCompletionTime": iso(left / rate) if running else None,
             "title": "release", "downloadId": download_id}
    if episode:
        entry["episode"] = {"seasonNumber": episode[0], "episodeNumber": episode[1], "absoluteEpisodeNumber": 0, "id": 1}
    return entry


def downloads(kind):
    elapsed = time.time() - START
    if kind == "movie-running":  # 35 % at start, done after about 15 minutes
        size = 18 * GB
        done = min(0.35 + elapsed * 0.65 / 900, 1)
        return [item(size, done, "downloading", size * 0.65 / 900, "dune")]
    if kind == "season-pack":  # three episodes in one pack, a fourth waits
        size = 6 * GB
        done = min(0.12 + elapsed / 1500, 1)
        pack = [item(size, done, "downloading", size / 1500, "tlou-s2", (2, n)) for n in (1, 2, 3)]
        return pack + [item(2 * GB, 0, "queued", 1, "tlou-s2e4", (2, 4))]
    if kind == "queued":
        return [item(9 * GB, 0, "queued", 1, "opp")]
    if kind == "paused":
        return [item(12 * GB, 0.6, "paused", 1, "inc")]
    return []


def media(entry):
    tmdb, kind, _, _, _, status, dl = entry
    if status is None:
        return None
    info = {"id": tmdb, "tmdbId": tmdb, "mediaType": kind, "status": status, "downloadStatus": downloads(dl), "downloadStatus4k": []}
    if kind == "tv":
        info["seasons"] = [{"seasonNumber": 1, "status": 5}, {"seasonNumber": 2, "status": 3}] if status == 4 else []
    if status == 5:
        info["jellyfinMediaId"] = "mock"
    return info


def title(entry):
    tmdb, kind, name, date, poster, _, _ = entry
    result = {"id": tmdb, "mediaType": kind, "posterPath": poster, "backdropPath": poster, "voteAverage": 8.1,
              "overview": "Ein Testtitel des Jellyseerr-Mocks.", "mediaInfo": media(entry)}
    result.update({"title": name, "releaseDate": date} if kind == "movie" else {"name": name, "firstAirDate": date})
    return result


def details(entry):
    result = title(entry)
    if entry[1] == "tv":
        result.update({"numberOfSeasons": 2, "seasons": [{"seasonNumber": n, "name": f"Staffel {n}", "episodeCount": 9} for n in (1, 2)]})
    else:
        result["runtime"] = 150
    return result


def request(entry, number):
    return {"id": number, "status": 2 if entry[5] in (3, 4, 5) else 1, "media": media(entry)}


class Handler(BaseHTTPRequestHandler):
    def reply(self, body, status=200, headers=()):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path.startswith("/api/v1/auth/"):
            return self.reply({"id": 1, "displayName": "Test"}, headers=[("Set-Cookie", "connect.sid=mock; Path=/; HttpOnly")])
        if self.path.startswith("/api/v1/request"):
            return self.reply({"id": 99, "status": 2})
        self.reply({"message": "not mocked"}, 404)

    def do_GET(self):
        path, _, query = self.path.partition("?")
        path = path.removeprefix("/api/v1/")
        if path == "status":
            return self.reply({"version": "2.7.3-mock"})
        if path == "settings/public":
            return self.reply({"applicationTitle": "Jellyseerr", "localLogin": True, "mediaServerLogin": True, "mediaServerType": 2})
        if path == "auth/me":
            return self.reply({"id": 1, "displayName": "Test"})
        if path.startswith("discover/") or path == "search":
            kinds = {"discover/movies": "movie", "discover/movies/upcoming": "movie", "discover/tv": "tv", "discover/tv/upcoming": "tv"}
            wanted = kinds.get(path)
            return self.reply({"results": [title(e) for e in TITLES if wanted in (None, e[1])]})
        if path == "request":
            if "filter=processing" in query:
                entries = [e for e in TITLES if e[5] in (3, 4)]
            else:
                entries = [e for e in TITLES if e[5] is not None]
            return self.reply({"results": [request(e, n) for n, e in enumerate(entries, 1)]})
        match = re.fullmatch(r"(movie|tv)/(\d+)", path)
        if match:
            entry = next((e for e in TITLES if e[0] == int(match[2]) and e[1] == match[1]), None)
            return self.reply(details(entry)) if entry else self.reply({"message": "not found"}, 404)
        self.reply({"message": "not mocked"}, 404)

    def log_message(self, format, *args):
        sys.stderr.write("seerr-mock " + format % args + "\n")


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 15055
    print(f"Jellyseerr mock on http://127.0.0.1:{port}")
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
