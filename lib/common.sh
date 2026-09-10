#!/usr/bin/env bash
# lib/common.sh — shared helpers sourced by setup.sh, run.sh and stop.sh.

# Load KEY=value pairs from a config file into the environment.
#
# The file is treated as pure DATA: values are never evaluated, quoted or
# expanded — a hand-edited config cannot inject commands. Full-line comments
# (#) and blank lines are ignored; CRLF line endings are tolerated. The value
# is everything after the FIRST '=', so values may contain '=' and spaces.
#
# Strict: returns non-zero (and the caller should abort) on malformed lines.
#
# Usage: load_config <file>
load_config() {
    local file="$1" line key value lineno=0
    if [[ ! -r "$file" ]]; then
        echo "Error: config file not found or unreadable: $file" >&2
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"                              # tolerate CRLF
        line="${line#"${line%%[![:space:]]*}"}"           # trim leading ws
        line="${line%"${line##*[![:space:]]}"}"           # trim trailing ws
        if [[ -z "$line" || "$line" == \#* ]]; then
            continue
        fi
        if [[ "$line" != *=* ]]; then
            echo "Error: $file:$lineno — expected KEY=value, got: $line" >&2
            return 1
        fi
        key="${line%%=*}"
        value="${line#*=}"
        if [[ ! "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
            echo "Error: $file:$lineno — invalid variable name: $key" >&2
            return 1
        fi
        printf -v "$key" '%s' "$value"
    done < "$file"
    return 0
}
