#!/usr/bin/env bash
# Test script for Center + Room multinode example. Run from repo root:
#   ./example/guess_gate_multinode_center_room/run.sh [start|center|room|stop|kill_all|test|test_multi_room|gen_proto|clean_logs]
set -e

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

# 优先使用 release 二进制（若存在），否则用 debug
if [ -x "./target/release/moon" ]; then
    MOON="${MOON:-./target/release/moon}"
else
    MOON="${MOON:-./target/debug/moon}"
fi
EX="example/guess_gate_multinode_center_room"
LOG_DIR="$EX/log"
PID_DIR="${PID_DIR:-$EX}"
ROOM_PID="$PID_DIR/.room.pid"
CENTER_PID="$PID_DIR/.center.pid"

mkdir -p "$PID_DIR"
mkdir -p "$LOG_DIR"

start_room() {
    if [ -f "$ROOM_PID" ] && kill -0 "$(cat "$ROOM_PID")" 2>/dev/null; then
        echo "[Room] already running (pid $(cat "$ROOM_PID"))"
        return 0
    fi
    echo "[Room] Starting... (log: $LOG_DIR/room-*.log)"
    "$MOON" "$EX/room_main.lua" &
    echo $! > "$ROOM_PID"
    sleep 1
    echo "[Room] started (pid $(cat "$ROOM_PID"))"
}

start_center() {
    if [ -f "$CENTER_PID" ] && kill -0 "$(cat "$CENTER_PID")" 2>/dev/null; then
        echo "[Center] already running (pid $(cat "$CENTER_PID"))"
        return 0
    fi
    echo "[Center] Starting... (log: $LOG_DIR/center-*.log)"
    "$MOON" "$EX/center_main.lua" &
    echo $! > "$CENTER_PID"
    sleep 1
    echo "[Center] started (pid $(cat "$CENTER_PID"))"
}

stop_all() {
    for f in "$CENTER_PID" "$ROOM_PID"; do
        if [ -f "$f" ]; then
            pid=$(cat "$f")
            if kill -0 "$pid" 2>/dev/null; then
                echo "Stopping $(basename "$f" .pid) (pid $pid)..."
                kill "$pid" 2>/dev/null || true
            fi
            rm -f "$f"
        fi
    done
    echo "Stopped."
}

kill_all_moon() {
    # 1) 优先按 pidfile 精准关闭（不误杀其它 moon）
    stop_all

    # 2) 兜底：杀掉与本 example 相关的 moon 进程（center/room/sim）
    # macOS: pgrep/kill 可用；仅匹配本 example 路径，避免误杀其它项目
    local pattern="$EX/(center_main\\.lua|room_main\\.lua|game_server_sim\\.lua)"
    local pids
    pids="$(pgrep -f "$pattern" 2>/dev/null || true)"
    if [ -n "$pids" ]; then
        echo "Killing moon processes matched by pattern: $pattern"
        echo "$pids" | xargs -n 1 kill 2>/dev/null || true
        sleep 0.2
        # 若仍存活再强杀，避免端口残留占用
        pids="$(pgrep -f "$pattern" 2>/dev/null || true)"
        if [ -n "$pids" ]; then
            echo "$pids" | xargs -n 1 kill -9 2>/dev/null || true
        fi
    else
        echo "No extra moon processes found for $EX"
    fi
}

start_all() {
    start_center
    start_room
    sleep 1
    echo "Nodes ready. Center: 13001, Room: 13002, Room->Center: 13005"
}

# --- commands ---
cmd_gen_proto() {
    echo "Compiling .proto -> .pb (from repo root)..."
    export MOON_REPO_ROOT="$REPO_ROOT"
    "$MOON" "$EX/tools/gen_proto.lua"
    echo "Done. Optional: pass proto path and out path as args."
}

cmd_start() {
    cmd_clean_logs
    start_all
    echo ""
    echo "  $0 test            # run one match (alice + bob)"
    echo "  $0 test_multi_room # run 2 rooms (alice+bob, carol+dave)"
    echo "  $0 stop           # stop Center and Room"
    echo "  $0 clean_logs     # remove log files under $LOG_DIR"
}

cmd_center() {
    start_center
    echo "  Log: $LOG_DIR/center-*.log"
}

cmd_room() {
    start_room
    echo "  Log: $LOG_DIR/room-*.log"
}

cmd_stop() {
    stop_all
}

cmd_kill_all() {
    kill_all_moon
}

cmd_clean_logs() {
    if [ ! -d "$LOG_DIR" ]; then
        echo "Log dir not found: $LOG_DIR"
        return 0
    fi
    n=$(find "$LOG_DIR" -maxdepth 1 -type f \( -name "*.log" -o -name "*.log.*" \) 2>/dev/null | wc -l | tr -d ' ')
    if [ "$n" -eq 0 ]; then
        echo "No log files in $LOG_DIR"
        return 0
    fi
    find "$LOG_DIR" -maxdepth 1 -type f \( -name "*.log" -o -name "*.log.*" \) -delete
    echo "Cleared $n log file(s) in $LOG_DIR"
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
    echo "Usage: $0 {start|center|room|stop|kill_all|test|test_multi_room|gen_proto|clean_logs}"
    echo "  start          Start Center + Room in background (from repo root)"
    echo "  center         Start Center only (port 13001, 13005)"
    echo "  room           Start Room only (port 13002, connects to Center)"
    echo "  stop           Stop Center and Room"
    echo "  kill_all       Kill all moon processes for this example (center/room/sim)"
    echo "  test           Start nodes (if needed), run one match (alice + bob)"
    echo "  test_multi_room Start nodes, run 2 rooms in parallel (4 players)"
    echo "  gen_proto      Compile protocol/proto/guess.proto -> protocol/guess.pb"
    echo "  clean_logs     Remove all log files under $EX/log/"
    echo ""
    echo "From repo root: MOON=./target/release/moon $0 start"
}

case "${1:-}" in
    start)   cmd_start ;;
    center)  cmd_center ;;
    room)    cmd_room ;;
    stop)    cmd_stop ;;
    kill_all) cmd_kill_all ;;
    test)    cmd_test ;;
    test_multi_room) cmd_test_multi_room ;;
    gen_proto) cmd_gen_proto ;;
    clean_logs) cmd_clean_logs ;;
    *)       usage; exit 1 ;;
esac
