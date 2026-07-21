# musl has no locale database; C.UTF-8 is built in and is what console
# tools (btop & co) look for to enable UTF-8 drawing. Respect an existing
# LANG if the user set one.
export LANG=${LANG:-C.UTF-8}
