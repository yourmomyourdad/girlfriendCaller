
#!/usr/bin/env bash
# MiroTalk C2C setup for an existing GitHub Codespace.
# Installs the app, starts it, and configures automatic startup.

set -Eeuo pipefail

UPSTREAM="https://github.com/miroslavpejic85/mirotalkc2c.git"
TARGET_DIR="/workspaces/mirotalkc2c"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DEVCONTAINER_DIR="$WORKSPACE_ROOT/.devcontainer"
LOG_FILE="/tmp/mirotalk-c2c.log"

say() {
  printf '\n==> %s\n' "$*"
}

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

# Check prerequisites.
for cmd in git node npm curl; do
  command -v "$cmd" >/dev/null 2>&1 ||
    fail "Missing required program: $cmd"
done

# If this script is running inside the MiroTalk repository,
# use the current directory instead of cloning another copy.
if [[ -f "$WORKSPACE_ROOT/package.json" ]] &&
   node -e 'process.exit(require(process.argv[1]).name === "mirotalkc2c" ? 0 : 1)' \
     "$WORKSPACE_ROOT/package.json" 2>/dev/null; then
  TARGET_DIR="$WORKSPACE_ROOT"
fi

# Clone the official project if it does not exist yet.
say "Finding MiroTalk C2C"

if [[ -d "$TARGET_DIR" ]]; then
  [[ -f "$TARGET_DIR/package.json" ]] ||
    fail "$TARGET_DIR exists but is not a MiroTalk project."

  node -e 'process.exit(require(process.argv[1]).name === "mirotalkc2c" ? 0 : 1)' \
    "$TARGET_DIR/package.json" 2>/dev/null ||
    fail "$TARGET_DIR is not the MiroTalk C2C project."

  echo "Using existing installation: $TARGET_DIR"
else
  mkdir -p "$(dirname "$TARGET_DIR")"
  git clone "$UPSTREAM" "$TARGET_DIR"
fi

cd "$TARGET_DIR"

# Create local configuration if it doesn't exist.
say "Preparing configuration"

if [[ ! -f .env ]]; then
  [[ -f .env.template ]] ||
    fail "The project's .env.template file is missing."

  cp .env.template .env
  echo "Created .env"
fi

# Replace the known demo API secret if it is still present.
if grep -q '^API_KEY_SECRET=mirotalkc2c_default_secret' .env; then
  SECRET="$(node -e \
    'console.log(require("crypto").randomBytes(32).toString("hex"))')"

  sed -i \
    "s/^API_KEY_SECRET=mirotalkc2c_default_secret.*/API_KEY_SECRET=$SECRET/" \
    .env

  echo "Generated a private API secret in .env"
fi

# Install dependencies.
say "Installing dependencies"
npm install --no-audit --no-fund

# Create Codespaces helper scripts.
mkdir -p "$DEVCONTAINER_DIR"

cat > "$DEVCONTAINER_DIR/mirotalk-install.sh" <<'INSTALL'
#!/usr/bin/env bash
set -Eeuo pipefail

DIR="/workspaces/mirotalkc2c"

if [[ ! -d "$DIR/.git" ]]; then
  mkdir -p "$(dirname "$DIR")"
  git clone https://github.com/miroslavpejic85/mirotalkc2c.git "$DIR"
fi

cd "$DIR"

[[ -f .env ]] || cp .env.template .env

npm install --no-audit --no-fund
INSTALL

cat > "$DEVCONTAINER_DIR/mirotalk-start.sh" <<'START'
#!/usr/bin/env bash
set -Eeuo pipefail

DIR="/workspaces/mirotalkc2c"
LOG="/tmp/mirotalk-c2c.log"

if [[ ! -f "$DIR/.env" ]]; then
  bash /workspaces/girlfriendCaller/.devcontainer/mirotalk-install.sh
fi

# Do not start a second server if one is already responding.
if curl -fsS --max-time 2 http://127.0.0.1:8080/ >/dev/null 2>&1; then
  echo "MiroTalk is already running on port 8080."
  exit 0
fi

# Start the application in the background.
if ! pgrep -f '[n]ode backend/server.js' >/dev/null 2>&1; then
  (cd "$DIR" && nohup npm start >"$LOG" 2>&1 </dev/null &)
fi

# Wait up to one minute for the server.
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8080/ >/dev/null 2>&1; then
    echo "MiroTalk is running on port 8080."
    exit 0
  fi

  sleep 2
done

echo "The server did not start. Recent log:" >&2
tail -n 60 "$LOG" 2>/dev/null || true
exit 1
START

chmod +x \
  "$DEVCONTAINER_DIR/mirotalk-install.sh" \
  "$DEVCONTAINER_DIR/mirotalk-start.sh"

# Configure Codespaces to forward port 8080 and start the server.
say "Configuring automatic startup"

DEVCONTAINER_JSON="$DEVCONTAINER_DIR/devcontainer.json"

if [[ ! -f "$DEVCONTAINER_JSON" ]]; then
  cat > "$DEVCONTAINER_JSON" <<'JSON'
{
  "name": "MiroTalk C2C",
  "image": "mcr.microsoft.com/devcontainers/universal:2",
  "forwardPorts": [8080],
  "portsAttributes": {
    "8080": {
      "label": "Our Video Call",
      "onAutoForward": "openBrowser"
    }
  },
  "postCreateCommand": "bash .devcontainer/mirotalk-install.sh",
  "postStartCommand": "bash .devcontainer/mirotalk-start.sh"
}
JSON
  echo "Created devcontainer.json"
else
  echo "Existing devcontainer.json found; leaving it unchanged."
  echo "You may need to add the settings shown below manually."
fi

# Start the app for this session.
say "Starting MiroTalk"

if curl -fsS --max-time 2 http://127.0.0.1:8080/ >/dev/null 2>&1; then
  echo "The server is already running."
else
  (cd "$TARGET_DIR" && nohup npm start >"$LOG_FILE" 2>&1 </dev/null &)

  for i in $(seq 1 30); do
    if curl -fsS --max-time 2 http://127.0.0.1:8080/ >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
fi

if ! curl -fsS --max-time 2 http://127.0.0.1:8080/ >/dev/null 2>&1; then
  echo "Startup failed. Recent server log:" >&2
  tail -n 60 "$LOG_FILE" 2>/dev/null || true
  exit 1
fi

printf '\n====================================\n'
printf '       MIROTALK IS READY 💗\n'
printf '====================================\n'
printf 'App directory: %s\n' "$TARGET_DIR"
printf 'Local address: http://localhost:8080\n'

if [[ -n "${CODESPACE_NAME:-}" &&
      -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]]; then
  printf 'Codespaces URL: https://%s-8080.%s\n' \
    "$CODESPACE_NAME" "$GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN"
fi

printf '\nNext steps:\n'
printf '1. Open the PORTS tab in Codespaces.\n'
printf '2. Open port 8080 in your browser.\n'
printf '3. Set port 8080 to Public if your girlfriend needs to connect without GitHub access.\n'
printf '4. Keep the Codespace running during calls.\n'
printf '\nServer log: %s\n' "$LOG_FILE"
