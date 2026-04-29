# claudev

Thin shell wrapper that authenticates against [void-auth](https://github.com/makscee/void-auth), fetches a sticky-served Anthropic OAuth pool token from [void-keys](https://github.com/makscee/void-keys), and exec's `claude` with `CLAUDE_CODE_OAUTH_TOKEN` set so Claude Code never prompts for login.

## Install (macOS / Linux)

```sh
curl -fsSL https://auth.makscee.ru/claudev/install.sh | sh
```

Then run `claudev` to log in (you'll need an admin-issued access code) and launch Claude Code.

## Configuration

Hosts are overridable via env vars (defaults shown):

| Var | Default |
|---|---|
| `CLAUDEV_AUTH_HOST` | `https://auth.makscee.ru` |
| `CLAUDEV_KEYS_HOST` | `https://keys.makscee.ru` |

State files in `~/.claudev/`: `token` (mode 0600), `config` (locale + last update check).

## Subcommands

- `claudev`            — launch claude (logs in if needed)
- `claudev login`      — re-login with a fresh access code
- `claudev logout`     — wipe local session
- `claudev update`     — force update check (skip 24h cache)
- `claudev --help`     — usage

Anything else passes through to `claude` verbatim. So `claudev --print "hi"` runs `claude --print "hi"`.

## Status

v1 — POSIX-sh, mac/linux only. Windows is v2 (use WSL for now).

## Spec + plan

- [Spec](https://github.com/makscee/hub/blob/master/docs/superpowers/specs/2026-04-30-claudev-v1-design.md)
- [Plan](https://github.com/makscee/hub/blob/master/docs/superpowers/plans/2026-04-30-claudev-v1-plan.md)
