"""
orch-metrics — метрики распределения работы оркестратора opencode.

Измеряет, как оркестратор (build) делит работу между собой, субагентами
(invr-* / explore / general) и бесплатным пулом (Lab100, doc-extract, firecrawl,
local-llm), и выдаёт корректирующие рекомендации по порогам делегирования.

Данные (строго только чтение):
  - %USERPROFILE%\\.local\\share\\opencode\\opencode.db (SQLite: session/message/part);
  - <tools>\\mcp-watchdog\\state\\current.json — состояния узлов;
  - <tools>\\run-watch\\state\\run-watch.json — реестр запусков.

Схема opencode.db, на которую опирается инструмент:
  session(id, parent_id, agent, tokens_input, time_created, ...)
  message(id, session_id, time_created, data JSON{role, agent, ...})
  part(id, message_id, session_id, time_created, data JSON{type:'tool', tool, state{input}})

Канон инструмента живёт в реестре INVR: tools/registry/orch-metrics/<version>.
Выход: stdout (таблица либо -Json), state\\orch-metrics.json и кольцевой журнал
state\\orch-metrics.log. Коды возврата: 0 — ок, 1 — сбой, 2 — БД недоступна.
"""
import argparse
import json
import math
import os
import sqlite3
import statistics
import sys
import tempfile
import time
from collections import Counter, defaultdict

TOOL_NAME = "orch-metrics"
TOOL_VERSION = "0.1.0"
LOG_KEEP_LINES = 200

# Порядок важен: первый совпавший канал забирает вызов (нет двойного счёта).
# Совпадение ищется по тексту аргументов вызова.
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

# Целевые значения правил коррекции (см. AGENTS.md, «Слои оркестрации»).
T_BUILD_SHARE_MAX = 0.60
T_SHARE_TASK_MIN = 0.10
T_MEDIAN_TURN_MIN = 6
T_TURNS20_MAX = 0.25
T_PAID_MAX = 0.30
T_LEAD_CHILDREN_MIN = 1.0
T_TOKENS_RATIO_MIN = 1.5
T_TOKENS_RATIO_GOAL = 2.0

DELEGATION_HIGH_THRESHOLD = 20


class DbUnavailable(Exception):
    pass


# ---------------------------------------------------------------- служебное


def tools_root():
    env = os.environ.get("INVR_TOOLS_ROOT")
    if env and os.path.isdir(env):
        return env
    # Прямой запуск: <tools>\registry\orch-metrics\<version>\orch_metrics.py
    return os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))


def default_db_path():
    env = os.environ.get("INVR_OPENCODE_DB")
    if env:
        return env
    home = os.path.expanduser("~")
    candidates = [
        os.path.join(home, ".local", "share", "opencode", "opencode.db"),
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
    """Запись через временный файл + os.replace — читатель не видит полузаписи."""
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".orch-metrics-", suffix=".tmp")
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
    """Согласование существительного с числительным: 1 цикл / 2 цикла / 5 циклов."""
    n = abs(int(n))
    if n % 10 == 1 and n % 100 != 11:
        return one
    if 2 <= n % 10 <= 4 and not (12 <= n % 100 <= 14):
        return few
    return many


def percentile(sorted_vals, q):
    if not sorted_vals:
        return 0
    k = max(1, math.ceil(q * len(sorted_vals))) - 1
    return sorted_vals[min(k, len(sorted_vals) - 1)]


def match_provider(text):
    for name, needles in PROVIDERS:
        if any(n in text for n in needles):
            return name
    return OTHER


def empty_provider_counts():
    d = {name: 0 for name, _ in PROVIDERS}
    d[OTHER] = 0
    return d


def group_stats(totals, has_task_flags):
    n = len(totals)
    if not n:
        return {
            "count": 0, "median": 0, "p90": 0, "min": 0, "max": 0,
            "without_task": 0, "without_task_share": 0.0,
            "ge_20": 0, "ge_20_share": 0.0, "ge_20_without_task": 0, "ge_20_no_task_share": 0.0,
        }
    s = sorted(totals)
    without = sum(1 for t, has_task in zip(s, has_task_flags) if not has_task)
    ge20 = sum(1 for t in s if t >= DELEGATION_HIGH_THRESHOLD)
    ge20_nt = sum(1 for t, has_task in zip(s, has_task_flags) if t >= DELEGATION_HIGH_THRESHOLD and not has_task)
    return {
        "count": n,
        "median": int(statistics.median(s)),
        "p90": percentile(s, 0.9),
        "min": s[0],
        "max": s[-1],
        "without_task": without,
        "without_task_share": share(without, n),
        "ge_20": ge20,
        "ge_20_share": share(ge20, n),
        "ge_20_without_task": ge20_nt,
        "ge_20_no_task_share": share(ge20_nt, ge20),
    }


# ---------------------------------------------------------------- сбор данных


def connect_ro(db_path):
    if not db_path or not os.path.isfile(db_path):
        raise DbUnavailable("БД opencode не найдена: %s" % (db_path or "<пусто>"))
    try:
        # Режим только чтения: SQLite не создаёт и не изменяет файл/журнал.
        uri = "file:" + db_path.replace("\\", "/") + "?mode=ro"
        con = sqlite3.connect(uri, uri=True)
        con.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='table'").fetchone()
        return con
    except sqlite3.Error as e:
        raise DbUnavailable("БД opencode недоступна (%s): %s" % (db_path, e))


def collect(db_path, sessions_n):
    con = connect_ro(db_path)
    try:
        cur = con.cursor()
        rows = cur.execute(
            "SELECT id, parent_id, agent, tokens_input, time_created FROM session "
            "ORDER BY time_created DESC LIMIT ?",
            (sessions_n,),
        ).fetchall()

        sess = {}
        for sid, parent_id, agent, tokens_input, time_created in rows:
            sess[sid] = {
                "parent_id": parent_id,
                "agent": agent or "unknown",
                "tokens_input": tokens_input or 0,
                "time_created": time_created or 0,
            }
        if not sess:
            raise DbUnavailable("в БД нет ни одной сессии: %s" % db_path)

        ids = list(sess.keys())
        ph = ",".join("?" * len(ids))

        role_of = {}
        sess_msgs = defaultdict(list)
        for mid, s_id, t_created, data in cur.execute(
            "SELECT id, session_id, time_created, data FROM message WHERE session_id IN (%s)" % ph, ids
        ):
            try:
                j = json.loads(data)
            except (ValueError, TypeError):
                continue
            role_of[mid] = j.get("role")
            sess_msgs[s_id].append((t_created or 0, mid))

        calls_by_agent = Counter()
        tool_per_session = defaultdict(Counter)
        turn_calls = defaultdict(Counter)
        provider_args = empty_provider_counts()
        provider_hint = empty_provider_counts()
        calls_with_args = 0
        calls_without_args = 0

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
                calls_without_args += 1
                continue
            calls_with_args += 1
            text = json.dumps(args, ensure_ascii=False).lower()
            provider_args[match_provider(text)] += 1
            provider_hint[match_provider((tool + " " + text).lower())] += 1

        return {
            "db_path": db_path,
            "sessions": sess,
            "role_of": role_of,
            "sess_msgs": sess_msgs,
            "calls_by_agent": calls_by_agent,
            "tool_per_session": tool_per_session,
            "turn_calls": turn_calls,
            "provider_args": provider_args,
            "provider_hint": provider_hint,
            "calls_with_args": calls_with_args,
            "calls_without_args": calls_without_args,
        }
    finally:
        con.close()


# ---------------------------------------------------------------- метрики


def compute_turns(data):
    """Ход = одно сообщение ассистента, содержащее вызовы инструментов.

    Цикл = один пользовательский запрос и все ходы ассистента до следующего
    запроса. Цикл — реальная единица для порога делегирования («≥20 вызовов
    подряд» относится ко всей работе над одним запросом, а не к одному
    сообщению), поэтому считаются оба разреза.
    """
    role_of = data["role_of"]
    turn_calls = data["turn_calls"]

    turn_ids = [m for m in turn_calls if role_of.get(m) == "assistant"]
    turn_totals = [sum(turn_calls[m].values()) for m in turn_ids]
    turn_has_task = [turn_calls[m].get("task", 0) > 0 for m in turn_ids]
    turns = group_stats(turn_totals, turn_has_task)

    cyc_totals, cyc_has_task = [], []
    for s_id, seq in data["sess_msgs"].items():
        seq.sort()
        total, has_task = 0, False
        for _t_created, mid in seq:
            if role_of.get(mid) == "user":
                if total:
                    cyc_totals.append(total)
                    cyc_has_task.append(has_task)
                total, has_task = 0, False
                continue
            if role_of.get(mid) != "assistant":
                continue
            total += sum(turn_calls[mid].values()) if mid in turn_calls else 0
            has_task = has_task or turn_calls[mid].get("task", 0) > 0
        if total:
            cyc_totals.append(total)
            cyc_has_task.append(has_task)
    cycles = group_stats(cyc_totals, cyc_has_task)
    return turns, cycles


def compute(db_path, sessions_n, watchdog_path, runwatch_path):
    data = collect(db_path, sessions_n)
    sess = data["sessions"]
    by_agent = data["calls_by_agent"]
    tool_per_session = data["tool_per_session"]

    calls_total = sum(by_agent.values())
    build_calls = by_agent.get("build", 0)
    build_share = share(build_calls, calls_total)

    task_calls = sum(c.get("task", 0) for c in tool_per_session.values())
    sessions_with_task = sum(1 for c in tool_per_session.values() if c.get("task", 0) > 0)
    sessions_n_actual = len(sess)
    share_task = share(sessions_with_task, sessions_n_actual)

    sub_sessions = [s for s in sess.values() if s["parent_id"]]
    sub_calls = sum(sum(tool_per_session.get(sid, {}).values()) for sid, s in sess.items() if s["parent_id"])
    subagent_share = share(sub_calls, calls_total)

    lead_ids = {sid for sid, s in sess.items() if s["agent"] == "invr-lead"}
    lead_children = sum(1 for s in sess.values() if s["parent_id"] in lead_ids)
    lead_avg = share(lead_children, len(lead_ids))

    input_build = sum(s["tokens_input"] for s in sess.values() if s["agent"] == "build")
    input_sub = sum(s["tokens_input"] for s in sub_sessions)
    tokens_ratio = share(input_build, input_sub) if input_sub else 0.0

    provider_args = dict(data["provider_args"])
    paid_share = share(sum(provider_args.get(k, 0) for k in PAID), data["calls_with_args"])

    turns, cycles = compute_turns(data)

    # Службы: ollama решает правило «бесплатный каскад», run-watch — контекст дисциплины процессов.
    wd = read_json(watchdog_path) or {}
    checks = wd.get("checks") or {}
    node_states = {k: {"status": v.get("status"), "state": v.get("state")} for k, v in checks.items()}
    ollama_ok = (checks.get("ollama") or {}).get("status") == "ok"

    rw = read_json(runwatch_path)
    rw_status = "нет данных"
    if isinstance(rw, dict):
        if isinstance(rw.get("runs"), list):
            c = Counter(str(r.get("status")) for r in rw["runs"])
            rw_status = ", ".join("%s=%d" % (k, v) for k, v in sorted(c.items())) or "пусто"
        else:
            rw_status = str(rw.get("status") or "запись")

    agents_hist = Counter(s["agent"] for s in sess.values())
    time_created = [s["time_created"] for s in sess.values() if s["time_created"]]

    m = {
        "sessions": sessions_n_actual,
        "sessions_requested": sessions_n,
        "window": {
            "from": (min(time_created) / 1000.0) if time_created else None,
            "to": (max(time_created) / 1000.0) if time_created else None,
        },
        "sessions_by_agent": dict(agents_hist),
        "subagent_sessions": len(sub_sessions),
        "calls_total": calls_total,
        "calls_by_agent": dict(by_agent),
        "build_calls": build_calls,
        "build_share_calls": build_share,
        "task_calls": task_calls,
        "sessions_with_task": sessions_with_task,
        "share_task": share_task,
        "turns": turns,
        "cycles": cycles,
        "calls_with_args": data["calls_with_args"],
        "calls_without_args": data["calls_without_args"],
        "provider_split": provider_args,
        "provider_split_with_toolname": dict(data["provider_hint"]),
        "paid_share": paid_share,
        "subagent_calls": sub_calls,
        "subagent_share_of_all_calls": subagent_share,
        "invr_lead_sessions": len(lead_ids),
        "invr_lead_children": lead_children,
        "invr_lead_avg_children": lead_avg,
        "input_build": input_build,
        "input_subagents": input_sub,
        "tokens_ratio": tokens_ratio,
    }
    return m, node_states, ollama_ok, rw_status


def build_advice(m, ollama_ok):
    advice = []

    def add(rule, value, condition, text, severity="medium"):
        advice.append({
            "rule": rule, "value": round(value, 4),
            "condition": condition, "text": text, "severity": severity,
        })

    if m["build_share_calls"] > T_BUILD_SHARE_MAX:
        add("build_share_high", m["build_share_calls"],
            "build_share_calls > %.2f" % T_BUILD_SHARE_MAX,
            "Больше %.0f%% вызовов делает сам build. Понизить порог делегирования до 12 вызовов "
            "и добавить пониженный порог 12 для задач с вебом/документами." % (T_BUILD_SHARE_MAX * 100),
            "high")

    if m["share_task"] < T_SHARE_TASK_MIN:
        add("share_task_low", m["share_task"],
            "share_task < %.2f" % T_SHARE_TASK_MIN,
            "Делегирование почти не используется (%d из %d сессий). Порог 12 вызовов; "
            "проверить диспетчер invr-lead и цепочку build → invr-lead → invr-*." % (
                m["sessions_with_task"], m["sessions"]),
            "high")

    if m["turns"]["median"] < T_MEDIAN_TURN_MIN:
        add("median_turn_low", m["turns"]["median"],
            "median_calls_per_turn < %d" % T_MEDIAN_TURN_MIN,
            "Медиана вызовов на ход = %.0f (порог делегирования считается по ходам/циклам): "
            "либо порог слишком высокий, либо задачи мелкие — поднять отдачу через invr-lead, "
            "не наращивая порог." % m["turns"]["median"],
            "low")

    if m["turns"]["ge_20_share"] > T_TURNS20_MAX and m["task_calls"] == 0:
        add("turns_ge_20_no_task", m["turns"]["ge_20_share"],
            "turns_ge_20_share > %.2f и task_calls = 0" % T_TURNS20_MAX,
            "Длинные ходы (≥%d вызовов) идут без делегирования — жёстко делегировать "
            "на invr-lead." % DELEGATION_HIGH_THRESHOLD,
            "high")

    # Дополнение к правилу выше: по одному сообщению ассистента длинных ходов почти не бывает
    # (стриминг дробит работу), поэтому порог реально проверяется по циклам — пользовательским
    # запросам: сколько из длинных циклов обошлись вовсе без task.
    if m["cycles"]["ge_20_no_task_share"] > T_TURNS20_MAX:
        add("cycles_ge_20_no_task", m["cycles"]["ge_20_no_task_share"],
            "cycles.ge_20_no_task_share > %.2f" % T_TURNS20_MAX,
            "Из %d %s по ≥%d вызовов %d (%.0f%%) выполнены вообще без task — "
            "порог делегирования не срабатывает; отдавать такие запросы invr-lead." % (
                m["cycles"]["ge_20"], plural(m["cycles"]["ge_20"], "цикла", "циклов", "циклов"),
                DELEGATION_HIGH_THRESHOLD, m["cycles"]["ge_20_without_task"],
                m["cycles"]["ge_20_no_task_share"] * 100),
            "high")

    if m["paid_share"] > T_PAID_MAX and ollama_ok:
        add("paid_share_high", m["paid_share"],
            "paid_share > %.2f при живом ollama" % T_PAID_MAX,
            "Платная доля %.1f%% при живом ollama: жёсткий бесплатный каскад "
            "lab100 → doc-extract → firecrawl → local-llm, облако — последним." % (m["paid_share"] * 100),
            "high")

    if m["invr_lead_avg_children"] < T_LEAD_CHILDREN_MIN:
        add("invr_lead_idle", m["invr_lead_avg_children"],
            "invr_lead_avg_children < %.1f" % T_LEAD_CHILDREN_MIN,
            "Диспетчер invr-lead не запускает субагентов: проверить `permission: task: allow` "
            "в .opencode\\agent\\invr-lead.md и `subagent_depth: 2` в opencode.json.",
            "high")

    if m["tokens_ratio"] < T_TOKENS_RATIO_MIN:
        add("tokens_ratio_low", m["tokens_ratio"],
            "tokens_ratio < %.1f" % T_TOKENS_RATIO_MIN,
            "Делегирование не даёт экономии токенов (build/субагенты = %.2f, цель ≥%.1f): "
            "пересмотреть профили и длинные задачи отдавать субагентам." % (
                m["tokens_ratio"], T_TOKENS_RATIO_GOAL),
            "medium")

    order = {"high": 0, "medium": 1, "low": 2}
    advice.sort(key=lambda a: order.get(a["severity"], 3))
    return advice


# ---------------------------------------------------------------- вывод


def fmt_int(n):
    return "{:,}".format(int(n)).replace(",", " ")


def fmt_pct(v):
    return "%.1f%%" % (v * 100.0)


def fmt_ts(v):
    if not v:
        return "—"
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(v))


def verdict(ok, bad_text):
    return "ок" if ok else bad_text


def render(report):
    m = report["metrics"]
    out = []
    w = out.append
    a = report["advice"]

    w("%s %s — выборка: последние %d сессий, %s вызовов" % (
        TOOL_NAME, TOOL_VERSION, m["sessions"], fmt_int(m["calls_total"])))
    w("окно: %s … %s | сессий по ролям: %s" % (
        fmt_ts(m["window"]["from"]), fmt_ts(m["window"]["to"]),
        ", ".join("%s=%d" % (k, v) for k, v in sorted(
            m["sessions_by_agent"].items(), key=lambda kv: (-kv[1], kv[0])))))
    w("контекст: ollama=%s | run-watch: %s" % (report["context"]["ollama"], report["context"]["run_watch"]))
    w("")

    w("%-28s %-16s %s" % ("МЕТРИКА", "ЗНАЧЕНИЕ", "ВЕРДИКТ"))
    w("-" * 78)

    w("%-28s %-16s %s" % ("sessions", str(m["sessions"]), "запрошено %d" % m["sessions_requested"]))
    w("%-28s %-16s %s" % ("subagent_sessions",
                          fmt_int(m["subagent_sessions"]),
                          "субагентов из %d (parent_id задан)" % m["sessions"]))
    w("%-28s %-16s %s" % ("calls_total", fmt_int(m["calls_total"]),
                          "хорошая выборка" if m["calls_total"] > 1000 else "мало данных"))
    w("%-28s %-16s %s" % ("calls_by_agent",
                          "; ".join("%s=%s" % (k, fmt_int(v)) for k, v in sorted(
                              m["calls_by_agent"].items(), key=lambda kv: (-kv[1], kv[0]))),
                          "вызовы по роли сессии"))
    w("%-28s %-16s %s" % ("build_share_calls", fmt_pct(m["build_share_calls"]),
                          verdict(m["build_share_calls"] <= T_BUILD_SHARE_MAX, "ВЫШЕ ЦЕЛИ (≤60%)")))
    w("%-28s %-16s %s" % ("subagent_share_of_all_calls", fmt_pct(m["subagent_share_of_all_calls"]),
                          verdict(m["subagent_share_of_all_calls"] >= 0.20, "мало субагентов (<20%)")))
    w("")

    w("%-28s %-16s %s" % ("task_calls", fmt_int(m["task_calls"]),
                          verdict(m["task_calls"] > 0, "делегирования нет")))
    w("%-28s %-16s %s" % ("sessions_with_task",
                          "%d/%d" % (m["sessions_with_task"], m["sessions"]), ""))
    w("%-28s %-16s %s" % ("share_task", "%.3f" % m["share_task"],
                          verdict(m["share_task"] >= T_SHARE_TASK_MIN, "НИЖЕ ЦЕЛИ (≥10%)")))
    w("")

    t, c = m["turns"], m["cycles"]
    w("ходы (сообщение ассистента с вызовами): %d" % t["count"])
    w("%-28s %-16s %s" % ("  median_calls_per_turn", str(t["median"]),
                          verdict(t["median"] >= T_MEDIAN_TURN_MIN, "ниже %d" % T_MEDIAN_TURN_MIN)))
    w("%-28s %-16s %s" % ("  p90_calls_per_turn", str(t["p90"]), ""))
    w("%-28s %-16s %s" % ("  turns_without_task",
                          "%d (%s)" % (t["without_task"], fmt_pct(t["without_task_share"])), ""))
    w("%-28s %-16s %s" % ("  turns_ge_20",
                          "%d (%s)" % (t["ge_20"], fmt_pct(t["ge_20_share"])),
                          verdict(t["ge_20_share"] <= T_TURNS20_MAX, "много длинных ходов")))
    w("циклы (пользовательский запрос): %d" % c["count"])
    w("%-28s %-16s %s" % ("  median_calls_per_turn", str(c["median"]), ""))
    w("%-28s %-16s %s" % ("  p90_calls_per_turn", str(c["p90"]), ""))
    w("%-28s %-16s %s" % ("  cycles_without_task",
                          "%d (%s)" % (c["without_task"], fmt_pct(c["without_task_share"])), ""))
    w("%-28s %-16s %s" % ("  cycles_ge_20",
                          "%d (%s)" % (c["ge_20"], fmt_pct(c["ge_20_share"])),
                          verdict(c["ge_20_share"] <= T_TURNS20_MAX, "много длинных циклов")))
    w("%-28s %-16s %s" % ("  cycles_ge_20_without_task",
                          "%d (%s)" % (c["ge_20_without_task"], fmt_pct(c["ge_20_no_task_share"])),
                          verdict(c["ge_20_no_task_share"] <= T_TURNS20_MAX, "длинные циклы без task")))
    w("")

    base = m["calls_with_args"]
    w("каналы по тексту аргументов (с аргументами: %d, без: %d):" % (base, m["calls_without_args"]))
    for name, _ in PROVIDERS:
        v = m["provider_split"].get(name, 0)
        tag = "платно" if name in PAID else "бесплатно"
        w("%-28s %-16s %s" % ("  " + name, "%d (%s)" % (v, fmt_pct(share(v, base))), tag))
    other = m["provider_split"].get(OTHER, 0)
    w("%-28s %-16s %s" % ("  " + OTHER, "%d (%s)" % (other, fmt_pct(share(other, base))), "прочее"))
    w("%-28s %-16s %s" % ("paid_share", "%.3f" % m["paid_share"],
                          verdict(m["paid_share"] <= T_PAID_MAX, "ВЫШЕ ЦЕЛИ (≤30%)")))
    w("")

    w("%-28s %-16s %s" % ("invr_lead_sessions", str(m["invr_lead_sessions"]), "сессий диспетчера"))
    w("%-28s %-16s %s" % ("invr_lead_children", str(m["invr_lead_children"]), ""))
    w("%-28s %-16s %s" % ("invr_lead_avg_children", "%.2f" % m["invr_lead_avg_children"],
                          verdict(m["invr_lead_avg_children"] >= T_LEAD_CHILDREN_MIN, "диспетчер простаивает")))
    w("")

    w("%-28s %-16s %s" % ("input_build", fmt_int(m["input_build"]), ""))
    w("%-28s %-16s %s" % ("input_subagents", fmt_int(m["input_subagents"]), ""))
    w("%-28s %-16s %s" % ("tokens_ratio", "%.3f" % m["tokens_ratio"],
                          verdict(m["tokens_ratio"] >= T_TOKENS_RATIO_MIN,
                                  "экономии нет (цель ≥%.1f)" % T_TOKENS_RATIO_GOAL)))
    w("")

    w("=== Рекомендации (advice): %d ===" % len(a))
    if not a:
        w("пороги в норме — правки правил оркестрации не требуются.")
    for i, item in enumerate(a, 1):
        w("[%d] %-24s %s" % (i, item["rule"], "важность: " + item["severity"]))
        w("    условие : %s (значение %.4f)" % (item["condition"], item["value"]))
        w("    действие: %s" % item["text"])
    return "\n".join(out)


def render_advice_only(report):
    a = report["advice"]
    out = ["advice: %d" % len(a)]
    for i, item in enumerate(a, 1):
        out.append("[%d] %s (%.4f) | %s" % (i, item["rule"], item["value"], item["text"]))
    return "\n".join(out)


def log_line(report):
    m, a = report["metrics"], report["advice"]
    return ("[%s] sessions=%d calls=%d build_share=%.3f share_task=%.3f "
            "median_turn=%d p90_turn=%d cycles_ge_20=%d paid_share=%.3f tokens_ratio=%.3f advice=%d") % (
        time.strftime("%Y-%m-%d %H:%M:%S"), m["sessions"], m["calls_total"],
        m["build_share_calls"], m["share_task"], m["turns"]["median"], m["turns"]["p90"],
        m["cycles"]["ge_20"], m["paid_share"], m["tokens_ratio"], len(a))


def append_log(path, line):
    old = []
    if os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8-sig") as f:
                old = [x for x in f.read().splitlines() if x.strip()]
        except OSError:
            old = []
    kept = (old + [line])[-LOG_KEEP_LINES:]
    write_atomic(path, "\n".join(kept) + "\n")


# ---------------------------------------------------------------- main


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="orch_metrics.py",
        description="Метрики распределения работы оркестратора opencode + корректирующие рекомендации.")
    ap.add_argument("--sessions", type=int, default=50, help="сколько последних сессий анализировать (по умолчанию 50)")
    ap.add_argument("--json", action="store_true", help="полный JSON в stdout")
    ap.add_argument("--no-state", action="store_true", help="не писать state\\orch-metrics.json и журнал")
    ap.add_argument("--quiet", action="store_true", help="только advice (без таблицы)")
    ap.add_argument("--db", default="", help="путь к opencode.db (по умолчанию %USERPROFILE%\\.local\\share\\opencode)")
    ap.add_argument("--state-dir", default="", help="каталог состояния (по умолчанию <tools>\\orch-metrics\\state)")
    ap.add_argument("--watchdog", default="", help="путь к current.json демона-стража")
    ap.add_argument("--run-watch", default="", help="путь к run-watch.json")
    args = ap.parse_args(argv)

    root = tools_root()
    db_path = args.db or default_db_path()
    state_dir = args.state_dir or os.path.join(root, TOOL_NAME, "state")
    watchdog_path = args.watchdog or os.path.join(root, "mcp-watchdog", "state", "current.json")
    runwatch_path = args.run_watch or os.path.join(root, "run-watch", "state", "run-watch.json")

    n = args.sessions if args.sessions and args.sessions > 0 else 50

    try:
        metrics, node_states, ollama_ok, rw_status = compute(db_path, n, watchdog_path, runwatch_path)
    except DbUnavailable as e:
        print("%s: %s" % (TOOL_NAME, e), file=sys.stderr)
        return 2
    except (sqlite3.Error, OSError, ValueError) as e:
        print("%s: непредвиденный сбой разбора данных: %s" % (TOOL_NAME, e), file=sys.stderr)
        return 1

    advice = build_advice(metrics, ollama_ok)
    report = {
        "schema": "inrv.orch-metrics/1",
        "tool": TOOL_NAME,
        "version": TOOL_VERSION,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "sources": {
            "db": db_path,
            "watchdog": watchdog_path,
            "run_watch": runwatch_path,
        },
        "targets": {
            "build_share_calls_max": T_BUILD_SHARE_MAX,
            "share_task_min": T_SHARE_TASK_MIN,
            "median_calls_per_turn_min": T_MEDIAN_TURN_MIN,
            "turns_ge_20_share_max": T_TURNS20_MAX,
            "paid_share_max": T_PAID_MAX,
            "invr_lead_avg_children_min": T_LEAD_CHILDREN_MIN,
            "tokens_ratio_min": T_TOKENS_RATIO_MIN,
            "tokens_ratio_goal": T_TOKENS_RATIO_GOAL,
            "delegation_high_threshold": DELEGATION_HIGH_THRESHOLD,
        },
        "context": {
            "ollama": "жив" if ollama_ok else "недоступен",
            "run_watch": rw_status,
            "nodes": node_states,
        },
        "metrics": metrics,
        "advice": advice,
    }

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    elif args.quiet:
        print(render_advice_only(report))
    else:
        print(render(report))

    if not args.no_state:
        try:
            write_atomic(os.path.join(state_dir, "orch-metrics.json"),
                         json.dumps(report, ensure_ascii=False, indent=2) + "\n")
            append_log(os.path.join(state_dir, "orch-metrics.log"), log_line(report))
        except OSError as e:
            # Метрики достоверны; проблема только в записи состояния — не роняем прогон.
            print("%s: не удалось записать состояние в %s: %s" % (TOOL_NAME, state_dir, e), file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except BrokenPipeError:
        sys.exit(0)