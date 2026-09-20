"""
MCP-сервер «локальные LLM» для opencode-оркестратора.

Даёт инструменты:
  - list_local_models()          — список моделей Ollama
  - model_chat(...)              — разовый вызов выбранной модели (8b/3b/3b-cpu)
  - agent_task(...)              — полный Hermes-агент (с инструментами) на задачу

Оркестратор (основной агент opencode) сам решает, какой инструмент/модель
использовать под задачу: 3b — быстро и дёшево, 8b — умнее, agent_task — когда
нужны реальные действия (файлы, терминал, память).
"""
import json
import os
import subprocess
import urllib.request
import urllib.error

from mcp.server.mcpserver import MCPServer

mcp = MCPServer(name="local-llm-orchestrator")

OLLAMA = "http://localhost:11434"
MODEL_ALLOW = {
    "hermes3:8b",
    "hermes3:3b",
    "hermes3:3b-cpu",
    "hermes3:3b-l8",
    "hermes3:3b-l12",
    "hermes3:3b-l16",
}
HERMES_EXE = os.environ.get("HERMES_EXE", r"C:\Users\<user>\.local\bin\hermes.exe")
PROJECT_DIR = os.environ.get("HERMES_PROJECT_DIR", r"C:\Scripts\hermes-project")


def _ollama_post(path: str, payload: dict, timeout: float = 900.0):
    req = urllib.request.Request(
        OLLAMA + path,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.URLError as e:
        raise RuntimeError(f"Ollama недоступен ({e.reason}). Сервер запущен?") from e


@mcp.tool()
def list_local_models() -> str:
    """Показать локальные модели Ollama (имена) с размерами. Используй перед выбором модели."""
    try:
        req = urllib.request.Request(OLLAMA + "/api/tags", method="GET")
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        rows = []
        for m in data.get("models", []):
            rows.append(f"{m['name']}  ({round(m.get('size', 0) / 1e9, 2)} GB)")
        return "\n".join(rows) if rows else "Моделей нет (ollama pull ...)"
    except Exception as e:
        return f"Ошибка: {e}"


@mcp.tool()
def model_chat(model: str, prompt: str, system: str = "", max_tokens: int = 512, temperature: float = 0.7) -> str:
    """
    Разовый вызов локальной модели БЕЗ инструментов.
    - model: hermes3:8b (умный, медленный ~10-15 ток/с), hermes3:3b (быстрый,
      слабее), hermes3:3b-cpu (только CPU).
    - prompt: текст запроса.
    - system: опциональная системная инструкция.
    - max_tokens: лимит ответа.
    Возвращает текст ответа модели. Подходит для коротких вопросов, суммаризаций,
    генерации текста; для реальных действий (файлы, терминал) используй agent_task.
    """
    if model not in MODEL_ALLOW:
        return f"Модель {model} не разрешена. Доступны: {', '.join(sorted(MODEL_ALLOW))}"
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})
    payload = {
        "model": model,
        "messages": messages,
        "stream": False,
        "keep_alive": "30m",
        "options": {
            "num_ctx": 16384,
            "num_predict": max_tokens,
            "temperature": temperature,
        },
    }
    try:
        data = _ollama_post("/api/chat", payload)
    except Exception as e:
        return f"Ошибка вызова: {e}"
    content = data.get("message", {}).get("content", "")
    return content.strip() or "(пустой ответ)"


@mcp.tool()
def agent_task(prompt: str, model: str = "hermes3:8b", timeout_s: int = 1800) -> str:
    """
    Запустить полного Hermes-агента (с инструментами: файлы, терминал, память)
    в C:\\Scripts\\hermes-project на задачу prompt одним прогоном.
    МЕДЛЕННО (минуты, CPU): используй только когда нужны реальные действия или
    глубокая работа с файлами/данными, а не простые ответы.
    model: hermes3:8b (по умолчанию) или hermes3:3b (быстрее, слабее).
    Возвращает итоговый ответ агента.
    """
    if model not in MODEL_ALLOW:
        return f"Модель {model} не разрешена. Доступны: {', '.join(sorted(MODEL_ALLOW))}"
    cmd = [HERMES_EXE, "-z", prompt, "-m", model, "--yolo"]
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            timeout=timeout_s,
            cwd=PROJECT_DIR,
        )
    except subprocess.TimeoutExpired as e:
        return f"agent_task: превышен таймаут {timeout_s}s. Частичный вывод:\n{e.stdout[-1500:] if e.stdout else '(пусто)'}"
    out = (proc.stdout or b"").decode("utf-8", errors="replace").strip()
    err = (proc.stderr or b"").decode("utf-8", errors="replace").strip()
    if proc.returncode != 0:
        return f"agent_task: rc={proc.returncode}\n--- stdout ---\n{out[-3000:]}\n--- stderr ---\n{err[-1500:]}"
    return out[-6000:] or "(пустой ответ агента)"


if __name__ == "__main__":
    mcp.run()