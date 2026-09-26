import os
from pathlib import Path

import pytest

os.environ["QT_QPA_PLATFORM"] = "offscreen"

from PySide6.QtCore import QUrl
from PySide6.QtGui import QGuiApplication
from PySide6.QtQml import QQmlComponent, QQmlEngine

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def application():
    return QGuiApplication.instance() or QGuiApplication([])


@pytest.fixture
def model(application):
    engine = QQmlEngine()
    component = QQmlComponent(engine)
    component.setData(b'''
import QtQuick
import "../Model.js" as Model
Item {
  function mpvSocketPath(dir) { return Model.mpvSocketPath(dir) }
  function mpvCommand(path) { return Model.mpvCommand(path) }
  function shouldSeekOnResume(fileLoaded, progressReady, pendingResumeSeconds) {
    return Model.shouldSeekOnResume(fileLoaded, progressReady, pendingResumeSeconds)
  }
  function chapterSeekTarget(chapters, position, direction) { return Model.chapterSeekTarget(chapters, position, direction) }
  function stepSpeed(current, direction) { return Model.stepSpeed(current, direction) }
}
''', QUrl.fromLocalFile(str(ROOT / "tests" / "harness.qml")))
    obj = component.create()
    assert obj is not None, component.errorString()
    # Keep engine/component alive for obj's lifetime: PySide6 drops the
    # dynamically-bound QML JS methods once these go out of scope and get
    # garbage-collected, even though obj itself survives.
    obj._engine = engine
    obj._component = component
    return obj


def test_mpv_socket_path_lives_under_runtime_dir(model):
    path = model.mpvSocketPath("/run/user/1000")
    assert path == "/run/user/1000/audiobookshelf-mpv.sock"


def test_mpv_socket_path_empty_when_no_runtime_dir(model):
    assert model.mpvSocketPath("") == ""


def test_mpv_command_includes_input_ipc_server_flag(model):
    cmd = model.mpvCommand("/run/user/1000/audiobookshelf-mpv.sock")
    # PySide6 hands back a JS array crossing the QVariant boundary as a
    # QJSValue rather than a native list; unwrap it to assert on the
    # real values the QML side produced.
    cmd = cmd.toVariant() if hasattr(cmd, "toVariant") else cmd
    assert cmd[0] == "mpv"
    assert "--input-ipc-server=/run/user/1000/audiobookshelf-mpv.sock" in cmd
    assert "--no-ytdl" in cmd  # same injection-surface reasoning as the reference


# shouldSeekOnResume backs PlayerState.qml's resume-seek race-condition fix (Task 16
# fix round 1): mpv's file-loaded event and the ABS get-progress fetch are two
# independent async operations that can land in either order, and a resume seek is
# only correct once both have. These cases cover every ordering.

def test_should_seek_false_when_only_file_loaded(model):
    assert model.shouldSeekOnResume(True, False, 700.0) is False


def test_should_seek_false_when_only_progress_ready(model):
    assert model.shouldSeekOnResume(False, True, 700.0) is False


def test_should_seek_true_when_both_ready_with_a_saved_position(model):
    assert model.shouldSeekOnResume(True, True, 700.0) is True


def test_should_seek_false_when_both_ready_but_no_saved_position(model):
    # -1 is the "nothing to resume" sentinel (fresh item, or progress fetch
    # returned no prior position) — both readiness flags true is not enough on
    # its own.
    assert model.shouldSeekOnResume(True, True, -1) is False


def test_should_seek_false_before_either_side_is_ready(model):
    assert model.shouldSeekOnResume(False, False, -1) is False


CHAPTERS = [{"start": 0}, {"start": 100}, {"start": 250}]


def test_chapter_forward_goes_to_next_start(model):
    assert model.chapterSeekTarget(CHAPTERS, 120, 1) == 250
    assert model.chapterSeekTarget(CHAPTERS, 260, 1) == -1


def test_chapter_back_restarts_current_unless_near_its_start(model):
    assert model.chapterSeekTarget(CHAPTERS, 120, -1) == 100
    assert model.chapterSeekTarget(CHAPTERS, 101, -1) == 0
    assert model.chapterSeekTarget(CHAPTERS, 1, -1) == 0
    assert model.chapterSeekTarget([], 50, 1) == -1


def test_speed_steps_and_clamps(model):
    assert model.stepSpeed("1", 1) == "1.25"
    assert model.stepSpeed("1", -1) == "0.8"
    assert model.stepSpeed("0.8", -1) == "0.8"
    assert model.stepSpeed("2", 1) == "2"
    assert model.stepSpeed("1.75", 1) == "1.25"
