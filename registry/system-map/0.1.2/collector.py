#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""system-map — сборщик единого снимка системы агентов и железа.

Только чтение внешних источников:
  * mcp-watchdog\state\current.json
  * monitor\state\nodes.json
  * mcp-watchdog-guardian\state\{current.json,guardian.pid}
  * run-watch\state\run-watch.json
  * opencode.db (сессии/субагенты/свежие вызовы инструментов, режим ro)
  * конфиг gordon, env-ключи провайдеров, ollama list/ps, Lab100 status
  * psutil (CPU/RAM/диски/процессы), WMI/счётчики GPU (Windows)

Наружу: JSON snapshot (stdout) и одноимённый файл в state\ (атомарно).
Машинные пути не зашиты: корень инструментов — --tools-root / INVR_TOOLS_ROOT.
"""

import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

SCHEMA = "invr.system-map/1"
DEFAULT_TOOLS = Path(__file__).resolve().parents[3]

STATE_COLORS = {
    "active": "#22c55e",
    "idle": "#f59e0b",
    "unloaded": "#9ca3af",
    "need-guard": "#fb923c",
    "fault": "#ef4444",
    "starting": "#22d3ee",
    "blocked": "#a855f7",
    "detached": "#6366f1",
    "reaped": "#6b7280",
    "unknown": "#64748b",
}


def now_iso():
    return datetime.now().astimezone().isoformat(timespec="seconds")


def read_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception:
        return default


def write_json_atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, ensure_ascii=False, indent=2, default=str)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def cached(name, state_dir, ttl, producer):
    """Небольшой кэш дорогих запросов (GPU, ollama, lab100)."""
    cache_file = Path(state_dir) / (name + ".cache.json")
    old = read_json(cache_file, {})
    ts = old.get("_ts", 0)
    if time.time() - ts < ttl and "value" in old:
        return old["value"]
    try:
        value = producer()
    except Exception as exc:
        value = old.get("value", {"error": str(exc)})
    write_json_atomic(cache_file, {"_ts": time.time(), "value": value})
    return value


def run_cmd(args, timeout=6, cwd=None):
    """Выполнить команду, вернуть (ok, stdout)."""
    try:
        p = subprocess.run(
            args,
            cwd=cwd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
        )
        return p.returncode == 0, (p.stdout or "").strip()
    except Exception as exc:
        return False, str(exc)


# --------------------------------------------------------------------------- железа
def collect_hardware(state_dir):
    out = {"cpu": {}, "memory": {}, "gpu": [], "disks": [], "io": {}, "os": {}}
    try:
        import psutil

        vm = psutil.virtual_memory()
        sw = psutil.swap_memory()
        out["cpu"] = {
            "percent": psutil.cpu_percent(interval=0.25),
            "logical": psutil.cpu_count(logical=True),
            "physical": psutil.cpu_count(logical=False),
            "freq_mhz": getattr(psutil.cpu_freq(), "current", None) if psutil.cpu_freq() else None,
        }
        try:
            out["cpu"]["load"] = list(os.getloadavg()) if hasattr(os, "getloadavg") else None
        except Exception:
            out["cpu"]["load"] = None
        out["memory"] = {
            "total_gb": round(vm.total / 2**30, 2),
            "used_gb": round(vm.used / 2**30, 2),
            "available_gb": round(vm.available / 2**30, 2),
            "free_gb": round(vm.free / 2**30, 2),
            "percent": vm.percent,
            "commit_total_gb": round(sw.total / 2**30, 2),
            "commit_used_gb": round(sw.used / 2**30, 2),
            "commit_percent": sw.percent,
        }
        for part in psutil.disk_partitions(all=False):
            if part.fstype not in ("NTFS", "exFAT", "FAT32", "ReFS"):
                continue
            try:
                u = psutil.disk_usage(part.mountpoint)
                out["disks"].append(
                    {
                        "device": part.device,
                        "mount": part.mountpoint,
                        "total_gb": round(u.total / 2**30, 2),
                        "used_gb": round(u.used / 2**30, 2),
                        "free_gb": round(u.free / 2**30, 2),
                        "percent": u.percent,
                    }
                )
            except Exception:
                continue
        io = psutil.disk_io_counters()
        if io:
            out["io"] = {
                "read_mb": round(io.read_bytes / 2**20, 1),
                "write_mb": round(io.write_bytes / 2**20, 1),
                "read_count": io.read_count,
                "write_count": io.write_count,
            }
        out["os"] = {
            "system": platform_system(),
            "boot_time": datetime.fromtimestamp(psutil.boot_time()).astimezone().isoformat(timespec="seconds"),
            "process_count": len(psutil.pids()),
        }
    except ImportError:
        out["error"] = "psutil не установлен"

    out["gpu"] = cached(
        "gpu",
        state_dir,
        60,
        lambda: gpu_info(),
    )
    return out


def platform_system():
    import platform

    return "%s %s" % (platform.system(), platform.release())


PS_CMD = r"""
$g = Get-CimInstance Win32_VideoController | ForEach-Object {
    [pscustomobject]@{
        name = $_.Name
        adapterRam = $_.AdapterRAM
        driver = $_.DriverVersion
    }
}
$u = $null
try {
    $c = Get-Counter -Counter '\GPU Engine(*)\Utilization Percentage' -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
    $u = ($c.CounterSamples | Measure-Object -Property CookedValue -Maximum).Maximum
} catch {}
$m = $null
try {
    $c2 = Get-Counter -Counter '\GPU Adapter Memory(*)\Dedicated Usage' -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
    $m = ($c2.CounterSamples | Measure-Object -Property CookedValue -Sum).Sum
} catch {}
[pscustomobject]@{ adapters = @($g); gpuUtil = $u; dedicatedBytes = $m } | ConvertTo-Json -Depth 4 -Compress
"""


def gpu_info():
    ok, text = run_cmd(["pwsh", "-NoProfile", "-Command", PS_CMD], timeout=12)
    if not ok:
        return [{"error": text[:400]}]
    try:
        data = json.loads(text)
    except Exception:
        return [{"error": "не удалось разобрать ответ PowerShell", "raw": text[:300]}]
    adapters = data.get("adapters") or []
    if isinstance(adapters, dict):
        adapters = [adapters]
    util = data.get("gpuUtil")
    dedicated = data.get("dedicatedBytes")
    res = []
    for a in adapters:
        ram = a.get("adapterRam") or 0
        res.append(
            {
                "name": a.get("name"),
                "driver": a.get("driver"),
                "vram_gb": round(ram / 2**30, 2) if ram else None,
                "gpu_percent": round(float(util), 1) if util not in (None, "") else None,
                "dedicated_mb": round(float(dedicated) / 2**20, 1) if dedicated not in (None, "") else None,
            }
        )
    return res


# ----------------------------------------------------------------------- процессы
MARKERS = [
    ("opencode", ["opencode"]),
    ("watchdog", ["mcp-watchdog.ps1"]),
    ("guardian", ["mcp-watchdog-guardian"]),
    ("monitor", ["infra-graph.ps1"]),
    ("tray", ["opencode-monitor.ps1"]),
    ("local-llm", ["llm_mcp_server.py"]),
    ("firecrawl", ["firecrawl-mcp"]),
    ("MCP_DOCKER", ["mcp gateway run"]),
    ("ollama", ["ollama"]),
    ("browsertool", ["driver.mjs"]),
    ("docker", ["Docker Desktop.exe", "com.docker.backend"]),
    ("node", ["node.exe"]),
    ("lab100", ["lab100"]),
]


def collect_processes():
    result = {}
    try:
        import psutil

        procs = list(
            psutil.process_iter(
                ["pid", "ppid", "name", "cmdline", "create_time", "memory_info"]
            )
        )
        # Первый вызов cpu_percent инициализирует счётчик, второй даёт реальное значение.
        for p in procs:
            try:
                p.cpu_percent(None)
            except Exception:
                pass
        time.sleep(0.15)
        for p in procs:
            try:
                info = p.info
                cmd = " ".join(info.get("cmdline") or [])
                low = cmd.lower()
                for key, markers in MARKERS:
                    if any(m.lower() in low for m in markers):
                        entry = result.setdefault(
                            key,
                            {"count": 0, "pids": [], "rss_mb": 0.0, "cpu_percent": 0.0, "samples": []},
                        )
                        rss = (info.get("memory_info").rss if info.get("memory_info") else 0) / 2**20
                        cpu = p.cpu_percent(None)
                        entry["count"] += 1
                        entry["pids"].append(info["pid"])
                        entry["rss_mb"] += rss
                        entry["cpu_percent"] += cpu
                        entry["samples"].append(
                            {
                                "pid": info["pid"],
                                "ppid": info.get("ppid"),
                                "name": info.get("name"),
                                "rss_mb": round(rss, 1),
                                "cpu_percent": round(cpu, 1),
                                "cmd": cmd[:220],
                            }
                        )
                        break
            except Exception:
                continue
        for key, entry in result.items():
            entry["rss_mb"] = round(entry["rss_mb"], 1)
            entry["cpu_percent"] = round(entry["cpu_percent"], 1)
            entry["samples"] = sorted(
                entry["samples"], key=lambda x: x["rss_mb"], reverse=True
            )[:4]
    except ImportError:
        result["error"] = "psutil не установлен"
    return result


# ------------------------------------------------------------------- opencode.db
def ts_seconds(v):
    """opencode хранит время и в мс, и в секундах — нормализуем к секундам."""
    try:
        f = float(v or 0)
    except Exception:
        return 0.0
    if f > 1e12:
        return f / 1000.0
    return f


def model_name(raw):
    if not raw:
        return ""
    if isinstance(raw, str) and raw.startswith("{"):
        try:
            return json.loads(raw).get("id", raw)
        except Exception:
            return raw[:60]
    return str(raw)[:60]


def collect_opencode(db_path, window_min=30):
    out = {
        "db": str(db_path),
        "available": db_path.exists(),
        "sourceTables": {},
        "sessions_total": 0,
        "sessions_recent": 0,
        "subagents_total": 0,
        "subagents_recent": 0,
        "tool_calls_recent": 0,
        "active": [],
        "subagents": [],
        "tools": {},
    }
    if not db_path.exists():
        return out
    try:
        conn = sqlite3.connect("file:" + str(db_path).replace("\\", "/") + "?mode=ro", uri=True, timeout=3)
        conn.row_factory = sqlite3.Row
        tables = {r[0] for r in conn.execute("select name from sqlite_master where type='table'")}
        # Актуальные данные opencode Desktop пишет в *_v2 / session_message.
        sess_table = "session_v2" if "session_v2" in tables else "session"
        msg_table = "session_message" if "session_message" in tables else "message"
        if conn.execute('select count(*) from "%s"' % sess_table).fetchone()[0] == 0 and "session" in tables:
            sess_table = "session"
        out["sourceTables"] = {"sessions": sess_table, "messages": msg_table}

        out["sessions_total"] = conn.execute('select count(*) from "%s"' % sess_table).fetchone()[0]
        cutoff = (datetime.now() - timedelta(minutes=window_min)).timestamp()
        rows = conn.execute(
            'select id,parent_id,title,agent,model,time_updated from "%s" '
            'order by time_updated desc limit 250' % sess_table
        ).fetchall()
        for r in rows:
            upd = ts_seconds(r["time_updated"])
            if upd >= cutoff:
                out["active"].append(
                    {
                        "id": str(r["id"])[-8:],
                        "parent": (str(r["parent_id"])[-8:] if r["parent_id"] else None),
                        "title": (r["title"] or "")[:80],
                        "agent": r["agent"],
                        "model": model_name(r["model"]),
                        "updated": datetime.fromtimestamp(upd).astimezone().isoformat(timespec="seconds"),
                        "is_subagent": bool(r["parent_id"]),
                    }
                )
        out["sessions_recent"] = len(out["active"])
        out["active"] = out["active"][:12]

        sub = conn.execute(
            'select id,parent_id,title,agent,time_updated from "%s" '
            'where parent_id is not null order by time_updated desc limit 40' % sess_table
        ).fetchall()
        out["subagents_total"] = len(sub)
        for r in sub[:12]:
            upd = ts_seconds(r["time_updated"])
            out["subagents"].append(
                {
                    "id": str(r["id"])[-8:],
                    "parent": str(r["parent_id"])[-8:],
                    "agent": r["agent"] or "subagent",
                    "title": (r["title"] or "")[:60],
                    "fresh": upd >= cutoff,
                }
            )
        out["subagents_recent"] = sum(1 for s in out["subagents"] if s["fresh"])

        if msg_table == "session_message":
            msg_rows = conn.execute(
                "select data,time_updated from session_message where time_updated >= ? "
                "order by time_updated desc limit 1200",
                (int(cutoff * 1000),),
            ).fetchall()
        else:
            msg_rows = conn.execute(
                "select data,time_updated from message where time_updated >= ? "
                "order by time_updated desc limit 1200",
                (int(cutoff * 1000),),
            ).fetchall()
        tool_re = re.compile(r'"(?:tool|toolName|name)"\s*:\s*"([^"]{1,60})"')
        skip = {"text", "reasoning", "step-start", "step-finish", "tool"}
        for mr in msg_rows:
            try:
                data = json.loads(mr["data"])
            except Exception:
                continue
            names = []
            content = data.get("content") if isinstance(data, dict) else None
            if isinstance(content, list):
                names = [
                    c.get("name") for c in content
                    if isinstance(c, dict) and c.get("type") == "tool" and c.get("name")
                ]
            if not names:
                names = tool_re.findall(json.dumps(data, ensure_ascii=False))
            for name in names:
                if not name or name.lower() in skip:
                    continue
                out["tools"][name] = out["tools"].get(name, 0) + 1
                out["tool_calls_recent"] += 1
        conn.close()
    except Exception as exc:
        out["error"] = str(exc)
    return out


# --------------------------------------------------------------------- провайдеры
def collect_providers(tools_root, state_dir):
    env_keys = [
        "OPENROUTER_API_KEY",
        "ANTHROPIC_API_KEY",
        "OPENAI_API_KEY",
        "GOOGLE_API_KEY",
        "GEMINI_API_KEY",
        "GROQ_API_KEY",
        "MISTRAL_API_KEY",
        "CEREBRAS_API_KEY",
        "FIRECRAWL_API_KEY",
        "YANDEX_SEARCH_API_KEY",
        "EXA_API_KEY",
        "MISTRAL_API_KEY",
        "OCRSPACE_API_KEY",
    ]
    keys = {k: ("set" if os.environ.get(k) or user_env(k) else "absent") for k in sorted(set(env_keys))}
    gordon_chat = read_json(tools_root / "state" / "gordon-chat.json", {}) or {}
    gproviders = []
    for p in (tools_root / "registry" / "gordon").glob("*/gordon-providers.json"):
        gproviders = read_json(p, []) or []
        break
    router = []
    for gp in gproviders:
        router.append(
            {
                "name": gp.get("name"),
                "model": gp.get("model"),
                "key": gp.get("env"),
                "available": keys.get(gp.get("env", ""), "absent") == "set",
            }
        )

    ollama = cached("ollama", state_dir, 15, lambda: ollama_info())
    lab = cached("lab100", state_dir, 90, lambda: lab100_info(tools_root))

    fc_status = cached("firecrawl-status", state_dir, 300, lambda: firecrawl_status())

    blocks = []
    for path in [
        tools_root / "gordon" / "state" / "gordon-router.log",
        tools_root / "state" / "gordon-chat.json",
        Path(os.environ.get("INVR_LOG_DIR", str(tools_root.parent / "Logs"))) / "mcp-watchdog.log",
    ]:
        try:
            if path.exists():
                text = path.read_text(encoding="utf-8", errors="replace")[-120000:]
                for kw, label in (
                    ("unsupported model", "unsupported model"),
                    ("rate limit", "rate-limit"),
                    ("429", "HTTP 429"),
                    ("403", "HTTP 403"),
                    ("geo", "геоблок"),
                    ("blocked", "blocked"),
                ):
                    if kw.lower() in text.lower():
                        blocks.append({"source": path.name, "reason": label})
        except Exception:
            continue

    return {
        "keys": keys,
        "gordon": {
            "session_id": gordon_chat.get("session_id"),
            "updated_at": gordon_chat.get("updated_at"),
        },
        "router": router,
        "ollama": ollama,
        "lab100": lab,
        "firecrawl_status": fc_status,
        "blockedHints": blocks[:20],
    }


def user_env(name):
    try:
        import winreg

        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as k:
            v, _ = winreg.QueryValueEx(k, name)
            return bool(v)
    except Exception:
        return False


def firecrawl_status():
    ok, txt = run_cmd(["firecrawl", "--status"], timeout=6)
    return txt[:400] if ok else ("недоступно: " + txt[:120])


def ollama_info():
    models, running = [], []
    ok, txt = run_cmd(["ollama", "list"], timeout=6)
    if ok:
        models = [line.split()[0] for line in txt.splitlines()[1:] if line.strip()][:20]
    ok, txt = run_cmd(["ollama", "ps"], timeout=6)
    if ok:
        running = [line.split()[0] for line in txt.splitlines()[1:] if line.strip()][:20]
    return {"models": models, "running": running}


def lab100_info(tools_root):
    root = None
    env_root = os.environ.get("INVR_LAB100_ROOT") or user_env_path("INVR_LAB100_ROOT")
    if env_root and Path(env_root).exists():
        root = Path(env_root)
    else:
        for cand in (tools_root.parent / "Lab100", tools_root / "Lab100"):
            if cand.exists() and (cand / "lab100").exists():
                root = cand
                break
    if not root:
        return {"available": False, "reason": "каталог Lab100 не найден", "steps": []}
    env = os.environ.copy()
    env["PYTHONUTF8"] = "1"
    env["PYTHONIOENCODING"] = "utf-8"
    try:
        p = subprocess.run(
            [sys.executable, "-m", "lab100.cli", "status"],
            cwd=str(root), env=env, capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=15,
        )
        txt = (p.stdout or "") + (p.stderr or "")
        return {
            "available": p.returncode == 0,
            "root": str(root),
            "status": txt[:600],
            "steps": ["firecrawl", "exa", "local-browser", "plain-http", "yandex-search"],
            "llm_cascade": ["ollama:3b", "ollama:8b", "gemini-3.6-flash"],
        }
    except Exception as exc:
        return {"available": False, "root": str(root), "reason": str(exc), "steps": []}


def user_env_path(name):
    try:
        import winreg

        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as k:
            v, _ = winreg.QueryValueEx(k, name)
            return str(v)
    except Exception:
        return None


# ------------------------------------------------------------------- граф узлов
def base_node(nid, label, ntype, **kwargs):
    n = {
        "id": nid,
        "label": label,
        "type": ntype,
        "state": kwargs.get("state", "unknown"),
        "intent": kwargs.get("intent", "auto"),
        "owner": kwargs.get("owner", ""),
        "nodeClass": kwargs.get("nodeClass", ""),
        "val": kwargs.get("val"),
        "pid": kwargs.get("pid", ""),
        "detail": kwargs.get("detail", ""),
        "source": kwargs.get("source", ""),
        "lastSeen": kwargs.get("lastSeen", ""),
    }
    n["color"] = STATE_COLORS.get(n["state"], STATE_COLORS["unknown"])
    return n


def build_graph(snapshot):
    nodes, edges = [], []
    wd = snapshot["sources"]["watchdog"].get("checks") or {}
    mon = snapshot["sources"]["monitor"].get("nodes") or {}
    procs = snapshot["processes"]
    octrl = snapshot["opencode"]

    # Базовый слой — всё, что знает монитор.
    for nid, m in mon.items():
        state = str(m.get("State") or "unknown").lower()
        if state == "busy":
            state = "active"
        nodes.append(
            base_node(
                nid,
                nid,
                node_type_for(nid),
                state=state,
                intent=str(m.get("Intent") or "auto"),
                owner=str(m.get("Owner") or ""),
                nodeClass=str(m.get("Class") or ""),
                val=m.get("Val"),
                pid=str(m.get("Pid") or ""),
                detail="IdleSec=%s; Err=%s; Fault=%s" % (
                    m.get("IdleSec"), m.get("Err"), m.get("Fault")
                ),
                source="monitor/nodes.json",
                lastSeen=str(m.get("LastReply") or ""),
            )
        )

    # Обогащение от демона-стража (актуальнее монитора).
    for nid, c in wd.items():
        existing = next((n for n in nodes if n["id"] == nid), None)
        state = str(c.get("state") or "unknown").lower()
        data = dict(
            state=state,
            intent=str(c.get("intent") or "auto"),
            owner=str(c.get("owner") or ""),
            nodeClass=str(c.get("class") or ""),
            val=c.get("val"),
            detail=str(c.get("detail") or ""),
            source="watchdog/current.json",
            lastSeen=str(c.get("lastCheckAt") or ""),
        )
        if existing:
            existing.update(data)
            existing["color"] = STATE_COLORS.get(state, STATE_COLORS["unknown"])
        else:
            nodes.append(base_node(nid, nid, node_type_for(nid), **data))

    # Процессы, которые монитор не знает (трей, драйвер и т.п.).
    if "tray" not in {n["id"] for n in nodes} and procs.get("tray"):
        nodes.append(
            base_node(
                "tray", "tray (opencode-monitor)", "ui", state="active",
                owner="guardian", pid=",".join(str(x) for x in procs["tray"]["pids"][:5]),
                detail="opencode-monitor.ps1 -TrayOnly", source="psutil", lastSeen=snapshot["collectedAt"],
            )
        )

    # Ресурсы железа как узлы.
    hw = snapshot["hardware"]
    cpu_pct = hw.get("cpu", {}).get("percent")
    nodes.append(base_node("host", "Хост / Windows", "resource", state="active", detail=hw.get("os", {}).get("system", ""), source="psutil"))
    nodes.append(base_node("cpu", "CPU", "resource", state=load_state(cpu_pct), val="%s%%" % cpu_pct, detail="ядер: %s/%s" % (hw.get("cpu", {}).get("logical"), hw.get("cpu", {}).get("physical")), source="psutil"))
    mem = hw.get("memory", {})
    nodes.append(base_node("memory", "RAM", "resource", state=load_state(mem.get("percent"), invert=True), val="%s%%" % mem.get("percent"), detail="свободно %s ГБ из %s ГБ" % (mem.get("available_gb"), mem.get("total_gb")), source="psutil"))
    for i, g in enumerate(hw.get("gpu", []) or []):
        nodes.append(base_node("gpu-%d" % i, str(g.get("name") or "GPU %d" % i)[:36], "resource", state="active" if not g.get("error") else "fault", val=("%s%%" % g["gpu_percent"]) if g.get("gpu_percent") is not None else "?", detail="VRAM %s ГБ; выделено %s МБ" % (g.get("vram_gb"), g.get("dedicated_mb")), source="WMI/Get-Counter"))
    for d in hw.get("disks", []) or []:
        name = "disk-" + d["mount"].replace(":", "").replace("\\", "")
        nodes.append(base_node(name, "Диск %s" % d["mount"], "resource", state=load_state(d.get("percent"), invert=True), val="%s%%" % d["percent"], detail="свободно %s ГБ из %s ГБ" % (d.get("free_gb"), d.get("total_gb")), source="psutil"))
        if "C:" in d["mount"]:
            disk_c = d

    # Сессии opencode и субагенты.
    for s in octrl.get("active", [])[:8]:
        if s.get("is_subagent"):
            continue
        nodes.append(base_node("sess-" + s["id"], "сессия " + s["id"], "session", state="active", val=s.get("model"), detail=(s.get("title") or "")[:70], source="opencode.db", lastSeen=s.get("updated")))
    for a in octrl.get("subagents", [])[:8]:
        state = "active" if a.get("fresh") else "idle"
        nodes.append(base_node("sub-" + a["id"], a["agent"], "subagent", state=state, owner="invr-lead" if a["agent"].startswith("invr") else "opencode", detail="родитель " + str(a.get("parent")), source="opencode.db"))

    # Плагины opencode (по факту наличия файлов).
    plugins_dir = Path(os.environ.get("INVR_PLUGINS_DIR", str(Path.home() / ".config" / "opencode" / "plugin")))
    for pf in sorted(plugins_dir.glob("*.js"))[:10]:
        nodes.append(base_node("plugin-" + pf.stem, pf.stem, "plugin", state="active", detail=str(pf), source="filesystem"))

    # Загруженные модели ollama.
    for m in (snapshot["providers"].get("ollama") or {}).get("running", [])[:8]:
        nodes.append(base_node("model-" + re.sub(r"[^a-z0-9]+", "-", m.lower()), m, "model", state="active", owner="ollama", detail="загружена в память", source="ollama ps"))

    # Рёбра — потоки управления/данных.
    def edge(a, b, kind, label="", hot=False):
        if any(n["id"] == a for n in nodes) and any(n["id"] == b for n in nodes):
            edges.append({"source": a, "target": b, "kind": kind, "label": label, "hot": hot})

    edge("guardian", "watchdog", "control", "надзор/перезапуск")
    edge("guardian", "monitor", "control", "надзор")
    edge("guardian", "tray", "control", "трей")
    edge("watchdog", "run-watch", "control", "reaper (сироты)")
    for target in ("local-llm", "firecrawl", "MCP_DOCKER", "ollama", "browsertool", "invr-stack", "docker"):
        edge("watchdog", target, "control", "проверка/автоподъём")
    edge("monitor", "watchdog", "data", "current.json")
    edge("guardian", "monitor", "data", "nodes.mirror.json")

    hot_tools = octrl.get("tools") or {}
    for target in ("local-llm", "firecrawl", "MCP_DOCKER"):
        hot = any(k in target or target.split("-")[0] in k.lower() for k in hot_tools)
        edge("oc", target, "call", "MCP-вызов", hot)
    edge("oc", "ollama", "call", "локальные модели")
    edge("oc", "gordon", "call", "роутер провайдеров")
    edge("oc", "lab", "call", "пул ИИ")
    edge("oc", "invr", "call", "делегирование task")
    for s in octrl.get("active", [])[:8]:
        if not s.get("is_subagent"):
            edge("oc", "sess-" + s["id"], "session", "активная сессия")
    for a in octrl.get("subagents", [])[:8]:
        edge("invr", "sub-" + a["id"], "task", a["agent"])

    edge("oc", "plugin-status-banner", "event", "строка статусов")
    edge("watchdog", "plugin-status-banner", "data", "current.json")
    edge("gordon", "openrouter", "route", "каскад")
    edge("gordon", "cloud", "route", "провайдеры")
    edge("lab", "firecrawl", "fallback", "поиск")
    edge("lab", "ollama", "fallback", "LLM")
    edge("lab", "browsertool", "fallback", "local-browser")
    for m in (snapshot["providers"].get("ollama") or {}).get("running", [])[:8]:
        edge("ollama", "model-" + re.sub(r"[^a-z0-9]+", "-", m.lower()), "load", "в VRAM/RAM")
    edge("host", "cpu", "host", "")
    edge("host", "memory", "host", "")
    edge("host", "gpu-0", "host", "")
    for d in hw.get("disks", []) or []:
        edge("host", "disk-" + d["mount"].replace(":", "").replace("\\", ""), "host", "")

    # Рёбра для инструментов и плагинов, которых нет в потоках монитора.
    explicit_edges = (
        ("oc", "ai-provider-check", "call", "проверка провайдеров"),
        ("rollback", "backup-util", "control", "копирование оригиналов"),
        ("oc", "backup-util", "call", "создание копий"),
        ("dmr-router", "dmr-model", "data", "маршрутизация моделей"),
        ("oc", "dmr-router", "call", "выбор модели"),
        ("oc", "doc-extract", "call", "извлечение документов"),
        ("doc-extract", "ollama", "fallback", "судья/локальная модель"),
        ("oc", "fab-prov", "call", "фабрика провайдеров"),
        ("oc", "factory", "call", "фабрика задач"),
        ("factory", "factory-mon", "control", "надзор фабрики"),
        ("firecrawl-key", "firecrawl", "control", "ключ доступа"),
        ("oc", "gh", "call", "репозитории"),
        ("oc", "janitor", "call", "уборка"),
        ("oc", "layr", "call", "слой автоматизации"),
        ("oc", "resolve-tools", "call", "резолвер инструментов"),
        ("oc", "rollback", "call", "каталог откатов"),
        ("rollback", "gh", "data", "журнал изменений"),
        ("oc", "system-map", "call", "снимок карты"),
        ("system-map", "watchdog", "data", "current.json"),
        ("system-map", "monitor", "data", "nodes.json"),
        ("oc", "vmdisk", "call", "виртуальные диски"),
        ("host", "gpu-1", "host", ""),
        ("guardian", "opencode-monitor", "control", "надзор трея"),
        ("oc", "orch-metrics", "call", "метрики оркестрации"),
        ("ollama-prov", "ollama", "control", "провайдер моделей"),
        ("oc", "plugin-encoding-utf8", "event", "кодировка вывода"),
        ("oc", "plugin-language-ru", "event", "языковые правила"),
        ("oc", "plugin-utf8-console", "event", "консоль UTF-8"),
    )
    for source, target, kind, label in explicit_edges:
        edge(source, target, kind, label)

    # Гарантия: ни один узел не остаётся без связи при изменении снимка.
    degree = {n["id"]: 0 for n in nodes}
    for e in edges:
        if e["source"] in degree:
            degree[e["source"]] += 1
        if e["target"] in degree:
            degree[e["target"]] += 1
    hubs = {
        "plugin": "oc", "session": "oc", "tool": "oc", "subagent": "oc",
        "resource": "host", "mcp": "watchdog", "service": "watchdog",
        "model": "ollama",
    }
    node_ids = {n["id"] for n in nodes}
    for n in nodes:
        if degree[n["id"]]:
            continue
        hub = hubs.get(n["type"], "oc")
        if hub not in node_ids:
            hub = next((h for h in ("oc", "watchdog", "host", "ollama") if h in node_ids), None)
        if not hub or hub == n["id"]:
            hub = next((x for x in node_ids if x != n["id"]), None)
        if not hub:
            continue
        edge(n["id"], hub, "link", "связь")
        degree[n["id"]] += 1
        degree[hub] += 1

    snapshot["nodes"] = nodes
    snapshot["edges"] = edges
    return snapshot


def isolated_count(nodes, edges):
    connected = set()
    for e in edges:
        connected.add(e["source"])
        connected.add(e["target"])
    return sum(1 for n in nodes if n["id"] not in connected)


def node_type_for(nid):
    if nid in ("guardian", "watchdog", "monitor", "oc"):
        return "core"
    if nid in ("local-llm", "firecrawl", "MCP_DOCKER", "browsertool", "run-watch", "doc-extract"):
        return "mcp"
    if nid in ("ollama", "docker", "lab", "gordon", "cloud", "rollback", "gh", "janitor"):
        return "service"
    if nid in ("openrouter", "invr", "fab-prov"):
        return "agent"
    if nid.startswith("plugin-"):
        return "plugin"
    if nid.startswith("sess-"):
        return "session"
    if nid.startswith("sub-"):
        return "subagent"
    if nid.startswith("model-"):
        return "model"
    return "tool"


def load_state(pct, invert=False):
    if pct is None:
        return "unknown"
    try:
        p = float(pct)
    except Exception:
        return "unknown"
    if invert:
        p = 100 - p
    if p >= 90:
        return "fault"
    if p >= 75:
        return "need-guard"
    if p >= 40:
        return "active"
    return "idle"


# ------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tools-root", default=str(DEFAULT_TOOLS))
    ap.add_argument("--state-dir", default="")
    ap.add_argument("--db", default="")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--no-state", action="store_true")
    args = ap.parse_args()

    tools_root = Path(args.tools_root)
    state_dir = Path(args.state_dir) if args.state_dir else tools_root / "system-map" / "state"
    state_dir.mkdir(parents=True, exist_ok=True)

    started = time.time()
    db = Path(args.db) if args.db else Path(
        os.environ.get("INVR_OPENCODE_DB")
        or str(Path.home() / ".local" / "share" / "opencode" / "opencode.db")
    )

    wd = read_json(tools_root / "mcp-watchdog" / "state" / "current.json", {}) or {}
    mon = read_json(tools_root / "monitor" / "state" / "nodes.json", {}) or {}
    guardian = read_json(tools_root / "mcp-watchdog-guardian" / "state" / "current.json", {}) or {}
    gpid = read_json(tools_root / "mcp-watchdog-guardian" / "state" / "guardian.pid", None)
    runwatch = read_json(tools_root / "run-watch" / "state" / "run-watch.json", {}) or {}

    snapshot = {
        "schema": SCHEMA,
        "collectedAt": now_iso(),
        "toolsRoot": str(tools_root),
        "hardware": collect_hardware(state_dir),
        "processes": collect_processes(),
        "opencode": collect_opencode(db),
        "providers": collect_providers(tools_root, state_dir),
        "sources": {
            "watchdog": wd,
            "monitor": mon,
            "guardian": guardian,
            "guardianPid": gpid,
            "runwatch": runwatch,
        },
        "meta": {},
    }
    build_graph(snapshot)

    states = {}
    for n in snapshot["nodes"]:
        states[n["state"]] = states.get(n["state"], 0) + 1
    snapshot["stats"] = {
        "nodes": len(snapshot["nodes"]),
        "edges": len(snapshot["edges"]),
        "isolated": isolated_count(snapshot["nodes"], snapshot["edges"]),
        "states": states,
        "openTickets": len(wd.get("openTickets") or []),
        "cpuPercent": snapshot["hardware"].get("cpu", {}).get("percent"),
        "memPercent": snapshot["hardware"].get("memory", {}).get("percent"),
    }
    snapshot["meta"] = {
        "collectMs": int((time.time() - started) * 1000),
        "colors": STATE_COLORS,
    }

    if not args.no_state:
        write_json_atomic(state_dir / "snapshot.json", snapshot)
    text = json.dumps(snapshot, ensure_ascii=False, default=str)
    if args.json:
        print(text)
    else:
        print("system-map: %s узлов, %s связей, %s тикетов; CPU %s%%, RAM %s%%" % (
            snapshot["stats"]["nodes"], snapshot["stats"]["edges"],
            snapshot["stats"]["openTickets"], snapshot["stats"]["cpuPercent"], snapshot["stats"]["memPercent"]
        ))
    return 0


if __name__ == "__main__":
    sys.exit(main())
