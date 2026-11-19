# seedbed project template: copy to ~/.config/seedbed/projects/<project>.sh and edit.
# shellcheck disable=SC2034

SB_SUBNET=10.226.20
SB_NET=examplebr0
SB_TLD=example
SB_POOL_SIZE=40GiB

EX_REPO=git@github.com:you/app.git
EX_DIR=/home/ubuntu/workspace/app

sb_bootstrap() {
    sb_ssh "$SB_BASE" "mkdir -p ~/workspace && { test -d $EX_DIR/.git || git clone -q $EX_REPO $EX_DIR; }"
    sb_ssh "$SB_BASE" "cd $EX_DIR && docker compose up -d --build 2>&1 | tail -2"
}

sb_verify() {
    sb_ssh "$SB_BASE" "curl -fsS -o /dev/null http://127.0.0.1/" || die "app not answering in $SB_BASE"
}

sb_after_clone() {
    local name=$1 branch=${2:-}
    [ -n "$branch" ] && sb_ssh "$name" "cd $EX_DIR && git fetch -q origin && git checkout -q -B '$branch' 'origin/$branch'"
    sb_ssh "$name" "cd $EX_DIR && docker compose up -d 2>&1 | tail -1"
}

sb_refresh() {
    sb_ssh "$SB_BASE" "cd $EX_DIR && git pull -q --ff-only && docker compose up -d --build 2>&1 | tail -1"
}

sb_urls() { echo "http://$1.$SB_TLD/"; }
