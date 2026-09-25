---
paths:
  - "**/*.py"
  - "**/tests/**"
---

# Testing

- Python backend logic (`scripts/abs_backend.py`) gets plain pytest —
  no live network calls in tests, mock `urllib` responses.
- QML logic in `Model.js` gets tested via the PySide6 + QQmlEngine harness
  pattern (see `tests/test_model.py` once it exists) — load the real file,
  call the real function, assert on the real return value. Don't
  reimplement the logic in the test.
- No test may open a real mpv process or hit a real Audiobookshelf server.
