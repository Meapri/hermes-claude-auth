# hermes-claude-auth
Claude Code OAuth bypass for hermes-agent, use your Claude Code subscription (Max/Pro) with Hermes.

## What this does
Patches hermes-agent at runtime to pass Anthropic's server-side OAuth content validation. It does not modify hermes-agent source files. Installation happens through a Python import hook that monkey-patches `build_anthropic_kwargs` on startup.

## Why this exists
On 2026-04-04, Anthropic added server-side validation that rejects OAuth requests from third-party tools. This patch adds the billing header signature and system prompt structure the API expects.

## Prerequisites
- hermes-agent installed (`~/.hermes/hermes-agent/`)
- Claude Code CLI authenticated (valid credentials at `~/.claude/.credentials.json`)
- hermes-agent configured for OAuth (`credential_pool` has a `claude_code` entry in `~/.hermes/auth.json`)
- Python 3.11+

## Install
```bash
# Remote install (one-liner)
curl -fsSL https://raw.githubusercontent.com/Meapri/hermes-claude-auth/main/install-remote.sh | bash

# Or clone manually
git clone https://github.com/Meapri/hermes-claude-auth.git
cd hermes-claude-auth
./install.sh
```

What `install.sh` does:
- Copies `anthropic_billing_bypass.py` to `~/.hermes/patches/`
- Installs the import hook as `sitecustomize.py` in the hermes venv's site-packages
- Restarts `hermes-gateway.service` if running

### Windows

The desktop build keeps its Hermes home at `%LOCALAPPDATA%\hermes` (not
`~/.hermes`) and its venv python at `venv\Scripts\python.exe`, so `install.sh`
does not apply. Use the PowerShell installer instead:

```powershell
git clone https://github.com/Meapri/hermes-claude-auth.git
cd hermes-claude-auth
powershell -ExecutionPolicy Bypass -File .\install.ps1
# verify:  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Check
```

It copies the patch to `%LOCALAPPDATA%\hermes\patches\` (outside the venv, so it
survives `hermes update`) and installs the platform-aware `sitecustomize.py`
into the venv's `Lib\site-packages\`. The hook auto-discovers the Windows
patches directory. After a `hermes update` that rebuilds the venv, re-run
`install.ps1` to restore `sitecustomize.py`.

## Agent Handoff Prompt

Use this prompt when another Hermes instance needs to install, repair, or audit
Claude auth without losing the Antigravity provider:

```text
You are setting up hermes-claude-auth on this machine.

Work from the persistent clone at ~/hermes-claude-auth. If it exists and is
clean, run `git pull`; if it has local changes, do not overwrite them and
report that pull was skipped. If it does not exist, run:
`git clone https://github.com/Meapri/hermes-claude-auth.git ~/hermes-claude-auth`

Then run:
`cd ~/hermes-claude-auth && ./install.sh`

After install, verify and report:
- `./install.sh --check` passes.
- `~/.hermes/patches/anthropic_billing_bypass.py` matches this repo.
- The Hermes venv `sitecustomize.py` contains `# hermes-claude-auth managed`.
- If `# hermes-antigravity managed` is also present, confirm the shared hook
  still contains Antigravity hooks for `hermes_cli.auth`,
  `hermes_cli.providers`, `hermes_cli.commands`, `cli`,
  `agent.auxiliary_client`, `hermes_cli.runtime_provider`,
  `hermes_cli.main`, `hermes_cli.model_switch`, and `api.config`.
- Importing `agent.error_classifier` in the Hermes venv does not print a
  `ModuleNotFoundError` traceback for `anthropic_billing_bypass`.
- `~/.hermes/hermes-agent/.git/hooks/post-merge` exists and is executable.

If Claude credentials are available, smoke-test:
`hermes chat --provider anthropic -m claude-sonnet-4-6 -q "OK" -Q`

If Antigravity is also installed and credentials are available, smoke-test:
`hermes chat --provider google-antigravity -m gemini-3.5-flash-high -q "OK" -Q`

If any smoke test cannot be run, say exactly what blocked it. Finish with the
current git commit, whether automatic repair is installed, and the check/smoke
results.
```

## Uninstall
```bash
./uninstall.sh          # remove hook only
./uninstall.sh --purge  # remove hook + patch file
```

## How it works
1. **Billing header**: SHA-256 signed `x-anthropic-billing-header` injected as `system[0]`
2. **System prompt relocation**: Non-identity system entries moved to the first user message as `<system-reminder>` blocks
3. **Beta flags**: Adds `prompt-caching-scope-2026-01-05` and `advisor-tool-2026-03-01`
4. **Stainless SDK spoof**: Lowercase `x-stainless-*` headers + `anthropic-dangerous-direct-browser-access` + `?beta=true` query param matching real Claude Code 2.1.112
5. **Tool name namespacing**: Hermes's `mcp_bash` is rewritten to `mcp__hermes__Bash` outbound; the response normalizer unwraps it back to `bash` so hermes's tool dispatcher resolves the registered name without auto-repair noise
6. **Tool pair repair**: Orphaned `tool_use` / `tool_result` blocks (left by long conversations or partial summaries) are stripped before signing — prevents HTTP 400 (upstream PR #136)
7. **Haiku effort stripping**: `effort` parameter is removed for haiku models that reject it with HTTP 400 (upstream PR #126)
8. **Temperature fix**: Strips non-default `temperature` on Opus 4.6 adaptive thinking, which otherwise rejects with HTTP 400
9. **Account metadata**: Maps `~/.claude.json::oauthAccount.accountUuid` to `metadata.user_id` (Anthropic rejected the older `account_uuid` key with HTTP 400 on 2026-04-29)

Installed through a `sitecustomize.py` MetaPathFinder hook, so it runs at interpreter startup with no source modifications.

## What gets modified
| File | Action |
|------|--------|
| `~/.hermes/patches/anthropic_billing_bypass.py` | Created |
| `<venv>/lib/pythonX.Y/site-packages/sitecustomize.py` | Created or shared with Antigravity |
| `~/.hermes/hermes-agent/.git/hooks/post-merge` | Created (auto-recovery after `hermes update`) |
| hermes-agent source files | NOT modified |

## After Hermes Update

When you run `hermes update` (which does `git pull` + `pip install`), the
`sitecustomize.py` inside the venv may be overwritten. The patch file survives.

**Automatic recovery (default).** `install.sh` installs a git `post-merge` hook
into `~/.hermes/hermes-agent/.git/hooks/`, so the moment `hermes update` runs its
`git pull`, the hook detects the missing hook and re-runs recovery automatically.
If the Google Antigravity plugin is also installed, its coexistence
`sitecustomize.py` (which already contains the Claude hook) is restored first and
this installer leaves it untouched — the two patches never clobber each other.

> **Keep the clone in a persistent path** (e.g. `~/hermes-claude-auth`), **not
> `/tmp`**. The post-merge hook looks for the installer at
> `$HOME/hermes-claude-auth/install.sh` first; a `/tmp` clone is wiped on reboot
> and auto-recovery silently can't run.

**Check what's broken** (verifies files exist AND match the repo byte-for-byte):
```bash
cd ~/hermes-claude-auth
./install.sh --check
```
`--check` flags **content drift** too — if the installed
`anthropic_billing_bypass.py` differs from the repo (e.g. a hot-fix was applied
to one but not synced to the other), it reports `[!] DRIFT` so you can sync the
newer copy back before a clean install silently reverts it. The shared
`sitecustomize.py` is intentionally not compared (it legitimately differs when
the Antigravity plugin's multi-hook version is installed).

**Recover (only restores sitecustomize.py + patch):**
```bash
cd ~/hermes-claude-auth
git pull && ./install.sh --post-update
```

**Full recovery:**
```bash
cd ~/hermes-claude-auth
git pull && ./install.sh
```

### What survives `hermes update`

| File | Location | Survives? |
|------|----------|:---:|
| `anthropic_billing_bypass.py` | `~/.hermes/patches/` | ✅ Outside repo |
| **`sitecustomize.py`** | venv `site-packages/` | ❌ Overwritten |
| Claude credentials | `~/.claude/` | ✅ Managed by Claude CLI |
| Auth token | `~/.hermes/auth.json` | ✅ Outside repo |

Only `sitecustomize.py` needs recovery. `--post-update` does exactly that.

## Compatibility
- Tested with hermes-agent on Python 3.11+
- Linux and macOS
- Depends on `build_anthropic_kwargs(is_oauth=...)` in `agent.anthropic_adapter`, so it may need updating if hermes-agent changes that interface

### Coexisting with the Google Antigravity plugin

If [hermes-google-antigravity-plugin](https://github.com/Meapri/hermes-google-antigravity-plugin)
is also installed, both share a single `sitecustomize.py` that carries **all 11
import hooks** (2 Claude + 9 Antigravity). Two cautions:

- **⚠ Don't run an old/`fix`-branch `install.sh` that lacks `--check` raw.** A
  Claude-only installer can overwrite the shared `sitecustomize.py` and silently
  drop the 9 Antigravity hooks, causing `Unknown provider: google-antigravity`.
  The current installer here is coexistence-aware (it restores the shared
  multi-hook file first and leaves it untouched), but if you ever clobber it,
  recover by re-running the Antigravity plugin's `./scripts/repair.sh --skip-pull`.
- The 2 Claude hooks are `agent.error_classifier` and
  `agent.anthropic_adapter`. The shared Antigravity hook must no-op silently if
  `anthropic_billing_bypass.py` is absent, and the Claude-only hook has the same
  guard for clean reinstall/uninstall cycles.
- **Verify with a real E2E call, not a bare import.** A direct
  `python -c "import ..."` can pass while `hermes chat` still fails on
  import-order grounds. Smoke-test each provider with an actual chat call:
  ```bash
  hermes chat --provider anthropic        -m claude-sonnet-4-6      -q "OK" -Q
  hermes chat --provider google-antigravity -m gemini-3.5-flash-high -q "OK" -Q
  ```

## Troubleshooting

### Install issues
- **"hermes-agent not found"**: Make sure Hermes is installed at `~/.hermes/hermes-agent/`
- **"No virtualenv found"**: Set `HERMES_VENV` to point to your venv
- **Patch not loading**: Check `journalctl --user -u hermes-gateway -n 50` for `[anthropic_billing_bypass]` or `[hermes-claude-auth]` messages
- **`ModuleNotFoundError: anthropic_billing_bypass` during `hermes model`**:
  run `cd ~/hermes-claude-auth && git pull && ./install.sh`, then verify
  `./install.sh --check`. Current hooks treat the Claude bypass as optional
  during shared-hook startup and should not print this traceback.

### Auth issues

- **`Anthropic 401 authentication failed`** or **`No Anthropic credentials found`**: Hermes reads Claude subscription credentials from `~/.claude/.credentials.json`. If Claude Code is authenticated (e.g. in macOS Keychain) but that file is missing or stale, Hermes fails even when Claude Code itself works.

  On macOS, `install.sh` v1.1.1+ auto-mirrors the `Claude Code-credentials` Keychain entry into `~/.claude/.credentials.json` on every run, so re-running the installer is usually enough. Full fix:

  1. Refresh Claude subscription login:
     ```bash
     claude auth login --claudeai
     ```
  2. Re-run the installer to re-mirror credentials (macOS) and reload the patch:
     ```bash
     ./install.sh
     ```
  3. Remove stale `ANTHROPIC_TOKEN` / `ANTHROPIC_API_KEY` values from `~/.hermes/.env` — they can override subscription auth.
  4. Reset cached credentials:
     ```bash
     hermes auth reset anthropic
     ```
  5. Retry with a smoke test:
     ```bash
     hermes chat -q 'Reply with exactly: AUTH TEST OK' --provider anthropic -m claude-sonnet-4-6 -Q
     ```

  If the auto-mirror doesn't work (e.g. your Keychain entry is under a different service name), mirror it manually:
  ```bash
  python3 - <<'PY'
  import subprocess
  from pathlib import Path

  secret = subprocess.check_output(
      ['security', 'find-generic-password', '-s', 'Claude Code-credentials', '-w'],
      text=True,
  ).strip()

  cred_path = Path.home() / '.claude' / '.credentials.json'
  cred_path.parent.mkdir(parents=True, exist_ok=True)
  cred_path.write_text(secret)
  cred_path.chmod(0o600)
  print(f'wrote {cred_path}')
  PY
  ```

  Credit: the macOS Keychain mirror approach was written up by [@DrQbz](https://github.com/DrQbz) in [issue #5](https://github.com/kristianvast/hermes-claude-auth/issues/5) and is now automated in `install.sh`.

- **Gateway fails with `No inference provider configured` / `Provider authentication failed`, but the CLI works fine**: This is a provider auto-resolution problem, *not* a credential problem. The gateway resolves the provider as `auto`, and `auto` only auto-selects an OAuth provider (like Anthropic via `claude_code`) when `~/.hermes/auth.json` has `active_provider` set. The CLI passes `model.provider` from `config.yaml` explicitly, so it bypasses `auto` and keeps working — which is why only the gateway (Telegram/Discord/etc.) breaks.

  This happens when your credentials live in `auth.json`'s `credential_pool` but `active_provider` is `null`. Since Anthropic uses OAuth (no `ANTHROPIC_API_KEY` env var), `auto` finds no env key to fall back on and raises `No inference provider configured`.

  **Fix** — point `active_provider` at your configured provider, then restart the gateway:
  ```bash
  python3 - <<'PY'
  import json, pathlib
  p = pathlib.Path.home() / '.hermes' / 'auth.json'
  d = json.loads(p.read_text())
  d['active_provider'] = 'anthropic'   # match model.provider in config.yaml
  p.write_text(json.dumps(d, indent=2))
  print('set active_provider=anthropic')
  PY

  sudo "$(command -v hermes)" gateway restart --system   # or: hermes gateway restart
  ```

  > Note: during a `sudo ... gateway restart`, you may see `ModuleNotFoundError: No module named 'antigravity_provider_patch'` printed once. That comes from the sudo wrapper process (its `HOME` is `/root`), not the actual gateway — the systemd unit pins `HOME=/home/<user>`, so the running gateway loads the patches correctly. It is harmless.

  Verify the fix in the gateway's environment:
  ```bash
  cd ~/.hermes && hermes auth list   # should show anthropic with the ← active marker
  ```

### Billing / routing issues

- **HTTP 400: "Third-party apps now draw from your extra usage, not your plan limits"**: Anthropic's server-side validation has classified your requests as third-party and routed them to pay-per-token credits instead of your Max/Pro plan. Make sure you're on the latest version of this patch (it tracks the upstream [opencode-claude-auth](https://github.com/griffinmartin/opencode-claude-auth) fingerprint changes). Reinstall with `./install.sh` and restart `hermes-gateway`. If the error persists after update, the bypass is currently broken upstream too — track [issue #6](https://github.com/kristianvast/hermes-claude-auth/issues/6) for status.
- **HTTP 400 persists after update**: The billing salt or signature format may have been rotated by Anthropic again. Check for newer commits to this repo.

## Credits
- [griffinmartin/opencode-claude-auth](https://github.com/griffinmartin/opencode-claude-auth), the original TypeScript implementation for opencode (MIT)
- [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent), the AI agent this patches (MIT)

## Disclaimer
This uses Claude Code subscription credentials outside the official Claude Code CLI. It works with Anthropic's current OAuth implementation but may break if Anthropic changes their validation. Use at your own risk.

## License
MIT, see [LICENSE](LICENSE).
