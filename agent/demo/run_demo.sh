#!/bin/sh
# The whole demo in one terminal: prep card, live meeting with the 25-Euro slip, a question at the end.
# Thinks with Claude Code (your Claude plan) or ANTHROPIC_API_KEY; without either (or with --offline) it uses its rules.
# NOTCH=1 also shows every event in the Starnotch notch (the app must be running).
cd "$(dirname "$0")/.." || exit 1
if [ "${NOTCH:-0}" = "1" ]; then
  uv run python demo/play.py --commands --speed "${SPEED:-1}" \
    | uv run python agent.py --memory demo/meetings --today 2026-10-26 "$@" \
    | uv run python notch_bridge.py
else
  uv run python demo/play.py --commands --speed "${SPEED:-2}" \
    | uv run python agent.py --memory demo/meetings --today 2026-10-26 "$@"
fi
