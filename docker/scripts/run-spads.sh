#!/bin/bash
pushd /opt/spads &>/dev/null
   set -x
  perl ./spads.pl etc/spads.conf \
	  "SPADS_LOBBY_LOGIN=$SPADS_LOBBY_LOGIN" \
	  "SPADS_LOBBY_PASSWORD=$SPADS_LOBBY_PASSWORD" \
	  "SPADS_OWNER_LOBBY_LOGIN=$SPADS_OWNER_LOBBY_LOGIN" \
	  $@
popd &>/dev/null
