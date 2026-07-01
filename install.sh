#!/usr/bin/env sh
set -eu

# Default repo is rewritten by CI from HUBBOUND_RELEASES_REPOSITORY when published.
REPO="${HUBBOUND_REPO:-KodastrDevelopment/hubbound-releases}"
INSTALL_DIR="${HUBBOUND_INSTALL_DIR:-$HOME/.local/bin}"
INSTALL_AGENT="${HUBBOUND_INSTALL_AGENT:-1}"
BASE_URL="https://github.com/${REPO}/releases/latest/download"

log() { printf '%s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || {
	log "missing required command: $1"
	exit 1
}; }

need curl
need tar

os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
case "$os" in
darwin | linux) ;;
*)
	log "unsupported OS: $os"
	exit 1
	;;
esac
case "$arch" in
x86_64 | amd64) arch="amd64" ;;
arm64 | aarch64) arch="arm64" ;;
*)
	log "unsupported arch: $arch"
	exit 1
	;;
esac

archive="hubbound_${os}_${arch}.tar.gz"
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

log "downloading $archive"
curl -fsSL "${BASE_URL}/${archive}" -o "$tmp/$archive"
curl -fsSL "${BASE_URL}/checksums.txt" -o "$tmp/checksums.txt"

expected=$(grep "  ${archive}$" "$tmp/checksums.txt" | awk '{print $1}')
if [ -z "${expected:-}" ]; then
	log "checksum not found for $archive"
	exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
	actual=$(sha256sum "$tmp/$archive" | awk '{print $1}')
else
	actual=$(shasum -a 256 "$tmp/$archive" | awk '{print $1}')
fi
[ "$expected" = "$actual" ] || {
	log "checksum mismatch for $archive"
	exit 1
}

mkdir -p "$INSTALL_DIR"
tar -xzf "$tmp/$archive" -C "$tmp"
for bin in hubbound hubbound-agent hubbound-helper; do
	if [ ! -f "$tmp/$bin" ]; then
		log "archive missing $bin"
		exit 1
	fi
	install -m 0755 "$tmp/$bin" "$INSTALL_DIR/$bin"
done

case ":$PATH:" in
*":$INSTALL_DIR:"*) ;;
*)
	shell_rc="$HOME/.profile"
	[ -n "${ZSH_VERSION:-}" ] && shell_rc="$HOME/.zshrc"
	[ -n "${BASH_VERSION:-}" ] && shell_rc="$HOME/.bashrc"
	{
		printf '\n# Hubbound\n'
		printf 'export PATH="%s:$PATH"\n' "$INSTALL_DIR"
	} >>"$shell_rc"
	log "added $INSTALL_DIR to PATH in $shell_rc; open a new terminal or run: export PATH=\"$INSTALL_DIR:\$PATH\""
	;;
esac

if [ "$INSTALL_AGENT" = "1" ]; then
	if [ "$os" = "darwin" ]; then
		plist_dir="$HOME/Library/LaunchAgents"
		plist="$plist_dir/com.hubbound.agent.plist"
		mkdir -p "$plist_dir"
		cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.hubbound.agent</string>
  <key>ProgramArguments</key><array><string>${INSTALL_DIR}/hubbound-agent</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${HOME}/Library/Logs/hubbound-agent.log</string>
  <key>StandardErrorPath</key><string>${HOME}/Library/Logs/hubbound-agent.err.log</string>
</dict></plist>
PLIST
		launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
		launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1 || launchctl load "$plist" >/dev/null 2>&1 || true
		log "installed LaunchAgent: $plist"
	elif command -v systemctl >/dev/null 2>&1; then
		unit_dir="$HOME/.config/systemd/user"
		unit="$unit_dir/hubbound-agent.service"
		mkdir -p "$unit_dir"
		cat >"$unit" <<UNIT
[Unit]
Description=Hubbound user agent
After=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/hubbound-agent run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
		systemctl --user daemon-reload >/dev/null 2>&1 || true
		systemctl --user enable --now hubbound-agent.service >/dev/null 2>&1 || true
		log "installed systemd user service: $unit"
	fi
fi

log "hubbound installed at $INSTALL_DIR/hubbound"
log "try: hubbound version"
