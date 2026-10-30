#!/usr/bin/env python3
"""scripts 定向 checker 日志判定：读取完成标记和精确诊断，不修改仿真产物。

四个非法输入用例必须各报一个指定错误，其余合法 don't-care 用例必须零错误。
不能单凭进程退出码或出现完成标记判通过，也不能把意外 native error 混入预期错误。
"""
import pathlib
import re
import sys

expected = {
    "rx_invalid": [],
    "rx_z": ["ETH_SEG_RX_VALID_X"],
    "rx_dontcare": [],
    "rx_eop_x": ["ETH_SEG_RX_QUALIFIED_X"],
    "rx_data_x": ["ETH_SEG_RX_QUALIFIED_X"],
    "tx_dontcare": [],
    "tx_data_x": ["ETH_SEG_TX_QUALIFIED_X"],
}
if len(sys.argv) != 3 or sys.argv[2] not in expected:
    raise SystemExit("usage: check_timing_checker.py LOG CASE")
path = pathlib.Path(sys.argv[1])
case = sys.argv[2]
text = path.read_text(errors="replace") if path.exists() else ""
if f"TIMING_CHECKER_COMPLETE={case}" not in text:
    raise SystemExit(f"{path}: missing completion marker")
diagnostics = re.findall(r"\b(ETH_SEG_[A-Z_]+):", text)
native_errors = re.findall(r"^\s*Error[:\-]", text, re.M)
if diagnostics != expected[case] or len(native_errors) != len(diagnostics):
    raise SystemExit(f"{path}: expected {expected[case]}, got {diagnostics}, native errors={len(native_errors)}")
if re.search(r"^\s*(?:Fatal[:\-]|UVM_(?:ERROR|FATAL)\b)", text, re.M):
    raise SystemExit(f"{path}: unexpected fatal/UVM diagnostic")
print(f"PASS checker {case}: {path}")
