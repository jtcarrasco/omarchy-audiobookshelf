---
paths:
  - "**/*.qml"
  - "**/*.js"
---

# QML/JS Code Quality

- One QML file, one visual component. If `LibraryWindow.qml` grows past
  ~300 lines, split list-row rendering into its own component file.
- `Model.js` holds pure functions only — no `Process`/`Socket` objects, no
  QML property reads. Every function here must be callable from a plain
  JS test harness with primitive/plain-object arguments.
- Never interpolate user-influenced strings into a shell command. Process
  `command:` is always an array.
