#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""서울 지하철 실시간 도착정보 — 브라우저에서 쓰는 작은 앱.

실행하면 내 PC 안에서만 도는 작은 서버가 뜨고, 브라우저가 자동으로 열린다.
역 이름을 넣고 조회하면 그 역에 곧 들어올 열차들을 보여 준다.

    python3 subway.py

서울 열린데이터광장 인증키가 필요하다. 아래 중 아무 방법이나 쓰면 된다.
    - 브라우저 화면에 뜨는 입력칸에 붙여넣기 (subway_key.txt 로 저장된다)
    - 환경변수 SEOUL_API_KEY
    - 실행할 때 --key 로 전달

인증키는 비밀번호와 같으므로 코드에 적지 않는다. subway_key.txt 는
.gitignore 에 넣어 두어 GitHub 에 올라가지 않는다.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import sys
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, quote, urlparse
from urllib.request import urlopen

DEFAULT_API_BASE = "http://swopenAPI.seoul.go.kr/api/subway"
KEY_FILE = Path(__file__).resolve().parent / "subway_key.txt"

# subwayId -> (노선 이름, 노선 색)
LINES = {
    "1001": ("1호선", "#0052A4"),
    "1002": ("2호선", "#00A84D"),
    "1003": ("3호선", "#EF7C1C"),
    "1004": ("4호선", "#00A5DE"),
    "1005": ("5호선", "#996CAC"),
    "1006": ("6호선", "#CD7C2F"),
    "1007": ("7호선", "#747F00"),
    "1008": ("8호선", "#E6186C"),
    "1009": ("9호선", "#BB8336"),
    "1032": ("GTX-A", "#9A6292"),
    "1061": ("중앙선", "#77C4A3"),
    "1063": ("경의중앙선", "#77C4A3"),
    "1065": ("공항철도", "#0090D2"),
    "1067": ("경춘선", "#0C8E72"),
    "1071": ("수의분당선", "#F5A200"),
    "1075": ("분당선", "#F5A200"),
    "1077": ("신분당선", "#D4003B"),
    "1092": ("우이신설선", "#B7C452"),
    "1093": ("서해선", "#8FC31F"),
    "1094": ("신림선", "#6789CA"),
}

# arvlCd -> 도착 상태
ARRIVAL_STATE = {
    "0": "진입", "1": "도착", "2": "출발", "3": "전역출발",
    "4": "전역진입", "5": "전역도착", "99": "운행중",
}

# 서울 열린데이터광장이 돌려주는 코드 -> 사람이 읽을 수 있는 설명
API_MESSAGES = {
    "INFO-000": None,  # 정상
    "INFO-200": "해당 역의 도착 정보가 없습니다. 역 이름을 확인해 주세요.",
    "ERROR-300": "요청 형식이 잘못되었습니다.",
    "ERROR-301": "역 이름이 비어 있습니다.",
    "ERROR-333": "요청 위치 값이 잘못되었습니다.",
    "ERROR-500": "서울시 서버에 문제가 있습니다. 잠시 후 다시 시도해 주세요.",
    "ERROR-600": "서울시 서버가 많이 바쁩니다. 잠시 후 다시 시도해 주세요.",
    "ERROR-601": "서울시 서버에 일시적인 오류가 있습니다.",
    "INFO-100": "인증키가 올바르지 않습니다. 키를 다시 입력해 주세요.",
    "INFO-300": "하루 요청 가능 횟수를 넘었습니다.",
}
BAD_KEY_CODES = {"INFO-100", "INFO-300"}


class ApiError(Exception):
    """서울시 API 호출 실패. code 는 있을 수도 없을 수도 있다."""

    def __init__(self, message: str, code: str = ""):
        super().__init__(message)
        self.code = code


# --------------------------------------------------------------------------
# 인증키 보관
# --------------------------------------------------------------------------
class KeyStore:
    def __init__(self, cli_key: str | None = None):
        self.source = ""
        self.key = ""
        if cli_key:
            self.key, self.source = cli_key.strip(), "--key 옵션"
        elif os.environ.get("SEOUL_API_KEY"):
            self.key, self.source = os.environ["SEOUL_API_KEY"].strip(), "환경변수"
        elif KEY_FILE.exists():
            self.key, self.source = KEY_FILE.read_text(encoding="utf-8").strip(), str(KEY_FILE.name)

    def save(self, key: str) -> None:
        key = key.strip()
        if not key:
            raise ValueError("인증키가 비어 있습니다.")
        KEY_FILE.write_text(key + "\n", encoding="utf-8")
        try:
            KEY_FILE.chmod(0o600)  # 윈도우에서는 무시된다
        except OSError:
            pass
        self.key, self.source = key, KEY_FILE.name


# --------------------------------------------------------------------------
# 서울시 API 호출
# --------------------------------------------------------------------------
def _friendly(code: str, raw: str) -> str:
    if code in API_MESSAGES and API_MESSAGES[code]:
        return API_MESSAGES[code]
    return raw or "알 수 없는 오류가 발생했습니다."


def _call_api(api_base: str, key: str, station: str, count: int, timeout: float) -> list[dict]:
    url = "{}/{}/json/realtimeStationArrival/0/{}/{}".format(
        api_base.rstrip("/"), quote(key, safe=""), count, quote(station)
    )
    try:
        with urlopen(url, timeout=timeout) as response:
            body = response.read().decode("utf-8", "replace")
    except HTTPError as exc:
        raise ApiError(f"서울시 서버가 오류를 돌려주었습니다 (HTTP {exc.code}).") from None
    except (URLError, TimeoutError, socket.timeout) as exc:
        raise ApiError(f"서울시 서버에 연결하지 못했습니다: {exc}") from None

    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        # 인증키가 틀리면 XML 로 오는 경우가 있다
        code = (re.search(r"<code>(.*?)</code>", body) or [None, ""])[1]
        message = (re.search(r"<message>(.*?)</message>", body) or [None, ""])[1]
        raise ApiError(_friendly(code, message), code) from None

    status = data.get("errorMessage") or {}
    code = str(status.get("code", ""))
    if code and code != "INFO-000":
        raise ApiError(_friendly(code, str(status.get("message", ""))), code)
    return data.get("realtimeArrivalList") or []


def _clean(value) -> str:
    return " ".join(str(value or "").split())


def _tidy_route(route: str, destination: str) -> str:
    """'성수행 - 건대입구방면' 같은 안내 문구를 다듬는다."""
    route = _clean(route)
    if route:
        return route
    return f"{destination}행" if destination else ""


def _shape(row: dict) -> dict:
    subway_id = str(row.get("subwayId", ""))
    line, color = LINES.get(subway_id, (f"{subway_id}호선", "#5B6570"))
    destination = _clean(row.get("bstatnNm"))
    try:
        eta = int(str(row.get("barvlDt") or "0").strip() or 0)
    except ValueError:
        eta = 0
    return {
        "line": line,
        "color": color,
        "direction": _clean(row.get("updnLine")),
        "destination": destination,
        "route": _tidy_route(row.get("trainLineNm"), destination),
        "message": _clean(row.get("arvlMsg2")),
        "position": _clean(row.get("arvlMsg3")),
        "state": ARRIVAL_STATE.get(str(row.get("arvlCd", "")), ""),
        "express": _clean(row.get("btrainSttus")),
        "train_no": _clean(row.get("btrainNo")),
        "eta_seconds": eta,
        "received": _clean(row.get("recptnDt")),
        "sort_key": _clean(row.get("ordkey")),
    }


def _name_candidates(station: str) -> list[str]:
    """'서울역' 처럼 입력해도 찾히도록 후보 이름을 만든다."""
    station = station.strip()
    names = [station]
    if len(station) > 2 and station.endswith("역"):
        names.append(station[:-1])
    else:
        names.append(station + "역")
    return [n for i, n in enumerate(names) if n and n not in names[:i]]


def get_arrivals(api_base: str, key: str, station: str, count: int = 20,
                 timeout: float = 10.0) -> dict:
    """역 이름으로 도착 정보를 가져온다. 이름 표기가 조금 달라도 한 번 더 시도한다."""
    last_error: ApiError | None = None
    for name in _name_candidates(station):
        try:
            rows = _call_api(api_base, key, name, count, timeout)
        except ApiError as exc:
            if exc.code in BAD_KEY_CODES:
                raise  # 인증키 문제면 다른 이름으로 재시도해도 소용없다
            last_error = exc
            continue
        if rows:
            arrivals = [_shape(row) for row in rows]
            arrivals.sort(key=lambda a: (a["sort_key"] or "9", a["eta_seconds"] or 9999))
            return {"station": name, "arrivals": arrivals}
    raise last_error or ApiError(f"'{station}' 역의 도착 정보를 찾지 못했습니다.")


# --------------------------------------------------------------------------
# 브라우저에 띄울 화면
# --------------------------------------------------------------------------
PAGE = """<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>실시간 지하철 도착정보</title>
<link rel="icon" href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>🚇</text></svg>">
<style>
  :root { --bg:#f4f6f8; --card:#fff; --line:#e3e7ec; --text:#1c2430; --muted:#69737f; --accent:#0052A4; }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--text);
         font-family: "Malgun Gothic", "Apple SD Gothic Neo", "Noto Sans KR", sans-serif; }
  .wrap { max-width: 760px; margin: 0 auto; padding: 24px 16px 64px; }
  h1 { font-size: 22px; margin: 0 0 4px; }
  .sub { color: var(--muted); font-size: 13px; margin-bottom: 20px; }
  .panel { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:16px; margin-bottom:16px; }
  form { display:flex; gap:8px; }
  input[type=text] { flex:1; min-width:0; padding:12px 14px; font-size:16px;
                     border:1px solid var(--line); border-radius:8px; background:#fff; color:inherit; }
  input[type=text]:focus { outline:2px solid var(--accent); outline-offset:-1px; }
  button { padding:12px 18px; font-size:15px; font-weight:600; border:0; border-radius:8px;
           background:var(--accent); color:#fff; cursor:pointer; white-space:nowrap; }
  button:disabled { opacity:.5; cursor:default; }
  button.ghost { background:#eef1f5; color:var(--text); font-weight:500; padding:6px 12px; font-size:13px; }
  .recent { display:flex; flex-wrap:wrap; gap:6px; margin-top:12px; }
  .bar { display:flex; align-items:center; gap:12px; flex-wrap:wrap;
         color:var(--muted); font-size:13px; margin: 4px 2px 12px; }
  .bar label { display:flex; align-items:center; gap:6px; cursor:pointer; }
  .group { margin-bottom:18px; }
  .group h2 { display:flex; align-items:center; gap:8px; font-size:15px; margin:0 0 8px 2px; }
  .badge { display:inline-block; padding:3px 10px; border-radius:999px; color:#fff; font-size:12px; font-weight:700; }
  .row { background:var(--card); border:1px solid var(--line); border-radius:10px;
         padding:12px 14px; margin-bottom:8px; display:flex; gap:12px; align-items:baseline; }
  .row .when { font-size:16px; font-weight:700; flex:1; min-width:0; }
  .row .where { color:var(--muted); font-size:13px; margin-top:3px; }
  .row .tag { font-size:11px; font-weight:700; color:#b8003a; border:1px solid #ffccd8;
              background:#fff2f5; border-radius:4px; padding:2px 6px; }
  .eta { font-size:15px; font-weight:700; color:var(--accent); white-space:nowrap; }
  .msg { padding:14px; border-radius:10px; font-size:14px; }
  .msg.error { background:#fff2f2; border:1px solid #ffd2d2; color:#b00020; }
  .msg.info { background:#eef4ff; border:1px solid #d5e2ff; color:#204b8f; }
  .hint { color:var(--muted); font-size:12px; margin-top:8px; line-height:1.6; }
  a { color: var(--accent); }
</style>
</head>
<body>
<div class="wrap">
  <h1>🚇 실시간 지하철 도착정보</h1>
  <div class="sub">서울 열린데이터광장 실시간 도착정보 · 역 이름을 넣고 조회하세요.</div>

  <div class="panel" id="setup" hidden>
    <strong>서울 열린데이터광장 인증키를 입력해 주세요.</strong>
    <div class="hint">한 번만 입력하면 이 PC의 <code>subway_key.txt</code> 파일에 저장되고,
      다음부터는 묻지 않습니다. 이 파일은 GitHub에 올라가지 않습니다.</div>
    <form id="keyForm" style="margin-top:12px">
      <input type="text" id="keyInput" placeholder="인증키를 붙여넣으세요" autocomplete="off">
      <button type="submit">저장</button>
    </form>
    <div id="keyMsg" class="hint"></div>
  </div>

  <div class="panel" id="search">
    <form id="searchForm">
      <input type="text" id="station" placeholder="역 이름 (예: 서울, 강남, 잠실)" autocomplete="off">
      <button type="submit" id="go">조회</button>
    </form>
    <div class="recent" id="recent"></div>
  </div>

  <div class="bar">
    <label><input type="checkbox" id="auto"> 30초마다 자동 새로고침</label>
    <span id="stamp"></span>
  </div>

  <div id="out"></div>
</div>

<script>
const $ = (id) => document.getElementById(id);
let timer = null, current = "";

function recentList() {
  try { return JSON.parse(localStorage.getItem("recentStations") || "[]"); } catch (e) { return []; }
}
function remember(name) {
  const list = [name, ...recentList().filter((n) => n !== name)].slice(0, 6);
  try { localStorage.setItem("recentStations", JSON.stringify(list)); } catch (e) {}
  drawRecent();
}
function drawRecent() {
  const box = $("recent");
  box.innerHTML = "";
  recentList().forEach((name) => {
    const b = document.createElement("button");
    b.type = "button"; b.className = "ghost"; b.textContent = name;
    b.onclick = () => { $("station").value = name; search(); };
    box.appendChild(b);
  });
}

function etaText(seconds) {
  if (!seconds || seconds < 0) return "";
  if (seconds < 60) return seconds + "초";
  return Math.floor(seconds / 60) + "분 " + (seconds % 60 ? (seconds % 60) + "초" : "");
}

function render(data) {
  const out = $("out");
  out.innerHTML = "";
  const groups = new Map();
  data.arrivals.forEach((a) => {
    const key = a.line + " " + (a.direction || "");
    if (!groups.has(key)) groups.set(key, { line: a.line, color: a.color, direction: a.direction, rows: [] });
    groups.get(key).rows.push(a);
  });
  groups.forEach((g) => {
    const box = document.createElement("div");
    box.className = "group";
    const h = document.createElement("h2");
    h.innerHTML = '<span class="badge" style="background:' + g.color + '"></span><span></span>';
    h.querySelector(".badge").textContent = g.line;
    h.querySelector("span:last-child").textContent = g.direction || "";
    box.appendChild(h);
    g.rows.forEach((a) => {
      const row = document.createElement("div");
      row.className = "row";
      const left = document.createElement("div");
      left.className = "when";
      const title = document.createElement("div");
      title.textContent = a.message || a.state || "정보 없음";
      const where = document.createElement("div");
      where.className = "where";
      where.textContent = [a.route, a.position ? "현재 " + a.position : ""].filter(Boolean).join(" · ");
      left.appendChild(title); left.appendChild(where);
      if (a.express && a.express !== "일반") {
        const tag = document.createElement("span");
        tag.className = "tag"; tag.textContent = a.express;
        title.appendChild(document.createTextNode(" "));
        title.appendChild(tag);
      }
      row.appendChild(left);
      const eta = document.createElement("div");
      eta.className = "eta"; eta.textContent = etaText(a.eta_seconds);
      row.appendChild(eta);
      box.appendChild(row);
    });
    out.appendChild(box);
  });
  $("stamp").textContent = data.station + "역 · " + new Date().toLocaleTimeString("ko-KR") + " 기준";
}

function note(kind, text) {
  $("out").innerHTML = "";
  const div = document.createElement("div");
  div.className = "msg " + kind;
  div.textContent = text;
  $("out").appendChild(div);
}

async function search() {
  const name = $("station").value.trim();
  if (!name) { $("station").focus(); return; }
  current = name;
  $("go").disabled = true;
  try {
    const res = await fetch("/api/arrivals?station=" + encodeURIComponent(name));
    const data = await res.json();
    if (!res.ok) {
      note("error", data.error || "조회에 실패했습니다.");
      if (data.need_key) { $("setup").hidden = false; $("keyInput").focus(); }
      return;
    }
    if (!data.arrivals.length) { note("info", "지금 들어오는 열차 정보가 없습니다."); return; }
    render(data);
    remember(name);
  } catch (e) {
    note("error", "앱과 연결이 끊겼습니다. 실행 중인 창이 닫혔는지 확인해 주세요.");
  } finally {
    $("go").disabled = false;
  }
}

$("searchForm").addEventListener("submit", (e) => { e.preventDefault(); search(); });
$("auto").addEventListener("change", (e) => {
  clearInterval(timer);
  if (e.target.checked) timer = setInterval(() => { if (current) search(); }, 30000);
});
$("keyForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const res = await fetch("/api/key", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ key: $("keyInput").value }),
  });
  const data = await res.json();
  $("keyMsg").textContent = data.error || "인증키를 저장했습니다.";
  if (!data.error) { $("setup").hidden = true; $("keyInput").value = ""; if (current) search(); }
});

(async () => {
  drawRecent();
  const res = await fetch("/api/status");
  const data = await res.json();
  $("setup").hidden = data.has_key;
  ($("setup").hidden ? $("station") : $("keyInput")).focus();
})();
</script>
</body>
</html>
"""


# --------------------------------------------------------------------------
# 아주 작은 웹 서버
# --------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    keys: KeyStore
    api_base: str
    count: int
    timeout: float

    server_version = "SubwayArrivals/1.0"

    def log_message(self, fmt, *args):  # 조용히
        pass

    # --- 응답 도우미 ---
    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, status: int, payload: dict) -> None:
        self._send(status, json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                   "application/json; charset=utf-8")

    # --- 라우팅 ---
    def do_GET(self) -> None:
        route = urlparse(self.path)
        if route.path in ("/", "/index.html"):
            self._send(200, PAGE.encode("utf-8"), "text/html; charset=utf-8")
        elif route.path == "/api/status":
            self._json(200, {"has_key": bool(self.keys.key), "source": self.keys.source})
        elif route.path == "/api/arrivals":
            self._arrivals(parse_qs(route.query))
        else:
            self._json(404, {"error": "없는 주소입니다."})

    def do_POST(self) -> None:
        if urlparse(self.path).path != "/api/key":
            self._json(404, {"error": "없는 주소입니다."})
            return
        length = int(self.headers.get("Content-Length") or 0)
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8") or "{}")
            self.keys.save(str(payload.get("key", "")))
        except (ValueError, OSError) as exc:
            self._json(400, {"error": f"인증키를 저장하지 못했습니다: {exc}"})
            return
        self._json(200, {"saved": True})

    def _arrivals(self, query: dict) -> None:
        station = (query.get("station") or [""])[0].strip()
        if not station:
            self._json(400, {"error": "역 이름을 입력해 주세요."})
            return
        if not self.keys.key:
            self._json(400, {"error": "인증키가 없습니다. 먼저 인증키를 입력해 주세요.", "need_key": True})
            return
        try:
            result = get_arrivals(self.api_base, self.keys.key, station, self.count, self.timeout)
        except ApiError as exc:
            self._json(502, {"error": str(exc), "need_key": exc.code in BAD_KEY_CODES})
            return
        self._json(200, result)


def _pick_port(preferred: int) -> int:
    for port in range(preferred, preferred + 20):
        with socket.socket() as probe:
            if probe.connect_ex(("127.0.0.1", port)) != 0:
                return port
    raise SystemExit("빈 포트를 찾지 못했습니다.")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="서울 지하철 실시간 도착정보를 브라우저에서 조회합니다.")
    parser.add_argument("--port", type=int, default=8765, help="사용할 포트 (기본 8765)")
    parser.add_argument("--key", help="서울 열린데이터광장 인증키")
    parser.add_argument("--count", type=int, default=20, help="한 번에 가져올 열차 수 (기본 20)")
    parser.add_argument("--timeout", type=float, default=10.0, help="응답 대기 시간(초)")
    parser.add_argument("--api-base", default=os.environ.get("SEOUL_API_BASE", DEFAULT_API_BASE),
                        help=argparse.SUPPRESS)  # 테스트용
    parser.add_argument("--no-browser", dest="open_browser", action="store_false",
                        help="브라우저를 자동으로 열지 않음")
    args = parser.parse_args(argv)

    Handler.keys = KeyStore(args.key)
    Handler.api_base = args.api_base
    Handler.count = args.count
    Handler.timeout = args.timeout

    port = _pick_port(args.port)
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    url = f"http://127.0.0.1:{port}/"

    print(f"실시간 지하철 도착정보 앱이 열렸습니다 -> {url}")
    print("인증키: " + (f"{Handler.keys.source} 에서 읽음" if Handler.keys.key else "아직 없음 (브라우저 화면에서 입력)"))
    print("종료하려면 이 창에서 Ctrl+C 를 누르세요.")
    if args.open_browser:
        threading.Timer(0.5, webbrowser.open, args=(url,)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n종료합니다.")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
