"""Audiobookshelf API backend for the Omarchy plugin.

Talks HTTP to a self-hosted Audiobookshelf server. No third-party deps —
stdlib urllib only, mirroring omarchy-podcasts' scripts/podcasts.py.
"""
import json
import os
import shutil
import subprocess
from html.parser import HTMLParser
from urllib.parse import quote, urlsplit
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError


class AbsAuthError(Exception):
    """Raised when login fails (bad credentials, unreachable server, etc.)."""


def login(base_url: str, username: str, password: str) -> dict:
    """POST /login, return the parsed JSON response body.

    Raises AbsAuthError on any failure (bad creds, network error, bad JSON).
    """
    url = base_url.rstrip("/") + "/login"
    body = json.dumps({"username": username, "password": password}).encode("utf-8")
    request = Request(
        url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urlopen(request, timeout=10) as response:
            return json.loads(response.read().decode("utf-8"))
    except HTTPError as exc:
        raise AbsAuthError(f"login rejected: HTTP {exc.code}") from exc
    except URLError as exc:
        raise AbsAuthError(f"could not reach server: {exc.reason}") from exc
    except json.JSONDecodeError as exc:
        raise AbsAuthError("server returned invalid JSON") from exc


def _authed_get(base_url: str, token: str, path: str) -> dict:
    """GET an ABS API path with a bearer token, return parsed JSON."""
    url = base_url.rstrip("/") + path
    request = Request(url, headers={"Authorization": f"Bearer {token}"}, method="GET")
    try:
        with urlopen(request, timeout=10) as response:
            return json.loads(response.read().decode("utf-8"))
    except HTTPError as exc:
        raise AbsAuthError(f"request to {path} failed: HTTP {exc.code}") from exc
    except URLError as exc:
        raise AbsAuthError(f"could not reach server: {exc.reason}") from exc


def list_library_items(base_url: str, token: str, library_id: str) -> list:
    """GET /api/libraries/<id>/items, return the results list (books+podcasts)."""
    data = _authed_get(base_url, token, f"/api/libraries/{library_id}/items")
    return data.get("results", [])


def list_libraries(base_url: str, token: str) -> list:
    """GET /api/libraries -> [{id, name, mediaType}] ("book" or "podcast")."""
    data = _authed_get(base_url, token, "/api/libraries")
    return [{"id": lib.get("id"), "name": lib.get("name") or "",
             "mediaType": lib.get("mediaType") or "book"}
            for lib in data.get("libraries") or []]


def pick_libraries(libraries: list, book_id: str = "", podcast_id: str = "") -> tuple:
    """Choose which book and podcast library to use. An explicit id wins if it
    still exists; otherwise the first library of that type; "" when the server
    has none of that type (books-only or podcasts-only servers)."""
    def choose(media_type, wanted):
        ids = [lib["id"] for lib in libraries if lib["mediaType"] == media_type]
        if wanted and wanted in ids:
            return wanted
        return ids[0] if ids else ""
    return choose("book", book_id), choose("podcast", podcast_id)


def list_all_items(base_url: str, token: str, library_id: str, podcast_library_id: str) -> list:
    """Books and podcasts live in two separate ABS libraries (config.json's
    libraryId/podcastLibraryId) — the library window needs both merged into
    one browsable list, filtered client-side by mediaType instead of two
    parallel fetch paths."""
    items = []
    for lib in (library_id, podcast_library_id):
        if lib:  # a server may have only one of the two library types
            items += list_library_items(base_url, token, lib)
    return items


class _TextExtractor(HTMLParser):
    """Collects visible text from an HTML fragment, turning block tags into
    line breaks."""
    _BLOCK = {"p", "br", "div", "li", "ul", "ol", "h1", "h2", "h3", "h4", "tr"}

    def __init__(self):
        super().__init__()
        self.parts = []

    def handle_starttag(self, tag, attrs):
        if tag in self._BLOCK:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in self._BLOCK:
            self.parts.append("\n")

    def handle_data(self, data):
        self.parts.append(data)


def html_to_text(fragment: str) -> str:
    """Episode show notes arrive as HTML. The panel renders plain text in the
    theme's own font and colors, so strip tags and collapse blank runs."""
    if not fragment:
        return ""
    parser = _TextExtractor()
    parser.feed(fragment)
    lines = [" ".join(line.split()) for line in "".join(parser.parts).splitlines()]
    text = "\n".join(lines)
    while "\n\n\n" in text:
        text = text.replace("\n\n\n", "\n\n")
    return text.strip()


def cover_url(base_url: str, token: str, item_id: str, width: int = 160) -> str:
    """Resized cover for the list thumbnails. GET requests accept the token as
    a query parameter (same approach as resolve_stream_url)."""
    return (base_url.rstrip("/") + f"/api/items/{item_id}/cover?width={width}&format=webp&token="
            + quote(token, safe=""))


def set_finished(base_url: str, token: str, progress_key: str, finished: bool) -> None:
    """PATCH /api/me/progress/<key> {isFinished}. <key> is an item id, or
    <itemId>/<episodeId> for a podcast episode."""
    body = json.dumps({"isFinished": finished}).encode("utf-8")
    url = base_url.rstrip("/") + f"/api/me/progress/{progress_key}"
    request = Request(
        url, data=body,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        method="PATCH",
    )
    try:
        with urlopen(request, timeout=10) as response:
            response.read()
    except HTTPError as exc:
        raise AbsAuthError(f"marking finished failed: HTTP {exc.code}") from exc
    except URLError as exc:
        raise AbsAuthError(f"could not reach server: {exc.reason}") from exc


def fetch_progress_index(base_url: str, token: str) -> dict:
    """GET /api/me once and index the user's mediaProgress by
    "<libraryItemId>" (books) or "<libraryItemId>/<episodeId>" (episodes),
    the same key shape /api/me/progress/<key> uses."""
    me = _authed_get(base_url, token, "/api/me")
    index = {}
    for entry in me.get("mediaProgress") or []:
        key = entry.get("libraryItemId")
        if not key:
            continue
        if entry.get("episodeId"):
            key += "/" + entry["episodeId"]
        # ABS's stored `progress` fraction doesn't reliably update on PATCH
        # (it mutates a JSON column in place), but currentTime always does, so
        # derive the fraction from position / duration when we can.
        current, duration = entry.get("currentTime") or 0, entry.get("duration") or 0
        fraction = min(1.0, current / duration) if duration > 0 else (entry.get("progress") or 0)
        index[key] = {"progress": fraction,
                      "isFinished": bool(entry.get("isFinished"))}
    return index


def annotate_items(items: list, progress_index: dict) -> list:
    """Attach what the library list shows: progress for books, and for podcasts
    an unplayedCount (episodes with no progress record at all, i.e. never
    started). Counting per item avoids fetching every podcast's episode list;
    stale records for deleted episodes can only undercount, so it's clamped."""
    started_per_item = {}
    for key in progress_index:
        if "/" in key:
            item_id = key.split("/", 1)[0]
            started_per_item[item_id] = started_per_item.get(item_id, 0) + 1
    for item in items:
        if item.get("mediaType") == "podcast":
            total = (item.get("media") or {}).get("numEpisodes") or 0
            item["unplayedCount"] = max(0, total - started_per_item.get(item.get("id"), 0))
        else:
            item["userProgress"] = progress_index.get(item.get("id"))
    return items


def list_episodes(base_url: str, token: str, item_id: str, progress_index: dict = None) -> list:
    """GET /api/items/<id>?expanded=1 for a podcast and return its episodes,
    newest first, trimmed to what the panel's episode list needs. Library-list
    responses only carry numEpisodes, not the episodes themselves."""
    data = _authed_get(base_url, token, f"/api/items/{item_id}?expanded=1")
    episodes = (data.get("media") or {}).get("episodes") or []
    trimmed = [{
        "id": ep.get("id"),
        "title": ep.get("title") or "Untitled episode",
        "publishedAt": ep.get("publishedAt") or 0,
        "duration": ((ep.get("audioFile") or {}).get("duration")) or ep.get("duration") or 0,
        "description": html_to_text(ep.get("description") or ""),
    } for ep in episodes]
    if progress_index is not None:
        for ep in trimmed:
            ep["userProgress"] = progress_index.get(f"{item_id}/{ep['id']}")
    trimmed.sort(key=lambda ep: ep["publishedAt"], reverse=True)
    return trimmed


def get_progress(base_url: str, token: str, item_id: str):
    """GET /api/me/progress/<id>. Returns None if the item has never been played."""
    url = base_url.rstrip("/") + f"/api/me/progress/{item_id}"
    request = Request(url, headers={"Authorization": f"Bearer {token}"}, method="GET")
    try:
        with urlopen(request, timeout=10) as response:
            return json.loads(response.read().decode("utf-8"))
    except HTTPError as exc:
        if exc.code == 404:
            return None
        raise AbsAuthError(f"progress fetch failed: HTTP {exc.code}") from exc
    except URLError as exc:
        raise AbsAuthError(f"could not reach server: {exc.reason}") from exc


def start_playback(base_url: str, token: str, item_id: str, episode_id: str = None) -> dict:
    """POST /api/items/<id>/play (or /play/<episode_id> for a podcast episode) to start
    a real ABS playback session.

    This is the officially documented "resolve what to actually stream" endpoint
    (api.audiobookshelf.org's "Play a Library Item or Podcast Episode") — its response
    carries authoritative duration/chapters/audioTracks for the item even when
    list_library_items()'s response was minified and lacked them. Used by the
    start-playback CLI command below, which is what LibraryWindow.qml's item-selection
    wiring (Task 16) actually calls.
    """
    path = f"/api/items/{item_id}/play"
    if episode_id:
        path += f"/{episode_id}"
    url = base_url.rstrip("/") + path
    body = json.dumps({
        "deviceInfo": {"clientVersion": "0.1.0"},
        "supportedMimeTypes": ["audio/mpeg", "audio/mp4", "audio/flac", "audio/ogg", "audio/aac"],
    }).encode("utf-8")
    request = Request(
        url, data=body,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urlopen(request, timeout=10) as response:
            return json.loads(response.read().decode("utf-8"))
    except HTTPError as exc:
        raise AbsAuthError(f"playback session failed: HTTP {exc.code}") from exc
    except URLError as exc:
        raise AbsAuthError(f"could not reach server: {exc.reason}") from exc


def resolve_stream_url(base_url: str, token: str, content_url: str) -> str:
    """Turn an ABS audioTrack.contentUrl (server-relative; the filename segment can
    contain spaces/special characters and is NOT percent-encoded in the API response —
    see the "Wizards First Rule 01.mp3" example in api.audiobookshelf.org's docs) into
    an absolute URL mpv can open directly.

    Auth is embedded as a `token` query parameter rather than an Authorization header:
    api.audiobookshelf.org's Authentication section explicitly documents this as
    supported for GET requests ("Optionally GET requests can use the API token like
    this: https://abs.example.com/api/items/<id>?token=<token>"). This avoids needing
    to plumb a custom Authorization header through mpv's IPC loadfile options (mpv does
    support per-load headers via a loadfile options string built from
    --http-header-fields, confirmed in mpv.io/manual/master's Network and JSON IPC
    sections, but the query-token route needs no such plumbing and is the simpler,
    equally-documented option).

    NEEDS LIVE VERIFICATION against a real Audiobookshelf server before this can be
    trusted — see task-16-report.md. The docs used to source this are explicitly
    flagged by Audiobookshelf itself as "out-of-date and no longer maintained".
    """
    parts = urlsplit(content_url)
    safe_path = "/".join(quote(segment) for segment in parts.path.split("/"))
    query = parts.query
    query = (query + "&" if query else "") + "token=" + quote(token, safe="")
    return base_url.rstrip("/") + safe_path + "?" + query


def update_progress(base_url: str, token: str, item_id: str, *,
                     current_time: float, duration: float, is_finished: bool = False) -> None:
    """PATCH /api/me/progress/<id> — sync playback position back to the server."""
    progress = 0.0 if duration <= 0 else max(0.0, min(1.0, current_time / duration))
    payload = {"currentTime": current_time, "duration": duration, "progress": progress}
    # Only send isFinished when finishing. ABS treats an explicit
    # isFinished: false on a finished item as "mark unfinished", which resets
    # its position to 0, and any isFinished key skips the progress update.
    if is_finished:
        payload["isFinished"] = True
    body = json.dumps(payload).encode("utf-8")
    url = base_url.rstrip("/") + f"/api/me/progress/{item_id}"
    request = Request(
        url, data=body,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        method="PATCH",
    )
    try:
        with urlopen(request, timeout=10) as response:
            response.read()
    except HTTPError as exc:
        raise AbsAuthError(f"progress update failed: HTTP {exc.code}") from exc
    except URLError as exc:
        raise AbsAuthError(f"could not reach server: {exc.reason}") from exc


_KEYRING_SERVICE = "abs-plugin"
_KEYRING_ACCOUNT = "token"


def store_token(token: str) -> None:
    """Store the ABS bearer token in the system keyring via secret-tool."""
    subprocess.run(
        ["secret-tool", "store", "--label=Audiobookshelf plugin token",
         "service", _KEYRING_SERVICE, "account", _KEYRING_ACCOUNT],
        input=token.encode("utf-8"),
        check=True,
    )


def load_token():
    """Load the ABS bearer token from the keyring. None if never stored."""
    result = subprocess.run(
        ["secret-tool", "lookup", "service", _KEYRING_SERVICE, "account", _KEYRING_ACCOUNT],
        stdout=subprocess.PIPE,
    )
    if result.returncode != 0:
        return None
    return result.stdout.decode("utf-8").strip() or None


def check_new_episodes(base_url: str, token: str, podcast_library_id: str,
                        seen_state_path: str) -> list:
    """Diff the current podcast library against a persisted seen-episode-id
    list. First run seeds the state file and returns [] (never notify on a
    library the plugin has never seen before). Failed fetches degrade to
    returning [] rather than raising — mirrors omarchy-podcasts' "failed
    feeds degrade to not-updating" behavior rather than retry-forever.
    """
    if not podcast_library_id:
        return []
    try:
        items = list_library_items(base_url, token, podcast_library_id)
    except AbsAuthError:
        return []

    current_ids = {item["id"] for item in items}

    first_run = not os.path.exists(seen_state_path)
    if first_run:
        seen_ids = set()
    else:
        with open(seen_state_path) as f:
            seen_ids = set(json.load(f))

    new_ids = set() if first_run else (current_ids - seen_ids)

    save_json_atomic(seen_state_path, sorted(current_ids))

    return [item for item in items if item["id"] in new_ids]


def save_json_atomic(path: str, obj) -> None:
    """Write JSON via a temp file + rename, so a crash mid-write never
    leaves a corrupt seen-state file (mirrors the reference's save_json)."""
    tmp_path = path + ".tmp"
    with open(tmp_path, "w") as f:
        json.dump(obj, f)
    os.replace(tmp_path, path)


def is_mpv_installed() -> bool:
    """Check whether mpv is on PATH — surfaced as a clear setup-wizard error
    rather than a confusing failure the first time the user hits Play."""
    return shutil.which("mpv") is not None


def is_plugin_configured() -> bool:
    """Whether config.json already exists — checked at plugin startup so the
    setup wizard doesn't reopen on every Quickshell restart when the user has
    already connected (login already wrote this file; see the login command
    below)."""
    config_path = os.path.expanduser("~/.config/audiobookshelf-plugin/config.json")
    return os.path.exists(config_path)


PENDING_PROGRESS_PATH = os.path.expanduser(
    "~/.local/state/audiobookshelf-plugin/pending-progress.json")


def _load_pending_progress() -> list:
    if not os.path.exists(PENDING_PROGRESS_PATH):
        return []
    with open(PENDING_PROGRESS_PATH) as f:
        return json.load(f)


def queue_pending_progress(item_id: str, current_time: float, duration: float,
                            is_finished: bool) -> None:
    """Cache a progress write that failed to send, so a network blip mid-playback
    never loses the user's actual position. Replaces any existing queued write for
    the same item — only the latest position for an item matters."""
    os.makedirs(os.path.dirname(PENDING_PROGRESS_PATH), exist_ok=True)
    pending = [p for p in _load_pending_progress() if p["item_id"] != item_id]
    pending.append({"item_id": item_id, "current_time": current_time,
                     "duration": duration, "is_finished": is_finished})
    save_json_atomic(PENDING_PROGRESS_PATH, pending)


def flush_pending_progress(base_url: str, token: str) -> int:
    """Retry every queued progress write. Returns how many succeeded. Entries that
    fail again stay queued for the next flush attempt (called opportunistically from
    the poll worker's timer tick, and once more at the start of a new play session)."""
    pending = _load_pending_progress()
    if not pending:
        return 0
    still_pending = []
    flushed = 0
    for entry in pending:
        try:
            update_progress(base_url, token, entry["item_id"],
                             current_time=entry["current_time"], duration=entry["duration"],
                             is_finished=entry["is_finished"])
            flushed += 1
        except AbsAuthError:
            still_pending.append(entry)
    save_json_atomic(PENDING_PROGRESS_PATH, still_pending)
    return flushed


def sync_progress(base_url: str, token: str, item_id: str, *,
                   current_time: float, duration: float, is_finished: bool = False) -> None:
    """What the popup actually calls every tick during playback — never raises,
    so one failed network call can't crash mid-playback. Falls back to the retry
    queue instead of losing the position."""
    try:
        update_progress(base_url, token, item_id, current_time=current_time,
                         duration=duration, is_finished=is_finished)
    except AbsAuthError:
        queue_pending_progress(item_id, current_time, duration, is_finished)


if __name__ == "__main__":
    import sys

    def _main():
        if len(sys.argv) < 2:
            print(json.dumps({"error": "no command given"}))
            sys.exit(1)
        command = sys.argv[1]

        # login runs before the token/config load below, since it's how the
        # token and config first get created. The password is deliberately
        # NOT a positional argv value (see security.md / store_token): argv
        # is readable by any local user via /proc/<pid>/cmdline for the life
        # of the process, so it comes from stdin instead, same as
        # store_token() pipes the token into secret-tool rather than passing
        # it as an argument.
        if command == "login":
            if len(sys.argv) < 4:
                print(json.dumps({
                    "error": "usage: login <base_url> <username> [library_id] "
                             "[podcast_library_id] (password on stdin)"}))
                sys.exit(1)
            base_url, username = sys.argv[2].rstrip("/"), sys.argv[3]
            library_id = sys.argv[4] if len(sys.argv) > 4 else ""
            podcast_library_id = sys.argv[5] if len(sys.argv) > 5 else ""
            # readline(), not read(): the QML side writes one newline-
            # terminated password per attempt on a persistent stdin channel
            # that is never closed (see SetupWizard.qml) — closing stdin
            # (via stdinEnabled = false) after the first attempt would
            # disable it permanently on that Process object per Quickshell's
            # docs, silently turning every retry's write() into a no-op and
            # every retry's password into "". read() would also just block
            # forever here since stdin is never closed.
            password = sys.stdin.readline().rstrip("\n")
            try:
                result = login(base_url, username, password)
            except AbsAuthError as exc:
                print(json.dumps({"error": str(exc)}))
                sys.exit(1)
            token = result["user"]["token"]
            try:
                libraries = list_libraries(base_url, token)
            except AbsAuthError as exc:
                print(json.dumps({"error": str(exc)}))
                sys.exit(1)
            library_id, podcast_library_id = pick_libraries(
                libraries, library_id, podcast_library_id)
            if not library_id and not podcast_library_id:
                print(json.dumps({"error": "this account can't see any book or podcast libraries"}))
                sys.exit(1)
            store_token(token)
            config_dir = os.path.expanduser("~/.config/audiobookshelf-plugin")
            os.makedirs(config_dir, exist_ok=True)
            save_json_atomic(os.path.join(config_dir, "config.json"), {
                "baseUrl": base_url,
                "libraryId": library_id,
                "podcastLibraryId": podcast_library_id,
            })
            print(json.dumps({"ok": True, "libraries": libraries,
                              "libraryId": library_id, "podcastLibraryId": podcast_library_id}))
            sys.exit(0)

        # check-mpv runs before the token/config load below too — the setup
        # wizard calls it ahead of login, when there's no token or config yet.
        if command == "check-mpv":
            print(json.dumps({"installed": is_mpv_installed()}))
            sys.exit(0)

        # check-configured runs before the token/config load below too —
        # BarWidget.qml calls it at plugin startup, before it knows whether
        # config.json (and therefore a token) exists at all.
        if command == "check-configured":
            configured = is_plugin_configured()
            cfg = {}
            if configured:
                try:
                    with open(os.path.expanduser("~/.config/audiobookshelf-plugin/config.json")) as f:
                        cfg = json.load(f)
                except (OSError, ValueError):
                    pass
            print(json.dumps({"configured": configured,
                              "baseUrl": cfg.get("baseUrl", "").rstrip("/"),
                              "libraryId": cfg.get("libraryId", ""),
                              "podcastLibraryId": cfg.get("podcastLibraryId", "")}))
            sys.exit(0)

        token = load_token()
        if token is None:
            print(json.dumps({"error": "not logged in"}))
            sys.exit(1)
        # base_url and library_id come from plugin config, written by the
        # login command above (Task 13's setup wizard).
        config_path = os.path.expanduser("~/.config/audiobookshelf-plugin/config.json")
        with open(config_path) as f:
            config = json.load(f)
        base_url = config["baseUrl"]
        library_id = config["libraryId"]

        if command == "list-libraries":
            try:
                libraries = list_libraries(base_url, token)
            except AbsAuthError as exc:
                print(json.dumps({"error": str(exc)}))
                sys.exit(1)
            print(json.dumps({"libraries": libraries, "libraryId": library_id,
                              "podcastLibraryId": config.get("podcastLibraryId", "")}))
            sys.exit(0)
        if command == "set-libraries":
            config["libraryId"] = sys.argv[2] if len(sys.argv) > 2 else ""
            config["podcastLibraryId"] = sys.argv[3] if len(sys.argv) > 3 else ""
            save_json_atomic(config_path, config)
            print(json.dumps({"ok": True}))
            sys.exit(0)

        if command == "list-items":
            items = list_all_items(base_url, token, library_id, config.get("podcastLibraryId", ""))
            try:
                annotate_items(items, fetch_progress_index(base_url, token))
            except AbsAuthError:
                pass  # the list is still useful without played/unplayed markers
            for item in items:
                if (item.get("media") or {}).get("coverPath"):
                    item["coverUrl"] = cover_url(base_url, token, item["id"])
            print(json.dumps(items))
        elif command == "set-finished":
            try:
                set_finished(base_url, token, sys.argv[2], sys.argv[3] == "true")
            except AbsAuthError as exc:
                print(json.dumps({"error": str(exc)}))
                sys.exit(1)
            print(json.dumps({"ok": True, "key": sys.argv[2], "finished": sys.argv[3] == "true"}))
        elif command == "list-episodes":
            try:
                try:
                    index = fetch_progress_index(base_url, token)
                except AbsAuthError:
                    index = None
                print(json.dumps(list_episodes(base_url, token, sys.argv[2], index)))
            except AbsAuthError as exc:
                print(json.dumps({"error": str(exc)}))
                sys.exit(1)
        elif command == "poll":
            state_path = os.path.expanduser(
                "~/.config/audiobookshelf-plugin/seen-episodes.json")
            new_eps = check_new_episodes(
                base_url, token, config.get("podcastLibraryId", ""), state_path)
            print(json.dumps(new_eps))
        elif command == "get-progress":
            item_id = sys.argv[2]
            try:
                progress = get_progress(base_url, token, item_id)
            except AbsAuthError as exc:
                print(json.dumps({"error": str(exc)}))
                sys.exit(1)
            # Echo the requested item_id back explicitly: get_progress()'s own
            # response body doesn't reliably carry it (it can be None, and the
            # real ABS response shape isn't guaranteed to include libraryItemId
            # the way the /play session response does), so the QML caller has
            # nothing else to compare against to detect a stale response landing
            # after the user has already selected a different item.
            print(json.dumps({"itemId": item_id, "progress": progress}))
        elif command == "start-playback":
            item_id = sys.argv[2]
            episode_id = sys.argv[3] if len(sys.argv) > 3 else None
            try:
                session = start_playback(base_url, token, item_id, episode_id)
            except AbsAuthError as exc:
                print(json.dumps({"error": str(exc)}))
                sys.exit(1)
            tracks = session.get("audioTracks") or []
            session["streamUrl"] = (
                resolve_stream_url(base_url, token, tracks[0]["contentUrl"]) if tracks else None)
            print(json.dumps(session))
        elif command == "sync-progress":
            item_id, current_time, duration, is_finished = sys.argv[2], float(sys.argv[3]), \
                float(sys.argv[4]), sys.argv[5] == "true"
            sync_progress(base_url, token, item_id, current_time=current_time,
                           duration=duration, is_finished=is_finished)
            print(json.dumps({"ok": True}))
        elif command == "flush-pending":
            flushed = flush_pending_progress(base_url, token)
            print(json.dumps({"flushed": flushed}))
        else:
            print(json.dumps({"error": f"unknown command {command}"}))
            sys.exit(1)

    _main()
