#!/bin/sh
# keepalived health check — managed by Ansible (roles/technitium).
#
# Exits non-zero when this node's Technitium is not answering, which drops the
# node's VRRP priority (keepalived_health_weight) so the VIP moves to the peer.
#
# Checks BOTH the API and actual DNS resolution: the web service can stay up
# while the DNS listener is wedged, and a VIP pointing at a node that answers
# HTTP but not DNS is worse than no VIP at all.
set -eu

curl -sf --max-time 2 http://127.0.0.1:5380/api/user/session/get >/dev/null || exit 1

# Any response proves the DNS listener is alive; the query need not succeed
# (SERVFAIL is fine, timeout is not).
dig +short +time=2 +tries=1 @127.0.0.1 localhost >/dev/null 2>&1 || exit 1

exit 0
