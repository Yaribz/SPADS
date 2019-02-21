#!/bin/bash

SPADS_LOBBY_LOGIN="${SPADS_LOBBY_LOGIN:-}"
SPADS_LOBBY_PASSWORD="${SPADS_LOBBY_PASSWORD:-}"
SPADS_LOBBY_PASSWORD_FILE="${SPADS_LOBBY_PASSWORD_FILE:-}"
SPADS_OWNER_LOBBY_LOGIN="${SPADS_OWNER_LOBBY_LOGIN:-}"

[[ -z "$SPADS_LOBBY_PASSWORD" && -f "$SPADS_LOBBY_PASSWORD_FILE" ]] && SPADS_LOBBY_PASSWORD="$(head -n 1 $SPADS_LOBBY_PASSWORD_FILE)"

[ -z "$SPADS_LOBBY_LOGIN" ] && echo "WARN: SPADS_LOBBY_LOGIN missing"
[ -z "$SPADS_LOBBY_PASSWORD" ] && echo "WARN: SPADS_LOBBY_PÄSSWORD missing"
[ -z "$SPADS_OWNER_LOBBY_LOGIN" ] && echo "WARN: SPADS_OWNER_LOBBY_LOGIN missing"

exec $@

