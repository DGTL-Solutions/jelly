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

# Blender Foundation's open movies (CC-BY, Spring public domain): colourful, free to show in App Store screenshots and the
# same titles as the screenshot library (see AppStore/README.md). tmdb id, type, title, date, poster, media status
# (2 pending, 3 processing, 4 partial, 5 available), downloads
TITLES = [
    (45745, "movie", "Sintel", "2010-09-27", "/l98Zns4oQe1BSvbF4hJ8oL6VSf0.jpg", 3, "movie-running"),
    (133701, "movie", "Tears of Steel", "2012-09-26", "/8qy3jRmaHR7f8VZh3iXCqCWfFsH.jpg", 3, "queued"),
    (9761, "movie", "Elephants Dream", "2006-03-24", "/9zROtU9TkpZQrOuEaMAp68FOWLK.jpg", 3, "paused"),
    (358332, "movie", "Cosmos Laundromat", "2015-08-10", "/5ZXi0oitpEgAdoJglFTc5SZF9nt.jpg", 3, None),
    (593048, "movie", "Spring", "2019-04-04", "/g5dSJtpoXYCSVx70srSAc3wqNFc.jpg", 3, None),
    (10378, "movie", "Big Buck Bunny", "2008-04-10", "/i9jJzvoXET4D9pOkoEwncSdNNER.jpg", 5, None),
    (253777, "movie", "Caminandes: Llama Drama", "2013-01-31", "/66VPke0YSiyfe97aobbcZ55ts56.jpg", 2, None),
    (253774, "movie", "Caminandes: Gran Dillama", "2013-11-22", "/7YtEiEzRBVCr8Sbgo1kVsr3OCMk.jpg", 2, None),
    (406956, "movie", "Caminandes: Llamigos", "2016-09-30", "/753kJbZ5iS7DUomTKX9qF5Cs5NY.jpg", None, None),
]
BACKDROPS = {}
VOTES = {45745: 7.5, 133701: 6.8, 9761: 6.0, 358332: 7.3, 593048: 7.6, 10378: 6.5, 253777: 7.2, 253774: 7.4, 406956: 7.6}
OVERVIEWS = {
    45745: "A wandering warrior finds an unlikely friend in a young dragon and sets out to bring it home.",
    133701: "A group of fighters in Amsterdam tries to save the world from a robot threat with one last experiment.",
    9761: "Two strangers explore a vast machine world where nothing is as it seems.",
    358332: "On a desolate island, a lonely sheep meets a salesman who offers him a lifetime of adventures.",
    593048: "A shepherd girl and her dog face ancient spirits in order to continue the cycle of life.",
    10378: "A gentle giant rabbit takes revenge on three bullying rodents after a day in the forest.",
    253777: "Koro the llama wants to get across the road, with a penguin as his only obstacle.",
    253774: "Koro the llama tries every trick to reach the greener grass behind an electric fence.",
    406956: "Koro the llama and a penguin compete for the last berry on a windswept Patagonian plain.",
}


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
        return [item(size, done, "downloading", size * 0.65 / 900, "living-dead")]
    if kind == "season-pack":  # two episodes in one pack, a third waits
        size = 6 * GB
        done = min(0.12 + elapsed / 1500, 1)
        pack = [item(size, done, "downloading", size / 1500, "pioneer-one-s1", (1, n)) for n in (4, 5)]
        return pack + [item(2 * GB, 0, "queued", 1, "pioneer-one-s1e6", (1, 6))]
    if kind == "queued":
        return [item(9 * GB, 0, "queued", 1, "great-train-robbery")]
    if kind == "paused":
        return [item(12 * GB, 0.6, "paused", 1, "king-lear")]
    return []


def media(entry):
    tmdb, kind, _, _, _, status, dl = entry
    if status is None:
        return None
    info = {"id": tmdb, "tmdbId": tmdb, "mediaType": kind, "status": status, "downloadStatus": downloads(dl), "downloadStatus4k": []}
    if kind == "tv":
        info["seasons"] = [{"seasonNumber": 1, "status": 4}] if status == 4 else []
    if status == 5:
        info["jellyfinMediaId"] = "mock"
    return info


def title(entry):
    tmdb, kind, name, date, poster, _, _ = entry
    result = {"id": tmdb, "mediaType": kind, "posterPath": poster, "backdropPath": BACKDROPS.get(tmdb, poster),
              "voteAverage": VOTES.get(tmdb, 7.0), "overview": OVERVIEWS.get(tmdb, ""), "mediaInfo": media(entry)}
    result.update({"title": name, "releaseDate": date} if kind == "movie" else {"name": name, "firstAirDate": date})
    return result


def details(entry):
    result = title(entry)
    if entry[1] == "tv":
        result.update({"numberOfSeasons": 1, "seasons": [{"seasonNumber": 1, "name": "Season 1", "episodeCount": 6}]})
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
