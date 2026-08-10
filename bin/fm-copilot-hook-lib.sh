#!/usr/bin/env bash
# Shared path-safety helpers for Firstmate-owned Copilot hook configuration.

fm_copilot_resolve_exclude_path() {
  local repo=$1 context=$2 mode=${3:-} common common_real exclude exclude_dir exclude_dir_real
  [ -n "$repo" ] && [ -d "$repo" ] || {
    echo "REFUSED: cannot resolve Copilot worker hook exclusion repository for $context" >&2
    return 1
  }
  common=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) ;;
    *) common="$repo/$common" ;;
  esac
  if [ -L "$common" ] || [ ! -d "$common" ]; then
    echo "REFUSED: unsafe Copilot worker hook git directory for $context" >&2
    return 1
  fi
  common_real=$(CDPATH='' cd -- "$common" 2>/dev/null && pwd -P) || return 1
  exclude=$(git -C "$repo" rev-parse --git-path info/exclude 2>/dev/null) || return 1
  case "$exclude" in
    /*) ;;
    *) exclude="$repo/$exclude" ;;
  esac
  [ "${exclude##*/}" = exclude ] && [ ! -L "$exclude" ] || {
    echo "REFUSED: unsafe Copilot worker hook exclusion path for $context" >&2
    return 1
  }
  exclude_dir=${exclude%/*}
  if [ -L "$exclude_dir" ]; then
    echo "REFUSED: unsafe Copilot worker hook exclusion parent for $context" >&2
    return 1
  fi
  if [ "$mode" = --create ]; then
    mkdir -p "$common_real/info" || return 1
  fi
  if [ -L "$common_real/info" ]; then
    echo "REFUSED: unsafe Copilot worker hook exclusion parent for $context" >&2
    return 1
  fi
  exclude_dir_real=$(CDPATH='' cd -- "$exclude_dir" 2>/dev/null && pwd -P) || return 1
  if [ "$exclude_dir_real" != "$common_real/info" ]; then
    echo "REFUSED: Copilot worker hook exclusion escapes the recorded repository for $context" >&2
    return 1
  fi
  [ ! -L "$exclude_dir_real/exclude" ] || {
    echo "REFUSED: unsafe Copilot worker hook exclusion path for $context" >&2
    return 1
  }
  printf '%s\n' "$exclude_dir_real/exclude"
}
