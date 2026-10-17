#!/usr/bin/env bash
# Builds this repository and installs it on this Mac, for running your own
# CodeBurn rather than the published one: the CLI the menu bar app shells out
# to, and the menu bar app itself. Run it after merging a PR.
#
# Usage:
#   scripts/install-local.sh [options]
#
#   (no options)     switch to dev, pull it from origin, build and install
#   --branch <name>  the same for another branch
#   --current        build what is checked out now, uncommitted changes
#                    included, without switching or pulling
#   --cli-only       skip the app
#   --app-only       skip the CLI
#   --no-install     build only; install nothing and leave the app running
#   --dry-run        print what would happen and stop
#
# The CLI goes where the app looks for it: the path `codeburn menubar`
# records in ~/Library/Application Support/CodeBurn/codeburn-cli-path.v1,
# else the `codeburn` on PATH. It is packed with `npm pack` and installed
# with that Node's own npm, so it replaces the copy the app already runs.
#
# The app is built with mac/Scripts/package-app.sh for this Mac's
# architecture and replaces the installed CodeBurnMenubar.app (in
# /Applications unless it lives elsewhere). It is signed with the first
# "Apple Development" identity in the keychain, which keeps macOS from asking
# for its permissions again after every build; CODESIGN_IDENTITY overrides
# that, and CODESIGN_IDENTITY=- signs ad hoc.

set -euo pipefail

APP_NAME="CodeBurnMenubar.app"
APP_EXECUTABLE="CodeBurnMenubar"
APP_BUNDLE_ID="org.agentseal.codeburn-menubar"
CLI_RECORD="${HOME}/Library/Application Support/CodeBurn/codeburn-cli-path.v1"
WORK_DIR="${HOME}/Library/Caches/codeburn-install-local"
MARKER_FILE=".codeburn-local-build"

BRANCH="dev"
USE_CURRENT=0
DO_CLI=1
DO_APP=1
DO_INSTALL=1
DRY_RUN=0

step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,/^$/p' "$(readlink -f "$0")" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch) [[ $# -ge 2 ]] || die "--branch needs a name"; BRANCH="$2"; shift ;;
      --current) USE_CURRENT=1 ;;
      --cli-only) DO_APP=0 ;;
      --app-only) DO_CLI=0 ;;
      --no-install) DO_INSTALL=0 ;;
      --dry-run) DRY_RUN=1 ;;
      -h|--help) usage 0 ;;
      *) printf 'Unknown option: %s\n\n' "$1" >&2; usage 1 ;;
    esac
    shift
  done
  [[ ${DO_CLI} -eq 1 || ${DO_APP} -eq 1 ]] || die "--cli-only and --app-only together leave nothing to do"
}

# ---------------------------------------------------------------------------
# Where things go
# ---------------------------------------------------------------------------

# The Node install that holds the CLI the app runs, as "<prefix>": its npm is
# <prefix>/bin/npm. Empty when no CLI is installed yet.
cli_prefix() {
  local recorded=""
  [[ -f "${CLI_RECORD}" ]] && recorded=$(head -n 1 "${CLI_RECORD}")
  [[ -n "${recorded}" && -e "${recorded}" ]] || recorded=$(command -v codeburn || true)
  [[ -n "${recorded}" ]] || return 0
  local resolved
  resolved=$(readlink -f "${recorded}")
  case "${resolved}" in
    */lib/node_modules/codeburn/dist/cli.js) printf '%s\n' "${resolved%/lib/node_modules/codeburn/dist/cli.js}" ;;
    *) die "The app's CLI is ${resolved}, not an npm global install; install it by hand from this repo" ;;
  esac
}

# Where the installed app lives: the running copy, else an installed one,
# else /Applications.
app_destination() {
  local running
  running=$(ps -axo command= | awk -v exe="/Contents/MacOS/${APP_EXECUTABLE}" 'index($0, exe) { sub(exe ".*", ""); print; exit }')
  if [[ -n "${running}" && "${running}" == *".app" ]]; then printf '%s\n' "${running}"; return; fi
  for dir in /Applications "${HOME}/Applications"; do
    if [[ -d "${dir}/${APP_NAME}" ]]; then printf '%s\n' "${dir}/${APP_NAME}"; return; fi
  done
  printf '%s\n' "/Applications/${APP_NAME}"
}

signing_identity() {
  if [[ -n "${CODESIGN_IDENTITY+set}" ]]; then
    [[ "${CODESIGN_IDENTITY}" == "-" ]] && printf '\n' || printf '%s\n' "${CODESIGN_IDENTITY}"
    return
  fi
  security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }'
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

update_source() {
  if [[ ${USE_CURRENT} -eq 1 ]]; then
    step "Building the current checkout"
    local dirty=""
    [[ -n "$(git status --porcelain --untracked-files=no)" ]] && dirty=" (with uncommitted changes)"
    info "$(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)${dirty}"
    return
  fi
  step "Updating ${BRANCH} from origin"
  # Untracked files survive a checkout; changes to tracked ones would block it
  # or be built by mistake.
  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    die "You have uncommitted changes on $(git rev-parse --abbrev-ref HEAD). Commit or stash them, or pass --current to build them."
  fi
  git fetch --quiet origin
  if [[ "$(git rev-parse --abbrev-ref HEAD)" != "${BRANCH}" ]]; then
    info "switching from $(git rev-parse --abbrev-ref HEAD) to ${BRANCH}"
    git checkout --quiet "${BRANCH}"
  fi
  git pull --ff-only --quiet origin "${BRANCH}"
  info "${BRANCH} @ $(git log -1 --format='%h %s')"
}

check_node() {
  command -v node >/dev/null || die "node is not on PATH"
  node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>22||(a===22&&b>=13)?0:1)' \
    || die "Node $(node --version) is too old to build CodeBurn; it needs 22.13 or newer"
}

install_dependencies() {
  # npm ci only when the lockfile changed since the last install.
  local stamp="node_modules/${MARKER_FILE}-lock"
  local lock
  lock=$(shasum -a 256 package-lock.json | awk '{print $1}')
  if [[ -d node_modules && -f "${stamp}" && "$(cat "${stamp}")" == "${lock}" ]]; then
    info "dependencies unchanged"
    return
  fi
  info "installing dependencies (package-lock.json changed)"
  npm ci --no-audit --no-fund --loglevel=error
  printf '%s\n' "${lock}" > "${stamp}"
}

build_cli() {
  step "Building the CLI"
  check_node
  install_dependencies
  npm run --silent build >/dev/null
  info "built dist/ ($(node -p 'require("./package.json").version'))"
}

install_cli() {
  step "Installing the CLI"
  local prefix npm_bin
  prefix=$(cli_prefix)
  if [[ -n "${prefix}" ]]; then
    npm_bin="${prefix}/bin/npm"
    [[ -x "${npm_bin}" ]] || die "No npm next to the app's CLI at ${npm_bin}"
  else
    npm_bin=$(command -v npm)
    prefix=$("${npm_bin}" config get prefix)
    info "no CLI installed yet; installing into ${prefix}"
  fi

  mkdir -p "${WORK_DIR}"
  rm -f "${WORK_DIR}"/codeburn-*.tgz
  local tarball
  tarball="${WORK_DIR}/$(npm pack --silent --pack-destination "${WORK_DIR}" | tail -n 1)"
  # That prefix's own node runs its npm; --prefix keeps an .npmrc from sending
  # the install anywhere else.
  PATH="$(dirname "${npm_bin}"):${PATH}" "${npm_bin}" install -g --prefix "${prefix}" \
    --no-audit --no-fund --loglevel=error "${tarball}"
  rm -f "${tarball}"

  local root="${prefix}/lib/node_modules/codeburn"
  [[ -f "${root}/dist/cli.js" ]] || die "npm reported success but ${root} has no dist/cli.js"
  git log -1 --format='%H%n%h %s' > "${root}/${MARKER_FILE}"
  info "installed into ${root}"
}

build_app() {
  step "Building the menu bar app"
  local identity arch
  identity=$(signing_identity)
  arch=$(uname -m)
  info "architecture ${arch}; signing ${identity:-ad hoc}"
  ARCHS="${arch}" CODESIGN_IDENTITY="${identity}" mac/Scripts/package-app.sh dev > "${WORK_DIR}/package-app.log" 2>&1 \
    || { tail -n 30 "${WORK_DIR}/package-app.log" >&2; die "The app build failed; the full log is ${WORK_DIR}/package-app.log"; }
  [[ -d "mac/.build/dist/${APP_NAME}" ]] || die "package-app.sh produced no ${APP_NAME}"
  info "built mac/.build/dist/${APP_NAME}"
}

quit_app() {
  pgrep -x "${APP_EXECUTABLE}" >/dev/null || return 0
  info "quitting the running app"
  osascript -e "tell application id \"${APP_BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    pgrep -x "${APP_EXECUTABLE}" >/dev/null || return 0
    sleep 0.5
  done
  pkill -x "${APP_EXECUTABLE}" || true
  sleep 1
}

install_app() {
  step "Installing the menu bar app"
  local dest built backup
  dest=$(app_destination)
  built="mac/.build/dist/${APP_NAME}"
  backup="${WORK_DIR}/${APP_NAME}.previous"
  quit_app
  rm -rf "${backup}"
  if [[ -d "${dest}" ]]; then mv "${dest}" "${backup}"; fi
  if ! ditto "${built}" "${dest}"; then
    rm -rf "${dest}"
    [[ -d "${backup}" ]] && mv "${backup}" "${dest}"
    die "Could not copy the app to ${dest}; the previous one is back in place"
  fi
  info "installed ${dest} (the previous copy is in ${backup})"
  open "${dest}"
  for _ in $(seq 1 20); do
    pgrep -x "${APP_EXECUTABLE}" >/dev/null && { info "launched"; return; }
    sleep 0.5
  done
  printf '  \033[33m! the app did not start; open %s to see why\033[0m\n' "${dest}"
}

dry_run() {
  step "Dry run"
  if [[ ${USE_CURRENT} -eq 1 ]]; then
    info "source: the current checkout, $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)"
  else
    info "source: ${BRANCH} from origin (now on $(git rev-parse --abbrev-ref HEAD))"
    [[ -z "$(git status --porcelain --untracked-files=no)" ]] || info "  blocked: uncommitted changes (use --current to build them)"
  fi
  if [[ ${DO_CLI} -eq 1 ]]; then
    local prefix
    prefix=$(cli_prefix)
    info "CLI: npm pack, then ${prefix:-$(dirname "$(command -v npm)")}/bin/npm install -g"
  fi
  if [[ ${DO_APP} -eq 1 ]]; then
    local identity
    identity=$(signing_identity)
    info "app: package-app.sh for $(uname -m), signed ${identity:-ad hoc}, installed to $(app_destination)"
  fi
  [[ ${DO_INSTALL} -eq 1 ]] || info "--no-install: nothing would be installed"
}

main() {
  parse_args "$@"
  # Through a symlink too (a `codeburn-update` on PATH): find the real file.
  cd "$(git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)"
  mkdir -p "${WORK_DIR}"

  if [[ ${DRY_RUN} -eq 1 ]]; then dry_run; return; fi

  # One run at a time: two would fight over dist/ and the installed app.
  local lock="${WORK_DIR}/lock"
  mkdir "${lock}" 2>/dev/null || die "Another install is running (or one was killed: remove ${lock})"
  trap 'rmdir "'"${lock}"'" 2>/dev/null || true' EXIT

  update_source
  [[ ${DO_CLI} -eq 1 ]] && build_cli
  [[ ${DO_APP} -eq 1 ]] && build_app
  if [[ ${DO_INSTALL} -eq 1 ]]; then
    [[ ${DO_CLI} -eq 1 ]] && install_cli
    [[ ${DO_APP} -eq 1 ]] && install_app
    # A CLI-only install still needs the app's resident `codeburn serve` to
    # restart, or it keeps answering with the old code.
    if [[ ${DO_APP} -eq 0 ]] && pgrep -x "${APP_EXECUTABLE}" >/dev/null; then
      step "Restarting the menu bar app for the new CLI"
      local dest
      dest=$(app_destination)
      quit_app
      open "${dest}"
    fi
  fi

  step "Done"
  info "$(git log -1 --format='%h %s')"
}

# Everything runs from main, so a `git pull` that rewrites this file mid-run
# cannot change what bash executes next.
main "$@"
exit
