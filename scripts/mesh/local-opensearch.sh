#!/usr/bin/env bash
# A local single-node OpenSearch for test_search_local.py and template work.
#
#   scripts/mesh/local-opensearch.sh install   # download + sha512-verify + unpack (once)
#   scripts/mesh/local-opensearch.sh start     # background on 127.0.0.1:9200, waits for green
#   scripts/mesh/local-opensearch.sh stop | status | logs
#
# Lives in .local/ (gitignored): the install in .local/opensearch-<version>, its
# data in .local/opensearch-data, so `install` can be re-run without losing an index.
# Security is off and it binds to loopback only: never point it at real data.
set -euo pipefail

VERSION="${OPENSEARCH_VERSION:-2.16.0}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCAL="$ROOT/.local"
HOME_DIR="$LOCAL/opensearch-$VERSION"
DATA="$LOCAL/opensearch-data"
PIDFILE="$LOCAL/opensearch.pid"
LOG="$LOCAL/opensearch.log"
URL="http://127.0.0.1:9200"
TARBALL="opensearch-$VERSION-linux-x64.tar.gz"
BASE="https://artifacts.opensearch.org/releases/bundle/opensearch/$VERSION"

running() { [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

configure() {
  # Replaces the bundle's (all-comment) opensearch.yml with the local settings.
  cat > "$HOME_DIR/config/opensearch.yml" <<YML
# Written by scripts/mesh/local-opensearch.sh
cluster.name: arbory-local
node.name: local
discovery.type: single-node
network.host: 127.0.0.1
http.port: 9200
path.data: $DATA
path.logs: $HOME_DIR/logs
plugins.security.disabled: true
YML
}

install() {
  if [[ -x "$HOME_DIR/bin/opensearch" ]]; then
    echo "already installed: $HOME_DIR"
  else
    mkdir -p "$LOCAL"
    local tmp; tmp="$(mktemp -d "$LOCAL/download.XXXXXX")"
    trap 'rm -rf "$tmp"' EXIT
    echo "downloading $TARBALL (~900 MB) from artifacts.opensearch.org"
    curl -fsSL -o "$tmp/$TARBALL.sha512" "$BASE/$TARBALL.sha512"
    curl -fL --progress-bar -o "$tmp/$TARBALL" "$BASE/$TARBALL"
    (cd "$tmp" && sha512sum -c "$TARBALL.sha512")
    tar xzf "$tmp/$TARBALL" -C "$LOCAL"
  fi
  mkdir -p "$DATA"
  configure
}

start() {
  if running; then echo "already running (pid $(cat "$PIDFILE"))"; return; fi
  [[ -x "$HOME_DIR/bin/opensearch" ]] || install
  configure
  mkdir -p "$DATA"
  # 1 GB heap is plenty for a few thousand pages.
  OPENSEARCH_JAVA_OPTS="${OPENSEARCH_JAVA_OPTS:--Xms1g -Xmx1g}" \
    nohup "$HOME_DIR/bin/opensearch" > "$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  echo -n "starting (pid $!)"
  for _ in $(seq 1 90); do
    if curl -fs "$URL/_cluster/health?wait_for_status=yellow&timeout=1s" >/dev/null 2>&1; then
      echo; curl -s "$URL/_cluster/health" ; echo; return
    fi
    running || { echo; echo "exited; see $LOG"; tail -20 "$LOG"; exit 1; }
    echo -n .; sleep 2
  done
  echo; echo "not healthy after 3 minutes; see $LOG"; exit 1
}

stop() {
  if running; then kill "$(cat "$PIDFILE")"; echo "stopped"; else echo "not running"; fi
  rm -f "$PIDFILE"
}

status() {
  if running; then echo "running (pid $(cat "$PIDFILE"))"; curl -s "$URL/_cluster/health"; echo
  else echo "not running"; fi
}

case "${1:-status}" in
  install) install ;;
  start) start ;;
  stop) stop ;;
  status) status ;;
  logs) tail -n "${2:-50}" "$LOG" ;;
  *) echo "usage: $0 install|start|stop|status|logs [n]" >&2; exit 2 ;;
esac
