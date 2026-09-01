#!/usr/bin/env bash
# Git smudge filter: applied when checking out files.
# Reads the target domain from .telegram-domain at the repo root.
#
# Two modes, registered as two filter drivers (see .gitattributes):
#
# Default (source code) — rewrites "t.me" only where it appears as a URL host:
# preceded by a string-opening quote or by "//" (any scheme, and comments), and
# followed by "/" or a closing quote. Anchoring on both boundaries catches every
# host form while leaving identifiers such as "context.messageStyle()" — which
# contain "t.me" as a substring — untouched.
#
# "bare" — rewrites every "t.me". For lang.strings, where the host also appears
# unquoted mid-sentence ("Public links such as t.me/title") and there are no
# identifiers to protect.
ROOT="$(git rev-parse --show-toplevel)"
DOMAIN="$(cat "$ROOT/.telegram-domain")"
if [ "$1" = "bare" ]; then
  exec sed -E \
    -e "s#t\\.me#${DOMAIN}#g"
fi
exec sed -E \
  -e "s#(\"|//)t\\.me([/\"])#\\1${DOMAIN}\\2#g"
