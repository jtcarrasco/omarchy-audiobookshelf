#!/usr/bin/env bash
# Runs after any file edit in this project — currently just syntax-checks
# Python files. Extend with a QML linter later if one gets added.
# Receives tool-call payload as JSON on stdin; scans for .py file paths and validates them.
set -euo pipefail

INPUT=$(cat)

# Parse JSON payload and extract all string values that look like file paths
# Use python3 -c to run the script and here-string to pass $INPUT to stdin
python3 -c '
import json
import sys
import subprocess

try:
    data = json.loads(sys.stdin.read())
except json.JSONDecodeError:
    sys.exit(0)

def extract_strings(obj, strings=None):
    if strings is None:
        strings = []
    if isinstance(obj, dict):
        for v in obj.values():
            extract_strings(v, strings)
    elif isinstance(obj, list):
        for item in obj:
            extract_strings(item, strings)
    elif isinstance(obj, str):
        strings.append(obj)
    return strings

for s in extract_strings(data):
    if s.endswith(".py"):
        try:
            subprocess.run(["python3", "-m", "py_compile", s], check=True)
        except FileNotFoundError:
            pass  # File does not exist, skip silently
' <<< "$INPUT"

