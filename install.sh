#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
HERMES_AGENT_DIR="${HERMES_AGENT_DIR:-$HERMES_HOME/hermes-agent}"
PATCHES_DIR="$HERMES_HOME/patches"
MARKER="# hermes-claude-auth managed"

# ── Parse flags ─────────────────────────────────────────────────────
POST_UPDATE=false
CHECK_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --post-update) POST_UPDATE=true ;;
        --check)       CHECK_ONLY=true ;;
        *) ;;
    esac
done

# ── Pre-flight checks ───────────────────────────────────────────────
if [ ! -d "$HERMES_AGENT_DIR" ]; then
    printf "${RED}[✗] hermes-agent not found at %s${RESET}\n" "$HERMES_AGENT_DIR"
    printf "    Install hermes-agent first: https://github.com/nousresearch/hermes-agent\n"
    exit 1
fi

if [ -n "${HERMES_VENV:-}" ] && [ -d "$HERMES_VENV" ]; then
    VENV_DIR="$HERMES_VENV"
elif [ -d "$HERMES_AGENT_DIR/venv" ]; then
    VENV_DIR="$HERMES_AGENT_DIR/venv"
elif [ -d "$HERMES_AGENT_DIR/.venv" ]; then
    VENV_DIR="$HERMES_AGENT_DIR/.venv"
else
    printf "${RED}[✗] No virtualenv found in %s (checked venv/, .venv/, and \$HERMES_VENV)${RESET}\n" "$HERMES_AGENT_DIR"
    exit 1
fi

VENV_PYTHON="$VENV_DIR/bin/python"
if [ ! -x "$VENV_PYTHON" ]; then VENV_PYTHON="$VENV_DIR/bin/python3"; fi
if [ ! -x "$VENV_PYTHON" ]; then
    printf "${RED}[✗] Python not found at %s${RESET}\n" "$VENV_PYTHON"
    exit 1
fi

SITE_PACKAGES="$("$VENV_PYTHON" -c "import site; print(site.getsitepackages()[0] if site.getsitepackages() else site.getusersitepackages())")"
if [ ! -d "$SITE_PACKAGES" ]; then
    printf "${RED}[✗] site-packages directory does not exist: %s${RESET}\n" "$SITE_PACKAGES"
    exit 1
fi

SITECUSTOMIZE="$SITE_PACKAGES/sitecustomize.py"

# ── --check mode: verify patch integrity ────────────────────────────
if $CHECK_ONLY; then
    ALL_OK=true
    for f in "$PATCHES_DIR/anthropic_billing_bypass.py"; do
        if [[ -f "$f" ]]; then
            printf "${GREEN}[✓] %s${RESET}\n" "$f"
        else
            printf "${RED}[✗] MISSING: %s${RESET}\n" "$f"
            ALL_OK=false
        fi
    done

    if [[ -f "$SITECUSTOMIZE" ]] && grep -q "$MARKER" "$SITECUSTOMIZE"; then
        printf "${GREEN}[✓] sitecustomize hook present${RESET}\n"
    else
        printf "${RED}[✗] sitecustomize hook MISSING or outdated${RESET}\n"
        ALL_OK=false
    fi

    if $ALL_OK; then
        printf "\n${GREEN}Claude Code bypass patches intact.${RESET}\n"
        exit 0
    else
        printf "\n${YELLOW}Some patches missing. Run: ./scripts/install.sh --post-update${RESET}\n"
        exit 1
    fi
fi

# ── Full install or post-update recovery ────────────────────────────
if $POST_UPDATE; then
    printf "${YELLOW}[post-update] Restoring Claude Code bypass after hermes update...${RESET}\n"
else
    printf "${YELLOW}[install] Installing Claude Code OAuth bypass...${RESET}\n"
fi

# ── Copy patch ──────────────────────────────────────────────────────
mkdir -p "$PATCHES_DIR"
cp "$SCRIPT_DIR/anthropic_billing_bypass.py" "$PATCHES_DIR/anthropic_billing_bypass.py"
chmod 644 "$PATCHES_DIR/anthropic_billing_bypass.py"
printf "${GREEN}[✓] Copied patch to %s/${RESET}\n" "$PATCHES_DIR"

# ── Install sitecustomize hook ──────────────────────────────────────
if [ ! -f "$SITECUSTOMIZE" ]; then
    cp "$SCRIPT_DIR/sitecustomize_hook.py" "$SITECUSTOMIZE"
elif grep -q "$MARKER" "$SITECUSTOMIZE"; then
    cp "$SCRIPT_DIR/sitecustomize_hook.py" "$SITECUSTOMIZE"
else
    BACKUP="$SITECUSTOMIZE.pre-hermes-claude-auth"
    cp "$SITECUSTOMIZE" "$BACKUP"
    printf "${YELLOW}[!] Backed up existing sitecustomize.py to %s${RESET}\n" "$BACKUP"
    cp "$SCRIPT_DIR/sitecustomize_hook.py" "$SITECUSTOMIZE"
fi

chmod 644 "$SITECUSTOMIZE"
printf "${GREEN}[✓] Installed hook into %s${RESET}\n" "$SITECUSTOMIZE"

# ── Verify patch ────────────────────────────────────────────────────
PATCH_CHECK=$("$VENV_PYTHON" -c "
import sys, os
sys.path.insert(0, os.path.expanduser('$PATCHES_DIR'))
try:
    import anthropic_billing_bypass
    v = getattr(anthropic_billing_bypass, '__version__', 'unknown')
    print(f'OK (v{v})')
except Exception as e:
    print(f'FAIL ({e})')
" 2>/dev/null || echo "FAIL (import error)")
printf "${GREEN}[✓] Patch integrity: %s${RESET}\n" "$PATCH_CHECK"

# ── macOS Keychain mirror ───────────────────────────────────────────
if [ "$(uname -s)" = "Darwin" ]; then
    CRED_FILE="$HOME/.claude/.credentials.json"
    if KEYCHAIN_CRED="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null)"; then
        mkdir -p "$(dirname "$CRED_FILE")"
        if [ ! -f "$CRED_FILE" ] || [ "$(cat "$CRED_FILE" 2>/dev/null)" != "$KEYCHAIN_CRED" ]; then
            printf '%s' "$KEYCHAIN_CRED" > "$CRED_FILE"
            chmod 600 "$CRED_FILE"
            printf "${GREEN}[✓] Mirrored Claude Code credentials from Keychain → %s${RESET}\n" "$CRED_FILE"
        else
            printf "${GREEN}[✓] Claude Code credentials file already matches Keychain${RESET}\n"
        fi
    elif [ ! -f "$CRED_FILE" ]; then
        printf "${YELLOW}[!] macOS detected but no 'Claude Code-credentials' Keychain entry found${RESET}\n"
        printf "    Run: claude auth login --claudeai\n"
    fi
fi

# ── Restart gateway ─────────────────────────────────────────────────
if systemctl --user is-active hermes-gateway.service >/dev/null 2>&1; then
    systemctl --user restart hermes-gateway.service
    printf "${GREEN}[✓] Restarted hermes-gateway.service${RESET}\n"
else
    printf "${YELLOW}[!] hermes-gateway not running — restart manually when ready${RESET}\n"
fi

echo ""
if $POST_UPDATE; then
    echo "Post-update recovery complete."
    echo "Verify: hermes chat --provider anthropic -m claude-sonnet-4-6 -q 'test'"
else
    printf "${GREEN}Installation complete.${RESET}\n"
    printf "  Patch:  %s/anthropic_billing_bypass.py\n" "$PATCHES_DIR"
    printf "  Hook:   %s\n" "$SITECUSTOMIZE"
    printf "  Venv:   %s\n" "$VENV_DIR"
fi
