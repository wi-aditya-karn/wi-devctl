#!/usr/bin/env bash
# devctl-dev - Interactive dev install (isolated from production install.sh)
# Usage: bash install_dev.sh
#
# Uses a separate home (~/.devctl-dev by default) and installs devctl-dev binary.
# Production install.sh / devctl / ~/.devctl are never touched.
set -e

DEFAULT_DEVCTL_HOME="~/.devctl-dev"
INSTALL_DIR=""
STEP=0
TOTAL_STEPS=6

expand_home_path() {
  local path="$1"
  case "$path" in
    "~") echo "$HOME" ;;
    "~/"*) echo "${HOME}${path:1}" ;;
    *) echo "$path" ;;
  esac
}

devctl_home_prompt_default() {
  if [ -n "${DEVCTL_HOME:-}" ]; then
    case "$DEVCTL_HOME" in
      "$HOME/.devctl-dev") echo "$DEFAULT_DEVCTL_HOME" ;;
      *) echo "$DEVCTL_HOME" ;;
    esac
  else
    echo "$DEFAULT_DEVCTL_HOME"
  fi
}

log_step() {
  STEP=$((STEP + 1))
  echo "[devctl-dev] [$STEP/${TOTAL_STEPS}] $*" >&2
}

prompt_with_default() {
  local var_name="$1" prompt_text="$2" default_value="$3"
  local input
  if [ -n "$default_value" ]; then
    read -r -p "${prompt_text} [${default_value}]: " input
    input="${input:-$default_value}"
  else
    read -r -p "${prompt_text}: " input
  fi
  printf -v "$var_name" '%s' "$input"
}

prompt_yes_no() {
  local var_name="$1" prompt_text="$2" default_yes="${3:-n}"
  local input default_label="y/N"
  [ "$default_yes" = "y" ] && default_label="Y/n"
  read -r -p "${prompt_text} [${default_label}]: " input
  input="${input:-$default_yes}"
  case "$input" in
    y|Y|yes|Yes) printf -v "$var_name" '%s' "1" ;;
    *) printf -v "$var_name" '%s' "0" ;;
  esac
}

url_to_slug() {
  local url="$1" path
  url="${url%.git}"
  if [[ "$url" == git@*:* ]]; then
    path="${url#*:}"
  else
    path="${url#*github.com/}"
    path="${path#https://}"
    path="${path#http://}"
  fi
  path="${path#/}"
  echo "$path" | tr '/' '-'
}

# Parse owner/repo, full GitHub URLs, or git@github.com:owner/repo into owner + repo.
normalize_github_repo() {
  local spec="$1"
  python3 - "$spec" <<'PY'
import re
import sys

spec = (sys.argv[1] or "").strip()
if not spec:
    print("empty GitHub repo spec", file=sys.stderr)
    sys.exit(1)

owner: str | None = None
repo: str | None = None

value = spec.rstrip("/")
m = re.match(r"git@github\.com:([^/]+)/([^/]+?)(?:\.git)?$", value)
if m:
    owner, repo = m.group(1), m.group(2).removesuffix(".git")
else:
    m = re.match(r"(?:https?://)?(?:www\.)?github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$", value)
    if m:
        owner, repo = m.group(1), m.group(2).removesuffix(".git")
    elif "/" in value and "://" not in value and "@" not in value:
        owner, repo = value.split("/", 1)
        repo = repo.removesuffix(".git")
    else:
        print(f"invalid GitHub repo spec: {spec!r}", file=sys.stderr)
        print("Use owner/repo (e.g. WorkIndia-Private/wi-devctl) or a github.com URL.", file=sys.stderr)
        sys.exit(1)

for label, val in (("owner", owner), ("repo", repo)):
    if not val or "://" in val or "/" in val:
        print(f"invalid GitHub {label}: {val!r}", file=sys.stderr)
        sys.exit(1)

print(owner)
print(repo)
PY
}

prompt_github_token() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "  → Using GITHUB_TOKEN from environment (${#GITHUB_TOKEN} chars)" >&2
    export GITHUB_TOKEN
    return
  fi
  read -r -s -p "GITHUB_TOKEN for private clone (leave empty if public or using SSH): " GITHUB_TOKEN
  echo "" >&2
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    export GITHUB_TOKEN
  fi
}

run_devctl() {
  env DEVCTL_HOME="$DEVCTL_HOME" "$@"
}

_pyinstaller_build() {
  local src_dir="$1" output="$2"
  local built

  echo "  → Building devctl-dev binary (PyInstaller)..." >&2
  if ! (
    cd "$src_dir"
    python3 -m pip install -q setuptools wheel pyinstaller pyyaml click certifi
    python3 -m pip install -q -e . --no-build-isolation
    pyinstaller --onefile --name devctl-dev --paths src \
      --hidden-import certifi --collect-all certifi \
      src/devctl/cli/main.py
  ); then
    echo "❌ Build failed." >&2
    return 1
  fi

  built="$src_dir/dist/devctl-dev"
  [[ "$output" == *.exe ]] && built="${built}.exe"
  if [ ! -f "$built" ]; then
    echo "❌ Built binary not found at $built" >&2
    return 1
  fi

  chmod +x "$built"
  mv "$built" "$output"
  echo "✅ Built and installed to $output" >&2
}

verify_devctl_home_isolation() {
  local devctl_bin="$1" expected_home="$2"
  local actual expected_resolved actual_resolved

  if ! actual=$(run_devctl "$devctl_bin" print-devctl-home 2>/dev/null); then
    echo "❌ Binary missing DEVCTL_HOME support (print-devctl-home failed)." >&2
    echo "   Push DEVCTL_HOME changes to the branch you selected and re-run install_dev.sh." >&2
    exit 1
  fi

  expected_resolved="$(expand_home_path "$expected_home")"
  actual_resolved="$(expand_home_path "$actual")"
  if [ "$actual_resolved" != "$expected_resolved" ]; then
    echo "❌ DEVCTL_HOME isolation check failed." >&2
    echo "   expected: $expected_resolved" >&2
    echo "   got:      $actual_resolved" >&2
    exit 1
  fi
  echo "  → DEVCTL_HOME isolation verified ($actual_resolved)" >&2
}

verify_dev_setup_artifacts() {
  if [ -n "${DEVCTL_AI_KIT_REPO:-}" ] && [ ! -f "${DEVCTL_HOME}/state.json" ]; then
    echo "❌ ai-kit setup did not write ${DEVCTL_HOME}/state.json." >&2
    echo "   Dev install may have touched ~/.devctl instead — aborting." >&2
    exit 1
  fi
}

reset_ai_kit_clone() {
  local slug="$1"
  local repos_dir="${DEVCTL_HOME}/repos"
  local state_file="${DEVCTL_HOME}/state.json"

  if [ -d "${repos_dir}/${slug}" ]; then
    echo "  → Removing existing dev clone: ${repos_dir}/${slug}" >&2
    rm -rf "${repos_dir}/${slug}"
  fi

  if [ -f "$state_file" ]; then
    python3 - "$slug" "$state_file" <<'PY'
import json
import sys

slug, path = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    state = json.load(f)
repos = state.get("repos", {})
entry = repos.get(slug)
if not entry:
    sys.exit(0)
entry.pop("branch", None)
repos[slug] = entry
state["repos"] = repos
with open(path, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)
    f.write("\n")
PY
    echo "  → Cleared pinned branch in ${state_file} for ${slug}" >&2
  fi
}

detect_platform() {
  local os arch
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m | tr '[:upper:]' '[:lower:]')

  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
  esac

  case "$os" in
    darwin) os="darwin" ;;
    linux) os="linux" ;;
    mingw*|msys*|cygwin*) os="windows" ;;
    *) echo "Unsupported OS: $os" >&2; exit 1 ;;
  esac

  echo "${os}-${arch}"
}

choose_install_dir() {
  for dir in "/opt/homebrew/bin" "/usr/local/bin"; do
    if [ -d "$dir" ] && [ -w "$dir" ] && [[ ":$PATH:" == *":$dir:"* ]]; then
      echo "$dir"
      return
    fi
  done
  mkdir -p "$HOME/.local/bin"
  echo "$HOME/.local/bin"
}

ensure_path_in_profiles() {
  local dir="$1"
  local export_line="export PATH=\"$dir:\$PATH\""
  local added=0
  for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    [ -f "$rc" ] || continue
    if ! grep -qF "$dir" "$rc" 2>/dev/null; then
      printf '\n# Added by devctl-dev installer\n%s\n' "$export_line" >> "$rc"
      echo "  → Added to $rc" >&2
      added=1
    fi
  done
  if [ "$added" = "0" ]; then
    echo "  → $dir already in shell profiles" >&2
  fi
}

build_devctl_from_branch() {
  local branch="$1" output="$2" owner="$3" repo="$4"
  local build_dir clone_url

  if ! command -v git >/dev/null 2>&1; then
    echo "❌ git is required to build from branch. Install git and re-run." >&2
    exit 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "❌ python3 is required to build from branch." >&2
    exit 1
  fi
  if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    echo "❌ Python 3.11+ is required to build from branch." >&2
    exit 1
  fi
  if ! python3 -m pip --version >/dev/null 2>&1; then
    echo "❌ pip is required to build from branch." >&2
    exit 1
  fi

  build_dir=$(mktemp -d)
  clone_url="https://github.com/${owner}/${repo}.git"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    clone_url="https://${GITHUB_TOKEN}@github.com/${owner}/${repo}.git"
  fi

  echo "  → Cloning ${owner}/${repo} (branch: ${branch})..." >&2
  if ! git clone --depth 1 --branch "$branch" "$clone_url" "$build_dir/src" 2>&1; then
    echo "  → Shallow clone failed, trying full clone..." >&2
    rm -rf "$build_dir/src"
    if ! git clone "$clone_url" "$build_dir/src" 2>&1; then
      rm -rf "$build_dir"
      echo "❌ Clone failed. For private repos: export GITHUB_TOKEN=ghp_xxx" >&2
      exit 1
    fi
    if ! git -C "$build_dir/src" checkout "$branch" 2>&1; then
      rm -rf "$build_dir"
      echo "❌ Checkout failed for branch: ${branch}" >&2
      exit 1
    fi
  fi

  if ! grep -q 'DEVCTL_HOME' "$build_dir/src/src/devctl/utils/shell.py" 2>/dev/null; then
    rm -rf "$build_dir"
    echo "❌ Branch ${owner}/${repo}@${branch} lacks DEVCTL_HOME isolation in shell.py." >&2
    echo "   Push DEVCTL_HOME support to that branch and re-run install_dev.sh." >&2
    exit 1
  fi

  if ! _pyinstaller_build "$build_dir/src" "$output"; then
    rm -rf "$build_dir"
    exit 1
  fi
  rm -rf "$build_dir"
}

build_devctl() {
  local branch="$1" output="$2" owner="$3" repo="$4"
  build_devctl_from_branch "$branch" "$output" "$owner" "$repo"
}

warmup_devctl_binary() {
  local devctl_bin="$1"
  echo "  → Warming up binary (--help)..." >&2
  run_devctl "$devctl_bin" --help >/dev/null 2>&1 || true
  sleep 1
}

run_ai_kit_setup_with_retry() {
  local devctl_bin="$1"
  shift
  local attempt
  for attempt in 1 2 3; do
    if run_devctl "$devctl_bin" "$@"; then
      return 0
    fi
    if [ "$attempt" -lt 3 ]; then
      echo "  → ai-kit setup failed (attempt ${attempt}/3), retrying in 2s..." >&2
      sleep 2
    fi
  done
  return 1
}

collect_dev_settings() {
  echo "" >&2
  echo "=== devctl-dev install (isolated from production ~/.devctl) ===" >&2
  echo "Press Enter to accept defaults shown in [brackets]." >&2
  echo "" >&2

  local github_default="${GITHUB_OWNER:-WorkIndia-Private}/${GITHUB_REPO:-wi-devctl}"
  if [ -n "${GITHUB_REPO:-}" ] && [[ "${GITHUB_REPO:-}" == *"://"* || "${GITHUB_REPO:-}" == git@* ]]; then
    github_default="${GITHUB_REPO}"
  fi

  prompt_with_default GITHUB_REPO_SPEC \
    "GitHub repo for wi-devctl (owner/repo or github.com URL)" \
    "$github_default"
  prompt_with_default DEVCTL_BRANCH "Git branch to build devctl-dev from" "${DEVCTL_BRANCH:-}"

  if [ -z "${DEVCTL_BRANCH:-}" ]; then
    echo "❌ A devctl branch is required for install_dev.sh." >&2
    exit 1
  fi

  local github_parts
  github_parts=$(normalize_github_repo "$GITHUB_REPO_SPEC") || exit 1
  GITHUB_OWNER=$(echo "$github_parts" | sed -n '1p')
  GITHUB_REPO=$(echo "$github_parts" | sed -n '2p')

  prompt_github_token

  prompt_with_default DEVCTL_AI_KIT_REPO "AI collab kit repo URL (leave empty to skip)" "${DEVCTL_AI_KIT_REPO:-}"

  if [ -n "${DEVCTL_AI_KIT_REPO:-}" ]; then
    prompt_with_default DEVCTL_AI_KIT_REPO_BRANCH "AI collab kit git branch (leave empty for repo default)" "${DEVCTL_AI_KIT_REPO_BRANCH:-}"
  else
    DEVCTL_AI_KIT_REPO_BRANCH=""
  fi

  echo "" >&2
  echo "Local data folder (stores state.json, repos, logs — not a GitHub URL):" >&2
  prompt_with_default DEVCTL_HOME_RAW "Local data directory on this machine (DEVCTL_HOME)" "$(devctl_home_prompt_default)"
  DEVCTL_HOME=$(expand_home_path "${DEVCTL_HOME_RAW:-$(devctl_home_prompt_default)}")

  echo "" >&2
  echo "Summary:" >&2
  echo "  local data:    ${DEVCTL_HOME}" >&2
  echo "  binary:        devctl-dev (production devctl is not modified)" >&2
  echo "  devctl source: ${GITHUB_OWNER}/${GITHUB_REPO}@${DEVCTL_BRANCH}" >&2
  if [ -n "${DEVCTL_AI_KIT_REPO:-}" ]; then
    if [ -n "${DEVCTL_AI_KIT_REPO_BRANCH:-}" ]; then
      echo "  ai-kit repo:   ${DEVCTL_AI_KIT_REPO} (branch: ${DEVCTL_AI_KIT_REPO_BRANCH})" >&2
    else
      echo "  ai-kit repo:   ${DEVCTL_AI_KIT_REPO} (default branch)" >&2
    fi
  else
    echo "  ai-kit repo:   (skipped)" >&2
  fi
  echo "" >&2

  prompt_yes_no CONFIRM "Continue with install?" "y"
  if [ "$CONFIRM" != "1" ]; then
    echo "Install cancelled." >&2
    exit 0
  fi
}

main() {
  collect_dev_settings
  mkdir -p "${DEVCTL_HOME}/repos" "${DEVCTL_HOME}/logs" "${DEVCTL_HOME}/backups"
  export DEVCTL_HOME

  TOTAL_STEPS=7
  [ -n "${DEVCTL_AI_KIT_REPO:-}" ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))

  log_step "Detecting platform"
  local platform
  platform=$(detect_platform)
  echo "  → $platform" >&2

  log_step "Choosing install directory"
  INSTALL_DIR=$(choose_install_dir)
  echo "  → $INSTALL_DIR" >&2

  local binary_name="devctl-dev"
  [[ "$platform" == windows* ]] && binary_name="devctl-dev.exe"

  log_step "Building devctl-dev from branch (${DEVCTL_BRANCH})"
  build_devctl "${DEVCTL_BRANCH}" "${INSTALL_DIR}/${binary_name}" "${GITHUB_OWNER}" "${GITHUB_REPO}"

  if [ "$INSTALL_DIR" = "$HOME/.local/bin" ]; then
    ensure_path_in_profiles "$INSTALL_DIR"
  fi

  export PATH="${INSTALL_DIR}:$PATH"
  local devctl_bin="${INSTALL_DIR}/${binary_name}"

  log_step "Verifying DEVCTL_HOME isolation"
  verify_devctl_home_isolation "$devctl_bin" "$DEVCTL_HOME"

  local ver_output
  ver_output=$(run_devctl "$devctl_bin" --version 2>&1) || {
    echo "❌ Binary verification failed (non-zero exit)" >&2
    exit 1
  }
  if [ -z "$ver_output" ]; then
    echo "❌ Binary verification failed (no output from --version)" >&2
    exit 1
  fi
  echo "  → $ver_output" >&2

  if [ -n "${DEVCTL_AI_KIT_REPO:-}" ]; then
    log_step "ai-kit setup (dev home: ${DEVCTL_HOME})"
    if ! command -v git >/dev/null 2>&1; then
      echo "❌ git is required for ai-kit setup." >&2
      exit 1
    fi

    local ai_kit_slug
    ai_kit_slug=$(url_to_slug "$DEVCTL_AI_KIT_REPO")

    if [ -n "${DEVCTL_AI_KIT_REPO_BRANCH:-}" ]; then
      reset_ai_kit_clone "$ai_kit_slug"
    fi

    local setup_args=(ai-kit setup --repo "$DEVCTL_AI_KIT_REPO")
    if [ -n "${DEVCTL_AI_KIT_REPO_BRANCH:-}" ]; then
      setup_args+=(--branch "$DEVCTL_AI_KIT_REPO_BRANCH")
    fi

    warmup_devctl_binary "$devctl_bin"
    if ! run_ai_kit_setup_with_retry "$devctl_bin" "${setup_args[@]}"; then
      echo "❌ ai-kit setup failed after 3 attempts." >&2
      exit 1
    fi
    echo "  → ai-kit setup complete" >&2
    verify_dev_setup_artifacts
  fi

  echo "" >&2
  echo "🚀 devctl-dev ready. Run: DEVCTL_HOME=${DEVCTL_HOME} devctl-dev --help" >&2
  echo "   State: ${DEVCTL_HOME}/state.json" >&2

  if [ "$INSTALL_DIR" = "$HOME/.local/bin" ]; then
    echo "  Restart your shell (or run: source ~/.zshrc) for PATH to take effect." >&2
  fi
}

main "$@"
