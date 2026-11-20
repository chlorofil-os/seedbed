# Seedbed

**Raise LXD dev machines from a template: one per branch, task or client, in seconds.**

Seedbed keeps one stopped template per project, which already holds the repos, built images
and data. Every machine is a copy-on-write clone of that template's snapshot. On btrfs a clone
takes about 20 seconds and almost no disk. Seedbed also keeps the host in step: bridge DNS
answers `*.<name>.<tld>`, `~/.ssh/config` gets a `Host <name>` block (agent forwarded, so git
works inside), and an optional Chrome launcher gets `--host-rules`.

It is the companion of [seedpod](https://github.com/chlorofil-os/seedpod): seedbed **makes** the
machines, seedpod **shows** them and the Docker inside them, in VS Code and over MCP.

```
host
└── LXD bridge <SB_NET> <SB_SUBNET>.0/24, pool <SB_POOL>
    ├── <project>-base   .10      STOPPED template, snapshot "golden"
    ├── <name>           .11      clone -> <name>.<tld>, *.<name>.<tld>
    └── <name>           .N       ...
         └── Docker: the project's compose stack
```

## Use

```bash
seedbed projects                         # project files seedbed can see
seedbed chlorofil bootstrap              # build the template (idempotent; re-run after a failure)
seedbed chlorofil new mytask             # clone, pin an IP, run the project's after-clone hook
seedbed chlorofil new otp feature/otp    # same, on a branch
seedbed chlorofil list
seedbed chlorofil ssh mytask             # shell as ubuntu, agent forwarded
seedbed chlorofil ssh mytask 'docker ps'
seedbed chlorofil stop mytask / start mytask
seedbed chlorofil snapshot mytask before-import   # roll back: lxc restore mytask before-import
seedbed chlorofil rm mytask --yes
seedbed chlorofil refresh-base           # project hook (pull, migrate) in the template, re-take golden
seedbed chlorofil git-identity mytask
seedbed chlorofil dns                    # rewrite bridge DNS, print the one-time host step
seedbed chlorofil help                   # plus the project's own commands
```

Each new machine gets a `clean` snapshot right after its hook runs: `lxc restore <name> clean`.

Install: `ln -s "$PWD/seedbed" ~/.local/bin/seedbed`. Needs LXD (`lxd` group), `python3`, `ssh`
and an unlocked ssh agent.

## Projects

A project is a bash file, `<project>.sh`. Seedbed searches for it in `$SEEDBED_PROJECTS`
(colon-separated), then `~/.config/seedbed/projects/`, then `projects/` in this repo. Keep private
projects out of this repo: put them, or a symlink to them, in `~/.config/seedbed/projects/`.
Settings that don't belong in a project file, such as git identity and tokens, go in
`~/.config/seedbed/<project>.conf`, which is sourced after the project file.

| Shipped | What |
|---|---|
| `projects/chlorofil.sh` | The ChloroFilOS suite: `chlorofil` + `chlorofil-app` side by side, Vite dev servers behind an in-machine Caddy |
| `projects/example.sh` | A minimal template to copy |

### Settings

| Setting | Default | |
|---|---|---|
| `SB_SUBNET` | **required** | First three octets. The bridge is `.1/24`, the template `.SB_BASE_HOST` (10), clones `.SB_FIRST_HOST`-`.SB_LAST_HOST` (11-99) |
| `SB_NET` | `lxdbr0` | Bridge. Created if missing. Seedbed owns its `raw.dnsmasq`, so give each project its own bridge |
| `SB_TLD` | `lxc` | Machines answer as `<name>.<tld>` and `*.<name>.<tld>` |
| `SB_DNS_DOMAINS` | `~<tld>` | Routing domains in the host's resolved unit |
| `SB_LXD_PROJECT` | `<project>` | LXD project the machines live in. Created if missing, sharing profiles, images, networks and storage with `default`; `default` puts them in the default project |
| `SB_POOL`, `SB_POOL_DRIVER`, `SB_POOL_SIZE` | `<project>`, `btrfs`, `100GiB` | Storage pool. Created if missing; a loop file, sparse |
| `SB_BASE`, `SB_SNAP` | `<project>-base`, `golden` | Template and its snapshot |
| `SB_IP_KEY` | `user.<project>.ip` | Instance config key holding the pinned IP. Its presence marks a project machine |
| `SB_KEY`, `SB_KNOWN` | `~/.ssh/id_<project>-lxc`, `~/.ssh/known_hosts_<project>_lxc` | Key cloud-init authorises; separate known_hosts |
| `SB_SSH_MARKER` | `<project>-lxc` | Marker of the managed block in `~/.ssh/config` |
| `SB_IMAGE`, `SB_PACKAGES`, `SB_DOCKER` | `ubuntu:24.04`, git make curl ca-certificates jq unzip, `1` | Template OS. `SB_DOCKER=1` installs Docker and turns on nesting |
| `SB_LIMIT_CPU`, `SB_LIMIT_MEMORY` | empty | `limits.cpu` / `limits.memory` in both profiles, e.g. `4`, `8GiB` |
| `SB_SSH_HOSTS` | `github.com` | Hosts scanned into the template's `~/.ssh/known_hosts`, so git over ssh works in every clone |
| `SB_PROFILE_DEV`, `SB_PROFILE_CLONE` | `<project>-dev`, `<project>-clone` | LXD profiles (written by `bootstrap`) |
| `SB_LAUNCHER`, `SB_LAUNCHER_CREATE` | empty, `0` | `.desktop` file whose `--host-rules` seedbed maintains; create it if missing (own Chrome user-data-dir) |
| `SB_HOST_REPO`, `SB_GIT_NAME`, `SB_GIT_EMAIL` | empty | Git identity for machines: `SEEDBED_GIT_NAME`/`_EMAIL` env, then the settings, then the host repo's git config |

### Hooks

Define any of these in the project file. They run on the host, and `sb_ssh <machine> <cmd>`,
`sb_scp`, `log`, `warn` and `die` are available.

| Hook | When |
|---|---|
| `sb_bootstrap` | Template is up and Docker works: clone, build, seed |
| `sb_verify` | Before the template is snapshotted: `die` if it isn't usable |
| `sb_after_clone <name> <branch>` | New machine is up: point the stack at `<name>.<tld>`, start it |
| `sb_refresh` | `refresh-base`: pull, migrate |
| `sb_urls <name>` | URLs to print. The first one shows in `list` |
| `sb_ssh_extra <name> <ip>` | Extra `~/.ssh/config` blocks per machine |
| `sb_help` | Lines describing the project's own commands: functions named `pcmd_<cmd>` (`-` becomes `_`) |

## Reaching machines

- **DNS:** `seedbed <project> dns` writes `address=/<name>.<tld>/<ip>` for each machine into the
  bridge's dnsmasq. It then prints a one-time sudo step: a systemd unit that points
  `resolvectl` for `~<tld>` at the bridge.
- **Chrome without DNS:** set `SB_LAUNCHER`. `new` and `rm` keep `MAP *.<name>.<tld> <ip>` rules
  on its `Exec=` line, and rules for other TLDs are kept. Chrome applies the flags only when that
  profile isn't already open.
- **TLS:** clones share whatever CA the template's stack generated. Import it once.

## The chlorofil project

```bash
echo 'CHLOROFIL_NPM_TOKEN=ghp_...' >> ~/.config/seedbed/chlorofil.conf  # read:packages, for chlorofil-app
seedbed chlorofil bootstrap
seedbed chlorofil new mytask                        # framework main
seedbed chlorofil new f5 f5-solid,app:feature/x     # framework branch, app branch
seedbed chlorofil ca                                # save the shared Caddy root CA to import
```

| URL | What |
|---|---|
| `https://fw.<name>.cfl:9000/` | Framework Vite dev server (`chlorofil/`, compose `web`) |
| `https://app.<name>.cfl:9100/` | App Vite dev server (`chlorofil-app/`, compose `web`) |
| `https://prod.<name>.cfl:8443/` | App production image, after `docker compose up -d --build nginx proxy` |

Both Vite configs accept only `Host: web`. So a Caddy container (`~/workspace/.seedbed-front`,
host network) listens on the Vite ports, rewrites `Host`, and serves HTTPS from its local CA.
Because it listens on the same ports, HMR's websocket reaches it. The repos' compose stacks publish
only on loopback (`127.0.0.1:19000`, `:19100`, `:18443`) through gitignored
`docker-compose.override.yml` files. Without a token the template holds `chlorofil-app` as source
only; `seedbed chlorofil token <name>` installs and starts it later.

## Gotchas

- **`lxc profile create` reads stdin.** Seedbed passes `</dev/null`. Do the same in hooks that call `lxc`.
- **Machines are independent copies.** `refresh-base` only affects machines made afterwards.
- **IPs are recorded in `SB_IP_KEY`.** Don't change them by hand.
- **Keep the bridge host-only.** Clones share the template's secrets (database passwords, tokens
  in `.env`), so don't expose it to the LAN.

## Licence

MIT
