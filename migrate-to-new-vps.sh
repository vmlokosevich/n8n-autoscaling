#!/bin/bash
# migrate-to-new-vps.sh - Export / bootstrap / import the n8n-autoscaling stack
# between VPS hosts. Transfers the project directory (code + secrets) and all
# Docker named volumes as a single migration bundle.
#
# Usage:
#   On source VPS:  ./migrate-to-new-vps.sh export [--keep-down]
#                   TARGET_HOST=user@new-vps ./migrate-to-new-vps.sh export
#   On target VPS:  ./migrate-to-new-vps.sh bootstrap
#                   ./migrate-to-new-vps.sh import /path/to/n8n-migration-*.tar.gz [--force]
#
# Environment (optional for export):
#   TARGET_HOST   scp/rsync destination (user@host)
#   TARGET_DIR    remote directory (default: ~)
#   TARGET_USER   unused alias for clarity; prefer TARGET_HOST=user@host

set -euo pipefail

# Colors
if command -v tput >/dev/null 2>&1 && [ -t 1 ]; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    CYAN=$(tput setaf 6)
    NC=$(tput sgr0)
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC=''
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VOLUME_SUFFIXES=(postgres_data redis_data n8n_main n8n_webhook backup_data)
QUEUE_DRAIN_TIMEOUT=300
QUEUE_POLL_INTERVAL=5

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  export [--keep-down]              Drain queue, stop stack, archive project + volumes
  bootstrap                         apt update/upgrade, install Docker, create shark network
  import <bundle.tar.gz> [--force]  Restore project + volumes and start the stack

Environment for export:
  TARGET_HOST   user@host to scp/rsync the bundle to after export
  TARGET_DIR    remote destination directory (default: ~)
EOF
    exit 1
}

die() {
    echo "${RED}ERROR: $*${NC}" >&2
    exit 1
}

info()  { echo "${BLUE}$*${NC}"; }
ok()    { echo "${GREEN}$*${NC}"; }
warn()  { echo "${YELLOW}$*${NC}"; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

get_env_value() {
    local key="$1" default="${2:-}"
    if [ -f "$SCRIPT_DIR/.env" ]; then
        local value
        value=$(grep -E "^${key}=" "$SCRIPT_DIR/.env" 2>/dev/null | head -1 | cut -d'=' -f2- | sed 's/#.*//' | xargs) || true
        if [ -n "$value" ]; then
            echo "$value"
            return
        fi
    fi
    echo "$default"
}

compose_project_name() {
    get_env_value "COMPOSE_PROJECT_NAME" "n8n-autoscaling"
}

build_compose_args() {
    local args=(-f docker-compose.yml)
    if [ -f "$SCRIPT_DIR/.env" ] && grep -q "^ENABLE_CLOUDFLARE_OVERRIDE=true" "$SCRIPT_DIR/.env" 2>/dev/null; then
        [ -f "$SCRIPT_DIR/docker-compose.cloudflare.yml" ] && args+=(-f docker-compose.cloudflare.yml)
    fi
    # Always include both profiles used in production so down/up covers all services
    args+=(--profile backup --profile cloudflare)
    printf '%s\n' "${args[@]}"
}

compose() {
    # shellcheck disable=SC2046
    docker compose $(build_compose_args | tr '\n' ' ') "$@"
}

volume_full_name() {
    local suffix="$1"
    echo "$(compose_project_name)_${suffix}"
}

volume_mountpoint() {
    docker volume inspect -f '{{ .Mountpoint }}' "$1" 2>/dev/null
}

# Prefer host-path tar for local volumes (no image pull / no network).
# Fall back to alpine container only if the mountpoint is not readable on the host
# (e.g. Docker Desktop VM paths, non-local volume drivers).
archive_volume() {
    local vol_name="$1" archive_path="$2"
    local mountpoint
    mountpoint=$(volume_mountpoint "$vol_name")

    if [ -n "$mountpoint" ] && [ -d "$mountpoint" ] && [ -r "$mountpoint" ]; then
        tar czf "$archive_path" -C "$mountpoint" .
        return 0
    fi

    warn "  Host mountpoint unavailable for $vol_name (got: ${mountpoint:-empty}) — falling back to alpine container"
    if ! docker run --rm \
        -v "${vol_name}:/volume:ro" \
        -v "$(dirname "$archive_path"):/backup" \
        alpine:3.21 \
        tar czf "/backup/$(basename "$archive_path")" -C /volume .
    then
        die "Failed to archive $vol_name. Host path not readable and alpine:3.21 pull/run failed (check Docker Hub / DNS). As root on Linux, ensure volume mountpoint is accessible."
    fi
}

restore_volume() {
    local vol_name="$1" archive_path="$2"
    local mountpoint
    mountpoint=$(volume_mountpoint "$vol_name")

    if [ -n "$mountpoint" ] && [ -d "$mountpoint" ] && [ -w "$mountpoint" ]; then
        tar xzf "$archive_path" -C "$mountpoint"
        return 0
    fi

    warn "  Host mountpoint unavailable for $vol_name (got: ${mountpoint:-empty}) — falling back to alpine container"
    if ! docker run --rm \
        -v "${vol_name}:/volume" \
        -v "$(dirname "$archive_path"):/backup:ro" \
        alpine:3.21 \
        sh -c "cd /volume && tar xzf /backup/$(basename "$archive_path")"
    then
        die "Failed to restore $vol_name. Host path not writable and alpine:3.21 pull/run failed (check Docker Hub / DNS). As root on Linux, ensure volume mountpoint is accessible."
    fi
}

ensure_in_project_dir() {
    cd "$SCRIPT_DIR"
    [ -f docker-compose.yml ] || die "docker-compose.yml not found in $SCRIPT_DIR"
    [ -f .env ] || die ".env not found in $SCRIPT_DIR — run from the project directory on the source VPS"
}

# ------------------------------------------------------------
# export
# ------------------------------------------------------------

cmd_export() {
    local keep_down=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --keep-down) keep_down=true; shift ;;
            -h|--help) usage ;;
            *) die "Unknown export option: $1" ;;
        esac
    done

    require_cmd docker
    require_cmd tar
    require_cmd sha256sum
    ensure_in_project_dir

    local project
    project=$(compose_project_name)
    local timestamp
    timestamp=$(date -u +%Y%m%d-%H%M%S)
    local export_dir="$SCRIPT_DIR/migration-export"
    local work_dir="$export_dir/work-$timestamp"
    local bundle_name="n8n-migration-${timestamp}.tar.gz"
    local bundle_path="$export_dir/$bundle_name"

    info "=== n8n-autoscaling migration export ==="
    info "Project: $project"
    info "Directory: $SCRIPT_DIR"
    echo ""

    # --- Drain queue ---
    info "Step 1/8: Draining Redis job queue..."
    if compose ps --status running --services 2>/dev/null | grep -q '^redis$'; then
        local redis_pw
        redis_pw=$(get_env_value "REDIS_PASSWORD" "")
        local queue_prefix
        queue_prefix=$(get_env_value "QUEUE_NAME_PREFIX" "bull")
        local queue_name
        queue_name=$(get_env_value "QUEUE_NAME" "jobs")
        local wait_key="${queue_prefix}:${queue_name}:wait"

        compose up -d --scale n8n-worker=0 --scale n8n-worker-runner=0 >/dev/null 2>&1 || true

        local waited=0
        local qlen=0
        while [ "$waited" -lt "$QUEUE_DRAIN_TIMEOUT" ]; do
            qlen=$(compose exec -T redis redis-cli --no-auth-warning -a "$redis_pw" LLEN "$wait_key" 2>/dev/null | tr -d '\r' || echo "?")
            if [ "$qlen" = "0" ]; then
                ok "Queue drained ($wait_key = 0)"
                break
            fi
            info "  Waiting for queue to drain... ($wait_key = $qlen, ${waited}s/${QUEUE_DRAIN_TIMEOUT}s)"
            sleep "$QUEUE_POLL_INTERVAL"
            waited=$((waited + QUEUE_POLL_INTERVAL))
        done
        if [ "$qlen" != "0" ]; then
            warn "Queue did not fully drain (last LLEN=$qlen). Continuing with export anyway."
        fi
    else
        warn "Redis is not running — skipping queue drain."
    fi

    # --- Stop stack (keep volumes) ---
    info "Step 2/8: Stopping all services (volumes preserved)..."
    compose down
    ok "Stack stopped."

    mkdir -p "$work_dir/volumes"
    # Ensure we can write even if previous run left root-owned files
    chmod -R u+w "$export_dir" 2>/dev/null || true

    # --- Archive project directory ---
    info "Step 3/8: Archiving project directory (code + secrets)..."
    # Exclude .git, migration working dirs, and this export tree to avoid recursion
    tar czf "$work_dir/project.tar.gz" \
        --exclude='.git' \
        --exclude='migration-export' \
        --exclude='migration-import' \
        --exclude='*.pyc' \
        --exclude='__pycache__' \
        --exclude='.venv' \
        --exclude='node_modules' \
        -C "$(dirname "$SCRIPT_DIR")" \
        "$(basename "$SCRIPT_DIR")"
    ok "Project archive: $(du -h "$work_dir/project.tar.gz" | awk '{print $1}')"

    # --- Archive volumes ---
    info "Step 4/8: Archiving Docker volumes..."
    local suffix vol_name archive_path
    for suffix in "${VOLUME_SUFFIXES[@]}"; do
        vol_name=$(volume_full_name "$suffix")
        archive_path="$work_dir/volumes/${suffix}.tar.gz"
        if ! docker volume inspect "$vol_name" >/dev/null 2>&1; then
            warn "  Volume $vol_name not found — skipping."
            continue
        fi
        info "  Archiving $vol_name..."
        archive_volume "$vol_name" "$archive_path"
        ok "  $suffix: $(du -h "$archive_path" | awk '{print $1}')"
    done

    # --- Manifest ---
    info "Step 5/8: Writing manifest..."
    {
        echo "timestamp=$timestamp"
        echo "source_host=$(hostname -f 2>/dev/null || hostname)"
        echo "source_arch=$(uname -m)"
        echo "project_name=$project"
        echo "project_dir=$SCRIPT_DIR"
        echo "docker_version=$(docker --version 2>/dev/null || echo unknown)"
        echo "compose_version=$(docker compose version 2>/dev/null || echo unknown)"
        if [ -d "$SCRIPT_DIR/.git" ]; then
            echo "git_commit=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
            echo "git_status=$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null | wc -l | tr -d ' ') dirty files"
        fi
        echo ""
        echo "# sha256 checksums"
        (cd "$work_dir" && find . -type f ! -name manifest.txt -print0 | sort -z | xargs -0 sha256sum)
    } > "$work_dir/manifest.txt"
    ok "Manifest written."

    # --- Bundle ---
    info "Step 6/8: Creating migration bundle..."
    tar czf "$bundle_path" -C "$work_dir" .
    # Clean work dir but keep the final bundle
    rm -rf "$work_dir"
    ok "Bundle: $bundle_path ($(du -h "$bundle_path" | awk '{print $1}'))"
    echo ""
    warn "This bundle contains secrets (.env, rclone.conf). Handle it securely."

    # --- Optional transfer ---
    info "Step 7/8: Transfer..."
    if [ -n "${TARGET_HOST:-}" ]; then
        local dest_dir="${TARGET_DIR:-~}"
        require_cmd scp
        info "Copying to ${TARGET_HOST}:${dest_dir}/ ..."
        scp "$bundle_path" "${TARGET_HOST}:${dest_dir}/"
        ok "Transferred to ${TARGET_HOST}:${dest_dir}/$bundle_name"
    else
        warn "TARGET_HOST not set. Copy the bundle manually, e.g.:"
        echo "  scp $bundle_path user@NEW_VPS:~/"
        echo "  # or"
        echo "  rsync -avP $bundle_path user@NEW_VPS:~/"
    fi

    # --- Restart source stack ---
    info "Step 8/8: Source stack..."
    if [ "$keep_down" = true ]; then
        warn "Left stopped (--keep-down). Restart with:"
        echo "  cd $SCRIPT_DIR && docker compose -f docker-compose.yml -f docker-compose.cloudflare.yml --profile backup --profile cloudflare up -d"
    else
        info "Restarting services on source VPS..."
        compose up -d
        ok "Source stack is back up."
    fi

    echo ""
    ok "Export complete."
    echo "Next on the new VPS:"
    echo "  1. Copy migrate-to-new-vps.sh (or the whole repo) to the new host"
    echo "  2. ./migrate-to-new-vps.sh bootstrap"
    echo "  3. ./migrate-to-new-vps.sh import ~/$bundle_name"
}

# ------------------------------------------------------------
# bootstrap (new VPS)
# ------------------------------------------------------------

cmd_bootstrap() {
    if [ "$(id -u)" -ne 0 ]; then
        die "bootstrap must be run as root (or via sudo)"
    fi

    info "=== n8n-autoscaling migration bootstrap (new VPS) ==="
    echo ""

    info "Step 1/4: Updating system packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get upgrade -y
    ok "System updated."

    info "Step 2/4: Installing prerequisites..."
    apt-get install -y ca-certificates curl gnupg lsb-release

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        ok "Docker already installed: $(docker --version)"
        ok "Compose: $(docker compose version)"
    else
        info "Step 3/4: Installing Docker Engine + Compose plugin..."
        install -m 0755 -d /etc/apt/keyrings
        if [ ! -f /etc/apt/keyrings/docker.asc ]; then
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
            chmod a+r /etc/apt/keyrings/docker.asc
        fi
        local codename
        codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-noble}")
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" \
            > /etc/apt/sources.list.d/docker.list
        apt-get update -y
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        systemctl enable --now docker
        ok "Docker installed: $(docker --version)"
        ok "Compose: $(docker compose version)"
    fi

    info "Step 4/4: Creating external network 'shark'..."
    if docker network inspect shark >/dev/null 2>&1; then
        ok "Network 'shark' already exists."
    else
        docker network create shark
        ok "Network 'shark' created."
    fi

    echo ""
    ok "Bootstrap complete."
    echo "Architecture: $(uname -m) (must match source VPS for raw postgres volume restore)"
    echo "Next:"
    echo "  ./migrate-to-new-vps.sh import /path/to/n8n-migration-TIMESTAMP.tar.gz"
}

# ------------------------------------------------------------
# import (new VPS)
# ------------------------------------------------------------

set_env_key() {
    local key="$1" value="$2" file="$3"
    if grep -qE "^#?${key}=" "$file" 2>/dev/null; then
        # Replace existing (commented or not)
        sed -i.bak -E "s|^#?${key}=.*|${key}=${value}|" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
    rm -f "${file}.bak"
}

cmd_import() {
    local bundle=""
    local force=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) force=true; shift ;;
            -h|--help) usage ;;
            *)
                if [ -z "$bundle" ]; then
                    bundle="$1"
                    shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    [ -n "$bundle" ] || die "Usage: $0 import <bundle.tar.gz> [--force]"
    [ -f "$bundle" ] || die "Bundle not found: $bundle"

    require_cmd docker
    require_cmd tar
    require_cmd sha256sum

    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        die "Docker is not available. Run: $0 bootstrap"
    fi

    local abs_bundle
    abs_bundle=$(cd "$(dirname "$bundle")" && pwd)/$(basename "$bundle")
    local import_root="${IMPORT_ROOT:-/root}"
    local project_name="n8n-autoscaling"
    local target_dir="${import_root}/${project_name}"
    local staging="$import_root/migration-import-$$"

    info "=== n8n-autoscaling migration import ==="
    info "Bundle: $abs_bundle"
    info "Target: $target_dir"
    echo ""

    # --- Unpack + verify ---
    info "Step 1/7: Unpacking and verifying checksums..."
    mkdir -p "$staging"
    tar xzf "$abs_bundle" -C "$staging"
    [ -f "$staging/manifest.txt" ] || die "manifest.txt missing from bundle"
    [ -f "$staging/project.tar.gz" ] || die "project.tar.gz missing from bundle"

    # Verify checksums (exclude manifest itself)
    (
        cd "$staging"
        # Rebuild expected list from files present (manifest may list relative paths)
        awk '/^[0-9a-f]{64}  /{print}' manifest.txt > /tmp/migrate-expected-$$.sha || true
        if [ -s /tmp/migrate-expected-$$.sha ]; then
            sha256sum -c /tmp/migrate-expected-$$.sha
        else
            warn "No checksums found in manifest — skipping verification."
        fi
        rm -f /tmp/migrate-expected-$$.sha
    )
    ok "Checksums OK."

    # Warn on arch mismatch
    local source_arch
    source_arch=$(grep '^source_arch=' "$staging/manifest.txt" | cut -d= -f2 || true)
    local local_arch
    local_arch=$(uname -m)
    if [ -n "$source_arch" ] && [ "$source_arch" != "$local_arch" ]; then
        die "Architecture mismatch: source=$source_arch target=$local_arch. Raw postgres volume restore is unsafe. Use pg_dump/pg_restore instead (see README Backup section)."
    fi

    # --- Restore project directory ---
    info "Step 2/7: Restoring project directory..."
    if [ -d "$target_dir" ] && [ "$force" != true ]; then
        die "Directory $target_dir already exists. Re-run with --force to overwrite, or remove it first."
    fi
    if [ -d "$target_dir" ] && [ "$force" = true ]; then
        warn "Removing existing $target_dir (--force)..."
        # Stop any running stack first if compose file exists
        if [ -f "$target_dir/docker-compose.yml" ]; then
            (cd "$target_dir" && docker compose --profile backup --profile cloudflare down 2>/dev/null) || true
        fi
        rm -rf "$target_dir"
    fi
    tar xzf "$staging/project.tar.gz" -C "$import_root"
    [ -d "$target_dir" ] || die "Expected $target_dir after extracting project.tar.gz"
    [ -f "$target_dir/.env" ] || die ".env missing after project restore"
    ok "Project restored to $target_dir"

    # --- Fix COMPOSE_PROFILES ---
    info "Step 3/7: Ensuring COMPOSE_PROFILES=backup,cloudflare..."
    set_env_key "COMPOSE_PROFILES" "backup,cloudflare" "$target_dir/.env"
    # Also ensure cloudflare override flag is set (matches production inventory)
    if ! grep -q "^ENABLE_CLOUDFLARE_OVERRIDE=true" "$target_dir/.env" 2>/dev/null; then
        set_env_key "ENABLE_CLOUDFLARE_OVERRIDE" "true" "$target_dir/.env"
    fi
    ok "Profiles fixed in .env"

    # --- Network ---
    info "Step 4/7: Ensuring network 'shark' exists..."
    if docker network inspect shark >/dev/null 2>&1; then
        ok "Network 'shark' exists."
    else
        docker network create shark
        ok "Network 'shark' created."
    fi

    # --- Restore volumes ---
    info "Step 5/7: Restoring Docker volumes..."
    # Prefer project name from restored .env
    SCRIPT_DIR="$target_dir"
    project_name=$(compose_project_name)
    local suffix vol_name archive_path
    for suffix in "${VOLUME_SUFFIXES[@]}"; do
        archive_path="$staging/volumes/${suffix}.tar.gz"
        vol_name="${project_name}_${suffix}"
        if [ ! -f "$archive_path" ]; then
            warn "  Missing archive for $suffix — skipping."
            continue
        fi
        if docker volume inspect "$vol_name" >/dev/null 2>&1; then
            if [ "$force" = true ]; then
                warn "  Removing existing volume $vol_name (--force)..."
                docker volume rm "$vol_name" >/dev/null
            else
                die "Volume $vol_name already exists. Re-run with --force to overwrite."
            fi
        fi
        docker volume create "$vol_name" >/dev/null
        info "  Restoring $vol_name..."
        restore_volume "$vol_name" "$archive_path"
        ok "  Restored $vol_name"
    done

    # --- Start stack ---
    info "Step 6/7: Building and starting stack..."
    cd "$target_dir"
    # shellcheck disable=SC2046
    docker compose $(build_compose_args | tr '\n' ' ') up -d --build

    info "Waiting for services to become healthy (up to 120s)..."
    local i=0
    while [ "$i" -lt 24 ]; do
        if docker compose exec -T postgres pg_isready -U "$(get_env_value POSTGRES_ADMIN_USER postgres)" >/dev/null 2>&1 \
           && docker compose exec -T redis redis-cli --no-auth-warning -a "$(get_env_value REDIS_PASSWORD '')" ping 2>/dev/null | grep -q PONG; then
            break
        fi
        sleep 5
        i=$((i + 1))
    done

    # --- Health checks ---
    info "Step 7/7: Health checks..."
    local failed=0

    if docker compose exec -T postgres pg_isready -U "$(get_env_value POSTGRES_ADMIN_USER postgres)" >/dev/null 2>&1; then
        ok "  PostgreSQL: OK"
    else
        warn "  PostgreSQL: FAILED"; failed=1
    fi

    if docker compose exec -T redis redis-cli --no-auth-warning -a "$(get_env_value REDIS_PASSWORD '')" ping 2>/dev/null | grep -q PONG; then
        ok "  Redis: OK"
    else
        warn "  Redis: FAILED"; failed=1
    fi

    if curl -fsS "http://127.0.0.1:5678/healthz" >/dev/null 2>&1; then
        ok "  n8n /healthz: OK"
    else
        warn "  n8n /healthz: not ready yet (may still be starting)"
        failed=1
    fi

    echo ""
    docker compose ps
    echo ""

    # Cleanup staging
    rm -rf "$staging"

    if [ "$failed" -ne 0 ]; then
        warn "Some health checks did not pass yet. Check logs:"
        echo "  cd $target_dir && docker compose logs -f"
    else
        ok "Import complete — stack looks healthy."
    fi

    echo ""
    info "Post-import checklist:"
    echo "  1. Open https://$(get_env_value N8N_HOST n8n.domain.com) and verify workflows/credentials/executions"
    echo "  2. Test a webhook on https://$(get_env_value N8N_WEBHOOK webhook.domain.com)"
    echo "  3. Check Cloudflare tunnel: docker compose logs cloudflared (DNS change not needed)"
    echo "  4. Confirm backups still upload to $(get_env_value BACKUP_RCLONE_DESTINATIONS '(configured destination)')"
    echo "  5. Optional autostart: cd $target_dir && ./generate-systemd.sh"
    echo "  6. Securely delete the migration bundle (contains secrets)"
    echo "  7. After validation, stop the old VPS (or keep as fallback for a few days)"
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

[ $# -ge 1 ] || usage

cmd="$1"
shift

case "$cmd" in
    export)    cmd_export "$@" ;;
    bootstrap) cmd_bootstrap "$@" ;;
    import)    cmd_import "$@" ;;
    -h|--help|help) usage ;;
    *) die "Unknown command: $cmd (use export | bootstrap | import)" ;;
esac
