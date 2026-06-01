#!/bin/bash
# SetupMyWF — Vast.ai Setup Script
# Generated: 2026-06-01
# Models: 8 | Nodes: 21

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

# === Auto-detect Python environment ===
if [ -x "/venv/main/bin/python3" ]; then
    # Vast.ai managed venv
    PYTHON="/venv/main/bin/python3"
    PIP="/venv/main/bin/pip"
elif [ -x "$COMFY/.venv-cu128/bin/python3" ]; then
    # RunPod bundled venv
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
echo "Using Python: $PYTHON ($($PYTHON --version 2>&1))"

# === HF_TOKEN ===
if [ -z "${HF_TOKEN}" ]; then
    log "⚠️  HF_TOKEN не задан в Environment Variables Vast.ai!"
    log "   Добавьте переменную HF_TOKEN перед запуском инстанса."
else
    log "✅ HF_TOKEN успешно загружен из Vast.ai"
fi

# === CIVITAI_TOKEN ===
if [ -z "${CIVITAI_TOKEN}" ]; then
    log "⚠️  CIVITAI_TOKEN не задан в Environment Variables Vast.ai!"
    log "   Добавьте переменную CIVITAI_TOKEN перед запуском инстанса."
else
    log "✅ CIVITAI_TOKEN успешно загружен из Vast.ai"
fi

# === Environment ===
export GIT_TERMINAL_PROMPT=0
export HF_TOKEN="${HF_TOKEN}"
CIVITAI_TOKEN="${CIVITAI_TOKEN}"

BSP="--break-system-packages"

# === hf_transfer for 5-10x speedup (KB 1.1) ===
$PIP install -q hf_transfer $BSP 2>/dev/null || true
export HF_HUB_ENABLE_HF_TRANSFER=1
# pip inside install.py scripts will respect this env var (TASK-010)
export PIP_BREAK_SYSTEM_PACKAGES=1

# === aria2 for faster CivitAI downloads (TASK-050) ===
if ! command -v aria2c >/dev/null 2>&1; then
    apt-get install -y -qq aria2 2>/dev/null || true
fi

# === Download Verification (TASK-052) ===
# Pass --verify-downloads to enable HEAD content-type checks before downloading
VERIFY_DOWNLOADS=0
for arg in "$@"; do
    [ "$arg" = "--verify-downloads" ] && VERIFY_DOWNLOADS=1
done

# === CUDA Detection (KB 3.1) ===
CUDA_VER=$(nvcc --version 2>/dev/null | grep -oP "release \K[0-9]+" || echo "12")
echo "Detected CUDA: $CUDA_VER"

# === LD_LIBRARY_PATH fix (KB 3.2) ===
CUDA_LIB=$($PYTHON -c "import nvidia.cuda_runtime, os; print(os.path.join(os.path.dirname(nvidia.cuda_runtime.__file__), 'lib'))" 2>/dev/null || true)
if [ -n "$CUDA_LIB" ] && [ -d "$CUDA_LIB" ]; then
    export LD_LIBRARY_PATH="${CUDA_LIB}:${LD_LIBRARY_PATH:-""}"
fi

# === Disk Space Check (KB 5) ===
# Use parent of $COMFY for df — /workspace may not exist on all providers
DISK_TARGET="${COMFY%/*}"
[ -d "$DISK_TARGET" ] || DISK_TARGET="/"
FREE_GB=$(df "$DISK_TARGET" --output=avail -BG 2>/dev/null | tail -1 | tr -d " G") || FREE_GB=""
if [ -z "$FREE_GB" ] || ! [ "$FREE_GB" -eq "$FREE_GB" ] 2>/dev/null; then
  echo "⚠️  Could not determine free disk space — skipping check"
  FREE_GB=999
fi
NEED_GB=48
echo "Disk: ${FREE_GB}GB free, need ~${NEED_GB}GB"
if [ "$FREE_GB" -lt "$NEED_GB" ]; then
  echo ""
  echo "ERROR: Not enough disk space — ${FREE_GB}GB free, need ~${NEED_GB}GB"
  echo "Increase disk size or remove unused files."
  if [ "${1:-}" = "--force" ]; then
    echo "⚠️  --force flag set, continuing despite insufficient space..."
  elif [ -t 0 ]; then
    read -p "Continue anyway? [y/N] " REPLY
    case "$REPLY" in [yY]*) ;; *) echo "Aborted."; exit 1;; esac
  else
    echo "Non-interactive mode — aborting. Use --force to override."
    exit 1
  fi
fi

# === HF Download Helper (KB 1.1) ===
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
        # Remove empty parent dirs left by hf_hub_download (TASK-022)
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
            # Xet fallback: disable hf_transfer and retry once (TASK-044)
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
    local LEGACY_COMMIT="${4:-}"  # fallback commit if comfy_api unavailable
    local NAME=$(basename "$REPO_URL")
    NAME="${NAME%.git}"  # strip .git suffix if present
    local NODE_DIR="$COMFY/custom_nodes/$NAME"
    local NODE_START=$(date +%s)
    local DEP_WARNINGS=0
    NODES_TOTAL=$((NODES_TOTAL + 1))

    if [ -d "$NODE_DIR" ]; then
        # Check if remote URL matches — re-clone if repo changed (e.g. fork switch)
        local CURRENT_REMOTE=$(git -C "$NODE_DIR" remote get-url origin 2>/dev/null || echo "")
        if [ -n "$CURRENT_REMOTE" ] && [ "$CURRENT_REMOTE" != "$REPO_URL" ] && [ "$CURRENT_REMOTE" != "${REPO_URL%.git}" ] && [ "${CURRENT_REMOTE%.git}" != "${REPO_URL%.git}" ]; then
            echo "    remote changed ($CURRENT_REMOTE → $REPO_URL), re-cloning..."
            rm -rf "$NODE_DIR"
        else
            echo "    pulling updates..."
            git -C "$NODE_DIR" pull --ff-only 2>/dev/null || true
        fi
    fi
    if [ ! -d "$NODE_DIR" ]; then
        if [ -n "$LEGACY_COMMIT" ] && ! python -c "from comfy_api.latest import io; io.ComfyNode" 2>/dev/null; then
            # V3-only node on old ComfyUI — download legacy commit via zip archive
            local COMMIT_ZIP="${REPO_URL%.git}/archive/${LEGACY_COMMIT}.zip"
            if timeout 120 curl -sL "$COMMIT_ZIP" -o "/tmp/${NAME}.zip" 2>/dev/null && \
               unzip -q "/tmp/${NAME}.zip" -d "$COMFY/custom_nodes" 2>/dev/null; then
                # zip extracts as RepoName-commitsha/, rename to expected dir name
                local EXTRACTED=$(find "$COMFY/custom_nodes" -maxdepth 1 -name "${NAME}-*" -type d | head -1)
                if [ -n "$EXTRACTED" ] && [ "$EXTRACTED" != "$NODE_DIR" ]; then
                    mv "$EXTRACTED" "$NODE_DIR" 2>/dev/null
                fi
                rm -f "/tmp/${NAME}.zip"
                echo "    ↳ pinned to legacy commit ${LEGACY_COMMIT} (no comfy_api)"
            else
                rm -f "/tmp/${NAME}.zip" 2>/dev/null
                echo "  ✗ $CNR_ID (failed to download legacy commit)"
                NODES_FAILED=$((NODES_FAILED + 1))
                ERRORS+=("NODE: $CNR_ID — legacy commit download failed")
                return 1
            fi
        else
        # git clone (no cm-cli — slow, causes timeouts, leaves partial state)
        if ! timeout 120 git clone --depth=1 --recurse-submodules "$REPO_URL" "$NODE_DIR" 2>/dev/null; then
            rm -rf "$NODE_DIR" 2>/dev/null
            # Try zip fallback: main first, then master
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
                # Clean up failed attempt (partial unzip, stale zip)
                rm -rf "$COMFY/custom_nodes/${NAME}-${BRANCH}" 2>/dev/null
                rm -f "/tmp/${NAME}.zip" 2>/dev/null
            done
            if [ "$ZIP_OK" -eq 0 ]; then
                echo "  ✗ $CNR_ID (failed to install)"
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
            echo "    installing dependencies..."
            # Strip torch/torchvision/torchaudio — already in venv, reinstalling breaks CUDA
            grep -viE '^\s*(torch|torchvision|torchaudio)\s*(\[|>|<|=|!|$|#)' "$NODE_DIR/requirements.txt" > /tmp/_reqs_filtered.txt 2>/dev/null || true
            if ! $PIP install -r /tmp/_reqs_filtered.txt $BSP 2>>"$COMFY/pip_errors.log"; then
                echo "    ⚠ pip requirements failed for $CNR_ID (see $COMFY/pip_errors.log)"
                DEP_WARNINGS=$((DEP_WARNINGS + 1))
            else
                HAS_REQS=1
            fi
        elif [ -f "$NODE_DIR/setup.py" ]; then
            echo "    running setup.py..."
            if ! $PIP install "$NODE_DIR" $BSP 2>>"$COMFY/pip_errors.log"; then
                echo "    ⚠ setup.py failed for $CNR_ID (see $COMFY/pip_errors.log)"
                DEP_WARNINGS=$((DEP_WARNINGS + 1))
            else
                HAS_REQS=1
            fi
        fi
        if [ -f "$NODE_DIR/install.py" ]; then
            echo "    running install.py..."
            if ! (cd "$NODE_DIR" && $PYTHON install.py 2>&1); then
                echo "    ⚠ install.py failed for $CNR_ID"
                DEP_WARNINGS=$((DEP_WARNINGS + 1))
            fi
        fi
        # TASK-048: Skip extra deps if requirements.txt/setup.py installed successfully
        # (EXTRA_DEPS typically duplicate what requirements.txt already provides)
        if [ -n "$EXTRA_DEPS" ] && [ "$HAS_REQS" -eq 0 ]; then
            echo "    installing extra deps: $EXTRA_DEPS"
            if ! $PIP install $EXTRA_DEPS $BSP 2>>"$COMFY/pip_errors.log"; then
                echo "    ⚠ extra deps failed for $CNR_ID (see $COMFY/pip_errors.log)"
                DEP_WARNINGS=$((DEP_WARNINGS + 1))
            fi
        fi
    fi
    local ELAPSED=$(( $(date +%s) - NODE_START ))
    if [ "$DEP_WARNINGS" -gt 0 ]; then
        echo "  ⚠ $CNR_ID (${ELAPSED}s, $DEP_WARNINGS dep issue(s))"
        ERRORS+=("NODE-DEPS: $CNR_ID — $DEP_WARNINGS dependency issue(s)")
    else
        echo "  ✓ $CNR_ID (${ELAPSED}s)"
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
        echo ""
        echo "FATAL: Less than 2GB disk space remaining (${FREE}GB free). Aborting."
        echo "Increase disk size or remove unused models."
        ERRORS+=("DISK: Out of space — ${FREE}GB remaining")
        exit 1
    fi
}

filesize() { stat -Lc%s "$1" 2>/dev/null || stat -Lf%z "$1" 2>/dev/null || echo 0; }

# === HEAD Content-Type Verification (TASK-052) ===
# Returns 0 if URL is safe to download, 1 if content-type is suspicious.
# Skips check for CivitAI (redirect chains) and when --verify-downloads is off.
verify_content_type() {
    [ "$VERIFY_DOWNLOADS" -eq 0 ] && return 0
    local URL="$1"
    local DISPLAY="$2"
    # Skip CivitAI — redirect chains return misleading content-type
    case "$URL" in *civitai.com*) return 0 ;; esac
    # HEAD request with 10s timeout — capture both HTTP code and content-type
    # Use -X HEAD (not -I) so -o /dev/null suppresses all output, leaving only -w on stdout
    # Single HEAD request — use "|" delimiter (never appears in MIME types or HTTP codes)
    local RESP
    local AUTH_HEADER=""
    if [ -n "${HF_TOKEN:-}" ] && echo "$URL" | grep -q "huggingface.co"; then
        AUTH_HEADER="Authorization: Bearer $HF_TOKEN"
    fi
    RESP=$(curl -s -X HEAD -m 10 -o /dev/null -w "%{http_code}|%{content_type}" -L ${AUTH_HEADER:+-H "$AUTH_HEADER"} "$URL" 2>/dev/null) || return 0
    local HTTP_CODE="${RESP%%|*}"
    local CT="${RESP#*|}"
    # If HEAD returns empty, fails, or non-2xx — allow download (CDN may not support HEAD,
    # or file may be on a non-default branch that returns 404 for /resolve/main/)
    [ -z "$CT" ] && return 0
    case "$HTTP_CODE" in 2??) ;; *) return 0 ;; esac
    # Extract base MIME type (strip charset etc.)
    local MIME="${CT%%;*}"
    MIME=$(echo "$MIME" | tr "[:upper:]" "[:lower:]" | xargs)
    case "$MIME" in
        text/html|text/plain|application/json|text/x-python|text/xml|text/csv)
            echo "  ⚠ $DISPLAY — HEAD check: suspicious content-type '$MIME', skipping download"
            # No ERRORS/MODELS_FAILED here — verify_model will report as "missing"
            return 1
            ;;
    esac
    return 0
}

# === Download wrapper: wget → curl fallback ===
dl_file() {
    # Usage: dl_file [-c] [-H "Header: val"]... -O <output> <url>
    # Translates wget-style args to curl if wget is missing
    local RESUME="" OUTPUT="" HEADERS=() URL=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -c) RESUME=1; shift ;;
            -O) OUTPUT="$2"; shift 2 ;;
            --header=*) HEADERS+=("${1#--header=}"); shift ;;
            --header) HEADERS+=("$2"); shift 2 ;;
            --*) shift ;;  # ignore other wget flags
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
    mkdir -p "$DEST_DIR"
    if [ -f "$MODEL_PATH" ]; then
        local ACTUAL=$(filesize "$MODEL_PATH")
        if [ "$ACTUAL" -gt $(min_size_for_path "$MODEL_PATH") ]; then
            echo "  ✓ $DISPLAY (exists)"
            return 0
        fi
    fi
    verify_content_type "https://huggingface.co/${REPO}/resolve/main/${FILE// /%20}" "$DISPLAY" || return 1
    echo "  ⬇ $DISPLAY ..."
    if $PYTHON /tmp/hf_download.py "$REPO" "$FILE" "$DEST_DIR" 0 "$(min_size_for_path "$MODEL_PATH")"; then
        if [ -n "$RENAME_TO" ] && [ "$BASENAME" != "$RENAME_TO" ]; then
            mv "$DEST_DIR/$BASENAME" "$DEST_DIR/$RENAME_TO" 2>/dev/null || true
        fi
        BYTES_DOWNLOADED=$((BYTES_DOWNLOADED + $(filesize "$MODEL_PATH")))
        echo "  ✓ $DISPLAY (done)"
    elif [ -n "$FALLBACK_URL" ]; then
        echo "    ↳ HF failed, trying CivitAI fallback..."
        download_civitai "$FALLBACK_URL" "$DEST_DIR" "$DISPLAY"
    else
        echo "  ✗ $DISPLAY (FAILED)"
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
    mkdir -p "$DEST_DIR"
    if [ -f "$MODEL_PATH" ]; then
        local ACTUAL=$(filesize "$MODEL_PATH")
        if [ "$ACTUAL" -gt $(min_size_for_path "$MODEL_PATH") ]; then
            echo "  ✓ $FILENAME (exists)"
            return 0
        fi
    fi
    echo "  ⬇ $FILENAME ..."
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
            echo "    ↳ aria2c failed, retrying..."
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
        # Detect HTML garbage — CivitAI may return error page instead of model
        if head -c 100 "$MODEL_PATH" 2>/dev/null | grep -qiE "<!doctype|<html|{\s*\"error\""; then
            if head -c 500 "$MODEL_PATH" 2>/dev/null | grep -qi "logged in\|Unauthorized\|requires you"; then
                echo "  ✗ $FILENAME (CivitAI login-only — download manually from browser)"
                ERRORS+=("MODEL: $FILENAME — creator requires CivitAI login. Download manually: open the model page on civitai.com, download the file, and upload to $DEST_DIR/")
            else
                echo "  ✗ $FILENAME (received HTML/JSON error instead of model)"
                ERRORS+=("MODEL: $FILENAME (CivitAI returned error page, may need browser download)")
            fi
            rm -f "$MODEL_PATH"
            MODELS_FAILED=$((MODELS_FAILED + 1))
            check_disk_space
            return 1
        fi
        # Auto-detect ZIP by magic bytes (PK\x03\x04) — CivitAI API may not flag it
        if head -c4 "$MODEL_PATH" 2>/dev/null | od -An -tx1 -N4 | grep -q "50 4b 03 04"; then
            echo "    ↳ ZIP detected, extracting $FILENAME..."
            local TMP_ZIP="${MODEL_PATH}.zip"
            mv "$MODEL_PATH" "$TMP_ZIP"
            local INNER=$(unzip -l "$TMP_ZIP" 2>/dev/null | grep -iE "\.(safetensors|pth|pt|ckpt|bin|gguf)$" | awk '{print $NF}' | head -1)
            if [ -n "$INNER" ]; then
                unzip -jo "$TMP_ZIP" "$INNER" -d "$DEST_DIR" 2>/dev/null && mv "$DEST_DIR/$(basename "$INNER")" "$MODEL_PATH" 2>/dev/null
                rm -f "$TMP_ZIP"
                BYTES_DOWNLOADED=$((BYTES_DOWNLOADED + $(filesize "$MODEL_PATH")))
                echo "  ✓ $FILENAME (extracted from ZIP)"
            else
                mv "$TMP_ZIP" "$MODEL_PATH"
                BYTES_DOWNLOADED=$((BYTES_DOWNLOADED + $(filesize "$MODEL_PATH")))
                echo "  ⚠ $FILENAME (ZIP but no model found inside)"
            fi
        else
            BYTES_DOWNLOADED=$((BYTES_DOWNLOADED + $(filesize "$MODEL_PATH")))
            echo "  ✓ $FILENAME (done)"
        fi
    else
        rm -f "$MODEL_PATH" "${MODEL_PATH}.aria2"
        echo "  ✗ $FILENAME (FAILED)"
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
            echo "  ✓ $DISPLAY_NAME"
            return 0
        else
            echo "  ✗ $DISPLAY_NAME (corrupted: ${ACTUAL} bytes)"
            MODELS_FAILED=$((MODELS_FAILED + 1))
            ERRORS+=("MODEL: $DISPLAY_NAME (corrupted)")
            return 1
        fi
    else
        echo "  ✗ $DISPLAY_NAME (missing)"
        MODELS_FAILED=$((MODELS_FAILED + 1))
        ERRORS+=("MODEL: $DISPLAY_NAME (missing)")
        return 1
    fi
}

# === onnxruntime-gpu CUDA fix (KB 3.1) ===
if [ "$CUDA_VER" -ge 12 ]; then
  $PYTHON -m pip install onnxruntime-gpu --extra-index-url https://aiinfra.pkgs.visualstudio.com/PublicPackages/_packaging/onnxruntime-cuda-12/pypi/simple/ $BSP 2>/dev/null || true
fi

# === ComfyUI-Manager config (KB 4.2) ===
MANAGER_CFG="$COMFY/user/__manager/config.ini"
if [ -f "$MANAGER_CFG" ]; then
  sed -i 's/security_level = normal/security_level = weak/' "$MANAGER_CFG"
else
  mkdir -p "$COMFY/user/__manager"
  echo "[default]" > "$MANAGER_CFG"
  echo "security_level = weak" >> "$MANAGER_CFG"
fi

# === Update ComfyUI & Manager ===
# Pre-installed ComfyUI on cloud templates is often outdated — newer nodes need comfy_api.
echo "Updating ComfyUI & Manager..."
if [ -d "$COMFY/.git" ]; then
    git -C "$COMFY" pull --ff-only 2>/dev/null && echo "  ✓ ComfyUI updated (git)" || echo "  ⚠ ComfyUI git pull failed (non-critical)"
fi
$PIP install -q --upgrade comfyui $BSP 2>/dev/null || true

MANAGER_DIR="$COMFY/custom_nodes/ComfyUI-Manager"
if [ -d "$MANAGER_DIR/.git" ]; then
    git -C "$MANAGER_DIR" pull --ff-only 2>/dev/null && echo "  ✓ ComfyUI-Manager updated" || echo "  ⚠ ComfyUI-Manager pull failed (non-critical)"
fi

# === Stop ComfyUI (TASK-029) ===
# Nodes installed while ComfyUI is running are not registered.
# Stop it now, install everything, then start fresh at the end.
COMFY_WAS_RUNNING=0
# Pause supervisord task if present (Vast.ai / RunPod managed images)
if command -v supervisorctl &>/dev/null; then
    supervisorctl stop comfyui 2>/dev/null || true
    supervisorctl stop comfy 2>/dev/null || true
fi
COMFY_PID=$(pgrep -f "python.*main.py.*--listen" 2>/dev/null || true)
if [ -n "$COMFY_PID" ]; then
    COMFY_WAS_RUNNING=1
    echo "Stopping ComfyUI (PID $COMFY_PID) for clean node installation..."
    kill "$COMFY_PID" 2>/dev/null
    for i in $(seq 1 15); do
        kill -0 "$COMFY_PID" 2>/dev/null || break
        sleep 1
    done
    kill -0 "$COMFY_PID" 2>/dev/null && kill -9 "$COMFY_PID" 2>/dev/null
    sleep 2
    echo "  ✓ ComfyUI stopped"
else
    echo "ComfyUI not running — proceeding with installation"
fi

echo -e "\n=== Installing Custom Nodes ==="

install_node 'comfyui_layerstyle' 'https://github.com/chflame163/ComfyUI_LayerStyle' 'numpy pillow torch matplotlib Scipy scikit_image scikit_learn opencv-contrib-python pymatting segment_anything timm addict yapf colour-science wget mediapipe loguru typer_config fastapi rich google-generativeai diffusers omegaconf tqdm transformers kornia image-reward ultralytics blend_modes blind-watermark qrcode pyzbar transparent-background huggingface_hub accelerate bitsandbytes torchscale wandb hydra-core psd-tools inference-cli[yolo-world] inference-gpu[yolo-world] onnxruntime peft iopath' ''
install_node 'was-node-suite-comfyui' 'https://github.com/WASasquatch/was-node-suite-comfyui' 'cmake fairscale git+https://github.com/WASasquatch/img2texture.git git+https://github.com/WASasquatch/cstr gitpython imageio joblib matplotlib numba numpy opencv-python-headless[ffmpeg] pilgram git+https://github.com/WASasquatch/ffmpy.git rembg scikit-image scikit-learn scipy timm tqdm transformers' ''
install_node 'comfyui-easy-use' 'https://github.com/yolain/ComfyUI-Easy-Use' 'diffusers accelerate clip_interrogator sentencepiece lark onnxruntime spandrel opencv-python-headless matplotlib peft' ''
install_node 'comfyui_essentials' 'https://github.com/cubiq/ComfyUI_essentials' 'numba colour-science rembg pixeloe' ''
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
install_node 'comfyui-depthcrafter-nodes' 'https://github.com/akatz-ai/ComfyUI-DepthCrafter-Nodes' 'torch diffusers accelerate' ''
install_node 'comfyui-videohelpersuite' 'https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite' 'opencv-python imageio-ffmpeg' ''
install_node 'comfyui_controlnet_aux' 'https://github.com/Fannovel16/comfyui_controlnet_aux' 'mediapipe==0.10.14' ''
install_node 'rgthree-comfy' 'https://github.com/rgthree/rgthree-comfy' '' ''
install_node 'comfyui-wanvideowrapper' 'https://github.com/kijai/ComfyUI-WanVideoWrapper' '' ''
install_node 'comfyui-various' 'https://github.com/jamesWalker55/comfyui-various' '' ''
install_node 'comfyui-custom-scripts' 'https://github.com/pythongosssss/ComfyUI-Custom-Scripts' '' ''
# WARNING: 'segment-anything-2' — no known repo. Types: DownloadAndLoadSAM2Model, Sam2Segmentation
NODES_TOTAL=$((NODES_TOTAL + 1))
NODES_FAILED=$((NODES_FAILED + 1))
ERRORS+=("NODE: Could not resolve repo for 'segment-anything-2'")
install_node 'comfyui-framepacking' 'https://github.com/rishipandey125/ComfyUI-FramePacking' '' ''
install_node 'comfyui-inpaint-cropandstitch' 'https://github.com/lquesada/ComfyUI-Inpaint-CropAndStitch' '' ''
install_node 'comfyui-allor' 'https://github.com/Nourepide/ComfyUI-Allor' '' ''
install_node 'comfyui-normalcrafterwrapper' 'https://github.com/AIWarper/ComfyUI-NormalCrafterWrapper' '' ''
install_node 'comfyui_comfyroll_customnodes' 'https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes' '' ''
install_node 'comfyui-followyouremojiwrapper' 'https://github.com/kijai/ComfyUI-FollowYourEmojiWrapper' '' ''
install_node 'derfuu_comfyui_moddednodes' 'https://github.com/Derfuu/Derfuu_ComfyUI_ModdedNodes' '' ''
install_node 'comfyliterals' 'https://github.com/M1kep/ComfyLiterals' '' ''
echo -e "\n=== Checking ComfyUI module compatibility ==="
COMFY_COMPAT_OK=1
for MOD in comfy.ldm.flux.model comfy.ldm.chroma.model comfy.ldm.wan.model comfy.ldm.hunyuan_video.model comfy.ldm.hidream.model; do
    if $PYTHON -c "import sys; sys.path.insert(0, '$COMFY'); __import__('$MOD')" 2>/dev/null; then
        echo "  ✓ $MOD"
    else
        echo "  ✗ $MOD — MISSING (may break nodes that depend on it)"
        COMFY_COMPAT_OK=0
    fi
done
if [ "$COMFY_COMPAT_OK" -eq 0 ]; then
    echo "  ⚠ Some ComfyUI modules missing — updating ComfyUI..."
    git -C "$COMFY" pull --ff-only 2>/dev/null || true
fi

echo -e "\n=== Downloading Models ==="

# === Skipped (not resolved — add manually) ===
# 2 model(s) were not resolved and skipped from auto-download.
# Commented examples below show where each file goes. Download manually and
# place into the listed directory, or re-run generation after fixing the registry.

# [SKIPPED — not resolved] DWPreprocessor: yolox_l.onnx
# dest: $COMFY/custom_nodes/comfyui_controlnet_aux/ckpts/
# download_hf 'Bingsu/adetailer' 'yolox_l.onnx' "$COMFY/"'custom_nodes/comfyui_controlnet_aux/ckpts'

# [SKIPPED — not resolved] DWPreprocessor: dw-ll_ucoco_384_bs5.torchscript.pt
# dest: $COMFY/custom_nodes/comfyui_controlnet_aux/ckpts/
# download_hf 'yzd-v/DWPose' 'dw-ll_ucoco_384_bs5.torchscript.pt' "$COMFY/"'custom_nodes/comfyui_controlnet_aux/ckpts'

download_hf 'Ludka8008/Ava' 'Ava_000001750.safetensors' "$COMFY/"'models/loras/wanvideo' 'arnold_schwarzenegger.safetensors'
download_hf 'Kijai/WanVideo_comfy' 'Wan21_CausVid_14B_T2V_lora_rank32.safetensors' "$COMFY/"'models/loras/wanvideo'
download_hf 'Kijai/WanVideo_comfy' 'Wan2_1_VAE_bf16.safetensors' "$COMFY/"'models/vae/wanvideo'
download_hf 'notkenski/upscalers' '4x_NMKD-Superscale-SP_178000_G.pth' "$COMFY/"'models/upscale_models'
download_hf 'Kijai/WanVideo_comfy' 'umt5-xxl-enc-bf16.safetensors' "$COMFY/"'models/clip'
download_hf 'Kijai/WanVideo_comfy' 'Wan2_1-T2V-14B_fp8_e4m3fn.safetensors' "$COMFY/"'models/diffusion_models/wanvideo'
download_hf 'Kijai/sam2-safetensors' 'sam2.1_hiera_large.safetensors' "$COMFY/"'models/sam2'
download_hf 'Kijai/WanVideo_comfy' 'Wan2_1-VACE_module_14B_bf16.safetensors' "$COMFY/"'models/upscale_models/wanvideo'

# === Verify Downloads (KB 1.7) ===
echo -e "\n=== Verifying model files ==="
verify_model "$COMFY/"'models/loras/wanvideo/arnold_schwarzenegger.safetensors' 'arnold_schwarzenegger.safetensors'
verify_model "$COMFY/"'models/loras/wanvideo/Wan21_CausVid_14B_T2V_lora_rank32.safetensors' 'Wan21_CausVid_14B_T2V_lora_rank32.safetensors'
verify_model "$COMFY/"'models/vae/wanvideo/Wan2_1_VAE_bf16.safetensors' 'Wan2_1_VAE_bf16.safetensors'
verify_model "$COMFY/"'models/upscale_models/4x_NMKD-Superscale-SP_178000_G.pth' '4x_NMKD-Superscale-SP_178000_G.pth'
verify_model "$COMFY/"'models/clip/umt5-xxl-enc-bf16.safetensors' 'umt5-xxl-enc-bf16.safetensors'
verify_model "$COMFY/"'models/diffusion_models/wanvideo/Wan2_1-T2V-14B_fp8_e4m3fn.safetensors' 'Wan2_1-T2V-14B_fp8_e4m3fn.safetensors'
verify_model "$COMFY/"'models/sam2/sam2.1_hiera_large.safetensors' 'sam2.1_hiera_large.safetensors'
verify_model "$COMFY/"'models/upscale_models/wanvideo/Wan2_1-VACE_module_14B_bf16.safetensors' 'Wan2_1-VACE_module_14B_bf16.safetensors'


# === sage-attention (performance) ===
$PIP install -q sageattention $BSP 2>/dev/null || true

# === Start ComfyUI (KB 4.3) ===
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

# === Temp File Cleanup (KB 8) ===
rm -f /tmp/*.zip /tmp/hf_download.py 2>/dev/null || true

# === Final Report (KB 4.2, 7) ===
TOTAL_SECONDS=$(( $(date +%s) - START_TIME ))
TOTAL_TIME=$(( TOTAL_SECONDS / 60 ))
DL_GB=$(awk "BEGIN{printf \"%.1f\", $BYTES_DOWNLOADED/1073741824}")
if [ "$TOTAL_SECONDS" -gt 0 ] && [ "$BYTES_DOWNLOADED" -gt 0 ]; then
    DL_SPEED=$(awk "BEGIN{printf \"%.1f\", $BYTES_DOWNLOADED/1048576/$TOTAL_SECONDS}")
else
    DL_SPEED="0"
fi
echo ""
echo "=== Setup Report ==="
echo "Nodes installed: $((NODES_TOTAL - NODES_FAILED))/$NODES_TOTAL"
echo "Models downloaded: $((MODELS_TOTAL - MODELS_FAILED))/$MODELS_TOTAL"
echo "Skipped (MANUALLY DOWNLOAD): 2 model(s) — see '=== Skipped (not resolved) ===' block above"
echo "Total downloaded: ${DL_GB} GB (avg ${DL_SPEED} MB/s)"
if [ "$MODELS_RENAMED" -gt 0 ]; then echo "Models renamed: $MODELS_RENAMED (same files, renamed to match your workflow)"; fi
echo "Total setup time: ${TOTAL_TIME} minutes"

if [ ${#ERRORS[@]} -gt 0 ]; then
  echo ""
  echo "=== ERRORS ==="
  for err in "${ERRORS[@]}"; do echo "  ✗ $err"; done
  echo ""
  echo "Fix the issues above and re-run the script."
fi

# === Disable rgthree frontend extension (ComfyUI 0.18+ compat) ===
# rgthree JS patches queuePrompt and crashes on 0.18+. Backend nodes still work.
COMFY_SETTINGS="$COMFY/user/default/comfy.settings.json"
mkdir -p "$COMFY/user/default"
if [ -f "$COMFY_SETTINGS" ]; then
    # Merge into existing settings — add to Comfy.Extension.Disabled array
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
echo "  ✓ rgthree frontend extension disabled (backend nodes still work)"

# === Patch PyTorch 2.6 weights_only default ===
COMFY_UTILS="$COMFY/comfy/utils.py"
if [ -f "$COMFY_UTILS" ] && grep -q "weights_only=True" "$COMFY_UTILS"; then
    sed -i 's/weights_only=True/weights_only=False/g' "$COMFY_UTILS"
    echo "  ✓ Patched torch.load weights_only for PyTorch 2.6+ compatibility"
fi

echo -e "\n=== Starting ComfyUI ==="

PORT=18188

# Kill any leftover ComfyUI process (belt-and-suspenders)
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

# Fresh start — nodes installed offline will be discovered on boot
# Prefer supervisord if it was managing ComfyUI (Vast.ai / RunPod managed images)
STARTED_VIA_SUPERVISOR=0
if command -v supervisorctl &>/dev/null; then
    for SVC in comfyui comfy; do
        if supervisorctl start "$SVC" 2>/dev/null | grep -q "started"; then
            echo "  ComfyUI started via supervisord ($SVC)"
            STARTED_VIA_SUPERVISOR=1
            break
        fi
    done
fi
if [ "$STARTED_VIA_SUPERVISOR" -eq 0 ]; then
    nohup bash "$COMFY/start.sh" > "$COMFY/comfyui.log" 2>&1 &
    echo "  ComfyUI started (PID $!)"
fi

# Wait for server to become ready
READY=0
for i in $(seq 1 60); do
    if curl -s --max-time 2 "http://127.0.0.1:$PORT/system_stats" > /dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 1
done

if [ "$READY" -eq 1 ]; then
    echo "  ✓ ComfyUI is ready on port $PORT"
    # Trigger Manager refresh for node list sync
    curl -s --max-time 5 "http://127.0.0.1:$PORT/manager/reboot" -X POST > /dev/null 2>&1 || true
    sleep 3
    # Wait for server after Manager reboot
    for i in $(seq 1 30); do
        if curl -s --max-time 2 "http://127.0.0.1:$PORT/system_stats" > /dev/null 2>&1; then
            echo "  ✓ ComfyUI ready after Manager refresh"
            break
        fi
        sleep 1
    done
else
    echo "  ⚠ ComfyUI did not respond within 60s — check logs: tail -f $COMFY/comfyui.log"
fi

echo -e "\n=== Setup Complete ==="
echo "$MODELS_TOTAL models, $NODES_TOTAL custom nodes"
echo "Log: tail -f $COMFY/comfyui.log"

echo ""
echo "✓ ComfyUI started fresh — all nodes should work. Open browser and refresh the page (F5)."
