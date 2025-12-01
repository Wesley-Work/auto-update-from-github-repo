#!/bin/bash

set -e

# === 全局变量 ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
VERSION_FILE="$SCRIPT_DIR/version.json"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/update-$(date '+%Y-%m-%d').log"

# 初始化日志
exec > >(tee -a "$LOG_FILE") 2>&1

# === 日志函数 ===
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    log "ERROR: $*" >&2
    exit 1
}

# === 依赖检查 ===
for cmd in jq curl unzip rsync; do
    command -v "$cmd" >/dev/null || error "❌ $cmd is required but not installed"
done

# SemVer 比较函数（兼容 Bash 3.2+）
# 返回: 0 if A > B, 1 if A == B, 2 if A < B
semver_compare() {
    local A="$1" B="$2"

    # 提取主版本（忽略 -alpha / +build 等）
    local A_MAIN="${A%%[-+]*}"
    local B_MAIN="${B%%[-+]*}"

    # 拆分 MAJOR.MINOR.PATCH
    IFS='.' read -r a_major a_minor a_patch <<< "$A_MAIN"
    IFS='.' read -r b_major b_minor b_patch <<< "$B_MAIN"

    # 补零（避免空值）
    a_major="${a_major:-0}"; a_minor="${a_minor:-0}"; a_patch="${a_patch:-0}"
    b_major="${b_major:-0}"; b_minor="${b_minor:-0}"; b_patch="${b_patch:-0}"

    # 比较主版本段（使用 eval 安全获取）
    for part in major minor patch; do
        eval "local a_val=\$a_$part"
        eval "local b_val=\$b_$part"
        if (( ${a_val:-0} > ${b_val:-0} )); then return 0; fi
        if (( ${a_val:-0} < ${b_val:-0} )); then return 2; fi
    done

    # 处理预发布部分
    local A_PRERELEASE="${A#"$A_MAIN"}"
    local B_PRERELEASE="${B#"$B_MAIN"}"
    [[ "$A_PRERELEASE" == -* ]] && A_PRERELEASE="${A_PRERELEASE#-}"
    [[ "$B_PRERELEASE" == -* ]] && B_PRERELEASE="${B_PRERELEASE#-}"

    # 无预发布 > 有预发布
    if [[ -z "$A_PRERELEASE" && -n "$B_PRERELEASE" ]]; then
        return 0
    elif [[ -n "$A_PRERELEASE" && -z "$B_PRERELEASE" ]]; then
        return 2
    elif [[ -z "$A_PRERELEASE" && -z "$B_PRERELEASE" ]]; then
        return 1
    fi

    # 拆分预发布标识（按 '.'）
    local a_pre b_pre i=0 a_seg b_seg
    IFS='.' read -ra a_pre <<< "$A_PRERELEASE"
    IFS='.' read -ra b_pre <<< "$B_PRERELEASE"

    while true; do
        a_seg="${a_pre[i]:-}"
        b_seg="${b_pre[i]:-}"

        if [[ -z "$a_seg" && -z "$b_seg" ]]; then
            return 1
        fi
        if [[ -z "$a_seg" ]]; then return 0; fi
        if [[ -z "$b_seg" ]]; then return 2; fi

        # 数值优先比较
        if [[ "$a_seg" =~ ^[0-9]+$ ]] && [[ "$b_seg" =~ ^[0-9]+$ ]]; then
            if (( a_seg > b_seg )); then return 0; fi
            if (( a_seg < b_seg )); then return 2; fi
        else
            if [[ "$a_seg" > "$b_seg" ]]; then return 0; fi
            if [[ "$a_seg" < "$b_seg" ]]; then return 2; fi
        fi
        ((i++))
    done
}

semver_gt() {
    semver_compare "$1" "$2"
    local res=$?
    return $(( res != 0 ))
}

# === GitHub API 请求封装 ===
github_api() {
    local url="$1"
    local headers=()
    if [ -n "$GITHUB_TOKEN" ]; then
        headers+=(-H "Authorization: token $GITHUB_TOKEN")
    fi
    curl -s "${headers[@]}" "$url"
}

# === 回滚函数 ===
rollback_to_version() {
    local target_ver="$1"
    [ -n "$target_ver" ] || error "❌ No version specified for rollback"

    # 读取配置
    REPO=$(jq -r '.repo // empty' "$CONFIG_FILE")
    TARGET_DIR=$(jq -r '.target_dir // empty' "$CONFIG_FILE")
    VP_DIR_NAME=$(jq -r '.version_package_dir // "VersionPackage"' "$CONFIG_FILE")
    VP_DIR="$TARGET_DIR/$VP_DIR_NAME"

    BACKUP_ZIP="$VP_DIR/${target_ver}.zip"
    [ -f "$BACKUP_ZIP" ] || error "❌ Backup not found: $BACKUP_ZIP"

    log ".Rollback: restoring version $target_ver from $BACKUP_ZIP"

    # 安全清空，保留 VersionPackage
    shopt -s dotglob nullglob
    for item in "$TARGET_DIR"/* "$TARGET_DIR"/.*; do
        if [ -e "$item" ]; then
            base=$(basename "$item")
            if [ "$base" != "." ] && [ "$base" != ".." ] && [ "$base" != "$VP_DIR_NAME" ]; then
                rm -rf "$item"
            fi
        fi
    done
    shopt -u dotglob nullglob

    # 解压备份
    unzip -q -o "$BACKUP_ZIP" -d "$TARGET_DIR" || error "❌ Rollback extraction failed"

    # 更新 version.json
    jq -n --arg ver "$target_ver" '{"current_version": $ver}' > "$VERSION_FILE"

    log "✅ Rollback to $target_ver completed successfully."
    exit 0
}

# === 主更新逻辑 ===
perform_update() {
    # 读取配置
    REPO=$(jq -r '.repo // empty' "$CONFIG_FILE")
    TARGET_DIR=$(jq -r '.target_dir // empty' "$CONFIG_FILE")
    VP_DIR_NAME=$(jq -r '.version_package_dir // "VersionPackage"' "$CONFIG_FILE")
    FILTER_EXCLUDE=($(jq -r '.filter_exclude[] // empty' "$CONFIG_FILE"))

    [ -n "$REPO" ] || error "❌ Missing 'repo' in config.json"
    [ -n "$TARGET_DIR" ] || error "❌ Missing 'target_dir'"

    VP_DIR="$TARGET_DIR/$VP_DIR_NAME"
    mkdir -p "$VP_DIR"

    # 读当前版本
    CURRENT_VERSION=""
    if [ -f "$VERSION_FILE" ]; then
        CURRENT_VERSION=$(jq -r '.current_version // ""' "$VERSION_FILE")
    fi

    # 获取最新 Release
    log "🚀 Fetching latest release for $REPO ..."
    RELEASE_API="https://api.github.com/repos/$REPO/releases/latest"
    LATEST_RELEASE=$(github_api "$RELEASE_API")

    if echo "$LATEST_RELEASE" | jq -e '.message // empty' >/dev/null; then
        error "❌ GitHub API error: $(echo "$LATEST_RELEASE" | jq -r '.message')"
    fi

    NEW_VERSION=$(echo "$LATEST_RELEASE" | jq -r '.tag_name // empty')
    [ -n "$NEW_VERSION" ] || error "❌ No tag_name in latest release"

    log "👉 Current version: ${CURRENT_VERSION:-<none>}"
    log "👉 Latest version:  $NEW_VERSION"

    if [ -n "$CURRENT_VERSION" ]; then
        if ! semver_gt "$NEW_VERSION" "$CURRENT_VERSION"; then
            log "🥱 No newer version available."
            exit 0
        fi
    else
        log "🤓 First-time install."
    fi

    # 从配置读取 asset.name 和 asset.type
    ASSET_NAME_PREFIX=$(jq -r '.asset.name // empty' "$CONFIG_FILE")
    ASSET_TYPE=$(jq -r '.asset.type // empty' "$CONFIG_FILE")
    
    [ -n "$ASSET_NAME_PREFIX" ] || error "❌ Missing 'asset.name' in config.json"
    # allow empty ASSET_TYPE
    # [ -n "$ASSET_TYPE" ] || error "❌ Missing 'asset.type' in config.json"
    
    FULL_PREFIX="${ASSET_NAME_PREFIX}-${ASSET_TYPE}BuildPackage"
    
    # 在最新 Release 的 assets 中查找匹配的 .zip
    ASSET_INFO=$(echo "$LATEST_RELEASE" | jq -r ".assets[] | select(.name | startswith(\"$FULL_PREFIX\") and endswith(\".zip\")) | .name + \"|\" + .browser_download_url" | head -n 1)
    
    if [ -z "$ASSET_INFO" ]; then
        error "❌ No asset found matching: ${FULL_PREFIX}*.zip"
    fi
    
    ASSET_FILENAME="${ASSET_INFO%|*}"
    ASSET_URL="gh.dlwk.top/${ASSET_INFO#*|}"
    
    log "📦 Use Asset: $ASSET_FILENAME"

    # 备份
    log "🤚 Starting backup..."
    if [ -n "$CURRENT_VERSION" ]; then
        BACKUP_PATH="$VP_DIR/${CURRENT_VERSION}.zip"
        log "📦 Creating backup at: $BACKUP_PATH"
        EXCLUDE_ARGS=()
        for excl in "${FILTER_EXCLUDE[@]}"; do
            EXCLUDE_ARGS+=(--exclude="$excl")
        done
        TEMP_BACKUP=$(mktemp -d)
        rsync -a "${EXCLUDE_ARGS[@]}" "$TARGET_DIR/" "$TEMP_BACKUP/"
        (cd "$TEMP_BACKUP" && zip -q -r "$BACKUP_PATH" .) || error "❌ Backup failed"
        rm -rf "$TEMP_BACKUP"
        log "✅ Backup saved"
    else
        log "⏭️ Skipping backup"
    fi

    # 下载并部署
    TEMP_DIR=$(mktemp -d)
    ZIP_PATH="$TEMP_DIR/release.zip"
    log "🤚 Downloading release..."
    curl --progress-bar -L -o "$ZIP_PATH" "$ASSET_URL" || error "❌ Download failed"
    # 复制新版本压缩包，存在即覆盖
    cp -f -v "$ZIP_PATH" "$VP_DIR/${NEW_VERSION}.zip"

    log "🚀 Deploying to $TARGET_DIR..."

    # 确保目标目录存在
    mkdir -p "$TARGET_DIR"
    
    # # 安全清空目录内容（包括隐藏文件），但跳过 . 和 ..
    # find "$TARGET_DIR" -mindepth 1 -exec rm -rf {} + 2>/dev/null || true

    # 安全清空，保留 VersionPackage
    shopt -s dotglob nullglob
    for item in "$TARGET_DIR"/* "$TARGET_DIR"/.*; do
        if [ -e "$item" ]; then
            base=$(basename "$item")
            if [ "$base" != "." ] && [ "$base" != ".." ] && [ "$base" != "$VP_DIR_NAME" ]; then
                rm -rf "$item"
            fi
        fi
    done
    shopt -u dotglob nullglob
    
    # 解压新版本
    unzip -q -o "$ZIP_PATH" -d "$TARGET_DIR" || error "❌ Extraction failed"
    
    # 清理临时文件
    rm -rf "$TEMP_DIR"

    # 更新版本记录
    jq -n --arg ver "$NEW_VERSION" '{"current_version": $ver}' > "$VERSION_FILE"
    log "✅ Successfully updated to $NEW_VERSION"
}

# === 主程序入口 ===

# 读取 GitHub Token（可选）
GITHUB_TOKEN=""
if [ -f "$SCRIPT_DIR/.token" ]; then
    GITHUB_TOKEN=$(cat "$SCRIPT_DIR/.token" | xargs)
fi

# 解析命令行参数
case "${1:-}" in
    --rollback)
        if [ -z "$2" ]; then
            error "❌ Usage: $0 --rollback <version>"
        fi
        rollback_to_version "$2"
        ;;
    --help|help|-h)
        cat <<EOF
Usage:
  $0                          # Check and update to latest release
  $0 --rollback <version>     # Rollback to a previous version (must exist in VersionPackage)

Configuration:
  - config.json: defines repo, target_dir, build_pattern, etc.
  - .token (optional): GitHub personal access token (one line)
  - Logs written to ./logs/

EOF
        exit 0
        ;;
    "")
        perform_update
        ;;
    *)
        error "❌ Unknown argument: $1. Use --help for usage."
        ;;
esac