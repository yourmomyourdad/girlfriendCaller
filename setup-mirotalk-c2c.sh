#!/usr/bin/env bash
# Start MiroTalk C2C in an existing GitHub Codespace.
# Run with: bash start-mirotalk-c2c.sh
set -Eeuo pipefail

REPO_URL="https://github.com/miroslavpejic85/mirotalkc2c.git"
APP_DIR="${MIROTALK_DIR:-/workspaces/mirotalkc2c}"

say() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

for cmd in git node npm curl; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing required command: $cmd"
done

say "Checking MiroTalk C2C"
if [[ ! -f "$APP_DIR/package.json" ]]; then
  if [[ -e "$APP_DIR" ]] && [[ -n "$(ls -A "$APP_DIR" 2>/dev/null || true)" ]]; then
    fail "$APP_DIR exists but doesn't contain MiroTalk. Set MIROTALK_DIR to another directory if needed."
  fi
  mkdir -p "$(dirname "$APP_DIR")"
  git clone "$REPO_URL" "$APP_DIR"
fi

node - "$APP_DIR/package.json" <<'NODE'
const p = require(process.argv[2]);
if (p.name !== 'mirotalkc2c') {
  console.error('The selected folder is not the MiroTalk C2C project.');
  process.exit(1);
}
NODE

cd "$APP_DIR"

say "Preparing .env"
if [[ ! -f .env ]]; then
  [[ -f .env.template ]] || fail "Can't find .env.template in $APP_DIR"
  cp .env.template .env
fi

PUBLIC_URL=""
if [[ -n "${CODESPACE_NAME:-}" && -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]]; then
  PUBLIC_URL="https://${CODESPACE_NAME}-8080.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
  export MIROTALK_PUBLIC_URL="$PUBLIC_URL"
  # HOST makes generated room links use the HTTPS Codespaces address (not localhost).
  # TRUST_PROXY is needed because Codespaces puts a reverse proxy in front of the app.
  node - .env <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const url = process.env.MIROTALK_PUBLIC_URL;
let lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
function setEnv(key, value) {
  const re = new RegExp('^\\s*' + key + '\\s*=');
  const replacement = `${key}=${value}`;
  const i = lines.findIndex(line => re.test(line));
  if (i >= 0) lines[i] = replacement;
  else lines.push(replacement);
}
setEnv('HOST', `'${url}'`);
setEnv('PORT', '8080');
setEnv('TRUST_PROXY', 'true');
fs.writeFileSync(file, lines.join('\n').replace(/\n*$/, '\n'));
NODE
  say "Room links will use ${PUBLIC_URL}"
else
  say "Codespaces URL variables weren't found; using the project's existing HOST setting."
fi

if [[ ! -d node_modules ]]; then
  say "Installing dependencies (first run only)"
  if [[ -f package-lock.json ]]; then
    npm ci --no-audit --no-fund
  else
    npm install --no-audit --no-fund
  fi
fi

# Codespaces forwards ports as PRIVATE (GitHub login required), so your partner
# can't open the link. Once the server is up, make port 8080 public.
if [[ -n "${CODESPACE_NAME:-}" ]]; then
  (
    for _ in $(seq 1 60); do
      if curl -fs -o /dev/null "http://localhost:8080/"; then
        if command -v gh >/dev/null 2>&1 && gh codespace ports visibility 8080:public -c "$CODESPACE_NAME" >/dev/null 2>&1; then
          printf '\n==> Port 8080 is now PUBLIC. Send her this link:\n    %s\n\n' "$PUBLIC_URL"
        else
          printf '\n==> Could not make port 8080 public automatically.\n    In the PORTS tab: right-click 8080 > Port Visibility > Public.\n    Then send her: %s\n\n' "$PUBLIC_URL"
        fi
        exit 0
      fi
      sleep 1
    done
  ) &
fi

printf '\n===========================================\n'
printf ' MiroTalk C2C is starting 💗\n'
printf '===========================================\n'
printf 'Project: %s\n' "$APP_DIR"
printf 'Keep this terminal running during calls.\n\n'

# Run in the foreground so terminal output shows any startup errors.
exec npm start
