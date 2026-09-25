import json
import sys
from pathlib import Path
from unittest.mock import patch, MagicMock, call
from urllib.error import HTTPError

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import abs_backend  # noqa: E402


def test_login_success_returns_parsed_body():
    fake_response_body = json.dumps({
        "user": {
            "id": "jtc",
            "username": "testuser",
            "token": "fake-token-abc123",
            "mediaProgress": [],
        },
        "userDefaultLibraryId": "lib_main",
        "serverSettings": {"version": "2.2.5"},
    }).encode("utf-8")

    fake_resp = MagicMock()
    fake_resp.read.return_value = fake_response_body
    fake_resp.__enter__.return_value = fake_resp
    fake_resp.__exit__.return_value = False

    with patch("abs_backend.urlopen", return_value=fake_resp) as mock_open:
        result = abs_backend.login("http://localhost:13378", "testuser", "hunter2")

    assert result["user"]["token"] == "fake-token-abc123"
    assert result["userDefaultLibraryId"] == "lib_main"
    called_request = mock_open.call_args[0][0]
    assert called_request.full_url == "http://localhost:13378/login"
    sent_body = json.loads(called_request.data.decode("utf-8"))
    assert sent_body == {"username": "testuser", "password": "hunter2"}


def test_login_failure_raises_abs_auth_error():
    err = HTTPError(url="http://localhost:13378/login", code=401,
                     msg="Unauthorized", hdrs=None, fp=None)
    with patch("abs_backend.urlopen", side_effect=err):
        try:
            abs_backend.login("http://localhost:13378", "testuser", "wrong")
            assert False, "expected AbsAuthError"
        except abs_backend.AbsAuthError as e:
            assert "401" in str(e)


def test_list_library_items_returns_results_list():
    fake_body = json.dumps({
        "results": [
            {
                "id": "li_book1",
                "libraryId": "lib_main",
                "mediaType": "book",
                "media": {"metadata": {"title": "Neuromancer", "authorName": "William Gibson"}},
            },
            {
                "id": "li_pod1",
                "libraryId": "lib_main",
                "mediaType": "podcast",
                "media": {"metadata": {"title": "Some Podcast"}},
            },
        ],
        "total": 2,
    }).encode("utf-8")

    fake_resp = MagicMock()
    fake_resp.read.return_value = fake_body
    fake_resp.__enter__.return_value = fake_resp
    fake_resp.__exit__.return_value = False

    with patch("abs_backend.urlopen", return_value=fake_resp) as mock_open:
        items = abs_backend.list_library_items(
            "http://localhost:13378", "fake-token-abc123", "lib_main")

    assert len(items) == 2
    assert items[0]["mediaType"] == "book"
    assert items[1]["mediaType"] == "podcast"
    called_request = mock_open.call_args[0][0]
    assert called_request.full_url == "http://localhost:13378/api/libraries/lib_main/items"
    assert called_request.get_header("Authorization") == "Bearer fake-token-abc123"


def test_list_all_items_merges_books_and_podcast_libraries():
    # list_all_items() does `items += list_library_items(...)`, an in-place
    # extend — feeding the mock the same list objects used in the assertion
    # below would let that mutate the "expected" value out from under it, so
    # each side gets its own fresh literal.
    with patch(
        "abs_backend.list_library_items",
        side_effect=[
            [{"id": "li_book1", "mediaType": "book"}],
            [{"id": "li_pod1", "mediaType": "podcast"}],
        ],
    ) as mock_list:
        items = abs_backend.list_all_items(
            "http://localhost:13378", "fake-token-abc123", "lib_books", "lib_podcasts")

    assert items == [
        {"id": "li_book1", "mediaType": "book"},
        {"id": "li_pod1", "mediaType": "podcast"},
    ]
    assert mock_list.call_args_list == [
        call("http://localhost:13378", "fake-token-abc123", "lib_books"),
        call("http://localhost:13378", "fake-token-abc123", "lib_podcasts"),
    ]


def test_get_progress_returns_dict_when_present():
    fake_body = json.dumps({
        "id": "li_book1", "currentTime": 632.5, "duration": 1454.1,
        "progress": 0.435, "isFinished": False,
    }).encode("utf-8")
    fake_resp = MagicMock()
    fake_resp.read.return_value = fake_body
    fake_resp.__enter__.return_value = fake_resp
    fake_resp.__exit__.return_value = False

    with patch("abs_backend.urlopen", return_value=fake_resp):
        progress = abs_backend.get_progress(
            "http://localhost:13378", "fake-token-abc123", "li_book1")

    assert progress["currentTime"] == 632.5


def test_get_progress_returns_none_on_404():
    err = HTTPError(url="x", code=404, msg="Not Found", hdrs=None, fp=None)
    with patch("abs_backend.urlopen", side_effect=err):
        progress = abs_backend.get_progress(
            "http://localhost:13378", "fake-token-abc123", "li_never_played")
    assert progress is None


def test_start_playback_posts_to_play_endpoint_and_returns_session():
    fake_body = json.dumps({
        "id": "play_c786zm3qtjz6bd5q3n",
        "libraryItemId": "li_8gch9ve09orgn4fdz8",
        "duration": 33854.905,
        "chapters": [{"id": 0, "start": 0, "end": 100, "title": "Ch 1"}],
        "audioTracks": [
            {"index": 1, "contentUrl": "/s/item/li_8gch9ve09orgn4fdz8/Wizards First Rule 01.mp3",
             "mimeType": "audio/mpeg"},
        ],
    }).encode("utf-8")
    fake_resp = MagicMock()
    fake_resp.read.return_value = fake_body
    fake_resp.__enter__.return_value = fake_resp
    fake_resp.__exit__.return_value = False

    with patch("abs_backend.urlopen", return_value=fake_resp) as mock_open:
        session = abs_backend.start_playback(
            "http://localhost:13378", "fake-token-abc123", "li_8gch9ve09orgn4fdz8")

    assert session["libraryItemId"] == "li_8gch9ve09orgn4fdz8"
    called_request = mock_open.call_args[0][0]
    assert called_request.full_url == "http://localhost:13378/api/items/li_8gch9ve09orgn4fdz8/play"
    assert called_request.get_method() == "POST"
    assert called_request.get_header("Authorization") == "Bearer fake-token-abc123"
    sent = json.loads(called_request.data.decode("utf-8"))
    assert "supportedMimeTypes" in sent


def test_start_playback_with_episode_id_hits_episode_play_path():
    fake_resp = MagicMock()
    fake_resp.read.return_value = b"{}"
    fake_resp.__enter__.return_value = fake_resp
    fake_resp.__exit__.return_value = False

    with patch("abs_backend.urlopen", return_value=fake_resp) as mock_open:
        abs_backend.start_playback(
            "http://localhost:13378", "fake-token", "li_bufnnmp4y5o2gbbxfm",
            "ep_lh6ko39pumnrma3dhv")

    called_request = mock_open.call_args[0][0]
    assert called_request.full_url == (
        "http://localhost:13378/api/items/li_bufnnmp4y5o2gbbxfm/play/ep_lh6ko39pumnrma3dhv")


def test_start_playback_failure_raises_abs_auth_error():
    err = HTTPError(url="x", code=401, msg="Unauthorized", hdrs=None, fp=None)
    with patch("abs_backend.urlopen", side_effect=err):
        try:
            abs_backend.start_playback("http://localhost:13378", "fake-token", "li_x")
            assert False, "expected AbsAuthError"
        except abs_backend.AbsAuthError as e:
            assert "401" in str(e)


def test_resolve_stream_url_encodes_spaces_and_appends_token():
    url = abs_backend.resolve_stream_url(
        "http://localhost:13378", "fake-token-abc123",
        "/s/item/li_8gch9ve09orgn4fdz8/Terry Goodkind - SOT Bk01 - Wizards First Rule 01.mp3")

    assert url.startswith("http://localhost:13378/s/item/li_8gch9ve09orgn4fdz8/")
    assert " " not in url  # spaces must be percent-encoded for mpv/libcurl to fetch reliably
    assert url.endswith("?token=fake-token-abc123")


def test_resolve_stream_url_preserves_existing_query_string():
    url = abs_backend.resolve_stream_url(
        "http://localhost:13378", "fake-token", "/s/item/li_x/file.mp3?ino=123")
    assert "ino=123&token=fake-token" in url


def test_update_progress_sends_correct_body():
    fake_resp = MagicMock()
    fake_resp.read.return_value = b"{}"
    fake_resp.__enter__.return_value = fake_resp
    fake_resp.__exit__.return_value = False

    with patch("abs_backend.urlopen", return_value=fake_resp) as mock_open:
        abs_backend.update_progress(
            "http://localhost:13378", "fake-token-abc123", "li_book1",
            current_time=700.0, duration=1454.1, is_finished=False)

    called_request = mock_open.call_args[0][0]
    assert called_request.full_url == "http://localhost:13378/api/me/progress/li_book1"
    assert called_request.get_method() == "PATCH"
    sent = json.loads(called_request.data.decode("utf-8"))
    assert sent["currentTime"] == 700.0
    assert sent["duration"] == 1454.1
    # isFinished is omitted unless finishing: ABS treats isFinished: false as
    # "mark unfinished" (resets position) and skips the progress update.
    assert "isFinished" not in sent
    assert 0.0 <= sent["progress"] <= 1.0


def test_store_token_calls_secret_tool_store():
    with patch("abs_backend.subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        abs_backend.store_token("fake-token-abc123")

    args = mock_run.call_args[0][0]
    assert args[:2] == ["secret-tool", "store"]
    assert "service" in args and "abs-plugin" in args
    sent_input = mock_run.call_args[1]["input"]
    assert sent_input == b"fake-token-abc123"


def test_load_token_returns_stripped_output():
    completed = MagicMock(returncode=0, stdout=b"fake-token-abc123\n")
    with patch("abs_backend.subprocess.run", return_value=completed):
        token = abs_backend.load_token()
    assert token == "fake-token-abc123"


def test_load_token_returns_none_when_not_found():
    completed = MagicMock(returncode=1, stdout=b"")
    with patch("abs_backend.subprocess.run", return_value=completed):
        token = abs_backend.load_token()
    assert token is None


import tempfile
import os


def test_check_new_episodes_returns_empty_on_first_run_but_seeds_state():
    fake_items = [
        {"id": "ep1", "mediaType": "podcast", "media": {"metadata": {"title": "Ep 1"}}},
        {"id": "ep2", "mediaType": "podcast", "media": {"metadata": {"title": "Ep 2"}}},
    ]
    with tempfile.TemporaryDirectory() as tmp:
        state_path = os.path.join(tmp, "seen.json")
        with patch("abs_backend.list_library_items", return_value=fake_items):
            new_eps = abs_backend.check_new_episodes(
                "http://localhost:13378", "fake-token", "lib_pod", state_path)
        assert new_eps == []  # first run seeds state, doesn't notify on everything
        with open(state_path) as f:
            seen = json.load(f)
        assert set(seen) == {"ep1", "ep2"}


def test_check_new_episodes_returns_only_genuinely_new_items():
    with tempfile.TemporaryDirectory() as tmp:
        state_path = os.path.join(tmp, "seen.json")
        with open(state_path, "w") as f:
            json.dump(["ep1"], f)

        fake_items = [
            {"id": "ep1", "mediaType": "podcast", "media": {"metadata": {"title": "Ep 1"}}},
            {"id": "ep2", "mediaType": "podcast", "media": {"metadata": {"title": "Ep 2 NEW"}}},
        ]
        with patch("abs_backend.list_library_items", return_value=fake_items):
            new_eps = abs_backend.check_new_episodes(
                "http://localhost:13378", "fake-token", "lib_pod", state_path)

        assert len(new_eps) == 1
        assert new_eps[0]["id"] == "ep2"


def test_is_mpv_installed_true_when_shutil_finds_it():
    with patch("abs_backend.shutil.which", return_value="/usr/bin/mpv"):
        assert abs_backend.is_mpv_installed() is True


def test_is_mpv_installed_false_when_missing():
    with patch("abs_backend.shutil.which", return_value=None):
        assert abs_backend.is_mpv_installed() is False


def test_queue_pending_progress_appends_to_disk(tmp_path, monkeypatch):
    queue_path = tmp_path / "pending-progress.json"
    monkeypatch.setattr(abs_backend, "PENDING_PROGRESS_PATH", str(queue_path))

    abs_backend.queue_pending_progress("li_book1", 700.0, 1454.1, False)

    saved = json.loads(queue_path.read_text())
    assert saved == [{"item_id": "li_book1", "current_time": 700.0,
                       "duration": 1454.1, "is_finished": False}]


def test_queue_pending_progress_replaces_same_item(tmp_path, monkeypatch):
    queue_path = tmp_path / "pending-progress.json"
    monkeypatch.setattr(abs_backend, "PENDING_PROGRESS_PATH", str(queue_path))

    abs_backend.queue_pending_progress("li_book1", 100.0, 1454.1, False)
    abs_backend.queue_pending_progress("li_book1", 200.0, 1454.1, False)

    saved = json.loads(queue_path.read_text())
    assert len(saved) == 1
    assert saved[0]["current_time"] == 200.0


def test_flush_pending_progress_sends_each_and_clears_queue_on_success(tmp_path, monkeypatch):
    queue_path = tmp_path / "pending-progress.json"
    queue_path.write_text(json.dumps([
        {"item_id": "li_book1", "current_time": 700.0, "duration": 1454.1, "is_finished": False},
    ]))
    monkeypatch.setattr(abs_backend, "PENDING_PROGRESS_PATH", str(queue_path))

    with patch("abs_backend.update_progress") as mock_update:
        flushed = abs_backend.flush_pending_progress("http://localhost:13378", "fake-token")

    mock_update.assert_called_once_with(
        "http://localhost:13378", "fake-token", "li_book1",
        current_time=700.0, duration=1454.1, is_finished=False)
    assert flushed == 1
    assert json.loads(queue_path.read_text()) == []


def test_flush_pending_progress_keeps_queue_on_repeated_failure(tmp_path, monkeypatch):
    queue_path = tmp_path / "pending-progress.json"
    queue_path.write_text(json.dumps([
        {"item_id": "li_book1", "current_time": 700.0, "duration": 1454.1, "is_finished": False},
    ]))
    monkeypatch.setattr(abs_backend, "PENDING_PROGRESS_PATH", str(queue_path))

    with patch("abs_backend.update_progress", side_effect=abs_backend.AbsAuthError("offline")):
        flushed = abs_backend.flush_pending_progress("http://localhost:13378", "fake-token")

    assert flushed == 0
    assert len(json.loads(queue_path.read_text())) == 1


def test_is_plugin_configured_true_when_config_json_exists(tmp_path, monkeypatch):
    fake_home = tmp_path
    (fake_home / ".config" / "audiobookshelf-plugin").mkdir(parents=True)
    (fake_home / ".config" / "audiobookshelf-plugin" / "config.json").write_text("{}")
    monkeypatch.setattr(os.path, "expanduser",
                         lambda p: p.replace("~", str(fake_home)))
    assert abs_backend.is_plugin_configured() is True


def test_is_plugin_configured_false_when_missing(tmp_path, monkeypatch):
    fake_home = tmp_path
    monkeypatch.setattr(os.path, "expanduser",
                         lambda p: p.replace("~", str(fake_home)))
    assert abs_backend.is_plugin_configured() is False


def test_sync_progress_queues_on_failure_instead_of_raising(monkeypatch):
    monkeypatch.setattr(abs_backend, "queue_pending_progress", MagicMock())
    with patch("abs_backend.update_progress", side_effect=abs_backend.AbsAuthError("offline")):
        # must not raise — a network blip mid-playback should never crash the sync call
        abs_backend.sync_progress("http://localhost:13378", "fake-token", "li_book1",
                                   current_time=700.0, duration=1454.1, is_finished=False)
    abs_backend.queue_pending_progress.assert_called_once_with("li_book1", 700.0, 1454.1, False)


def test_list_episodes_returns_trimmed_newest_first():
    payload = {"media": {"episodes": [
        {"id": "e1", "title": "Old", "publishedAt": 100, "audioFile": {"duration": 60.0}},
        {"id": "e2", "title": "New", "publishedAt": 200, "audioFile": {"duration": 90.0}},
    ]}}
    with patch.object(abs_backend, "_authed_get", return_value=payload) as get:
        episodes = abs_backend.list_episodes("http://abs", "tok", "pod1")
    get.assert_called_once_with("http://abs", "tok", "/api/items/pod1?expanded=1")
    assert [ep["id"] for ep in episodes] == ["e2", "e1"]
    assert episodes[0] == {"id": "e2", "title": "New", "publishedAt": 200, "duration": 90.0,
                           "description": ""}


def test_fetch_progress_index_keys_books_and_episodes():
    me = {"mediaProgress": [
        {"libraryItemId": "b1", "progress": 0.5, "isFinished": False},
        {"libraryItemId": "p1", "episodeId": "e1", "progress": 1, "isFinished": True},
    ]}
    with patch.object(abs_backend, "_authed_get", return_value=me):
        index = abs_backend.fetch_progress_index("http://abs", "tok")
    assert index == {"b1": {"progress": 0.5, "isFinished": False},
                     "p1/e1": {"progress": 1, "isFinished": True}}


def test_fetch_progress_index_derives_fraction_from_position():
    # ABS's stored progress can lag (0.0005 while currentTime says a third).
    me = {"mediaProgress": [{"libraryItemId": "b1", "progress": 0.0005,
                             "currentTime": 7080.0, "duration": 21240.0, "isFinished": False}]}
    with patch.object(abs_backend, "_authed_get", return_value=me):
        index = abs_backend.fetch_progress_index("http://abs", "tok")
    assert round(index["b1"]["progress"], 3) == 0.333


def test_annotate_items_counts_unplayed_episodes_and_attaches_book_progress():
    items = [
        {"id": "p1", "mediaType": "podcast", "media": {"numEpisodes": 5}},
        {"id": "p2", "mediaType": "podcast", "media": {"numEpisodes": 1}},
        {"id": "b1", "mediaType": "book", "media": {}},
    ]
    index = {"p1/e1": {}, "p1/e2": {}, "p2/e9": {}, "p2/e8": {},
             "b1": {"progress": 0.25, "isFinished": False}}
    abs_backend.annotate_items(items, index)
    assert items[0]["unplayedCount"] == 3
    assert items[1]["unplayedCount"] == 0  # stale records clamp at zero
    assert items[2]["userProgress"] == {"progress": 0.25, "isFinished": False}


def test_html_to_text_strips_tags_and_keeps_paragraph_breaks():
    html = "<p>First  line</p>\n<p><br /></p>\n<p>Producers: A &amp; B</p>"
    assert abs_backend.html_to_text(html) == "First line\n\nProducers: A & B"
    assert abs_backend.html_to_text("") == ""


def test_cover_url_resizes_and_appends_token():
    url = abs_backend.cover_url("http://abs/", "t/k", "item1")
    assert url == "http://abs/api/items/item1/cover?width=160&format=webp&token=t%2Fk"


def test_set_finished_patches_progress_key():
    captured = {}

    def fake_urlopen(request, timeout):
        captured["url"] = request.full_url
        captured["method"] = request.get_method()
        captured["body"] = json.loads(request.data)
        response = MagicMock()
        response.__enter__.return_value.read.return_value = b"{}"
        return response

    with patch.object(abs_backend, "urlopen", side_effect=fake_urlopen):
        abs_backend.set_finished("http://abs", "tok", "p1/e1", True)
    assert captured == {"url": "http://abs/api/me/progress/p1/e1", "method": "PATCH",
                        "body": {"isFinished": True}}


def test_pick_libraries_defaults_and_missing_types():
    libs = [{"id": "b1", "name": "Books", "mediaType": "book"},
            {"id": "b2", "name": "Kids", "mediaType": "book"}]
    assert abs_backend.pick_libraries(libs) == ("b1", "")
    assert abs_backend.pick_libraries(libs, "b2", "") == ("b2", "")
    assert abs_backend.pick_libraries(libs, "gone", "") == ("b1", "")


def test_list_all_items_skips_missing_library():
    with patch.object(abs_backend, "list_library_items", return_value=[{"id": "x"}]) as fetch:
        items = abs_backend.list_all_items("http://abs", "tok", "books", "")
    fetch.assert_called_once_with("http://abs", "tok", "books")
    assert items == [{"id": "x"}]


def test_check_new_episodes_without_podcast_library_returns_empty(tmp_path):
    with patch.object(abs_backend, "list_library_items") as fetch:
        assert abs_backend.check_new_episodes("http://abs", "tok", "", str(tmp_path / "s.json")) == []
    fetch.assert_not_called()


def test_disconnect_clears_token_and_config(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    cfg = tmp_path / ".config" / "audiobookshelf-plugin"
    state = tmp_path / ".local" / "state" / "audiobookshelf-plugin"
    cfg.mkdir(parents=True); state.mkdir(parents=True)
    (cfg / "config.json").write_text("{}")
    with patch("abs_backend.subprocess.run") as run:
        abs_backend.disconnect()
    assert run.call_args[0][0][:2] == ["secret-tool", "clear"]
    assert not cfg.exists() and not state.exists()
