#!/bin/bash

set -e

# === 全局路径 ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/update-$(date '+%Y-%m-%d').log"

# 同时输出到终端和日志
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
for cmd in jq curl unzip rsync zip; do
    command -v "$cmd" >/dev/null || error "❌ Required command '$cmd' not installed"
done

# === SemVer 比较函数 ===
semver_compare() {
    local A="$1" B="$2"
    local A_MAIN="${A%%[-+]*}" B_MAIN="${B%%[-+]*}"
    IFS='.' read -r a_major a_minor a_patch <<< "$A_MAIN"
    IFS='.' read -r b_major b_minor b_patch <<< "$B_MAIN"
    a_major="${a_major:-0}"; a_minor="${a_minor:-0}"; a_patch="${a_patch:-0}"
    b_major="${b_major:-0}"; b_minor="${b_minor:-0}"; b_patch="${b_patch:-0}"

    for part in major minor patch; do
        eval "local a_val=\$a_$part"
        eval "local b_val=\$b_$part"
        if (( ${a_val:-0} > ${b_val:-0} )); then return 0; fi
        if (( ${a_val:-0} < ${b_val:-0} )); then return 2; fi
    done

    local A_PRERELEASE="${A#"$A_MAIN"}"
    local B_PRERELEASE="${B#"$B_MAIN"}"
    [[ "$A_PRERELEASE" == -* ]] && A_PRERELEASE="${A_PRERELEASE#-}"
    [[ "$B_PRERELEASE" == -* ]] && B_PRERELEASE="${B_PRERELEASE#-}"

    if [[ -z "$A_PRERELEASE" && -n "$B_PRERELEASE" ]]; then return 0
    elif [[ -n "$A_PRERELEASE" && -z "$B_PRERELEASE" ]]; then return 2
    elif [[ -z "$A_PRERELEASE" && -z "$B_PRERELEASE" ]]; then return 1
    fi

    local a_pre b_pre i=0 a_seg b_seg
    IFS='.' read -ra a_pre <<< "$A_PRERELEASE"
    IFS='.' read -ra b_pre <<< "$B_PRERELEASE"

    while true; do
        a_seg="${a_pre[i]:-}"
        b_seg="${b_pre[i]:-}"
        if [[ -z "$a_seg" && -z "$b_seg" ]]; then return 1; fi
        if [[ -z "$a_seg" ]]; then return 0; fi
        if [[ -z "$b_seg" ]]; then return 2; fi
        if [[ "$a_seg" =~ ^[0-9]+$ ]] && [[ "$b_seg" =~ ^[0-9]+$ ]]; then
            (( a_seg > b_seg )) && return 0
            (( a_seg < b_seg )) && return 2
        else
            [[ "$a_seg" > "$b_seg" ]] && return 0
            [[ "$a_seg" < "$b_seg" ]] && return 2
        fi
        ((i++))
    done
}

semver_gt() {
    semver_compare "$1" "$2"
    local res=$?
    return $(( res != 0 ))
}

# === GitHub API 封装 ===
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
    local config_id="$1"
    local target_ver="$2"
    [ -n "$target_ver" ] || error "❌ Usage: $0 --rollback <config_id> <version>"

    local SINGLE_CONFIG VERSION_FILE_SINGLE REPO TARGET_DIR VP_DIR_NAME VP_DIR BACKUP_ZIP

    if jq -e 'type == "array"' "$CONFIG_FILE" >/dev/null; then
        local index=$(jq -r --arg id "$config_id" '
            to_entries[] | 
            select(
                (.value.id == $id) or 
                (.value.target_dir | sub("/$"; "") | split("/")[-1] // "" == $id)
            ) | .key
        ' "$CONFIG_FILE")
        if [ -z "$index" ] || [ "$index" = "null" ]; then
            error "❌ Config with id '$config_id' not found in config.json"
        fi
        SINGLE_CONFIG=$(mktemp)
        jq ".[$index]" "$CONFIG_FILE" > "$SINGLE_CONFIG"
        VERSION_FILE_SINGLE="$SCRIPT_DIR/version-$config_id.json"
    else
        SINGLE_CONFIG="$CONFIG_FILE"
        VERSION_FILE_SINGLE="$SCRIPT_DIR/version.json"
    fi

    REPO=$(jq -r '.repo // empty' "$SINGLE_CONFIG")
    TARGET_DIR=$(jq -r '.target_dir // empty' "$SINGLE_CONFIG")
    VP_DIR_NAME=$(jq -r '.version_package_dir // "VersionPackage"' "$SINGLE_CONFIG")
    set -f
    local NOT_REMOVE_FILE=($(jq -r '.notRemoveFile[] // empty' "$SINGLE_CONFIG"))
    set +f
    VP_DIR="$TARGET_DIR/$VP_DIR_NAME"
    BACKUP_ZIP="$VP_DIR/${target_ver}.zip"

    [ -f "$BACKUP_ZIP" ] || error "❌ Backup not found: $BACKUP_ZIP"
    log ".Rollback: restoring version $target_ver from $BACKUP_ZIP"

    mkdir -p "$TARGET_DIR"
    shopt -s dotglob nullglob
    for item in "$TARGET_DIR"/* "$TARGET_DIR"/.*; do
        if [ -e "$item" ]; then
            base=$(basename "$item")
            if [ "$base" != "." ] && [ "$base" != ".." ] && [ "$base" != "$VP_DIR_NAME" ]; then
                local skip_it=false
                for pattern in "${NOT_REMOVE_FILE[@]}"; do
                    local clean_p="${pattern%/}"
                    if [[ "$base" == $clean_p ]]; then
                        skip_it=true
                        break
                    fi
                done

                if [ "$skip_it" = "true" ]; then
                    log "⏭️  Rollback: skipping removal of $base"
                    continue
                fi
                rm -rf "$item"
            fi
        fi
    done
    shopt -u dotglob nullglob

    unzip -q -o "$BACKUP_ZIP" -d "$TARGET_DIR" || error "❌ Rollback extraction failed"
    jq -n --arg ver "$target_ver" '{"current_version": $ver}' > "$VERSION_FILE_SINGLE"
    log "✅ Rollback to $target_ver completed."
    rm -f "$SINGLE_CONFIG" 2>/dev/null
    exit 0
}

# === 更新单个配置 ===
perform_update_for_config() {
    local CONFIG_PATH="$1"
    local VERSION_PATH="$2"

    local REPO=$(jq -r '.repo // empty' "$CONFIG_PATH")
    local TARGET_DIR=$(jq -r '.target_dir // empty' "$CONFIG_PATH")
    local VP_DIR_NAME=$(jq -r '.version_package_dir // "VersionPackage"' "$CONFIG_PATH")
    set -f
    local FILTER_EXCLUDE=($(jq -r '.filter_exclude[] // empty' "$CONFIG_PATH"))
    local NOT_REMOVE_FILE=($(jq -r '.notRemoveFile[] // empty' "$CONFIG_PATH"))
    set +f
    local ASSET_NAME_PREFIX=$(jq -r '.asset.name // empty' "$CONFIG_PATH")
    local ASSET_TYPE=$(jq -r '.asset.type // empty' "$CONFIG_PATH")

    [ -n "$REPO" ] || error "❌ Missing 'repo' in config"
    [ -n "$TARGET_DIR" ] || error "❌ Missing 'target_dir'"
    [ -n "$ASSET_NAME_PREFIX" ] || error "❌ Missing 'asset.name'"

    local VP_DIR="$TARGET_DIR/$VP_DIR_NAME"
    mkdir -p "$VP_DIR"

    local CURRENT_VERSION=""
    [ -f "$VERSION_PATH" ] && CURRENT_VERSION=$(jq -r '.current_version // ""' "$VERSION_PATH")

    log "🚀 Fetching latest release for $REPO ..."
    local RELEASE_API="https://api.github.com/repos/$REPO/releases/latest"
    local LATEST_RELEASE=$(github_api "$RELEASE_API")

    if echo "$LATEST_RELEASE" | jq -e 'has("message")' >/dev/null; then
        ERROR_MSG=$(echo "$LATEST_RELEASE" | jq -r '.message')
        if [[ "$ERROR_MSG" == "Not Found" ]]; then
            log "⚠️  Repo $REPO has no releases. Skipping update."
            return 0  # 跳过，不报错
        else
            error "❌ GitHub API error for $REPO: $ERROR_MSG"
        fi
    fi

    local NEW_VERSION=$(echo "$LATEST_RELEASE" | jq -r '.tag_name // empty')
    [ -n "$NEW_VERSION" ] || error "❌ No tag_name in latest release"

    log "👉 Current version: ${CURRENT_VERSION:-<none>}"
    log "👉 Latest version:  $NEW_VERSION"

    if [ -n "$CURRENT_VERSION" ] && ! semver_gt "$NEW_VERSION" "$CURRENT_VERSION"; then
        log "🥱 No newer version available."
        return 0
    fi

    local FULL_PREFIX="${ASSET_NAME_PREFIX}-${ASSET_TYPE}BuildPackage"
    local ASSET_INFO=$(echo "$LATEST_RELEASE" | jq -r ".assets[] | select(.name | startswith(\"$FULL_PREFIX\") and endswith(\".zip\")) | .name + \"|\" + .browser_download_url" | head -n 1)

    [ -z "$ASSET_INFO" ] && error "❌ No asset found matching: ${FULL_PREFIX}*.zip"

    local ASSET_FILENAME="${ASSET_INFO%|*}"
    local ASSET_URL="gh.dlwk.top/${ASSET_INFO#*|}"
    log "📦 Use Asset: $ASSET_FILENAME"

    # === 备份当前版本（如果存在）===
    if [ -n "$CURRENT_VERSION" ]; then
        local BACKUP_PATH="$VP_DIR/${CURRENT_VERSION}.zip"
        if [ ! -f "$BACKUP_PATH" ]; then
            log "📦 Creating backup at: $BACKUP_PATH"
            local EXCLUDE_ARGS=()
            for excl in "${FILTER_EXCLUDE[@]}"; do
                EXCLUDE_ARGS+=(--exclude="$excl")
            done
            local TEMP_BACKUP=$(mktemp -d)
            rsync -a "${EXCLUDE_ARGS[@]}" "$TARGET_DIR/" "$TEMP_BACKUP/"
            (cd "$TEMP_BACKUP" && zip -q -r "$BACKUP_PATH" .) || error "❌ Backup failed"
            rm -rf "$TEMP_BACKUP"
            log "✅ Backup saved"
        else
            log "⏭️ Backup already exists, skipping."
        fi
    else
        log "⏭️ Skipping backup (no current version)"
    fi

    # === 下载新版本 ===
    local TEMP_DIR=$(mktemp -d)
    local ZIP_PATH="$TEMP_DIR/release.zip"
    log "🤚 Downloading release..."
    curl --progress-bar -L -o "$ZIP_PATH" "$ASSET_URL" || error "❌ Download failed"
    cp -f "$ZIP_PATH" "$VP_DIR/${NEW_VERSION}.zip"

    # === 部署新版本 ===
    log "🚀 Deploying to $TARGET_DIR..."
    mkdir -p "$TARGET_DIR"
    shopt -s dotglob nullglob
    for item in "$TARGET_DIR"/* "$TARGET_DIR"/.*; do
        if [ -e "$item" ]; then
            local base=$(basename "$item")
            if [ "$base" != "." ] && [ "$base" != ".." ] && [ "$base" != "$VP_DIR_NAME" ]; then
                local skip_it=false
                for pattern in "${NOT_REMOVE_FILE[@]}"; do
                    local clean_p="${pattern%/}"
                    if [[ "$base" == $clean_p ]]; then
                        skip_it=true
                        break
                    fi
                done

                if [ "$skip_it" = "true" ]; then
                    log "⏭️  Skipping removal of: $base"
                    continue
                fi
                rm -rf "$item"
            fi
        fi
    done
    shopt -u dotglob nullglob

    unzip -q -o "$ZIP_PATH" -d "$TARGET_DIR" || error "❌ Extraction failed"
    rm -rf "$TEMP_DIR"

    # === 更新版本记录 ===
    jq -n --arg ver "$NEW_VERSION" '{"current_version": $ver}' > "$VERSION_PATH"
    log "✅ Successfully updated to $NEW_VERSION"
}

# === 主程序入口 ===
GITHUB_TOKEN=""
[ -f "$SCRIPT_DIR/.token" ] && GITHUB_TOKEN=$(cat "$SCRIPT_DIR/.token" | xargs)
if [ -n "$GITHUB_TOKEN" ]; then
    log "👀 Use Token 🔐"
else
    log "🔐 No GitHub Token found, proceeding unauthenticated"
fi

case "${1:-}" in
    --rollback)
        if [ $# -ne 3 ]; then
            error "❌ Usage: $0 --rollback <config_id> <version>"
        fi
        rollback_to_version "$2" "$3"
        ;;
    --help|help|-h)
        cat <<EOF
Usage:
  $0                          # Update all configs in config.json
  $0 --rollback <config_id> <version>

Config.json format:
  - Single config (object): legacy mode
  - Multi-config (array): each item must have 'repo', 'target_dir', 'asset.name'
    Optional: 'id' (used for version file), 'version_package_dir', 'filter_exclude'

Version files: version-<id>.json (or version.json for single config)
Logs: ./logs/update-YYYY-MM-DD.log
EOF
        exit 0
        ;;
    "")
        if jq -e 'type == "array"' "$CONFIG_FILE" >/dev/null; then
            count=$(jq 'length' "$CONFIG_FILE")
            log "📁 Processing $count configurations..."
            for ((i=0; i<count; i++)); do
                tmp_cfg=$(mktemp)
                jq ".[$i]" "$CONFIG_FILE" > "$tmp_cfg"
                id=$(jq -r --argjson idx "$i" '.id // (.target_dir | sub("/$"; "") | split("/")[-1] // ("config_" + ($idx | tostring)))' "$tmp_cfg")
                ver_file="$SCRIPT_DIR/version-$id.json"
                log "────────────────────────────────────"
                log "🔄 Updating config: $id"
                perform_update_for_config "$tmp_cfg" "$ver_file"
                rm -f "$tmp_cfg"
            done
        elif jq -e 'type == "object"' "$CONFIG_FILE" >/dev/null; then
            log "🔄 Running in single-config mode"
            perform_update_for_config "$CONFIG_FILE" "$SCRIPT_DIR/version.json"
        else
            error "❌ config.json must be a JSON object or array"
        fi
        ;;
    *)
        error "❌ Unknown argument: $1. Use --help for usage."
        ;;
esac