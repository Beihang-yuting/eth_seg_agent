#!/usr/bin/env python3
"""scripts 回归工具：读取 VCS/UVM 日志，不修改仿真产物。

编译检查明确错误；运行必须具有完整 UVM summary 和零 ERROR/FATAL 计数。
第三个可选参数指定测试专用完成标记，防止超时、截断或早退被误判通过。
同时识别 VCS 原生 $error/$fatal，不能只依赖 UVM 的计数或进程退出码。
"""
import pathlib
import re
import sys

if len(sys.argv) not in (3, 4) or sys.argv[2] not in ("compile", "run"):
    raise SystemExit("usage: check_log.py LOG compile|run [COMPLETION_MARKER]")
path = pathlib.Path(sys.argv[1])
kind = sys.argv[2]
text = path.read_text(errors="replace") if path.exists() else ""
if not text:
    raise SystemExit(f"missing or empty log: {path}")
bad = re.findall(
    r"UVM_(?:ERROR|FATAL)\s*:\s*[1-9][0-9]*|^UVM_(?:ERROR|FATAL)[ \t]+(?=[^ \t:\n])[^\n]+|"
    r"^\s*(?:Error|Fatal)-[^\n]+|^\s*(?:Error|Fatal)[ \t]*:[ \t]*(?![ \t]*0[ \t]*$)[^\n]+|"
    r"^\s*\$?(?:error|fatal)\s*\([^\n]*",
    text, re.I | re.M,
)
if bad:
    raise SystemExit(f"{path}: unexpected diagnostics: {bad[:4]}")
if kind == "compile":
    if re.search(r"Error-?\s*:\s*[1-9]", text, re.I):
        raise SystemExit(f"{path}: compile errors found")
elif kind == "run":
    if "UVM Report Summary" not in text:
        raise SystemExit(f"{path}: no complete UVM summary")
    for severity in ("ERROR", "FATAL"):
        if not re.search(rf"^\s*UVM_{severity}\s*:\s*0\s*$", text, re.M):
            raise SystemExit(f"{path}: missing zero UVM_{severity} count")
    if len(sys.argv) == 4 and not re.search(rf"^UVM_INFO[^\n]*\[{re.escape(sys.argv[3])}\]", text, re.M):
        raise SystemExit(f"{path}: missing test completion marker {sys.argv[3]}")
print(f"PASS {kind}: {path}")
