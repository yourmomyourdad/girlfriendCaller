#!/usr/bin/env bash
# Start MiroTalk C2C in an existing GitHub Codespace.
# Run with: bash start-mirotalk-c2c.sh
set -Eeuo pipefail

REPO_URL="https://github.com/miroslavpejic85/mirotalkc2c.git"
APP_DIR="${MIROTALK_DIR:-/workspaces/mirotalkc2c}"

say() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

for cmd in git node npm; do
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

# In Codespaces, set the advertised base URL so generated room links use the
# browser-accessible HTTPS address rather than localhost. Outside Codespaces,
# leave the existing HOST setting alone.
if [[ -n "${CODESPACE_NAME:-}" && -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]]; then
  export MIROTALK_PUBLIC_URL="https://${CODESPACE_NAME}-8080.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
  node - .env <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const url = process.env.MIROTALK_PUBLIC_URL;
let lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
function setEnv(key, value) {
  const re = new RegExp('^\\s*' + key + '\\s*=');
  const replacement = `${key}="${value}"`;
  const i = lines.findIndex(line => re.test(line));
  if (i >= 0) lines[i] = replacement;
  else lines.push(replacement);
}
setEnv('HOST', url);
setEnv('PORT', '8080');
fs.writeFileSync(file, lines.join('\n').replace(/\n*$/, '\n'));
NODE
  say "Room links will use ${MIROTALK_PUBLIC_URL}"
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

printf '\n===========================================\n'
printf ' MiroTalk C2C is starting 💗\n'
printf '===========================================\n'
printf 'Project: %s\n' "$APP_DIR"
printf 'When the server starts, open port 8080 in the Codespaces PORTS tab.\n'
printf 'Keep this terminal running during calls.\n\n'

# Run in the foreground so terminal output shows any startup errors.
exec npm start
