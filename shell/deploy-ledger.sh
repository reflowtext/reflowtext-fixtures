#!/usr/bin/env bash
#
# deploy-ledger.sh: roll a new release of the Meridian ledger service onto a
# set of hosts, one at a time, with a health check and automatic rollback.
#
#   ./deploy-ledger.sh --release 2026.11.3 --hosts hosts/staging.txt
#   ./deploy-ledger.sh --release 2026.11.3 --hosts hosts/prod.txt --batch 2 --yes
#   ./deploy-ledger.sh --rollback --hosts hosts/prod.txt
#
# Each host keeps its last three releases under /srv/ledger/releases and a
# `current` symlink. Switching a release is an atomic symlink swap followed by
# a service restart, so a failed health check can always go back.

set -Eeuo pipefail
shopt -s inherit_errexit nullglob

readonly SCRIPT_NAME="${0##*/}"
readonly APP_ROOT="/srv/ledger"
readonly ARTIFACT_URL_BASE="https://artifacts.meridian.example/ledger"
readonly HEALTH_PATH="/healthz"
readonly HEALTH_PORT=8443
readonly KEEP_RELEASES=3

release=""
hosts_file=""
batch_size=1
assume_yes=false
dry_run=false
mode="deploy"
log_dir="$(mktemp -d "${TMPDIR:-/tmp}/ledger-deploy.XXXXXX")"
declare -a deployed_hosts=()

# ---------------------------------------------------------------- output ---

if [[ -t 2 ]]; then
  c_dim=$'\e[2m' c_red=$'\e[31m' c_grn=$'\e[32m' c_ylw=$'\e[33m' c_off=$'\e[0m'
else
  c_dim="" c_red="" c_grn="" c_ylw="" c_off=""
fi

log()  { printf '%s%s%s %s\n' "$c_dim" "$(date -u +%H:%M:%S)" "$c_off" "$*" >&2; }
ok()   { log "${c_grn}✓${c_off} $*"; }
warn() { log "${c_ylw}!${c_off} $*"; }
die()  { log "${c_red}✗${c_off} $*"; exit 1; }

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME --release VERSION --hosts FILE [options]
       $SCRIPT_NAME --rollback --hosts FILE [options]

Options:
  -r, --release VERSION   release to deploy, e.g. 2026.11.3
  -H, --hosts FILE        one host per line; '#' starts a comment
  -b, --batch N           hosts updated in parallel (default 1)
      --rollback          point every host back at its previous release
  -n, --dry-run           print what would happen, change nothing
  -y, --yes               do not ask for confirmation
  -h, --help              show this help
EOF
}

# --------------------------------------------------------------- cleanup ---

on_exit() {
  local status=$?
  if (( status != 0 )) && [[ $mode == deploy ]] && (( ${#deployed_hosts[@]} > 0 )); then
    warn "deploy failed after ${#deployed_hosts[@]} host(s); rolling those back"
    local host
    for host in "${deployed_hosts[@]}"; do
      rollback_host "$host" || warn "rollback on $host also failed: inspect by hand"
    done
  fi
  if (( status == 0 )); then
    rm -rf -- "$log_dir"
  else
    warn "logs kept in $log_dir"
  fi
}

on_error() {
  local line=$1 cmd=$2
  log "${c_red}error${c_off} at line $line: $cmd"
}

trap on_exit EXIT
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
trap 'die "interrupted"' INT TERM

# --------------------------------------------------------------- helpers ---

run() {
  if $dry_run; then
    log "${c_dim}dry-run:${c_off} $*"
  else
    "$@"
  fi
}

remote() {
  local host=$1; shift
  run ssh -o BatchMode=yes -o ConnectTimeout=10 "deploy@$host" "$@"
}

read_hosts() {
  local file=$1 line
  [[ -r $file ]] || die "cannot read hosts file: $file"
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -n $line ]] && printf '%s\n' "$line"
  done <"$file"
}

confirm() {
  $assume_yes && return 0
  [[ -t 0 ]] || die "not a terminal and --yes not given; refusing to guess"
  local answer
  read -r -p "$1 [y/N] " answer
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]]
}

wait_healthy() {
  local host=$1 attempt
  $dry_run && return 0
  for attempt in {1..20}; do
    if curl --silent --fail --max-time 3 \
         "https://$host:$HEALTH_PORT$HEALTH_PATH" | grep -q '"status":"ok"'; then
      return 0
    fi
    sleep $(( attempt < 5 ? 1 : 3 ))
  done
  return 1
}

# ------------------------------------------------------------ operations ---

deploy_host() {
  local host=$1
  local target="$APP_ROOT/releases/$release"
  local tarball="ledger-$release-linux-amd64.tar.gz"

  log "$host: fetching $release"
  remote "$host" "set -e
    mkdir -p '$target'
    cd '$target'
    if [ ! -f .complete ]; then
      curl --fail --silent --show-error -o '$tarball' '$ARTIFACT_URL_BASE/$release/$tarball'
      curl --fail --silent --show-error -o '$tarball.sha256' '$ARTIFACT_URL_BASE/$release/$tarball.sha256'
      sha256sum --check --status '$tarball.sha256'
      tar -xzf '$tarball' && rm -f '$tarball' '$tarball.sha256'
      touch .complete
    fi"

  log "$host: switching to $release"
  remote "$host" "set -e
    ln -sfn '$target' '$APP_ROOT/current.next'
    mv -T '$APP_ROOT/current.next' '$APP_ROOT/current'
    sudo systemctl restart ledger.service"
  # This runs in a subshell, so tell the parent through a marker file that
  # the host has switched and would need rolling back.
  $dry_run || touch "$log_dir/$host.switched"

  if ! wait_healthy "$host"; then
    die "$host: health check failed after switching to $release"
  fi

  remote "$host" "cd '$APP_ROOT/releases' && ls -1t | tail -n +$((KEEP_RELEASES + 1)) | xargs -r rm -rf --"
  ok "$host: running $release"
}

rollback_host() {
  local host=$1
  log "$host: rolling back"
  remote "$host" "set -e
    cd '$APP_ROOT/releases'
    current=\$(basename \"\$(readlink -f '$APP_ROOT/current')\")
    previous=\$(ls -1t | grep -vx \"\$current\" | head -n 1)
    [ -n \"\$previous\" ] || { echo 'no previous release to return to' >&2; exit 1; }
    ln -sfn \"$APP_ROOT/releases/\$previous\" '$APP_ROOT/current.next'
    mv -T '$APP_ROOT/current.next' '$APP_ROOT/current'
    sudo systemctl restart ledger.service
    echo \"now on \$previous\""
  wait_healthy "$host" && ok "$host: rolled back"
}

deploy_all() {
  local -a hosts=("$@") pids=() batch=()
  local i host pid failed=0

  for (( i = 0; i < ${#hosts[@]}; i += batch_size )); do
    batch=("${hosts[@]:i:batch_size}")
    pids=()
    for host in "${batch[@]}"; do
      ( deploy_host "$host" ) >"$log_dir/$host.log" 2>&1 &
      pids+=("$!")
    done
    for pid in "${pids[@]}"; do
      wait "$pid" || failed=1
    done
    for host in "${batch[@]}"; do
      cat "$log_dir/$host.log" >&2
      [[ -e $log_dir/$host.switched ]] && deployed_hosts+=("$host")
    done
    (( failed == 0 )) || die "batch ${batch[*]} failed; stopping before the next batch"
  done
}

# ------------------------------------------------------------------ main ---

parse_args() {
  while (( $# > 0 )); do
    case $1 in
      -r|--release)  release=${2:?--release needs a value}; shift ;;
      -H|--hosts)    hosts_file=${2:?--hosts needs a file}; shift ;;
      -b|--batch)    batch_size=${2:?--batch needs a number}; shift ;;
      --rollback)    mode="rollback" ;;
      -n|--dry-run)  dry_run=true ;;
      -y|--yes)      assume_yes=true ;;
      -h|--help)     usage; exit 0 ;;
      *)             usage >&2; die "unknown argument: $1" ;;
    esac
    shift
  done

  [[ -n $hosts_file ]] || { usage >&2; die "--hosts is required"; }
  [[ $batch_size =~ ^[1-9][0-9]*$ ]] || die "--batch must be a positive integer"
  if [[ $mode == deploy ]]; then
    [[ $release =~ ^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$ ]] || die "--release must look like 2026.11.3"
  fi
}

main() {
  parse_args "$@"
  local -a hosts
  mapfile -t hosts < <(read_hosts "$hosts_file")
  (( ${#hosts[@]} > 0 )) || die "no hosts in $hosts_file"

  for cmd in ssh curl; do
    command -v "$cmd" >/dev/null || die "missing required command: $cmd"
  done

  case $mode in
    deploy)
      log "release ${c_grn}$release${c_off} → ${#hosts[@]} host(s), $batch_size at a time"
      confirm "Proceed?" || die "aborted"
      deploy_all "${hosts[@]}"
      ok "all ${#hosts[@]} host(s) on $release"
      ;;
    rollback)
      confirm "Roll back ${#hosts[@]} host(s)?" || die "aborted"
      for host in "${hosts[@]}"; do rollback_host "$host"; done
      ;;
  esac
}

main "$@"
