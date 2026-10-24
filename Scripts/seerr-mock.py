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

# The public demo server's own films and series (public domain or Creative Commons), so screenshots show nothing
# we have no rights to. tmdb id, type, title, date, poster, media status (2 pending, 3 processing, 4 partial,
# 5 available), downloads
TITLES = [
    (10331, "movie", "Night of the Living Dead", "1968-10-04", "/rb2NWyb008u1EcKCOyXs2Nmj0ra.jpg", 3, "movie-running"),
    (33050, "tv", "Pioneer One", "2010-06-16", "/p53wbsukyhJ8TieisoeU1zZr9iA.jpg", 4, "season-pack"),
    (5698, "movie", "The Great Train Robbery", "1903-12-07", "/vEYr1sJR1dOFGXwXawpBN6hDRGF.jpg", 3, "queued"),
    (225117, "movie", "King Lear", "1953-10-18", "/gSyCFr1mC6xdA78k8TSTVDtNhtv.jpg", 3, "paused"),
    (18783, "movie", "Sahara", "1943-11-11", "/roVIPqVLMdvs7uOcqDuwO891t8s.jpg", 3, None),
    (138, "movie", "Dracula", "1931-02-12", "/ueVSPt7vAba0XScHWTDWS5tNxYX.jpg", 5, None),
    (23033, "movie", "Jungle Book", "1942-04-03", "/zYkffyYCFO1Li1f20MyaAYUaYC4.jpg", None, None),
    (406956, "movie", "Caminandes: Llamigos", "2016-09-30", "/753kJbZ5iS7DUomTKX9qF5Cs5NY.jpg", 2, None),
    (5926, "movie", "The Great St. Louis Bank Robbery", "1959-06-01", "/zodT2zxrTpCTWZp1jrz2xNZhSq7.jpg", None, None),
    (253774, "movie", "Caminandes: Gran Dillama", "2013-11-22", "/7YtEiEzRBVCr8Sbgo1kVsr3OCMk.jpg", None, None),
]
BACKDROPS = {10331: "/duPDqFFRkwKcGfVibBvtVKA7VNh.jpg", 138: "/p4WwQJmJzVHywWWFoHRHCAdZ8wa.jpg", 23033: "/iSqKGCO5W2vIcwHfJXIrkTEtAFV.jpg"}
VOTES = {10331: 7.5, 33050: 6.9, 5698: 6.9, 225117: 6.2, 18783: 7.1, 138: 7.3, 23033: 6.6, 406956: 7.6, 5926: 6.1, 253774: 6.8}
OVERVIEWS = {
    10331: "A group of strangers barricade themselves in a farmhouse as the recently dead rise and close in.",
    33050: "An object falls from the sky over Canada, and two agents follow its trail to a stranger claiming to come from space.",
    5698: "A gang of bandits holds up a steam train and flees on horseback, with a posse close behind.",
    225117: "Orson Welles plays the ageing king who divides his realm between his daughters, with tragic consequences.",
    18783: "A tank crew and a band of stragglers hold a desert well against a German battalion.",
    138: "Count Dracula leaves Transylvania for London, where he sets his sights on Mina Seward.",
    23033: "Raised by wolves, Mowgli returns to his village and must choose between the jungle and the people.",
    406956: "Koro the llama and a penguin compete for the last berry on a windswept Patagonian plain.",
    5926: "Career criminals and a local youth carefully plan and rehearse the robbery of a Missouri bank.",
    253774: "Koro the llama tries every trick to reach the greener grass behind an electric fence.",
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
