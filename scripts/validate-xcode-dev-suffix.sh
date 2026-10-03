#!/bin/sh
set -eu

# Runtime DevNamespace.sanitize accepts these canonical namespace characters and caps the
# namespace at 24 bytes. Xcode bundle IDs and sharing identifiers use the suffix verbatim, so
# reject noncanonical inputs here instead of silently normalizing build identities.
LC_ALL=C
export LC_ALL

suffix=${PINCER_DEV_SUFFIX-}
if [ -z "$suffix" ]; then
    exit 0
fi

invalid_suffix() {
    printf '%s\n' \
        'error: PINCER_DEV_SUFFIX must be empty or .dev- followed by 1–24 lowercase letters, digits, or single hyphen-separated groups.' >&2
    exit 1
}

case "$suffix" in
    .dev-*) namespace=${suffix#.dev-} ;;
    *) invalid_suffix ;;
esac

if [ -z "$namespace" ] || [ "${#namespace}" -gt 24 ]; then
    invalid_suffix
fi

case "$namespace" in
    -* | *- | *--* | *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) invalid_suffix ;;
esac

exit 0
