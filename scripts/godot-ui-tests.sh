#!/bin/sh
# 앱 대전 화면 자동 테스트 실행 (리소스 가져오기 → 테스트, 스크립트 오류·시간 초과도 실패). 사용: sh scripts/godot-ui-tests.sh [추가 인자]
G=$(ls "$LOCALAPPDATA"/Microsoft/WinGet/Packages/GodotEngine*/Godot_v*_console.exe 2>/dev/null | head -1)
cd "$(dirname "$0")/../godot" || exit 2
"$G" --headless --path . --import >/dev/null 2>&1
OUT=$(timeout "${UI_TEST_TIMEOUT:-900}" "$G" --headless --path . -- --ui-tests "$@" 2>&1)
CODE=$?
echo "$OUT" | grep -E "^\[ui-tests\]|SCRIPT ERROR|Parse Error|   at: " | awk '!seen[$0]++' | head -60
[ $CODE -eq 124 ] && { echo "[ui-tests] 시간 초과 → 실패"; exit 1; }
if echo "$OUT" | grep -qE "SCRIPT ERROR|Parse Error"; then echo "[ui-tests] 스크립트 오류 있음 → 실패"; exit 1; fi
echo "$OUT" | grep -q "결과: 통과" || exit 1
