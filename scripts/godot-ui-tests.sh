#!/bin/sh
# 앱 대전 화면 자동 테스트 (godot/scripts/battle/ui_tests.gd)
#  1) 헤드리스: 배치·그리기·화면 조작 대전 (+ 인자로 일부만: layout render play ...)
#  2) 창 모드: 합성 터치 끌어 놓기 (헤드리스는 합성 입력이 UI 에 전달되지 않음) — 인자 없이 실행할 때, UI_TEST_NO_WINDOW=1 이면 건너뜀
# 스크립트 오류·시간 초과도 실패
G=$(ls "$LOCALAPPDATA"/Microsoft/WinGet/Packages/GodotEngine*/Godot_v*_console.exe 2>/dev/null | head -1)
cd "$(dirname "$0")/../godot" || exit 2
"$G" --headless --path . --import >/dev/null 2>&1
check() {
  echo "$1" | grep -E "^\[ui-tests\]|SCRIPT ERROR|Parse Error|   at: " | awk '!seen[$0]++' | head -60
  [ "$2" -eq 124 ] && { echo "[ui-tests] 시간 초과 → 실패"; return 1; }
  if echo "$1" | grep -qE "SCRIPT ERROR|Parse Error"; then echo "[ui-tests] 스크립트 오류 있음 → 실패"; return 1; fi
  echo "$1" | grep -q "결과: 통과" || return 1
}
if [ $# -gt 0 ]; then
  OUT=$(timeout "${UI_TEST_TIMEOUT:-1500}" "$G" --headless --path . -- --ui-tests "$@" 2>&1); check "$OUT" $? || exit 1
  exit 0
fi
OUT=$(timeout "${UI_TEST_TIMEOUT:-1500}" "$G" --headless --path . -- --ui-tests layout render play 2>&1); check "$OUT" $? || exit 1
[ -n "$UI_TEST_NO_WINDOW" ] && exit 0
OUT=$(timeout "${UI_TEST_TIMEOUT:-1500}" "$G" --path . --resolution 720x1560 -- --ui-tests drag 2>&1); check "$OUT" $? || exit 1
