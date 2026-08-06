#!/usr/bin/env bash
# Validate a project origin URL that one home hands to another.
#
# Firstmate resolves a project's origin itself - from the captain, the project
# registry, a clone that already exists somewhere, or the forge - and passes the
# concrete URL into seeding. Nothing here discovers an origin, so no caller has
# to create a local clone just to learn one. This library only answers whether a
# supplied origin is a safe clone URL, and is sourced by both the sending parent
# (bin/fm-remote-home-seed.sh) and the receiving host
# (bin/fm-remote-home-provision.sh), so an unsafe value is refused at each end
# rather than trusted because the other end already looked at it.
#
# Accepted forms:
#   https://host/path, http://host/path, ssh://host/path, git://host/path
#   file:///path
#   [user@]host:path              scp-like syntax
#   /absolute/path                a repository on the cloning host's filesystem
#
# Every other value is refused, including remote-helper transports such as
# "ext::<command>", which git executes; option-shaped values that a later
# command line could absorb as a flag; and any value carrying whitespace or
# control characters.

fm_project_origin_safe() { # <url>; 0 when the URL is an accepted clone URL
  local url=${1-} host path

  case $url in
    '' | -*) return 1 ;;
  esac
  case $url in
    *[[:space:]]* | *[[:cntrl:]]*) return 1 ;;
  esac
  case $url in
    https://?* | http://?* | ssh://?* | git://?* | file:///?*) return 0 ;;
    /?*) return 0 ;;
    *://*) return 1 ;;
  esac

  case $url in
    *:*) ;;
    *) return 1 ;;
  esac
  host=${url%%:*}
  path=${url#*:}
  case $host in
    *@*) host=${host#*@} ;;
  esac
  case $host in
    '' | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  case $path in
    '' | :*) return 1 ;;
  esac
  return 0
}
