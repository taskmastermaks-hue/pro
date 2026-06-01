#!/bin/bash
# SetupMyWF — Vast.ai Setup Script
# Generated: 2026-05-27
# Models: 13 | Nodes: 10

# === Error Accumulation (KB 4.2) ===
ERRORS=()
NODES_FAILED=0
NODES_TOTAL=0
MODELS_FAILED=0
MODELS_TOTAL=0
MODELS_RENAMED=0
BYTES_DOWNLOADED=0

# === Timing Setup ===
START_TIME=$(date +%s)

COMFY='/workspace/ComfyUI'

# === Progress Log ===
LOG_FILE="$COMFY/setup_progress.log"
mkdir -p "$COMFY"
> "$LOG_FILE"

log() {
    local MSG="$1"
    local TS=$(date '+%H:%M:%S')
    echo "[$TS] $MSG" | tee -a "$LOG_FILE"
}

log_section() {
    local TITLE="$1"
    local LINE="$(printf '=%.0s' {1..60})"
    echo "" | tee -a "$LOG_FILE"
    echo "$LINE" | tee -a "$LOG_FILE"
    log "$TITLE"
    echo "$LINE" | tee -a "$LOG_FILE"
}

# Progress helpers (removed inline progress - shown only in final report)
log_node_progress() { :; }
log_model_progress() { :; }

# === Auto-detect Python environment ===
if [ -x "/venv/main/bin/python3" ]; then
    PYTHON="/venv/main/bin/python3"
    PIP="/venv/main/bin/pip"
elif [ -x "$COMFY/.venv-cu128/bin/python3" ]; then
    source "$COMFY/.venv-cu128/bin/activate"
    PYTHON="$COMFY/.venv-cu128/bin/python3"
    PIP="$COMFY/.venv-cu128/bin/pip"
elif [ -n "$VIRTUAL_ENV" ] && [ -x "$VIRTUAL_ENV/bin/python3" ]; then
    PYTHON="$VIRTUAL_ENV/bin/python3"
    PIP="$VIRTUAL_ENV/bin/pip"
elif [ -n "$CONDA_PREFIX" ] && [ -x "$CONDA_PREFIX/bin/python3" ]; then
    PYTHON="$CONDA_PREFIX/bin/python3"
    PIP="$CONDA_PREFIX/bin/pip"
else
    PYTHON="$(command -v python3)"
    PIP="$(command -v pip3 || command -v pip)"
fi
log "Using Python: $PYTHON ($($PYTHON --version 2>&1))"

# === HF_TOKEN ===
if [ -z "${HF_TOKEN}" ]; then
    log "⚠️  HF_TOKEN не задан в Environment Variables Vast.ai!"
    log "   Добавьте переменную HF_TOKEN перед запуском инстанса."
else
    log "✅ HF_TOKEN успешно загружен из Vast.ai"
fi

# === Environment ===
export GIT_TERMINAL_PROMPT=0
export HF_TOKEN="${HF_TOKEN}"
CIVITAI_TOKEN='df502a1f2104acee436a6f133cb58d75'

BSP="--break-system-packages"

# === hf_transfer for 5-10x speedup ===
$PIP install -q hf_transfer $BSP 2>/dev/null || true
export HF_HUB_ENABLE_HF_TRANSFER=1
export PIP_BREAK_SYSTEM_PACKAGES=1

# === aria2 ===
if ! command -v aria2c >/dev/null 2>&1; then
    apt-get install -y -qq aria2 2>/dev/null || true
fi

# === Download Verification ===
VERIFY_DOWNLOADS=0
for arg in "$@"; do
    [ "$arg" = "--verify-downloads" ] && VERIFY_DOWNLOADS=1
done

# === CUDA Detection ===
CUDA_VER=$(nvcc --version 2>/dev/null | grep -oP "release \K[0-9]+" || echo "12")
log "Detected CUDA: $CUDA_VER"

# === LD_LIBRARY_PATH fix ===
CUDA_LIB=$($PYTHON -c "import nvidia.cuda_runtime, os; print(os.path.join(os.path.dirname(nvidia.cuda_runtime.__file__), 'lib'))" 2>/dev/null || true)
if [ -n "$CUDA_LIB" ] && [ -d "$CUDA_LIB" ]; then
    export LD_LIBRARY_PATH="${CUDA_LIB}:${LD_LIBRARY_PATH:-""}"
fi

# === Disk Space Check ===
DISK_TARGET="${COMFY%/*}"
[ -d "$DISK_TARGET" ] || DISK_TARGET="/"
FREE_GB=$(df "$DISK_TARGET" --output=avail -BG 2>/dev/null | tail -1 | tr -d " G") || FREE_GB=""
if [ -z "$FREE_GB" ] || ! [ "$FREE_GB" -eq "$FREE_GB" ] 2>/dev/null; then
  log "⚠️  Could not determine free disk space — skipping check"
  FREE_GB=999
fi
NEED_GB=42
log "Disk: ${FREE_GB}GB free, need ~${NEED_GB}GB"
if [ "$FREE_GB" -lt "$NEED_GB" ]; then
  log ""
  log "ERROR: Not enough disk space — ${FREE_GB}GB free, need ~${NEED_GB}GB"
  log "Increase disk size or remove unused files."
  if [ "${1:-}" = "--force" ]; then
    log "⚠️  --force flag set, continuing despite insufficient space..."
  elif [ -t 0 ]; then
    read -p "Continue anyway? [y/N] " REPLY
    case "$REPLY" in [yY]*) ;; *) log "Aborted."; exit 1;; esac
  else
    log "Non-interactive mode — aborting. Use --force to override."
    exit 1
  fi
fi

$PIP install timm --break-system-packages >/dev/null 2>&1 || true

# === HF Download Helper ===
$PIP install -q huggingface_hub $BSP 2>/dev/null || true
cat > /tmp/hf_download.py << 'PYEOF'
import sys, os, shutil
from huggingface_hub import hf_hub_download
repo_id, filename, dest_dir = sys.argv[1], sys.argv[2], sys.argv[3]
expected_size = int(sys.argv[4]) if len(sys.argv) > 4 else 0
min_size = int(sys.argv[5]) if len(sys.argv) > 5 else 1000
token = os.environ.get('HF_TOKEN')
os.makedirs(dest_dir, exist_ok=True)
basename = os.path.basename(filename)
target = os.path.join(dest_dir, basename)
def do_download():
    path = hf_hub_download(repo_id=repo_id, filename=filename, local_dir=dest_dir, token=token)
    if os.path.abspath(path) != os.path.abspath(target):
        src_parent = os.path.dirname(path)
        shutil.move(path, target)
        path = target
        d = src_parent
        while d != dest_dir and d != os.path.dirname(d):
            try:
                os.rmdir(d)
            except OSError:
                break
            d = os.path.dirname(d)
    else:
        path = target
    return path

for attempt in range(3):
    try:
        path = do_download()
        size = os.path.getsize(path)
        if size < min_size:
            if os.environ.get("HF_HUB_ENABLE_HF_TRANSFER") == "1":
                print(f"File too small ({size}B), retrying without hf_transfer...", file=sys.stderr)
                os.environ["HF_HUB_ENABLE_HF_TRANSFER"] = "0"
                try: os.remove(path)
                except OSError: pass
                path = do_download()
                os.environ["HF_HUB_ENABLE_HF_TRANSFER"] = "1"
                size = os.path.getsize(path)
            if size < min_size:
                raise ValueError(f"File too small: {size} bytes (min {min_size})")
        if expected_size > 0 and size < expected_size * 95 // 100:
            raise ValueError(f"File size mismatch: {size} < {expected_size * 95 // 100}")
        print(f"OK: {path} ({size / 1e9:.1f} GB)")
        sys.exit(0)
    except Exception as e:
        print(f"Attempt {attempt+1}/3 failed: {e}", file=sys.stderr)
        import time; time.sleep(2 ** attempt)
print("FAILED after 3 attempts", file=sys.stderr)
sys.exit(1)
PYEOF

# === Functions ===

install_node() {
    local CNR_ID="$1"
    local REPO_URL="$2"
    local EXTRA_DEPS="$3"
    local LEGACY_COMMIT="${4:-}"
    local NAME=$(basename "$REPO_URL")
    NAME="${NAME%.git}"
    local NODE_DIR="$COMFY/custom_nodes/$NAME"
    local NODE_START=$(date +%s)
    local DEP_WARNINGS=0
    NODES_TOTAL=$((NODES_TOTAL + 1))

    log "📦 Нода [${NODES_TOTAL}/10]: $CNR_ID"

    if [ -d "$NODE_DIR" ]; then
        local CURRENT_REMOTE=$(git -C "$NODE_DIR" remote get-url origin 2>/dev/null || echo "")
        if [ -n "$CURRENT_REMOTE" ] && [ "$CURRENT_REMOTE" != "$REPO_URL" ] && [ "$CURRENT_REMOTE" != "${REPO_URL%.git}" ] && [ "${CURRENT_REMOTE%.git}" != "${REPO_URL%.git}" ]; then
            rm -rf "$NODE_DIR"
        else
            git -C "$NODE_DIR" pull --ff-only >/dev/null 2>&1 || true
        fi
    fi
    if [ ! -d "$NODE_DIR" ]; then
        if [ -n "$LEGACY_COMMIT" ] && ! python -c "from comfy_api.latest import io; io.ComfyNode" 2>/dev/null; then
            local COMMIT_ZIP="${REPO_URL%.git}/archive/${LEGACY_COMMIT}.zip"
            if timeout 120 curl -sL "$COMMIT_ZIP" -o "/tmp/${NAME}.zip" 2>/dev/null && \
               unzip -q "/tmp/${NAME}.zip" -d "$COMFY/custom_nodes" 2>/dev/null; then
                local EXTRACTED=$(find "$COMFY/custom_nodes" -maxdepth 1 -name "${NAME}-*" -type d | head -1)
                if [ -n "$EXTRACTED" ] && [ "$EXTRACTED" != "$NODE_DIR" ]; then
                    mv "$EXTRACTED" "$NODE_DIR" 2>/dev/null
                fi
                rm -f "/tmp/${NAME}.zip"
                log "    ↳ pinned to legacy commit ${LEGACY_COMMIT} (no comfy_api)"
            else
                rm -f "/tmp/${NAME}.zip" 2>/dev/null
                log "❌ Нода $CNR_ID — ошибка установки"
                NODES_FAILED=$((NODES_FAILED + 1))
                ERRORS+=("NODE: $CNR_ID — legacy commit download failed")
                return 1
            fi
        else
            if ! timeout 120 git clone --depth=1 --recurse-submodules "$REPO_URL" "$NODE_DIR" >/dev/null 2>&1; then
                rm -rf "$NODE_DIR" 2>/dev/null
                local ZIP_OK=0
                for BRANCH in main master; do
                    local ZIP_URL="${REPO_URL%.git}/archive/refs/heads/${BRANCH}.zip"
                    if timeout 120 curl -sL "$ZIP_URL" -o "/tmp/${NAME}.zip" 2>/dev/null && \
                       unzip -q "/tmp/${NAME}.zip" -d "$COMFY/custom_nodes" 2>/dev/null && \
                       mv "$COMFY/custom_nodes/${NAME}-${BRANCH}" "$NODE_DIR" 2>/dev/null; then
                        rm -f "/tmp/${NAME}.zip"
                        ZIP_OK=1
                        break
                    fi
                    rm -rf "$COMFY/custom_nodes/${NAME}-${BRANCH}" 2>/dev/null
                    rm -f "/tmp/${NAME}.zip" 2>/dev/null
                done
                if [ "$ZIP_OK" -eq 0 ]; then
                    log "❌ Нода $CNR_ID — ошибка установки"
                    NODES_FAILED=$((NODES_FAILED + 1))
                    ERRORS+=("NODE: $CNR_ID — $REPO_URL")
                    return 1
                fi
            fi
        fi
    fi

    if [ -d "$NODE_DIR" ]; then
        local HAS_REQS=0
        if [ -f "$NODE_DIR/requirements.txt" ]; then
            : # silent
            grep -viE '^\s*(torch|torchvision|torchaudio)\s*(\[|>|<|=|!|$|#)' "$NODE_DIR/requirements.txt" > /tmp/_reqs_filtered.txt 2>/dev/null || true
            if ! $PIP install -r /tmp/_reqs_filtered.txt $BSP >>"$COMFY/pip_errors.log" 2>&1; then
                : # silent
                DEP_WARNINGS=$((DEP_WARNINGS + 1))
            else
                HAS_REQS=1
            fi
        elif [ -f "$NODE_DIR/setup.py" ]; then
            : # silent
            if ! $PIP install "$NODE_DIR" $BSP >>"$COMFY/pip_errors.log" 2>&1; then
                : # silent
                DEP_WARNINGS=$((DEP_WARNINGS + 1))
            else
                HAS_REQS=1
            fi
        fi
        if [ -f "$NODE_DIR/install.py" ]; then
            : # silent
            if ! (cd "$NODE_DIR" && $PYTHON install.py 2>&1); then
                : # silent
                DEP_WARNINGS=$((DEP_WARNINGS + 1))
            fi
        fi
        if [ -n "$EXTRA_DEPS" ] && [ "$HAS_REQS" -eq 0 ]; then
            : # silent
            if ! $PIP install $EXTRA_DEPS $BSP >>"$COMFY/pip_errors.log" 2>&1; then
                : # silent
                DEP_WARNINGS=$((DEP_WARNINGS + 1))
            fi
        fi
    fi
    local ELAPSED=$(( $(date +%s) - NODE_START ))
    if [ "$DEP_WARNINGS" -gt 0 ]; then
        log "⚠️  $CNR_ID — установлен с предупреждениями (${ELAPSED}s)"
        ERRORS+=("NODE-DEPS: $CNR_ID — $DEP_WARNINGS dependency issue(s)")
    else
        log "✅ $CNR_ID — установлен (${ELAPSED}s)"
    fi
}

min_size_for_path() {
    local P="$1"
    case "$P" in
        */diffusion_models/*|*/unet/*|*/checkpoints/*|*/gguf/*) echo 100000000 ;;
        */clip/*|*/clip_vision/*|*/vae/*|*/sams/*|*/seedvr2/*) echo 1000000 ;;
        */loras/*|*/style_models/*) echo 50000 ;;
        */detection/*|*/onnx/*) echo 1000 ;;
        */upscale_models/*) echo 1000000 ;;
        */ultralytics/*|*/embeddings/*) echo 10000 ;;
        */models/*) echo 1000000 ;;
        *) echo 1000 ;;
    esac
}

check_disk_space() {
    local FREE=$(df "$DISK_TARGET" --output=avail -BG 2>/dev/null | tail -1 | tr -d " G")
    if [ -z "$FREE" ] || ! [ "$FREE" -eq "$FREE" ] 2>/dev/null; then return 0; fi
    if [ "$FREE" -lt 2 ]; then
        log ""
        log "FATAL: Less than 2GB disk space remaining (${FREE}GB free). Aborting."
        log "Increase disk size or remove unused models."
        ERRORS+=("DISK: Out of space — ${FREE}GB remaining")
        exit 1
    fi
}

filesize() { stat -Lc%s "$1" 2>/dev/null || stat -Lf%z "$1" 2>/dev/null || echo 0; }

verify_content_type() {
    [ "$VERIFY_DOWNLOADS" -eq 0 ] && return 0
    local URL="$1"
    local DISPLAY="$2"
    case "$URL" in *civitai.com*) return 0 ;; esac
    local RESP
    local AUTH_HEADER=""
    if [ -n "${HF_TOKEN:-}" ] && echo "$URL" | grep -q "huggingface.co"; then
        AUTH_HEADER="Authorization: Bearer $HF_TOKEN"
    fi
    RESP=$(curl -s -X HEAD -m 10 -o /dev/null -w "%{http_code}|%{content_type}" -L ${AUTH_HEADER:+-H "$AUTH_HEADER"} "$URL" 2>/dev/null) || return 0
    local HTTP_CODE="${RESP%%|*}"
    local CT="${RESP#*|}"
    [ -z "$CT" ] && return 0
    case "$HTTP_CODE" in 2??) ;; *) return 0 ;; esac
    local MIME="${CT%%;*}"
    MIME=$(echo "$MIME" | tr "[:upper:]" "[:lower:]" | xargs)
    case "$MIME" in
        text/html|text/plain|application/json|text/x-python|text/xml|text/csv)
            log "  ⚠ $DISPLAY — HEAD check: suspicious content-type '$MIME', skipping download"
            return 1
            ;;
    esac
    return 0
}

dl_file() {
    local RESUME="" OUTPUT="" HEADERS=() URL=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -c) RESUME=1; shift ;;
            -O) OUTPUT="$2"; shift 2 ;;
            --header=*) HEADERS+=("${1#--header=}"); shift ;;
            --header) HEADERS+=("$2"); shift 2 ;;
            --*) shift ;;
            *) URL="$1"; shift ;;
        esac
    done
    if command -v wget >/dev/null 2>&1; then
        local ARGS=(-c --show-progress --progress=bar:force --tries=3 --retry-connrefused --waitretry=5 --timeout=60)
        for H in "${HEADERS[@]}"; do ARGS+=(--header="$H"); done
        ARGS+=(-O "$OUTPUT" "$URL")
        wget "${ARGS[@]}" 2>&1
    else
        local ARGS=(-L --fail --progress-bar --retry 3 --connect-timeout 60 -o "$OUTPUT")
        [ -n "$RESUME" ] && ARGS+=(-C -)
        for H in "${HEADERS[@]}"; do ARGS+=(-H "$H"); done
        ARGS+=("$URL")
        curl "${ARGS[@]}"
    fi
}

download_hf() {
    local REPO="$1"
    local FILE="$2"
    local DEST_DIR="$3"
    local RENAME_TO="${4:-}"
    local FALLBACK_URL="${5:-}"
    local BASENAME=$(basename "$FILE")
    local DISPLAY="${RENAME_TO:-$BASENAME}"
    local MODEL_PATH="${DEST_DIR}/${DISPLAY}"
    MODELS_TOTAL=$((MODELS_TOTAL + 1))
    mkdir -p "$DEST_DIR"
    log "📥 Модель [${MODELS_TOTAL}]: $DISPLAY"
    if [ -f "$MODEL_PATH" ]; then
        local ACTUAL=$(filesize "$MODEL_PATH")
        if [ "$ACTUAL" -gt $(min_size_for_path "$MODEL_PATH") ]; then
            log "✅ $DISPLAY — уже есть"
            return 0
        fi
    fi
    verify_content_type "https://huggingface.co/${REPO}/resolve/main/${FILE// /%20}" "$DISPLAY" || { log_model_progress; return 1; }
    if PYTHONWARNINGS=ignore $PYTHON /tmp/hf_download.py "$REPO" "$FILE" "$DEST_DIR" 0 "$(min_size_for_path "$MODEL_PATH")"; then
        if [ -n "$RENAME_TO" ] && [ "$BASENAME" != "$RENAME_TO" ]; then
            mv "$DEST_DIR/$BASENAME" "$DEST_DIR/$RENAME_TO" 2>/dev/null || true
        fi
        BYTES_DOWNLOADED=$((BYTES_DOWNLOADED + $(filesize "$MODEL_PATH")))
        log "✅ $DISPLAY — загружен"
    elif [ -n "$FALLBACK_URL" ]; then
        log "    ↳ HF failed, trying CivitAI fallback..."
        download_civitai "$FALLBACK_URL" "$DEST_DIR" "$DISPLAY"
    else
        log "❌ $DISPLAY — ошибка загрузки"
        MODELS_FAILED=$((MODELS_FAILED + 1))
        ERRORS+=("MODEL: $DISPLAY (download failed)")
    fi
    check_disk_space
}

download_civitai() {
    local URL="$1"
    local DEST_DIR="$2"
    local FILENAME="$3"
    local MODEL_PATH="${DEST_DIR}/${FILENAME}"
    MODELS_TOTAL=$((MODELS_TOTAL + 1))
    mkdir -p "$DEST_DIR"
    log "📥 Модель [${MODELS_TOTAL}]: $FILENAME"
    if [ -f "$MODEL_PATH" ]; then
        local ACTUAL=$(filesize "$MODEL_PATH")
        if [ "$ACTUAL" -gt $(min_size_for_path "$MODEL_PATH") ]; then
            log "✅ $FILENAME — уже есть"
            return 0
        fi
    fi
    local DL_URL="$URL"
    if [ -n "${CIVITAI_TOKEN:-}" ]; then
        if echo "$DL_URL" | grep -q "?"; then
            DL_URL="${DL_URL}&token=${CIVITAI_TOKEN}"
        else
            DL_URL="${DL_URL}?token=${CIVITAI_TOKEN}"
        fi
    fi
    local DL_OK=0
    local UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    if command -v aria2c >/dev/null 2>&1; then
        if aria2c -x 4 -s 4 --min-split-size=20M --retry-wait=0 --max-tries=1 --file-allocation=falloc --console-log-level=warn --summary-interval=0 --header="User-Agent: $UA" --header="Referer: https://civitai.com/" -o "$FILENAME" -d "$DEST_DIR" "$DL_URL"; then
            DL_OK=1
        fi
        if [ "$DL_OK" = "0" ]; then
            rm -f "$MODEL_PATH" "${MODEL_PATH}.aria2"
            log "    ↳ aria2c failed, retrying..."
            if dl_file -c --header="User-Agent: $UA" --header="Referer: https://civitai.com/" -O "$MODEL_PATH" "$DL_URL"; then
                DL_OK=1
            fi
        fi
    else
        if dl_file -c --header="User-Agent: $UA" --header="Referer: https://civitai.com/" -O "$MODEL_PATH" "$DL_URL"; then
            DL_OK=1
        fi
    fi
    if [ "$DL_OK" = "1" ]; then
        if head -c 100 "$MODEL_PATH" 2>/dev/null | grep -qiE "<!doctype|<html|{\s*\"error\""; then
            if head -c 500 "$MODEL_PATH" 2>/dev/null | grep -qi "logged in\|Unauthorized\|requires you"; then
                log "  ✗ $FILENAME (CivitAI login-only — download manually from browser)"
                ERRORS+=("MODEL: $FILENAME — creator requires CivitAI login. Download manually: open the model page on civitai.com, download the file, and upload to $DEST_DIR/")
            else
                log "  ✗ $FILENAME (received HTML/JSON error instead of model)"
                ERRORS+=("MODEL: $FILENAME (CivitAI returned error page, may need browser download)")
            fi
            rm -f "$MODEL_PATH"
            MODELS_FAILED=$((MODELS_FAILED + 1))
            log_model_progress
            check_disk_space
            return 1
        fi
        if head -c4 "$MODEL_PATH" 2>/dev/null | od -An -tx1 -N4 | grep -q "50 4b 03 04"; then
            log "    ↳ ZIP detected, extracting $FILENAME..."
            local TMP_ZIP="${MODEL_PATH}.zip"
            mv "$MODEL_PATH" "$TMP_ZIP"
            local INNER=$(unzip -l "$TMP_ZIP" 2>/dev/null | grep -iE "\.(safetensors|pth|pt|ckpt|bin|gguf)$" | awk '{print $NF}' | head -1)
            if [ -n "$INNER" ]; then
                unzip -jo "$TMP_ZIP" "$INNER" -d "$DEST_DIR" 2>/dev/null && mv "$DEST_DIR/$(basename "$INNER")" "$MODEL_PATH" 2>/dev/null
                rm -f "$TMP_ZIP"
                BYTES_DOWNLOADED=$((BYTES_DOWNLOADED + $(filesize "$MODEL_PATH")))
                log "✅ $FILENAME — загружен (из ZIP)"
            else
                mv "$TMP_ZIP" "$MODEL_PATH"
                BYTES_DOWNLOADED=$((BYTES_DOWNLOADED + $(filesize "$MODEL_PATH")))
                log "⚠️  $FILENAME — ZIP без модели внутри"
            fi
        else
            BYTES_DOWNLOADED=$((BYTES_DOWNLOADED + $(filesize "$MODEL_PATH")))
            log "✅ $FILENAME — загружен"
        fi
    else
        rm -f "$MODEL_PATH" "${MODEL_PATH}.aria2"
        log "❌ $FILENAME — ошибка загрузки"
        MODELS_FAILED=$((MODELS_FAILED + 1))
        ERRORS+=("MODEL: $FILENAME (download failed)")
    fi
    check_disk_space
}

verify_model() {
    local MODEL_PATH="$1"
    local DISPLAY_NAME="$2"
    MODELS_TOTAL=$((MODELS_TOTAL + 1))
    if [ -f "$MODEL_PATH" ]; then
        local ACTUAL=$(filesize "$MODEL_PATH")
        if [ "$ACTUAL" -gt $(min_size_for_path "$MODEL_PATH") ]; then
            log "✅ $DISPLAY_NAME"
            return 0
        else
            log "❌ $DISPLAY_NAME — повреждён (${ACTUAL} bytes)"
            MODELS_FAILED=$((MODELS_FAILED + 1))
            ERRORS+=("MODEL: $DISPLAY_NAME (corrupted)")
            return 1
        fi
    else
        log "❌ $DISPLAY_NAME — отсутствует"
        MODELS_FAILED=$((MODELS_FAILED + 1))
        ERRORS+=("MODEL: $DISPLAY_NAME (missing)")
        return 1
    fi
}

# === ComfyUI-Manager config ===
MANAGER_CFG="$COMFY/user/__manager/config.ini"
if [ -f "$MANAGER_CFG" ]; then
  sed -i 's/security_level = normal/security_level = weak/' "$MANAGER_CFG"
else
  mkdir -p "$COMFY/user/__manager"
  echo "[default]" > "$MANAGER_CFG"
  echo "security_level = weak" >> "$MANAGER_CFG"
fi

# === Update ComfyUI & Manager ===
log_section "🔄 Обновление ComfyUI"
if [ -d "$COMFY/.git" ]; then
    git -C "$COMFY" pull --ff-only >/dev/null 2>&1 && log "✅ ComfyUI обновлён" || log "⚠️  ComfyUI git pull failed (non-critical)"
fi
$PIP install -q --upgrade comfyui $BSP >/dev/null 2>&1 || true

MANAGER_DIR="$COMFY/custom_nodes/ComfyUI-Manager"
if [ -d "$MANAGER_DIR/.git" ]; then
    git -C "$MANAGER_DIR" pull --ff-only >/dev/null 2>&1 && log "✅ Manager обновлён" || log "⚠️  Manager pull failed (non-critical)"
fi

# === Stop ComfyUI ===
COMFY_WAS_RUNNING=0
if command -v supervisorctl &>/dev/null; then
    supervisorctl stop comfyui >/dev/null 2>&1 || true
    supervisorctl stop comfy >/dev/null 2>&1 || true
fi
COMFY_PID=$(pgrep -f "python.*main.py.*--listen" 2>/dev/null || true)
if [ -n "$COMFY_PID" ]; then
    COMFY_WAS_RUNNING=1
    log "Stopping ComfyUI (PID $COMFY_PID) for clean node installation..."
    kill "$COMFY_PID" 2>/dev/null
    sleep 1
    for i in $(seq 1 15); do
        kill -0 "$COMFY_PID" 2>/dev/null || break
        sleep 1
    done
    kill -0 "$COMFY_PID" 2>/dev/null && kill -9 "$COMFY_PID" 2>/dev/null
    sleep 2
    log "  ✓ ComfyUI stopped"
else
    : # silent
fi

log_section "🔧 Установка нод"

install_node 'crt-nodes' 'https://github.com/PGCRT/CRT-Nodes' 'opencv-contrib-python scipy ultralytics color-matcher spandrel pedalboard wordcloud librosa imageio-ffmpeg huggingface_hub einops rotary-embedding-torch llama-cpp-python omnivoice' ''
install_node 'comfyui-videohelpersuite' 'https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite' 'opencv-python imageio-ffmpeg' ''
install_node 'comfyui-kjnodes' 'https://github.com/kijai/ComfyUI-KJNodes' 'matplotlib' ''
# Pin KJNodes to v1.4.0 — find commit where pyproject.toml has version = "1.4.0"
KJNODES_DIR="$COMFY/custom_nodes/ComfyUI-KJNodes"
if [ -d "$KJNODES_DIR/.git" ]; then
    log "  Pinning comfyui-kjnodes to v1.4.0..."
    KJNODES_COMMIT=$(git -C "$KJNODES_DIR" fetch --unshallow >/dev/null 2>&1; git -C "$KJNODES_DIR" log --oneline --all -- pyproject.toml 2>/dev/null | while read sha msg; do
        if git -C "$KJNODES_DIR" show "$sha:pyproject.toml" 2>/dev/null | grep -q 'version = "1.4.0"'; then
            echo "$sha"
            break
        fi
    done)
    if [ -n "$KJNODES_COMMIT" ]; then
        git -C "$KJNODES_DIR" checkout "$KJNODES_COMMIT" -- . >/dev/null 2>&1 && \
            log "  ✓ comfyui-kjnodes pinned to v1.4.0 (commit $KJNODES_COMMIT)" || \
            log "  ⚠ comfyui-kjnodes: checkout to v1.4.0 failed, using latest"
    else
        log "  ⚠ comfyui-kjnodes: v1.4.0 commit not found in history, using latest"
    fi
fi
install_node 'comfyui-teskors-utils' 'https://github.com/teskor-hub/comfyui-teskors-utils' 'opencv-python' ''
install_node 'comfyui-wanvideowrapper' 'https://github.com/kijai/ComfyUI-WanVideoWrapper' '' ''
install_node 'comfyui-wananimatepreprocess' 'https://github.com/kijai/ComfyUI-WanAnimatePreprocess' '' ''
install_node 'rgthree-comfy' 'https://github.com/rgthree/rgthree-comfy' '' ''
install_node 'comfyui-sam3' 'https://github.com/PozzettiAndrea/ComfyUI-SAM3' 'timm' ''
install_node 'comfyui-swwan' 'https://github.com/aining2022/ComfyUI_Swwan' '' ''
install_node 'comfyui-yolo-mask-process' 'https://github.com/gasdyueer/comfyui-yolo-mask-process' '' ''

log_section "🔍 Проверка модулей ComfyUI"
COMFY_COMPAT_OK=1
for MOD in comfy.ldm.flux.model comfy.ldm.chroma.model comfy.ldm.wan.model comfy.ldm.hunyuan_video.model comfy.ldm.hidream.model; do
    if $PYTHON -c "import sys; sys.path.insert(0, '$COMFY'); __import__('$MOD')" 2>/dev/null; then
        : # silent ok
    else
        log "⚠️  Модуль $MOD отсутствует"
        COMFY_COMPAT_OK=0
    fi
done
if [ "$COMFY_COMPAT_OK" -eq 0 ]; then
    log "🔄 Обновляем ComfyUI (отсутствуют модули)..."
    git -C "$COMFY" pull --ff-only >/dev/null 2>&1 || true
fi

log_section "📥 Загрузка моделей"

download_hf 'Ludka8008/co-wan-m' 'models/loras/light.safetensors' "$COMFY/models/loras"
download_hf 'Ludka8008/co-wan-m' 'models/loras/wan.reworked.safetensors' "$COMFY/models/loras"
download_hf 'Ludka8008/co-wan-m' 'models/loras/WanPusa.safetensors' "$COMFY/models/loras"
download_hf 'Ludka8008/co-wan-m' 'models/loras/WanFun.reworked.safetensors' "$COMFY/models/loras"
download_hf 'Ludka8008/co-wan-m' 'models/vae/vae.safetensors' "$COMFY/models/vae"
download_hf 'Ludka8008/co-wan-m' 'models/text_encoders/text_enc.safetensors' "$COMFY/models/clip"
download_hf 'Ludka8008/co-wan-m' 'models/clip_vision/klip_vision.safetensors' "$COMFY/models/clip_vision"
download_hf 'Ludka8008/co-wan-m' 'models/diffusion_models/WanModel.safetensors' "$COMFY/models/diffusion_models"
download_hf 'Ludka8008/co-wan-m' 'models/detection/vitpose_h_wholebody_model.onnx' "$COMFY/models/detection"
download_hf 'Kijai/vitpose_comfy' 'onnx/vitpose_h_wholebody_data.bin' "$COMFY/models/detection"
download_hf 'Ludka8008/co-wan-m' 'models/detection/yolov10m.onnx' "$COMFY/models/detection"
download_hf 'Ludka8008/co-wan-m' 'models/controlnet/Wan21_Uni3C_controlnet_fp16.safetensors' "$COMFY/models/controlnet"
download_hf 'Bingsu/adetailer' 'face_yolov8m.pt' "$COMFY/models/ultralytics/bbox"
mkdir -p "$COMFY/models/YOLO_MODEL"
cp -n "$COMFY/models/ultralytics/bbox/face_yolov8m.pt" "$COMFY/models/YOLO_MODEL/" 2>/dev/null || true

log_section "🔍 Проверка моделей"
MODELS_TOTAL=0
MODELS_FAILED=0
verify_model "$COMFY/models/loras/light.safetensors" 'light.safetensors'
verify_model "$COMFY/models/loras/wan.reworked.safetensors" 'wan.reworked.safetensors'
verify_model "$COMFY/models/loras/WanPusa.safetensors" 'WanPusa.safetensors'
verify_model "$COMFY/models/loras/WanFun.reworked.safetensors" 'WanFun.reworked.safetensors'
verify_model "$COMFY/models/vae/vae.safetensors" 'vae.safetensors'
verify_model "$COMFY/models/clip/text_enc.safetensors" 'text_enc.safetensors'
verify_model "$COMFY/models/clip_vision/klip_vision.safetensors" 'klip_vision.safetensors'
verify_model "$COMFY/models/diffusion_models/WanModel.safetensors" 'WanModel.safetensors'
verify_model "$COMFY/models/detection/vitpose_h_wholebody_model.onnx" 'vitpose_h_wholebody_model.onnx'
verify_model "$COMFY/models/detection/yolov10m.onnx" 'yolov10m.onnx'
verify_model "$COMFY/models/controlnet/Wan21_Uni3C_controlnet_fp16.safetensors" 'Wan21_Uni3C_controlnet_fp16.safetensors'
verify_model "$COMFY/models/ultralytics/bbox/face_yolov8m.pt" 'face_yolov8m.pt'
verify_model "$COMFY/models/YOLO_MODEL/face_yolov8m.pt" 'face_yolov8m.pt (YOLO_MODEL)'


# === sage-attention ===
$PIP install -q sageattention $BSP 2>/dev/null || true

# === Start ComfyUI ===
cat > "$COMFY/start.sh" << STARTEOF
#!/bin/bash
CUDA_LIB=\$($PYTHON -c "import nvidia.cuda_runtime, os; print(os.path.join(os.path.dirname(nvidia.cuda_runtime.__file__), 'lib'))" 2>/dev/null || true)
if [ -n "\$CUDA_LIB" ] && [ -d "\$CUDA_LIB" ]; then
    export LD_LIBRARY_PATH="\${CUDA_LIB}:\${LD_LIBRARY_PATH:-""}"
fi
cd $COMFY
$PYTHON main.py --listen 0.0.0.0 --port 18188 --enable-cors-header "*" --use-sage-attention --fast
STARTEOF
chmod +x "$COMFY/start.sh"

# === Temp File Cleanup ===
rm -f /tmp/*.zip /tmp/hf_download.py 2>/dev/null || true

# === Final Report ===
TOTAL_SECONDS=$(( $(date +%s) - START_TIME ))
TOTAL_TIME=$(( TOTAL_SECONDS / 60 ))
DL_GB=$(awk "BEGIN{printf \"%.1f\", $BYTES_DOWNLOADED/1073741824}")
if [ "$TOTAL_SECONDS" -gt 0 ] && [ "$BYTES_DOWNLOADED" -gt 0 ]; then
    DL_SPEED=$(awk "BEGIN{printf \"%.1f\", $BYTES_DOWNLOADED/1048576/$TOTAL_SECONDS}")
else
    DL_SPEED="0"
fi

log_section "Итог установки"
NODE_OK=$((NODES_TOTAL - NODES_FAILED))
MODEL_OK=$((MODELS_TOTAL - MODELS_FAILED))
log "🔧 Ноды   : ${NODE_OK}/${NODES_TOTAL}"
log "📦 Модели : ${MODEL_OK}/${MODELS_TOTAL}"
log "💾 Скачано: ${DL_GB} GB (${DL_SPEED} MB/s)"
log "⏱  Время  : ${TOTAL_TIME} мин"

if [ ${#ERRORS[@]} -gt 0 ]; then
  log ""
  log "❌ Ошибки (${#ERRORS[@]}):"
  for err in "${ERRORS[@]}"; do log "   • $err"; done
fi

log ""
log "📄 Лог: $LOG_FILE"

# === Disable rgthree frontend extension ===
COMFY_SETTINGS="$COMFY/user/default/comfy.settings.json"
mkdir -p "$COMFY/user/default"
if [ -f "$COMFY_SETTINGS" ]; then
    if command -v python3 &>/dev/null; then
        python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f: s = json.load(f)
except: s = {}
d = s.get('Comfy.Extension.Disabled', [])
if 'Comfy.RgthreeComfy' not in d: d.append('Comfy.RgthreeComfy')
s['Comfy.Extension.Disabled'] = d
with open(sys.argv[1], 'w') as f: json.dump(s, f, indent=2)
" "$COMFY_SETTINGS"
    else
        echo '{"Comfy.Extension.Disabled":["Comfy.RgthreeComfy"]}' > "$COMFY_SETTINGS"
    fi
else
    echo '{"Comfy.Extension.Disabled":["Comfy.RgthreeComfy"]}' > "$COMFY_SETTINGS"
fi
log "✅ rgthree frontend extension отключён"

# === Patch PyTorch 2.6 weights_only default ===
COMFY_UTILS="$COMFY/comfy/utils.py"
if [ -f "$COMFY_UTILS" ] && grep -q "weights_only=True" "$COMFY_UTILS"; then
    sed -i 's/weights_only=True/weights_only=False/g' "$COMFY_UTILS"
    log "✅ Patched torch.load weights_only"
fi

log_section "🚀 Запуск ComfyUI"

PORT=18188

COMFY_PID=$(pgrep -f "python.*main.py.*--listen" 2>/dev/null || true)
if [ -n "$COMFY_PID" ]; then
    kill "$COMFY_PID" 2>/dev/null
    for i in $(seq 1 10); do
        kill -0 "$COMFY_PID" 2>/dev/null || break
        sleep 1
    done
    kill -0 "$COMFY_PID" 2>/dev/null && kill -9 "$COMFY_PID" 2>/dev/null
    sleep 2
fi

STARTED_VIA_SUPERVISOR=0
if command -v supervisorctl &>/dev/null; then
    for SVC in comfyui comfy; do
        if supervisorctl start "$SVC" 2>/dev/null | grep -qi "started\|running"; then
            log "✅ ComfyUI запущен через supervisord"
            STARTED_VIA_SUPERVISOR=1
            break
        fi
    done
fi
if [ "$STARTED_VIA_SUPERVISOR" -eq 0 ]; then
    nohup bash "$COMFY/start.sh" > "$COMFY/comfyui.log" 2>&1 &
    log "✅ ComfyUI запущен (PID $!)"
fi

READY=0
for i in $(seq 1 60); do
    if curl -s --max-time 2 "http://127.0.0.1:$PORT/system_stats" > /dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 1
done

if [ "$READY" -eq 1 ]; then
    log "✅ ComfyUI запущен на порту $PORT"
    curl -s --max-time 5 "http://127.0.0.1:$PORT/manager/reboot" -X POST > /dev/null 2>&1 || true
    sleep 3
    for i in $(seq 1 30); do
        if curl -s --max-time 2 "http://127.0.0.1:$PORT/system_stats" > /dev/null 2>&1; then
            log "✅ ComfyUI готов"
            break
        fi
        sleep 1
    done
else
    log "⚠️  ComfyUI не отвечает — проверь: tail -f $COMFY/comfyui.log"
fi

log_section "🎉 Готово"
log "✅ Ноды: ${NODE_OK}/${NODES_TOTAL}  Модели: ${MODEL_OK}/${MODELS_TOTAL}"
log "🌐 Открой браузер и нажми F5"
