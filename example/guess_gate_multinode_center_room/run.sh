#!/usr/bin/env bash
# Test script for Center + Room multinode example. Run from repo root:
#   ./example/guess_gate_multinode_center_room/run.sh [start|stop|test|test_multi_room]
set -e

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

MOON="${MOON:-./target/debug/moon}"
EX="example/guess_gate_multinode_center_room"
PID_DIR="${PID_DIR:-$EX}"
ROOM_PID="$PID_DIR/.room.pid"
CENTER_PID="$PID_DIR/.center.pid"

mkdir -p "$PID_DIR"

start_room() {
    if [ -f "$ROOM_PID" ] && kill -0 "$(cat "$ROOM_PID")" 2>/dev/null; then
        echo "Room already running (pid $(cat "$ROOM_PID"))"
        return 0
    fi
    echo "Starting Room node..."
    "$MOON" "$EX/room_main.lua" &
    echo $! > "$ROOM_PID"
    sleep 1
    echo "Room node started (pid $(cat "$ROOM_PID"))"
}

start_center() {
    if [ -f "$CENTER_PID" ] && kill -0 "$(cat "$CENTER_PID")" 2>/dev/null; then
        echo "Center already running (pid $(cat "$CENTER_PID"))"
        return 0
    fi
    echo "Starting Center node..."
    "$MOON" "$EX/center_main.lua" &
    echo $! > "$CENTER_PID"
    sleep 1
    echo "Center node started (pid $(cat "$CENTER_PID"))"
}

stop_all() {
    for f in "$CENTER_PID" "$ROOM_PID"; do
        if [ -f "$f" ]; then
            local pid
            pid=$(cat "$f")
            if kill -0 "$pid" 2>/dev/null; then
                echo "Stopping $f (pid $pid)..."
                kill "$pid" 2>/dev/null || true
            fi
            rm -f "$f"
        fi
    done
    echo "Stopped."
}

start_all() {
    start_center
    start_room
    sleep 1
}

# --- commands ---
cmd_gen_proto() {
    echo "Compiling .proto -> .pb (from repo root)..."
    export MOON_REPO_ROOT="$REPO_ROOT"
    "$MOON" "$EX/tools/gen_proto.lua"
    echo "Done. Optional: pass proto path and out path as args."
}

cmd_start() {
    start_all
    echo "Use: $0 test       # run one sim (alice + bob)"
    echo "Use: $0 test_multi_room  # run two sims in parallel (2 rooms, 4 players)"
    echo "Use: $0 stop       # stop Room and Center"
}

cmd_stop() {
    stop_all
}

cmd_test() {
    start_all
    echo "Running two single-player clients (alice, bob)..."
    MOON_REPO_ROOT="$REPO_ROOT" SIM_PLAYER=alice "$MOON" "$EX/game_server_sim.lua" &
    SIM1_PID=$!
    sleep 1
    MOON_REPO_ROOT="$REPO_ROOT" SIM_PLAYER=bob "$MOON" "$EX/game_server_sim.lua" &
    SIM2_PID=$!
    wait $SIM1_PID $SIM2_PID
    echo "Sim finished."
}

cmd_test_multi_room() {
    start_all
    echo "Running four single-player clients (room1: alice+bob, room2: carol+dave)..."
    MOON_REPO_ROOT="$REPO_ROOT" SIM_PLAYER=alice "$MOON" "$EX/game_server_sim.lua" &
    MOON_REPO_ROOT="$REPO_ROOT" SIM_PLAYER=bob "$MOON" "$EX/game_server_sim.lua" &
    sleep 2
    MOON_REPO_ROOT="$REPO_ROOT" SIM_PLAYER=carol "$MOON" "$EX/game_server_sim.lua" &
    MOON_REPO_ROOT="$REPO_ROOT" SIM_PLAYER=dave "$MOON" "$EX/game_server_sim.lua" &
    wait
    echo "All sims finished."
}

usage() {
    echo "Usage: $0 {start|stop|test|test_multi_room|gen_proto}"
    echo "  start          Start Room + Center in background (from repo root)"
    echo "  stop           Stop Room and Center"
    echo "  test           Start nodes (if needed), run one sim (alice + bob), exit"
    echo "  test_multi_room Start nodes, run two sims in parallel (2 rooms, 4 players)"
    echo "  gen_proto      Compile protocol/proto/guess.proto -> protocol/guess.pb"
    echo ""
    echo "From repo root: MOON=./target/debug/moon $0 test"
}

case "${1:-}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    test)   cmd_test ;;
    test_multi_room) cmd_test_multi_room ;;
    gen_proto) cmd_gen_proto ;;
    *)      usage; exit 1 ;;
esac
