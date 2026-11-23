"""delegation-lint — жёсткая проверка правила делегирования opencode.

Данные (строго только чтение):
  - %USERPROFILE%\\.local\\share\\opencode\\opencode.db (SQLite: session/message/part, режим mode=ro);
  - <tools>\\mcp-watchdog\\state\\current.json — признак живого ollama.

Схема opencode.db:
  session(id, parent_id, agent, tokens_input, time_created, ...)
  message(id, session_id, time_created, data JSON{role, agent, ...})
  part(id, message_id, session_id, time_created, data JSON{type:'tool', tool, state{input}})

Коды возврата: 0 — нарушений нет, 1 — есть нарушения, 2 — БД недоступна, 3 — сбой.
Канон инструмента: tools/registry/delegation-lint/<version>.
"""
import argparse
import json
import os
import sqlite3
import sys
import tempfile
import time
from collections import Counter, defaultdict

TOOL_NAME = "delegation-lint"
TOOL_VERSION = "0.1.0"

# Первый совпавший канал забирает вызов — нет двойного счёта.
PROVIDERS = (
    ("lab100", ("lab100", "lab_100")),
    ("doc-extract", ("doc-extract", "docextract")),
    ("firecrawl", ("firecrawl",)),
    ("local-llm", ("local-llm", "local_llm", "ollama", "hermes3")),
    ("browsertool", ("browsertool", "driver.mjs")),
    ("gordon", ("gordon", "docker agent", "model runner")),
    ("gemini", ("gemini",)),
    ("openrouter", ("openrouter",)),
    ("yandex", ("yandex",)),
    ("exa", ("exa",)),
)
OTHER = "other"
PAID = ("gordon", "gemini", "openrouter", "yandex", "exa")


class DbUnavailable(Exception):
    pass


def tools_root():
    env = os.environ.get("INVR_TOOLS_ROOT")
    if env and os.path.isdir(env):
        return env
    return os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))


def default_db_path():
    env = os.environ.get("INVR_OPENCODE_DB")
    if env:
        return env
    candidates = [
        os.path.join(os.path.expanduser("~"), ".local", "share", "opencode", "opencode.db"),
        os.path.join(os.environ.get("LOCALAPPDATA", ""), "opencode", "opencode.db"),
    ]
    for c in candidates:
        if os.path.isfile(c):
            return c
    return candidates[0]


def read_json(path):
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_atomic(path, text):
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".delegation-lint-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def share(num, den):
    return (num / den) if den else 0.0


def plural(n, one, few, many):
    n = abs(int(n))
    if n % 10 == 1 and n % 100 != 11:
        return one
    if 2 <= n % 10 <= 4 and not (12 <= n % 100 <= 14):
        return few
    return many


def match_provider(text):
    for name, needles in PROVIDERS:
        if any(n in text for n in needles):
            return name
    return OTHER


def connect_ro(db_path):
    if not db_path or not os.path.isfile(db_path):
        raise DbUnavailable("БД opencode не найдена: %s" % (db_path or "<пусто>"))
    try:
        uri = "file:" + db_path.replace("\\", "/") + "?mode=ro"
        con = sqlite3.connect(uri, uri=True)
        con.execute("PRAGMA query_only=ON")
        con.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='table'").fetchone()
        return con
    except sqlite3.Error as e:
        raise DbUnavailable("БД opencode недоступна (%s): %s" % (db_path, e))


def collect(db_path, sessions_n):
    con = connect_ro(db_path)
    try:
        cur = con.cursor()
        rows = cur.execute(
            "SELECT id, parent_id, agent, time_created FROM session "
            "ORDER BY time_created DESC LIMIT ?",
            (sessions_n,),
        ).fetchall()
        sess = {}
        for sid, parent_id, agent, t in rows:
            sess[sid] = {
                "parent_id": parent_id,
                "agent": agent or "unknown",
                "time_created": t or 0,
            }
        if not sess:
            raise DbUnavailable("в БД нет ни одной сессии: %s" % db_path)

        ids = list(sess)
        ph = ",".join("?" * len(ids))
        role_of = {}
        sess_msgs = defaultdict(list)
        for mid, s_id, t, data in cur.execute(
            "SELECT id, session_id, time_created, data FROM message WHERE session_id IN (%s)" % ph, ids
        ):
            try:
                j = json.loads(data)
            except (ValueError, TypeError):
                continue
            role_of[mid] = j.get("role")
            sess_msgs[s_id].append((t or 0, mid))

        calls_by_agent = Counter()
        tool_per_session = defaultdict(Counter)
        turn_calls = defaultdict(Counter)
        provider_args = {name: 0 for name, _ in PROVIDERS}
        provider_args[OTHER] = 0
        calls_with_args = 0

        for s_id, mid, data in cur.execute(
            "SELECT session_id, message_id, data FROM part WHERE session_id IN (%s)" % ph, ids
        ):
            try:
                j = json.loads(data)
            except (ValueError, TypeError):
                continue
            if j.get("type") != "tool":
                continue
            tool = j.get("tool") or "unknown"
            calls_by_agent[sess[s_id]["agent"]] += 1
            tool_per_session[s_id][tool] += 1
            turn_calls[mid][tool] += 1

            args = (j.get("state") or {}).get("input")
            if not isinstance(args, dict) or not args:
                continue
            calls_with_args += 1
            text = json.dumps(args, ensure_ascii=False).lower()
            provider_args[match_provider(text)] += 1

        return {
            "sessions": sess,
            "role_of": role_of,
            "sess_msgs": sess_msgs,
            "calls_by_agent": calls_by_agent,
            "tool_per_session": tool_per_session,
            "turn_calls": turn_calls,
            "provider_args": provider_args,
            "calls_with_args": calls_with_args,
        }
    finally:
        con.close()


def cycle_stats(data, cycle_min_calls):
    """Цикл = один пользовательский запрос и все вызовы до следующего запроса."""
    role_of = data["role_of"]
    turn_calls = data["turn_calls"]
    totals, has_task_flags = [], []

    for s_id, seq in data["sess_msgs"].items():
        seq.sort()
        total, has_task = 0, False
        for _t, mid in seq:
            role = role_of.get(mid)
            if role == "user":
                if total:
                    totals.append(total)
                    has_task_flags.append(has_task)
                total, has_task = 0, False
            elif role == "assistant":
                total += sum(turn_calls[mid].values()) if mid in turn_calls else 0
                has_task = has_task or turn_calls[mid].get("task", 0) > 0
        if total:
            totals.append(total)
            has_task_flags.append(has_task)

    long_cycles = sum(1 for t in totals if t >= cycle_min_calls)
    long_no_task = sum(
        1 for t, has_task in zip(totals, has_task_flags)
        if t >= cycle_min_calls and not has_task
    )
    return {
        "count": len(totals),
        "long_calls_min": cycle_min_calls,
        "long": long_cycles,
        "long_no_task": long_no_task,
        "long_no_task_share": share(long_no_task, long_cycles),
        "without_task": sum(1 for h in has_task_flags if not h),
        "without_task_share": share(sum(1 for h in has_task_flags if not h), len(totals)),
    }


def compute(db_path, sessions_n, watchdog_path, cycle_min_calls):
    data = collect(db_path, sessions_n)
    sess = data["sessions"]
    calls_total = sum(data["calls_by_agent"].values())
    build_calls = data["calls_by_agent"].get("build", 0)

    task_calls = sum(c.get("task", 0) for c in data["tool_per_session"].values())
    sessions_with_task = sum(1 for c in data["tool_per_session"].values() if c.get("task", 0) > 0)

    lead_ids = {sid for sid, s in sess.items() if s["agent"] == "invr-lead"}
    lead_children = sum(1 for s in sess.values() if s["parent_id"] in lead_ids)
    provider_args = data["provider_args"]
    paid_calls = sum(provider_args.get(k, 0) for k in PAID)

    wd = read_json(watchdog_path) or {}
    ollama_ok = ((wd.get("checks") or {}).get("ollama") or {}).get("status") == "ok"

    times = [s["time_created"] for s in sess.values() if s["time_created"]]
    metrics = {
        "sessions": len(sess),
        "sessions_requested": sessions_n,
        "window": {
            "from": (min(times) / 1000.0) if times else None,
            "to": (max(times) / 1000.0) if times else None,
        },
        "calls_total": calls_total,
        "build_calls": build_calls,
        "build_share_calls": share(build_calls, calls_total),
        "task_calls": task_calls,
        "sessions_with_task": sessions_with_task,
        "share_task": share(sessions_with_task, len(sess)),
        "cycles": cycle_stats(data, cycle_min_calls),
        "invr_lead_sessions": len(lead_ids),
        "invr_lead_children": lead_children,
        "invr_lead_avg_children": share(lead_children, len(lead_ids)),
        "paid_calls": paid_calls,
        "calls_with_args": data["calls_with_args"],
        "paid_share": share(paid_calls, data["calls_with_args"]),
    }
    return metrics, ollama_ok


def check(metrics, ollama_ok, limits):
    violations = []

    def add(rule, value, op, limit, text, severity="high"):
        violations.append({
            "rule": rule,
            "value": round(value, 4),
            "condition": "%s %s" % (op, limit),
            "limit": limit,
            "text": text,
            "severity": severity,
        })

    v = metrics["build_share_calls"]
    if v > limits["BuildShareMax"]:
        add("build_share_high", v, ">", limits["BuildShareMax"],
            "Доля вызовов build %.1f%% выше порога %.1f%%: передавать длинные циклы диспетчеру invr-lead."
            % (v * 100, limits["BuildShareMax"] * 100))

    v = metrics["share_task"]
    if v < limits["ShareTaskMin"]:
        add("share_task_low", v, "<", limits["ShareTaskMin"],
            "Делегирование почти не используется: task в %d из %d сессий; проверять цепочку build → invr-lead → invr-*."
            % (metrics["sessions_with_task"], metrics["sessions"]))

    c = metrics["cycles"]
    v = c["long_no_task_share"]
    if v > limits["CyclesNoTaskMax"]:
        add("cycles_no_task_high", v, ">", limits["CyclesNoTaskMax"],
            "Из %d %s по ≥%d вызовов %d (%.0f%%) выполнены без task — порог делегирования не срабатывает."
            % (c["long"], plural(c["long"], "цикла", "циклов", "циклов"),
               c["long_calls_min"], c["long_no_task"], v * 100))

    v = metrics["invr_lead_avg_children"]
    if v < limits["LeadChildrenMin"]:
        add("invr_lead_idle", v, "<", limits["LeadChildrenMin"],
            "Диспетчер invr-lead запускает в среднем %.2f субагента: проверить `task: allow`, "
            "`subagent_depth: 2` и убрать условие «≥8 минут» из порога делегирования."
            % v)

    v = metrics["paid_share"]
    if v > limits["PaidShareMax"] and ollama_ok:
        add("paid_share_high", v, ">", limits["PaidShareMax"],
            "Доля платных каналов %.1f%% при живом ollama выше порога %.1f%%: "
            "жёсткий бесплатный каскад lab100 → doc-extract → firecrawl → local-llm."
            % (v * 100, limits["PaidShareMax"] * 100))

    return violations


def fmt_ts(v):
    if not v:
        return "—"
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(v))


def render(report):
    m = report["metrics"]
    lim = report["thresholds"]
    c = m["cycles"]
    out = [
        "%s %s — последние %d сессий, %s вызовов" % (
            TOOL_NAME, TOOL_VERSION, m["sessions"], format(m["calls_total"], ",").replace(",", " ")),
        "окно: %s … %s | ollama: %s" % (
            fmt_ts(m["window"]["from"]), fmt_ts(m["window"]["to"]), report["context"]["ollama"]),
        "",
        "%-30s %-14s %-14s %s" % ("ПРАВИЛО", "ЗНАЧЕНИЕ", "ПОРОГ", "ВЕРДИКТ"),
        "-" * 76,
    ]
    rows = [
        ("build_share_calls", "%.3f" % m["build_share_calls"],
         "≤ %.2f" % lim["BuildShareMax"], m["build_share_calls"] <= lim["BuildShareMax"]),
        ("share_task", "%.3f" % m["share_task"],
         "≥ %.2f" % lim["ShareTaskMin"], m["share_task"] >= lim["ShareTaskMin"]),
        ("cycles_ge_%d_no_task_share" % c["long_calls_min"], "%.3f" % c["long_no_task_share"],
         "≤ %.2f" % lim["CyclesNoTaskMax"], c["long_no_task_share"] <= lim["CyclesNoTaskMax"]),
        ("invr_lead_avg_children", "%.2f" % m["invr_lead_avg_children"],
         "≥ %.2f" % lim["LeadChildrenMin"], m["invr_lead_avg_children"] >= lim["LeadChildrenMin"]),
        ("paid_share", "%.3f" % m["paid_share"],
         "≤ %.2f%s" % (lim["PaidShareMax"], "" if report["context"]["ollama"] == "жив" else " (ollama не жива)"),
         m["paid_share"] <= lim["PaidShareMax"] or report["context"]["ollama"] != "жив"),
    ]
    for rule, value, limit, ok in rows:
        out.append("%-30s %-14s %-14s %s" % (rule, value, limit, "ок" if ok else "НАРУШЕНИЕ"))

    out.append("")
    out.append("циклов ≥%d вызовов: %d, без task: %d | invr-lead: %d сессий, %d детей" % (
        c["long_calls_min"], c["long"], c["long_no_task"],
        m["invr_lead_sessions"], m["invr_lead_children"]))
    out.append("")
    out.append("=== Нарушения: %d ===" % len(report["violations"]))
    if not report["violations"]:
        out.append("правило делегирования соблюдено — правки конфигурации не требуются.")
    for i, item in enumerate(report["violations"], 1):
        out.append("[%d] %s (важность: %s)" % (i, item["rule"], item["severity"]))
        out.append("    значение %s, условие %s" % (item["value"], item["condition"]))
        out.append("    действие: %s" % item["text"])
    out.append("")
    out.append("ИТОГ: %s (код возврата %d)" % (
        "нарушения есть" if report["violations"] else "нарушений нет",
        report["summary"]["exitCode"]))
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="delegation_lint.py",
        description="Жёсткая проверка правила делегирования opencode (только чтение БД).")
    ap.add_argument("--sessions", type=int, default=50)
    ap.add_argument("--build-share-max", type=float, default=0.6)
    ap.add_argument("--share-task-min", type=float, default=0.1)
    ap.add_argument("--cycles-no-task-max", type=float, default=0.25)
    ap.add_argument("--lead-children-min", type=float, default=1.0)
    ap.add_argument("--paid-share-max", type=float, default=0.3)
    ap.add_argument("--cycle-min-calls", type=int, default=20)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--out", default="")
    ap.add_argument("--db", default="")
    ap.add_argument("--watchdog", default="")
    args = ap.parse_args(argv)

    root = tools_root()
    db_path = args.db or default_db_path()
    watchdog_path = args.watchdog or os.path.join(root, "mcp-watchdog", "state", "current.json")
    limits = {
        "BuildShareMax": args.build_share_max,
        "ShareTaskMin": args.share_task_min,
        "CyclesNoTaskMax": args.cycles_no_task_max,
        "LeadChildrenMin": args.lead_children_min,
        "PaidShareMax": args.paid_share_max,
        "CycleMinCalls": args.cycle_min_calls,
    }
    n = args.sessions if args.sessions > 0 else 50

    try:
        metrics, ollama_ok = compute(db_path, n, watchdog_path, args.cycle_min_calls)
    except DbUnavailable as e:
        print("%s: %s" % (TOOL_NAME, e), file=sys.stderr)
        return 2
    except (sqlite3.Error, OSError, ValueError) as e:
        print("%s: сбой разбора данных: %s" % (TOOL_NAME, e), file=sys.stderr)
        return 3

    violations = check(metrics, ollama_ok, limits)
    exit_code = 1 if violations else 0
    report = {
        "schema": "inrv.delegation-lint/1",
        "tool": TOOL_NAME,
        "version": TOOL_VERSION,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "sources": {"db": db_path, "watchdog": watchdog_path},
        "thresholds": limits,
        "context": {"ollama": "жив" if ollama_ok else "недоступен"},
        "metrics": metrics,
        "violations": violations,
        "summary": {"ok": not violations, "violations": len(violations), "exitCode": exit_code},
    }
    text = (json.dumps(report, ensure_ascii=False, indent=2) if args.json else render(report))
    print(text)

    if args.out:
        try:
            write_atomic(args.out, text + "\n")
        except OSError as e:
            print("%s: не удалось записать %s: %s" % (TOOL_NAME, args.out, e), file=sys.stderr)
    return exit_code


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except BrokenPipeError:
        sys.exit(0)
