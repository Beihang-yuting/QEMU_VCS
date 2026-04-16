#!/usr/bin/env python3
"""Trace analyzer for CoSim Platform.

解析 bridge_enable_trace() 产生的 CSV 或 JSON trace 文件，输出：
  - 事件数量统计（TLP / CPL / DMA / MSI）
  - 请求→完成延迟分布（按 tag 匹配）
  - 未匹配 / 重复 tag 的告警
  - DMA / MSI 细分统计
  - ASCII 直方图

Usage:
  python3 scripts/trace_analyzer.py <trace_file> [--verbose]

不依赖 pandas / matplotlib，仅用 Python 标准库以便在 CI 环境直接运行。
"""
from __future__ import annotations

import argparse
import csv
import json
import statistics
import sys
from collections import Counter
from pathlib import Path


def _parse_csv(path: Path):
    with path.open("r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            yield _normalize(row)


def _parse_json(path: Path):
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, list):
        raise ValueError("JSON trace must be a list of records")
    for row in data:
        yield _normalize(row)


def _normalize(row: dict) -> dict:
    out = {
        "timestamp": int(row.get("timestamp") or 0),
        "kind":      (row.get("kind") or "").strip(),
        "type":      (row.get("type") or "").strip(),
        "tag":       None,
        "addr":      None,
        "len":       None,
        "data":      row.get("data") or "",
        "vector":    None,
        "dir":       (row.get("dir") or "").strip(),
    }
    for key in ("tag", "len", "vector"):
        val = row.get(key)
        if val is not None and str(val).strip() != "":
            try:
                out[key] = int(val)
            except ValueError:
                pass
    addr = row.get("addr")
    if addr not in (None, ""):
        try:
            s = str(addr)
            out["addr"] = int(s, 16) if s.lower().startswith("0x") else int(s)
        except ValueError:
            pass

    # CSV-specific layout in trace_log.c:
    #   DMA row puts direction into the "type" column
    #   MSI row puts vector into the "data" column
    if out["kind"] == "dma" and not out["dir"] and out["type"]:
        out["dir"] = out["type"]
        out["type"] = ""
    if out["kind"] == "msi" and out["vector"] is None and out["data"]:
        try:
            out["vector"] = int(out["data"])
        except ValueError:
            pass
    return out


def analyze(records, verbose: bool = False) -> int:
    if not records:
        print("trace file is empty")
        return 1

    kind_counts = Counter(r["kind"] for r in records)
    type_counts = Counter((r["kind"], r["type"]) for r in records)

    print("=" * 60)
    print(f"Trace summary ({len(records)} records)")
    print("=" * 60)
    print()
    print("Events by kind:")
    for k, n in sorted(kind_counts.items()):
        print(f"  {k:<8} {n}")
    print()
    print("Events by (kind, type):")
    for (k, t), n in sorted(type_counts.items()):
        print(f"  {k:<6} {t or '-':<8} {n}")
    print()

    # ---- latency analysis: match tlp(req) -> cpl by tag ----
    req_by_tag = {}
    latencies = []
    orphan_cpls = []
    duplicate_reqs = []

    for r in records:
        if r["kind"] == "tlp" and r["type"] in ("MRd", "MWr", "CfgRd", "CfgWr"):
            if r["tag"] is None:
                continue
            if r["tag"] in req_by_tag:
                duplicate_reqs.append(r["tag"])
            req_by_tag[r["tag"]] = r
        elif r["kind"] == "cpl":
            if r["tag"] is None:
                continue
            req = req_by_tag.pop(r["tag"], None)
            if req is None:
                orphan_cpls.append(r)
            else:
                latencies.append(r["timestamp"] - req["timestamp"])

    print("Request / completion matching:")
    print(f"  matched        : {len(latencies)}")
    print(f"  missing cpl    : {len(req_by_tag)}")
    print(f"  orphan cpl     : {len(orphan_cpls)}")
    print(f"  duplicate tags : {len(duplicate_reqs)}")
    print()

    if latencies:
        print("Latency (sim timestamp units):")
        print(f"  count : {len(latencies)}")
        print(f"  min   : {min(latencies)}")
        print(f"  max   : {max(latencies)}")
        print(f"  mean  : {statistics.mean(latencies):.2f}")
        print(f"  median: {statistics.median(latencies)}")
        if len(latencies) > 1:
            print(f"  stdev : {statistics.stdev(latencies):.2f}")
        sorted_lat = sorted(latencies)
        p95 = sorted_lat[int(0.95 * (len(sorted_lat) - 1))]
        p99 = sorted_lat[int(0.99 * (len(sorted_lat) - 1))]
        print(f"  p95   : {p95}")
        print(f"  p99   : {p99}")
        print()
        print("Latency distribution (ASCII histogram):")
        _ascii_histogram(latencies)
        print()

    dmas = [r for r in records if r["kind"] == "dma"]
    if dmas:
        dir_counts = Counter(r["dir"] or "?" for r in dmas)
        total_bytes = sum(r["len"] or 0 for r in dmas)
        print(f"DMA: total {len(dmas)} transfers, {total_bytes} bytes")
        for d, n in dir_counts.items():
            print(f"  direction {d:<5} : {n}")
        print()

    msis = [r for r in records if r["kind"] == "msi"]
    if msis:
        vec_counts = Counter(r["vector"] for r in msis)
        print(f"MSI: {len(msis)} interrupts")
        for v, n in sorted(vec_counts.items(), key=lambda x: (x[0] is None, x[0])):
            print(f"  vector {v} : {n}")
        print()

    if verbose:
        print("-" * 60)
        print("First 10 events:")
        for r in records[:10]:
            print(f"  t={r['timestamp']:<8} {r['kind']:<4} {r['type']:<6} tag={r['tag']} "
                  f"addr={r['addr']} len={r['len']}")

    if duplicate_reqs or orphan_cpls or req_by_tag:
        print("WARNING: trace has unmatched tags — see counts above")
        return 2
    return 0


def _ascii_histogram(values, bins: int = 10, width: int = 40) -> None:
    lo, hi = min(values), max(values)
    if lo == hi:
        print(f"  {lo} | {'#' * width} ({len(values)})")
        return
    step = (hi - lo) / bins
    buckets = [0] * bins
    for v in values:
        idx = min(int((v - lo) / step), bins - 1)
        buckets[idx] += 1
    peak = max(buckets) or 1
    for i, count in enumerate(buckets):
        lo_e = lo + i * step
        hi_e = lo + (i + 1) * step
        bar = "#" * int(count * width / peak)
        print(f"  {lo_e:>10.0f}-{hi_e:<10.0f} | {bar:<{width}} ({count})")


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="CoSim trace analyzer")
    p.add_argument("path", type=Path, help="Trace file (.csv or .json)")
    p.add_argument("--verbose", "-v", action="store_true",
                   help="Print first 10 events")
    args = p.parse_args(argv)

    if not args.path.exists():
        print(f"error: file not found: {args.path}", file=sys.stderr)
        return 1

    suffix = args.path.suffix.lower()
    if suffix == ".csv":
        records = list(_parse_csv(args.path))
    elif suffix == ".json":
        records = list(_parse_json(args.path))
    else:
        print(f"error: unsupported trace format (want .csv or .json, got {suffix})",
              file=sys.stderr)
        return 1

    return analyze(records, verbose=args.verbose)


if __name__ == "__main__":
    sys.exit(main())
