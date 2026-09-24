#!/usr/bin/env bash
# =====================================================================
# IRSTD Paper Daily 本地一键脚本（Git Bash / Linux / macOS）
#
# 流程：抓取 arXiv -> 生成 README / GitHub Pages / 微信版
#       -> Server酱微信通知 -> SMTP 邮件日报 -> git 提交 -> git push
#
# 常用：
#   bash run_daily.sh                 增量抓取 + 通知 + 提交推送
#   bash run_daily.sh --full-refresh  忽略增量水位，重扫全部历史
#   bash run_daily.sh --backfill-code 只为历史论文补代码链接
#   bash run_daily.sh --check         只检查环境，不抓取
#   bash run_daily.sh --dry-run       只打印将要执行的命令
#
# 参数：
#   --full-refresh      传给程序：忽略增量水位，全量重扫
#   --backfill-code     传给程序：为历史论文补齐代码链接
#   --config PATH       传给程序：--config_path PATH（默认 config.yaml）
#   --no-notify         跳过微信通知
#   --no-email          跳过邮件日报
#   --no-pull           提交前不执行 git pull --rebase
#   --no-push           只本地提交，不推送
#   --no-commit         只生成文件，不提交也不推送
#   --message TEXT      自定义提交信息
#   --check             环境自检后退出
#   --dry-run           只打印将要执行的命令
#   -h | --help         显示帮助
#
# 可在仓库根目录放一个 .env（已加入 .gitignore）保存密钥：
#   SERVERCHAN_SENDKEY                     Server酱 SendKey
#   SMTP_HOST/SMTP_USERNAME/SMTP_PASSWORD/EMAIL_TO   邮件通知
#   GITHUB_TOKEN                           提高 GitHub 代码搜索限额（可选）
#   DAILY_ARXIV_PYTHON                     覆盖解释器路径（可选）
# =====================================================================

set -uo pipefail

# 直接用 PowerShell 调用 D:\GIT\Git\bin\bash.exe 时，PATH 可能缺少 MSYS 工具目录，
# 这里按 bash 自身位置补全 /usr/bin、/mingw64/bin，保证 date、sed 等命令可用。
if [[ -n "${BASH:-}" ]]; then
    _bash_root="${BASH%/*}"      # 例如 /d/GIT/Git/bin
    _bash_root="${_bash_root%/bin}"
    for _extra in "$_bash_root/usr/bin" "$_bash_root/mingw64/bin" "$_bash_root/bin" "/usr/bin" "/bin"; do
        case ":$PATH:" in
            *":$_extra:"*) ;;
            *) [[ -d "$_extra" ]] && PATH="$_extra:$PATH" ;;
        esac
    done
    export PATH
    unset _bash_root _extra
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd -- "$SCRIPT_DIR" || { printf '无法进入脚本目录: %s\n' "$SCRIPT_DIR" >&2; exit 1; }

# Windows 控制台默认 GBK，强制子进程使用 UTF-8，避免中文日志乱码或编码报错
export PYTHONIOENCODING="${PYTHONIOENCODING:-utf-8}"
export PYTHONUTF8="${PYTHONUTF8:-1}"

ENV_NAME="daily_arxiv"
ENV_FILE="$SCRIPT_DIR/.env"
CONFIG_PATH="config.yaml"
COMMIT_MESSAGE="chore: update IRSTD paper daily"

GENERATED_FILES=(
    "README.md"
    "docs/irstd-paper-daily.json"
    "docs/irstd-paper-daily-state.json"
    "docs/irstd-paper-daily-wechat.json"
    "docs/index.md"
    "docs/wechat.md"
)

FULL_REFRESH=0
BACKFILL_CODE=0
SEND_WECHAT=1
SEND_EMAIL=1
DO_PULL=1
DO_PUSH=1
DO_COMMIT=1
CHECK_ONLY=0
DRY_RUN=0

STEP=0
START_SECONDS=$SECONDS

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] 警告: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { printf '[%s] 错误: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }
step() { STEP=$((STEP + 1)); printf '\n[%s] ==== 步骤 %d: %s ====\n' "$(date '+%H:%M:%S')" "$STEP" "$*"; }

usage() {
    cat <<'USAGE'
IRSTD Paper Daily 本地一键脚本

用法: bash run_daily.sh [选项]

  （无选项）          增量抓取 + 微信/邮件通知 + 提交并推送
  --full-refresh      忽略增量水位，重扫历史全部论文
  --backfill-code     只为历史论文补齐代码链接
  --config PATH       指定配置文件（默认 config.yaml）
  --no-notify         跳过微信通知
  --no-email          跳过邮件日报
  --no-pull           提交前不执行 git pull --rebase
  --no-push           只本地提交，不推送
  --no-commit         只生成文件，不提交也不推送
  --message TEXT      自定义提交信息
  --check             环境自检后退出，不抓取
  --dry-run           只打印将要执行的命令
  -h, --help          显示本帮助

密钥与开关放在仓库根目录 .env（已 gitignore，模板见 .env.example）：
  SERVERCHAN_SENDKEY / SMTP_HOST / SMTP_USERNAME / SMTP_PASSWORD / EMAIL_TO
  GITHUB_TOKEN（可选，提高代码仓库搜索限额）
  DAILY_ARXIV_PYTHON（可选，覆盖解释器路径）
USAGE
}

parse_args() {
    while (($#)); do
        case "$1" in
            --full-refresh)  FULL_REFRESH=1 ;;
            --backfill-code) BACKFILL_CODE=1 ;;
            --config)
                shift
                [[ $# -gt 0 ]] || die "--config 需要跟一个配置文件路径"
                CONFIG_PATH="$1"
                ;;
            --config=*) CONFIG_PATH="${1#*=}" ;;
            --no-notify) SEND_WECHAT=0 ;;
            --no-email)  SEND_EMAIL=0 ;;
            --no-pull)   DO_PULL=0 ;;
            --no-push)   DO_PUSH=0 ;;
            --no-commit) DO_COMMIT=0; DO_PUSH=0 ;;
            --message)
                shift
                [[ $# -gt 0 ]] || die "--message 需要跟一段提交信息"
                COMMIT_MESSAGE="$1"
                ;;
            --message=*) COMMIT_MESSAGE="${1#*=}" ;;
            --check)   CHECK_ONLY=1 ;;
            --dry-run) DRY_RUN=1 ;;
            -h|--help) usage; exit 0 ;;
            *) die "未知参数: $1（用 --help 查看用法）" ;;
        esac
        shift
    done
}

# 读取 .env：只处理 KEY=VALUE（可带 export 前缀），忽略空行与 # 注释
load_env_file() {
    [[ -f "$ENV_FILE" ]] || return 0
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" == \#* ]] && continue
        line="${line#export }"
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        key="${key//[[:space:]]/}"
        [[ -n "$key" ]] || continue
        if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then
            value="${value:1:${#value}-2}"
        fi
        export "$key=$value"
    done < "$ENV_FILE"
    log "已加载 $ENV_FILE"
}

# 固定使用 conda 环境 daily_arxiv；可用 DAILY_ARXIV_PYTHON 覆盖
resolve_python() {
    if [[ -n "${DAILY_ARXIV_PYTHON:-}" ]]; then
        printf '%s\n' "$DAILY_ARXIV_PYTHON"
        return 0
    fi
    local candidates=(
        "/d/MINICONDA/envs/$ENV_NAME/python.exe"
        "D:/MINICONDA/envs/$ENV_NAME/python.exe"
        "/c/MINICONDA/envs/$ENV_NAME/python.exe"
        "$HOME/miniconda3/envs/$ENV_NAME/bin/python"
        "$HOME/miniconda3/envs/$ENV_NAME/python.exe"
        "$HOME/anaconda3/envs/$ENV_NAME/bin/python"
    )
    local candidate
    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    if command -v conda >/dev/null 2>&1; then
        printf 'conda:%s\n' "$ENV_NAME"
        return 0
    fi
    return 1
}

current_branch() {
    git rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'main\n'
}

run_cmd() {
    if ((DRY_RUN)); then
        printf '[dry-run] %s\n' "$*"
        return 0
    fi
    printf '[%s] $ %s\n' "$(date '+%H:%M:%S')" "$*"
    "$@"
}

describe_secret() {
    local name="$1" label="$2" missing_note="${3:-未配置（将跳过）}"
    if [[ -n "${!name:-}" ]]; then
        printf '  %-18s %s\n' "$label" "已配置"
    else
        printf '  %-18s %s\n' "$label" "$missing_note"
    fi
}

describe_email() {
    local label="邮件(SMTP)"
    if [[ -n "${SMTP_HOST:-}" && -n "${SMTP_USERNAME:-}" \
          && -n "${SMTP_PASSWORD:-}" && -n "${EMAIL_TO:-}" ]]; then
        printf '  %-18s %s\n' "$label" "已配置"
    elif [[ -n "${SMTP_HOST:-}${SMTP_USERNAME:-}${SMTP_PASSWORD:-}${EMAIL_TO:-}" ]]; then
        printf '  %-18s %s\n' "$label" "配置不完整（将跳过）"
    else
        printf '  %-18s %s\n' "$label" "未配置（将跳过）"
    fi
}

main() {
    parse_args "$@"
    load_env_file

    step "环境自检"
    command -v git >/dev/null 2>&1 || die "找不到 git 命令"
    [[ -f "$CONFIG_PATH" ]] || die "找不到配置文件: $CONFIG_PATH"

    local python_ref python_cmd
    python_ref="$(resolve_python)" \
        || die "找不到 conda 环境 $ENV_NAME，请确认路径，或用 DAILY_ARXIV_PYTHON 指定解释器"
    if [[ "$python_ref" == conda:* ]]; then
        local conda_env="${python_ref#conda:}"
        PYTHON_CMD=(conda run --no-capture-output -n "$conda_env" python)
    else
        PYTHON_CMD=("$python_ref")
    fi
    [[ -x "${PYTHON_CMD[0]}" || "${PYTHON_CMD[0]}" == "conda" ]] \
        || die "解释器不可执行: ${PYTHON_CMD[0]}"

    log "仓库目录: $SCRIPT_DIR"
    log "配置文件: $CONFIG_PATH"
    log "解释器:   ${PYTHON_CMD[*]}"
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log "git 分支: $(current_branch)"
    else
        warn "当前目录不是 git 仓库，提交与推送步骤会失败"
    fi

    printf '\n依赖检查:\n'
    "${PYTHON_CMD[@]}" -c 'import sys, arxiv, yaml, requests; print("  Python %s | arxiv %s | PyYAML %s | requests %s" % (sys.version.split()[0], arxiv.__version__, yaml.__version__, requests.__version__))' \
        || die "daily_arxiv 环境依赖不完整，请执行: conda run -n daily_arxiv python -m pip install -r requirements.txt"

    printf '\n通知配置:\n'
    describe_secret SERVERCHAN_SENDKEY "微信(SendKey)"
    describe_email
    describe_secret GITHUB_TOKEN "GitHub Token" "未配置（代码搜索使用未认证限额）"

    if ((CHECK_ONLY)); then
        log "环境自检通过（--check 模式，未抓取任何论文）"
        exit 0
    fi

    if ((DO_PULL)); then
        step "同步远端"
        run_cmd git pull --rebase --autostash \
            || warn "git pull 失败，继续使用本地版本（推送阶段可能被拒绝）"
    fi

    step "抓取 arXiv 并生成日报"
    local py_args=("daily_arxiv.py" "--config_path" "$CONFIG_PATH")
    ((FULL_REFRESH)) && py_args+=("--full-refresh")
    ((BACKFILL_CODE)) && py_args+=("--backfill_code")
    if ((SEND_WECHAT)); then
        if [[ -n "${SERVERCHAN_SENDKEY:-}" ]]; then
            py_args+=("--notify-wechat" "--notify-unchanged")
        else
            warn "未设置 SERVERCHAN_SENDKEY，跳过微信通知（可写入 $ENV_FILE）"
        fi
    fi
    run_cmd "${PYTHON_CMD[@]}" "${py_args[@]}" || die \
        "抓取或渲染失败，已终止（未提交、未推送）。若日志出现 arXiv HTTP 406/403，通常是临时限流或 IP 被短暂封锁，等几分钟后重试。"

    if ((SEND_EMAIL)); then
        step "发送邮件日报"
        if [[ -n "${SMTP_HOST:-}" && -n "${SMTP_USERNAME:-}" \
              && -n "${SMTP_PASSWORD:-}" && -n "${EMAIL_TO:-}" ]]; then
            run_cmd "${PYTHON_CMD[@]}" -m arxiv_daily.emailer "docs/wechat.md" \
                || warn "邮件发送失败，继续处理提交"
        else
            warn "邮件配置不完整（需要 SMTP_HOST/SMTP_USERNAME/SMTP_PASSWORD/EMAIL_TO），跳过邮件"
        fi
    fi

    if ((DRY_RUN)); then
        log "dry-run 结束：以上命令均未真正执行"
        exit 0
    fi

    step "检查生成文件变化"
    local changed
    changed="$(git status --porcelain -- "${GENERATED_FILES[@]}")"
    if [[ -z "$changed" ]]; then
        log "生成文件没有变化，跳过提交与推送"
        print_summary
        exit 0
    fi
    printf '%s\n' "$changed"

    if ((DO_COMMIT)) && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        step "提交并推送"
        run_cmd git add -- "${GENERATED_FILES[@]}"
        git diff --cached --stat -- "${GENERATED_FILES[@]}"
        run_cmd git commit -m "$COMMIT_MESSAGE" \
            || warn "提交失败或无内容可提交"
        if ((DO_PUSH)); then
            run_cmd git push origin "$(current_branch)" \
                || die "git push 失败：请检查远端权限、网络或先手动解决分支差异"
        else
            log "已按 --no-push 跳过推送"
        fi
    else
        log "已跳过提交与推送（--no-commit 或当前目录不是 git 仓库）"
    fi

    print_summary
}

print_summary() {
    local elapsed=$((SECONDS - START_SECONDS))
    printf '\n'
    log "全部完成，用时 $((elapsed / 60)) 分 $((elapsed % 60)) 秒"
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log "最新提交: $(git log -1 --pretty='%h %s' 2>/dev/null)"
    fi
}

main "$@"
