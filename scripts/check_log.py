#!/usr/bin/env python3
"""检查 VCS/UVM 日志中的明确完成标志和错误计数，避免仅凭退出码判定通过。"""
import pathlib
import re
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: check_log.py LOG compile|run")
path = pathlib.Path(sys.argv[1])
kind = sys.argv[2]
text = path.read_text(errors="replace") if path.exists() else ""
if not text:
    raise SystemExit(f"missing or empty log: {path}")
bad = re.findall(r"UVM_(?:ERROR|FATAL)\s*:\s*[1-9][0-9]*|^Error-[^\n]+|^Fatal-[^\n]+|Error-?\s*:\s*[1-9][0-9]*", text, re.I | re.M)
if bad:
    raise SystemExit(f"{path}: unexpected diagnostics: {bad[:4]}")
if kind == "compile":
    if re.search(r"Error-?\s*:\s*[1-9]", text, re.I):
        raise SystemExit(f"{path}: compile errors found")
elif kind == "run":
    if "UVM Report Summary" not in text and "UVM_INFO" not in text:
        raise SystemExit(f"{path}: no UVM summary marker")
print(f"PASS {kind}: {path}")
