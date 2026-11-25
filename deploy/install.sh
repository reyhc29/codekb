#!/usr/bin/env bash
# =============================================================================
# CodeKB local installer / runner for our fork of awslabs/codekb.
# -----------------------------------------------------------------------------
# Lives in deploy/ so upstream merges never touch it. Builds the image from the
# repo root Dockerfile and runs it as one loopback-only container.
#
# Parameter precedence (low -> high):
#     built-in defaults  <  config file (deploy/codekb.conf)  <  CLI flags
#
# Usage:
#   deploy/install.sh [ACTION] [--config FILE] [--key value ...]
#
# ACTIONS:
#   all      render .env, create AWS resources, build image, run  (default)
#   env      only render deploy/.env from parameters
#   setup    only run infra/cli/setup_aws.sh (buckets, vector index, IAM policy,
#            log group, KMS key, guardrail)
#   build    only build the image from the repo
#   run      build if needed, then (re)create and start the container
#   mcp      print the MCP client config snippet for this instance
#   down     stop and remove the container
#   status   show container state + the URLs
#
# The image tag is codekb:fork-<git tree hash of the build inputs>, so a rebuild
# happens only when backend/, frontend/ or the Dockerfile change.
# =============================================================================
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"

# ---------- built-in defaults (overridden by config file, then flags) --------
CONFIG_FILE="${DEPLOY_DIR}/codekb.conf"
ACTION="all"

AWS_PROFILE=""
AWS_ACCOUNT_ID=""
AWS_REGION="us-east-1"
CODEKB_S3_REGION=""
CODEKB_S3_VECTORS_REGION=""
CODEKB_BEDROCK_REGION=""
CODEKB_S3_BUCKET=""
CODEKB_S3_VECTORS_BUCKET=""
CODEKB_S3_VECTORS_INDEX="codekb-index"
CODEKB_BEDROCK_MODEL_ID="us.anthropic.claude-opus-4-6-v1"
CODEKB_BEDROCK_MAX_TOKENS="65000"
CODEKB_SUMMARIZATION_CONCURRENCY="40"
CODEKB_BEDROCK_GUARDRAIL_ENABLED="false"
CODEKB_LOG_LEVEL="WARNING"
CODEKB_REQUIRE_AUTHENTICATION="false"
CODEKB_REQUIRE_AUTHORIZATION="false"
CODEKB_SECURITY_HEADERS_ENABLED="false"
CODEKB_ALLOWED_GIT_HOSTS=""
HOST_BIND="127.0.0.1"
HOST_PORT="8742"
CONTAINER_NAME="codekb"
CREDS_MODE="profile"                             # profile | env | role
CONTAINER_ENGINE="docker"
RESTART_POLICY="unless-stopped"
ALLOW_PUBLIC_BIND="false"
IMAGE_NAME="codekb"
GIT_SSH_DIR="$HOME/.ssh"
GIT_SSH_KEY="id_ecdsa"
ENV_FILE="${DEPLOY_DIR}/.env"

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"
}
log()  { printf '\033[1;36m[codekb]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[codekb] WARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[codekb] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- pre-scan for --config so the file loads before flag overrides -----
_a=("$@")
for ((i=0; i<${#_a[@]}; i++)); do
  [[ "${_a[$i]:-}" == "--config" ]] && CONFIG_FILE="${_a[$((i+1))]:-$CONFIG_FILE}"
done
if [[ -f "$CONFIG_FILE" ]]; then
  log "loading config: $CONFIG_FILE"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

# ---------- CLI flag overrides -----------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    all|env|setup|build|run|mcp|down|status) ACTION="$1"; shift;;
    --config)            shift 2;;
    --profile)           AWS_PROFILE="$2"; shift 2;;
    --account)           AWS_ACCOUNT_ID="$2"; shift 2;;
    --region)            AWS_REGION="$2"; shift 2;;
    --bucket)            CODEKB_S3_BUCKET="$2"; shift 2;;
    --vectors-bucket)    CODEKB_S3_VECTORS_BUCKET="$2"; shift 2;;
    --vectors-index)     CODEKB_S3_VECTORS_INDEX="$2"; shift 2;;
    --model)             CODEKB_BEDROCK_MODEL_ID="$2"; shift 2;;
    --concurrency)       CODEKB_SUMMARIZATION_CONCURRENCY="$2"; shift 2;;
    --allowed-git-hosts) CODEKB_ALLOWED_GIT_HOSTS="$2"; shift 2;;
    --port)              HOST_PORT="$2"; shift 2;;
    --bind)              HOST_BIND="$2"; shift 2;;
    --name)              CONTAINER_NAME="$2"; shift 2;;
    --creds-mode)        CREDS_MODE="$2"; shift 2;;
    --engine)            CONTAINER_ENGINE="$2"; shift 2;;
    --restart)           RESTART_POLICY="$2"; shift 2;;
    --env-file)          ENV_FILE="$2"; shift 2;;
    --git-ssh-dir)       GIT_SSH_DIR="$2"; shift 2;;
    --git-ssh-key)       GIT_SSH_KEY="$2"; shift 2;;
    --allow-public-bind) ALLOW_PUBLIC_BIND="true"; shift;;
    -h|--help)           usage; exit 0;;
    *) die "unknown argument: $1  (try --help)";;
  esac
done

CODEKB_S3_REGION="${CODEKB_S3_REGION:-$AWS_REGION}"
CODEKB_S3_VECTORS_REGION="${CODEKB_S3_VECTORS_REGION:-$AWS_REGION}"
CODEKB_BEDROCK_REGION="${CODEKB_BEDROCK_REGION:-$AWS_REGION}"
aws_args=()
[[ -n "$AWS_PROFILE" ]] && aws_args+=(--profile "$AWS_PROFILE")

resolve_account() {
  if [[ -z "$AWS_ACCOUNT_ID" ]]; then
    log "resolving account via STS..."
    AWS_ACCOUNT_ID="$(aws "${aws_args[@]}" sts get-caller-identity --query Account --output text)" \
      || die "could not resolve AWS account — check credentials for profile '${AWS_PROFILE:-<default>}'"
  fi
  CODEKB_S3_BUCKET="${CODEKB_S3_BUCKET:-codekb-knowledgebase-${AWS_ACCOUNT_ID}}"
  CODEKB_S3_VECTORS_BUCKET="${CODEKB_S3_VECTORS_BUCKET:-codekb-vectors-${AWS_ACCOUNT_ID}}"
}

image_ref() {
  # Tree hash of exactly what the Dockerfile copies; "-dirty" if any is uncommitted.
  local rev
  rev="$(git -C "$REPO_ROOT" rev-parse --short "HEAD:backend")$(git -C "$REPO_ROOT" rev-parse --short "HEAD:frontend" | cut -c1-4)" \
    || die "not a git checkout: $REPO_ROOT"
  if [[ -n "$(git -C "$REPO_ROOT" status --porcelain -- backend frontend Dockerfile)" ]]; then
    rev="${rev}-dirty"
  fi
  IMAGE="${IMAGE_NAME}:fork-${rev}"
}

check_bind() {
  case "$HOST_BIND" in
    127.0.0.1|localhost|::1) ;;
    *) [[ "$ALLOW_PUBLIC_BIND" == "true" ]] || die "HOST_BIND='$HOST_BIND' is not loopback. This deploy runs with
      CODEKB_REQUIRE_AUTHENTICATION=false; exposing it needs auth/TLS in front.
      Re-run with --allow-public-bind to override."
       warn "binding to non-loopback '$HOST_BIND' — you asserted auth/TLS is handled upstream.";;
  esac
}

render_env() {
  log "rendering $ENV_FILE"
  ( umask 077
  cat > "$ENV_FILE" <<EOF
# Generated by deploy/install.sh — do not edit by hand; change deploy/codekb.conf instead.
CODEKB_AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID}
CODEKB_STORAGE_BACKEND=s3_vectors
CODEKB_S3_BUCKET=${CODEKB_S3_BUCKET}
CODEKB_S3_REGION=${CODEKB_S3_REGION}
CODEKB_S3_VECTORS_BUCKET=${CODEKB_S3_VECTORS_BUCKET}
CODEKB_S3_VECTORS_INDEX=${CODEKB_S3_VECTORS_INDEX}
CODEKB_S3_VECTORS_REGION=${CODEKB_S3_VECTORS_REGION}
CODEKB_LOG_LEVEL=${CODEKB_LOG_LEVEL}
OTEL_LOGS_EXPORTER=none
OTEL_SERVICE_NAME=codekb
CODEKB_REQUIRE_AUTHENTICATION=${CODEKB_REQUIRE_AUTHENTICATION}
CODEKB_REQUIRE_AUTHORIZATION=${CODEKB_REQUIRE_AUTHORIZATION}
CODEKB_SECURITY_HEADERS_ENABLED=${CODEKB_SECURITY_HEADERS_ENABLED}
CODEKB_BEDROCK_MODEL_ID=${CODEKB_BEDROCK_MODEL_ID}
CODEKB_BEDROCK_REGION=${CODEKB_BEDROCK_REGION}
CODEKB_BEDROCK_MAX_TOKENS=${CODEKB_BEDROCK_MAX_TOKENS}
CODEKB_BEDROCK_READ_TIMEOUT=3600
CODEKB_BEDROCK_GUARDRAIL_ENABLED=${CODEKB_BEDROCK_GUARDRAIL_ENABLED}
CODEKB_SUMMARIZATION_CONCURRENCY=${CODEKB_SUMMARIZATION_CONCURRENCY}
CODEKB_ALLOWED_GIT_HOSTS=${CODEKB_ALLOWED_GIT_HOSTS}
EOF
  )
}

do_setup() {
  [[ -n "$CODEKB_ALLOWED_GIT_HOSTS" ]] || warn "CODEKB_ALLOWED_GIT_HOSTS is empty — git-by-URL is disabled."
  log "running infra/cli/setup_aws.sh with $ENV_FILE"
  # setup_aws.sh reads .env from the repo root; point it at ours for this run.
  local root_env="$REPO_ROOT/.env"
  [[ -e "$root_env" && ! "$root_env" -ef "$ENV_FILE" ]] && die "$root_env exists; move it so setup uses $ENV_FILE"
  ln -sf "$ENV_FILE" "$root_env"
  trap 'rm -f "$root_env"' RETURN
  AWS_PROFILE="${AWS_PROFILE}" AWS_REGION="${AWS_REGION}" bash "$REPO_ROOT/infra/cli/setup_aws.sh"
}

do_build() {
  image_ref
  log "building $IMAGE from $REPO_ROOT"
  "$CONTAINER_ENGINE" build -t "$IMAGE" "$REPO_ROOT"
}

do_run() {
  check_bind
  image_ref
  "$CONTAINER_ENGINE" image inspect "$IMAGE" >/dev/null 2>&1 || do_build
  log "removing any existing container '$CONTAINER_NAME'"
  "$CONTAINER_ENGINE" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

  # The image runs as uid 10001 with HOME=/home/codekb (mode 700). Run as the host user
  # so it can read the host ~/.aws and ssh key (mode 600), and use a neutral
  # HOME, because the host uid cannot enter /home/codekb.
  # ssh refuses to run for a uid with no passwd entry ("No user exists for
  # uid"), so give the container the image's passwd plus one line for us.
  local passwd_file="${ENV_FILE%/*}/.passwd-${CONTAINER_NAME}"
  { "$CONTAINER_ENGINE" run --rm --entrypoint cat "$IMAGE" /etc/passwd
    echo "codekb-host:x:$(id -u):$(id -g):codekb host user:/codekb-home:/sbin/nologin"
  } > "$passwd_file" || die "could not write $passwd_file"
  local args=(-d --name "$CONTAINER_NAME" --restart "$RESTART_POLICY"
    -p "${HOST_BIND}:${HOST_PORT}:8000" --env-file "$ENV_FILE"
    --user "$(id -u):$(id -g)" -v "$passwd_file:/etc/passwd:ro"
    -e HOME=/codekb-home -e AWS_REGION="$AWS_REGION")
  if [[ -n "$GIT_SSH_DIR" ]]; then
    [[ -f "$GIT_SSH_DIR/$GIT_SSH_KEY" ]] || die "git ssh key '$GIT_SSH_DIR/$GIT_SSH_KEY' not found (set GIT_SSH_DIR=\"\" to disable)"
    args+=(-v "$GIT_SSH_DIR:/codekb-home/.ssh-host:ro"
      -e "GIT_SSH_COMMAND=ssh -F /dev/null -i /codekb-home/.ssh-host/$GIT_SSH_KEY -o UserKnownHostsFile=/codekb-home/.ssh-host/known_hosts -o StrictHostKeyChecking=accept-new -o User=git")
  fi
  case "$CREDS_MODE" in
    profile) args+=(-v "$HOME/.aws:/codekb-home/.aws:ro" -e AWS_PROFILE="${AWS_PROFILE:-default}");;
    env)     eval "$(aws "${aws_args[@]}" configure export-credentials --format env)"
             args+=(-e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN);;
    role)    ;;
    *) die "unknown CREDS_MODE '$CREDS_MODE' (profile|env|role)";;
  esac
  log "starting '$CONTAINER_NAME' ($IMAGE) on ${HOST_BIND}:${HOST_PORT} (creds-mode=$CREDS_MODE)"
  "$CONTAINER_ENGINE" run "${args[@]}" "$IMAGE"
  sleep 2
  "$CONTAINER_ENGINE" logs "$CONTAINER_NAME" 2>&1 | head -20 || true
}

do_mcp() {
  cat <<EOF
Add this to your MCP client config (Kiro: ~/.kiro/settings/mcp.json):

{
  "mcpServers": {
    "codekb": {
      "url": "http://localhost:${HOST_PORT}/mcp/mcp",
      "transport": "streamable-http",
      "disabled": false,
      "autoApprove": []
    }
  }
}
EOF
}

do_status() {
  "$CONTAINER_ENGINE" ps -a --filter "name=^/${CONTAINER_NAME}$" \
    --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' || true
  echo
  log "Web UI : http://localhost:${HOST_PORT}"
  log "MCP    : http://localhost:${HOST_PORT}/mcp/mcp"
}

do_down() {
  log "stopping and removing '$CONTAINER_NAME'"
  "$CONTAINER_ENGINE" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}

case "$ACTION" in
  env)    resolve_account; render_env ;;
  setup)  resolve_account; render_env; do_setup ;;
  build)  do_build ;;
  run)    resolve_account; render_env; do_run; echo; do_status ;;
  mcp)    do_mcp ;;
  down)   do_down ;;
  status) do_status ;;
  all)    resolve_account; render_env; do_setup; do_build; do_run; echo; do_status; echo; do_mcp ;;
  *) die "unknown action '$ACTION' (try --help)";;
esac

log "done: action '$ACTION'"
