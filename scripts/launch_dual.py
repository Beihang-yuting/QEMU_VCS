#!/usr/bin/env python3
"""launch_dual.py — Dual-node CoSim launcher (P3-T7).

Boots two CoSim nodes (A and B) that talk to each other over the ETH SHM link.
Supports:

  * mode=local : subprocess launches both nodes on the current machine
  * mode=ssh   : launches node B remotely over SSH (paramiko if available,
                 falls back to the `ssh` CLI). Node A still runs locally.

The launcher stays in the foreground, monitors stdout/stderr of each child,
and cleans up both on Ctrl-C or SIGTERM.

Typical use:
  # stub smoke test (no QEMU, no VCS)
  python3 scripts/launch_dual.py --launcher-cmd "sleep 2" --smoke

  # real run (assumes run_cosim.sh is configured with env)
  python3 scripts/launch_dual.py \\
      --shm-pcie-a /cosim-pcie-a --shm-pcie-b /cosim-pcie-b \\
      --shm-eth   /cosim-eth0 \\
      --sock-a    /tmp/cosim-a.sock --sock-b /tmp/cosim-b.sock

The --smoke flag makes the launcher exit 0 after 5 seconds if both children
are still alive (useful for CI).
"""
from __future__ import annotations

import argparse
import os
import shlex
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


class Node:
    def __init__(self, name, cmd, env=None, remote_host=None, remote_ssh_cmd=None):
        self.name = name
        self.cmd = cmd                  # list[str] or str (shell)
        self.env = env or {}
        self.remote_host = remote_host
        self.remote_ssh_cmd = remote_ssh_cmd or "ssh"
        self.proc = None

    def start(self):
        if self.remote_host:
            if isinstance(self.cmd, list):
                shell_cmd = " ".join(shlex.quote(c) for c in self.cmd)
            else:
                shell_cmd = self.cmd
            env_prefix = " ".join(f"{k}={shlex.quote(v)}" for k, v in self.env.items())
            remote_shell = f"{env_prefix} {shell_cmd}" if env_prefix else shell_cmd
            full = [self.remote_ssh_cmd, self.remote_host, "bash", "-lc", remote_shell]
            print(f"[{self.name}] remote: {' '.join(full)}")
            self.proc = subprocess.Popen(full,
                                         stdout=subprocess.PIPE,
                                         stderr=subprocess.STDOUT,
                                         text=True)
        else:
            full_env = os.environ.copy()
            full_env.update(self.env)
            if isinstance(self.cmd, str):
                print(f"[{self.name}] local: {self.cmd}")
                self.proc = subprocess.Popen(self.cmd,
                                             shell=True,
                                             env=full_env,
                                             stdout=subprocess.PIPE,
                                             stderr=subprocess.STDOUT,
                                             text=True)
            else:
                print(f"[{self.name}] local: {' '.join(self.cmd)}")
                self.proc = subprocess.Popen(self.cmd,
                                             env=full_env,
                                             stdout=subprocess.PIPE,
                                             stderr=subprocess.STDOUT,
                                             text=True)

    def pipe_stdout(self):
        if not self.proc or not self.proc.stdout:
            return
        for line in self.proc.stdout:
            print(f"[{self.name}] {line.rstrip()}")

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def stop(self, timeout=3):
        if not self.proc:
            return
        if self.alive():
            self.proc.terminate()
            try:
                self.proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()


def build_cmd(args, _role_upper):
    """Construct the per-node launch command."""
    if args.launcher_cmd:
        # User-supplied command (e.g., "sleep 2" for smoke tests).
        return args.launcher_cmd
    # Default: real QEMU via run_cosim.sh
    return str(REPO_ROOT / "scripts" / "run_cosim.sh")


def build_env(args, role_upper):
    """Compose environment for each node."""
    env = {}
    if role_upper == "A":
        env["SHM_NAME"] = args.shm_pcie_a
        env["SOCK_PATH"] = args.sock_a
    else:
        env["SHM_NAME"] = args.shm_pcie_b
        env["SOCK_PATH"] = args.sock_b
    env["COSIM_ETH_SHM"] = args.shm_eth
    env["COSIM_ROLE"] = role_upper
    return env


def main(argv=None):
    p = argparse.ArgumentParser(description="CoSim dual-node launcher")
    p.add_argument("--mode", choices=["local", "ssh"], default="local")
    p.add_argument("--node-a-host", default=None, help="SSH host for node A (rarely used)")
    p.add_argument("--node-b-host", default=None,
                   help="SSH host for node B (defaults to localhost in ssh mode)")
    p.add_argument("--shm-pcie-a", default="/cosim-pcie-a")
    p.add_argument("--shm-pcie-b", default="/cosim-pcie-b")
    p.add_argument("--shm-eth",    default="/cosim-eth0")
    p.add_argument("--sock-a",     default="/tmp/cosim-a.sock")
    p.add_argument("--sock-b",     default="/tmp/cosim-b.sock")
    p.add_argument("--launcher-cmd", default=None,
                   help="Override launch command (e.g. 'sleep 2' for smoke tests)")
    p.add_argument("--ssh-cmd", default="ssh",
                   help="SSH executable (default: ssh)")
    p.add_argument("--smoke", action="store_true",
                   help="Exit 0 after 5 seconds if both nodes are alive")
    args = p.parse_args(argv)

    if args.mode == "ssh" and not (args.node_a_host or args.node_b_host):
        print("warning: --mode ssh requested but no host given; falling back to local")
        args.mode = "local"

    nodes = [
        Node(name="A",
             cmd=build_cmd(args, "A"),
             env=build_env(args, "A"),
             remote_host=(args.node_a_host if args.mode == "ssh" else None),
             remote_ssh_cmd=args.ssh_cmd),
        Node(name="B",
             cmd=build_cmd(args, "B"),
             env=build_env(args, "B"),
             remote_host=(args.node_b_host if args.mode == "ssh" else None),
             remote_ssh_cmd=args.ssh_cmd),
    ]

    for n in nodes:
        n.start()

    threads = [threading.Thread(target=n.pipe_stdout, daemon=True) for n in nodes]
    for t in threads:
        t.start()

    stop_requested = threading.Event()

    def sigint(_signum, _frame):
        print("\n[launch] shutdown requested")
        stop_requested.set()

    signal.signal(signal.SIGINT, sigint)
    signal.signal(signal.SIGTERM, sigint)

    deadline = time.time() + 5.0 if args.smoke else None
    rc_out = 0

    try:
        while not stop_requested.is_set():
            time.sleep(0.2)
            for n in nodes:
                if not n.alive():
                    print(f"[launch] {n.name} exited (rc={n.proc.returncode})")
                    stop_requested.set()
                    break
            if deadline and time.time() >= deadline:
                alive = all(n.alive() for n in nodes)
                print(f"[launch] smoke deadline reached; nodes alive={alive}")
                stop_requested.set()
                if not alive:
                    rc_out = 1
                break
    finally:
        for n in nodes:
            n.stop()
        for t in threads:
            t.join(timeout=1)

    return rc_out


if __name__ == "__main__":
    sys.exit(main())
