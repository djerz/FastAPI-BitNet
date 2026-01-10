#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Config (override via env)
# ----------------------------
CONTAINER_NAME="${CONTAINER_NAME:-ai_container}"
API_BASE="${API_BASE:-http://127.0.0.1:8080}"
UPSTREAM_BASE="${UPSTREAM_BASE:-http://127.0.0.1:5000}"
MODEL_ID="${MODEL_ID:-bitnet}"

# Request defaults
TEMPERATURE="${TEMPERATURE:-0.2}"
MAX_TOKENS_SMALL="${MAX_TOKENS_SMALL:-32}"
MAX_TOKENS_MED="${MAX_TOKENS_MED:-128}"
MAX_TOKENS_LARGE="${MAX_TOKENS_LARGE:-512}"

# curl behavior
CURL_MAX_TIME="${CURL_MAX_TIME:-60}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-3}"

# Perf experiments
CONCURRENCY="${CONCURRENCY:-4}"     # number of parallel requests
REPEAT="${REPEAT:-3}"              # repetitions per test
THREADS_LIST="${THREADS_LIST:-4 8 12 16}"  # used for advisory only unless you restart server

# ----------------------------
# Helpers
# ----------------------------
hr() { printf "\n%s\n" "------------------------------------------------------------"; }
ok() { printf "✅ %s\n" "$*"; }
warn() { printf "⚠️  %s\n" "$*" >&2; }
fail() { printf "❌ %s\n" "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

curl_json() {
  local method="$1"; shift
  local url="$1"; shift
  local data="${1:-}"; shift || true

  if [[ "$method" == "GET" ]]; then
    curl -sS \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --max-time "$CURL_MAX_TIME" \
      -H "Content-Type: application/json" \
      "$url"
  else
    curl -sS \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --max-time "$CURL_MAX_TIME" \
      -H "Content-Type: application/json" \
      -X "$method" \
      -d "$data" \
      "$url"
  fi
}

curl_time() {
  # prints: http_code total_time connect_time starttransfer_time size_download
  local method="$1"; shift
  local url="$1"; shift
  local data="${1:-}"; shift || true

  if [[ "$method" == "GET" ]]; then
    curl -sS -o /dev/null \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --max-time "$CURL_MAX_TIME" \
      -w "%{http_code} %{time_total} %{time_connect} %{time_starttransfer} %{size_download}\n" \
      "$url"
  else
    curl -sS -o /dev/null \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --max-time "$CURL_MAX_TIME" \
      -H "Content-Type: application/json" \
      -X "$method" \
      -d "$data" \
      -w "%{http_code} %{time_total} %{time_connect} %{time_starttransfer} %{size_download}\n" \
      "$url"
  fi
}

docker_exec() {
  docker exec -it "$CONTAINER_NAME" sh -lc "$*"
}

json_escape() {
  # minimal JSON string escaper for bash (no jq dependency)
  python - <<'PY'
import json,sys
s=sys.stdin.read()
print(json.dumps(s)[1:-1])
PY
}

mk_chat_payload() {
  local user_msg="$1"
  local max_tokens="$2"
  local temp="$3"
  local umsg
  umsg="$(printf "%s" "$user_msg" | json_escape)"
  cat <<JSON
{
  "model": "$MODEL_ID",
  "messages": [{"role":"user","content":"$umsg"}],
  "temperature": $temp,
  "max_tokens": $max_tokens
}
JSON
}

mk_chat_payload_multiturn() {
  local max_tokens="$1"
  cat <<JSON
{
  "model": "$MODEL_ID",
  "messages": [
    {"role":"system","content":"You are concise."},
    {"role":"user","content":"Explain what BitNet is in one sentence."},
    {"role":"assistant","content":"BitNet is a neural network approach that uses low-bit representations to reduce compute and memory."},
    {"role":"user","content":"Now give one practical use case."}
  ],
  "temperature": 0.2,
  "max_tokens": $max_tokens
}
JSON
}

# ----------------------------
# Preflight
# ----------------------------
need_cmd curl
need_cmd docker
need_cmd python

hr
echo "Config:"
echo "  CONTAINER_NAME=$CONTAINER_NAME"
echo "  API_BASE=$API_BASE"
echo "  UPSTREAM_BASE=$UPSTREAM_BASE"
echo "  MODEL_ID=$MODEL_ID"
echo "  CURL_MAX_TIME=$CURL_MAX_TIME  CONCURRENCY=$CONCURRENCY  REPEAT=$REPEAT"
hr

# ----------------------------
# 1) Basic endpoint tests
# ----------------------------
echo "1) Basic endpoint tests"

echo "-> GET /health"
health="$(curl_json GET "$API_BASE/health" || true)"
[[ "$health" == *"ok"* ]] && ok "/health returned ok" || fail "/health did not return ok: $health"

echo "-> GET /v1/models"
models="$(curl_json GET "$API_BASE/v1/models" || true)"
[[ "$models" == *"$MODEL_ID"* ]] && ok "/v1/models contains model id '$MODEL_ID'" || warn "/v1/models does not mention '$MODEL_ID' (might still work). Response: $models"

echo "-> POST /v1/chat/completions (small)"
payload="$(mk_chat_payload "Say hello in one short sentence." "$MAX_TOKENS_SMALL" "$TEMPERATURE")"
resp="$(curl_json POST "$API_BASE/v1/chat/completions" "$payload" || true)"
[[ "$resp" == *"choices"* && "$resp" == *"message"* ]] && ok "chat completion basic shape ok" || fail "chat completion response not OpenAI-shaped: $resp"

# ----------------------------
# 2) Functional/behavior tests
# ----------------------------
hr
echo "2) Functional/behavior tests"

echo "-> Multi-turn conversation"
payload="$(mk_chat_payload_multiturn "$MAX_TOKENS_MED")"
resp="$(curl_json POST "$API_BASE/v1/chat/completions" "$payload" || true)"
[[ "$resp" == *"choices"* && "$resp" == *"content"* ]] && ok "multi-turn ok" || warn "multi-turn response looks odd: $resp"

echo "-> Stop behavior (should be short)"
payload="$(mk_chat_payload "Answer with exactly 5 words." "$MAX_TOKENS_SMALL" "$TEMPERATURE")"
resp="$(curl_json POST "$API_BASE/v1/chat/completions" "$payload" || true)"
[[ "$resp" == *"choices"* ]] && ok "stop/short response request returned" || warn "stop/short response request odd: $resp"

echo "-> Large prompt (stress tokenizer/prompt handling)"
big="$(python - <<'PY'
print("This is a test. " * 800)
PY
)"
payload="$(mk_chat_payload "$big" "$MAX_TOKENS_SMALL" "$TEMPERATURE")"
code_time="$(curl_time POST "$API_BASE/v1/chat/completions" "$payload" || true)"
echo "   timing: (http_code total connect ttfb bytes) => $code_time"

# ----------------------------
# 3) Latency profiling (TTFB + total)
# ----------------------------
hr
echo "3) Latency profiling (repeat=$REPEAT)"
echo "Columns: http_code total_s connect_s ttfb_s bytes"

bench_one() {
  local label="$1"
  local msg="$2"
  local mt="$3"
  echo "-> $label"
  for i in $(seq 1 "$REPEAT"); do
    payload="$(mk_chat_payload "$msg" "$mt" "$TEMPERATURE")"
    curl_time POST "$API_BASE/v1/chat/completions" "$payload" || true
  done
}

bench_one "Small completion" "Say hello in one short sentence." "$MAX_TOKENS_SMALL"
bench_one "Medium completion" "Summarize the purpose of BitNet in 2 sentences." "$MAX_TOKENS_MED"
bench_one "Large completion" "Write a short paragraph about CPU inference optimization." "$MAX_TOKENS_LARGE"

# ----------------------------
# 4) Concurrency test
# ----------------------------
hr
echo "4) Concurrency test (parallel=$CONCURRENCY, max_tokens=$MAX_TOKENS_SMALL)"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

payload="$(mk_chat_payload "Return a short greeting." "$MAX_TOKENS_SMALL" "$TEMPERATURE")"

pids=()
for i in $(seq 1 "$CONCURRENCY"); do
  (
    # Always produce exactly one line of output per worker
    if out="$(curl_time POST "$API_BASE/v1/chat/completions" "$payload" 2>/dev/null)"; then
      printf "%s\n" "$out" >"$tmpdir/out_$i.txt"
    else
      printf "ERR\n" >"$tmpdir/out_$i.txt"
    fi
  ) &
  pids+=("$!")
done

# Wait for all workers; don't let one failure abort the whole script under set -e
for pid in "${pids[@]}"; do
  wait "$pid" || true
done

echo "Results:"
cat "$tmpdir"/out_*.txt | sed 's/^/  /'

# Count errors robustly; avoid grep exit codes killing the script under set -e
errs="$(awk 'BEGIN{e=0} $0 ~ /^ERR$/ {e++} END{print e}' "$tmpdir"/out_*.txt)"
if [[ "$errs" -gt 0 ]]; then
  warn "Some parallel requests failed/timeouts ($errs). Consider lowering concurrency or increasing threads/timeout."
else
  ok "Concurrency run completed without immediate curl errors"
fi

# ----------------------------
# 5) Upstream server direct check (optional) — run INSIDE container
# ----------------------------
hr
echo "5) Upstream BitNet server check (optional, inside container)"

# Quick reachability check to upstream from inside container
echo "-> Upstream GET / (inside container)"
u_status="$(docker exec -i "$CONTAINER_NAME" sh -lc \
  "curl -sS -o /dev/null --max-time 3 -w '%{http_code} %{time_total} %{time_connect} %{time_starttransfer} %{size_download}\n' http://127.0.0.1:5000/ 2>/dev/null" \
  || true
)"

if [[ -z "$u_status" ]]; then
  warn "Upstream server not reachable inside container at http://127.0.0.1:5000 (is run_inference_server/llama-server running?)"
else
  echo "Upstream GET / timing: $u_status"
fi

# Try /completion quickly (inside container)
echo "-> POST /completion (limit tokens!, inside container)"
upstream_payload='{"prompt":"Say hello in one short sentence.","n_predict":32,"temperature":0.2,"stop":["<|eot_id|>","<|end_of_text|>"]}'

u_resp="$(docker exec -i "$CONTAINER_NAME" sh -lc \
  "curl -sS --max-time 60 -H 'Content-Type: application/json' -d '$upstream_payload' http://127.0.0.1:5000/completion" \
  || true
)"

if [[ "$u_resp" == *"content"* || "$u_resp" == *"text"* ]]; then
  ok "Upstream /completion works (inside container)"
else
  warn "Upstream /completion response unexpected (inside container): $u_resp"
fi

# ----------------------------
# 6) Docker CPU / memory diagnostics
# ----------------------------
hr
echo "6) Docker CPU/memory diagnostics"

echo "-> docker stats snapshot"
docker stats --no-stream "$CONTAINER_NAME" || true

echo "-> In-container CPU info"
docker_exec 'uname -a; echo; nproc; echo; lscpu 2>/dev/null | sed -n "1,25p" || true'

echo "-> In-container memory info"
docker_exec 'free -h || true; echo; cat /proc/meminfo | sed -n "1,15p"'

echo "-> Process tree (top consumers)"
docker_exec 'ps aux --sort=-%cpu | head -n 12; echo; ps aux --sort=-%mem | head -n 12'

# ----------------------------
# 7) Performance tuning guidance (actionable)
# ----------------------------
hr
echo "7) Performance tuning guidance"

cat <<EOF
You can usually improve "time to first token" and "total time" with:

A) Ensure your shim forwards generation limits:
   - Send n_predict = max_tokens to /completion (otherwise it may default to 4096).
   - Send stop tokens like <|eot_id|> and <|end_of_text|>.

B) Tune BitNet server threads (-t):
   - Try values around your physical core count (often nproc or nproc-1).
   - Your suggested THREADS_LIST: $THREADS_LIST
   - To test properly, restart the container for each -t value and rerun this script.

C) Reduce max_tokens for interactive editor use:
   - CopilotChat is best with max_tokens ~ 64–256. Bigger = slower.

D) Reduce prompt size:
   - Large file contexts can dominate runtime. If you add RAG/context, keep it tight.

E) Docker CPU allocation:
   - If you're on Docker Desktop, ensure the VM has enough CPU cores assigned.
   - Consider running with --cpus and compare results, e.g.:
       docker run --cpus=8 ...

F) Model choice:
   - If you have alternate GGUF quantizations (e.g., different i2/i4), compare
     latency and quality by switching BN_MODEL_GGUF and re-running this script.

EOF

# ----------------------------
# 8) Optional: scripted "restart with threads" loop (requires your entrypoint supports BITNET_THREADS)
# ----------------------------
hr
echo "8) Optional auto-sweep threads (only if your entrypoint reads BITNET_THREADS env)"
cat <<EOF
If you modify your entrypoint to:
  python /code/run_inference_server.py ... -t "\${BITNET_THREADS:-8}" ...

Then you can run a sweep like:
  for t in $THREADS_LIST; do
    docker rm -f $CONTAINER_NAME
    docker run -d --name $CONTAINER_NAME -p 8080:8080 -e BITNET_THREADS=\$t fastapi_bitnet
    CONTAINER_NAME=$CONTAINER_NAME API_BASE=$API_BASE ./test_bitnet_api.sh | tee "bench_t\$t.txt"
  done

EOF

ok "All tests completed (see warnings above if any)."

