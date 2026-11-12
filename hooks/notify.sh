#!/usr/bin/env bash
# Claude Code -> macOS notification bridge.
#
# Invoked by Claude Code hooks with the event name as $1:
#   Stop / Notification / PermissionRequest / PreToolUse
# Reads the event JSON on stdin, renders native macOS notifications via
# terminal-notifier, and wires the notification click to focus the right VS Code
# window (via focus-vscode.sh).
#
# Tool-permission prompts ("Allow reading from X?", "Allow running …?") arrive as
# Claude Code's dedicated PermissionRequest event. Earlier versions guessed them
# with a "waiting detector" (PreToolUse/PostToolUse hooks on every Read/Edit/
# Write). That needed a hook on every file operation — and each PreToolUse hook
# blocks its tool call — so it is gone. Stale PostToolUse or wide PreToolUse
# entries left in an old settings.json are ignored cheaply.
#
# Logs to $TMPDIR/claude-banners.log. Never exits non-zero — a failed
# notification must not break the Claude Code session.

set -uo pipefail

EVENT="${1:-Stop}"

LOG="${TMPDIR:-/tmp}/claude-banners.log"
log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$EVENT" "$*" >>"$LOG" 2>/dev/null || true; }

FOCUS_SCRIPT="$HOME/.claude/hooks/focus-vscode.sh"

# --- read the event JSON from stdin ---------------------------------------
INPUT="$(cat 2>/dev/null || true)"

# --- lightweight JSON string reader (no node) ------------------------------
# Pulls the first "key":"value". Values we read this way (tool_use_id, tool_name,
# cwd) never contain embedded double quotes, so this is sufficient — and fast
# enough to run on every single tool call.
jstr() { printf '%s' "$INPUT" | grep -oE "\"$1\":\"[^\"]*\"" | head -1 | sed -e "s/^\"$1\":\"//" -e 's/\"$//'; }

# --- rich field extraction (node, python3 fallback) ------------------------
# Only used on the paths that show a banner (Notification, PermissionRequest,
# AskUserQuestion, ExitPlanMode) — so the parser lookup lives here, not at top
# level. Emits msg/question/plan/cwd/detail as space-joined base64 tokens ("-"
# for empty) so positional `read` is safe. detail = what a PermissionRequest
# wants to run: tool_input.description, else .command, else .file_path.
extract() {
  local JSON_PARSER=""
  if command -v node >/dev/null 2>&1; then JSON_PARSER="node"
  elif command -v python3 >/dev/null 2>&1; then JSON_PARSER="python3"; fi
  case "$JSON_PARSER" in
    node)
      printf '%s' "$INPUT" | node -e '
        let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
          let d={};try{d=JSON.parse(s)}catch(e){}
          const ti=d.tool_input||{};
          const msg=d.message||"";
          const q=(ti.questions&&ti.questions[0]&&ti.questions[0].question)||"";
          const plan=ti.plan?"1":"";
          const cwd=d.cwd||"";
          const detail=ti.description||ti.command||ti.file_path||"";
          const enc=v=>{const b=Buffer.from(String(v),"utf8").toString("base64");return b||"-";};
          process.stdout.write([msg,q,plan,cwd,detail].map(enc).join(" "));
        });' 2>/dev/null
      ;;
    python3)
      printf '%s' "$INPUT" | python3 -c '
import sys,json,base64
try: d=json.load(sys.stdin)
except Exception: d={}
ti=d.get("tool_input") or {}
msg=d.get("message") or ""
qs=ti.get("questions") or []
q=(qs[0].get("question") if qs and isinstance(qs[0],dict) else "") or ""
plan="1" if ti.get("plan") else ""
cwd=d.get("cwd") or ""
detail=ti.get("description") or ti.get("command") or ti.get("file_path") or ""
def enc(v):
    b=base64.b64encode(str(v).encode("utf-8")).decode("ascii")
    return b if b else "-"
sys.stdout.write(" ".join(enc(x) for x in [msg,q,plan,cwd,detail]))' 2>/dev/null
      ;;
    *) printf -- '- - - - -' ;;
  esac
}
dec() { [ "${1:-}" = "-" ] && return 0; printf '%s' "$1" | base64 -d 2>/dev/null || true; }

# --- helpers ---------------------------------------------------------------
find_terminal_notifier() {
  if command -v terminal-notifier >/dev/null 2>&1; then command -v terminal-notifier; return; fi
  local p
  for p in \
    "$HOME/.claude/bin/terminal-notifier.app/Contents/MacOS/terminal-notifier" \
    "/opt/homebrew/bin/terminal-notifier" \
    "/usr/local/bin/terminal-notifier" \
    "/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier"; do
    [ -x "$p" ] && { printf '%s' "$p"; return; }
  done
}

# Resolve a possibly-nested working directory to the project root that VS Code
# actually has open (git top-level, else nearest marker dir, else unchanged).
# Normalises to an absolute path first so the marker walk can't loop on ".".
resolve_project_root() {
  local d="${1:-}"
  [ -n "$d" ] || { printf '%s' "$d"; return; }
  local abs
  abs="$(cd "$d" 2>/dev/null && pwd)" || abs=""
  [ -n "$abs" ] || { printf '%s' "$d"; return; }
  d="$abs"
  local g git_bin=""
  for g in /usr/bin/git /opt/homebrew/bin/git /usr/local/bin/git; do
    [ -x "$g" ] && { git_bin="$g"; break; }
  done
  if [ -n "$git_bin" ]; then
    local top
    top="$("$git_bin" -C "$d" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$top" ] && [ -d "$top" ] && { printf '%s' "$top"; return; }
  fi
  local cur="$d"
  while [ -n "$cur" ] && [ "$cur" != "/" ]; do
    if [ -e "$cur/.git" ] || [ -d "$cur/.vscode" ] || [ -e "$cur/CLAUDE.md" ] || [ -e "$cur/package.json" ]; then
      printf '%s' "$cur"; return
    fi
    cur="$(dirname "$cur")"
  done
  printf '%s' "$d"
}

# Suppress when you're already looking at this project's VS Code window. Takes the
# project leaf name. Best-effort: needs Accessibility for the window-title step
# and fails OPEN (shows the banner) when it can't tell.
is_focused_on_this_project() {
  local leaf="${1:-}"
  [ -n "$leaf" ] || return 1
  local asn bid
  asn="$(lsappinfo front 2>/dev/null)" || return 1
  [ -n "$asn" ] || return 1
  bid="$(lsappinfo info -only bundleID "$asn" 2>/dev/null | sed -n 's/.*"CFBundleIdentifier"="\([^"]*\)".*/\1/p')"
  case "$bid" in
    com.microsoft.VSCode|com.microsoft.VSCodeInsiders|com.visualstudio.code.oss|com.vscodium) ;;
    *) return 1 ;;
  esac
  local title
  title="$(osascript -e 'tell application "System Events" to tell (first process whose frontmost is true) to get title of front window' 2>/dev/null)" || return 1
  [ -n "$title" ] || return 1
  case "$title" in
    *"$leaf"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Render one notification. Resolves cwd -> project root, suppresses if you're
# already on that window, and wires the click to focus it.
#   show_banner <subtitle> <body> <raw-cwd>
# CLAUDE_PROJECT_DIR (the session's root folder, set by Claude Code for hooks)
# wins over the payload cwd: cwd follows every `cd` the session makes, so it can
# point into a subfolder that is not a git repo or VS Code window of its own.
show_banner() {
  local subtitle="$1" body="${2:- }" rawcwd="${CLAUDE_PROJECT_DIR:-${3:-}}"
  local cwd leaf
  cwd="$(resolve_project_root "$rawcwd")"
  leaf=""; [ -n "$cwd" ] && leaf="$(basename "$cwd" 2>/dev/null || true)"
  if is_focused_on_this_project "$leaf"; then
    log "suppressed (focused, leaf='$leaf'): $subtitle / $body"; return 0
  fi
  local tn; tn="$(find_terminal_notifier)"
  if [ -z "$tn" ]; then log "FAILED: terminal-notifier not found"; return 0; fi
  [ -z "$body" ] && body=" "
  if [ "${#body}" -gt 200 ]; then body="${body:0:197}..."; fi
  local group="claude-banners"; [ -n "$leaf" ] && group="claude-banners-$leaf"
  local execute=""
  if [ -n "$cwd" ] && [ -f "$FOCUS_SCRIPT" ]; then
    local b64; b64="$(printf '%s' "$cwd" | base64 | tr -d '\n')"
    execute="'$FOCUS_SCRIPT' $b64"
  fi
  local args=( -title "Claude Code" -subtitle "$subtitle" -message "$body" -sound default -group "$group" )
  [ -n "$execute" ] && args+=( -execute "$execute" )
  if "$tn" "${args[@]}" >>"$LOG" 2>&1; then log "submitted: '$subtitle' / '$body'"; else log "FAILED: terminal-notifier exited $?"; fi
}

# --- dispatch --------------------------------------------------------------
case "$EVENT" in
  PreToolUse)
    # Matched on AskUserQuestion|ExitPlanMode by install.sh. Anything else comes
    # from a stale, wider matcher in an old settings.json — ignore it (cheap path:
    # grep only, no node).
    tool_name="$(jstr tool_name)"
    case "$tool_name" in
      AskUserQuestion|ExitPlanMode)
        # Always a prompt for you -> banner immediately, with the question text.
        T_MSG="-"; T_Q="-"; T_PLAN="-"; T_CWD="-"; T_DETAIL="-"
        read -r T_MSG T_Q T_PLAN T_CWD T_DETAIL < <(extract) || true
        Q="$(dec "$T_Q")"; PLAN="$(dec "$T_PLAN")"; CWD="$(dec "$T_CWD")"
        if [ -n "$Q" ]; then BODY="$Q"
        elif [ -n "$PLAN" ]; then BODY="Claude is proposing a plan — your approval is needed"
        else BODY="Waiting for your input in VS Code"; fi
        show_banner "Needs your attention" "$BODY" "$CWD"
        ;;
      *) : ;;
    esac
    exit 0
    ;;
  PermissionRequest)
    # The "Allow …?" tool-approval prompt. AskUserQuestion/ExitPlanMode also
    # arrive here, but PreToolUse already showed them with the question text.
    tool_name="$(jstr tool_name)"
    case "$tool_name" in
      AskUserQuestion|ExitPlanMode)
        log "skipped: PermissionRequest for $tool_name (PreToolUse already notified)"
        exit 0 ;;
    esac
    T_MSG="-"; T_Q="-"; T_PLAN="-"; T_CWD="-"; T_DETAIL="-"
    read -r T_MSG T_Q T_PLAN T_CWD T_DETAIL < <(extract) || true
    CWD="$(dec "$T_CWD")"; DETAIL="$(dec "$T_DETAIL")"
    if [ -n "$DETAIL" ]; then BODY="${tool_name:-Tool}: $DETAIL"
    else BODY="${tool_name:-A tool} is waiting for your permission"; fi
    show_banner "Needs your approval" "$BODY" "$CWD"
    ;;
  PostToolUse)
    # No longer used (the old waiting detector); ignore stale hook entries.
    exit 0
    ;;
  Notification)
    # permission_prompt only repeats a prompt PermissionRequest / PreToolUse has
    # already shown, 15-30 s later — often after you answered. Skip it; other
    # types (idle_prompt, ...) still notify.
    if [ "$(jstr notification_type)" = "permission_prompt" ]; then
      log "skipped: notification_type=permission_prompt (PermissionRequest/PreToolUse already notified)"
      exit 0
    fi
    T_MSG="-"; T_Q="-"; T_PLAN="-"; T_CWD="-"; T_DETAIL="-"
    read -r T_MSG T_Q T_PLAN T_CWD T_DETAIL < <(extract) || true
    MSG="$(dec "$T_MSG")"; Q="$(dec "$T_Q")"; PLAN="$(dec "$T_PLAN")"; CWD="$(dec "$T_CWD")"
    if [ -n "$MSG" ]; then BODY="$MSG"
    elif [ -n "$Q" ]; then BODY="$Q"
    elif [ -n "$PLAN" ]; then BODY="Claude is proposing a plan — your approval is needed"
    else BODY="Waiting for your input in VS Code"; fi
    show_banner "Needs your attention" "$BODY" "$CWD"
    ;;
  Stop)
    CWD="$(jstr cwd)"
    show_banner "Turn complete" "Ready for your next prompt" "$CWD"
    ;;
  *)
    # Unknown events used to fall through to "Turn complete" — e.g. every
    # PermissionRequest showed a false "Turn complete" banner.
    log "skipped: no banner for event '$EVENT'"
    ;;
esac

exit 0
