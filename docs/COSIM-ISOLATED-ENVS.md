# CoSim 隔离双环境 — QEMU 侧 / VCS 侧 解耦 + TCP 跨机 E2E

QEMU 环境与 VCS 环境**完全隔离**,唯一耦合面是一个连接描述符 `cosim-conn.json`。
QEMU 侧只管起 QEMU + guest;VCS 侧(你自集成 DUT/UVM)读描述符连过去。

```
  ┌── QEMU 机 (e.g. 53) ──────────┐         ┌── VCS 机 (e.g. 61) ─────────────┐
  │ make run-qemu                 │  TCP    │ 你自集成的 env                  │
  │  ├ 起 N 个 QEMU (server,listen)│◄───────►│  ├ 读 cosim-conn.json           │
  │  │   cosim-pcie-rc,transport=tcp        │  ├ 解析 → plusargs              │
  │  │   port_base=P, instance_id=r│         │  │   ./your_simv (client connect)│
  │  └ 写 cosim-conn.json ─────────┼── scp ──┼─►└ 驱动你的 xilinx-pcie DUT     │
  └───────────────────────────────┘         └────────────────────────────────┘
```

- QEMU 是 **server**(先起、阻塞 listen);VCS 是 **client**(后连)。**QEMU 必须先在。**
- 每个 RC = 一个 QEMU 实例。端口约定:**`port = port_base + instance_id*3`**(每实例占 3 个 fd)。
  同一 `port_base`,`instance_id = r`。VCS 侧对齐传同一 `port_base`,`instance_id=r`(别再加 stride)。

---

## 契约文件 `cosim-conn.json`

QEMU 侧 `make run-qemu` 生成,VCS 侧解析后传成 plusargs 消费。

```json
{
  "transport": "tcp",
  "host": "10.11.10.53",
  "port_base": 9100,
  "num_rc": 2,
  "port_formula": "port = port_base + instance_id*3",
  "rcs": [ {"rc": 0, "instance_id": 0, "port": 9100},
           {"rc": 1, "instance_id": 1, "port": 9103} ],
  "device": { "vendor": "0x1af4", "device": "0x1041", "bar0_size": "0x10000" }
}
```

| 字段 | 谁用 | 说明 |
|---|---|---|
| `transport` | 两侧 | `tcp`(跨机,支持多 RC) / `shm`(同机,当前仅单 RC) |
| `host` | VCS | client 连接目标(QEMU 机 IP) |
| `port_base` | 两侧 | 端口基;实际端口 `port_base + instance_id*3` |
| `num_rc` | 两侧 | RC 数 = QEMU 实例数 |
| `rcs[]` | VCS | 每 RC 的 instance_id / 算出的 port(便于核对) |
| `device.*` | VCS | guest 枚举的设备身份,须与 VCS 侧 `config_proxy` 一致,否则枚不出设备 |

> **transport 选型**:隔离 + 多 RC → **TCP**(唯一支持多 RC 的路径,C 侧 SHM 是单例)。
> SHM 只在同机 + 单 RC + 要吞吐时用。

---

## E2E 步骤(TCP 跨机)

### 1. QEMU 机(如 53)——只起 QEMU

```bash
cd <cosim-platform>
make run-qemu NUM_RC=2 PORT_BASE=9100 ADVERTISE_HOST=10.11.10.53
# → 起 2 个 QEMU(RC0 port 9100 / RC1 port 9103,listen),写 run/cosim-conn.json,前台守着
```

镜像/QEMU 自动定位 `third_party/qemu/build/` + `guest/images/<GUEST_TYPE>/`;找不到用
`QEMU= KERNEL= ROOTFS=` 覆盖。设备身份用 `DEV_VENDOR/DEV_DEVICE/DEV_BAR0_SIZE` 覆盖。

### 2. VCS 机(如 61)——你自集成的环境,读描述符连过去

把 `run/cosim-conn.json` 拉到 VCS 机(scp),解析出 host/port_base/num_rc,传成 plusargs
给你的 simv(或你 env 的 run 脚本):

```bash
# VCS 侧:解析描述符 → 传给你的 simv(或你 env 的 run 脚本)
HOST=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["host"])' cosim-conn.json)
PORT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["port_base"])' cosim-conn.json)
NRC=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["num_rc"])' cosim-conn.json)
./your_simv +COSIM +REMOTE_HOST=$HOST +PORT_BASE=$PORT +NUM_RC=$NRC +BYPASS_CONFIG=1
```

simv 集成见 [COSIM-MINIMAL-INTEGRATION.md](COSIM-MINIMAL-INTEGRATION.md)。

### 3. 接 DUT

你的 top 每 RC 4 条 AXIS 总线 `rcN_{rq,rc,cq,cc}`。接你的
xilinx-pcie EP DUT 的 AXIS 口(同名 RQ→RQ / RC→RC / CQ→CQ / CC→CC)。无 DUT 时只能
elaborate 空跑(RC build 起来但没 tready,不跑数据)。

### 4. 跑 workload + 看结果

guest 里跑寄存器读写 / DMA / 打流;两侧看 log(`run/log/qemu_rc*.log` 与 VCS `run.log`)。

---

## 入口清单

| 入口 | 侧 | 职责 |
|---|---|---|
| `make run-qemu NUM_RC=<n> PORT_BASE=<p> ADVERTISE_HOST=<ip>` | QEMU | 起 N QEMU(隔离)+ 写 `run/cosim-conn.json` |
| VCS 侧读 `cosim-conn.json` → plusargs(见上 §2 recipe) | VCS | 解析描述符 → `+REMOTE_HOST/+PORT_BASE/+NUM_RC` 传给你的 simv |
| `make cosim-lib` | VCS | 把 C 侧打成 `build/lib/libcosim_bridge.a`(你自己 flow 链接用) |

---

## 同机 SHM(备选,单 RC)

同机、单 RC、要吞吐时:QEMU `shm_name=/cosim0,sock_path=<dir>/cosim0.sock`,
VCS `+SHM_NAME=/cosim0 +SOCK_PATH=<dir>/cosim0.sock`。描述符 `transport:"shm"` +
`shm_name`/`sock_path` 字段。**多 RC 不支持 SHM**(C 侧 `g_shm` 单例);要多 RC SHM
需先把 SHM 路径也 per-RC 化(额外 C 活)。
