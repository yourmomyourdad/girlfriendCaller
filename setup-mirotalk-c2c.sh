#!/usr/bin/env bash
# Create a GitHub fork of MiroTalk C2C, configure Codespaces, and launch it.
# Run from a Bash terminal with GitHub CLI (gh) installed.
set -Eeuo pipefail

UPSTREAM="miroslavpejic85/mirotalkc2c"
DEFAULT_REPO_NAME="our-video-call"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || fail "GitHub CLI (gh) is missing. Run this in a GitHub Codespaces terminal, or install GitHub CLI first."
command -v git >/dev/null 2>&1 || fail "git is missing."
command -v jq >/dev/null 2>&1 || fail "jq is missing. It is normally available in GitHub Codespaces."

if ! gh auth status >/dev/null 2>&1; then
  say "Signing in to GitHub"
  gh auth login -h github.com -p https -w || fail "GitHub login failed."
fi

say "Checking GitHub permissions"
# These scopes may require a one-time approval in the browser.
gh auth refresh -h github.com -s repo -s codespace || fail "GitHub permissions were not granted."
gh auth setup-git >/dev/null

LOGIN="$(gh api user --jq .login)"
read -rp "Name for your copy of the project [$DEFAULT_REPO_NAME]: " REPO_NAME
REPO_NAME="${REPO_NAME:-$DEFAULT_REPO_NAME}"
REPO_NAME="$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')"
[[ -n "$REPO_NAME" ]] || fail "That repository name is not valid."
TARGET="$LOGIN/$REPO_NAME"

say "Preparing $TARGET"
if gh repo view "$TARGET" >/dev/null 2>&1; then
  PARENT="$(gh api "repos/$TARGET" --jq '.parent.full_name // ""' 2>/dev/null || true)"
  if [[ "${PARENT,,}" != "${UPSTREAM,,}" ]]; then
    fail "$TARGET already exists and is not a fork of $UPSTREAM. Re-run and choose a different repository name."
  fi
  echo "Found your existing fork; reusing it."
else
  gh repo fork "$UPSTREAM" --fork-name "$REPO_NAME" --clone=false --remote=false || \
    fail "Could not fork $UPSTREAM. Check your GitHub permissions and try again."
fi

# Wait briefly for the new fork to become visible to GitHub's API.
for _ in $(seq 1 30); do
  if gh repo view "$TARGET" >/dev/null 2>&1; then break; fi
  sleep 2
done
gh repo view "$TARGET" >/dev/null 2>&1 || fail "GitHub created the fork but it is not visible yet. Re-run this script in a minute."
BRANCH="$(gh repo view "$TARGET" --json defaultBranchRef --jq '.defaultBranchRef.name')"
[[ -n "$BRANCH" && "$BRANCH" != "null" ]] || fail "Could not determine the fork's default branch."

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT
say "Cloning your fork and adding one-click Codespaces setup"
git clone --single-branch --branch "$BRANCH" "https://github.com/$TARGET.git" "$WORKDIR"
git -C "$WORKDIR" config user.name "$LOGIN"
git -C "$WORKDIR" config user.email "$LOGIN@users.noreply.github.com"
mkdir -p "$WORKDIR/.devcontainer"

cat > "$WORKDIR/.devcontainer/devcontainer.json" <<'JSON'
{
  "name": "Our Video Call - MiroTalk C2C",
  "image": "mcr.microsoft.com/devcontainers/javascript-node:1-22-bookworm",
  "forwardPorts": [8080],
  "portsAttributes": {
    "8080": {
      "label": "Our Video Call",
      "onAutoForward": "openBrowser"
    }
  },
  "postCreateCommand": "bash .devcontainer/setup.sh",
  "postStartCommand": "bash .devcontainer/start.sh",
  "remoteUser": "node"
}
JSON

cat > "$WORKDIR/.devcontainer/setup.sh" <<'SETUP'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  cp .env.template .env
  # Replace the example API key with a random per-Codespace value.
  if command -v openssl >/dev/null 2>&1; then
    API_SECRET="$(openssl rand -hex 32)"
    if grep -q '^API_KEY_SECRET=' .env; then
      sed -i "s/^API_KEY_SECRET=.*/API_KEY_SECRET=${API_SECRET}/" .env
    fi
  fi
fi
npm ci
SETUP

cat > "$WORKDIR/.devcontainer/start.sh" <<'START'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

if curl -fsS --max-time 2 http://127.0.0.1:8080/ >/dev/null 2>&1; then
  exit 0
fi
if ! pgrep -f '[n]ode backend/server.js' >/dev/null 2>&1; then
  nohup npm start > /tmp/mirotalk-c2c.log 2>&1 </dev/null &
fi
for _ in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8080/ >/dev/null 2>&1; then
    echo "MiroTalk C2C is running on port 8080."
    exit 0
  fi
  sleep 2
done
echo "MiroTalk did not respond on port 8080. Recent server log:" >&2
tail -n 60 /tmp/mirotalk-c2c.log 2>/dev/null || true
exit 1
START

chmod +x "$WORKDIR/.devcontainer/setup.sh" "$WORKDIR/.devcontainer/start.sh"
git -C "$WORKDIR" add .devcontainer
git -C "$WORKDIR" commit -m "Add automatic GitHub Codespaces setup" >/dev/null || {
  echo "No setup changes to commit."
}
git -C "$WORKDIR" push origin "$BRANCH"

say "Creating a GitHub Codespace"
BEFORE_NAMES="$(gh codespace list --json name,repository --jq ".[] | select(.repository == \"$TARGET\") | .name" 2>/dev/null || true)"
if ! gh codespace create \
  --repo "$TARGET" \
  --branch "$BRANCH" \
  --devcontainer-path .devcontainer/devcontainer.json \
  --display-name "Our Video Call" \
  --idle-timeout 30m \
  --retention-period 7d; then
  echo
  echo "Your GitHub repository is ready: https://github.com/$TARGET"
  fail "The repository was set up, but GitHub could not create the Codespace. Check your Codespaces quota/billing and use Code > Codespaces on the repository to create it manually."
fi

say "Finding the new Codespace"
CS_NAME=""
for _ in $(seq 1 60); do
  while IFS= read -r NAME; do
    [[ -n "$NAME" ]] || continue
    if ! printf '%s\n' "$BEFORE_NAMES" | grep -Fxq "$NAME"; then
      CS_NAME="$NAME"
      break
    fi
  done < <(gh codespace list --json name,repository --jq ".[] | select(.repository == \"$TARGET\") | .name" 2>/dev/null || true)
  [[ -n "$CS_NAME" ]] && break
  sleep 2
done
if [[ -z "$CS_NAME" ]]; then
  echo "Repository setup succeeded: https://github.com/$TARGET"
  echo "GitHub may still be preparing the Codespace. Check https://github.com/codespaces"
  exit 0
fi

echo
read -rp "Make port 8080 PUBLIC so your girlfriend can open the call without GitHub login? Anyone with the URL can access the app. [y/N]: " MAKE_PUBLIC
if [[ "$MAKE_PUBLIC" =~ ^[Yy]$ ]]; then
  say "Making the call app reachable by link"
  # Wait for port detection before changing its visibility.
  PORT_READY=0
  for _ in $(seq 1 45); do
    PORTS="$(gh codespace ports -c "$CS_NAME" --json sourcePort,browseUrl 2>/dev/null || true)"
    if printf '%s' "$PORTS" | jq -e 'any(.[]; .sourcePort == 8080)' >/dev/null 2>&1; then
      PORT_READY=1
      break
    fi
    sleep 2
  done
  if [[ "$PORT_READY" == "1" ]]; then
    gh codespace ports visibility 8080:public -c "$CS_NAME" || \
      echo "Couldn't change visibility automatically; use the Codespaces Ports panel and set port 8080 to Public."
  else
    echo "Port 8080 has not appeared yet. After the Codespace finishes starting, set port 8080 to Public in the Ports panel."
  fi
fi

APP_URL=""
for _ in $(seq 1 30); do
  APP_URL="$(gh codespace ports -c "$CS_NAME" --json sourcePort,browseUrl --jq '.[] | select(.sourcePort == 8080) | .browseUrl' 2>/dev/null | head -n 1 || true)"
  [[ -n "$APP_URL" && "$APP_URL" != "null" ]] && break
  sleep 2
done

printf '\n\033[1;32mSETUP COMPLETE\033[0m\n'
printf 'Repository: https://github.com/%s\n' "$TARGET"
printf 'Codespace:  %s\n' "$CS_NAME"
if [[ -n "$APP_URL" && "$APP_URL" != "null" ]]; then
  printf 'Call app:   %s\n' "$APP_URL"
else
  echo "Call app: port 8080 is being prepared. Open the Codespaces Ports panel to get its URL."
fi
printf '\nThe Codespace must remain running during calls. Stop it when you are done.\n'
printf 'License note: MiroTalk C2C is AGPL-3.0; review its license before distributing modified versions.\n'

# Ask GitHub CLI to open the editor if this environment supports it; setup remains
# complete if automatic browser opening isn't available in this terminal.
gh codespace code -c "$CS_NAME" --web >/dev/null 2>&1 || true
