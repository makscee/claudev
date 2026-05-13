# claudev

Thin shell wrapper that authenticates against [void-auth](https://github.com/makscee/void-auth), fetches a sticky-served Anthropic OAuth pool token from [void-keys](https://github.com/makscee/void-keys), and exec's `claude` with `CLAUDE_CODE_OAUTH_TOKEN` set so Claude Code never prompts for login.

## Install (macOS / Linux)

```sh
eval "$(curl -fsSL https://auth.makscee.ru/claudev/install.sh | sh)"
```

The `eval` form activates `~/.local/bin` on `PATH` in the current shell on first install, so you can run `claudev` immediately. The plain `curl … | sh` form also works but won't put `claudev` on `PATH` until you open a new shell.

Then run `claudev` to log in (you'll need an admin-issued access code) and launch Claude Code.

## Windows (Git Bash)

claudev runs natively under [Git Bash](https://gitforwindows.org/) (no WSL required). Open a Git Bash window and run the same one-liner:

```sh
eval "$(curl -fsSL https://auth.makscee.ru/claudev/install.sh | sh)"
```

Or clone and run the installer locally:

```sh
git clone https://github.com/makscee/claudev.git
cd claudev
bash install.sh        # or: ./install.sh
```

Restart Git Bash after install so the updated `PATH` takes effect. The installer writes to `~/.bash_profile` (creating it if needed) and ensures it sources `~/.bashrc`, so both files participate.

### NTFS / chmod note

`chmod +x` is a no-op on NTFS — Git Bash treats files as executable based on extension and shebang. The installer is invoked as `bash install.sh` or `./install.sh`, and the wrapper is callable as either `claudev` or `claudev.sh` from the shell.

### Troubleshooting

- `claudev: command not found` — check `echo $PATH` includes `$HOME/.local/bin`. If not, verify `~/.bash_profile` exists and contains the `export PATH=...` line, and that it sources `~/.bashrc` (the installer does this automatically).
- Restart Git Bash after install — open shells don't pick up `PATH` changes from rc files.

## Configuration

Hosts are overridable via env vars (defaults shown):

| Var | Default |
|---|---|
| `CLAUDEV_AUTH_HOST` | `https://auth.makscee.ru` |
| `CLAUDEV_KEYS_HOST` | `https://keys.makscee.ru` |

State files in `~/.claudev/`: `token` (mode 0600), `config` (locale + last update check).

### Environment variables

- `CLAUDEV_OFFLINE=1` — skip self-update, locale fetch, token refresh, key
  fetch, and proxy spawn; `exec` the `claude` on `PATH` directly with the
  caller's argv. Used by tests; do not set in production.

## Subcommands

- `claudev`            — launch claude (logs in if needed)
- `claudev login`      — re-login with a fresh access code
- `claudev logout`     — wipe local session
- `claudev update`     — force update check (skip 24h cache)
- `claudev --help`     — usage

Anything else passes through to `claude` verbatim. So `claudev --print "hi"` runs `claude --print "hi"`.

### Forwarded flags

Any flag claudev does not consume is passed through to the underlying `claude`
binary unchanged. In particular:

- `--mcp-config <path>` — load MCP server definitions from `<path>`. Required
  to talk to a local void-os daemon MCP server.

## Status

v1 — POSIX-sh, mac/linux + Windows (Git Bash). WSL also works.

## Spec + plan

- [Spec](https://github.com/makscee/hub/blob/master/docs/superpowers/specs/2026-04-30-claudev-v1-design.md)
- [Plan](https://github.com/makscee/hub/blob/master/docs/superpowers/plans/2026-04-30-claudev-v1-plan.md)
