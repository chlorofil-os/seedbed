# seedbed project: the ChloroFilOS suite (chlorofil-os/chlorofil + chlorofil-os/chlorofil-app).
# shellcheck disable=SC2034

SB_BASE=chlorofil-base
SB_POOL=chlorofil
SB_POOL_SIZE=80GiB
SB_NET=cflbr0
SB_SUBNET=10.226.10
SB_TLD=cfl
SB_LIMIT_CPU=4
SB_LIMIT_MEMORY=8GiB
SB_PACKAGES="git make curl ca-certificates jq unzip"
SB_LAUNCHER=$HOME/Desktop/chlorofil.cfl.desktop
SB_LAUNCHER_CREATE=1
SB_LAUNCHER_TITLE="ChloroFilOS dev machines"
SB_HOST_REPO=$HOME/workspace/chlorofil-os/chlorofil

CFL_FW_REPO=${CFL_FW_REPO:-git@github.com:chlorofil-os/chlorofil.git}
CFL_APP_REPO=${CFL_APP_REPO:-git@github.com:chlorofil-os/chlorofil-app.git}
CFL_W=/home/ubuntu/workspace
CFL_FW=$CFL_W/chlorofil
CFL_APP=$CFL_W/chlorofil-app
CFL_FRONT=$CFL_W/.seedbed-front
CFL_CADDY_IMAGE=caddy:2.10-alpine@sha256:4c6e91c6ed0e2fa03efd5b44747b625fec79bc9cd06ac5235a779726618e530d

cfl_token() { echo "${CHLOROFIL_NPM_TOKEN:-${NODE_AUTH_TOKEN:-}}"; }

# Writes each repo's .env and docker-compose.override.yml.
cfl_write_local() {
    local name=$1
    sb_ssh "$name" "cat > $CFL_FW/.env" <<'EOF'
UID=1000
GID=1000
EOF
    sb_ssh "$name" "cat > $CFL_FW/docker-compose.override.yml" <<'EOF'
# Written by seedbed.
services:
  web:
    ports:
      - "127.0.0.1:19000:9000"
EOF
    { printf 'UID=1000\nGID=1000\n'; local t; t=$(cfl_token); if [ -n "$t" ]; then printf 'NODE_AUTH_TOKEN=%s\n' "$t"; fi; } \
        | sb_ssh "$name" "umask 077; cat > $CFL_APP/.env"
    sb_ssh "$name" "cat > $CFL_APP/docker-compose.override.yml" <<'EOF'
# Written by seedbed.
services:
  web:
    ports:
      - "127.0.0.1:19100:9100"
  proxy:
    ports:
      - "127.0.0.1:18443:443"
EOF
}

cfl_write_front() {
    local name=$1
    sb_ssh "$name" "mkdir -p $CFL_FRONT && cat > $CFL_FRONT/Caddyfile" <<'EOF'
# Written by seedbed.
{
	local_certs
	skip_install_trust
	auto_https disable_redirects
}

https://fw.{$DEV_DOMAIN}:9000 {
	reverse_proxy 127.0.0.1:19000 {
		header_up Host web
	}
}

https://app.{$DEV_DOMAIN}:9100 {
	reverse_proxy 127.0.0.1:19100 {
		header_up Host web
	}
}

https://prod.{$DEV_DOMAIN}:8443 {
	reverse_proxy https://127.0.0.1:18443 {
		header_up Host localhost
		transport http {
			tls_insecure_skip_verify
			tls_server_name localhost
		}
	}
}

:80 {
	respond "{$DEV_DOMAIN}: https://fw.{$DEV_DOMAIN}:9000/  https://app.{$DEV_DOMAIN}:9100/  https://prod.{$DEV_DOMAIN}:8443/
"
}
EOF
    sb_ssh "$name" "cat > $CFL_FRONT/compose.yml" <<EOF
# Written by seedbed.
name: seedbed-front
services:
  caddy:
    image: $CFL_CADDY_IMAGE
    container_name: seedbed-front
    network_mode: host
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - data:/data
      - config:/config
volumes:
  data:
  config:
EOF
    sb_ssh "$name" "echo DEV_DOMAIN=$name.$SB_TLD > $CFL_FRONT/.env && cd $CFL_FRONT && docker compose up -d --force-recreate 2>&1 | tail -1"
}

# True when chlorofil-app can start: a token, or node_modules already installed.
cfl_app_ready() {
    local name=$1
    [ -n "$(cfl_token)" ] && return 0
    sb_ssh "$name" "docker volume inspect chlorofil-app_chlorofil-app-node_modules >/dev/null 2>&1 && docker run --rm -v chlorofil-app_chlorofil-app-node_modules:/m alpine test -d /m/@chlorofil-os" 2>/dev/null
}

cfl_up() {
    local name=$1
    sb_ssh "$name" "cd $CFL_FW && docker compose up -d web 2>&1 | tail -1"
    if cfl_app_ready "$name"; then
        sb_ssh "$name" "cd $CFL_APP && docker compose up -d web 2>&1 | tail -1"
    else
        echo "  chlorofil-app not started: no read:packages token (seedbed chlorofil token $name)"
    fi
}

# Waits for https://<host>.<name>.cfl:<port>/ to return 200.
cfl_wait() {
    local name=$1 host=$2 port=$3 code
    for _ in $(seq 1 90); do
        code=$(sb_ssh "$name" "curl -sk -o /dev/null -w '%{http_code}' --resolve $host.$name.$SB_TLD:$port:127.0.0.1 https://$host.$name.$SB_TLD:$port/" || true)
        [ "$code" = 200 ] && { echo "  $host.$name.$SB_TLD:$port -> 200"; return 0; }
        sleep 4
    done
    echo "  $host.$name.$SB_TLD:$port -> ${code:-no answer} after 6 min" >&2
    return 1
}

sb_bootstrap() {
    local b=$SB_BASE
    log "cloning the suite into $CFL_W"
    sb_ssh "$b" "mkdir -p $CFL_W/chlorofil-worktrees && touch $CFL_W/chlorofil-worktrees/.heavy.lock
        test -d $CFL_FW/.git || git clone -q $CFL_FW_REPO $CFL_FW
        test -d $CFL_APP/.git || git clone -q $CFL_APP_REPO $CFL_APP
        cd $CFL_FW && git log --oneline -1 && cd $CFL_APP && git log --oneline -1"
    cfl_write_local "$b"
    log "front proxy"
    cfl_write_front "$b"
    log "framework: images, node_modules (web + e2e)"
    sb_ssh "$b" "cd $CFL_FW && docker compose build -q web && docker compose --profile e2e build -q e2e \
        && docker compose up -d web 2>&1 | tail -1 \
        && docker compose run --rm --no-deps e2e npm ci --no-audit --no-fund 2>&1 | tail -1"
    if [ -n "$(cfl_token)" ]; then
        log "app: images, node_modules (web + e2e)"
        sb_ssh "$b" "cd $CFL_APP && docker compose build -q web && docker compose --profile e2e build -q e2e \
            && docker compose up -d web 2>&1 | tail -1 \
            && docker compose run --rm --no-deps e2e npm ci --no-audit --no-fund 2>&1 | tail -1"
    else
        warn "no CHLOROFIL_NPM_TOKEN (read:packages): template holds chlorofil-app source only"
    fi
}

sb_verify() {
    cfl_wait "$SB_BASE" fw 9000 || die "framework dev server not answering"
    if [ -n "$(cfl_token)" ]; then cfl_wait "$SB_BASE" app 9100 || die "app dev server not answering"; fi
}

# $2: "<framework branch>", "app:<app branch>", or both comma-separated.
sb_after_clone() {
    local name=$1 spec=${2:-} part
    cfl_write_local "$name"
    IFS=, read -ra parts <<<"$spec"
    for part in "${parts[@]}"; do
        [ -n "$part" ] || continue
        local dir=$CFL_FW br=$part
        [[ $part == app:* ]] && { dir=$CFL_APP; br=${part#app:}; }
        log "checking out $br in $(basename "$dir")"
        sb_ssh "$name" "cd $dir && git fetch -q origin && git checkout -q -B '$br' 'origin/$br' && git log --oneline -1"
    done
    log "front proxy as $name.$SB_TLD"
    cfl_write_front "$name"
    cfl_up "$name"
    cfl_wait "$name" fw 9000 || true
}

sb_refresh() {
    local b=$SB_BASE
    cfl_write_local "$b"
    sb_ssh "$b" "cd $CFL_FW && git checkout -q main && git pull -q --ff-only && git log --oneline -1
        cd $CFL_APP && git checkout -q main && git pull -q --ff-only && git log --oneline -1"
    cfl_write_front "$b"
    cfl_up "$b"
    cfl_wait "$b" fw 9000 || die "framework dev server not answering"
}

sb_urls() {
    local d=$1.$SB_TLD
    echo "https://fw.$d:9000/"
    echo "https://app.$d:9100/"
    echo "https://prod.$d:8443/   (after: cd ~/workspace/chlorofil-app && docker compose up -d --build nginx proxy)"
}

sb_help() {
    cat <<'EOF'
token <name>   write the read:packages token (CHLOROFIL_NPM_TOKEN) into chlorofil-app/.env and start the app
ca [file]      save the machines' shared Caddy root CA (default ~/Desktop/chlorofil-cfl-root.crt)
up <name>      (re)write the front proxy and start both dev servers
new <name> [fw-branch][,app:<app-branch>]
EOF
}

pcmd_token() {
    local name=${1:?usage: token <name>}
    [ -n "$(cfl_token)" ] || die "set CHLOROFIL_NPM_TOKEN (env or ~/.config/seedbed/chlorofil.conf)"
    cfl_write_local "$name"
    sb_ssh "$name" "cd $CFL_APP && docker compose build -q web && docker compose up -d web 2>&1 | tail -1"
    cfl_wait "$name" app 9100
}

pcmd_ca() {
    local out=${1:-$HOME/Desktop/chlorofil-cfl-root.crt} src=$SB_BASE
    local n s
    while IFS=$'\t' read -r n s _; do [ "$s" = Running ] && { src=$n; break; }; done < <(machines)
    sb_ssh "$src" "docker exec seedbed-front cat /data/caddy/pki/authorities/local/root.crt" > "$out"
    openssl x509 -in "$out" -noout -subject -fingerprint -sha256 2>/dev/null | sed 's/^/  /'
    echo "saved $out: import it in Chrome under Settings > Privacy and security > Security > Manage certificates > Authorities"
}

pcmd_up() {
    local name=${1:?usage: up <name>}
    cfl_write_local "$name"
    cfl_write_front "$name"
    cfl_up "$name"
}
