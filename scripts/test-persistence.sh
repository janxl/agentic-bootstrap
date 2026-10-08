#!/usr/bin/env bash
# End-to-end persistence test: chat, restart the agent pod mid-conversation, check nothing is lost.
# Takes no parameters. Uses the real gateway and the configured model (a couple of LLM calls, so
# allow a minute or so). If the gateway is not already reachable on http://localhost, it starts a
# temporary port-forward.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1

GW="${GATEWAY:-http://localhost}"
if ! curl -s -m 3 -o /dev/null "$GW/"; then
  PF_PORT=18080
  k port-forward svc/gateway "$PF_PORT:80" >/dev/null 2>&1 &
  PF_PID=$!
  trap 'kill $PF_PID 2>/dev/null' EXIT
  GW="http://localhost:$PF_PORT"
  for _ in $(seq 1 20); do curl -s -m 2 -o /dev/null "$GW/" && break; sleep 1; done
fi

SID="persist-test-$RANDOM-$RANDOM"
fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }
chat() { curl -s -m 300 "$GW/chat" -H 'Content-Type: application/json' -d "{\"session_id\":\"$SID\",\"message\":\"$1\"}"; }
history() { curl -s -m 30 "$GW/history/${1:-$SID}"; }

echo "-- before restart"
[ "$(history)" = '{"messages":[]}' ] && pass "new session starts empty" || fail "new session starts empty: $(history)"
R1=$(chat "Remember this code word: PINEAPPLE. Reply with just OK.")
echo "$R1" | grep -q '"reply"' && pass "first message answered" || fail "first message answered: $R1"
H1=$(history)
echo "$H1" | grep -q PINEAPPLE && pass "history contains the first message" || fail "history contains the first message: $H1"

echo "-- restart agent pod"
OLD=$(k get pod -l app=agent -o jsonpath='{.items[0].metadata.name}')
k rollout restart deploy/agent >/dev/null
k rollout status deploy/agent --timeout=180s >/dev/null
NEW=$(k get pod -l app=agent -o jsonpath='{.items[0].metadata.name}')
[ "$OLD" != "$NEW" ] && pass "pod was replaced ($OLD -> $NEW)" || fail "pod was not replaced"

echo "-- after restart"
H2=$(history)
echo "$H2" | grep -q PINEAPPLE && pass "history survived the restart" || fail "history survived the restart: $H2"
[ "$H2" = "$H1" ] && pass "history is identical to before the restart" || fail "history differs after restart"
R2=$(chat "What was the code word I asked you to remember? Answer in one word.")
echo "$R2" | grep -qi PINEAPPLE && pass "the model recalls the code word from stored history" \
  || echo "INFO  model did not repeat the code word (LLM-dependent, not a storage failure): $R2"
H3=$(history)
[ "$(echo "$H3" | grep -o '"role"' | wc -l)" -eq 4 ] && pass "history now has 2 user + 2 assistant messages" || fail "unexpected history: $H3"
[ "$(history "some-other-session-$RANDOM")" = '{"messages":[]}' ] && pass "other sessions are not affected" || fail "other sessions leaked"

echo
[ $fails -eq 0 ] && echo "all passed" || echo "$fails failed"
exit $((fails > 0))
