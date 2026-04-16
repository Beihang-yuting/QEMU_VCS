#!/usr/bin/env python3
"""cosim_cli — QEMU-VCS CoSim Platform 调试控制台 (P4-①).

作为 QEMU 侧进程，加载 libcosim_bridge.so，创建 Bridge 上下文，等待 VCS 连入，
然后提供交互式 REPL 触发各种事务，便于不起真实 QEMU 即可联调 VCS RTL。

示例：
  python3 scripts/cosim_cli.py --shm /cosim0 --sock /tmp/cosim.sock \\
      --lib build/bridge/libcosim_bridge.so

常用命令（在 REPL 中）：
  help                              列出所有命令
  read  <addr> [size]               发起 MRd TLP（默认 size=4）
  write <addr> <val> [size]         发起 MWr TLP
  mode  fast|precise                切换同步模式
  advance <cycles>                  精确模式推进 N 个周期
  trace on <path> [csv|json]        开启事务追踪
  trace off                         关闭追踪
  status                            打印当前模式与连接状态
  quit / exit                       退出
"""
from __future__ import annotations

import argparse
import ctypes as ct
import os
import shlex
import sys
from pathlib import Path

# --- bridge C ABI shims -------------------------------------------------------

COSIM_TLP_DATA_SIZE = 64


class TlpEntry(ct.Structure):
    _pack_ = 1
    _fields_ = [
        ("type",       ct.c_uint8),
        ("tag",        ct.c_uint8),
        ("len",        ct.c_uint16),
        ("addr",       ct.c_uint64),
        ("data",       ct.c_uint8 * COSIM_TLP_DATA_SIZE),
        ("dma_offset", ct.c_uint64),
        ("timestamp",  ct.c_uint64),
    ]


class CplEntry(ct.Structure):
    _pack_ = 1
    _fields_ = [
        ("type",      ct.c_uint8),
        ("tag",       ct.c_uint8),
        ("status",    ct.c_uint16),
        ("len",       ct.c_uint16),
        ("_pad",      ct.c_uint16),
        ("data",      ct.c_uint8 * COSIM_TLP_DATA_SIZE),
        ("timestamp", ct.c_uint64),
    ]


TLP_MRD = 1
TLP_MWR = 0
TRACE_FMT_CSV = 0
TRACE_FMT_JSON = 1
COSIM_MODE_FAST = 0
COSIM_MODE_PRECISE = 1


def load_bridge(lib_path: Path) -> ct.CDLL:
    if not lib_path.exists():
        print(f"error: library not found: {lib_path}", file=sys.stderr)
        print("tip: run `make bridge` first, then pass --lib build/bridge/libcosim_bridge.so",
              file=sys.stderr)
        sys.exit(1)
    lib = ct.CDLL(str(lib_path))

    lib.bridge_init.argtypes = [ct.c_char_p, ct.c_char_p]
    lib.bridge_init.restype  = ct.c_void_p
    lib.bridge_connect.argtypes = [ct.c_void_p]
    lib.bridge_connect.restype  = ct.c_int
    lib.bridge_send_tlp_and_wait.argtypes = [ct.c_void_p,
                                              ct.POINTER(TlpEntry),
                                              ct.POINTER(CplEntry)]
    lib.bridge_send_tlp_and_wait.restype  = ct.c_int
    lib.bridge_send_tlp_fire.argtypes = [ct.c_void_p, ct.POINTER(TlpEntry)]
    lib.bridge_send_tlp_fire.restype  = ct.c_int
    lib.bridge_request_mode_switch.argtypes = [ct.c_void_p, ct.c_int]
    lib.bridge_request_mode_switch.restype  = ct.c_int
    lib.bridge_get_mode.argtypes = [ct.c_void_p]
    lib.bridge_get_mode.restype  = ct.c_int
    lib.bridge_advance_clock.argtypes = [ct.c_void_p, ct.c_uint64]
    lib.bridge_advance_clock.restype  = ct.c_int
    lib.bridge_enable_trace.argtypes = [ct.c_void_p, ct.c_char_p, ct.c_int]
    lib.bridge_enable_trace.restype  = ct.c_int
    lib.bridge_disable_trace.argtypes = [ct.c_void_p]
    lib.bridge_disable_trace.restype  = None
    lib.bridge_destroy.argtypes = [ct.c_void_p]
    lib.bridge_destroy.restype  = None
    return lib


# --- REPL ---------------------------------------------------------------------


class CLI:
    def __init__(self, lib: ct.CDLL, ctx: int) -> None:
        self.lib = lib
        self.ctx = ctx

    @staticmethod
    def parse_int(s: str) -> int:
        s = s.strip()
        if s.startswith(("0x", "0X")):
            return int(s, 16)
        return int(s)

    def do_read(self, args):
        if not args:
            print("usage: read <addr> [size]")
            return
        addr = self.parse_int(args[0])
        size = int(args[1]) if len(args) > 1 else 4
        if size not in (1, 2, 4, 8):
            print("error: size must be 1/2/4/8")
            return
        req = TlpEntry(type=TLP_MRD, addr=addr, len=size)
        cpl = CplEntry()
        rc = self.lib.bridge_send_tlp_and_wait(self.ctx, ct.byref(req), ct.byref(cpl))
        if rc < 0:
            print(f"error: TLP MRd failed rc={rc}")
            return
        val = 0
        for i in range(size):
            val |= cpl.data[i] << (i * 8)
        print(f"read addr=0x{addr:X} size={size}  ->  0x{val:0{size*2}X}")

    def do_write(self, args):
        if len(args) < 2:
            print("usage: write <addr> <val> [size]")
            return
        addr = self.parse_int(args[0])
        val  = self.parse_int(args[1])
        size = int(args[2]) if len(args) > 2 else 4
        if size not in (1, 2, 4, 8):
            print("error: size must be 1/2/4/8")
            return
        req = TlpEntry(type=TLP_MWR, addr=addr, len=size)
        for i in range(size):
            req.data[i] = (val >> (i * 8)) & 0xFF
        rc = self.lib.bridge_send_tlp_fire(self.ctx, ct.byref(req))
        if rc < 0:
            print(f"error: TLP MWr failed rc={rc}")
            return
        print(f"write addr=0x{addr:X} size={size} val=0x{val:0{size*2}X}  ->  sent (fire-and-forget)")

    def do_mode(self, args):
        if not args:
            current = self.lib.bridge_get_mode(self.ctx)
            name = {COSIM_MODE_FAST: "fast", COSIM_MODE_PRECISE: "precise"}.get(current, f"?({current})")
            print(f"current mode: {name}")
            return
        target = args[0].lower()
        mode_map = {"fast": COSIM_MODE_FAST, "precise": COSIM_MODE_PRECISE}
        if target not in mode_map:
            print("error: mode must be fast|precise")
            return
        rc = self.lib.bridge_request_mode_switch(self.ctx, mode_map[target])
        if rc < 0:
            print(f"error: mode switch failed rc={rc}")
            return
        print(f"mode switch requested -> {target}")

    def do_advance(self, args):
        if not args:
            print("usage: advance <cycles>  (only valid in precise mode)")
            return
        cycles = int(args[0])
        rc = self.lib.bridge_advance_clock(self.ctx, cycles)
        if rc < 0:
            print("error: advance_clock failed (are you in precise mode?)")
            return
        print(f"advanced {cycles} cycles, VCS acked")

    def do_trace(self, args):
        if not args:
            print("usage: trace on <path> [csv|json]  |  trace off")
            return
        if args[0] == "off":
            self.lib.bridge_disable_trace(self.ctx)
            print("trace off")
            return
        if args[0] == "on" and len(args) >= 2:
            path = args[1]
            fmt_name = args[2].lower() if len(args) > 2 else "csv"
            fmt = TRACE_FMT_CSV if fmt_name == "csv" else TRACE_FMT_JSON
            rc = self.lib.bridge_enable_trace(self.ctx, path.encode(), fmt)
            if rc < 0:
                print(f"error: enable_trace failed rc={rc}")
                return
            print(f"trace on: {path} ({fmt_name})")
            return
        print("usage: trace on <path> [csv|json]  |  trace off")

    def do_status(self, args):
        current = self.lib.bridge_get_mode(self.ctx)
        name = {COSIM_MODE_FAST: "fast", COSIM_MODE_PRECISE: "precise"}.get(current, f"?({current})")
        print(f"ctx   : 0x{self.ctx:X}")
        print(f"mode  : {name}")

    def do_help(self, args):
        print(__doc__.strip())

    def run(self) -> int:
        print("cosim_cli ready. Type 'help' for commands, 'quit' to exit.")
        try:
            import readline  # noqa: F401
        except ImportError:
            pass

        while True:
            try:
                line = input("cosim> ").strip()
            except (EOFError, KeyboardInterrupt):
                print()
                break
            if not line:
                continue
            parts = shlex.split(line)
            cmd, args = parts[0].lower(), parts[1:]
            if cmd in ("quit", "exit"):
                break
            handler = getattr(self, f"do_{cmd}", None)
            if handler is None:
                print(f"unknown command: {cmd}. Type 'help' for a list.")
                continue
            try:
                handler(args)
            except Exception as e:  # noqa: BLE001
                print(f"error: {e}")
        return 0


# --- main ---------------------------------------------------------------------


def main(argv=None) -> int:
    repo_root = Path(__file__).resolve().parent.parent
    default_lib = repo_root / "build" / "bridge" / "libcosim_bridge.so"

    p = argparse.ArgumentParser(description="CoSim debug console")
    p.add_argument("--shm",  default="/cosim0", help="POSIX shared memory name")
    p.add_argument("--sock", default="/tmp/cosim.sock", help="Unix socket path")
    p.add_argument("--lib",  default=str(default_lib),
                   help="Path to libcosim_bridge.so")
    p.add_argument("--no-wait", action="store_true",
                   help="Skip bridge_connect() (smoke test without VCS)")
    args = p.parse_args(argv)

    lib = load_bridge(Path(args.lib))
    os.environ.setdefault("LD_LIBRARY_PATH", str(repo_root / "build" / "bridge"))

    print(f"init bridge (shm={args.shm} sock={args.sock}) ...")
    ctx = lib.bridge_init(args.shm.encode(), args.sock.encode())
    if not ctx:
        print("error: bridge_init returned NULL", file=sys.stderr)
        return 1

    if not args.no_wait:
        print(f"waiting for VCS to connect on {args.sock} (Ctrl-C to abort) ...")
        try:
            rc = lib.bridge_connect(ct.c_void_p(ctx))
        except KeyboardInterrupt:
            print("aborted")
            lib.bridge_destroy(ct.c_void_p(ctx))
            return 1
        if rc < 0:
            print("error: bridge_connect failed", file=sys.stderr)
            lib.bridge_destroy(ct.c_void_p(ctx))
            return 1
        print("VCS connected.")
    else:
        print("WARNING: --no-wait set; commands that talk to VCS will hang")

    cli = CLI(lib, ctx)
    rc = cli.run()

    print("destroying bridge ...")
    lib.bridge_destroy(ct.c_void_p(ctx))
    return rc


if __name__ == "__main__":
    sys.exit(main())
