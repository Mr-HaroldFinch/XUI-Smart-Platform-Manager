#!/usr/bin/env bash
# ==============================================================================
#  MOC Networks | XUI-SPM - X-UI Smart Panel Manager  (NX Panel, 3x-ui, Alireza, x-ui)
#  Powered by MOC Networks Smart Solution
# ------------------------------------------------------------------------------
#  1) Backup    - OLD server: consistent SQLite snapshot + AES-256; panel type auto-detected
#  2) Migrate   - NEW server: NX Panel wizard, or exact restore into 3x-ui / Alireza / x-ui
#  3) Inspect   - what a backup file contains (users, domains, inbounds, exposure, certificates)
#  4) Panels    - install OR update (the menu adapts to what is installed) + optional Nginx/HTTPS
#  5) Optimize  - expired/unused certificates, old backups, rollback leftovers
#  6) Self-update - this script (GitHub)   |   Verification runs automatically after a migration
#
#  Version scheme: [Version].[Year].[Month].[Subversion]
# ==============================================================================

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    echo "Bash 4.4 or newer is required." >&2
    exit 1
fi

set -u
set -o pipefail
umask 077

# Text must be handled as UTF-8 (a C/POSIX locale counts bytes and cuts Persian/emoji text in half).
ensure_utf8() {
    local l
    [[ $(locale charmap 2>/dev/null) == UTF-8 ]] && return 0
    for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
        if [[ $(LC_ALL=$l locale charmap 2>/dev/null) == UTF-8 ]]; then export LC_ALL=$l; return 0; fi
    done
    return 0
}
ensure_utf8

# ── Display style ─────────────────────────────────────────────────────────────
# "safe" (default) shows only characters that every console font has (Consolas, Courier New, PuTTY, MobaXterm).
# Emoji and symbols such as the heavy tick or ❯ come from fallback fonts there and appear clipped or as empty boxes.
# "fancy" (--fancy, MOC_ICONS=fancy) keeps the emoji. The text of this script is converted once, at start-up.
ICON_STYLE=${MOC_ICONS:-}
for _a in "$@"; do
    case $_a in --fancy|--fancy-icons) ICON_STYLE=fancy ;; --safe-icons) ICON_STYLE=safe ;; esac
done
[[ -n $ICON_STYLE ]] || ICON_STYLE=$(head -n 1 /etc/moc-networks/icons.pref 2>/dev/null | tr -d '[:space:]')
[[ $ICON_STYLE == fancy ]] || ICON_STYLE=safe
unset _a
if [[ $ICON_STYLE == safe && -z ${MOC_SRC_SAFE:-} && ${BASH_SOURCE[0]:-$0} == "$0" && -f $0 && -r $0 && $(locale charmap 2>/dev/null) == UTF-8 ]]; then
    _del='' _expr=() _c='' _ch='' _to='' _i=0
    for _c in 1F527 1F680 1F504 1F519 1F4BE 274C 1F310 1F4E6 1F50D 1F52C 1F199 1F510 1F4C1 2705 1F539 2757 2B50 1F512 26D4 23F8 \
              23ED 1F3B2 270F 2796 26AA 1F9E9 1F6D1 1F50E 1F30D 2795 1F5A5 1F5D1 1F4A1 1F6E1 1F4CB 1F9F9 1F4CA 1F517 1F441 FE0F; do
        printf -v _ch "\\U${_c}"; _del+="${_ch}|"
    done
    for _i in {166..191}; do printf -v _c '%x' "$_i"; printf -v _ch "\\xf0\\x9f\\x87\\x${_c}"; _del+="${_ch}|"; done      # flag letters
    _del=${_del%|}
    _expr=(-e "s/(${_del})+[[:space:]]*//g")
    for _c in "2714:221A" "2716:00D7" "26A0:25B2" "2139:0069" "2605:2666" "276F:25BA" "256D:250C" "256E:2510" "2570:2514" "256F:2518" \
              "2501:2550" "2595:2502" "258F:2502" "21B3:2514" "280B:00B7" "2819:2022" "2839:25CF" "2838:25CF" "283C:2022" "2834:00B7" \
              "2826:00B7" "2827:2022" "2807:25CF" "280F:2022"; do
        printf -v _ch "\\U${_c%%:*}"; printf -v _to "\\U${_c##*:}"
        _expr+=(-e "s/${_ch}/${_to}/g")
    done
    _src=$(sed -E "${_expr[@]}" -- "$0") && [[ -n $_src ]] && {
        export MOC_SRC_SAFE=1
        eval "$_src"
        exit $?
    }
fi
if [[ $ICON_STYLE == safe ]]; then
    I_OK='√' I_INFO='i' I_WARN='▲' I_ERR='×' I_STAR='♦' I_LOCK='■' I_GAP='   '
else
    I_OK=$'\U2705' I_INFO=$'\U1F539' I_WARN=$'\U2757' I_ERR=$'\U274C' I_STAR=$'\U2B50' I_LOCK=$'\U1F512' I_GAP='  '
fi

# ── Constants ─────────────────────────────────────────────────────────────────
readonly VER_MAIN="1" VER_YEAR="2026" VER_MONTH="11" VER_SUB="4"
readonly SCRIPT_VERSION="${VER_MAIN}.${VER_YEAR}.${VER_MONTH}.${VER_SUB}"
readonly SIGNATURE="MOC Networks Smart Solution"

readonly BACKUP_HOME="/root"
readonly ARCHIVE_ROOT="server_backup"          # top-level dir inside archives (compat)
readonly PBKDF2_ITER=600000
readonly NX_INSTALL_URL='https://raw.githubusercontent.com/nx-panel/panel/main/install.sh'
readonly NX_MIGRATE_BASE='https://github.com/Nexora-VPN/nexora-migrate/releases/latest/download'
readonly NX_RELEASES_URL='https://github.com/Nexora-VPN/nexora-migrate/releases'
readonly NX_DOCS_URL='https://docs.nx-panel.org/'
readonly NX_WIZARD_PORT=8787

SCRIPT_PATH="$(readlink -f -- "$0" 2>/dev/null || true)"

# ── Runtime state ─────────────────────────────────────────────────────────────
UI_LANG="EN"
UI_COLS=80
TERM_COLS=80
ROWS=24
ANIM=0 TYPE_ON=0
LRM=''
MC_TAIL=0
MENU_HAS_BACK=0
CERT_TMP=""
RULE=""
REMOTE_MODE=0
MENU_RESULT=""
INPUT_VALUE=""
RESOLVED_IP=""
PANEL_NAME="x-ui"
SELECTED_ARCHIVE=""
MIG_STAGE=""
MIG_TOOL=""
CLEANUP_PATHS=()
WIZ_PID='' WIZ_UFW=''
C_CYAN='' C_GREEN='' C_YELLOW='' C_RED='' C_PURPLE='' C_BLUE=''
C_WHITE='' C_DIM='' C_BOLD='' C_RESET='' C_ACC='' C_NOTE=''

# ── Cleanup / signals ─────────────────────────────────────────────────────────
register_cleanup() { CLEANUP_PATHS+=("$1"); }

cleanup() {
    local p
    [[ -t 2 ]] && printf '\033[?25h' >&2          # always give the cursor back
    [[ -t 1 ]] && printf '\033[r' >/dev/tty 2>/dev/null   # and the normal scrolling region
    for p in "${CLEANUP_PATHS[@]}"; do
        [[ -n $p && -e $p ]] && rm -rf -- "$p"
    done
    [[ -n ${WIZ_PID:-} ]] && kill "$WIZ_PID" 2>/dev/null
    [[ -n ${WIZ_UFW:-} ]] && ufw --force delete allow from "${WIZ_UFW%% *}" to any port "${WIZ_UFW##* }" proto tcp >/dev/null 2>&1
    unset XUI_BK_PASS SSHPASS SRV_PASS 2>/dev/null || true
    return 0
}
trap cleanup EXIT
trap 'printf "\n"; exit 130' INT TERM

# ── UI toolkit ────────────────────────────────────────────────────────────────
init_ui() {
    local i cols
    if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
        C_CYAN=$'\033[38;5;51m';  C_GREEN=$'\033[38;5;82m'
        C_YELLOW=$'\033[38;5;214m'; C_RED=$'\033[38;5;196m'
        C_PURPLE=$'\033[38;5;141m'; C_BLUE=$'\033[38;5;39m'
        C_WHITE=$'\033[1;37m';    C_DIM=$'\033[2m'
        C_BOLD=$'\033[1m';        C_RESET=$'\033[0m'
        C_ACC=$'\033[1;38;5;220m'; C_NOTE=$'\033[38;5;110m'   # highlighted data / explanatory notes in menus
    fi
    cols=$(tput cols 2>/dev/null || echo 80)
    [[ $cols =~ ^[0-9]+$ ]] || cols=80
    TERM_COLS=$cols; (( TERM_COLS < 60 )) && TERM_COLS=60
    (( cols > 100 )) && cols=100
    (( cols < 60 ))  && cols=60
    UI_COLS=$cols
    ROWS=$(tput lines 2>/dev/null || echo 24)
    [[ $ROWS =~ ^[0-9]+$ ]] || ROWS=24
    ANIM=0
    if [[ -t 0 && -t 1 && -t 2 && -n $C_RESET && -z ${MOC_NO_ANIM:-} ]]; then ANIM=1; fi
    TYPE_ON=$ANIM
    RULE=""
    for (( i = 0; i < 64; i++ )); do RULE+='─'; done   # same width as the banner box
}

set_lrm() { if [[ $UI_LANG == FA ]]; then LRM=$'\xe2\x80\x8e'; else LRM=''; fi; }

cert_tmp_init() {   # one private scratch file for certificate scans (removed on exit)
    if [[ -z $CERT_TMP || ! -f $CERT_TMP ]]; then
        CERT_TMP=$(mktemp "${TMPDIR:-/tmp}/moc-certs.XXXXXX") || CERT_TMP=/dev/null
        register_cleanup "$CERT_TMP"
    fi
}

tf() { local f; f=$(t "$1"); shift; printf "$f" "$@"; }   # tf <key> <printf args...>

# ── Text helpers: display-width aware wrapping (never truncates) ─────────────
pywrap() {   # pywrap <width> <text>...  -> one output line per text; wrapped rows are joined by \x1f
    local w=$1
    shift
    if ! command -v python3 >/dev/null 2>&1; then printf '%s\n' "$@"; return 0; fi
    python3 -I -c '
import re, sys, unicodedata
try: sys.stdout.reconfigure(encoding="utf-8")
except Exception: pass
W = int(sys.argv[1])
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
ZERO = {0x01,0x02,0x200b,0x200c,0x200d,0x200e,0x200f,0x2060,0x2066,0x2067,0x2068,0x2069,0xfe0f}
def cw(c):
    o = ord(c)
    if o in ZERO or unicodedata.category(c) in ("Mn", "Me", "Cf"): return 0
    return 2 if unicodedata.east_asian_width(c) in ("W", "F") else 1
def sw(s): return sum(map(cw, ANSI.sub("", s)))
def wrap(s, w):
    rows, cur, cwid = [], "", 0
    for tok in re.findall(r"\s+|\S+", s):
        tw = sw(tok)
        if cwid + tw <= w:
            cur += tok; cwid += tw
        elif tok.isspace():
            if cur.strip():
                rows.append(cur.rstrip()); cur, cwid = "", 0
        else:
            if cur.strip():
                rows.append(cur.rstrip()); cur, cwid = "", 0
            while tw > w:
                piece, pw = "", 0
                for ch in tok:
                    if pw + cw(ch) > w: break
                    piece += ch; pw += cw(ch)
                if not piece: break
                rows.append(piece); tok = tok[len(piece):]; tw = sw(tok)
            cur, cwid = tok, tw
    if cur.strip() or not rows: rows.append(cur.rstrip())
    return rows
for a in sys.argv[2:]:
    print("\x1f".join(wrap(a, W)))
' "$w" "$@"
}

# say <color> <icon> <text> [fd]  - icon, THREE spaces, then the text; long text wraps with a hanging indent
say() {
    local color=$1 icon=$2 text=$3 fd=${4:-1} w=$(( UI_COLS - 8 )) first=1 row
    local -a rows=()
    text=${text//$'\n'/ }
    if (( ${#text} > w )); then IFS=$'\x1f' read -ra rows < <(pywrap "$w" "$text"); else rows=("$text"); fi
    for row in "${rows[@]}"; do
        if (( first )); then
            printf ' %s%s%s%s%s%s%s%s\n' "$color" "$icon" "$C_RESET" "$I_GAP" "$color" "$LRM" "$row" "$C_RESET" >&"$fd"; first=0
        else
            printf '     %s%s%s%s\n' "$color" "$LRM" "$row" "$C_RESET" >&"$fd"
        fi
    done
}
ui_ok()   { say "$C_GREEN"  "$I_OK" "$*"; }
ui_info() { say "$C_BLUE"   "$I_INFO" "$*"; }
ui_warn() { say "$C_YELLOW" "$I_WARN" "$*" 2; }
ui_err()  { say "$C_RED"    "$I_ERR" "$*" 2; }
die()     { ui_err "$*"; exit 1; }

ui_rule() { printf ' %s%s%s\n' "${C_DIM}${C_CYAN}" "$RULE" "$C_RESET"; }

ui_section() {
    printf '\n'
    ui_rule
    printf ' %s%s%s%s\n' "${C_BOLD}${C_CYAN}" "$LRM" "$1" "$C_RESET"
    ui_rule
}

ui_step() {   # ui_step <n> <total> <text>
    printf '\n %s%s[%s/%s]%s   %s%s%s%s\n' "$C_CYAN" "$C_BOLD" "$1" "$2" "$C_RESET" "$C_WHITE" "$LRM" "$3" "$C_RESET"
    pb_start
    pb_set $(( PB_LO + ($1 - 1) * (PB_HI - PB_LO) / $2 )) "[$1/$2] $3"
}

ui_kv() {     # ui_kv <label> <value> [value-color]   (long values wrap under the value column)
    local label=$1 val=$2 color=${3:-$C_WHITE} w=$(( TERM_COLS - 26 )) first=1 row
    local -a rows=()
    val=${val//$'\n'/ }
    (( w < 30 )) && w=30
    if (( ${#val} > w )); then IFS=$'\x1f' read -ra rows < <(pywrap "$w" "$val"); else rows=("$val"); fi
    for row in "${rows[@]}"; do
        if (( first )); then
            printf ' %s▌%s  %s%-18s%s %s%s%s%s\n' "$C_CYAN" "$C_RESET" "$C_DIM" "$label" "$C_RESET" "$color" "$LRM" "$row" "$C_RESET"; first=0
        else
            printf '    %18s %s%s%s%s\n' '' "$color" "$LRM" "$row" "$C_RESET"
        fi
    done
}

box_line() {  # box_line <ASCII text> [color]   (ASCII only so the right border always aligns)
    local text=$1 color=${2:-$C_WHITE} inner=62 pad left right
    pad=$(( inner - ${#text} )); (( pad < 0 )) && pad=0
    left=$(( pad / 2 )); right=$(( pad - left ))
    hp ' %s│%s%*s%s%s%s%*s%s│%s\n' "$C_CYAN" "$C_RESET" "$left" '' "$color" "$text" "$C_RESET" "$right" '' "$C_CYAN" "$C_RESET"
}

# ── Animated header: logo shimmer + session badge ────────────────────────────
LOGO_ART=(
'███╗   ███╗ ██████╗  ██████╗'
'████╗ ████║██╔═══██╗██╔════╝'
'██╔████╔██║██║   ██║██║     '
'██║╚██╔╝██║██║   ██║██║     '
'██║ ╚═╝ ██║╚██████╔╝╚██████╗'
'╚═╝     ╚═╝ ╚═════╝  ╚═════╝')
LOGO_GRAD=(51 45 39 33 63 99)
HDR_NET='━━━━━━━━  N E T W O R K S  ━━━━━━━━'
HDR_ROW=0 HDR_LOGO_ROW=0 HDR_PAD=0 HDR_NET_ROW=0 HDR_NETPAD=0 HDR_BADGE_ROW=0 HDR_VALID=0 HDR_COMPACT=0
HDR_TITLE='━━━━━━━━  M O C   N E T W O R K S  ━━━━━━━━'
SHIM='' HP_OUT='' MOR='' FRAME=''

hp() {   # printf that also counts the rows it printed (the header animation needs absolute row numbers)
    local s nl
    printf -v s "$@"
    printf '%s' "$s"
    nl=${s//[!$'\n']/}
    HDR_ROW=$(( HDR_ROW + ${#nl} ))
}

# shimmer <text> <phase> <base-color> <offset>  -> SHIM : text with a bright band sweeping across it
shimmer() {
    local text=$1 phase=$2 base=$3 off=$4 n=${#1} i ch d c last=-1 out='' pos
    pos=$(( (phase * 2) % (n + 30) - 8 + off ))
    for (( i = 0; i < n; i++ )); do
        ch=${text:i:1}
        if [[ $ch == ' ' ]]; then out+=' '; continue; fi
        d=$(( i - pos )); (( d < 0 )) && d=$(( -d ))
        if   (( d == 0 )); then c=231
        elif (( d <= 1 )); then c=195
        elif (( d <= 3 )); then c=159
        else c=$base; fi
        if (( c != last )); then out+=$'\e[1;38;5;'"${c}m"; last=$c; fi
        out+=$ch
    done
    SHIM="${out}"$'\e[0m'
}

# header_paint <phase> -> HP_OUT   (absolute cursor moves; only valid right after show_header)
header_paint() {
    local phase=$1 i dot
    HP_OUT=''
    (( HDR_LOGO_ROW > 0 || HDR_COMPACT )) || return 0
    if (( HDR_LOGO_ROW > 0 )); then
        for i in "${!LOGO_ART[@]}"; do
            shimmer "${LOGO_ART[i]}" "$phase" "${LOGO_GRAD[i]}" $(( -i * 2 ))
            HP_OUT+=$'\e['$(( HDR_LOGO_ROW + i ))';'$(( HDR_PAD + 1 ))'H'"$SHIM"
        done
        shimmer "$HDR_NET" "$phase" 33 -4
    else
        shimmer "$HDR_TITLE" "$phase" 39 -4
    fi
    HP_OUT+=$'\e['"${HDR_NET_ROW};$(( HDR_NETPAD + 1 ))H${SHIM}"
    if (( HDR_BADGE_ROW > 0 )); then
        if (( REMOTE_MODE )); then
            if (( (phase / 3) % 2 )); then dot=$'\e[1;38;5;196m●'; else dot=$'\e[2;38;5;88m●'; fi
        else
            if (( (phase / 6) % 2 )); then dot=$'\e[1;38;5;82m●'; else dot=$'\e[38;5;28m●'; fi
        fi
        HP_OUT+=$'\e['"${HDR_BADGE_ROW};2H${dot}"$'\e[0m'
    fi
}

print_logo() {
    local i line
    hp '\n'
    if (( UI_COLS < 64 )); then
        HDR_LOGO_ROW=0
        hp ' %s%s M O C   N E T W O R K S %s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
        return
    fi
    HDR_PAD=$(( (UI_COLS - 28) / 2 )); (( HDR_PAD < 1 )) && HDR_PAD=1
    HDR_LOGO_ROW=$(( HDR_ROW + 1 ))
    for i in "${!LOGO_ART[@]}"; do
        if [[ -n $C_RESET ]]; then hp '%*s\033[1;38;5;%dm%s%s\n' "$HDR_PAD" '' "${LOGO_GRAD[i]}" "${LOGO_ART[i]}" "$C_RESET"
        else hp '%*s%s\n' "$HDR_PAD" '' "${LOGO_ART[i]}"; fi
    done
    HDR_NETPAD=$(( (UI_COLS - ${#HDR_NET}) / 2 ))
    HDR_NET_ROW=$(( HDR_ROW + 1 ))
    hp '%*s%s%s%s\n' "$HDR_NETPAD" '' "${C_BOLD}${C_BLUE}" "$HDR_NET" "$C_RESET"
    line="XUI-SPM  ·  X-UI Smart Panel Manager"
    hp '%*s%s%s%s\n\n' $(( (UI_COLS - ${#line}) / 2 )) '' "$C_DIM" "$line" "$C_RESET"
}

print_banner() {
    local bar="" i sub
    HDR_COMPACT=0
    if (( ROWS < 38 )); then    # short terminal: a one-line title keeps menus and reports from scrolling the header away
        HDR_COMPACT=1; HDR_LOGO_ROW=0
        HDR_NETPAD=$(( (UI_COLS - ${#HDR_TITLE}) / 2 )); (( HDR_NETPAD < 0 )) && HDR_NETPAD=0
        hp '\n'
        HDR_NET_ROW=$(( HDR_ROW + 1 ))
        hp '%*s%s%s%s\n' "$HDR_NETPAD" '' "${C_BOLD}${C_BLUE}" "$HDR_TITLE" "$C_RESET"
        sub="X-UI Smart Panel Manager  ·  v${SCRIPT_VERSION}  ·  $(date '+%Y-%m-%d %H:%M')"
        hp '%*s%s%s%s\n' $(( (UI_COLS - ${#sub}) / 2 > 0 ? (UI_COLS - ${#sub}) / 2 : 0 )) '' "$C_DIM" "${sub:0:$((UI_COLS - 2))}" "$C_RESET"
        return 0
    fi
    print_logo
    for (( i = 0; i < 62; i++ )); do bar+='─'; done
    hp ' %s╭%s╮%s\n' "$C_CYAN" "$bar" "$C_RESET"
    box_line "X-UI Smart Panel Manager  (XUI-SPM)" "${C_BOLD}${C_WHITE}"
    box_line "NX Panel  |  3x-ui  |  Alireza x-ui  |  x-ui" "$C_CYAN"
    box_line "${SIGNATURE}  |  v${SCRIPT_VERSION}" "$C_DIM"
    box_line "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$C_DIM"
    hp ' %s╰%s╯%s\n' "$C_CYAN" "$bar" "$C_RESET"
}

PUB_QUICK='' PUB_QUICK_DONE=0
pub_ip_quick() {   # sets PUB_QUICK: the public IPv4 of this server (plain-text services asked in parallel, ~3 s at most); empty when offline
    local tmp u f ip
    (( PUB_QUICK_DONE )) && return 0
    PUB_QUICK_DONE=1; PUB_QUICK=''
    command -v curl >/dev/null 2>&1 || return 0
    tmp=$(mktemp -d 2>/dev/null) || return 0
    for u in https://api.ipify.org https://icanhazip.com https://checkip.amazonaws.com https://ifconfig.me/ip; do
        ( curl -4 -fsS --connect-timeout 2 --max-time 3 "$u" 2>/dev/null | tr -d ' \r\n' >"${tmp}/$(printf '%s' "$u" | cksum | cut -d' ' -f1)" ) &
    done
    wait
    for f in "$tmp"/*; do
        [[ -f $f ]] || continue
        ip=$(<"$f")
        if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then PUB_QUICK=$ip; break; fi
    done
    rm -rf -- "$tmp"
    return 0
}

local_ip_first() {   # the first private/global IPv4 held by this machine
    local ip
    ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4, a, "/"); print a[1]; exit}')
    [[ -n $ip ]] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    printf '%s' "$ip"
}

ip_pair_plain() {   # "203.0.113.5 · internal 10.0.0.4"  /  "203.0.113.5"  /  "10.0.0.4 (internal - no public address found)"
    local pub=${1:-} loc=${2:-}
    if [[ -n $pub && -n $loc && $pub != "$loc" ]]; then printf '%s · %s %s' "$pub" "$(t ip_internal)" "$loc"
    elif [[ -n $pub ]]; then printf '%s' "$pub"
    elif [[ -n $loc ]]; then printf '%s · %s' "$loc" "$(t ip_internal_only)"
    else printf 'no IP'; fi
}

host_label() {   # host_label -> "hostname (ip)"
    local host pub loc
    host=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown)
    pub_ip_quick; pub=${PUB_QUICK:-${PUB_IP:-}}; loc=$(local_ip_first)
    printf '%s (%s)' "${host:0:34}" "$(ip_pair_plain "$pub" "$loc")"
}

host_colored() {   # host_colored [host pub-ip internal-ip]  -> name, public and internal address in different colours
    local host=${1:-} pub=${2:-} loc=${3:-} body
    if [[ -z $host ]]; then
        host=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown)
        pub_ip_quick; pub=${PUB_QUICK:-${PUB_IP:-}}; loc=$(local_ip_first)
    fi
    if [[ -n $pub && -n $loc && $pub != "$loc" ]]; then
        body="${C_ACC}${pub}${C_RESET} ${C_DIM}· $(t ip_internal)${C_RESET} ${C_WHITE}${loc}${C_RESET}"
    elif [[ -n $pub ]]; then body="${C_ACC}${pub}${C_RESET}"
    elif [[ -n $loc ]]; then body="${C_WHITE}${loc}${C_RESET} ${C_DIM}· ${C_YELLOW}$(t ip_internal_only)${C_RESET}"
    else body="${C_DIM}no IP${C_RESET}"; fi
    printf '%s%s%s %s(%s%s%s)%s' "${C_BOLD}${C_CYAN}" "${host:0:34}" "$C_RESET" "$C_DIM" "$C_RESET" "$body" "$C_DIM" "$C_RESET"
}

print_session_header() {
    local src_host src_ip here
    here=$(host_colored)
    hp '\n'
    HDR_BADGE_ROW=$(( HDR_ROW + 1 ))
    if (( REMOTE_MODE )); then
        src_host=${XUI_SOURCE_HOST:-unknown}; src_ip=${XUI_SOURCE_IP:-unavailable}
        src_host=${src_host//[^[:print:]]/}; src_ip=${src_ip//[^[:print:]]/}
        hp ' %s●%s %s%s%s%s  %s- %s%s\n' "$C_RED" "$C_RESET" "$C_RED" "$C_BOLD" "$(t hdr_remote)" "$C_RESET" "$C_YELLOW" "$(t hdr_remote_sub)" "$C_RESET"
        hp '   %s%s :%s %s\n' "$C_DIM" "$(t hdr_here)" "$C_RESET" "$here"
        hp '   %s%s :%s %s%s%s %s(%s%s%s%s%s)%s\n' "$C_DIM" "$(t hdr_from)" "$C_RESET" "${C_BOLD}${C_PURPLE}" "${src_host:0:30}" "$C_RESET" "$C_DIM" "$C_RESET" "$C_ACC" "${src_ip:0:64}" "$C_DIM" "$C_RESET" "$C_RESET"
        hp '   %s%s :%s %s%s%s\n' "$C_DIM" "$(t hdr_goback)" "$C_RESET" "$C_WHITE" "$(t hdr_goback_txt)" "$C_RESET"
    else
        hp ' %s●%s %s%s%s%s   %s\n' "$C_GREEN" "$C_RESET" "$C_GREEN" "$C_BOLD" "$(t hdr_local)" "$C_RESET" "$here"
    fi
}

# show_header: clear the screen and draw the (animated) logo, banner and session badge at the top
show_header() {
    HDR_VALID=0 HDR_ROW=0 HDR_BADGE_ROW=0 HDR_LOGO_ROW=0
    if [[ -t 1 ]]; then printf '\033[H\033[2J'; fi
    print_banner
    print_session_header
    printf '\n'
    (( ANIM && (HDR_LOGO_ROW > 0 || HDR_COMPACT) )) && HDR_VALID=1
    return 0
}

progress_bar() {   # progress_bar <0-100>
    local pct=$1 size=20 filled i color=$C_RED out=""
    filled=$(( pct * size / 100 ))
    if (( pct >= 70 )); then color=$C_GREEN; elif (( pct >= 40 )); then color=$C_YELLOW; fi
    out+="$color"
    for (( i = 0; i < size; i++ )); do
        if (( i < filled )); then out+='■'; else out+='·'; fi
    done
    printf '%s%s %d%%' "$out" "$C_RESET" "$pct"
}

meter() {   # meter <used-percent> [width]  - usage bar: green / amber / red
    local pct=$1 w=${2:-20} f i color=$C_GREEN out=''
    (( pct < 0 )) && pct=0; (( pct > 100 )) && pct=100
    f=$(( pct * w / 100 ))
    if (( pct >= 90 )); then color=$C_RED; elif (( pct >= 70 )); then color=$C_YELLOW; fi
    for (( i = 0; i < w; i++ )); do
        if (( i < f )); then out+="${color}█"; else out+="${C_DIM}░"; fi
    done
    printf '%s%s %3d%%' "$out" "$C_RESET" "$pct"
}

# ── Typewriter effect: output looks like it is being typed very fast ─────────

type_filter() {
    local line n=0 chunk i len ch buf cnt k skip=0
    while IFS= read -r line; do
        n=$(( n + 1 ))
        if (( skip )); then printf '%s\n' "$line"; continue; fi
        chunk=$(( 5 + n / 2 )); (( chunk > 80 )) && chunk=80
        buf='' cnt=0 len=${#line}
        for (( i = 0; i < len; i++ )); do
            ch=${line:i:1}
            buf+=$ch
            if [[ $ch == $'\033' ]]; then         # copy a whole escape sequence without counting it
                while (( i + 1 < len )); do
                    i=$(( i + 1 )); ch=${line:i:1}; buf+=$ch
                    [[ $ch == [A-Za-z] ]] && break
                done
                continue
            fi
            if (( ++cnt >= chunk )); then
                printf '%s' "$buf"; buf=''; cnt=0
                if IFS= read -rsn1 -t 0.004 k </dev/tty 2>/dev/null; then   # any key = show the rest at once
                    skip=1; printf '%s' "${line:i+1}"; break
                fi
            fi
        done
        printf '%s\n' "$buf"
    done
}

TYPE_TMP=""
typed_begin() {   # everything printed until typed_end is captured, then shown with the typing effect (or in a scroller)
    (( TYPE_ON )) && [[ -z $TYPE_TMP ]] || return 0
    TYPE_TMP=$(mktemp "${TMPDIR:-/tmp}/.moc-type.XXXXXX") || { TYPE_TMP=''; return 0; }
    exec 5>&1 6>&2 1>"$TYPE_TMP" 2>&1
}

typed_end() {
    local n tmp=$TYPE_TMP
    [[ -n $tmp ]] || return 0
    exec 1>&5 2>&6 5>&- 6>&-
    TYPE_TMP=''
    n=$(wc -l <"$tmp" | tr -d ' ')
    ROWS=$(tput lines 2>/dev/null || echo 24); [[ $ROWS =~ ^[0-9]+$ ]] || ROWS=24
    if (( n + 3 > ROWS - PB_ON )) && command -v less >/dev/null 2>&1 && [[ -t 0 ]]; then
        printf ' %s%s%s\n' "$C_NOTE" "$(t scroll_hint)" "$C_RESET"
        LESS="" less -R -K -P "$(t scroll_prompt)" "$tmp" </dev/tty || cat "$tmp"
    else
        type_filter <"$tmp"
    fi
    rm -f -- "$tmp"
}

typed() { typed_begin; "$@"; local rc=$?; typed_end; return "$rc"; }   # typed <function> [args]  (display-only functions)

# ── Percent progress bar on the last terminal row (scroll region keeps it below all output) ──
PB_ON=0 PB_PCT=0 PB_LO=0 PB_HI=100 PB_LABEL=''
pb_draw() {   # pb_draw [dim 0|1]
    (( PB_ON )) || return 0
    local w=$(( UI_COLS - 30 )) f i out='' c lbl=$PB_LABEL dim=${1:-0}
    local -a pal=(39 38 37 36 35 41 42 46 82)
    (( w > 44 )) && w=44; (( w < 10 )) && w=10
    f=$(( PB_PCT * w / 100 ))
    for (( i = 0; i < w; i++ )); do
        if (( i < f )); then
            c=${pal[ i * 8 / w ]}; (( dim )) && c=240
            out+=$'\e[38;5;'"${c}m"'█'
        else out+=$'\e[38;5;238m░'; fi
    done
    (( ${#lbl} > 28 )) && lbl="${lbl:0:27}…"
    printf '\e7\e[%d;1H\e[2K %-30s\e[0m ▕%s\e[38;5;245m▏\e[0m %3d%%\e8' "$ROWS" "$lbl" "$out" "$PB_PCT" >/dev/tty 2>/dev/null || true
}
pb_start() {
    (( ANIM && PB_ON == 0 )) || return 0
    ROWS=$(tput lines 2>/dev/null || echo 24); [[ $ROWS =~ ^[0-9]+$ ]] || ROWS=24
    (( ROWS >= 14 )) || return 0
    PB_ON=1 PB_PCT=0
    printf '\n\e[A\e7\e[1;%dr\e8' $(( ROWS - 1 )) >/dev/tty 2>/dev/null || PB_ON=0
}
pb_set() {   # pb_set <percent> [label]  (smooth fill)
    (( PB_ON )) || return 0
    local to=$1 step
    [[ -n ${2:-} ]] && PB_LABEL=$2
    (( to > 100 )) && to=100
    while (( PB_PCT < to )); do
        step=$(( (to - PB_PCT + 3) / 4 )); (( step < 1 )) && step=1
        PB_PCT=$(( PB_PCT + step )); (( PB_PCT > to )) && PB_PCT=$to
        pb_draw; sleep 0.02
    done
    pb_draw
}
pb_reset() {   # give the terminal back its normal scrolling and clear the bar row
    [[ -t 1 ]] || return 0
    printf '\e7\e[r\e[%d;1H\e[2K\e8' "$ROWS" >/dev/tty 2>/dev/null || true
    PB_ON=0
}
pb_stop() {   # fill to 100 %, hold a moment, fade out
    (( PB_ON )) || return 0
    PB_LABEL=''; pb_set 100
    sleep 0.5; pb_draw 1; sleep 0.15
    pb_reset
}

# ── Spinner for work that must run in the current shell ──────────────────────
SPIN_PID=""
spin_start() {
    if [[ ! -t 1 ]]; then ui_info "$1"; return 0; fi
    (
        trap 'exit 0' TERM
        local -a fr=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏); local i=0
        while true; do printf '\r\033[K %s%s%s   %s' "$C_BLUE" "${fr[i++ % 10]}" "$C_RESET" "$1" >&2; sleep 0.1; done
    ) &
    SPIN_PID=$!
}
spin_stop() {
    if [[ -n $SPIN_PID ]]; then
        kill "$SPIN_PID" 2>/dev/null; wait "$SPIN_PID" 2>/dev/null || true
        SPIN_PID=""; printf '\r\033[K' >&2
    fi
    return 0
}

# run_task "message" cmd args...  - spinner while a command runs; shows its log on failure
run_task() {
    local msg=$1 log pid rc=0 i=0
    local -a frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    shift
    log=$(mktemp) || return 1
    "$@" >"$log" 2>&1 &
    pid=$!
    if [[ -t 1 ]]; then
        while kill -0 "$pid" 2>/dev/null; do
            printf '\r\033[K %s%s%s   %s' "$C_BLUE" "${frames[i++ % 10]}" "$C_RESET" "$msg"
            sleep 0.1
        done
    fi
    wait "$pid" || rc=$?
    [[ -t 1 ]] && printf '\r\033[K'
    if (( rc == 0 )); then
        printf ' %s%s%s%s%s\n' "$C_GREEN" "$I_OK" "$C_RESET" "$I_GAP" "$msg"
    else
        printf ' %s%s%s%s%s\n' "$C_RED" "$I_ERR" "$C_RESET" "$I_GAP" "$msg" >&2
        tail -n 15 "$log" >&2
    fi
    rm -f -- "$log"
    return "$rc"
}

# ── i18n (EN is complete; FA overrides what it defines) ──────────────────────
declare -A T_EN=(
    [lang_title]="LANGUAGE SELECTION"
    [scroll_hint]="This report is longer than one screen: use ↑ ↓ / PgUp PgDn to scroll, press q to continue."
    [scroll_prompt]=" ↑↓ PgUp PgDn = scroll   ·   q = continue   (%pb\\%) "
    [exit]="Exit"
    [yes]="Yes"
    [no]="No"
    [bye]="Goodbye"
    [back_to_menu]="Back at the main menu - pick another action, or choose Exit to leave."
    [main_title]="X-UI Smart Panel Manager  (NX Panel · 3x-ui · Alireza · x-ui)"
    [opt_backup]="📦   Smart backup                  (run on the OLD server)"
    [opt_restore]="🔄   Migrate / restore             (run on the NEW server)"
    [opt_install]="🔧   Install a panel             (NX Panel / 3x-ui / Alireza / x-ui)"
    [opt_update]="🚀   Update a panel"
    [opt_inspect]="🔍   Inspect a backup file         (users, domains, inbounds, exposure)"
    [inspect_title]="Which backup do you want to inspect?"
    [opt_exit]="❌   Exit"
    [install_title]="Which panel do you want to install?"
    [deps_ok]="All required system tools are present."
    [deps_missing]="Missing system tools:"
    [deps_ask]="Install the missing packages now?"
    [deps_no_apt]="apt-get was not found. Install these packages manually:"
    [deps_cancel]="Cannot continue without the required tools."
    [step_precheck]="Pre-backup system checks"
    [step_gather]="Gathering configuration files"
    [step_compress]="Building the archive"
    [step_verify]="Verifying archive integrity"
    [step_deliver]="Backup ready"
    [err_no_db]="No x-ui.db found under /etc or /usr/local. Is X-UI installed on this server?"
    [pick_db]="Several X-UI databases were found - select one"
    [enc_title]="Backup password protection"
    [enc_ask]="Encrypt the backup with a password (AES-256)?"
    [enc_pass_prompt]="Backup password (min 12 characters): "
    [enc_pass_confirm]="Repeat the password: "
    [enc_short]="The password must be at least 12 characters."
    [enc_mismatch]="Passwords do not match - try again."
    [enc_warn_plain]="Unencrypted backup: it will contain panel credentials and TLS private keys in clear form."
    [dec_pass_prompt]="Backup password: "
    [backup_ok]="Backup completed successfully."
    [backup_loc]="FILE"
    [sync_title]="Direct transfer to the new server"
    [sync_ask]="Copy the backup and this script to the new server now?"
    [remote_addr]="New server IPv4 or domain: "
    [remote_user]="SSH username [root]: "
    [remote_port]="SSH port [22]: "
    [remote_pass]="SSH password: "
    [addr_retry]="Enter a valid IPv4 address or a resolvable domain."
    [transferring]="The system is working: copying the files to the remote server - please wait, the connection is fine..."
    [transfer_ok]="Transfer complete - the files are in /root on the new server."
    [remote_launch]="Open the restore menu on the new server over SSH now?"
    [err_keyboard]="Non-English characters detected. Switch the keyboard to English and retry."
    [err_empty]="Input cannot be empty."
    [restore_title]="MIGRATION - select operation"
    [opt_real]="🚀   Real migration - you choose the destination panel (NX Panel is recommended, never forced)"
    [opt_test]="🔬   Test the backup - no system changes"
    [opt_back]="Back"
    [step_select]="Select the backup archive"
    [step_validate]="Extracting and validating the backup"
    [step_preflight]="Server pre-flight checks"
    [step_install]="NX Panel panel"
    [step_migrate]="Official migration wizard"
    [step_target]="Choose the destination panel"
    [step_plan]="Your migration plan"
    [step_run]="Migrating"
    [pick_backup]="Select the source backup"
    [err_no_backup]="No XUI_Backup_* archive found under /root."
    [test_passed]="TEST PASSED - the backup is readable and its database passes integrity checks."
    [test_nochange]="Nothing on this server was changed by the test."
    [real_confirm]="Continue with the migration? This can install software and change this server."
    [preflight_ask]="Run optional pre-flight checks (hardware, IP reputation, domains)? Contacts external services."
    [pf_title]="NEW SERVER INFRASTRUCTURE REPORT"
    [pf_weak]="Hardware is below the recommended minimum for a proxy node."
    [pf_force]="Continue anyway on this weak server?"
    [geo_title]="Target userbase analysis"
    [geo_ask]="Which country will the users connect from?"
    [dom_confirm]="Do you accept the status of these domains and want to proceed?"
    [nx_install_ask]="NX Panel is not installed/active. Install it with the official installer now?"
    [nx_setup_done]="Have you completed the NX Panel setup wizard and can you sign in as administrator?"
    [menu_hint]="↑/↓ move · Enter select · 1-%d direct"
    [menu_hint_back]=" · 0 / Esc back"
    [opt_back1]="🔙   Back"
    [press_key]="Press any key to return to the menu..."
    [opt_panels]="🔧   Install / update a panel      (installed here: %s)"
    [opt_panels_none]="🔧   Install / update a panel      (no panel installed yet)"
    [opt_optimize]="🚀   System optimization           (certificates, old backups, leftovers)"
    [opt_selfupdate]="🆙   Update this script            (from GitHub)"
    [opt_exit_remote]="🔙   Return to the original server  (%s)"
    [panels_title]="Panels on this server - install or update"
    [optimize_title]="System optimization"
    [selfupd_title]="Update this script"
    [target_title]="Choose the destination panel"
    [target_hint]="NX Panel is only a suggestion - pick any panel below, including the one your backup came from."
    [hdr_remote]="REMOTE SERVER"
    [hdr_remote_sub]="every action runs HERE, not on your original server"
    [hdr_here]="You are on"
    [opt_c_sysupd]="Full system update - apt update / upgrade / dist-upgrade / autoremove / autoclean"
    [sysupd_title]="FULL SYSTEM UPDATE"
    [sysupd_note_title]="Before you continue"
    [sysupd_note1]="Packages are downloaded and installed in the background; the screen shows only what matters."
    [sysupd_note2]="Services are not restarted automatically. A kernel update becomes active after a reboot."
    [sysupd_ask]="Update this server now?"
    [sysupd_reboot]="Reboot the server now?"
    [w_sysupd]="the full system update"
    [bye_title]="Goodbye - thank you for using MOC Networks."
    [bye_remote]="Closing the remote session - back to %s."
    [bye_line]="May your servers stay fast, stable and quietly out of sight."
    [ssh_auth]="Logging in over SSH - type the password if you are asked (it is used once and never stored)..."
    [ssh_ok]="Logged in. The connection stays open, so you will not be asked again."
    [ssh_fail]="SSH login failed. Check the IP, user, port and password / key."
    [ssh_working_probe]="The system is working: inspecting the remote server (hardware, network, GitHub access, speed) - about 40 seconds. The connection is fine, please wait..."
    [remote_starting]="The system is working: starting the manager on the remote server - the screen refreshes in a few seconds, the connection is not frozen."
    [ip_internal]="internal"
    [ip_internal_only]="internal, no public IP found"
    [hdr_from]="Came from"
    [hdr_goback]="To go back"
    [hdr_goback_txt]="Esc / 0 = back  ·  main menu: Esc / 0 or the last item = original server"
    [hdr_local]="LOCAL SERVER"
    [rw_title]="REMOTE SERVER - double-check before you continue"
    [rw_l1]="\"%s\" will run on THIS remote server:  %s"
    [rw_l2]="Your original server - %s - will NOT be touched by this action."
    [rw_ask]="Run \"%s\" on THIS remote server?"
    [w_backup]="backup"
    [w_restore]="migration / restore"
    [w_optimize]="system optimization"
    [w_update]="update %s"
    [w_install]="install %s"
    [rl_title]="Leaving the REMOTE server"
    [rl_body]="You will go back to your original server (%s); the remote session closes."
    [rl_ask]="Return to the original server now?"
    [panels_none]="No supported panel was found on this server - pick one to install."
    [pn_update]="Update %s"
    [pn_other]="Install a different panel, or reinstall one…"
    [pn_install]="Install %s"
    [choose_action]="Choose an action"
    [opt_c_certs]="🔐   Certificates - remove expired / unused   (%s expired · %s unused)"
    [opt_c_backups]="💾   Old backup files - keep only the newest   (%s file(s) · %s)"
    [opt_c_left]="📁   Rollback copies and leftovers   (%s item(s) · %s)"
    [opt_c_scan]="🔄   Scan again"
    [q_del_certs]="Delete these %s certificate(s)? A rollback copy is saved first."
    [q_del_bk]="Delete %s older backup file(s) and free %s?"
    [q_del_left]="Delete these %s item(s) and free %s?"
    [w_keep_off]="Keep at least one copy OFF this server (your own computer or cloud storage) before deleting."
    [w_rollback]="Rollback copies are your way back after a restore or update. Delete them only when the new setup works."
    [q_which_certs]="Which certificates should be removed?"
    [o_certs_safe]="Expired AND not used by the panel / Nginx   (safe)"
    [o_certs_all]="ALL certificates that nothing uses   (includes valid ones)"
    [q_keep_n]="How many of the NEWEST backup files should be kept?"
    [o_keep_n]="Keep the newest %s"
    [o_recommended]="(recommended)"
    [srv_save_title]="Remember the servers you work with?"
    [srv_save_info]="This script can keep a list of your servers (name, address, SSH port, status, score and location) in an encoded file on THIS server (/etc/moc-networks/servers.dat), so next time you can pick one instead of typing it. NO PASSWORD is ever stored - only those details."
    [srv_save_ask]="Save the list of servers for next time?"
    [srv_save_yes]="Saved. The list is kept encoded in /etc/moc-networks/servers.dat (details only, never a password)."
    [srv_save_no]="Nothing will be saved. You can switch this on later in System optimization -> Servers."
    [srv_title]="Servers - check, score and manage"
    [srv_never]="Saved: name, address, SSH port, status, score, location.  Never saved: passwords."
    [srv_none]="No servers saved yet. Check a server and it appears here (when saving is on)."
    [srv_which]="Which server?"
    [srv_new]="Enter a new server"
    [srv_back_hint]="Type 0 at any question to go back."
    [srv_check_first]="Check and score this server first (hardware, network, NAT, GitHub access)?"
    [srv_pref_on]="Saving the server list: ON   (choose to turn it off)"
    [srv_pref_off]="Saving the server list: OFF   (choose to turn it on)"
    [srv_c_local]="Check and score THIS server"
    [srv_c_remote]="Check and score a REMOTE server   (saved or new, over SSH)"
    [srv_c_remove]="Remove a saved server from the list"
    [where_title]="Where should the restore run?"
    [where_local]="This server   (default)"
    [where_remote]="A remote server over SSH   (saved list or a new one)"
    [tst_title]="TEST RESULT - the same checks a real migration relies on"
    [opt_c_servers]="Servers - check and score, saved list   (this server or a remote one)"
    [opt_c_stealth]="VPN stealth check - can an observer tell this is a VPN?"
)

declare -A T_FA=(
    [exit]="خروج"
    [yes]="بله"
    [no]="خیر"
    [bye]="خداحافظ"
    [back_to_menu]="به منوی اصلی برگشتید - کار دیگری انتخاب کنید یا برای خروج «خروج» را بزنید."
    [main_title]="مدیر هوشمند پنل‌های X-UI  (NX Panel · 3x-ui · Alireza · x-ui)"
    [opt_backup]="📦   ایجاد پشتیبان هوشمند          (روی سرور قدیمی)"
    [opt_restore]="🔄   مهاجرت / بازیابی              (روی سرور جدید)"
    [opt_install]="🔧   نصب پنل                      (NX Panel / 3x-ui / Alireza / x-ui)"
    [opt_update]="🚀   به‌روزرسانی پنل"
    [opt_inspect]="🔍   بررسی فایل پشتیبان            (کاربران، دامنه‌ها، اینباندها، نحوه سرویس‌دهی)"
    [inspect_title]="کدام فایل پشتیبان را می‌خواهید بررسی کنید؟"
    [opt_exit]="❌   خروج"
    [install_title]="کدام پنل را می‌خواهید نصب کنید؟"
    [deps_ok]="تمام ابزارهای لازم سیستم نصب هستند."
    [deps_missing]="ابزارهای زیر روی سیستم نصب نیستند:"
    [deps_ask]="بسته‌های موردنیاز الان نصب شوند؟"
    [deps_no_apt]="apt-get پیدا نشد. این بسته‌ها را دستی نصب کنید:"
    [deps_cancel]="بدون این ابزارها امکان ادامه نیست."
    [step_precheck]="بررسی‌های پیش از پشتیبان‌گیری"
    [step_gather]="جمع‌آوری فایل‌های پیکربندی"
    [step_compress]="ساخت آرشیو"
    [step_verify]="بررسی سلامت آرشیو"
    [step_deliver]="پشتیبان آماده است"
    [err_no_db]="فایل x-ui.db پیدا نشد. آیا X-UI روی این سرور نصب است؟"
    [pick_db]="چند دیتابیس X-UI پیدا شد - یکی را انتخاب کنید"
    [enc_title]="رمزگذاری فایل پشتیبان"
    [enc_ask]="فایل پشتیبان با رمز عبور (AES-256) رمزگذاری شود؟"
    [enc_pass_prompt]="رمز عبور پشتیبان (حداقل ۱۲ کاراکتر): "
    [enc_pass_confirm]="تکرار رمز عبور: "
    [enc_short]="رمز عبور باید حداقل ۱۲ کاراکتر باشد."
    [enc_mismatch]="رمزها یکسان نیستند - دوباره تلاش کنید."
    [enc_warn_plain]="پشتیبان بدون رمز: اطلاعات ورود پنل و کلیدهای خصوصی TLS به‌صورت آشکار در آن قرار می‌گیرد."
    [dec_pass_prompt]="رمز عبور پشتیبان: "
    [backup_ok]="پشتیبان با موفقیت ساخته شد."
    [backup_loc]="مسیر فایل"
    [sync_title]="انتقال مستقیم به سرور جدید"
    [sync_ask]="پشتیبان و این اسکریپت همین حالا به سرور جدید کپی شوند؟"
    [remote_addr]="آی‌پی یا دامنه سرور جدید: "
    [remote_user]="نام کاربری SSH [root]: "
    [remote_port]="پورت SSH [22]: "
    [remote_pass]="رمز عبور SSH: "
    [addr_retry]="یک IPv4 معتبر یا دامنه قابل‌تبدیل وارد کنید."
    [transferring]="سیستم در حال کار است: کپی فایل‌ها روی سرور ریموت - لطفاً صبر کنید، اتصال برقرار است..."
    [transfer_ok]="انتقال کامل شد - فایل‌ها در /root سرور جدید قرار گرفتند."
    [remote_launch]="منوی بازیابی همین حالا روی سرور جدید باز شود؟"
    [err_keyboard]="کاراکتر غیرانگلیسی تشخیص داده شد. صفحه‌کلید را انگلیسی کنید و دوباره وارد کنید."
    [err_empty]="ورودی نمی‌تواند خالی باشد."
    [restore_title]="مهاجرت - انتخاب عملیات"
    [opt_real]="🚀   مهاجرت واقعی - پنل مقصد را خودتان انتخاب می‌کنید (NX Panel فقط پیشنهاد می‌شود)"
    [opt_test]="🔬   تست بک‌آپ - بدون هیچ تغییری در سیستم"
    [opt_back]="بازگشت"
    [step_select]="انتخاب فایل پشتیبان"
    [step_validate]="استخراج و اعتبارسنجی پشتیبان"
    [step_preflight]="بررسی‌های اولیه سرور"
    [step_install]="پنل NX Panel"
    [step_migrate]="ویزارد رسمی مهاجرت"
    [step_target]="انتخاب پنل مقصد"
    [step_plan]="برنامه مهاجرت شما"
    [step_run]="در حال مهاجرت"
    [pick_backup]="پشتیبان مبدأ را انتخاب کنید"
    [err_no_backup]="هیچ آرشیو XUI_Backup_* در /root پیدا نشد."
    [test_passed]="تست موفق - پشتیبان خوانا است و دیتابیس آن سالم است."
    [test_nochange]="این تست هیچ تغییری در سیستم ایجاد نکرد."
    [real_confirm]="مهاجرت ادامه یابد؟ این کار می‌تواند نرم‌افزار نصب کند و سرور را تغییر دهد."
    [preflight_ask]="بررسی‌های اختیاری (سخت‌افزار، اعتبار IP، دامنه‌ها) انجام شود؟ به سرویس‌های خارجی متصل می‌شود."
    [pf_title]="گزارش زیرساخت سرور جدید"
    [pf_weak]="سخت‌افزار از حداقل پیشنهادی برای یک نود پروکسی ضعیف‌تر است."
    [pf_force]="با وجود ضعف سخت‌افزاری ادامه می‌دهید؟"
    [geo_title]="تحلیل کاربران هدف"
    [geo_ask]="کاربران از کدام کشور متصل می‌شوند؟"
    [dom_confirm]="وضعیت این دامنه‌ها را تأیید می‌کنید و مایل به ادامه هستید؟"
    [nx_install_ask]="NX Panel نصب/فعال نیست. با نصب‌کننده رسمی نصب شود؟"
    [nx_setup_done]="ویزارد راه‌اندازی NX Panel را کامل کرده‌اید و می‌توانید با حساب مدیر وارد شوید؟"
    [menu_hint]="↑/↓ حرکت · Enter انتخاب · 1-%d مستقیم"
    [menu_hint_back]=" · 0 / Esc بازگشت"
    [opt_back1]="🔙   بازگشت"
    [press_key]="برای بازگشت به منو یک کلید بزنید..."
    [opt_panels]="🔧   نصب / به‌روزرسانی پنل          (نصب‌شده روی این سرور: %s)"
    [opt_panels_none]="🔧   نصب / به‌روزرسانی پنل          (هنوز پنلی نصب نشده)"
    [opt_optimize]="🚀   بهینه‌سازی سیستم               (گواهی‌ها، پشتیبان‌های قدیمی، فایل‌های اضافه)"
    [opt_selfupdate]="🆙   به‌روزرسانی همین اسکریپت       (از گیت‌هاب)"
    [opt_exit_remote]="🔙   بازگشت به سرور اصلی  (%s)"
    [panels_title]="پنل‌های این سرور - نصب یا به‌روزرسانی"
    [optimize_title]="بهینه‌سازی سیستم"
    [selfupd_title]="به‌روزرسانی اسکریپت"
    [target_title]="انتخاب پنل مقصد"
    [target_hint]="NX Panel فقط یک پیشنهاد است؛ هر پنلی را می‌توانید انتخاب کنید، از جمله همان پنلی که پشتیبان از آن آمده است."
    [hdr_remote]="سرور ریموت"
    [hdr_remote_sub]="همه کارها روی همین سرور انجام می‌شود، نه روی سرور اصلی شما"
    [hdr_here]="اکنون روی"
    [opt_c_sysupd]="به‌روزرسانی کامل سیستم - apt update / upgrade / dist-upgrade / autoremove / autoclean"
    [sysupd_title]="به‌روزرسانی کامل سیستم"
    [sysupd_note_title]="پیش از ادامه"
    [sysupd_note1]="بسته‌ها در پس‌زمینه دانلود و نصب می‌شوند و فقط موارد مهم نمایش داده می‌شود."
    [sysupd_note2]="سرویس‌ها خودکار راه‌اندازی مجدد نمی‌شوند. به‌روزرسانی هسته بعد از ری‌استارت فعال می‌شود."
    [sysupd_ask]="همین حالا این سرور به‌روزرسانی شود؟"
    [sysupd_reboot]="سرور همین حالا ری‌استارت شود؟"
    [w_sysupd]="به‌روزرسانی کامل سیستم"
    [bye_title]="خدانگهدار - از اینکه از MOC Networks استفاده کردید سپاسگزاریم."
    [bye_remote]="بستن نشست ریموت - بازگشت به %s."
    [bye_line]="سرورهایتان همیشه سریع، پایدار و دور از چشم باد."
    [ssh_auth]="ورود از طریق SSH - اگر رمز خواسته شد وارد کنید (فقط یک بار استفاده و هرگز ذخیره نمی‌شود)..."
    [ssh_ok]="وارد شدید. اتصال باز می‌ماند و دوباره رمز پرسیده نمی‌شود."
    [ssh_fail]="ورود با SSH ناموفق بود. آدرس، کاربر، پورت و رمز / کلید را بررسی کنید."
    [ssh_working_probe]="سیستم در حال کار است: بررسی سرور ریموت (سخت‌افزار، شبکه، دسترسی به GitHub، سرعت) - حدود ۴۰ ثانیه. اتصال برقرار است، لطفاً صبر کنید..."
    [remote_starting]="سیستم در حال کار است: اجرای برنامه روی سرور ریموت - چند ثانیه دیگر صفحه تازه می‌شود، اتصال قطع نشده است."
    [ip_internal]="داخلی"
    [ip_internal_only]="داخلی، IP عمومی پیدا نشد"
    [hdr_from]="آمده‌اید از"
    [hdr_goback]="برای بازگشت"
    [hdr_goback_txt]="Esc / 0 = عقب  ·  منوی اصلی: Esc / 0 یا آخرین گزینه = سرور اصلی"
    [hdr_local]="سرور محلی"
    [rw_title]="سرور ریموت - پیش از ادامه دوباره بررسی کنید"
    [rw_l1]="«%s» روی همین سرور ریموت اجرا می‌شود:  %s"
    [rw_l2]="سرور اصلی شما - %s - در این کار دست‌نخورده می‌ماند."
    [rw_ask]="«%s» روی همین سرور ریموت اجرا شود؟"
    [w_backup]="پشتیبان‌گیری"
    [w_restore]="مهاجرت / بازیابی"
    [w_optimize]="بهینه‌سازی سیستم"
    [w_update]="به‌روزرسانی %s"
    [w_install]="نصب %s"
    [rl_title]="خروج از سرور ریموت"
    [rl_body]="به سرور اصلی خود (%s) برمی‌گردید و نشست ریموت بسته می‌شود."
    [rl_ask]="اکنون به سرور اصلی برگردید؟"
    [panels_none]="هیچ پنل پشتیبانی‌شده‌ای روی این سرور پیدا نشد - یکی را برای نصب انتخاب کنید."
    [pn_update]="به‌روزرسانی %s"
    [pn_other]="نصب پنل دیگر، یا نصب دوباره یکی از آنها…"
    [pn_install]="نصب %s"
    [choose_action]="یک کار را انتخاب کنید"
    [opt_c_certs]="🔐   گواهی‌ها - حذف منقضی‌شده / بدون استفاده   (%s منقضی · %s بی‌استفاده)"
    [opt_c_backups]="💾   فایل‌های پشتیبان قدیمی - فقط جدیدترین‌ها بمانند   (%s فایل · %s)"
    [opt_c_left]="📁   نسخه‌های بازگشت و فایل‌های اضافه   (%s مورد · %s)"
    [opt_c_scan]="🔄   بررسی دوباره"
    [q_del_certs]="این %s گواهی حذف شود؟ پیش از آن یک نسخه بازگشت ذخیره می‌شود."
    [q_del_bk]="%s فایل پشتیبان قدیمی حذف شود و %s فضا آزاد شود؟"
    [q_del_left]="این %s مورد حذف شود و %s فضا آزاد شود؟"
    [w_keep_off]="پیش از حذف، دست‌کم یک نسخه را خارج از این سرور (کامپیوتر خودتان یا فضای ابری) نگه دارید."
    [w_rollback]="نسخه‌های بازگشت راه برگشت شما پس از بازیابی یا به‌روزرسانی هستند؛ فقط وقتی سامانه جدید درست کار می‌کند حذف‌شان کنید."
    [q_which_certs]="کدام گواهی‌ها حذف شوند؟"
    [o_certs_safe]="منقضی‌شده و بدون استفاده در پنل / Nginx   (امن)"
    [o_certs_all]="همه گواهی‌هایی که هیچ‌چیز از آن‌ها استفاده نمی‌کند   (شامل معتبرها)"
    [q_keep_n]="چند فایل پشتیبان جدیدتر نگه داشته شود؟"
    [o_keep_n]="نگه‌داشتن %s فایل جدیدترین"
    [o_recommended]="(پیشنهادی)"
    [srv_save_title]="سرورهای مورد استفاده‌تان ذخیره شود؟"
    [srv_save_info]="این برنامه می‌تواند فهرست سرورهایتان (نام، آدرس، پورت SSH، وضعیت، امتیاز و موقعیت مکانی) را به‌صورت کدشده در یک فایل روی همین سرور (/etc/moc-networks/servers.dat) نگه دارد تا دفعه بعد به‌جای تایپ، یکی را انتخاب کنید. هیچ رمز عبوری ذخیره نمی‌شود، فقط همین مشخصات."
    [srv_save_ask]="فهرست سرورها برای دفعه بعد ذخیره شود؟"
    [srv_save_yes]="ذخیره شد. فهرست به‌صورت کدشده در /etc/moc-networks/servers.dat است (فقط مشخصات، بدون رمز عبور)."
    [srv_save_no]="چیزی ذخیره نمی‌شود. بعداً از بهینه‌سازی سیستم ← سرورها می‌توانید آن را روشن کنید."
    [srv_title]="سرورها - بررسی، امتیازدهی و مدیریت"
    [srv_never]="ذخیره می‌شود: نام، آدرس، پورت SSH، وضعیت، امتیاز، موقعیت.  ذخیره نمی‌شود: رمز عبور."
    [srv_none]="هنوز سروری ذخیره نشده. یک سرور را بررسی کنید تا اینجا بیاید (اگر ذخیره روشن باشد)."
    [srv_which]="کدام سرور؟"
    [srv_new]="ورود سرور جدید"
    [srv_back_hint]="در هر پرسش عدد 0 را بزنید تا برگردید."
    [srv_check_first]="ابتدا این سرور بررسی و امتیازدهی شود (سخت‌افزار، شبکه، NAT، دسترسی گیت‌هاب)؟"
    [srv_pref_on]="ذخیره فهرست سرورها: روشن   (برای خاموش‌کردن انتخاب کنید)"
    [srv_pref_off]="ذخیره فهرست سرورها: خاموش   (برای روشن‌کردن انتخاب کنید)"
    [srv_c_local]="بررسی و امتیازدهی همین سرور"
    [srv_c_remote]="بررسی و امتیازدهی یک سرور ریموت   (ذخیره‌شده یا جدید، با SSH)"
    [srv_c_remove]="حذف یک سرور ذخیره‌شده از فهرست"
    [where_title]="بازیابی روی کدام سرور انجام شود؟"
    [where_local]="همین سرور   (پیش‌فرض)"
    [where_remote]="یک سرور ریموت با SSH   (از فهرست ذخیره‌شده یا جدید)"
    [tst_title]="نتیجه تست - همان بررسی‌هایی که مهاجرت واقعی به آن‌ها تکیه دارد"
    [opt_c_servers]="سرورها - بررسی و امتیازدهی، فهرست ذخیره‌شده   (همین سرور یا ریموت)"
    [opt_c_stealth]="بررسی پنهان‌بودن VPN - آیا ناظر بیرونی تشخیص می‌دهد این VPN است؟"
)

t() {
    local k=$1
    if [[ $UI_LANG == FA && -n ${T_FA[$k]:-} ]]; then
        printf '%s%s' "$LRM" "${T_FA[$k]}"
    else
        printf '%s' "${T_EN[$k]:-$k}"
    fi
}

# ── Input & menus ─────────────────────────────────────────────────────────────
# Persian/Arabic-Indic digits -> ASCII digits (pure bash, locale independent).
sanitize_input() {
    local s=$1 i
    local -a fa=(۰ ۱ ۲ ۳ ۴ ۵ ۶ ۷ ۸ ۹) ar=(٠ ١ ٢ ٣ ٤ ٥ ٦ ٧ ٨ ٩)
    for i in {0..9}; do
        s=${s//"${fa[i]}"/$i}
        s=${s//"${ar[i]}"/$i}
    done
    printf '%s' "$s"
}

# True when the string holds anything outside printable ASCII (works in any locale).
has_non_ascii() {
    local LC_ALL=C
    [[ $1 == *[![:print:]]* ]]
}

trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

# prompt_input <prompt> [secret 0|1] [default]   -> INPUT_VALUE
prompt_input() {
    local prompt=$1 secret=${2:-0} default=${3-} raw
    while true; do
        if [[ $secret == 1 ]]; then
            read -r -s -p " ${C_CYAN}❯${C_RESET} ${prompt}" raw || return 1
            printf '\n'
        else
            read -r -p " ${C_CYAN}❯${C_RESET} ${prompt}" raw || return 1
            raw=$(sanitize_input "$raw")       # never rewrite secrets
        fi
        if [[ -z $raw ]]; then
            if [[ -n $default ]]; then INPUT_VALUE=$default; return 0; fi
            ui_err "$(t err_empty)"; continue
        fi
        if has_non_ascii "$raw"; then
            ui_err "$(t err_keyboard)"; continue
        fi
        INPUT_VALUE=$raw
        return 0
    done
}

cursor_row() {   # prints the terminal row of the cursor (asks the terminal); fails if it does not answer
    local pos='' old rc=0
    old=$(stty -g 2>/dev/null) || old=''
    [[ -n $old ]] && stty -echo 2>/dev/null          # the reply must never be echoed on screen
    printf '\033[6n' >&2
    # shellcheck disable=SC2034
    IFS= read -rs -t 0.5 -d 'R' pos 2>/dev/null || rc=1
    [[ -n $old ]] && stty "$old" 2>/dev/null
    (( rc == 0 )) || return 1
    pos=${pos##*[}
    [[ ${pos%%;*} =~ ^[0-9]+$ ]] || return 1
    printf '%s' "${pos%%;*}"
}

# Menu text markup: \x01 ... \x02 marks highlighted data (names, counts, hosts); a trailing "  (note)" is shown in a softer colour.
mk_strip() { local x=$1; x=${x//$'\x01'/}; x=${x//$'\x02'/}; printf '%s' "$x"; }
mk_color() {   # mk_color <text> <base-color>   (used for titles and the one-line summary)
    local x=$1 base=${2:-}
    x=${x//$'\x01'/${C_ACC}}; x=${x//$'\x02'/${C_RESET}${base}}
    printf '%s' "$x"
}
menu_colorize() {   # menu_colorize <row-text> <is-first-row 0|1>  -> MCL
    local x=$1 head tail='' note="$C_NOTE"
    (( $2 )) && MC_TAIL=0
    if (( MC_TAIL )); then head=''; tail=$x
    elif [[ $x == *'  ('* ]]; then head=${x%%'  ('*}; tail="  (${x#*'  ('}"; MC_TAIL=1
    else head=$x; fi
    head=${head//$'\x01'/${C_ACC}}; head=${head//$'\x02'/${C_RESET}}
    tail=${tail//$'\x01'/${C_RESET}${C_ACC}}; tail=${tail//$'\x02'/${C_RESET}${note}}
    MCL="${head}${C_RESET}"
    [[ -n $tail ]] && MCL+="${note}${tail}${C_RESET}"
}

# menu_opt_rows <index> <phase>  -> MOR   (rows of one option; uses menu_select's variables)
menu_opt_rows() {
    local i=$1 phase=$2 j num mark parts label row_start
    local -a prow=()
    IFS=$'\x1f' read -ra prow <<<"${owrap[i]}"
    printf -v num '%*d' "$nw" "$(( i + 1 ))"
    MOR=''
    for (( j = 0; j < ${#prow[@]}; j++ )); do
        label=${prow[j]}
        if (( j == 0 )); then
            if (( i == selected )); then
                if (( ANIM )); then mark=$'\e[1;38;5;51m❯'$'\e[0m'; else mark="${C_GREEN}${C_BOLD}❯${C_RESET}"; fi
                row_start=" ${C_CYAN}│${C_RESET}  ${mark} ${num}  "
            else
                row_start=" ${C_CYAN}│${C_RESET}    ${C_BLUE}${num}${C_RESET}  "
            fi
        else
            row_start=" ${C_CYAN}│${C_RESET}    $(printf '%*s' "$nw" '')  "
        fi
        if (( i == selected )); then
            label=$(mk_strip "$label")
            if (( ANIM )); then shimmer "$label" "$phase" 37 $(( j * 3 )); label=$SHIM
            else label="${C_GREEN}${C_BOLD}${label}${C_RESET}"; fi
        else
            menu_colorize "$label" "$(( j == 0 ))"; label=$MCL
        fi
        (( j > 0 )) && MOR+=$'\n'
        MOR+="${LRM}${row_start}${LRM}${label}"
    done
}

# menu_frame <phase> -> FRAME   (the whole menu block, ends with a newline)
menu_frame() {
    local phase=$1 i j
    FRAME="${LRM} ${C_CYAN}╭─ ${C_BOLD}${C_WHITE}$(mk_color "${twrap[0]}" "${C_BOLD}${C_WHITE}")${C_RESET}"$'\n'
    for (( j = 1; j < ${#twrap[@]}; j++ )); do
        FRAME+="${LRM} ${C_CYAN}│${C_RESET}  ${C_BOLD}${C_WHITE}$(mk_color "${twrap[j]}" "${C_BOLD}${C_WHITE}")${C_RESET}"$'\n'
    done
    FRAME+="${LRM} ${C_CYAN}│${C_RESET}"$'\n'
    for (( i = 0; i < count; i++ )); do
        menu_opt_rows "$i" "$phase"
        FRAME+="${MOR}"$'\n'
    done
    FRAME+="${LRM} ${C_CYAN}│${C_RESET}"$'\n'
    FRAME+="${LRM} ${C_CYAN}╰─ ${hint}${C_RESET}"$'\n'
}

# menu_select <title> <default-index> <option>...   -> MENU_RESULT (1-based)
# Left-bar layout (no right border): emoji / Persian text can never break alignment.
# Long labels WRAP (never truncated). The selected row shimmers; the logo above keeps animating.
# With MENU_HAS_BACK=1 the LAST option is a "Back" entry that Esc, 0 and b also choose.
menu_select() {
    local title=$1 selected=$(( $2 - 1 )) i key seq rc count lines phase=0 back=${MENU_HAS_BACK:-0}
    local nw lw tw hdr_ok=0 row hint sum out
    shift 2
    local -a opts=("$@") owrap=() oh=() ostart=() twrap=() wl=() parts=()
    count=${#opts[@]}
    (( count > 0 )) || return 1
    (( selected >= 0 && selected < count )) || selected=0

    if [[ ! -t 0 || ! -t 2 ]]; then          # non-interactive fallback
        local fallback
        printf '%s\n' "$(mk_strip "$title")" >&2
        for (( i = 0; i < count; i++ )); do printf '  [%d] %s\n' "$((i + 1))" "$(mk_strip "${opts[i]}")" >&2; done
        read -r -p 'Select number: ' fallback || return 1
        fallback=$(sanitize_input "$fallback")
        [[ $fallback =~ ^[0-9]+$ ]] && (( fallback >= 1 && fallback <= count )) || return 1
        MENU_RESULT=$fallback
        return 0
    fi

    nw=${#count}; lw=$(( UI_COLS - 10 - nw )); tw=$(( UI_COLS - 6 ))
    mapfile -t wl < <(pywrap "$lw" "${opts[@]}")
    IFS=$'\x1f' read -ra twrap < <(pywrap "$tw" "$title")
    (( ${#twrap[@]} > 0 )) || twrap=("$title")
    sum=0
    for (( i = 0; i < count; i++ )); do
        owrap[i]=${wl[i]:-${opts[i]}}
        IFS=$'\x1f' read -ra parts <<<"${owrap[i]}"
        oh[i]=${#parts[@]}; (( oh[i] > 0 )) || oh[i]=1
        ostart[i]=$(( ${#twrap[@]} + 1 + sum ))
        sum=$(( sum + oh[i] ))
    done
    lines=$(( ${#twrap[@]} + sum + 3 ))
    printf -v hint "$(t menu_hint)" "$(( count > 9 ? 9 : count ))"
    (( back )) && hint+="${MENU_BACK_HINT:-$(t menu_hint_back)}"

    if (( ANIM && HDR_VALID )); then          # animate the logo only if nothing has scrolled it away
        row=$(cursor_row) || row=0
        (( row > 0 && row + lines <= ROWS - PB_ON )) && hdr_ok=1
    fi

    printf '\033[?25l' >&2
    menu_frame "$phase"; printf '%s' "$FRAME" >&2
    while true; do
        if (( ANIM )); then
            IFS= read -rsn1 -t 0.1 key; rc=$?
            if (( rc > 128 )); then              # timeout = animation tick
                phase=$(( phase + 1 ))
                out=$'\e7'
                if (( hdr_ok )); then header_paint "$phase"; out+=$HP_OUT$'\e8\e7'; fi   # back to the saved spot (and save it again) before moving up
                menu_opt_rows "$selected" "$phase"
                out+=$'\e['$(( lines - ostart[selected] ))$'A\r'"$MOR"$'\e8'
                printf '%s' "$out" >&2
                continue
            fi
            (( rc == 0 )) || { printf '\033[?25h' >&2; return 1; }
        else
            IFS= read -rsn1 key || { printf '\033[?25h' >&2; return 1; }
        fi
        case $key in
            $'\x1b')
                seq=''
                IFS= read -rsn2 -t 0.05 seq || true
                case $seq in
                    '[A'|'OA') (( selected = (selected - 1 + count) % count )) ;;
                    '[B'|'OB') (( selected = (selected + 1) % count )) ;;
                    '') if (( back )); then selected=$(( count - 1 )); break; fi ;;
                esac ;;
            k) (( selected = (selected - 1 + count) % count )) ;;
            j) (( selected = (selected + 1) % count )) ;;
            0|b|B) if (( back )); then selected=$(( count - 1 )); break; fi ;;
            '') break ;;
            [1-9])
                if (( key <= count )); then selected=$(( key - 1 )); break; fi ;;
        esac
        printf '\033[%dA\r\033[J' "$lines" >&2
        menu_frame "$phase"; printf '%s' "$FRAME" >&2
    done
    # Collapse the menu into a single summary line.
    printf '\033[%dA\r\033[J\033[?25h' "$lines" >&2
    local lab=${owrap[selected]//$'\x1f'/ } sumt
    sumt=$lab
    (( ${#twrap[@]} == 1 && ( ${#twrap[0]} <= 36 || ${MENU_SUM_TITLE:-0} ) )) && sumt="${twrap[0]}  →  ${lab}"
    say "$C_GREEN" "$I_OK" "$(mk_color "$sumt" "$C_GREEN")" 2
    MENU_RESULT=$(( selected + 1 ))
    return 0
}

# menu_select_b <title> <default> <option>...  - same, plus a trailing "Back" entry. Returns 3 when Back was chosen.
menu_select_b() {
    local title=$1 def=$2 n
    shift 2
    n=$(( $# + 1 ))
    MENU_HAS_BACK=1 menu_select "$title" "$def" "$@" "$(t opt_back1)" || return 1
    (( MENU_RESULT == n )) && return 3
    return 0
}

# confirm <question> [y|n default]  -> exit status 0 = yes. Default is NO for safety (Esc / 0 = no).
confirm() {
    local def=2
    [[ ${2:-n} == y ]] && def=1
    MENU_SUM_TITLE=1 MENU_BACK_HINT=" · 0 / Esc = $(t no)" MENU_HAS_BACK=1 menu_select "$1" "$def" "$(t yes)" "$(t no)" || return 1
    [[ $MENU_RESULT == 1 ]]
}

# ── Validation & security helpers ─────────────────────────────────────────────
valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

is_ipv4() {
    local ip=$1 o IFS=.
    local -a parts
    [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    read -ra parts <<<"$ip"
    for o in "${parts[@]}"; do (( 10#$o <= 255 )) || return 1; done
    return 0
}

# Accepts an IPv4 or a hostname; sets RESOLVED_IP. Errors are printed here.
resolve_destination() {
    local raw re
    raw=$(trim "$1")
    re='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\.?$'
    RESOLVED_IP=""
    if [[ -z $raw ]]; then ui_err "Address cannot be empty."; return 1; fi
    if [[ $raw == *"://"* || $raw == */* || $raw == *:* || $raw == *[[:space:]]* ]]; then
        ui_err "Enter only an IPv4 address or hostname (no scheme, port or path)."; return 1
    fi
    if is_ipv4 "$raw"; then RESOLVED_IP=$raw; return 0; fi
    if (( ${#raw} > 253 )) || ! [[ $raw =~ $re ]]; then
        ui_err "Invalid address. Example: 203.0.113.10 or server.example.com"; return 1
    fi
    command -v getent >/dev/null 2>&1 || { ui_err "getent is unavailable - enter the IPv4 address instead."; return 1; }
    RESOLVED_IP=$(getent ahostsv4 "$raw" 2>/dev/null | awk 'NR==1 {print $1; exit}')
    if [[ -z $RESOLVED_IP ]]; then ui_err "'$raw' could not be resolved to an IPv4 address."; return 1; fi
    ui_ok "Resolved ${raw} -> ${RESOLVED_IP}"
    return 0
}

# validate_archive_safety <archive> [allowed-root]
# Rejects absolute paths, traversal, special files, oversized archives and any link that
# escapes <allowed-root>. An empty root denies all links (used for downloaded tools).
validate_archive_safety() {
    local archive=$1 root=${2-}
    command -v python3 >/dev/null 2>&1 || { ui_err "python3 is required for archive validation."; return 1; }
    python3 - "$archive" "$root" <<'PYARCH'
import posixpath, stat, sys, tarfile, zipfile
path, root = sys.argv[1], sys.argv[2]
MAX_TOTAL = 8 * 1024 ** 3
total = 0

def safe_name(name):
    name = name.replace(chr(92), '/').rstrip('/')
    if not name or name.startswith('/'):
        return False
    return all(part not in ('..', '') for part in name.split('/'))

def safe_link(name, target, hard=False):
    target = target.replace(chr(92), '/')
    if not root or not target or target.startswith('/'):
        return False
    base = '' if hard else posixpath.dirname(name)
    resolved = posixpath.normpath(posixpath.join(base, target))
    return resolved == root or resolved.startswith(root + '/')

try:
    if path.endswith('.zip'):
        with zipfile.ZipFile(path) as z:
            for i in z.infolist():
                total += i.file_size
                if not safe_name(i.filename):
                    raise ValueError('unsafe path: ' + i.filename)
                mode = (i.external_attr >> 16) & 0xffff
                if stat.S_ISLNK(mode):
                    if not safe_link(i.filename.rstrip('/'), z.read(i).decode('utf-8', 'strict')):
                        raise ValueError('unsafe symlink: ' + i.filename)
                elif mode and not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
                    raise ValueError('special file: ' + i.filename)
    else:
        with tarfile.open(path, 'r:gz') as t:
            for m in t.getmembers():
                total += max(m.size, 0)
                if not safe_name(m.name):
                    raise ValueError('unsafe path: ' + m.name)
                if m.issym():
                    if not safe_link(m.name.rstrip('/'), m.linkname):
                        raise ValueError('unsafe symlink: %s -> %r' % (m.name, m.linkname))
                elif m.islnk():
                    if not safe_link(m.name.rstrip('/'), m.linkname, True):
                        raise ValueError('unsafe hard link: %s -> %r' % (m.name, m.linkname))
                elif not (m.isfile() or m.isdir()):
                    raise ValueError('special file: ' + m.name)
    if total > MAX_TOTAL:
        raise ValueError('archive expands to more than 8 GiB')
except Exception as e:
    print('Archive safety validation failed: ' + str(e), file=sys.stderr)
    sys.exit(1)
PYARCH
}

decrypt_archive() {   # decrypt_archive <in> <out> <password>
    XUI_BK_PASS=$3 openssl enc -d -aes-256-cbc -pbkdf2 -iter "$PBKDF2_ITER" \
        -pass env:XUI_BK_PASS -in "$1" -out "$2" 2>/dev/null
}

create_archive() {    # create_archive <workdir> <outfile> <encrypt 0|1> <password>
    local work=$1 out=$2 enc=$3 pass=$4
    if [[ $enc == 1 ]]; then
        tar -C "$work" -czf - "$ARCHIVE_ROOT" |
            XUI_BK_PASS=$pass openssl enc -aes-256-cbc -pbkdf2 -iter "$PBKDF2_ITER" -salt \
                -pass env:XUI_BK_PASS -out "$out"
    else
        tar -C "$work" -czf "$out" "$ARCHIVE_ROOT"
    fi
}

verify_plain_tar() {  # gzip CRC + safety + must contain the panel database
    local f=$1 listing
    gzip -t "$f" 2>/dev/null || return 1
    validate_archive_safety "$f" "$ARCHIVE_ROOT" || return 1
    listing=$(mktemp) || return 1
    if ! tar -tzf "$f" >"$listing" 2>/dev/null; then rm -f -- "$listing"; return 1; fi
    grep -x "$ARCHIVE_ROOT/panel/x-ui.db" "$listing" >/dev/null
    local rc=$?
    rm -f -- "$listing"
    return "$rc"
}

# ── Dependencies ──────────────────────────────────────────────────────────────
declare -A PKG_FOR=(
    [sqlite3]=sqlite3 [python3]=python3 [openssl]=openssl [curl]=curl [tar]=tar
    [gzip]=gzip [unzip]=unzip [dig]=dnsutils [ssh]=openssh-client [scp]=openssh-client
    [sha256sum]=coreutils [awk]=gawk [getent]=libc-bin [ping]=iputils-ping
)
MISSING_PKGS=()

collect_missing() {
    local c p
    MISSING_PKGS=()
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 && continue
        p=${PKG_FOR[$c]:-$c}
        [[ " ${MISSING_PKGS[*]:-} " == *" $p "* ]] || MISSING_PKGS+=("$p")
    done
}

# Offers to install missing tools (backup workflow only).
ensure_tools() {
    local pkg
    collect_missing "$@"
    if (( ${#MISSING_PKGS[@]} == 0 )); then ui_ok "$(t deps_ok)"; return 0; fi
    ui_warn "$(t deps_missing) ${MISSING_PKGS[*]}"
    command -v apt-get >/dev/null 2>&1 || die "$(t deps_no_apt) ${MISSING_PKGS[*]}"
    confirm "$(t deps_ask)" y || die "$(t deps_cancel)"
    export DEBIAN_FRONTEND=noninteractive
    run_task "apt-get update" apt-get update -y || die "apt repository update failed."
    for pkg in "${MISSING_PKGS[@]}"; do
        run_task "Installing ${pkg}" apt-get install -y --no-install-recommends "$pkg" || die "Failed to install ${pkg}."
    done
}

# Never installs anything (migration/test workflow) - only reports.
require_tools() {
    collect_missing "$@"
    (( ${#MISSING_PKGS[@]} == 0 )) && return 0
    ui_err "Missing tools: ${MISSING_PKGS[*]}"
    ui_info "Install them manually:  apt-get install -y ${MISSING_PKGS[*]}"
    return 1
}

# ── Pre-flight checks (advisory) ──────────────────────────────────────────────
CPU_CORES=1 RAM_MB=0 DISK_TOTAL_GB=0 DISK_FREE_GB=0 OS_NAME="Linux"
PUB_IP="" PUB_COUNTRY="" PUB_CC="" SPEED_MBPS=""

json_field() { python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1" 2>/dev/null; }

country_flag() {
    [[ $ICON_STYLE == safe ]] && return 0
    [[ $1 =~ ^[A-Za-z]{2}$ ]] || { printf '🌐'; return; }
    python3 -c 'import sys; print("".join(chr(0x1F1E6 + ord(c) - 65) for c in sys.argv[1].upper()))' "$1" 2>/dev/null || printf '🌐'
}


compute_score() {     # prints a score 0-100
    local s=0 ram_gb=$(( (RAM_MB + 512) / 1024 ))
    if   (( CPU_CORES >= 4 )); then s=$(( s + 25 )); elif (( CPU_CORES >= 2 )); then s=$(( s + 15 )); else s=$(( s + 5 )); fi
    if   (( ram_gb >= 16 )); then s=$(( s + 25 )); elif (( ram_gb >= 8 )); then s=$(( s + 20 ));
    elif (( ram_gb >= 4 ));  then s=$(( s + 12 )); else s=$(( s + 5 )); fi
    if (( DISK_TOTAL_GB >= 80 )); then s=$(( s + 25 )); else s=$(( s + 5 )); fi
    if [[ -z $SPEED_MBPS ]]; then s=$(( s + 10 ))
    elif (( SPEED_MBPS >= 800 )); then s=$(( s + 25 ))
    elif (( SPEED_MBPS >= 100 )); then s=$(( s + 15 )); else s=$(( s + 5 )); fi
    printf '%d' "$s"
}

check_blacklists() {
    local ip=$1 a b c d rev bl ans label color
    is_ipv4 "$ip" || { ui_warn "Public IPv4 unknown - blacklist check skipped."; return 0; }
    command -v dig >/dev/null 2>&1 || { ui_warn "dig not installed - blacklist check skipped (apt-get install dnsutils)."; return 0; }
    IFS=. read -r a b c d <<<"$ip"
    rev="${d}.${c}.${b}.${a}"
    ui_section "IP reputation (DNSBL)"
    for bl in zen.spamhaus.org bl.spamcop.net psbl.surriel.com dnsbl.dronebl.org; do
        ans=$(dig +short +time=2 +tries=1 "${rev}.${bl}" A 2>/dev/null | head -n 1)
        if   [[ $ans == 127.255.255.* ]]; then label="UNKNOWN (public resolver refused)"; color=$C_YELLOW
        elif [[ $ans == 127.* ]];         then label="LISTED";                          color=$C_RED
        else                                   label="CLEAN";                           color=$C_GREEN
        fi
        printf ' %s▌%s %-24s %s%s%s\n' "$C_CYAN" "$C_RESET" "$bl" "$color" "$label" "$C_RESET"
    done
    ui_info "DNSBLs mainly reflect e-mail reputation; treat them as advisory for a proxy node."
}

extract_domains() {   # prints SNI / Host domains found in the inbounds, one per line
    python3 - "$1" <<'PYDOM'
import json, re, sqlite3, sys, urllib.parse
keys = {"serverName", "sni", "host", "Host"}
dom = re.compile(r"[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
out = set()
def walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k in keys and isinstance(v, str):
                for part in v.split(","):
                    part = part.strip()
                    if dom.fullmatch(part):
                        out.add(part.lower())
            else:
                walk(v)
    elif isinstance(o, list):
        for i in o:
            walk(i)
try:
    con = sqlite3.connect("file:%s?mode=ro" % urllib.parse.quote(sys.argv[1]), uri=True)
    for (raw,) in con.execute("SELECT stream_settings FROM inbounds"):
        try:
            walk(json.loads(raw))
        except Exception:
            pass
except Exception:
    pass
print("\n".join(sorted(out)))
PYDOM
}

audit_domains() {     # audit_domains <db>   -> 1 if the user declines to proceed
    local db=$1 resolver dom answer ping_out avg jit status color n=0
    local -a domains=()
    local -a resolvers=(178.22.122.100 77.88.8.8 223.5.5.5 8.8.8.8)
    command -v dig >/dev/null 2>&1 || { ui_warn "dig not installed - domain audit skipped."; return 0; }
    mapfile -t domains < <(extract_domains "$db")
    (( ${#domains[@]} > 0 )) && [[ -n ${domains[0]} ]] || { ui_info "No SNI/Host domains found in the inbounds."; return 0; }

    ui_section "$(t geo_title)"
    menu_select_b "$(t geo_ask)" 1 "🇮🇷   Iran" "🇷🇺   Russia" "🇨🇳   China" "🌐   Generic (8.8.8.8)" || { ui_info "Domain audit skipped."; return 0; }
    resolver=${resolvers[MENU_RESULT-1]}

    printf '\n %s%-34s %-12s %-12s %s%s\n' "$C_DIM" "DOMAIN" "DNS" "LATENCY" "JITTER" "$C_RESET"
    for dom in "${domains[@]}"; do
        (( ++n > 25 )) && { ui_info "Only the first 25 domains are tested."; break; }
        answer=$(dig +short +time=2 +tries=1 "@${resolver}" "$dom" 2>/dev/null | head -n 1)
        avg="-"; jit="-"
        if [[ -z $answer ]]; then
            status="NO ANSWER"; color=$C_RED
        elif [[ $answer == 10.* || $answer == 127.* || $answer == 0.* ]]; then
            status="SUSPECT"; color=$C_YELLOW
        else
            status="DNS OK"; color=$C_GREEN
            if ping_out=$(ping -c 3 -W 2 "$dom" 2>/dev/null); then
                avg=$(awk -F/ 'END {printf "%.1f ms", $5}' <<<"$ping_out")
                jit=$(awk -F/ 'END {split($7, a, " "); printf "%.1f ms", a[1]}' <<<"$ping_out")
            else
                avg="timeout"; jit="timeout"
            fi
        fi
        printf ' %s▌%s %-34.34s %s%-12s%s %-12s %s\n' "$C_CYAN" "$C_RESET" "$dom" "$color" "$status" "$C_RESET" "$avg" "$jit"
    done
    ui_info "These are DNS answers from the chosen resolver and ping from THIS server; they cannot prove reachability inside the target country."
    confirm "$(t dom_confirm)" y
}

SP_HOST="" SP_KERNEL="" SP_ARCH="" SP_VIRT="" SP_UPTIME="" SP_L1="0" SP_L5="0" SP_L15="0" SP_CPU_MODEL="" SP_RAM_AVAIL=0 SP_SWAP_MB=0
SP_DISK_USED_GB=0 SP_DISK_PCT=0 SP_TZ="" SP_NTP="" SP_CC="" SP_QDISC="" SP_FW="" SP_SSH_PORT="" SP_P80="" SP_P443="" SP_LISTEN=0
SP_IPV6="" SP_REBOOT=0 SP_F2B="" SP_NGINX="" SP_CERTBOT="" SP_DOCKER="" SP_RTT="" SP_CITY="" SP_ISP="" SP_ASN="" SP_PANELS=""

or_else() {   # or_else <value> <suffix> <fallback> [prefix]  -> "prefix value suffix", or the fallback when empty
    if [[ -n $1 ]]; then printf '%s%s%s' "${4:-}" "$1" "$2"; else printf '%s' "$3"; fi
}

port_owner() {   # port_owner <port> -> process name listening on it, or empty
    ss -H -ltnp "sport = :$1" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -n 1
}

collect_specs() {
    local json='' bps k v mem_avail
    SP_HOST=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown)
    SP_KERNEL=$(uname -r); SP_ARCH=$(uname -m)
    SP_VIRT=$(systemd-detect-virt 2>/dev/null || true); [[ -n $SP_VIRT ]] || SP_VIRT="unknown"
    SP_UPTIME=$(uptime -p 2>/dev/null | sed 's/^up //'); : "${SP_UPTIME:=unknown}"
    read -r SP_L1 SP_L5 SP_L15 _ </proc/loadavg 2>/dev/null || true
    SP_CPU_MODEL=$(awk -F: '/model name/ {sub(/^ +/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null)
    CPU_CORES=$(nproc 2>/dev/null || echo 1)
    RAM_MB=$(awk '/^MemTotal:/ {printf "%d", $2 / 1024}' /proc/meminfo 2>/dev/null)
    mem_avail=$(awk '/^MemAvailable:/ {printf "%d", $2 / 1024}' /proc/meminfo 2>/dev/null)
    SP_SWAP_MB=$(awk '/^SwapTotal:/ {printf "%d", $2 / 1024}' /proc/meminfo 2>/dev/null)
    read -r DISK_TOTAL_GB DISK_FREE_GB SP_DISK_USED_GB SP_DISK_PCT < <(df -BG --output=size,avail,used,pcent / 2>/dev/null | awk 'NR==2 {gsub(/[G%]/, ""); print $1, $2, $3, $4}')
    : "${DISK_TOTAL_GB:=0}" "${DISK_FREE_GB:=0}" "${SP_DISK_USED_GB:=0}" "${SP_DISK_PCT:=0}" "${RAM_MB:=0}" "${mem_avail:=0}" "${SP_SWAP_MB:=0}"
    SP_RAM_AVAIL=$mem_avail
    OS_NAME=$(grep -m1 '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')
    : "${OS_NAME:=Linux}"
    SP_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    SP_NTP=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
    SP_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    SP_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then SP_FW="ufw (active)"
    elif systemctl is-active --quiet firewalld 2>/dev/null; then SP_FW="firewalld (active)"
    elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q 'chain'; then SP_FW="nftables rules present"
    elif command -v iptables >/dev/null 2>&1 && [[ $(iptables -S 2>/dev/null | grep -vc '^-P .* ACCEPT$') -gt 0 ]]; then SP_FW="iptables rules present"
    else SP_FW="none detected"; fi
    SP_SSH_PORT=$(ss -H -ltnp 2>/dev/null | awk '/"sshd"/ {n = split($4, a, ":"); print a[n]; exit}')
    [[ -n $SP_SSH_PORT ]] || SP_SSH_PORT=$(awk '{print $4}' <<<"${SSH_CONNECTION:-}")
    SP_P80=$(port_owner 80); SP_P443=$(port_owner 443)
    SP_LISTEN=$(ss -H -ltn 2>/dev/null | wc -l | tr -d ' ')
    SP_IPV6=$(local_ipv6_list | head -n 1)
    [[ -f /var/run/reboot-required ]] && SP_REBOOT=1
    SP_F2B=$(systemctl is-active fail2ban 2>/dev/null || true)
    SP_NGINX=$(nginx -v 2>&1 | sed -n 's/.*nginx\/\([0-9.]*\).*/\1/p' | head -n 1)
    SP_CERTBOT=$(certbot --version 2>&1 | awk '{print $2; exit}')
    command -v docker >/dev/null 2>&1 && SP_DOCKER=$(docker --version 2>/dev/null | sed -n 's/Docker version \([^,]*\),.*/\1/p')
    SP_RTT=$(ping -c 3 -W 2 1.1.1.1 2>/dev/null | awk -F/ '/^(rtt|round-trip)/ {printf "%d", $5}')

    json=$(curl -4 -fsS --connect-timeout 3 --max-time 7 'https://ipwho.is/' 2>/dev/null || true)
    [[ -n $json ]] || json=$(curl -4 -fsS --connect-timeout 3 --max-time 7 'https://ipapi.co/json/' 2>/dev/null || true)
    if [[ -n $json ]]; then
        while IFS='=' read -r k v; do
            case $k in ip) PUB_IP=$v ;; country) PUB_COUNTRY=$v ;; cc) PUB_CC=$v ;; city) SP_CITY=$v ;; isp) SP_ISP=$v ;; asn) SP_ASN=$v ;; esac
        done < <(python3 -I -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: d = {}
c = d.get("connection") or {}
for k, v in (("ip", d.get("ip")), ("country", d.get("country") or d.get("country_name")), ("cc", d.get("country_code")),
             ("city", d.get("city")), ("isp", c.get("isp") or c.get("org") or d.get("org")), ("asn", c.get("asn") or d.get("asn"))):
    print("%s=%s" % (k, "" if v is None else str(v).replace("\n", " ")))
' <<<"$json" 2>/dev/null)
    fi
    if [[ -z ${PUB_IP:-} ]]; then pub_ip_quick; PUB_IP=${PUB_QUICK:-}; fi
    : "${PUB_COUNTRY:=Unavailable}" "${PUB_CC:=--}"

    # Real throughput: download a fixed 25 MB object and read curl's own speed counter.
    bps=$(curl -4 -sS -o /dev/null --max-time 12 -w '%{speed_download}' \
        'https://speed.cloudflare.com/__down?bytes=25000000' 2>/dev/null || true)
    SPEED_MBPS=$(awk -v b="${bps:-0}" 'BEGIN { m = int(b * 8 / 1000000); if (m > 0) print m }')
    SP_PANELS=$(installed_panels 2>/dev/null | paste -sd, - | sed 's/,/, /g')
    check_github
    nat_detect
}

ui_kv_meter() {   # ui_kv_meter <label> <percent> <text>
    printf ' %s▌%s  %s%-18s%s ' "$C_CYAN" "$C_RESET" "$C_DIM" "$1" "$C_RESET"
    meter "$2" 18
    printf '  %s\n' "$3"
}

# infra_report <score> <tier> - the detailed "new server" card; display only
infra_report() {
    local score=$1 tier=$2 ram_used ram_pct load_pct p row gname gst gms gcode flag
    ram_used=$(( RAM_MB - SP_RAM_AVAIL )); (( RAM_MB > 0 )) && ram_pct=$(( ram_used * 100 / RAM_MB )) || ram_pct=0
    load_pct=$(awk -v l="$SP_L1" -v c="$CPU_CORES" 'BEGIN { printf "%d", (c > 0 ? l * 100 / c : 0) }')

    ui_section "${INFRA_TITLE:-$(t pf_title)}"
    ui_card "SYSTEM"
    ui_kv "HOSTNAME" "$SP_HOST"
    ui_kv "OPERATING SYSTEM" "$OS_NAME"
    ui_kv "KERNEL" "${SP_KERNEL}  ·  ${SP_ARCH}"
    ui_kv "VIRTUALIZATION" "$SP_VIRT"
    ui_kv "UPTIME" "$SP_UPTIME"
    ui_kv "TIME" "${SP_TZ:-unknown zone}  ·  clock synchronised: $( [[ $SP_NTP == yes ]] && echo yes || echo "${SP_NTP:-unknown}")" "$( [[ $SP_NTP == yes ]] && echo "$C_GREEN" || echo "$C_YELLOW")"

    ui_card "RESOURCES"
    ui_kv "CPU" "${CPU_CORES} core(s)  ·  ${SP_CPU_MODEL:-unknown model}" "$C_GREEN"
    ui_kv_meter "LOAD (1 min)" "$load_pct" "${SP_L1} ${SP_L5} ${SP_L15}   (1 / 5 / 15 min)"
    ui_kv_meter "RAM" "$ram_pct" "${ram_used} / ${RAM_MB} MB used"
    if (( SP_SWAP_MB > 0 )); then ui_kv "SWAP" "${SP_SWAP_MB} MB" "$C_GREEN"; else ui_kv "SWAP" "none" "$C_YELLOW"; fi
    ui_kv_meter "DISK  /" "$SP_DISK_PCT" "${DISK_FREE_GB} GB free of ${DISK_TOTAL_GB} GB"

    ui_card "NETWORK"
    ui_kv "PUBLIC IPv4" "${PUB_IP:-Unavailable (network/API blocked)}" "$C_GREEN"
    ui_kv "INTERNAL IPv4" "${SP_LOCAL_V4:-none}" "$C_WHITE"
    case ${SP_NAT:--1} in
        1) ui_kv "NAT" "Behind NAT - this server only holds ${SP_LOCAL_V4}; the address people reach it on is ${PUB_IP}" "$C_YELLOW" ;;
        0) ui_kv "NAT" "No NAT - the public address is configured on this server" "$C_GREEN" ;;
        *) if [[ -z ${PUB_IP:-} && -n ${SP_LOCAL_V4:-} ]]; then ui_kv "NAT" "not determined - no public address could be found (offline or blocked), only the internal one is known" "$C_YELLOW"
           else ui_kv "NAT" "not determined" "$C_DIM"; fi ;;
    esac
    ui_kv "IPv6" "${SP_IPV6:-not configured}" "$( [[ -n $SP_IPV6 ]] && echo "$C_GREEN" || echo "$C_DIM")"
    flag=$(country_flag "$PUB_CC")
    ui_kv "LOCATION" "${flag:+${flag}   }${PUB_COUNTRY}${SP_CITY:+, ${SP_CITY}}  (${PUB_CC})" "$C_YELLOW"
    ui_kv "PROVIDER" "${SP_ISP:-unknown}${SP_ASN:+  ·  AS${SP_ASN#AS}}"
    ui_kv "LATENCY" "$(or_else "$SP_RTT" ' ms to 1.1.1.1' 'not measured')" "$C_WHITE"
    ui_kv "DOWNLOAD" "$(or_else "$SPEED_MBPS" ' Mbps' 'not measured')" "$C_YELLOW"
    ui_kv "TCP CONGESTION" "${SP_CC:-unknown}  ·  queue: ${SP_QDISC:-unknown}" "$( [[ $SP_CC == bbr ]] && echo "$C_GREEN" || echo "$C_YELLOW")"

    ui_card "DOWNLOAD SOURCES  (GitHub and installers)"
    if (( GH_TOTAL > 0 )); then
        for row in "${GH_ROWS[@]}"; do
            IFS='|' read -r gname gst gms gcode <<<"$row"
            if [[ $gst == OK ]]; then ui_kv "$gname" "reachable  ·  ${gms} ms" "$C_GREEN"; else ui_kv "$gname" "UNREACHABLE  (HTTP ${gcode})" "$C_RED"; fi
        done
    else ui_kv "STATUS" "not checked (curl is missing)" "$C_DIM"; fi

    ui_card "SECURITY AND PORTS"
    ui_kv "FIREWALL" "$SP_FW" "$( [[ $SP_FW == none* ]] && echo "$C_YELLOW" || echo "$C_GREEN")"
    ui_kv "SSH PORT" "${SP_SSH_PORT:-unknown}"
    ui_kv "PORT 80" "$(or_else "$SP_P80" '' 'free' 'in use by ')" "$( [[ -z $SP_P80 || $SP_P80 == nginx ]] && echo "$C_GREEN" || echo "$C_YELLOW")"
    ui_kv "PORT 443" "$(or_else "$SP_P443" '' 'free' 'in use by ')" "$( [[ -z $SP_P443 || $SP_P443 == nginx ]] && echo "$C_GREEN" || echo "$C_YELLOW")"
    ui_kv "LISTENING" "${SP_LISTEN} TCP port(s)"
    ui_kv "FAIL2BAN" "$( [[ $SP_F2B == active ]] && echo active || echo "not running")" "$( [[ $SP_F2B == active ]] && echo "$C_GREEN" || echo "$C_DIM")"

    ui_card "SOFTWARE"
    ui_kv "PANELS" "${SP_PANELS:-none installed}" "$( [[ -n $SP_PANELS ]] && echo "$C_GREEN" || echo "$C_DIM")"
    ui_kv "NGINX" "$(or_else "$SP_NGINX" '' 'not installed' 'v')" "$( [[ -n $SP_NGINX ]] && echo "$C_GREEN" || echo "$C_DIM")"
    ui_kv "CERTBOT" "$(or_else "$SP_CERTBOT" '' 'not installed' 'v')" "$( [[ -n $SP_CERTBOT ]] && echo "$C_GREEN" || echo "$C_DIM")"
    ui_kv "DOCKER" "$(or_else "$SP_DOCKER" '' 'not installed' 'v')" "$C_DIM"

    ui_card "VERDICT"
    ui_kv "TIER" "$tier" "$C_PURPLE"
    printf ' %s▌%s  %s%-18s%s ' "$C_CYAN" "$C_RESET" "$C_DIM" "SCORE" "$C_RESET"
    progress_bar "$score"; printf '  (%d.%d / 10)\n' "$(( score / 10 ))" "$(( score % 10 ))"

    ui_card "CHECKS AND ADVICE"
    if (( RAM_MB >= 1700 )); then ui_ok "RAM ${RAM_MB} MB is enough for a proxy node."; else ui_warn "RAM ${RAM_MB} MB is below the recommended 2 GB."; fi
    if (( CPU_CORES >= 2 )); then ui_ok "${CPU_CORES} CPU cores."; else ui_warn "A single CPU core - fine for a few users, tight for many."; fi
    if (( DISK_FREE_GB >= 5 )); then ui_ok "${DISK_FREE_GB} GB of free disk space."; else ui_warn "Only ${DISK_FREE_GB} GB of disk space is free - backups and logs will fill it quickly."; fi
    if (( SP_SWAP_MB == 0 && RAM_MB < 2048 )); then ui_warn "No swap on a small-RAM server: add a 1-2 GB swap file to avoid out-of-memory kills."; fi
    if [[ $SP_CC == bbr ]]; then ui_ok "TCP BBR is enabled (better throughput on lossy links)."
    else ui_warn "TCP BBR is not enabled (currently ${SP_CC:-unknown}). Enabling it usually improves proxy speed."; fi
    if [[ $SP_NTP == yes ]]; then ui_ok "The system clock is synchronised (important for VMess/Reality)."
    else ui_warn "The clock is not reported as synchronised - VMess and TLS can fail with a wrong time."; fi
    if [[ $SP_FW == none* ]]; then ui_warn "No firewall detected. Consider ufw (allow SSH, 80, 443 and your panel/inbound ports)."; else ui_ok "Firewall: ${SP_FW}."; fi
    for p in 80 443; do
        local owner; if (( p == 80 )); then owner=$SP_P80; else owner=$SP_P443; fi
        if [[ -n $owner && $owner != nginx ]]; then ui_warn "Port ${p} is used by '${owner}' - Nginx / Let's Encrypt cannot use it until that stops."; fi
    done
    if (( SP_REBOOT )); then ui_warn "A reboot is pending (system updates were installed)."; fi
    if [[ $SP_VIRT == openvz || $SP_VIRT == lxc ]]; then ui_warn "Container virtualization (${SP_VIRT}): kernel tuning such as BBR may not be possible."; fi
    if [[ -z $PUB_IP ]]; then ui_warn "The public IP could not be detected (offline or API blocked)."; fi
    if (( ${SP_NAT:--1} == 1 )); then ui_warn "Behind NAT: ports opened on this server are NOT reachable from the internet until the router / provider forwards them to ${SP_LOCAL_V4}. The public address is ${PUB_IP}."; fi
    if (( GH_TOTAL > 0 && GH_OK == 0 )); then ui_err "GitHub and the installers cannot be reached - panel installs, updates and the NX migration tool will fail. Use a proxy or mirror first."
    elif (( GH_TOTAL > 0 && GH_OK < GH_TOTAL )); then ui_warn "$(( GH_TOTAL - GH_OK )) of ${GH_TOTAL} download sources cannot be reached; some installers may fail."
    elif (( GH_TOTAL > 0 )); then ui_ok "GitHub and all installer sources are reachable."; fi
}

run_preflight() {     # run_preflight <db>   -> 1 = abort
    local db=$1 score weak=0 tier
    spin_start "Inspecting this server: hardware, network, NAT, GitHub access, speed test (up to 40 s)..."
    collect_specs
    spin_stop
    score=$(final_score); tier=$(score_tier "$score")
    if (( RAM_MB < 1700 || CPU_CORES < 1 )); then weak=1; fi
    if (( GH_TOTAL > 0 && GH_OK == 0 )); then weak=1; fi
    if [[ -n $SPEED_MBPS ]] && (( SPEED_MBPS < 100 )); then weak=1; fi

    typed_begin
    infra_report "$score" "$tier"
    typed_end

    check_blacklists "$PUB_IP"
    if (( weak )); then
        ui_warn "$(t pf_weak)"
        confirm "$(t pf_force)" n || return 1
    fi
    audit_domains "$db" || return 1
    return 0
}

# ── Panel registry & automatic detection ──────────────────────────────────────
# Panel ids: nx | 3x-ui | alireza | x-ui   (alireza and x-ui are the "classic x-ui line")
norm_panel() {
    case ${1,,} in
        nx|nx-panel)              printf 'nx' ;;
        3x-ui|3xui|sanaei|mhsanaei) printf '3x-ui' ;;
        alireza|alireza0)         printf 'alireza' ;;
        x-ui|xui|vaxilu)          printf 'x-ui' ;;
        *)                        printf '%s' "$1" ;;
    esac
}
panel_label() {
    case $1 in
        nx)      printf 'NX Panel' ;;
        3x-ui)   printf '3x-ui (MHSanaei)' ;;
        alireza) printf 'Alireza x-ui' ;;
        x-ui)    printf 'Classic x-ui (vaxilu)' ;;
        *)       printf '%s' "$1" ;;
    esac
}
panel_service() { [[ $1 == nx ]] && printf 'nx-panel' || printf 'x-ui'; }
panel_cli()     { [[ $1 == nx ]] && printf '/opt/nx-panel/nx-panel' || printf '/usr/local/x-ui/x-ui'; }
panel_installer_url() {
    case $1 in
        nx)      printf '%s' "$NX_INSTALL_URL" ;;
        3x-ui)   printf 'https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh' ;;
        alireza) printf 'https://raw.githubusercontent.com/alireza0/x-ui/main/install.sh' ;;
        x-ui)    printf 'https://raw.githubusercontent.com/vaxilu/x-ui/master/install.sh' ;;
    esac
}
panel_installed() { [[ -x $(panel_cli "$1") ]]; }
panel_rank()      { case $1 in x-ui) echo 1 ;; alireza) echo 2 ;; 3x-ui) echo 3 ;; *) echo 0 ;; esac; }

# panel_compat <source> <target>  ->  same | upgrade | downgrade | unknown
panel_compat() {
    local a b
    a=$(panel_rank "$1"); b=$(panel_rank "$2")
    if (( a == 0 || b == 0 )); then echo unknown
    elif (( a == b )); then echo same
    elif (( b > a )); then echo upgrade
    else echo downgrade; fi
}

# Read-only analysis of a panel database: detect | domains | ports | settings
dbtool() {
    python3 -I - "$@" <<'PYDB'
import ipaddress, json, os, re, sqlite3, sys, urllib.parse
cmd, db = sys.argv[1], sys.argv[2]
try:
    con = sqlite3.connect("file:%s?mode=ro" % urllib.parse.quote(db), uri=True)
    tables = {r[0] for r in con.execute("select name from sqlite_master where type='table'")}
except Exception as e:
    print("error: %s" % e, file=sys.stderr); sys.exit(1)

def cols(t):
    try:
        return {r[1] for r in con.execute('pragma table_info("%s")' % t)}
    except Exception:
        return set()

def settings():
    out = {}
    if "settings" in tables:
        try:
            for k, v in con.execute('select "key", "value" from settings'):
                out[k] = v
        except Exception:
            pass
    return out

if cmd == "detect":
    if "inbounds" not in tables:
        print("unknown|none|no 'inbounds' table - not an x-ui family database"); sys.exit(0)
    if tables & {"endpoints", "tls", "changes"} and "client_traffics" not in tables:
        print("unknown|none|looks like an s-ui database (only the NX Panel wizard can import it)"); sys.exit(0)
    inb = cols("inbounds")
    t3 = sorted(tables & {"history_of_seeders", "outbound_traffics", "nodes", "api_tokens", "client_inbounds", "hosts"})
    c3 = sorted(inb & {"traffic_reset", "last_traffic_reset_time", "all_time", "node_id", "share_addr_strategy"})
    al = sorted(tables & {"outbounds", "routing_rules"})
    if t3 or c3:
        print("3x-ui|high|3x-ui markers: %s" % ", ".join(["table " + x for x in t3] + ["column " + x for x in c3]))
    elif al:
        print("alireza|high|Alireza markers: %s" % ", ".join("table " + x for x in al))
    elif "client_traffics" in tables:
        print("3x-ui|low|has client_traffics (3x-ui / Alireza line) but no distinguishing marker")
    else:
        print("x-ui|high|classic schema: users, inbounds, settings - no client_traffics")
    sys.exit(0)

dom_re = re.compile(r"^(?=.{4,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$")
def clean(d):
    d = (d or "").strip().lower().rstrip(".")
    try:
        ipaddress.ip_address(d); return None
    except ValueError:
        pass
    return d if dom_re.match(d) else None

def first_host(ss):
    cands = [(ss.get("tlsSettings") or {}).get("serverName")]
    for k in ("wsSettings", "httpupgradeSettings", "xhttpSettings", "splithttpSettings"):
        v = ss.get(k) or {}
        cands += [v.get("host"), (v.get("headers") or {}).get("Host")]
    cands.append((ss.get("grpcSettings") or {}).get("authority"))
    for c in cands:
        c = clean(c)
        if c:
            return c
    return ""

def jload(x):
    try:
        v = json.loads(x or "{}")
        return v if isinstance(v, dict) else {}
    except Exception:
        return {}

if cmd == "domains":
    # Domains the OPERATOR owns: panel/sub domain, TLS server names, cert directory names, 3x-ui hosts.
    # Reality targets / camouflage SNIs are deliberately excluded - they are not ours to point anywhere.
    found = {}
    def add(d, src):
        d = clean(d)
        if d:
            found.setdefault(d, set()).add(src)
    s = settings()
    for k in ("webDomain", "subDomain"):
        add(s.get(k), "panel:" + k)
    try:
        for (ss,) in con.execute("select stream_settings from inbounds"):
            try:
                j = json.loads(ss or "{}")
            except Exception:
                continue
            if j.get("security") != "reality":
                add(first_host(j), "inbound-host")
            if j.get("security") == "tls":
                tls = j.get("tlsSettings") or {}
                add(tls.get("serverName"), "inbound-tls")
                for c in tls.get("certificates") or []:
                    m = re.search(r"/live/([^/]+)/", c.get("certificateFile") or "")
                    if m:
                        add(m.group(1), "cert-path")
    except Exception:
        pass
    if "hosts" in tables and "address" in cols("hosts"):
        try:
            for (a,) in con.execute("select address from hosts"):
                add(a, "host")
        except Exception:
            pass
    for d in sorted(found):
        print("%s\t%s" % (d, ",".join(sorted(found[d]))))
    sys.exit(0)


def nginx_text(paths):
    out = []
    for p in paths:
        files = []
        if os.path.isfile(p):
            files = [p]
        elif os.path.isdir(p):
            for r, _, fs in os.walk(p, followlinks=True):
                files += [os.path.join(r, f) for f in fs]
        for f in files[:400]:
            try:
                with open(f, "r", errors="ignore") as fh:
                    out.append(fh.read(400000))
            except Exception:
                pass
    return "\n".join(out)

def proxied(txt, port):
    pat = r"(?:proxy_pass|grpc_pass)\s+(?:https?|grpcs?)://(?:127\.0\.0\.1|localhost|\[::1\]):%d\b" % int(port)
    return re.search(pat, txt) is not None

def is_local(listen):
    listen = (listen or "").strip()
    return listen in ("127.0.0.1", "::1", "localhost") or listen.startswith("/") or listen.startswith("@")

def scalar(q):
    try:
        return con.execute(q).fetchone()[0] or 0
    except Exception:
        return 0

if cmd == "stats":
    paths = sys.argv[3:]
    try:
        rows = con.execute("select port, protocol, enable, listen, settings, up, down from inbounds").fetchall()
    except Exception:
        rows = []
    seen, protos, en, traffic = set(), {}, 0, 0
    for port, proto, enable, listen, st, up, down in rows:
        protos[proto] = protos.get(proto, 0) + 1
        en += 1 if enable else 0
        traffic += (up or 0) + (down or 0)
        j = jload(st)
        for c in list(j.get("clients") or []) + list(j.get("accounts") or []):
            if isinstance(c, dict):
                seen.add(str(c.get("email") or c.get("id") or c.get("password") or c.get("user") or id(c)))
    ct = scalar("select count(*) from client_traffics") if "client_traffics" in tables else 0
    cl = scalar("select count(*) from clients") if "clients" in tables else 0
    traffic = max(traffic, scalar("select sum(up+down) from client_traffics") if "client_traffics" in tables else 0)
    s = settings()
    pport, plisten = s.get("webPort", ""), s.get("webListen", "")
    if paths and pport.isdigit() and proxied(nginx_text(paths), pport):
        front = "nginx"
    elif is_local(plisten):
        front = "local"
    else:
        front = "direct"
    print("inbounds=%d" % len(rows)); print("inbounds_enabled=%d" % en)
    print("users=%d" % max(len(seen), ct, cl))
    print("protocols=%s" % ", ".join("%s %d" % (k, protos[k]) for k in sorted(protos)))
    print("traffic=%d" % traffic)
    print("panel_port=%s" % pport); print("panel_listen=%s" % plisten); print("panel_front=%s" % front)
    sys.exit(0)

if cmd == "inbounds":
    paths = sys.argv[3:]
    txt = nginx_text(paths) if paths else None
    try:
        rows = con.execute("select id, port, protocol, remark, enable, listen, settings, stream_settings from inbounds order by port").fetchall()
    except Exception:
        rows = []
    for iid, port, proto, remark, enable, listen, st, ss in rows:
        sj, tj = jload(st), jload(ss)
        n = len([c for c in (sj.get("clients") or []) if isinstance(c, dict)])
        if txt is not None and port and proxied(txt, port):
            front = "nginx"
        elif is_local(listen):
            front = "local"
        else:
            front = "direct"
        # "-" placeholders: an empty field would be swallowed by the shell's tab splitting
        print("\t".join(str(x if x not in ("", None) else "-") for x in (iid, port, proto, (remark or "").replace("\t", " "), 1 if enable else 0,
              tj.get("network") or "tcp", tj.get("security") or "none", listen or "", first_host(tj), front, n)))
    sys.exit(0)

if cmd == "ports":
    try:
        for port, proto, remark in con.execute("select port, protocol, remark from inbounds where enable=1 and port>0"):
            print("%s\t%s\t%s" % (port, proto, (remark or "").replace("\t", " ")))
    except Exception:
        pass
    sys.exit(0)

if cmd == "settings":
    s = settings()
    for k in ("webPort", "webBasePath", "webListen", "webDomain", "webCertFile", "subEnable", "subPort", "subDomain"):
        if k in s:
            print("%s=%s" % (k, s[k]))
    sys.exit(0)
sys.exit(2)
PYDB
}

# Which repo does the CLI script on THIS server update from? (corroborates a weak DB signal)
panel_from_cli() {
    local f hit
    for f in /usr/bin/x-ui /usr/local/x-ui/x-ui.sh; do
        [[ -r $f ]] || continue
        hit=$(tr '[:upper:]' '[:lower:]' <"$f" 2>/dev/null | grep -oE 'mhsanaei/3x-ui|alireza0/x-ui|vaxilu/x-ui' | head -n 1)
        case $hit in
            mhsanaei/3x-ui) printf '3x-ui'; return 0 ;;
            alireza0/x-ui)  printf 'alireza'; return 0 ;;
            vaxilu/x-ui)    printf 'x-ui'; return 0 ;;
        esac
    done
    return 1
}

# detect_panel <db> [live=0|1]  -> PANEL_NAME PANEL_CONF PANEL_WHY. Never asks the user.
detect_panel() {
    local db=$1 live=${2:-0} line name conf why cli=""
    line=$(dbtool detect "$db" 2>/dev/null) || line="unknown|none|database could not be read"
    IFS='|' read -r name conf why <<<"$line"
    (( live )) && cli=$(panel_from_cli || true)

    if [[ $conf == high ]]; then
        [[ -n $cli && $cli != "$name" ]] && why+=" (CLI script says ${cli}; the database schema wins)"
    elif [[ -n $cli ]]; then
        name=$cli; conf=medium; why="installed CLI script updates from the ${cli} repository; ${why}"
    fi
    PANEL_NAME=$name; PANEL_CONF=$conf; PANEL_WHY=$why
}

print_panel_detection() {
    local color=$C_GREEN
    [[ $PANEL_CONF == medium ]] && color=$C_YELLOW
    [[ $PANEL_CONF == low || $PANEL_CONF == none ]] && color=$C_RED
    ui_kv "PANEL" "$(panel_label "$PANEL_NAME")  [auto-detected]" "$color"
    ui_kv "CONFIDENCE" "$PANEL_CONF" "$color"
    ui_kv "EVIDENCE" "${PANEL_WHY:0:$((UI_COLS - 24))}" "$C_DIM"
    if [[ $PANEL_CONF == low ]]; then
        ui_warn "Low confidence. The restore workflow re-checks compatibility and never overwrites without a backup."
    fi
}

sqlite_has_table() {
    local r
    r=$(sqlite3 -readonly "$1" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='$2';" 2>/dev/null)
    [[ $r == 1 ]]
}

# ── System helpers ────────────────────────────────────────────────────────────
rand_string() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "${1:-12}"; }

port_in_use() {
    local port=$1 listeners
    if command -v ss >/dev/null 2>&1; then
        listeners=$(ss -H -lntu 2>/dev/null | awk '{print $5}')
        grep -Eq "[:.]${port}\$" <<<"$listeners"
        return
    fi
    (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null
}

pick_free_port() {
    local i p
    for (( i = 0; i < 60; i++ )); do
        p=$(( 10000 + ((RANDOM << 15) | RANDOM) % 22000 ))
        port_in_use "$p" || { printf '%s' "$p"; return 0; }
    done
    return 1
}

detect_public_ip() {   # sets PUB_IP (reuses a value found by the pre-flight)
    local u ip
    if [[ -n ${PUB_IP:-} ]] && is_ipv4 "$PUB_IP"; then return 0; fi
    for u in https://api4.ipify.org https://ipv4.icanhazip.com https://4.ident.me https://v4.api.ipinfo.io/ip; do
        ip=$(curl -4 -fsS --connect-timeout 3 --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]"') || true
        if is_ipv4 "$ip"; then PUB_IP=$ip; return 0; fi
    done
    return 1
}

local_ipv6_list() { ip -6 -o addr show scope global 2>/dev/null | awk '{split($4, a, "/"); print a[1]}'; }

open_firewall() {      # open_firewall <port>...   (ufw only; other firewalls are only reported)
    local st p
    command -v ufw >/dev/null 2>&1 || return 0
    st=$(ufw status 2>/dev/null)
    [[ $st == *"Status: active"* ]] || return 0
    for p in "$@"; do ufw allow "${p}/tcp" >/dev/null 2>&1 && ui_ok "ufw: allowed ${p}/tcp"; done
}

is_cloudflare_ip() {
    python3 -I - "$1" <<'PYCF'
import ipaddress, sys
nets = "173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22".split()
try:
    ip = ipaddress.ip_address(sys.argv[1])
    sys.exit(0 if any(ip in ipaddress.ip_network(n) for n in nets) else 1)
except ValueError:
    sys.exit(1)
PYCF
}

db_set_setting() {     # db_set_setting <db> <key> <value>   (panel must be stopped)
    python3 -I - "$1" "$2" "$3" <<'PYSET'
import sqlite3, sys
db, key, val = sys.argv[1:4]
con = sqlite3.connect(db)
cur = con.execute('update settings set "value"=? where "key"=?', (val, key))
if cur.rowcount == 0:
    con.execute('insert into settings ("key","value") values (?,?)', (key, val))
con.commit()
PYSET
}

# ── DNS verification ──────────────────────────────────────────────────────────
DNS_STATE="" DNS_NOW="" DNS_NOTE="" SERVER_VERDICT="UNKNOWN" EXPECTED_IP=""

dns_a() {              # dns_a <domain> <resolver>  -> sorted unique IPv4 answers
    local -a rarg=()
    [[ -n $2 ]] && rarg=("@$2")
    if command -v dig >/dev/null 2>&1; then
        dig +short +time=3 +tries=1 "${rarg[@]}" A "$1" 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -u
    else
        getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u
    fi
}

dns_check_domain() {   # dns_check_domain <domain> <expected-ip>  -> DNS_STATE / DNS_NOW / DNS_NOTE
    local d=$1 want=$2 r1 r2 all ip cdn_all=1 v6 mine hit
    DNS_NOTE=""
    r1=$(dns_a "$d" 1.1.1.1); r2=$(dns_a "$d" 8.8.8.8)
    all=$(printf '%s\n%s\n' "$r1" "$r2" | sed '/^$/d' | sort -u)
    if [[ -z $all ]]; then DNS_STATE="NO-RECORD"; DNS_NOW="-"; return 0; fi
    DNS_NOW=$(tr '\n' ' ' <<<"$all"); DNS_NOW=${DNS_NOW% }

    while read -r ip; do is_cloudflare_ip "$ip" || cdn_all=0; done <<<"$all"
    if (( cdn_all )); then DNS_STATE="CDN"; DNS_NOTE="Cloudflare proxy hides the origin - verify it in the Cloudflare dashboard"; return 0; fi

    if [[ $all == "$want" ]]; then
        if [[ -n $r1 && -n $r2 ]]; then DNS_STATE="MATCH"; else DNS_STATE="PROPAGATING"; DNS_NOTE="only one resolver answers so far"; fi
    elif grep -qxF "$want" <<<"$all"; then
        DNS_STATE="PARTIAL"; DNS_NOTE="also resolves to another IP"
    else
        DNS_STATE="MISMATCH"
    fi

    if command -v dig >/dev/null 2>&1 && [[ $DNS_STATE == MATCH ]]; then   # an old AAAA record breaks IPv6 users
        v6=$(dig +short +time=3 +tries=1 @1.1.1.1 AAAA "$d" 2>/dev/null | grep -E '^[0-9a-fA-F:]+$' | head -n 1)
        if [[ -n $v6 ]]; then
            mine=$(local_ipv6_list); hit=0
            grep -qixF "$v6" <<<"$mine" && hit=1
            if (( ! hit )); then DNS_STATE="AAAA-MISMATCH"; DNS_NOTE="AAAA record ${v6} is not on this server"; fi
        fi
    fi
}

alert_box() {          # alert_box <title> <line>...
    local title=$1 l row w=$(( UI_COLS - 8 ))
    local -a rows=()
    shift
    printf '\n %s█%s   %s%s⛔   %s%s\n' "$C_RED" "$C_RESET" "$C_RED" "$C_BOLD" "$title" "$C_RESET"
    for l in "$@"; do
        IFS=$'\x1f' read -ra rows < <(pywrap "$w" "$l")
        for row in "${rows[@]}"; do printf ' %s█%s   %s%s\n' "$C_RED" "$C_RESET" "$LRM" "$row"; done
    done
    printf '\n'
}

# ask_expected_ip <context-note>  -> EXPECTED_IP (the IP the domains must resolve to)
ask_expected_ip() {
    local def=""
    detect_public_ip && def=$PUB_IP
    [[ -n ${1:-} ]] && ui_info "$1"
    if [[ -n $def ]]; then
        prompt_input "IP the domains must resolve to [${def}]: " 0 "$def" || return 1
    else
        ui_warn "Could not detect this server's public IPv4 automatically."
        prompt_input "IP the domains must resolve to: " 0 || return 1
    fi
    is_ipv4 "$INPUT_VALUE" || { ui_err "Not a valid IPv4 address."; return 1; }
    EXPECTED_IP=$INPUT_VALUE
}

nginx_server_names() { # nginx_server_names <path>... -> real domain names found in server_name directives
    (( $# )) || return 0
    grep -RhoE 'server_name[[:space:]]+[^;]+' "$@" 2>/dev/null | sed 's/^server_name[[:space:]]*//' | tr -s ' \t' '\n' |
        grep -E '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' | tr '[:upper:]' '[:lower:]' | sort -u
}

# collect_domains <outfile> <db> <nginx-base-dir> <letsencrypt-live-dir>  (any argument may be empty)
# One line per UNIQUE domain:  domain <TAB> source1,source2,...
collect_domains() {
    local out=$1 db=$2 ngx=$3 live=$4 d raw
    local -a paths=()
    raw=$(mktemp) || return 1
    [[ -n $db && -f $db ]] && dbtool domains "$db" >>"$raw" 2>/dev/null
    if [[ -n $ngx && -d $ngx ]]; then
        mapfile -t paths < <(nginx_active_paths "$ngx")
        while read -r d; do [[ -n $d ]] && printf '%s\tnginx\n' "$d" >>"$raw"; done < <(nginx_server_names "${paths[@]}")
    fi
    if [[ -n $live && -d $live ]]; then
        for d in "$live"/*/; do
            d=$(basename "$d")
            [[ $d =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && printf '%s\tcert\n' "${d,,}" >>"$raw"
        done
    fi
    awk -F'\t' 'NF >= 1 && $1 != "" { k = $1; if (index("," src[k] ",", "," $2 ",") == 0) src[k] = (src[k] == "" ? $2 : src[k] "," $2) }
        END { for (k in src) printf "%s\t%s\n", k, src[k] }' "$raw" | sort >"$out"
    rm -f -- "$raw"
}

# verify_dns_stage <domains-file> <expected-ip>  -> 0 = all good, 1 = server stays OUT OF SERVICE
verify_dns_stage() {
    local file=$1 want=$2 d state now note cdn_n=0 bad_n n=0 color
    local -a domains=() fixes=()
    mapfile -t domains < <(cut -f1 "$file" 2>/dev/null | sed '/^$/d' | sort -u)

    if (( ${#domains[@]} == 0 )); then
        ui_warn "No domain names were found in the backup/panel configuration."
        prompt_input "Domains users connect through (space separated, '-' if IP only): " 0 "-" || return 1
        if [[ $INPUT_VALUE == "-" ]]; then
            ui_info "IP-only deployment: nothing to verify in DNS."; SERVER_VERDICT="READY"; return 0
        fi
        read -ra domains <<<"$INPUT_VALUE"
    fi

    while true; do
        fixes=(); cdn_n=0; bad_n=0; n=0; RPT_DNS=()
        printf '\n %s   %-34s %-15s %s%s\n' "$C_DIM" "DOMAIN" "STATE" "RESOLVES TO  (expected ${want})" "$C_RESET"
        for d in "${domains[@]}"; do
            (( ++n > 40 )) && { ui_info "Only the first 40 domains are checked."; break; }
            dns_check_domain "$d" "$want"
            state=$DNS_STATE; now=$DNS_NOW; note=$DNS_NOTE
            RPT_DNS+=("${d}${TAB}${state}${TAB}${now}")
            case $state in
                MATCH) color=$C_GREEN ;;
                CDN|PROPAGATING) color=$C_YELLOW; cdn_n=$(( cdn_n + 1 )) ;;
                *) color=$C_RED; bad_n=$(( bad_n + 1 )); fixes+=("A   ${d}   ->   ${want}      (now: ${now})") ;;
            esac
            printf ' %s▌%s  %-34.34s %s%-15s%s %s %s%s%s\n' "$C_CYAN" "$C_RESET" "$d" "$color" "$state" "$C_RESET" "$now" "$C_DIM" "${note:+- $note}" "$C_RESET"
        done

        if (( bad_n == 0 && cdn_n == 0 )); then
            ui_ok "DNS verified: every domain resolves to ${want}."; SERVER_VERDICT="READY"; return 0
        fi
        if (( bad_n == 0 )); then
            ui_warn "Some domains are behind a CDN or still propagating - DNS cannot prove they reach this server."
            if confirm "Have you confirmed that their origin / A record is ${want}?" n; then SERVER_VERDICT="READY"; return 0; fi
        fi
        alert_box "THIS SERVER IS NOT IN SERVICE YET" \
            "DNS does not point to this server (${want}). Users cannot reach it" \
            "until the records below are changed at your DNS provider:" "" "${fixes[@]}" "" \
            "Keep the OLD server running until every record matches."
        menu_select "DNS is not ready - what now?" 1 \
            "🔄   Re-check now (after changing the records)" \
            "⏸   Finish anyway - this server stays OUT OF SERVICE" || return 1
        if [[ $MENU_RESULT == 2 ]]; then SERVER_VERDICT="OUT_OF_SERVICE"; return 1; fi
    done
}

# ── Post-migration verification (DNS first) ───────────────────────────────────
PV_PASS=0 PV_WARN=0 PV_FAIL=0
pv_ok()   { PV_PASS=$(( PV_PASS + 1 )); ui_ok "$*"; rpt_add OK "$*"; }
pv_warn() { PV_WARN=$(( PV_WARN + 1 )); ui_warn "$*"; rpt_add WARN "$*"; }
pv_fail() { PV_FAIL=$(( PV_FAIL + 1 )); ui_err "$*"; rpt_add FAIL "$*"; }

panel_port_of() {      # panel_port_of <panel>  -> listening port of the panel UI
    local cli
    cli=$(panel_cli "$1")
    if [[ $1 == nx ]]; then
        "$cli" config get web_listen_port 2>/dev/null | head -n 1 | tr -d '[:space:]'
    else
        "$cli" setting -show true 2>/dev/null | grep -Eo 'port: [0-9]+' | head -n 1 | awk '{print $2}'
    fi
}

# post_verify <panel> <domains-file|""> <db|""> <expected-ip-note>
post_verify() {
    local panel=$1 dfile=$2 db=$3 note=${4:-} svc port code p proto remark d exp
    local tmp_domains=""
    PV_PASS=0; PV_WARN=0; PV_FAIL=0; SERVER_VERDICT="UNKNOWN"
    svc=$(panel_service "$panel")

    ui_section "POST-MIGRATION VERIFICATION"
    ui_step 1 5 "DNS records vs this server's IP"
    if [[ -z $dfile || ! -f $dfile ]]; then
        tmp_domains=$(mktemp) || return 1
        register_cleanup "$tmp_domains"
        collect_domains "$tmp_domains" "$db" /etc/nginx /etc/letsencrypt/live
        dfile=$tmp_domains
    fi
    if ask_expected_ip "$note"; then
        exp=$EXPECTED_IP
        if verify_dns_stage "$dfile" "$exp"; then pv_ok "DNS points to ${exp}."
        else pv_fail "DNS does not point to ${exp} yet."; fi
    else
        pv_fail "DNS could not be verified (no usable IP)."; SERVER_VERDICT="OUT_OF_SERVICE"
    fi

    ui_step 2 5 "Panel service and port"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then pv_ok "Service ${svc} is active."
    else pv_fail "Service ${svc} is NOT active  (journalctl -u ${svc} -n 50)"; fi
    if [[ $panel != nx ]]; then
        if pgrep -f xray >/dev/null 2>&1; then pv_ok "Xray core process is running."
        else pv_warn "No xray process found - start the Xray service from the panel."; fi
    fi
    port=$(panel_port_of "$panel")
    if [[ $port =~ ^[0-9]+$ ]]; then
        if port_in_use "$port"; then
            code=$(curl -s -o /dev/null -m 6 -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null)
            [[ $code == 000 ]] && code=$(curl -sk -o /dev/null -m 6 -w '%{http_code}' "https://127.0.0.1:${port}/" 2>/dev/null)
            if [[ $code != 000 ]]; then pv_ok "Panel port ${port} answers (HTTP ${code})."
            else pv_warn "Port ${port} is open but did not answer HTTP/HTTPS."; fi
        else pv_fail "Panel port ${port} is not listening."; fi
    else pv_warn "Could not read the panel port."; fi

    ui_step 3 5 "Nginx and certificates"
    if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
        if nginx -t >/dev/null 2>&1; then pv_ok "nginx configuration test passed."; else pv_fail "nginx -t failed - run it to see the error."; fi
        while read -r d; do
            [[ -f /etc/letsencrypt/live/${d}/fullchain.pem ]] || continue
            if openssl x509 -checkend $(( 14 * 86400 )) -noout -in "/etc/letsencrypt/live/${d}/fullchain.pem" >/dev/null 2>&1; then
                pv_ok "Certificate for ${d} is valid for 14+ days."
            else pv_warn "Certificate for ${d} expires within 14 days or is invalid."; fi
        done < <(cut -f1 "$dfile" | sort -u)
    else
        ui_info "Nginx is not running on this server - skipped."
    fi

    ui_step 4 5 "Inbound ports"
    if [[ $panel != nx && -n $db && -f $db ]]; then
        local n=0
        while IFS=$'\t' read -r p proto remark; do
            [[ -n $p ]] || continue
            (( ++n > 60 )) && break
            if port_in_use "$p"; then pv_ok "Inbound ${p}/${proto} ${remark:+(${remark}) }is listening."
            else pv_warn "Inbound ${p}/${proto} ${remark:+(${remark}) }is not listening."; fi
        done < <(dbtool ports "$db")
        (( n == 0 )) && ui_info "No enabled inbounds in the database."
    else
        ui_info "Inbounds live on NX nodes - check each node from the panel. Skipped."
    fi

    ui_step 5 5 "Verdict"
    if [[ $SERVER_VERDICT != READY || $PV_FAIL -gt 0 ]]; then SERVER_VERDICT="OUT_OF_SERVICE"; fi
    ui_kv "PASSED" "$PV_PASS" "$C_GREEN"
    ui_kv "WARNINGS" "$PV_WARN" "$C_YELLOW"
    ui_kv "FAILED" "$PV_FAIL" "$( (( PV_FAIL )) && echo "$C_RED" || echo "$C_GREEN")"
    if [[ $SERVER_VERDICT == READY ]]; then
        printf '\n %s█%s   %s%s%s  SERVER READY - DNS matches and the panel is healthy.%s\n' "$C_GREEN" "$C_RESET" "$C_GREEN" "$C_BOLD" "$I_OK" "$C_RESET"
        [[ $PV_WARN -gt 0 ]] && ui_info "Review the warnings above before switching all users."
    else
        alert_box "SERVER IS OUT OF SERVICE" \
            "Do NOT switch users to this server yet." \
            "Fix every failed check above (DNS first), then re-check with:" \
            "  sudo bash $(basename "$0") --verify"
    fi
    printf 'verdict=%s\nchecked=%s\nip=%s\n' "$SERVER_VERDICT" "$(date '+%F %T')" "${EXPECTED_IP:-unknown}" >"${BACKUP_HOME}/moc-server-status.txt" 2>/dev/null || true
}

# ── Nginx reverse proxy (+ HTTPS via certbot) ─────────────────────────────────
# setup_nginx_proxy <domain> <upstream-port> <email|"">   -> 0 ok
setup_nginx_proxy() {
    local domain=$1 port=$2 email=$3 conf="/etc/nginx/conf.d/moc-panel-${1}.conf" mapf=/etc/nginx/conf.d/00-moc-upgrade-map.conf
    local -a cb=()

    # An Xray inbound on 80/443 blocks nginx (and certbot's HTTP-01 challenge).
    local p
    for p in 80 443; do
        if port_in_use "$p" && ! ss -H -lntp 2>/dev/null | grep -E "[:.]${p}[[:space:]]" | grep -q nginx; then
            ui_err "Port ${p} is already used by another process (usually an Xray inbound)."
            ui_info "Free ${p} (move that inbound to another port or use it as a fallback target), then run this step again."
            return 1
        fi
    done

    command -v apt-get >/dev/null 2>&1 || { ui_err "apt-get not found - install nginx and certbot manually."; return 1; }
    export DEBIAN_FRONTEND=noninteractive
    run_task "apt-get update" apt-get update -y || return 1
    run_task "Installing nginx and certbot" apt-get install -y --no-install-recommends nginx certbot python3-certbot-nginx || return 1
    systemctl enable --now nginx >/dev/null 2>&1

    if [[ ! -f $mapf ]]; then
        # shellcheck disable=SC2016
    printf 'map $http_upgrade $moc_conn_upgrade {\n    default upgrade;\n    ""      close;\n}\n' >"$mapf"
    fi
    cat >"$conf" <<NGX
# Managed by MOC Networks Smart Solution - reverse proxy for the panel on 127.0.0.1:${port}
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$moc_conn_upgrade;
        proxy_read_timeout 300s;
    }
}
NGX
    if ! nginx -t >/dev/null 2>&1; then
        ui_err "nginx -t failed with the generated configuration:"; nginx -t 2>&1 | tail -n 8 >&2
        rm -f -- "$conf"; return 1
    fi
    systemctl reload nginx || { ui_err "nginx reload failed."; return 1; }
    open_firewall 80 443

    cb=(certbot --nginx -d "$domain" --non-interactive --agree-tos --redirect)
    if [[ -n $email ]]; then cb+=(-m "$email"); else cb+=(--register-unsafely-without-email); fi
    if run_task "Requesting a Let's Encrypt certificate for ${domain}" "${cb[@]}"; then
        ui_ok "HTTPS is active: https://${domain}/"
    else
        ui_warn "Certificate request failed - the panel is reachable over plain HTTP only (credentials are NOT encrypted)."
        ui_info "After DNS is correct run:  certbot --nginx -d ${domain}"
    fi
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1
    return 0
}

# ── Panel installation (custom, non-interactive official installers) ──────────
IO_PORT="" IO_BASE="" IO_USER="" IO_PASS="" IO_DB="sqlite" IO_NGINX=0 IO_DOMAIN="" IO_EMAIL="" IO_LOOPBACK=0

collect_install_options() {   # collect_install_options <panel> <quick 0|1>
    local panel=$1 quick=${2:-0} v
    IO_DB=sqlite; IO_NGINX=0; IO_DOMAIN=""; IO_EMAIL=""; IO_LOOPBACK=0
    IO_PORT=$(pick_free_port) || IO_PORT=2053
    IO_BASE=$(rand_string 12); IO_USER=$(rand_string 10); IO_PASS=$(rand_string 14)
    [[ $quick == 1 ]] && return 0

    ui_section "Install options - $(panel_label "$panel")"
    menu_select_b "Panel port" 1 "🎲   Random free port (recommended)  [${IO_PORT}]" "✏️   Choose my own port" || return 1
    if [[ $MENU_RESULT == 2 ]]; then
        while true; do
            prompt_input "Panel port (1-65535): " || return 1
            v=$INPUT_VALUE
            if ! valid_port "$v"; then ui_err "Not a valid port."; continue; fi
            if port_in_use "$v"; then ui_err "Port ${v} is already in use."; continue; fi
            IO_PORT=$v; break
        done
    fi

    if [[ $panel == 3x-ui || $panel == alireza ]]; then
        prompt_input "Secret web path [random: ${IO_BASE}]: " 0 "$IO_BASE" || return 1
        v=${INPUT_VALUE#/}; v=${v%/}
        [[ $v =~ ^[A-Za-z0-9_-]{1,40}$ ]] || { ui_err "Use letters, digits, - and _ only."; return 1; }
        IO_BASE=$v
    else
        IO_BASE=""
        [[ $panel == x-ui ]] && ui_info "Classic x-ui has no secret-path option; the panel is served at the root."
    fi

    if [[ $panel == nx ]]; then
        ui_info "NX Panel creates its admin account in the browser setup wizard (one-time link printed at the end)."
        IO_USER=""; IO_PASS=""
    else
        prompt_input "Admin username [random: ${IO_USER}]: " 0 "$IO_USER" || return 1
        [[ $INPUT_VALUE =~ ^[A-Za-z0-9._-]{3,32}$ ]] || { ui_err "Username: 3-32 chars of letters, digits, . _ -"; return 1; }
        IO_USER=$INPUT_VALUE
        prompt_input "Admin password (Enter = generated, min 8 chars): " 1 "$IO_PASS" || return 1
        (( ${#INPUT_VALUE} >= 8 )) || { ui_err "Password must be at least 8 characters."; return 1; }
        [[ $INPUT_VALUE =~ ^[A-Za-z0-9._@%+=:,-]+$ ]] || { ui_err "Use letters, digits and . _ @ % + = : , - only (keeps the installer safe)."; return 1; }
        IO_PASS=$INPUT_VALUE
    fi

    [[ $quick == 2 ]] && return 0          # settings-only mode: no database / nginx questions

    if [[ $panel == nx || $panel == 3x-ui ]]; then
        menu_select_b "Database" 1 "SQLite  (simple, recommended for most setups)" "PostgreSQL  (installed locally - for very large user counts)" || return 1
        [[ $MENU_RESULT == 2 ]] && IO_DB=postgres
    fi

    if confirm "Put Nginx with HTTPS in front of the panel? (needs a domain pointing to this server)" n; then
        prompt_input "Panel domain (e.g. panel.example.com): " || return 1
        v=${INPUT_VALUE,,}
        [[ $v =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || { ui_err "Invalid domain name."; return 1; }
        IO_DOMAIN=$v
        prompt_input "E-mail for Let's Encrypt expiry notices ('-' to skip): " 0 "-" || return 1
        [[ $INPUT_VALUE == "-" ]] || IO_EMAIL=$INPUT_VALUE
        IO_NGINX=1
        if confirm "Bind the panel to 127.0.0.1 so it is reachable ONLY through Nginx? (recommended)" y; then IO_LOOPBACK=1; fi
    fi
}

# Applies port / path / credentials / bind address and restarts the panel.
apply_panel_settings() {   # apply_panel_settings <panel>
    local panel=$1 svc cli ok=1 i
    svc=$(panel_service "$panel"); cli=$(panel_cli "$panel")
    case $panel in
        nx)
            "$cli" config set web_listen_port "$IO_PORT" >/dev/null 2>&1 || ok=0
            (( IO_LOOPBACK )) && { "$cli" config set web_listen_ip 127.0.0.1 >/dev/null 2>&1 || ok=0; }
            systemctl restart "$svc" ;;
        3x-ui)
            "$cli" setting -username "$IO_USER" -password "$IO_PASS" -port "$IO_PORT" -webBasePath "$IO_BASE" >/dev/null 2>&1 || ok=0
            (( IO_LOOPBACK )) && { "$cli" setting -listenIP 127.0.0.1 >/dev/null 2>&1 || ok=0; }
            systemctl restart "$svc" ;;
        alireza)
            "$cli" setting -username "$IO_USER" -password "$IO_PASS" -port "$IO_PORT" -webBasePath "$IO_BASE" >/dev/null 2>&1 || ok=0
            if (( IO_LOOPBACK )); then
                systemctl stop "$svc"; db_set_setting /etc/x-ui/x-ui.db webListen 127.0.0.1 || ok=0
            fi
            systemctl restart "$svc" ;;
        x-ui)
            "$cli" setting -username "$IO_USER" -password "$IO_PASS" >/dev/null 2>&1 || ok=0
            "$cli" setting -port "$IO_PORT" >/dev/null 2>&1 || ok=0
            if (( IO_LOOPBACK )); then
                systemctl stop "$svc"; db_set_setting /etc/x-ui/x-ui.db webListen 127.0.0.1 || ok=0
            fi
            systemctl restart "$svc" ;;
    esac
    (( ok )) || ui_warn "Some settings could not be applied - check them with: $(basename "$cli") setting -show true"
    for (( i = 0; i < 20; i++ )); do systemctl is-active --quiet "$svc" && break; sleep 0.5; done
    systemctl is-active --quiet "$svc" || { ui_err "${svc} did not start after applying the settings."; return 1; }
    ui_ok "Settings applied: port ${IO_PORT}${IO_BASE:+, path /${IO_BASE}/}$( (( IO_LOOPBACK )) && printf ', bound to 127.0.0.1')."
}

run_panel_installer() {   # run_panel_installer <panel>  (uses IO_*)
    local panel=$1 dir inst
    dir=$(mktemp -d "${BACKUP_HOME}/.moc-install.XXXXXX") || { ui_err "Cannot create a temporary directory."; return 1; }
    register_cleanup "$dir"; inst="${dir}/install.sh"
    download_installer "$inst" "$(panel_installer_url "$panel")" || { ui_err "Installer download failed. Nothing was installed."; return 1; }
    ui_info "Running the official installer for $(panel_label "$panel") - its own output follows."
    case $panel in
        nx)
            if [[ $IO_DB == postgres ]]; then bash "$inst" --postgres </dev/null; else bash "$inst" </dev/null; fi ;;
        3x-ui)
            XUI_NONINTERACTIVE=1 XUI_SSL_MODE=none XUI_DB_TYPE="$IO_DB" XUI_USERNAME="$IO_USER" XUI_PASSWORD="$IO_PASS" \
                XUI_PANEL_PORT="$IO_PORT" XUI_WEB_BASE_PATH="$IO_BASE" bash "$inst" </dev/null ;;
        alireza)
            XUI_NONINTERACTIVE=1 XUI_USERNAME="$IO_USER" XUI_PASSWORD="$IO_PASS" XUI_PANEL_PORT="$IO_PORT" \
                XUI_WEB_BASE_PATH="$IO_BASE" bash "$inst" </dev/null ;;
        x-ui)
            printf 'n\n' | bash "$inst" ;;      # answers "no" to the credentials prompt; values are applied below
    esac || { ui_err "The official installer failed."; return 1; }
    panel_installed "$panel" || { ui_err "Installation finished but ${panel} was not found."; return 1; }
}

# install_panel_flow <panel> <quick 0|1>   -> installs + customises + optional nginx; writes a credentials file
install_panel_flow() {
    local panel=$1 quick=${2:-0} url ip="" report tok host
    if panel_installed "$panel"; then
        ui_warn "$(panel_label "$panel") is already installed here."
        confirm "Re-run the official installer over it (keeps the database)?" n || return 0
    fi
    require_tools curl || return 1
    collect_install_options "$panel" "$quick" || return 1
    run_panel_installer "$panel" || return 1
    apply_panel_settings "$panel" || return 1

    detect_public_ip && ip=$PUB_IP
    if (( IO_NGINX )); then
        ui_section "Nginx + HTTPS"
        if [[ -n $ip ]] && ! { dns_check_domain "$IO_DOMAIN" "$ip"; [[ $DNS_STATE == MATCH || $DNS_STATE == CDN ]]; }; then
            alert_box "DNS is not ready for ${IO_DOMAIN}" "Create:  A   ${IO_DOMAIN}   ->   ${ip}   (currently: ${DNS_NOW})" "Let's Encrypt cannot issue a certificate until it resolves here."
            confirm "Continue anyway? (HTTP only until you fix DNS)" n || { ui_info "Skipped Nginx. Run this menu again after fixing DNS."; IO_NGINX=0; }
        fi
        (( IO_NGINX )) && { setup_nginx_proxy "$IO_DOMAIN" "$IO_PORT" "$IO_EMAIL" || ui_warn "Nginx setup did not complete."; }
    else
        open_firewall "$IO_PORT"
    fi

    host=${ip:-<SERVER_IP>}
    if (( IO_NGINX )); then host=$IO_DOMAIN; fi
    report="${BACKUP_HOME}/moc-panel-${panel}-$(date +%Y%m%d-%H%M%S).txt"
    {
        printf 'Panel   : %s\n' "$(panel_label "$panel")"
        if [[ $panel == nx ]]; then
            tok=$("$(panel_cli nx)" setup-token 2>/dev/null | tail -n 1)
            if (( IO_NGINX )); then printf 'Setup   : https://%s/setup?t=%s\n' "$host" "$tok"
            else printf 'Setup   : http://%s:%s/setup?t=%s\n' "$host" "$IO_PORT" "$tok"; fi
        else
            if (( IO_NGINX )); then printf 'URL     : https://%s/%s\n' "$host" "${IO_BASE:+${IO_BASE}/}"
            else printf 'URL     : http://%s:%s/%s\n' "$host" "$IO_PORT" "${IO_BASE:+${IO_BASE}/}"; fi
            printf 'Username: %s\nPassword: %s\n' "$IO_USER" "$IO_PASS"
        fi
        printf 'Port    : %s\nDatabase: %s\n' "$IO_PORT" "$IO_DB"
    } >"$report"
    chmod 600 "$report"

    ui_section "Installation complete"
    while IFS= read -r url; do ui_kv "${url%%:*}" "${url#*: }" "$C_GREEN"; done <"$report"
    ui_info "Saved (root only) to: ${report}  - move it somewhere safe and delete it."
    if [[ $panel == nx && $IO_NGINX == 1 ]]; then
        ui_warn "Behind Nginx: in the NX setup wizard keep the panel on plain HTTP, then add 127.0.0.1 under Settings -> Security -> trusted_proxies."
    fi
    if [[ $panel == nx ]]; then ui_info "Setup link lost? Run:  nx-panel setup-token"; fi
}

# ── Migration report ──────────────────────────────────────────────────────────
TAB=$'\t'
RPT_TITLE="MIGRATION REPORT"
RPT_STEPS=() RPT_DNS=() RPT_ACCESS=() RPT_FILES=() RPT_FACTS=() RPT_NEXT=() RPT_DATA=()
MIG_START=0 MIG_TARGET=""

rpt_reset()  { RPT_STEPS=(); RPT_DNS=(); RPT_ACCESS=(); RPT_FILES=(); RPT_FACTS=(); RPT_NEXT=(); RPT_DATA=(); MIG_START=$(date +%s); }
rpt_add()    { RPT_STEPS+=("$1${TAB}$2${TAB}${3:-}"); }          # rpt_add OK|WARN|FAIL|SKIP <title> [detail]
rpt_fact()   { RPT_FACTS+=("$1${TAB}$2"); }
rpt_access() { RPT_ACCESS+=("$1${TAB}$2"); }
rpt_file()   { RPT_FILES+=("$1${TAB}$2"); }


render_report() {        # render_report <color 1|0>
    local col=$1 e='' g='' y='' r='' c='' d='' b='' w='' line st title detail k v n=1 inner text pad left right
    local ok=0 wn=0 fl=0 sk=0 elapsed host sym color fill kind name _d _e days state used use tw pre
    local -a nxt=()
    if (( col )); then e=$C_RESET g=$C_GREEN y=$C_YELLOW r=$C_RED c=$C_CYAN d=$C_DIM b=$C_BOLD w=$C_WHITE; fi

    for line in "${RPT_STEPS[@]}"; do
        IFS=$'\t' read -r st _ <<<"$line"
        case $st in OK) ok=$((ok + 1)) ;; WARN) wn=$((wn + 1)) ;; FAIL) fl=$((fl + 1)) ;; *) sk=$((sk + 1)) ;; esac
    done
    elapsed=$(( $(date +%s) - MIG_START )); (( MIG_START == 0 )) && elapsed=0
    host=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown)

    inner=$(( UI_COLS - 6 ))
    if [[ $SERVER_VERDICT == READY ]]; then text="${I_OK}${I_GAP}${RPT_TITLE}  -  SERVER READY FOR SERVICE"; color=$g
    else text="${I_ERR}${I_GAP}${RPT_TITLE}  -  SERVER OUT OF SERVICE"; color=$r; fi
    pad=$(( inner - ${#text} - 1 )); (( pad < 0 )) && pad=0; left=$(( pad / 2 )); right=$(( pad - left ))   # the icon is two cells wide
    fill=$(printf '%*s' "$inner" '' | sed 's/ /═/g')
    printf '\n %s╔%s╗%s\n' "$color" "$fill" "$e"
    printf ' %s║%*s%s%s%s%*s║%s\n' "$color" "$left" '' "$b" "$text" "$color" "$right" '' "$e"
    printf ' %s╚%s╝%s\n' "$color" "$fill" "$e"

    rsec() { local t=$1 f; f=$(printf '%*s' $(( UI_COLS - 8 - ${#t} )) '' | sed 's/ /─/g'); printf '\n %s── %s%s%s %s%s%s\n' "$c" "$b$w" "$t" "$e$c" "$d" "$f" "$e"; }
    rprint() {   # rprint <prefix> <indent> <text> - wrapped at word boundaries, hanging indent, never truncated
        local pre=$1 ind=$2 txt=$3 w row first=1
        local -a rows=()
        txt=${txt//$'\n'/ }
        w=$(( UI_COLS - 3 - ind )); (( w < 30 )) && w=30
        if (( ${#txt} > w )); then IFS=$'\x1f' read -ra rows < <(pywrap "$w" "$txt"); else rows=("$txt"); fi
        for row in "${rows[@]}"; do
            if (( first )); then printf '%s%s%s%s\n' "$pre" "$LRM" "$row" "$e"; first=0
            else printf '%*s%s%s%s\n' "$ind" '' "$LRM" "$row" "$e"; fi
        done
    }
    rkv() { local lab; printf -v lab '%-18s' "$1"; rprint " ${c}▌${e}  ${d}${lab}${e} ${3:-}" 23 "$2"; }

    rsec "OVERVIEW"
    rkv "DATE" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    rkv "THIS SERVER" "$host"
    rkv "DURATION" "$(( elapsed / 60 ))m $(printf '%02d' $(( elapsed % 60 )))s"
    for line in "${RPT_FACTS[@]}"; do
        IFS=$'\t' read -r k v <<<"$line"
        rkv "$k" "$v"
    done
    printf ' %s▌%s  %s%-18s%s %s%d passed%s · %s%d warnings%s · %s%d failed%s · %d skipped\n' "$c" "$e" "$d" "CHECKS" "$e" "$g" "$ok" "$e" "$y" "$wn" "$e" "$r" "$fl" "$e" "$sk"

    rsec "STEPS"
    for line in "${RPT_STEPS[@]}"; do
        IFS=$'\t' read -r st title detail <<<"$line"
        case $st in OK) sym=$I_OK; color=$g ;; WARN) sym=$I_WARN; color=$y ;; FAIL) sym=$I_ERR; color=$r ;; *) sym='-'; color=$d ;; esac
        rprint " ${color}${sym}${e}  ${b}" 5 "$title"
        [[ -n $detail ]] && rprint "     ${d}" 5 "$detail"
    done

    if (( ${#RPT_DNS[@]} )); then
        rsec "DNS RECORDS"
        printf ' %s   %-34s %-15s %s%s\n' "$d" "DOMAIN" "STATE" "RESOLVES TO" "$e"
        for line in "${RPT_DNS[@]}"; do
            IFS=$'\t' read -r k st v <<<"$line"
            case $st in MATCH) color=$g ;; CDN|PROPAGATING) color=$y ;; *) color=$r ;; esac
            printf '    %-34.34s %s%-15s%s %s\n' "$k" "$color" "$st" "$e" "$v"
        done
    fi

    if (( ${#RPT_ACCESS[@]} )); then
        rsec "ACCESS"
        for line in "${RPT_ACCESS[@]}"; do
            IFS=$'\t' read -r k v <<<"$line"
            rkv "$k" "$v" "$g"
        done
    fi

    if (( CERT_TOTAL >= 0 )) && [[ -s ${CERT_FILE:-/nonexistent} || $CERT_TOTAL -eq 0 ]]; then
        rsec "CERTIFICATES ON THIS SERVER"
        if (( CERT_EXPIRED > 0 )); then color=$r; elif (( CERT_SOON > 0 || CERT_UNUSED > 0 )); then color=$y; else color=$g; fi
        rkv "SUMMARY" "$(cert_line)" "$color"
        if (( CERT_TOTAL > 0 )); then
            printf ' %s%-32s %-28s %s%s\n' "$d" "CERTIFICATE" "STATUS" "IN USE" "$e"
            tw=0
            while IFS=$'\t' read -r kind name _d _e days state used; do
                (( ++tw > 8 )) && break
                case $state in expired) color=$r ;; soon) color=$y ;; *) color=$g ;; esac
                case $used in 1) use="yes" ;; 0) use="NO" ;; *) use="?" ;; esac
                printf ' %-32.32s %s%-28s%s %s\n' "$name" "$color" "$(cert_when "$state" "$days")" "$e" "$use"
            done < <(awk -F'\t' '{ k = ($6 == "expired") ? 0 : (($7 == 0) ? 1 : (($6 == "soon") ? 2 : 3)); print k "\t" $0 }' "$CERT_FILE" | sort -t$'\t' -k1,1n -k6,6n | cut -f2-)
        fi
    fi

    if (( ${#RPT_FILES[@]} )); then
        rsec "FILES & ROLLBACK COPIES"
        for line in "${RPT_FILES[@]}"; do
            IFS=$'\t' read -r k v <<<"$line"
            rkv "$k" "$v"
        done
    fi

    if [[ $SERVER_VERDICT != READY ]]; then
        nxt+=("Point every record listed under DNS RECORDS to this server's IP at your DNS provider.")
        nxt+=("Re-check later with:  sudo bash $(basename "$0") --verify   (keep the OLD server online until the verdict is READY).")
    fi
    for line in "${RPT_NEXT[@]}"; do nxt+=("$line"); done
    if (( CERT_EXPIRED > 0 || CERT_UNUSED > 0 )); then
        nxt+=("Clean up ${CERT_EXPIRED} expired / ${CERT_UNUSED} unused certificate(s): main menu -> System optimization (nothing is deleted without your confirmation).")
    fi
    nxt+=("Log in to the panel and connect a real client through one inbound; confirm the traffic counters move.")
    nxt+=("Keep the old server running until DNS has propagated (check your TTL), then retire it.")
    nxt+=("Delete the backup archive and the rollback copies above when you no longer need them - they contain secrets.")
    nxt+=("Enable scheduled backups (the panel's own backup feature, or this script on a cron job).")
    rsec "NEXT STEPS"
    for line in "${nxt[@]}"; do
        printf -v pre ' %s%2d.%s  ' "$c" "$n" "$e"
        rprint "$pre" 6 "$line"; n=$((n + 1))
    done
    if (( ${#RPT_DATA[@]} )); then
        rsec "WHAT WAS MIGRATED"
        for line in "${RPT_DATA[@]}"; do
            IFS=$'\t' read -r k v <<<"$line"
            rkv "${k^^}" "$v" "$w"
        done
    fi
    printf '\n %s%s  ·  v%s%s\n\n' "$d" "$SIGNATURE" "$SCRIPT_VERSION" "$e"
    unset -f rsec rkv rprint
}

print_final_report() {   # print_final_report [title]
    local f db=""
    [[ -n ${1:-} ]] && RPT_TITLE=$1
    f="${BACKUP_HOME}/moc-migration-report-$(date +%Y%m%d-%H%M%S).txt"
    [[ -f /etc/x-ui/x-ui.db ]] && db=/etc/x-ui/x-ui.db
    cert_tmp_init
    cert_scan "$CERT_TMP" /etc/letsencrypt/live /root/cert "$db" /etc/nginx
    pb_stop
    typed_begin
    render_report 1
    typed_end
    if render_report 0 >"$f" 2>/dev/null; then
        chmod 600 "$f"
        ui_kv "REPORT SAVED" "$f" "$C_GREEN"
        ui_info "Plain-text copy (root only) - no passwords are stored in it."
    fi
}

# ── Choosing the destination panel ────────────────────────────────────────────
target_note() {          # target_note <source> <target>  ->  "<fidelity>|<description>"
    local src=$1 id=$2
    if [[ $id == nx ]]; then
        printf 'converted|Wizard re-imports users & inbounds (converted copy).'
        return
    fi
    case $(panel_compat "$src" "$id") in
        same)      printf 'exact|Exact copy of your database. Lowest risk.' ;;
        upgrade)   printf 'exact+upgrade|Exact copy; schema upgraded on first start.' ;;
        downgrade) printf 'OLDER LINE|Older than your backup: the database is imported as-is, features it does not know are ignored. You will be asked to confirm.' ;;
        *)         printf 'unknown|Source type unknown - cannot check compatibility.' ;;
    esac
}

# choose_migration_target <source-panel>  -> MIG_TARGET (nx | 3x-ui | alireza | x-ui)
# Every panel is offered; NX Panel is recommended when the free edition can hold the data.
choose_migration_target() {
    local src=$1 rec why id note fid desc color tag nx_ok=1 mark mcol w=$(( UI_COLS - 12 )) row first
    local -a pool=(nx 3x-ui alireza x-ui) ids=() labels=() rows=()
    (( BF_USERS > NX_FREE_USERS )) && nx_ok=0
    if (( nx_ok )); then
        rec=nx; why="a modern, actively developed multi-node platform; your ${BF_USERS} user(s) fit in its free edition (${NX_FREE_USERS} users / ${NX_FREE_NODES} nodes)."
    else
        case $src in 3x-ui|alireza|x-ui) rec=$src ;; *) rec=3x-ui ;; esac
        why="NX Panel's free edition cannot hold ${BF_USERS} users, and this panel keeps your data as an exact copy."
    fi
    ids=("$rec")
    for id in "${pool[@]}"; do [[ $id == "$rec" ]] || ids+=("$id"); done

    while true; do
        labels=()
        ui_section "$(t target_title)"
        ui_kv "BACKUP CAME FROM" "$(panel_label "$src")${PANEL_CONF:+   (detected from the database - ${PANEL_CONF} confidence)}" "$C_YELLOW"
        ui_kv "YOUR DATA" "${BF_USERS} users · ${BF_INB} inbounds · ${BF_NDOM} domains"
        ui_info "$(t target_hint)"
        printf '\n'
        for id in "${ids[@]}"; do
            note=$(target_note "$src" "$id"); fid=${note%%|*}; desc=${note#*|}
            if [[ $id == nx ]]; then
                if (( nx_ok )); then desc+="  Free edition: ${NX_FREE_USERS} users / ${NX_FREE_NODES} nodes."
                else fid="TOO MANY USERS"; desc="Free edition: max ${NX_FREE_USERS} users / ${NX_FREE_NODES} nodes - ${BF_USERS} users do not fit."; fi
            fi
            case $fid in exact|exact+upgrade) color=$C_GREEN ;; "TOO MANY USERS") color=$C_RED ;; *) color=$C_YELLOW ;; esac
            tag=""
            [[ $id == "$rec" ]] && tag="${I_STAR} recommended"
            if [[ $id == "$src" ]]; then tag+="${tag:+ · }your current panel"; fi
            mark='○'; mcol=$C_DIM; [[ $id == "$rec" ]] && { mark=$I_STAR; mcol=$C_GREEN; }
            printf ' %s%s%s  %s%s%s   %s[%s]%s   %s%s%s\n' "$mcol" "$mark" "$C_RESET" "$C_BOLD" "$(panel_label "$id")" "$C_RESET" "$color" "$fid" "$C_RESET" "$C_DIM" "$tag" "$C_RESET"
            IFS=$'\x1f' read -ra rows < <(pywrap "$w" "$desc")
            for row in "${rows[@]}"; do printf '       %s%s%s\n' "$C_DIM" "$row" "$C_RESET"; done
            labels+=("$(panel_label "$id")   [${fid}]${tag:+   ${tag}}")
        done
        printf '\n'; say "$C_GREEN" "$I_STAR" "Recommendation: $(panel_label "$rec") - ${why}"
        if (( ! nx_ok )); then
            alert_box "NX PANEL FREE EDITION CANNOT HOLD THIS DATA" \
                "You have ${BF_USERS} users; the free edition supports ${NX_FREE_USERS} users and ${NX_FREE_NODES} nodes." \
                "Migrate to 3x-ui (Sanaei), Alireza or classic x-ui instead, or keep the panel you already use."
        fi
        printf '\n'
        menu_select_b "Which panel should this server run?" 1 "${labels[@]}" || return 1
        MIG_TARGET=${ids[MENU_RESULT-1]}
        if [[ $MIG_TARGET != nx && $(panel_compat "$src" "$MIG_TARGET") == downgrade ]]; then
            notice_box "A NOTE ABOUT $(panel_label "$MIG_TARGET")" \
                "Your backup comes from $(panel_label "$src"), which is a newer / richer panel." \
                "Panels of this family share most of the schema, so the import normally works - only your database must be imported correctly." \
                "Features that $(panel_label "$MIG_TARGET") does not know (for example newer client or node settings) are ignored, and the panel may need a restart. A copy of everything is kept for rollback."
            confirm "I understand - continue with $(panel_label "$MIG_TARGET")?" y || continue
        fi
        if [[ $MIG_TARGET == nx ]] && (( ! nx_ok )); then
            ui_warn "NX Panel without a licence cannot hold ${BF_USERS} users."
            confirm "I already own a paid NX licence that covers ${BF_USERS} users - continue with NX Panel?" n && return 0
            continue
        fi
        return 0
    done
}

# snapshot_panel <panel> -> SNAP_FILE   (tar of everything the panel keeps on disk)
SNAP_FILE=""
snapshot_panel() {
    local p=$1 d f
    local -a paths=() cand=()
    SNAP_FILE=""
    if [[ $p == nx ]]; then cand=(/opt/nx-panel /var/opt/nx-panel /etc/systemd/system/nx-panel.service)
    else cand=(/etc/x-ui /usr/local/x-ui /usr/bin/x-ui /etc/default/x-ui /etc/systemd/system/x-ui.service); fi
    for d in "${cand[@]}"; do [[ -e $d ]] && paths+=("${d#/}"); done
    (( ${#paths[@]} )) || return 1
    f="${BACKUP_HOME}/pre-replace-${p}-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -C / -czf "$f" "${paths[@]}" 2>/dev/null; chmod 600 "$f" 2>/dev/null
    [[ -s $f ]] || return 1
    SNAP_FILE=$f
}
remove_panel() {   # remove_panel <panel>   (the NX data folder is kept, exactly like the official uninstall)
    local p=$1
    if [[ $p == nx ]]; then
        systemctl disable --now nx-panel >/dev/null 2>&1
        rm -f -- /etc/systemd/system/nx-panel.service; rm -rf -- /opt/nx-panel
    else
        systemctl disable --now x-ui >/dev/null 2>&1
        rm -f -- /etc/systemd/system/x-ui.service /usr/bin/x-ui; rm -rf -- /usr/local/x-ui /etc/x-ui
    fi
    systemctl daemon-reload >/dev/null 2>&1
}
# replace_installed_panels <target>  -> 0 go on, 1 cancelled / failed, 3 = Back
replace_installed_panels() {
    local tgt=$1 p label tl rc
    local -a others=()
    mapfile -t others < <(installed_panels | grep -vx "$tgt")
    (( ${#others[@]} )) || return 0
    tl=$(panel_label "$tgt")
    for p in "${others[@]}"; do
        label=$(panel_label "$p")
        notice_box "$(panel_label "$p") IS ALREADY INSTALLED ON THIS SERVER" \
            "You chose ${tl}. Before it is installed, ${label} must be handled." \
            "A full backup copy of ${label} (database, settings, service files) is made first and kept in ${BACKUP_HOME}; only then is it removed."
        if [[ $tgt != nx && $p != nx ]]; then       # same family: they share /etc/x-ui and the x-ui service
            menu_select_b "What should happen to ${label}?" 1 "💾   Back it up, REMOVE it and install ${tl}" || return 3
        else
            menu_select_b "What should happen to ${label}?" 1 "💾   Back it up, REMOVE it and install ${tl}" "🧩   Keep ${label} running next to ${tl} (different ports)" || return 3
            [[ $MENU_RESULT == 2 ]] && { rpt_add OK "Kept ${label} next to ${tl}"; continue; }
        fi
        confirm "Back up and permanently remove ${label} now?" n || return 1
        if snapshot_panel "$p"; then
            ui_ok "Backup of ${label} saved: ${SNAP_FILE}"; rpt_file "OLD PANEL BACKUP" "$SNAP_FILE"
        else
            ui_err "Could not create the backup of ${label} - nothing was removed."; return 1
        fi
        remove_panel "$p"
        ui_ok "${label} removed. Its backup stays at ${SNAP_FILE}."
        rpt_add OK "Backed up and removed ${label}" "$SNAP_FILE"
    done
    return 0
}

# print_migration_plan <source> <target> <backup-mode> <domain-count> <has-web 0|1> -> confirm
print_migration_plan() {
    local src=$1 tgt=$2 bmode=$3 ndom=$4 web=$5 op=${6:-1} n=0 compat rc others
    others=$(installed_panels | grep -vx "$tgt" | paste -sd, - | sed 's/,/, /g')
    step() { n=$((n + 1)); printf ' %s%d.%s %s\n' "$C_CYAN" "$n" "$C_RESET" "$1"; }
    ui_section "Your migration plan:  $(panel_label "$src")  ->  $(panel_label "$tgt")"
    printf ' %s%s%s%sBackup validated (archive safety, SQLite integrity, panel detection)\n' "$C_GREEN" "$I_OK" "$C_RESET" "$I_GAP"
    if [[ -n $others ]]; then step "Another panel is installed here (${others}): you decide what happens to it - if it is removed, a full backup copy is made first"; fi
    if [[ $tgt == nx ]]; then
        if panel_installed nx; then step "Reuse the NX Panel already installed on this server"
        else step "Install NX Panel with your own port / database options (official installer)"; fi
        step "Download nx-migrate, verify its SHA-256, serve the wizard over HTTPS on this server's address (no SSH tunnel needed)"
        step "Verify DNS for ${ndom} domain(s) against the IP of the NX node that will serve them"
    else
        compat=$(panel_compat "$src" "$tgt")
        if panel_installed "$tgt"; then step "Reuse the installed $(panel_label "$tgt"); its current database is copied aside, then replaced"
        else step "Install $(panel_label "$tgt") with the official installer"; fi
        case $compat in
            same)      step "Restore your database exactly as it is (same panel, nothing is converted)" ;;
            upgrade)   step "Restore your database; $(panel_label "$tgt") upgrades its schema on first start" ;;
            downgrade) step "Restore your database into an older panel - ${C_YELLOW}features it does not know are ignored${C_RESET}" ;;
            *)         step "Restore your database (compatibility unknown)" ;;
        esac
        if (( web )); then step "Restore Nginx config, Let's Encrypt certificates and web root (nginx -t, automatic rollback)"
        elif [[ $bmode == PANEL_ONLY ]]; then step "Backup has no web stack - you can add Nginx + HTTPS in front of the panel"; fi
        step "Choose: keep the old port / secret path / login, or change them"
        step "Verify DNS for ${ndom} domain(s), service, port, TLS and inbounds"
    fi
    step "Final report with every result, files kept for rollback and next steps"
    unset -f step
    printf '\n'
    if (( op == 2 )); then ui_info "Test mode: this is exactly what a real migration would do. Nothing was changed."; return 0; fi
    menu_select_b "Start this plan now?" 1 "🚀   Start the migration now" "🛑   Cancel - change nothing" || rc=$?
    rc=${rc:-0}
    (( rc == 3 )) && return 3
    (( rc == 0 )) && [[ $MENU_RESULT == 1 ]] && return 0
    return 1
}

# ── Backup facts: users, domains, inbounds, how the service is exposed ───────
readonly NX_FREE_USERS=50 NX_FREE_NODES=2      # NX Panel free edition (confirm on the NX licence page)
BF_USERS=0 BF_INB=0 BF_INB_EN=0 BF_PROTOS="" BF_TRAFFIC=0 BF_NDOM=0 BF_DOMTYPES=""
BF_PFRONT="direct" BF_PPORT="" BF_PLISTEN="" BF_HAVE_NGX=0
declare -A DNS_CF_CACHE=()
DNS_PROBE=""

nginx_active_paths() {   # nginx_active_paths <nginx-base-dir>  -> config paths that are really loaded
    local b=$1 p
    for p in "$b/nginx.conf" "$b/conf.d" "$b/sites-enabled" "$b/stream.d" "$b/streams-enabled"; do
        [[ -e $p ]] && printf '%s\n' "$p"
    done
    return 0
}

human_bytes() { awk -v b="${1:-0}" 'BEGIN { split("B KB MB GB TB PB", u, " "); i = 1; while (b >= 1024 && i < 6) { b /= 1024; i++ } printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'; }

domain_types() {         # domain_types <domains-file> -> "Panel 1, Inbound TLS 2, ..."
    [[ -s $1 ]] || return 0
    awk -F'\t' '{
        n = split($2, a, ","); delete seen
        for (i = 1; i <= n; i++) {
            t = a[i]
            if (t ~ /^panel:webDomain/) t = "Panel"
            else if (t ~ /^panel:subDomain/) t = "Subscription"
            else if (t == "inbound-tls" || t == "inbound-host") t = "Inbound TLS/host"
            else if (t == "host") t = "CDN host"
            else if (t == "nginx") t = "Nginx"
            else if (t ~ /^cert/) t = "Certificate"
            else continue
            if (!(t in seen)) { seen[t] = 1; c[t]++ }
        }
    } END { for (k in c) printf "%s %d\n", k, c[k] }' "$1" | sort | paste -sd, - | sed 's/,/, /g'
}

# gather_backup_facts <db> <nginx-base-dir|""> <domains-file> [letsencrypt-live-dir]
gather_backup_facts() {
    local db=$1 ngx=$2 dfile=$3 live=${4:-} k v
    local -a paths=()
    BF_USERS=0 BF_INB=0 BF_INB_EN=0 BF_PROTOS="" BF_TRAFFIC=0 BF_PFRONT="direct" BF_PPORT="" BF_PLISTEN="" BF_HAVE_NGX=0
    if [[ -n $ngx && -d $ngx ]]; then
        BF_HAVE_NGX=1; mapfile -t paths < <(nginx_active_paths "$ngx")
    fi
    while IFS='=' read -r k v; do
        case $k in
            users) BF_USERS=$v ;;
            inbounds) BF_INB=$v ;;
            inbounds_enabled) BF_INB_EN=$v ;;
            protocols) BF_PROTOS=$v ;;
            traffic) BF_TRAFFIC=$v ;;
            panel_port) BF_PPORT=$v ;;
            panel_listen) BF_PLISTEN=$v ;;
            panel_front) BF_PFRONT=$v ;;
        esac
    done < <(dbtool stats "$db" "${paths[@]}" 2>/dev/null)
    BF_NDOM=0; BF_DOMTYPES=""
    if [[ -s $dfile ]]; then
        BF_NDOM=$(cut -f1 "$dfile" | sort -u | wc -l | tr -d ' ')
        BF_DOMTYPES=$(domain_types "$dfile")
    fi
    CERT_TOTAL=-1
    if [[ -n $live && -d $live ]]; then
        cert_tmp_init
        cert_scan "$CERT_TMP" "$live" "" "$db" "$ngx"
    fi
}

front_label() {          # panel exposure in words
    case $BF_PFRONT in
        nginx)  printf 'Behind Nginx (reverse proxy -> panel port %s)' "${BF_PPORT:-?}" ;;
        local)  printf 'Bound to %s - reachable only through a proxy or tunnel' "${BF_PLISTEN:-localhost}" ;;
        *)      if (( BF_HAVE_NGX )); then printf 'Direct - port %s is not proxied by Nginx' "${BF_PPORT:-?}"
                else printf 'Direct, or unknown - this backup has no Nginx configuration to check'; fi ;;
    esac
}

nx_tier_label() {
    if (( BF_USERS <= NX_FREE_USERS )); then printf 'fits  (%s of %s users; free edition also allows %s nodes)' "$BF_USERS" "$NX_FREE_USERS" "$NX_FREE_NODES"
    else printf 'DOES NOT FIT  (%s users > %s allowed by the free edition)' "$BF_USERS" "$NX_FREE_USERS"; fi
}

print_backup_overview() {
    local c=$C_GREEN
    ui_kv "USERS" "$BF_USERS" "$C_WHITE"
    ui_kv "INBOUNDS" "${BF_INB_EN} enabled / ${BF_INB} total${BF_PROTOS:+   ($BF_PROTOS)}"
    ui_kv "DOMAINS" "${BF_NDOM}${BF_DOMTYPES:+   ($BF_DOMTYPES)}"
    ui_kv "PANEL ACCESS" "$(front_label)" "$C_YELLOW"
    ui_kv "TRAFFIC USED" "$(human_bytes "$BF_TRAFFIC")"
    if (( CERT_TOTAL >= 0 )); then ui_kv "CERTIFICATES" "$(cert_line)" "$(cert_color)"; fi
    (( BF_USERS > NX_FREE_USERS )) && c=$C_RED
    ui_kv "NX FREE TIER" "$(nx_tier_label)" "$c"
}

rpt_data_from_bf() {
    RPT_DATA=()
    RPT_DATA+=("Users${TAB}${BF_USERS}")
    RPT_DATA+=("Inbounds${TAB}${BF_INB_EN} enabled / ${BF_INB} total${BF_PROTOS:+  (${BF_PROTOS})}")
    RPT_DATA+=("Domains${TAB}${BF_NDOM}${BF_DOMTYPES:+  (${BF_DOMTYPES})}")
    RPT_DATA+=("Panel access${TAB}$(front_label)")
    RPT_DATA+=("Traffic recorded${TAB}$(human_bytes "$BF_TRAFFIC")")
    (( CERT_TOTAL >= 0 )) && RPT_DATA+=("Certificates${TAB}$(cert_line)")
}

# ── Cloudflare / Nginx exposure per inbound ───────────────────────────────────
dns_ready() {            # one quick probe so that offline hosts do not wait on every domain
    if [[ -z $DNS_PROBE ]]; then
        if [[ -n $(dns_a cloudflare.com "") ]]; then DNS_PROBE=yes; else DNS_PROBE=no; fi
    fi
    [[ $DNS_PROBE == yes ]]
}

domain_cdn() {           # domain_cdn <domain> -> 0 = behind Cloudflare, 1 = not, 2 = unknown
    local d=$1 ips ip all_cf=1
    [[ -n $d ]] || return 2
    if [[ -n ${DNS_CF_CACHE[$d]:-} ]]; then return "${DNS_CF_CACHE[$d]}"; fi
    if ! dns_ready; then DNS_CF_CACHE[$d]=2; return 2; fi
    ips=$(dns_a "$d" "")
    if [[ -z $ips ]]; then DNS_CF_CACHE[$d]=2; return 2; fi
    while read -r ip; do is_cloudflare_ip "$ip" || all_cf=0; done <<<"$ips"
    if (( all_cf )); then DNS_CF_CACHE[$d]=0; return 0; fi
    DNS_CF_CACHE[$d]=1; return 1
}

# inbound_table <db> <nginx-base-dir|"">
inbound_table() {
    local db=$1 ngx=$2 port proto remark en net sec host front nclients label color n=0 cdn
    local nb=0 cfn=0 dn=0 ln=0 nrow=0 first
    local -a paths=() rows2=()
    [[ -n $ngx && -d $ngx ]] && mapfile -t paths < <(nginx_active_paths "$ngx")
    printf '\n %s   %-6s %-11s %-9s %-8s %s%s\n' "$C_DIM" "PORT" "PROTOCOL" "TRANSPORT" "SECURITY" "USERS" "$C_RESET"
    while IFS=$'\t' read -r _ port proto remark en net sec _ host front nclients; do
        [[ -n $port ]] || continue
        [[ $host == "-" ]] && host=""
        (( ++n > 40 )) && { ui_info "Only the first 40 inbounds are listed."; break; }
        cdn=2
        if [[ $net =~ ^(ws|grpc|httpupgrade|xhttp|splithttp)$ || $sec == tls ]]; then domain_cdn "$host"; cdn=$?; fi
        case $front in
            nginx) label="Nginx -> Xray"; nb=$((nb + 1)) ;;
            local) label="Local only (proxy config not in backup)"; ln=$((ln + 1)) ;;
            *)     label="Direct on :${port}"; dn=$((dn + 1)) ;;
        esac
        if (( cdn == 0 )); then label="Cloudflare -> ${label}"; cfn=$((cfn + 1)); color=$C_PURPLE
        elif [[ $front == nginx ]]; then color=$C_GREEN
        elif [[ $front == local ]]; then color=$C_YELLOW
        else color=$C_BLUE; fi
        [[ $en == 1 ]] || label="$label  (disabled)"
        printf ' %s▌%s  %-6s %-11.11s %-9.9s %-8.8s %s\n' "$C_CYAN" "$C_RESET" "$port" "$proto" "$net" "$sec" "$nclients"
        IFS=$'\x1f' read -ra rows2 < <(pywrap $(( UI_COLS - 14 )) "${label}${host:+  [${host}]}")
        for first in "${rows2[@]}"; do
            if (( nrow++ == 0 )); then printf '    %s↳%s  %s%s%s\n' "$C_DIM" "$C_RESET" "$color" "$first" "$C_RESET"
            else printf '       %s%s%s\n' "$color" "$first" "$C_RESET"; fi
        done; nrow=0
    done < <(dbtool inbounds "$db" "${paths[@]}" 2>/dev/null)
    (( n == 0 )) && { ui_info "No inbounds in this database."; return 0; }
    printf '\n'
    ui_kv "SUMMARY" "${nb} via Nginx · ${cfn} via Cloudflare · ${dn} direct · ${ln} local-only"
    if ! dns_ready; then ui_info "DNS is unavailable here, so Cloudflare detection was skipped."; fi
}

# domain_table <domains-file>
domain_table() {
    local d src t cdn tag n=0 types
    [[ -s $1 ]] || { ui_info "No domain names were found."; return 0; }
    printf '\n %s   %-30s %-26s %s%s\n' "$C_DIM" "DOMAIN" "TYPE" "CDN" "$C_RESET"
    while IFS=$'\t' read -r d src; do
        (( ++n > 40 )) && { ui_info "Only the first 40 domains are listed."; break; }
        types=$(awk -v s="$src" 'BEGIN { n = split(s, a, ","); for (i = 1; i <= n; i++) { t = a[i]
            if (t ~ /^panel:webDomain/) t = "Panel"; else if (t ~ /^panel:subDomain/) t = "Subscription"; else if (t == "inbound-tls" || t == "inbound-host") t = "Inbound TLS/host"
            else if (t == "host") t = "CDN host"; else if (t == "nginx") t = "Nginx"; else if (t ~ /^cert/) t = "Certificate"; else continue
            if (!(t in u)) { u[t] = 1; o = o (o ? ", " : "") t } } print o }')
        domain_cdn "$d"; cdn=$?
        case $cdn in 0) tag="${C_PURPLE}Cloudflare${C_RESET}" ;; 1) tag="direct" ;; *) tag="${C_DIM}?${C_RESET}" ;; esac
        printf ' %s▌%s  %-30.30s %-26.26s %s\n' "$C_CYAN" "$C_RESET" "$d" "$types" "$tag"
    done < <(sort -u "$1")
}

# ── Inspect a backup file ─────────────────────────────────────────────────────
backup_valid() {   # backup_valid <file>: only list files this script can really read (a valid archive / an OpenSSL-encrypted one)
    local f=$1 sz magic
    [[ -f $f && ! -L $f && -r $f ]] || return 1
    sz=$(stat -c %s "$f" 2>/dev/null) || return 1
    (( sz > 0 )) || return 1
    case $f in
        *.tar.gz.enc)
            (( sz >= 48 )) || return 1
            magic=$(head -c 8 "$f" 2>/dev/null | tr -d '\0')
            [[ $magic == 'Salted__' ]] ;;
        *.tar.gz)
            gzip -t "$f" 2>/dev/null || return 1
            (( sz > 524288000 )) && return 0
            tar -tzf "$f" 2>/dev/null | grep -qE '(^|/)panel/x-ui\.db$' ;;
        *.zip)
            [[ $(head -c 2 "$f" 2>/dev/null) == PK ]] ;;
        *) return 1 ;;
    esac
}

backup_candidates() {
    local f
    find "$BACKUP_HOME" -maxdepth 2 -type f \
        \( -name 'XUI_Backup_*.tar.gz' -o -name 'XUI_Backup_*.tar.gz.enc' -o -name 'XUI_Backup_*.zip' \) \
        -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2- |
    while IFS= read -r f; do backup_valid "$f" && printf '%s\n' "$f"; done
}

backup_label() {         # backup_label <file> -> "3x-ui · FULL · 2026-10-30 10:10 · 12 MB · encrypted"
    local f=$1 b p="" m="" d="" t="" enc="" re
    b=$(basename "$f")
    re='^XUI_Backup_(.+)_(FULL|PANEL_ONLY)_([0-9]{4}-[0-9]{2}-[0-9]{2})_([0-9]{2})([0-9]{2})[0-9]{2}'
    if [[ $b =~ $re ]]; then
        p=${BASH_REMATCH[1]}; m=${BASH_REMATCH[2]}; d=${BASH_REMATCH[3]}; t="${BASH_REMATCH[4]}:${BASH_REMATCH[5]}"
    fi
    [[ $f == *.enc ]] && enc=" · ${I_LOCK} encrypted"
    if [[ -n $p ]]; then printf '\x01%s\x02 · %s · %s %s · %s%s' "$p" "$m" "$d" "$t" "$(du -h "$f" | cut -f1)" "$enc"
    else printf '%s · %s%s' "${f#"$BACKUP_HOME"/}" "$(du -h "$f" | cut -f1)" "$enc"; fi
}

pause_key() {
    [[ -t 0 ]] || return 0
    printf '\n %s%s%s ' "$C_DIM" "$(t press_key)" "$C_RESET"
    IFS= read -rsn1 _ || true
    printf '\r\033[K'
}

inspect_one() {          # inspect_one <archive>
    local archive=$1 stage root db dt created sv bmode pname enc="no" ndb
    stage=$(mktemp -d "${BACKUP_HOME}/.moc-inspect.XXXXXX") || { ui_err "Cannot create a staging directory."; return 0; }
    chmod 700 "$stage"; register_cleanup "$stage"
    extract_archive "$archive" "$stage" || return 0
    root="${stage}/${ARCHIVE_ROOT}"; db="${root}/panel/x-ui.db"
    if [[ ! -f $db || -L $db || ! -f ${root}/mode.txt ]]; then ui_err "This archive has no panel database - it is not a valid backup."; return 0; fi
    bmode=$(tr -d '\r\n' <"${root}/mode.txt")
    created=""; [[ -f ${root}/created_at.txt && ! -L ${root}/created_at.txt ]] && created=$(tr -d '\r\n' <"${root}/created_at.txt")
    [[ -n $created ]] || created="$(date -r "$archive" '+%Y-%m-%d %H:%M:%S %Z') (file date; older backups do not store it)"
    sv="older than v1.2026.10.28"; [[ -f ${root}/script_version.txt && ! -L ${root}/script_version.txt ]] && sv=$(tr -d '\r\n' <"${root}/script_version.txt")
    [[ $archive == *.enc ]] && enc="yes (AES-256-CBC, PBKDF2)"
    pname=unknown; [[ -f ${root}/panel_name.txt && ! -L ${root}/panel_name.txt ]] && pname=$(tr -d '\r\n' <"${root}/panel_name.txt")
    dt="${stage}/domains.tsv"
    spin_start "Reading the backup (database, domains, certificates)..."
    collect_domains "$dt" "$db" "${root}/nginx" "${root}/ssl/live"
    gather_backup_facts "$db" "${root}/nginx" "$dt" "${root}/ssl/live"
    detect_panel "$db" 0
    spin_stop
    if [[ $PANEL_CONF != high ]] && [[ $(norm_panel "$pname") =~ ^(3x-ui|alireza|x-ui)$ ]]; then
        PANEL_NAME=$(norm_panel "$pname"); PANEL_CONF=medium; PANEL_WHY="panel name stored in the backup; ${PANEL_WHY}"
    fi

    typed_begin
    ui_section "Backup report - $(basename "$archive")"
    ui_kv "CREATED" "$created"
    ui_kv "FILE SIZE" "$(du -h "$archive" | awk '{print $1}')"
    ui_kv "SHA-256" "$(sha256sum "$archive" | awk '{print $1}')" "$C_DIM"
    ui_kv "ENCRYPTED" "$([[ $enc == yes* || $enc == *AES* ]] && echo "${I_LOCK} ${enc}" || echo "$enc")"
    ui_kv "SCRIPT VERSION" "$sv"
    ui_kv "BACKUP MODE" "$bmode  $([[ $bmode == FULL ]] && echo '(panel + Nginx + certificates + web root)' || echo '(panel database only)')"
    print_panel_detection
    ndb=$(sqlite3 -readonly "$db" 'PRAGMA integrity_check;' 2>/dev/null | head -n 1)
    ui_kv "DB INTEGRITY" "${ndb:-unknown}" "$([[ $ndb == ok ]] && echo "$C_GREEN" || echo "$C_RED")"
    print_backup_overview
    ui_section "Inbounds - how each one is served"
    inbound_table "$db" "${root}/nginx"
    ui_section "Domains"
    domain_table "$dt"
    if (( CERT_TOTAL > 0 )); then
        ui_section "Certificates inside this backup"
        cert_table 12
    fi
    if (( BF_USERS > NX_FREE_USERS )); then
        alert_box "NX PANEL FREE EDITION CANNOT HOLD THIS BACKUP" \
            "${BF_USERS} users exceed the free limit of ${NX_FREE_USERS} users / ${NX_FREE_NODES} nodes." \
            "Restore into 3x-ui, Alireza or classic x-ui instead - ideally the panel shown above."
    fi
    typed_end
    rm -rf -- "$stage"
}

do_inspect() {
    local -a found=() labels=()
    local f sel=1
    while true; do
        show_header
        mapfile -t found < <(backup_candidates)
        if (( ${#found[@]} == 0 )); then ui_err "No XUI_Backup_* archive found under ${BACKUP_HOME}."; return 0; fi
        labels=()
        for f in "${found[@]}"; do labels+=("$(backup_label "$f")"); done
        menu_select_b "$(t inspect_title)" "$sel" "${labels[@]}" || return 0
        sel=$MENU_RESULT
        inspect_one "${found[MENU_RESULT-1]}"
        pause_key
    done
}

# ── Workflow 1: backup ────────────────────────────────────────────────────────
prompt_new_password() {
    local p1 p2
    while true; do
        prompt_input "$(t enc_pass_prompt)" 1 || return 1; p1=$INPUT_VALUE
        if (( ${#p1} < 12 )); then ui_err "$(t enc_short)"; continue; fi
        prompt_input "$(t enc_pass_confirm)" 1 || return 1; p2=$INPUT_VALUE
        if [[ $p1 == "$p2" ]]; then INPUT_VALUE=$p1; return 0; fi
        ui_err "$(t enc_mismatch)"
    done
}

transfer_backup() {
    local file=$1
    ui_section "$(t sync_title)"
    confirm "$(t sync_ask)" y || return 0
    ship_to_remote "$file" restore || true
}

do_backup() {
    local -a dbs=()
    local xui_db mode date work stage backup_file part use_enc=0 bk_pass="" vdir dtmp

    ensure_tools tar gzip sqlite3 python3 openssl awk

    ui_step 1 5 "$(t step_precheck)"
    mapfile -t dbs < <(find /etc /usr/local -maxdepth 5 -type f -name 'x-ui.db' 2>/dev/null | sort)
    (( ${#dbs[@]} > 0 )) || die "$(t err_no_db)"
    xui_db=""
    local d
    for d in "${dbs[@]}"; do [[ $d == /etc/x-ui/x-ui.db ]] && xui_db=$d; done     # the live default path wins
    if [[ -z $xui_db ]]; then
        if (( ${#dbs[@]} == 1 )); then
            xui_db=${dbs[0]}
        else
            menu_select_b "$(t pick_db)" 1 "${dbs[@]}" || die "Cancelled."
            xui_db=${dbs[MENU_RESULT-1]}
        fi
    fi
    ui_kv "DATABASE" "$xui_db"
    detect_panel "$xui_db" 1
    print_panel_detection
    [[ $PANEL_NAME != unknown ]] || die "${xui_db} is not an x-ui family database - backup aborted."
    if grep -qsE '^XUI_DB_TYPE=postgres' /etc/default/x-ui /etc/conf.d/x-ui /etc/sysconfig/x-ui; then
        ui_warn "This panel is configured for PostgreSQL. The SQLite file above may be stale or empty and is NOT the live data."
        confirm "Back up the SQLite file anyway?" n || die "Cancelled. Dump the PostgreSQL database separately (pg_dump)."
    fi
    if [[ -d /etc/nginx ]]; then mode="FULL"; else mode="PANEL_ONLY"; fi
    ui_kv "MODE" "$mode" "$C_YELLOW"
    dtmp=$(mktemp) || die "Cannot create a temporary file."
    register_cleanup "$dtmp"
    collect_domains "$dtmp" "$xui_db" "$([[ -d /etc/nginx ]] && echo /etc/nginx)" "$([[ -d /etc/letsencrypt/live ]] && echo /etc/letsencrypt/live)"
    gather_backup_facts "$xui_db" "$([[ -d /etc/nginx ]] && echo /etc/nginx)" "$dtmp" "$([[ -d /etc/letsencrypt/live ]] && echo /etc/letsencrypt/live)"
    typed print_backup_overview

    ui_section "$(t enc_title)"
    if confirm "$(t enc_ask)" y; then
        use_enc=1
        prompt_new_password || die "Cancelled."
        bk_pass=$INPUT_VALUE
    else
        ui_warn "$(t enc_warn_plain)"
    fi

    date=$(date +%Y-%m-%d_%H%M%S)
    if (( use_enc )); then
        backup_file="${BACKUP_HOME}/XUI_Backup_${PANEL_NAME}_${mode}_${date}.tar.gz.enc"
    else
        backup_file="${BACKUP_HOME}/XUI_Backup_${PANEL_NAME}_${mode}_${date}.tar.gz"
    fi
    part="${backup_file}.part"
    register_cleanup "$part"

    ui_step 2 5 "$(t step_gather)"
    work=$(mktemp -d "${BACKUP_HOME}/.xui-backup.XXXXXX") || die "Cannot create a staging directory."
    register_cleanup "$work"
    stage="${work}/${ARCHIVE_ROOT}"
    install -d -m 700 "${stage}/panel"
    printf '%s\n' "$mode"          > "${stage}/mode.txt"
    printf '%s\n' "$PANEL_NAME"    > "${stage}/panel_name.txt"
    printf '%s\n' "$SCRIPT_VERSION" > "${stage}/script_version.txt"
    date '+%Y-%m-%d %H:%M:%S %Z' > "${stage}/created_at.txt"

    # .backup is a consistent online snapshot (a plain cp of a live WAL database can lose data).
    run_task "Consistent SQLite snapshot of the panel database" \
        sqlite3 "$xui_db" ".backup '${stage}/panel/x-ui.db'" || die "Database snapshot failed."
    sqlite3 -readonly "${stage}/panel/x-ui.db" 'PRAGMA integrity_check;' | grep -x ok >/dev/null \
        || die "Snapshot failed the SQLite integrity check."

    if [[ $mode == FULL ]]; then
        install -d -m 700 "${stage}/nginx" "${stage}/ssl" "${stage}/www"
        # -L: Debian's sites-enabled links are absolute and would (rightly) fail archive validation.
        run_task "Nginx configuration" cp -rL --preserve=mode,timestamps /etc/nginx/. "${stage}/nginx/" \
            || ui_warn "Some Nginx files could not be copied (broken links?) - continuing."
        if [[ -d /etc/letsencrypt ]]; then
            run_task "Let's Encrypt certificates" cp -a /etc/letsencrypt/. "${stage}/ssl/" \
                || ui_warn "Some certificate files could not be copied."
        fi
        if [[ -d /var/www ]]; then
            run_task "Web root" cp -rL --preserve=mode,timestamps /var/www/. "${stage}/www/" \
                || ui_warn "Some web files could not be copied."
        fi
    fi

    ui_step 3 5 "$(t step_compress)"
    run_task "Compressing$( (( use_enc )) && printf ' and encrypting (AES-256)')" \
        create_archive "$work" "$part" "$use_enc" "$bk_pass" || die "Archive creation failed; nothing was kept."
    [[ -s $part ]] || die "Archive is empty."

    ui_step 4 5 "$(t step_verify)"
    if (( use_enc )); then
        vdir=$(mktemp -d "${BACKUP_HOME}/.xui-verify.XXXXXX") || die "Cannot create a verification directory."
        register_cleanup "$vdir"
        decrypt_archive "$part" "${vdir}/check.tar.gz" "$bk_pass" || die "VERIFY FAILED: archive cannot be decrypted."
        verify_plain_tar "${vdir}/check.tar.gz" || die "VERIFY FAILED: archive is damaged or unsafe."
        rm -rf -- "$vdir"
    else
        verify_plain_tar "$part" || die "VERIFY FAILED: archive is damaged or unsafe."
    fi
    mv -f -- "$part" "$backup_file"
    chmod 600 "$backup_file"
    unset bk_pass
    rm -rf -- "$work"                         # plaintext staging is removed immediately
    ui_ok "Archive verified: readable, safe paths, database present."

    ui_step 5 5 "$(t step_deliver)"
    ui_ok "$(t backup_ok)"
    ui_kv "$(t backup_loc)" "$backup_file" "$C_GREEN"
    ui_kv "SIZE" "$(du -h "$backup_file" | awk '{print $1}')"
    ui_kv "SHA-256" "$(sha256sum "$backup_file" | awk '{print $1}')"
    ui_kv "ENCRYPTED" "$( (( use_enc )) && echo 'yes (AES-256-CBC, PBKDF2)' || echo 'NO')" "$( (( use_enc )) && echo "$C_GREEN" || echo "$C_RED")"

    transfer_backup "$backup_file"
}

# ── Workflow 2: migrate / test ────────────────────────────────────────────────
select_backup_archive() {
    local -a found=() labels=()
    local f
    mapfile -t found < <(backup_candidates)
    if (( ${#found[@]} == 0 )); then ui_err "$(t err_no_backup)"; return 1; fi
    for f in "${found[@]}"; do labels+=("$(backup_label "$f")"); done
    menu_select_b "$(t pick_backup)" 1 "${labels[@]}" || return 1
    SELECTED_ARCHIVE=${found[MENU_RESULT-1]}
    [[ -s $SELECTED_ARCHIVE ]] || { ui_err "Selected archive is empty or missing."; return 1; }
}

extract_archive() {   # extract_archive <archive> <dest>
    local archive=$1 dest=$2 tmp
    case $archive in
        *.tar.gz.enc)
            require_tools openssl || return 1
            prompt_input "$(t dec_pass_prompt)" 1 || return 1
            tmp="${dest}/.decrypted.tar.gz"
            if ! decrypt_archive "$archive" "$tmp" "$INPUT_VALUE" || ! gzip -t "$tmp" 2>/dev/null; then
                ui_err "Decryption failed - wrong password or corrupted file."; return 1
            fi
            validate_archive_safety "$tmp" "$ARCHIVE_ROOT" || return 1
            tar --no-same-owner --no-same-permissions -xzf "$tmp" -C "$dest" || { ui_err "Extraction failed."; return 1; }
            rm -f -- "$tmp" ;;
        *.tar.gz)
            validate_archive_safety "$archive" "$ARCHIVE_ROOT" || return 1
            tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$dest" || { ui_err "Extraction failed."; return 1; } ;;
        *.zip)                                # legacy archives from older script versions
            require_tools unzip || return 1
            validate_archive_safety "$archive" "$ARCHIVE_ROOT" || return 1
            ui_info "Legacy ZIP archive. If it is encrypted, enter its password at the prompt."
            unzip -oq "$archive" -d "$dest" || { ui_err "ZIP extraction failed."; return 1; } ;;
        *) ui_err "Unsupported archive type."; return 1 ;;
    esac
}

download_installer() {   # download_installer <dest> [url]   (default: the NX Panel installer)
    local dest=$1 url=${2:-$NX_INSTALL_URL} first=""
    run_task "Downloading the official installer" \
        curl --fail --show-error --silent --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
             --connect-timeout 10 --max-time 180 "$url" -o "$dest" || return 1
    [[ -s $dest ]] || return 1
    IFS= read -r first <"$dest" || true
    [[ $first == '#!'* ]] || { ui_err "Downloaded installer failed basic validation."; return 1; }
    chmod 700 "$dest"
    ui_kv "INSTALLER SHA-256" "$(sha256sum "$dest" | awk '{print $1}')"
}

fetch_migrate_tool() {   # sets MIG_TOOL (dir) and MIG_BIN
    local asset line
    case "$(uname -m)" in
        x86_64|amd64)  asset='nx-migrate-linux-amd64.tar.gz' ;;
        aarch64|arm64) asset='nx-migrate-linux-arm64.tar.gz' ;;
        *) ui_err "Unsupported architecture $(uname -m). See ${NX_RELEASES_URL}"; return 1 ;;
    esac
    MIG_TOOL=$(mktemp -d "${BACKUP_HOME}/.nx-tool.XXXXXX") || return 1
    register_cleanup "$MIG_TOOL"
    run_task "Downloading the migration tool" \
        curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 180 \
             "${NX_MIGRATE_BASE}/${asset}" -o "${MIG_TOOL}/${asset}" || { ui_err "Download failed. See ${NX_RELEASES_URL}"; return 1; }
    run_task "Downloading checksums" \
        curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 30 \
             "${NX_MIGRATE_BASE}/SHA256SUMS" -o "${MIG_TOOL}/SHA256SUMS" || return 1
    line=$(awk -v a="$asset" '{ f = $2; sub(/^\*/, "", f); sub(/^\.\//, "", f); if (f == a) { print $1 "  " a; exit } }' "${MIG_TOOL}/SHA256SUMS")
    [[ -n $line ]] || { ui_err "No checksum entry for ${asset}; refusing to run it."; return 1; }
    (cd "$MIG_TOOL" && sha256sum -c --status <<<"$line") || { ui_err "Checksum verification FAILED; refusing to execute the binary."; return 1; }
    ui_ok "Checksum verified."
    validate_archive_safety "${MIG_TOOL}/${asset}" "" || return 1
    tar --no-same-owner --no-same-permissions -xzf "${MIG_TOOL}/${asset}" -C "$MIG_TOOL" || { ui_err "Could not unpack the tool."; return 1; }
    MIG_BIN=$(find "$MIG_TOOL" -maxdepth 2 -type f -name 'nx-migrate' -print -quit)
    [[ -n $MIG_BIN && -s $MIG_BIN ]] || { ui_err "Migration binary missing from the release archive."; return 1; }
    chmod 700 "$MIG_BIN"
}

wizard_source_hint() {   # panel name from the backup -> suggested wizard source type
    case $1 in
        3x-ui|sanaei) printf '3x-ui' ;;
        alireza|x-ui) printf 'classic x-ui line (x-ui / Alireza)' ;;
        *)            printf 'check which panel the backup came from' ;;
    esac
}

restore_web_stack() {    # restore_web_stack <backup-root>   (FULL backups: nginx + certificates + web root)
    local root=$1 ts snap
    ts=$(date +%Y%m%d-%H%M%S)
    if [[ ! -d ${root}/nginx ]] || [[ -z $(ls -A "${root}/nginx" 2>/dev/null) ]]; then
        ui_info "The backup contains no Nginx configuration - nothing to restore."; return 0
    fi
    ui_section "Restoring Nginx, certificates and web root"
    if ! command -v nginx >/dev/null 2>&1; then
        command -v apt-get >/dev/null 2>&1 || { ui_err "nginx is missing and apt-get is unavailable."; return 1; }
        export DEBIAN_FRONTEND=noninteractive
        run_task "apt-get update" apt-get update -y || return 1
        run_task "Installing nginx" apt-get install -y --no-install-recommends nginx || return 1
    fi
    if ! command -v certbot >/dev/null 2>&1 && [[ -d ${root}/ssl ]]; then
        run_task "Installing certbot (needed for certificate renewals)" \
            apt-get install -y --no-install-recommends certbot python3-certbot-nginx || ui_warn "certbot not installed - renew certificates manually."
    fi

    snap="${BACKUP_HOME}/pre-restore-web-${ts}.tar.gz"
    local -a snap_paths=(etc/nginx)
    [[ -d /etc/letsencrypt ]] && snap_paths+=(etc/letsencrypt)
    tar -C / -czf "$snap" "${snap_paths[@]}" 2>/dev/null || true
    chmod 600 "$snap" 2>/dev/null || true
    ui_info "Current web configuration saved to ${snap} (used for automatic rollback)."

    install -d -m 755 /etc/nginx
    cp -a "${root}/nginx/." /etc/nginx/ || { ui_err "Could not copy the Nginx configuration."; return 1; }
    if [[ -d ${root}/ssl && -n $(ls -A "${root}/ssl" 2>/dev/null) ]]; then
        install -d -m 755 /etc/letsencrypt
        cp -a "${root}/ssl/." /etc/letsencrypt/ || ui_warn "Some certificate files could not be copied."
    fi
    if [[ -d ${root}/www && -n $(ls -A "${root}/www" 2>/dev/null) ]]; then
        install -d -m 755 /var/www
        cp -a "${root}/www/." /var/www/ || ui_warn "Some web files could not be copied."
    fi

    if nginx -t >/dev/null 2>&1; then
        systemctl enable --now nginx >/dev/null 2>&1; systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx
        ui_ok "Nginx configuration restored and reloaded."
        open_firewall 80 443
    else
        ui_err "nginx -t failed with the restored configuration - rolling back:"
        nginx -t 2>&1 | tail -n 6 >&2
        tar -C / -xzf "$snap" 2>/dev/null && systemctl reload nginx >/dev/null 2>&1
        ui_warn "Previous web configuration restored. The backup's Nginx files need manual review."
        return 1
    fi
}

# restore_family <source-panel> <target-panel> <source-db> <extracted-root> <backup-mode> <migration-dir>
# Direct, exact restore into an x-ui family panel (3x-ui / Alireza / classic x-ui).
restore_family() {
    local src=$1 target=$2 srcdb=$3 root=$4 bmode=$5 mig=$6 compat ts live=/etc/x-ui/x-ui.db i prev_db="" keep_settings=1
    local k v port="" base="" ip="" url_host web_restored=0 nginx_domain="" nginx_email="" rc=0
    ts=$(date +%Y%m%d-%H%M%S)
    compat=$(panel_compat "$src" "$target")

    if [[ $compat == downgrade ]]; then
        :   # the chooser already explained this and asked for confirmation
    fi
    if grep -qsE '^XUI_DB_TYPE=postgres' /etc/default/x-ui /etc/conf.d/x-ui /etc/sysconfig/x-ui; then
        ui_err "This server's panel uses PostgreSQL; restoring an SQLite backup into it is not supported by this script."; return 0
    fi

    # ---- personalisation: asked once, before anything changes ----
    menu_select_b "Panel login, port and secret path after the migration" 1 \
        "Keep the OLD server's settings (they are restored with the database)" \
        "Change them now (port / secret path / credentials)" || rc=$?
    (( rc == 3 )) && return 3
    (( rc == 0 )) || { ui_info "Cancelled; nothing was changed."; return 0; }
    rc=0
    [[ $MENU_RESULT == 2 ]] && keep_settings=0
    if ! { [[ $bmode == FULL && -d ${root}/nginx && -n $(ls -A "${root}/nginx" 2>/dev/null) ]]; } && ! systemctl is-active --quiet nginx 2>/dev/null; then
        if confirm "Put Nginx with HTTPS in front of the panel after the restore? (needs a domain)" n; then
            prompt_input "Panel domain (e.g. panel.example.com): " || return 0
            nginx_domain=${INPUT_VALUE,,}
            [[ $nginx_domain =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || { ui_err "Invalid domain name."; return 0; }
            prompt_input "E-mail for Let's Encrypt notices ('-' to skip): " 0 "-" || return 0
            [[ $INPUT_VALUE == "-" ]] || nginx_email=$INPUT_VALUE
        fi
    fi

    rpt_fact "SOURCE PANEL" "$(panel_label "$src")"
    rpt_fact "TARGET PANEL" "$(panel_label "$target")"
    rpt_fact "DATA PATH" "$compat restore (database copied, not converted)"

    rc=0; replace_installed_panels "$target" || rc=$?
    (( rc == 3 )) && return 3
    (( rc == 0 )) || { ui_info "Cancelled; nothing was changed."; return 0; }
    if panel_installed "$target"; then
        ui_warn "$(panel_label "$target") is already installed here: its current database will be REPLACED (a copy is kept)."
        confirm "Replace the existing panel database with the backup?" n || { ui_info "Cancelled; nothing was changed."; return 0; }
        rpt_add OK "Reused the installed $(panel_label "$target")"
    else
        if install_panel_flow "$target" 1; then rpt_add OK "Installed $(panel_label "$target") (official installer)"
        else ui_err "Panel installation failed; nothing was restored."; return 0; fi
    fi
    panel_installed "$target" || { ui_err "Panel is not installed - cannot restore."; return 0; }

    ui_section "Restoring the panel database"
    systemctl stop x-ui 2>/dev/null
    if [[ -f $live ]]; then
        prev_db="${BACKUP_HOME}/pre-restore-${target}-${ts}.db"
        if cp -a "$live" "$prev_db" && chmod 600 "$prev_db"; then ui_info "Previous database kept at ${prev_db}"; rpt_file "OLD DATABASE" "$prev_db"; fi
    fi
    rm -f -- "${live}-wal" "${live}-shm"
    install -d -m 755 "$(dirname "$live")"
    if ! install -m 600 "$srcdb" "$live"; then
        ui_err "Could not write ${live}."; rpt_add FAIL "Database restore" "write failed"
        [[ -n $prev_db ]] && cp -a "$prev_db" "$live"; systemctl start x-ui; return 0
    fi
    systemctl start x-ui
    for (( i = 0; i < 30; i++ )); do systemctl is-active --quiet x-ui && break; sleep 0.5; done
    if ! systemctl is-active --quiet x-ui; then
        ui_err "x-ui did not start with the restored database. Rolling back."
        journalctl -u x-ui -n 15 --no-pager 2>/dev/null | tail -n 15 >&2
        if [[ -n $prev_db ]]; then cp -a "$prev_db" "$live"; systemctl start x-ui; fi
        rpt_add FAIL "Database restore" "panel refused the database; rolled back"
        SERVER_VERDICT="OUT_OF_SERVICE"; print_final_report "MIGRATION REPORT"; return 0
    fi
    ui_ok "Database restored; $(panel_label "$target") is running with your old users, inbounds and traffic."
    rpt_add OK "Restored the panel database" "users, inbounds and traffic counters came along"

    if [[ $bmode == FULL ]]; then
        if restore_web_stack "$root"; then rpt_add OK "Restored Nginx, certificates and web root"; web_restored=1
        else ui_warn "Web stack restore needs attention (see above)."; rpt_add WARN "Web stack restore" "needs manual review - previous config was rolled back"; fi
    else
        rpt_add SKIP "Web stack" "PANEL_ONLY backup"
    fi

    if (( keep_settings == 0 )); then
        if collect_install_options "$target" 2 && apply_panel_settings "$target"; then
            rpt_add OK "Applied your new panel port / path / credentials"
            rpt_file "NEW LOGIN" "user ${IO_USER} - password shown once on screen; store it in a password manager"
            ui_kv "NEW USERNAME" "$IO_USER" "$C_GREEN"; ui_kv "NEW PASSWORD" "$IO_PASS" "$C_GREEN"
        else rpt_add WARN "Panel settings change" "not applied"; fi
    else
        rpt_add OK "Kept the old server's port, secret path and login"
    fi

    while IFS='=' read -r k v; do
        [[ $k == webPort ]] && port=$v
        [[ $k == webBasePath ]] && base=$v
    done < <(dbtool settings "$live")
    base=${base:-/}; [[ $base == /* ]] || base="/$base"; [[ $base == */ ]] || base+="/"
    detect_public_ip && ip=$PUB_IP
    url_host=${ip:-<SERVER_IP>}

    if [[ -n $nginx_domain && $port =~ ^[0-9]+$ ]]; then
        ui_section "Nginx + HTTPS"
        if [[ -n $ip ]]; then
            dns_check_domain "$nginx_domain" "$ip"
            if [[ $DNS_STATE != MATCH && $DNS_STATE != CDN ]]; then
                alert_box "DNS is not ready for ${nginx_domain}" "Create:  A   ${nginx_domain}   ->   ${ip}   (currently: ${DNS_NOW})" "Let's Encrypt cannot issue a certificate until it resolves here."
                confirm "Continue anyway? (HTTP only until DNS is fixed)" n || nginx_domain=""
            fi
        fi
        if [[ -n $nginx_domain ]]; then
            if setup_nginx_proxy "$nginx_domain" "$port" "$nginx_email"; then
                rpt_add OK "Nginx reverse proxy for ${nginx_domain}" "certbot requested"
                rpt_access "PANEL URL" "https://${nginx_domain}${base}"
            else rpt_add WARN "Nginx reverse proxy" "did not complete"; fi
        else rpt_add SKIP "Nginx reverse proxy" "cancelled at the DNS check"; fi
    fi
    rpt_access "PANEL PORT" "${port:-unknown}"
    rpt_fact "BACKUP MODE" "$bmode"
    rpt_file "MIGRATION DIR" "$mig  (database copy + domain list)"
    RPT_NEXT+=("Open the panel, check Inbounds and Clients, and restart Xray once from the panel.")
    [[ $port =~ ^[0-9]+$ ]] && RPT_NEXT+=("Make sure port ${port} and your inbound ports are open in the provider firewall / ufw.")
    [[ -z $nginx_domain && $web_restored == 0 ]] && RPT_NEXT+=("The panel is served over plain HTTP. Put Nginx + HTTPS in front of it (main menu -> Install a panel) or use an SSH tunnel.")

    post_verify "$target" "${mig}/domains.txt" "$live" ""
    [[ -z $ip ]] && ip=${EXPECTED_IP:-}
    url_host=${ip:-<SERVER_IP>}
    [[ $port =~ ^[0-9]+$ ]] && rpt_access "DIRECT URL" "http://${url_host}:${port}${base}"
    print_final_report "MIGRATION REPORT"
}

nx_ensure_installed() {
    local rc=0
    if systemctl is-active --quiet nx-panel 2>/dev/null; then
        ui_ok "NX Panel is installed and active."; return 0
    fi
    if panel_installed nx; then
        ui_err "NX Panel is installed but the nx-panel service is not active. Start/check it first:  systemctl status nx-panel"; return 1
    fi
    confirm "$(t nx_install_ask)" n || { ui_info "Cancelled. Existing X-UI was not removed."; return 1; }
    install_panel_flow nx 0 || { ui_err "NX Panel installation did not complete. Existing X-UI files were not touched."; return 1; }
    confirm "$(t nx_setup_done)" n || rc=2
    return $rc
}

# nx_wizard_run <migration-dir> <source-panel>  -> exit status of the wizard
# The wizard is served over HTTPS on this server's own address (no SSH tunnel, no loopback links).
nx_wizard_run() {
    local mig=$1 pname=$2 port=$NX_WIZARD_PORT host="" cert="" key="" tdir log client="" link="" i d nxport nxurl ssh_port rc=0 mode=https
    ssh_port=$(awk '{print $4}' <<<"${SSH_CONNECTION:-}" 2>/dev/null); [[ $ssh_port =~ ^[0-9]+$ ]] || ssh_port=22
    nxport=$(panel_port_of nx); nxurl="http://127.0.0.1:${nxport:-<NX port>}"
    port_in_use "$port" && port=$(pick_free_port 20000 40000)
    detect_public_ip || true
    host=${PUB_IP:-}
    # a real certificate (no browser warning) when one of the migrated domains already points here
    if [[ -n $host && -r ${mig}/domains.txt ]]; then
        while IFS= read -r d; do
            [[ -f /etc/letsencrypt/live/${d}/fullchain.pem ]] || continue
            dns_check_domain "$d" "$host"
            if [[ $DNS_STATE == MATCH ]]; then host=$d; cert=/etc/letsencrypt/live/${d}/fullchain.pem; key=/etc/letsencrypt/live/${d}/privkey.pem; break; fi
        done < <(cut -f1 "${mig}/domains.txt" | sort -u)
    fi
    if [[ -z $host ]]; then ui_warn "Public address unknown."; mode=tunnel
    elif [[ -z $cert ]]; then
        tdir=$(mktemp -d "${BACKUP_HOME}/.nx-tls.XXXXXX") || mode=tunnel
        if [[ $mode == https ]]; then
            register_cleanup "$tdir"
            if openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj "/CN=${host}" \
                -addext "subjectAltName=IP:${host}" -keyout "${tdir}/k.pem" -out "${tdir}/c.pem" >/dev/null 2>&1; then
                cert=${tdir}/c.pem; key=${tdir}/k.pem
            else mode=tunnel; fi
        fi
    fi
    client=$(awk '{print $1}' <<<"${SSH_CONNECTION:-}" 2>/dev/null)

    ui_section "Migration wizard"
    ui_card "WHAT YOU WILL DO  (4 short steps)"
    ui_kv "1  OPEN" "the link shown below in your browser$([[ -z ${cert:-} || $cert == "${tdir:-/nonexistent}"* ]] && printf '  (a certificate warning is normal: Advanced -> Continue)')" "$C_WHITE"
    ui_kv "2  SOURCE" "type: $(wizard_source_hint "$pname")  ·  file: x-ui.db (or fetch it live from the old panel)" "$C_YELLOW"
    ui_kv "3  CONNECT NX" "address  ${nxurl}  ·  admin login or API token" "$C_YELLOW"
    ui_kv "4  FINISH" "Preview, then Transfer - the wizard closes itself" "$C_WHITE"
    ui_kv "DATABASE FILE" "${mig}/x-ui.db" "$C_GREEN"
    ui_info "To get the file onto your computer:   scp -P ${ssh_port} root@${PUB_IP:-<SERVER_IP>}:${mig}/x-ui.db ."
    ui_info "Docs: ${NX_DOCS_URL}"
    printf '\n'

    if [[ $mode == https ]]; then
        log=$(mktemp "${BACKUP_HOME}/.nx-wiz.XXXXXX") && register_cleanup "$log"
        if [[ -n $client ]] && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
            ufw allow from "$client" to any port "$port" proto tcp >/dev/null 2>&1 && { WIZ_UFW="${client} ${port}"; ui_ok "Firewall: port ${port} opened for your address ${client} only (closed again afterwards)."; }
        elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
            ufw allow "${port}/tcp" >/dev/null 2>&1 && { WIZ_UFW="any ${port}"; }
        fi
        (cd "$MIG_TOOL" && exec "$MIG_BIN" -no-browser -allow-remote -listen "0.0.0.0:${port}" -tls-cert "$cert" -tls-key "$key") >"$log" 2>&1 &
        WIZ_PID=$!
        for (( i = 0; i < 40; i++ )); do
            link=$(grep -Eo 'https?://[^[:space:]]+' "$log" 2>/dev/null | head -n 1)
            [[ -n $link ]] && break
            kill -0 "$WIZ_PID" 2>/dev/null || break
            sleep 0.25
        done
        if [[ -n $link ]]; then
            link=$(sed -E "s#^https?://[^/]+#https://${host}:${port}#" <<<"$link")
            printf ' %s%s%s%s%sOPEN THIS LINK%s   (valid for this session only)\n\n     %s%s%s\n\n' "$C_GREEN" "$I_OK" "$C_RESET" "$I_GAP" "$C_BOLD" "$C_RESET" "${C_BOLD}${C_CYAN}" "$link" "$C_RESET"
            ui_info "Waiting for the wizard to finish. Press Ctrl+C to cancel."
            wait "$WIZ_PID"; rc=$?
            WIZ_PID=''
        else
            ui_warn "The wizard did not publish a link over HTTPS - falling back to the SSH-tunnel method."
            kill "$WIZ_PID" 2>/dev/null; WIZ_PID=''; mode=tunnel
        fi
        if [[ -n $WIZ_UFW ]]; then ufw --force delete allow from "${WIZ_UFW%% *}" to any port "${WIZ_UFW##* }" proto tcp >/dev/null 2>&1 || ufw --force delete allow "${port}/tcp" >/dev/null 2>&1; WIZ_UFW=''; fi
    fi
    if [[ $mode == tunnel ]]; then
        ui_info "From your own computer open a second terminal:"
        printf '\n     %sssh -L %s:127.0.0.1:%s -p %s <SSH_USER>@<DESTINATION_IP>%s\n\n' "$C_WHITE" "$NX_WIZARD_PORT" "$NX_WIZARD_PORT" "$ssh_port" "$C_RESET"
        ui_info "Keep it open and use the link the wizard prints below."
        (cd "$MIG_TOOL" && "$MIG_BIN" -no-browser)
        rc=$?
    fi
    return "$rc"
}

migrate_core() {         # migrate_core <1=real|2=test>
    local op=$1 archive root src_db bmode pname hinted mig_dir ssh_port rc ndom dtmp web
    require_tools sqlite3 python3 tar gzip || return 0

    ui_step 1 6 "$(t step_select)"
    select_backup_archive || return 0
    archive=$SELECTED_ARCHIVE

    ui_step 2 6 "$(t step_validate)"
    MIG_STAGE=$(mktemp -d "${BACKUP_HOME}/.moc-nx-stage.XXXXXX") || { ui_err "Cannot create a staging directory."; return 0; }
    chmod 700 "$MIG_STAGE"
    extract_archive "$archive" "$MIG_STAGE" || { ui_err "No system files were changed."; return 0; }
    root="${MIG_STAGE}/${ARCHIVE_ROOT}"
    src_db="${root}/panel/x-ui.db"
    if [[ ! -f $src_db || -L $src_db || ! -s $src_db || ! -f ${root}/mode.txt || -L ${root}/mode.txt ]]; then
        ui_err "Archive lacks a regular ${ARCHIVE_ROOT}/panel/x-ui.db and mode.txt. No changes were made."; return 0
    fi
    bmode=$(tr -d '\r\n' < "${root}/mode.txt")
    [[ $bmode == FULL || $bmode == PANEL_ONLY ]] || { ui_err "Invalid backup mode: ${bmode}"; return 0; }
    pname=unknown
    [[ -f ${root}/panel_name.txt && ! -L ${root}/panel_name.txt ]] && pname=$(tr -d '\r\n' < "${root}/panel_name.txt")
    [[ $pname =~ ^[A-Za-z0-9._-]{1,32}$ ]] || pname=unknown
    sqlite3 -readonly "$src_db" 'PRAGMA integrity_check;' 2>/dev/null | grep -x ok >/dev/null \
        || { ui_err "SQLite integrity check failed. No system files were changed."; return 0; }

    # The panel type is re-detected from the database itself; the name stored in the backup is only a fallback.
    detect_panel "$src_db" 0
    hinted=$(norm_panel "$pname")
    if [[ $PANEL_CONF != high && $hinted =~ ^(3x-ui|alireza|x-ui)$ ]]; then
        PANEL_NAME=$hinted; PANEL_CONF=medium; PANEL_WHY="panel name recorded in the backup (${pname}); ${PANEL_WHY}"
    fi
    pname=$PANEL_NAME

    dtmp="${MIG_STAGE}/domains.tsv"
    collect_domains "$dtmp" "$src_db" "${root}/nginx" "${root}/ssl/live"
    gather_backup_facts "$src_db" "${root}/nginx" "$dtmp" "${root}/ssl/live"
    ndom=$BF_NDOM

    ui_ok "Archive structure, backup mode and SQLite integrity validated."
    typed_begin
    print_panel_detection
    ui_kv "BACKUP MODE" "$bmode"
    print_backup_overview
    typed_end

    require_tools curl sha256sum awk grep systemctl || return 0
    local prc
    while true; do
        ui_step 3 6 "$(t step_target)"
        choose_migration_target "$pname" || { ui_info "Back to the menu - nothing was changed."; return 0; }
        web=0
        [[ $bmode == FULL && -d ${root}/nginx && -n $(ls -A "${root}/nginx" 2>/dev/null) ]] && web=1

        ui_step 4 6 "$(t step_preflight)"
        MENU_RESULT=1
        if (( op != 2 )); then
            prc=0; menu_select_b "$(t preflight_ask)" 1 "🔎   Yes - check this server now (recommended)" "⏭   Skip the check" || prc=$?
            (( prc == 3 )) && continue
            (( prc == 0 )) || return 0
        fi
        if [[ $MENU_RESULT == 1 ]]; then
            run_preflight "$src_db" || { ui_warn "Aborted at pre-flight. Nothing was installed."; return 0; }
        fi

        ui_step 5 6 "$(t step_plan)"
        prc=0; print_migration_plan "$pname" "$MIG_TARGET" "$bmode" "$ndom" "$web" "$op" || prc=$?
        (( prc == 3 )) && continue
        if (( op == 2 )); then
            ui_step 6 6 "Test summary"
            ui_ok "$(t test_passed)"
            typed migration_selfcheck "$pname" "$MIG_TARGET" "$bmode" "$dtmp" "$archive"
            return 0
        fi
        (( prc == 0 )) || { ui_info "Cancelled; nothing was changed."; return 0; }

        # Stage the database + domain list durably (private) before anything is installed.
        mig_dir="${BACKUP_HOME}/moc-nx-migration-$(date +%Y%m%d-%H%M%S)"
        install -d -m 700 "$mig_dir" || { ui_err "Cannot create the migration folder."; return 0; }
        install -m 600 "$src_db" "${mig_dir}/x-ui.db" || { ui_err "Cannot stage the source database."; return 0; }
        install -m 600 "$dtmp" "${mig_dir}/domains.txt"
        printf 'Source archive : %s\nSource panel   : %s\nSuggested wizard source type: %s\n' \
            "$archive" "$pname" "$(wizard_source_hint "$pname")" > "${mig_dir}/README.txt"
        ui_step 6 6 "$(t step_run)"
        PB_LO=$(( 500 / 6 )) PB_HI=100

        rpt_reset
        rpt_add OK "Validated the backup" "archive safety, SQLite integrity, panel auto-detected as $(panel_label "$pname") (${PANEL_CONF} confidence)"
        rpt_fact "BACKUP FILE" "$(basename "$archive")"
        rpt_data_from_bf
        rpt_file "BACKUP ARCHIVE" "$archive"
        if [[ $MIG_TARGET != nx ]]; then
            prc=0; restore_family "$pname" "$MIG_TARGET" "$src_db" "$root" "$bmode" "$mig_dir" || prc=$?
            if (( prc == 3 )); then
                ui_info "Back to the panel choice - nothing was changed."
                rm -rf -- "$mig_dir"; PB_LO=0
                continue
            fi
            return 0
        fi
        break
    done

    rpt_fact "SOURCE PANEL" "$(panel_label "$pname")"
    rpt_fact "TARGET PANEL" "NX Panel"
    rpt_fact "DATA PATH" "converted by the NX migration wizard"
    rpt_fact "BACKUP MODE" "$bmode"
    rpt_file "MIGRATION DIR" "$mig_dir  (database copy + domain list)"
    ui_info "NX Panel has a different architecture: x-ui.db, Nginx, SSL and X-UI service files are NOT copied into NX Panel paths."
    rm -rf -- "$MIG_STAGE"; MIG_STAGE=""
    rc=0; replace_installed_panels nx || rc=$?
    if (( rc != 0 )); then ui_info "Cancelled; nothing was changed."; return 0; fi
    nx_ensure_installed; rc=$?
    if (( rc == 2 )); then
        ui_info "Migration paused. Source database is staged at: ${mig_dir}/x-ui.db"
        ui_info "Re-run this workflow after completing the NX Panel setup; keep the original archive safe."
        return 0
    elif (( rc != 0 )); then
        return 0
    fi
    rpt_add OK "NX Panel is installed and running"

    MIG_BIN=""
    fetch_migrate_tool || return 0
    nx_wizard_run "$mig_dir" "$pname"; rc=$?
    ui_info "Wizard exited with status ${rc}. Review its report before considering the migration complete."
    ui_info "Staged source database kept securely at: ${mig_dir}/x-ui.db"
    if (( rc == 0 )); then rpt_add OK "NX migration wizard finished" "review its own transfer report"
    else rpt_add WARN "NX migration wizard exited with status ${rc}" "check what was transferred"; fi
    local nxport nxip=""
    nxport=$(panel_port_of nx)
    detect_public_ip && nxip=$PUB_IP
    [[ $nxport =~ ^[0-9]+$ ]] && rpt_access "PANEL URL" "http://${nxip:-<SERVER_IP>}:${nxport}/"
    RPT_NEXT+=("In NX Panel assign the imported Template to your node(s) and confirm the node connection, inbounds and subscription links.")
    RPT_NEXT+=("Users connect to NODES: point your domains at the node IP(s), not necessarily at this panel server.")

    post_verify nx "${mig_dir}/domains.txt" "" \
        "NX users connect to NODES: enter the IP of the node that serves these domains (this server only if the node runs here)."
    print_final_report "MIGRATION REPORT"
    return 0
}

migrate_once() {
    MIG_STAGE=""; MIG_TOOL=""; SERVER_VERDICT="UNKNOWN"; rpt_reset
    migrate_core "$1"
    [[ -n $MIG_STAGE ]] && rm -rf -- "$MIG_STAGE"
    [[ -n $MIG_TOOL ]]  && rm -rf -- "$MIG_TOOL"
    MIG_STAGE=""; MIG_TOOL=""
    return 0
}


do_restore() {
    local where=1 sel=1
    while true; do
        if (( REMOTE_MODE )); then
            where=1
        else
            show_header
            menu_select_b "$(t where_title)" "$where" "$(t where_local)" "$(t where_remote)" || return 0
            where=$MENU_RESULT
        fi
        if (( where == 2 )); then
            run_workflow remote_restore_flow; pause_key
            continue
        fi
        while true; do
            show_header
            menu_select_b "$(t restore_title)" "$sel" "$(t opt_real)" "$(t opt_test)" || break
            sel=$MENU_RESULT
            migrate_once "$MENU_RESULT"
            pause_key
        done
        (( REMOTE_MODE )) && return 0
    done
}

# ── Workflow 3: install a panel ───────────────────────────────────────────────
do_install() {
    local -a ids=(nx 3x-ui alireza x-ui) labels=() i
    for i in "${ids[@]}"; do
        if panel_installed "$i"; then labels+=("$(panel_label "$i")   ${I_OK} installed"); else labels+=("$(panel_label "$i")"); fi
    done
    menu_select_b "$(t install_title)" 1 "${labels[@]}" || return 0
    install_panel_flow "${ids[MENU_RESULT-1]}" 0
}

# ── Workflow 4: update ────────────────────────────────────────────────────────
# installed_panels -> prints ids of panels present on this server
installed_panels() {
    local fam=""
    panel_installed nx && echo nx
    if panel_installed x-ui; then
        fam=$(panel_from_cli || true)
        if [[ -z $fam && -f /etc/x-ui/x-ui.db ]]; then detect_panel /etc/x-ui/x-ui.db 0; fam=$PANEL_NAME; fi
        echo "${fam:-x-ui}"
    fi
}

do_update() {
    local -a found=() labels=() ; local panel svc dir rc ts snap=""
    mapfile -t found < <(installed_panels)
    (( ${#found[@]} > 0 )) || die "No supported panel (NX Panel, 3x-ui, Alireza x-ui, x-ui) was found on this server."
    if [[ -n ${1:-} ]]; then
        panel=$1
    elif (( ${#found[@]} == 1 )); then
        panel=${found[0]}
    else
        for panel in "${found[@]}"; do labels+=("$(panel_label "$panel")"); done
        menu_select_b "Which panel should be updated?" 1 "${labels[@]}" || return 0
        panel=${found[MENU_RESULT-1]}
    fi
    svc=$(panel_service "$panel")
    ui_kv "PANEL" "$(panel_label "$panel")" "$C_GREEN"
    require_tools curl sha256sum || exit 1
    ui_info "The official installer updates in place and keeps the database."
    ui_warn "Database schema changes are forward-only - a pre-update copy of the database is taken first."
    confirm "Run the official installer to update $(panel_label "$panel") now?" n || { ui_info "Update cancelled; no changes were made."; return 0; }

    ts=$(date +%Y%m%d-%H%M%S)
    if [[ $panel != nx && -f /etc/x-ui/x-ui.db ]]; then
        snap="${BACKUP_HOME}/pre-update-${panel}-${ts}.db"
        sqlite3 /etc/x-ui/x-ui.db ".backup '${snap}'" 2>/dev/null || cp -a /etc/x-ui/x-ui.db "$snap"
        chmod 600 "$snap"; ui_ok "Database copy: ${snap}"
    fi
    dir=$(mktemp -d "${BACKUP_HOME}/.moc-update.XXXXXX") || die "Cannot create a temporary directory."
    register_cleanup "$dir"
    download_installer "${dir}/install.sh" "$(panel_installer_url "$panel")" || die "Installer download failed. Nothing was executed."
    case $panel in
        x-ui) printf 'n\n' | bash "${dir}/install.sh"; rc=$? ;;
        nx)   bash "${dir}/install.sh" </dev/null; rc=$? ;;
        *)    XUI_NONINTERACTIVE=1 bash "${dir}/install.sh" </dev/null; rc=$? ;;
    esac
    if (( rc == 0 )) && systemctl is-active --quiet "$svc" 2>/dev/null; then
        ui_ok "Update finished and ${svc} is active. Verify the version and logs in the panel."
    else
        ui_err "Update did not finish cleanly or the service is inactive."
        ui_info "Check:  systemctl status ${svc}   |   journalctl -u ${svc} -n 100"
        [[ -n $snap ]] && ui_info "Pre-update database copy: ${snap}"
        exit 1
    fi
}

# ── Workflow 5: post-migration verification ───────────────────────────────────
do_verify() {
    local -a found=() labels=(); local panel dfile latest db=""
    mapfile -t found < <(installed_panels)
    (( ${#found[@]} > 0 )) || die "No supported panel was found on this server - nothing to verify."
    if (( ${#found[@]} == 1 )); then
        panel=${found[0]}
    else
        for panel in "${found[@]}"; do labels+=("$(panel_label "$panel")"); done
        menu_select_b "Which panel should be verified?" 1 "${labels[@]}" || return 0
        panel=${found[MENU_RESULT-1]}
    fi
    [[ $panel != nx && -f /etc/x-ui/x-ui.db ]] && db=/etc/x-ui/x-ui.db
    rpt_reset; rpt_fact "PANEL" "$(panel_label "$panel")"
    dfile=$(mktemp) || die "Cannot create a temporary file."
    register_cleanup "$dfile"
    collect_domains "$dfile" "$db" /etc/nginx /etc/letsencrypt/live
    latest=$(find "$BACKUP_HOME" -maxdepth 2 -path '*/moc-nx-migration-*/domains.txt' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2-)
    if [[ -n $latest ]]; then
        cat "$latest" "$dfile" | awk -F'\t' '$1 != "" { k = $1; if (index("," src[k] ",", "," $2 ",") == 0) src[k] = (src[k] == "" ? $2 : src[k] "," $2) }
            END { for (k in src) printf "%s\t%s\n", k, src[k] }' | sort >"${dfile}.m" && mv -f "${dfile}.m" "$dfile"
    fi
    post_verify "$panel" "$dfile" "$db" ""
    print_final_report "VERIFICATION REPORT"
}

ui_card() {   # ui_card <title>  - a titled divider inside a report
    local f
    f=$(printf '%*s' $(( UI_COLS - 8 - ${#1} )) '' | sed 's/ /─/g')
    printf '\n %s── %s%s%s%s %s%s%s\n' "$C_CYAN" "${C_BOLD}${C_WHITE}" "$LRM" "$1" "${C_RESET}${C_CYAN}" "$C_DIM" "$f" "$C_RESET"
}

notice_box() {   # notice_box <title> <line>...   (amber, for "double-check" reminders)
    local title=$1 l row w=$(( UI_COLS - 8 ))
    local -a rows=()
    shift
    printf '\n %s█%s  %s%s%s%s  %s%s%s\n' "$C_YELLOW" "$C_RESET" "$C_YELLOW" "$C_BOLD" "$I_WARN" "$C_RESET" "$C_BOLD" "$title" "$C_RESET"
    for l in "$@"; do
        IFS=$'\x1f' read -ra rows < <(pywrap "$w" "$l")
        for row in "${rows[@]}"; do printf ' %s█%s   %s%s\n' "$C_YELLOW" "$C_RESET" "$LRM" "$row"; done
    done
    printf '\n'
}

# ── Remote session helpers ───────────────────────────────────────────────────
# confirm_where <what> [y|n]  -> 0 = go ahead. Only asks inside a REMOTE session.
confirm_where() {
    local what=$1 l1 l2
    (( REMOTE_MODE )) || return 0
    printf -v l1 "$(t rw_l1)" "$what" "$(host_label)"
    printf -v l2 "$(t rw_l2)" "${XUI_SOURCE_HOST:-unknown}"
    notice_box "$(t rw_title)" "$l1" "$l2"
    printf -v l1 "$(t rw_ask)" "$what"
    confirm "$l1" "${2:-n}"
}

# ── Panels: one menu for install + update ────────────────────────────────────
panel_version() {   # panel_version <panel> -> version string (best effort)
    local cli a v
    cli=$(panel_cli "$1")
    [[ -x $cli ]] || return 0
    for a in -v --version version; do
        v=$(timeout 3 "$cli" "$a" 2>/dev/null </dev/null | head -n 1)
        if [[ $v =~ [0-9]+\.[0-9]+ ]] && (( ${#v} < 60 )); then printf '%s' "$v"; return 0; fi
    done
}

do_panels() {
    local -a found=() ids=(nx 3x-ui alireza x-ui) labels=() acts=()
    local p act v st sel=1 lbl what
    while true; do
        show_header
        mapfile -t found < <(installed_panels)
        labels=(); acts=()
        ui_section "$(t panels_title)"
        if (( ${#found[@]} )); then
            for p in "${found[@]}"; do
                v=$(panel_version "$p"); st=$(systemctl is-active "$(panel_service "$p")" 2>/dev/null || true)
                ui_kv "$(panel_label "$p")" "${v:-version unknown} · service ${st:-unknown}" "$([[ $st == active ]] && echo "$C_GREEN" || echo "$C_YELLOW")"
                printf -v lbl "$(t pn_update)" "$(panel_label "$p")"; labels+=("🚀   ${lbl}"); acts+=("update:${p}")
            done
            labels+=("🔧   $(t pn_other)"); acts+=("install")
        else
            ui_info "$(t panels_none)"
            for p in "${ids[@]}"; do printf -v lbl "$(t pn_install)" "$(panel_label "$p")"; labels+=("🔧   ${lbl}"); acts+=("install:${p}"); done
        fi
        printf '\n'
        menu_select_b "$(t choose_action)" "$sel" "${labels[@]}" || return 0
        sel=$MENU_RESULT
        act=${acts[MENU_RESULT-1]}
        case $act in
            update:*)  printf -v what "$(t w_update)" "$(panel_label "${act#update:}")"; confirm_where "$what" && run_workflow do_update "${act#update:}" ;;
            install)   run_workflow do_install ;;
            install:*) printf -v what "$(t w_install)" "$(panel_label "${act#install:}")"; confirm_where "$what" && run_workflow install_panel_flow "${act#install:}" 0 ;;
        esac
        pause_key
    done
}

# ── Update this script (GitHub) ──────────────────────────────────────────────
# The raw URL of the published script. Until it is set, the menu asks for it once and remembers it.
readonly SELF_UPDATE_URL_DEFAULT='https://raw.githubusercontent.com/Mr-HaroldFinch/XUI-Smart-Platform-Manager/main/XUI-SPM.sh'
readonly SELF_UPDATE_CONF='/etc/moc-xui/update_url'

script_version_of() {   # script_version_of <file> -> x.y.m.s
    local f=$1 a b c d
    a=$(sed -n 's/^readonly VER_MAIN="\([0-9]*\)".*/\1/p' "$f" | head -n 1)
    b=$(sed -n 's/.*VER_YEAR="\([0-9]*\)".*/\1/p' "$f" | head -n 1)
    c=$(sed -n 's/.*VER_MONTH="\([0-9]*\)".*/\1/p' "$f" | head -n 1)
    d=$(sed -n 's/.*VER_SUB="\([0-9]*\)".*/\1/p' "$f" | head -n 1)
    [[ -n $a && -n $b && -n $c && -n $d ]] && printf '%s.%s.%s.%s' "$a" "$b" "$c" "$d"
}

version_cmp() {   # version_cmp <a> <b>  -> prints -1 / 0 / 1
    local -a x y
    local i
    IFS=. read -ra x <<<"$1"; IFS=. read -ra y <<<"$2"
    for i in 0 1 2 3; do
        if (( 10#${x[i]:-0} > 10#${y[i]:-0} )); then echo 1; return; fi
        if (( 10#${x[i]:-0} < 10#${y[i]:-0} )); then echo -1; return; fi
    done
    echo 0
}

self_update_url() {
    local u=${MOC_UPDATE_URL:-}
    [[ -n $u ]] || { [[ -r $SELF_UPDATE_CONF ]] && u=$(head -n 1 "$SELF_UPDATE_CONF" | tr -d '[:space:]'); }
    [[ -n $u ]] || u=$SELF_UPDATE_URL_DEFAULT
    printf '%s' "$u"
}

do_self_update() {    # do_self_update [check-only 0|1]
    local check=${1:-0} url tmp new_ver cmp sum_url want got
    ui_section "$(t selfupd_title)"
    ui_kv "INSTALLED" "v${SCRIPT_VERSION}" "$C_WHITE"
    ui_kv "SCRIPT FILE" "${SCRIPT_PATH:-not a regular file}"
    url=$(self_update_url)
    if [[ -z $url ]]; then
        ui_info "The script's GitHub address is not configured yet."
        ui_info "Enter the RAW link of XUI-SPM.sh (https://raw.githubusercontent.com/<user>/<repo>/<branch>/XUI-SPM.sh). It is remembered for next time."
        prompt_input "Update URL (empty = cancel): " 0 "-" || return 0
        [[ $INPUT_VALUE == "-" ]] && { ui_info "Cancelled."; return 0; }
        url=$INPUT_VALUE
        [[ $url == https://* ]] || { ui_err "Only https:// links are accepted."; return 0; }
        if install -d -m 755 "$(dirname "$SELF_UPDATE_CONF")" 2>/dev/null && printf '%s\n' "$url" >"$SELF_UPDATE_CONF" 2>/dev/null; then chmod 600 "$SELF_UPDATE_CONF"; fi
    fi
    [[ $url == https://* ]] || { ui_err "The update URL must start with https://"; return 0; }
    ui_kv "UPDATE SOURCE" "$url" "$C_BLUE"
    require_tools curl sha256sum || return 0
    tmp=$(mktemp -d "${BACKUP_HOME}/.moc-selfupdate.XXXXXX") || { ui_err "Cannot create a temporary folder."; return 0; }
    register_cleanup "$tmp"
    run_task "Downloading the latest script" \
        curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 --max-filesize 3000000 "$url" -o "${tmp}/new.sh" \
        || { ui_err "Download failed. Check the link and the network."; return 0; }
    head -n 1 "${tmp}/new.sh" | grep -q '^#!.*bash' || { ui_err "The downloaded file is not a bash script - refusing to use it."; return 0; }
    bash -n "${tmp}/new.sh" 2>/dev/null || { ui_err "The downloaded script has syntax errors - refusing to use it."; return 0; }
    grep -q 'XUI-SPM' "${tmp}/new.sh" || { ui_err "This does not look like the XUI-SPM (X-UI Smart Panel Manager) script."; return 0; }
    new_ver=$(script_version_of "${tmp}/new.sh")
    [[ -n $new_ver ]] || { ui_err "Cannot read the version number of the downloaded script."; return 0; }
    got=$(sha256sum "${tmp}/new.sh" | awk '{print $1}')
    ui_kv "LATEST" "v${new_ver}" "$C_WHITE"
    ui_kv "SHA-256" "$got" "$C_DIM"
    sum_url="${url}.sha256"
    if curl -fsSL --proto '=https' --connect-timeout 5 --max-time 15 "$sum_url" -o "${tmp}/sum" 2>/dev/null; then
        want=$(awk '{print $1; exit}' "${tmp}/sum")
        if [[ $want == "$got" ]]; then ui_ok "Checksum matches the published ${sum_url##*/}."
        else ui_err "Checksum does NOT match the published file - refusing to install."; return 0; fi
    else
        ui_info "No ${sum_url##*/} was published next to the script, so the checksum could not be verified (the link is over HTTPS)."
    fi
    cmp=$(version_cmp "$new_ver" "$SCRIPT_VERSION")
    if [[ $cmp == 0 ]]; then ui_ok "You already run the latest version (v${SCRIPT_VERSION})."; return 0; fi
    if [[ $cmp == -1 ]]; then ui_warn "The published version (v${new_ver}) is OLDER than the installed one (v${SCRIPT_VERSION})."; fi
    (( check )) && { ui_info "A newer version is available: v${new_ver}.  Update from the main menu."; return 0; }
    [[ -f $SCRIPT_PATH ]] || { ui_err "This script was not started from a regular file (piped?), so it cannot replace itself."; return 0; }
    confirm "Replace v${SCRIPT_VERSION} with v${new_ver} now? The current file is kept as a .bak copy." "$([[ $cmp == 1 ]] && echo y || echo n)" || { ui_info "Not updated."; return 0; }
    cp -p -- "$SCRIPT_PATH" "${SCRIPT_PATH}.bak-${SCRIPT_VERSION}" 2>/dev/null && ui_ok "Previous version saved: ${SCRIPT_PATH}.bak-${SCRIPT_VERSION}"
    install -m 700 "${tmp}/new.sh" "$SCRIPT_PATH" || { ui_err "Could not write ${SCRIPT_PATH}."; return 0; }
    ui_ok "Updated to v${new_ver}."
    if confirm "Restart the script now to use the new version?" y; then
        cleanup; exec bash "$SCRIPT_PATH"
    fi
    ui_info "Start the script again to use v${new_ver}."
}

# ── Certificates: inventory, expiry, usage ───────────────────────────────────
CERT_TOTAL=-1 CERT_VALID=0 CERT_SOON=0 CERT_EXPIRED=0 CERT_UNUSED=0 CERT_FILE=""

cert_record() {   # cert_record <kind> <name> <dir> <file>   (uses cert_scan's variables)
    local kind=$1 name=$2 d=$3 f=$4 end exp days state used
    end=$(openssl x509 -noout -enddate -in "$f" 2>/dev/null) || return 0
    exp=$(date -d "${end#notAfter=}" +%s 2>/dev/null) || return 0
    if (( exp < now )); then state=expired; days=$(( (now - exp) / 86400 ))
    else
        days=$(( (exp - now) / 86400 ))
        if (( days <= 14 )); then state=soon; else state=valid; fi
    fi
    if (( have_hay )); then
        if [[ $kind == le ]]; then
            if grep -qF -- "/live/${name}/" "$hay" 2>/dev/null; then used=1; else used=0; fi
        elif grep -qF -- "/${name}/" "$hay" 2>/dev/null; then used=1; else used=0; fi
    else used=2; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$name" "$d" "$exp" "$days" "$state" "$used" >>"$out"
}

# cert_scan <out-file> <letsencrypt-live-dir> <acme-dir> <panel-db> <nginx-base-dir>   (any argument may be "")
# out-file: kind <TAB> name <TAB> dir <TAB> expiry-epoch <TAB> days <TAB> valid|soon|expired <TAB> used 1|0|2(unknown)
cert_scan() {
    local out=$1 live=$2 xdir=$3 db=$4 ngx=$5 hay d f name p now have_hay=0
    local kind _n _d _e _days state used
    CERT_TOTAL=0 CERT_VALID=0 CERT_SOON=0 CERT_EXPIRED=0 CERT_UNUSED=0 CERT_FILE=$out
    : >"$out"
    command -v openssl >/dev/null 2>&1 || { CERT_TOTAL=-1; return 0; }
    hay=$(mktemp) || { CERT_TOTAL=-1; return 0; }
    if [[ -n $db && -f $db ]] && command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 -readonly "$db" 'SELECT value FROM settings;' >>"$hay" 2>/dev/null && have_hay=1
        sqlite3 -readonly "$db" 'SELECT stream_settings FROM inbounds;' >>"$hay" 2>/dev/null && have_hay=1
    fi
    if [[ -n $ngx && -d $ngx ]]; then
        while IFS= read -r p; do
            grep -RhsE 'ssl_certificate|letsencrypt|/cert/' -- "$p" >>"$hay" 2>/dev/null
        done < <(nginx_active_paths "$ngx")
        have_hay=1
    fi
    now=$(date +%s)
    if [[ -n $live && -d $live ]]; then
        for d in "$live"/*/; do
            [[ -d $d ]] || continue
            d=${d%/}; name=${d##*/}
            f=$d/cert.pem; [[ -f $f ]] || f=$d/fullchain.pem; [[ -f $f ]] || continue
            cert_record le "$name" "$d" "$f"
        done
    fi
    if [[ -n $xdir && -d $xdir ]]; then
        for d in "$xdir"/*/; do
            [[ -d $d ]] || continue
            d=${d%/}; name=${d##*/}
            f=$d/fullchain.pem
            [[ -f $f ]] || f=$(find "$d" -maxdepth 1 -type f \( -name '*.crt' -o -name '*.cer' -o -name 'cert.pem' \) -print -quit 2>/dev/null)
            [[ -n $f && -f $f ]] || continue
            cert_record acme "$name" "$d" "$f"
        done
    fi
    rm -f -- "$hay"
    while IFS=$'\t' read -r kind _n _d _e _days state used; do
        CERT_TOTAL=$(( CERT_TOTAL + 1 ))
        case $state in valid) CERT_VALID=$(( CERT_VALID + 1 )) ;; soon) CERT_SOON=$(( CERT_SOON + 1 )) ;; expired) CERT_EXPIRED=$(( CERT_EXPIRED + 1 )) ;; esac
        [[ $used == 0 ]] && CERT_UNUSED=$(( CERT_UNUSED + 1 ))
    done <"$out"
    return 0
}

cert_line() {   # one-line summary of the last scan
    local s
    if (( CERT_TOTAL < 0 )); then printf 'not available (openssl missing)'; return; fi
    if (( CERT_TOTAL == 0 )); then printf 'none found'; return; fi
    s="${CERT_TOTAL} total · ${CERT_VALID} valid"
    (( CERT_SOON > 0 ))    && s+=" · ${CERT_SOON} expiring within 14 days"
    (( CERT_EXPIRED > 0 )) && s+=" · ${CERT_EXPIRED} EXPIRED"
    (( CERT_UNUSED > 0 ))  && s+=" · ${CERT_UNUSED} not used by the panel or Nginx"
    printf '%s' "$s"
}
cert_color() { if (( CERT_EXPIRED > 0 )); then printf '%s' "$C_RED"; elif (( CERT_SOON > 0 || CERT_UNUSED > 0 )); then printf '%s' "$C_YELLOW"; else printf '%s' "$C_GREEN"; fi; }

cert_when() {   # cert_when <state> <days>
    case $1 in
        expired) printf 'EXPIRED %s day(s) ago' "$2" ;;
        soon)    printf 'expires in %s day(s)' "$2" ;;
        *)       printf 'valid, %s days left' "$2" ;;
    esac
}

# cert_table [max-rows]  - the certificates that need attention first
cert_table() {
    local max=${1:-12} n=0 kind name _d _e days state used src col use
    (( CERT_TOTAL > 0 )) || return 0
    printf '\n %s   %-26s %-14s %-24s %s%s\n' "$C_DIM" "CERTIFICATE" "SOURCE" "STATUS" "IN USE" "$C_RESET"
    while IFS=$'\t' read -r kind name _d _e days state used; do
        (( ++n > max )) && { ui_info "Only the first ${max} certificates are listed."; break; }
        [[ $kind == le ]] && src="Let's Encrypt" || src="ACME (panel)"
        case $state in expired) col=$C_RED ;; soon) col=$C_YELLOW ;; *) col=$C_GREEN ;; esac
        case $used in 1) use="${C_GREEN}yes${C_RESET}" ;; 0) use="${C_YELLOW}NO${C_RESET}" ;; *) use="${C_DIM}?${C_RESET}" ;; esac
        printf ' %s▌%s  %-26.26s %-14s %s%-24s%s %s\n' "$C_CYAN" "$C_RESET" "$name" "$src" "$col" "$(cert_when "$state" "$days")" "$C_RESET" "$use"
    done < <(awk -F'\t' '{ k = ($6 == "expired") ? 0 : (($7 == 0) ? 1 : (($6 == "soon") ? 2 : 3)); print k "\t" $0 }' "$CERT_FILE" | sort -t$'\t' -k1,1n -k6,6n | cut -f2-)
}

# cert_cleanup <expired|unused>   - snapshot, then delete certificates that nothing references
cert_cleanup() {
    local mode=$1 kind name d _e days state used ts snap n=0 held=0 p
    local -a cand=() keep=() tarp=()
    while IFS=$'\t' read -r kind name d _e days state used; do
        if [[ $used == 0 && ( $mode == unused || $state == expired ) ]]; then cand+=("${kind}"$'\t'"${name}"$'\t'"${d}"$'\t'"${state}"$'\t'"${days}")
        elif [[ $state == expired && $used == 1 ]]; then held=$(( held + 1 )); fi
    done <"$CERT_FILE"
    if (( held > 0 )); then
        ui_warn "${held} expired certificate(s) are STILL USED by the panel or Nginx - they are not deleted. Renew them (certbot renew, or the panel's ACME menu)."
    fi
    if (( ${#cand[@]} == 0 )); then ui_ok "Nothing to remove."; return 0; fi
    printf '\n %s   %-30s %-14s %s%s\n' "$C_DIM" "CERTIFICATE" "SOURCE" "STATUS" "$C_RESET"
    for p in "${cand[@]}"; do
        IFS=$'\t' read -r kind name d state days <<<"$p"
        printf ' %s▌%s  %-30s %-14s %s\n' "$C_CYAN" "$C_RESET" "$name" "$([[ $kind == le ]] && echo "Let's Encrypt" || echo "ACME (panel)")" "$(cert_when "$state" "$days")"
    done
    printf '\n'
    confirm "$(tf q_del_certs "${#cand[@]}")" n || { ui_info "Nothing was deleted."; return 0; }
    ts=$(date +%Y%m%d-%H%M%S); snap="${BACKUP_HOME}/pre-cleanup-certs-${ts}.tar.gz"
    for p in "${cand[@]}"; do
        IFS=$'\t' read -r kind name d _e <<<"$p"
        if [[ $kind == le ]]; then
            for f in "etc/letsencrypt/live/${name}" "etc/letsencrypt/archive/${name}" "etc/letsencrypt/renewal/${name}.conf"; do
                [[ -e /$f ]] && tarp+=("$f")
            done
        else tarp+=("${d#/}"); fi
    done
    if (( ${#tarp[@]} )) && tar -C / -czf "$snap" "${tarp[@]}" 2>/dev/null; then
        chmod 600 "$snap"; ui_ok "Rollback copy: ${snap}"
    else
        ui_warn "Could not create the rollback copy - nothing was deleted."; return 0
    fi
    for p in "${cand[@]}"; do
        IFS=$'\t' read -r kind name d _e <<<"$p"
        if [[ $kind == le ]]; then
            if command -v certbot >/dev/null 2>&1 && [[ -f /etc/letsencrypt/renewal/${name}.conf ]] \
               && certbot delete --cert-name "$name" --non-interactive >/dev/null 2>&1; then
                n=$(( n + 1 ))
            else
                rm -rf -- "/etc/letsencrypt/live/${name}" "/etc/letsencrypt/archive/${name}" "/etc/letsencrypt/renewal/${name}.conf" && n=$(( n + 1 ))
            fi
        else
            rm -rf -- "$d" && n=$(( n + 1 ))
        fi
    done
    ui_ok "Removed ${n} certificate(s)."
    ui_info "To restore them: tar -C / -xzf ${snap}"
}

# ── System optimization menu ─────────────────────────────────────────────────
OPT_BK=() OPT_LEFT=() OPT_BK_BYTES=0 OPT_LEFT_BYTES=0 OPT_KEEP=3

path_bytes() { local p b=0 s; for p in "$@"; do s=$(du -sb -- "$p" 2>/dev/null | cut -f1); b=$(( b + ${s:-0} )); done; printf '%s' "$b"; }

leftover_candidates() {   # rollback copies, old reports and stale staging folders under /root
    find "$BACKUP_HOME" -maxdepth 1 \( \
        -name 'pre-restore-*' -o -name 'pre-update-*' -o -name 'pre-cleanup-certs-*' -o -name 'moc-migration-report-*.txt' \
        -o -name 'moc-panel-*.txt' -o -name 'moc-nx-migration-*' \
        -o \( -name '.moc-*' -mmin +60 \) -o \( -name '.xui-backup.*' -mmin +60 \) -o \( -name '.xui-verify.*' -mmin +60 \) \
        -o \( -name '.nx-tool.*' -mmin +60 \) \) -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-
}

optimize_scan() {
    local db=""
    [[ -f /etc/x-ui/x-ui.db ]] && db=/etc/x-ui/x-ui.db
    [[ -n $CERT_FILE && ${CERT_FILE##*/} == moc-certs.* ]] || CERT_FILE=$(mktemp "${TMPDIR:-/tmp}/moc-certs.XXXXXX")
    register_cleanup "$CERT_FILE"
    cert_scan "$CERT_FILE" /etc/letsencrypt/live /root/cert "$db" /etc/nginx
    mapfile -t OPT_BK < <(backup_candidates)
    OPT_BK_BYTES=0; (( ${#OPT_BK[@]} )) && OPT_BK_BYTES=$(path_bytes "${OPT_BK[@]}")
    mapfile -t OPT_LEFT < <(leftover_candidates)
    OPT_LEFT_BYTES=0; (( ${#OPT_LEFT[@]} )) && OPT_LEFT_BYTES=$(path_bytes "${OPT_LEFT[@]}")
}

optimize_overview() {
    local pct free old=0
    pct=$(df --output=pcent / 2>/dev/null | awk 'NR==2 {gsub(/[ %]/, ""); print}'); : "${pct:=0}"
    free=$(df -BG --output=avail / 2>/dev/null | awk 'NR==2 {gsub(/G/, ""); print}'); : "${free:=0}"
    (( ${#OPT_BK[@]} > OPT_KEEP )) && old=$(( ${#OPT_BK[@]} - OPT_KEEP ))
    ui_card "SCAN RESULT"
    printf ' %s▌%s  %s%-18s%s ' "$C_CYAN" "$C_RESET" "$C_DIM" "DISK /" "$C_RESET"; meter "$pct" 20; printf '  %s GB free\n' "$free"
    ui_kv "CERTIFICATES" "$(cert_line)" "$(cert_color)"
    ui_kv "BACKUP FILES" "${#OPT_BK[@]} file(s) · $(human_bytes "$OPT_BK_BYTES")$( (( old )) && printf '   (%s older than the newest %s)' "$old" "$OPT_KEEP")" "$C_WHITE"
    ui_kv "LEFTOVERS" "${#OPT_LEFT[@]} item(s) · $(human_bytes "$OPT_LEFT_BYTES")   (rollback copies, old reports, staging folders)" "$C_WHITE"
    cert_table 8
}

clean_backups_flow() {
    local keep f n=0 total=0 sz
    local -a del=()
    if (( ${#OPT_BK[@]} == 0 )); then ui_info "No XUI_Backup_* files found under ${BACKUP_HOME}."; return 0; fi
    menu_select_b "$(t q_keep_n)" 3 "$(tf o_keep_n 1)" "$(tf o_keep_n 2)" "$(tf o_keep_n 3)   $(t o_recommended)" "$(tf o_keep_n 5)" "$(tf o_keep_n 10)" || return 0
    case $MENU_RESULT in 1) keep=1 ;; 2) keep=2 ;; 3) keep=3 ;; 4) keep=5 ;; *) keep=10 ;; esac
    OPT_KEEP=$keep
    for f in "${OPT_BK[@]}"; do
        (( ++n > keep )) && del+=("$f")
    done
    if (( ${#del[@]} == 0 )); then ui_ok "Only ${#OPT_BK[@]} backup file(s) exist - nothing older to remove."; return 0; fi
    printf '\n %s   %-52s %-12s %s%s\n' "$C_DIM" "FILE (will be deleted)" "SIZE" "DATE" "$C_RESET"
    for f in "${del[@]}"; do
        sz=$(stat -c %s -- "$f" 2>/dev/null || echo 0); total=$(( total + sz ))
        printf ' %s▌%s  %-52s %-12s %s\n' "$C_CYAN" "$C_RESET" "${f#"$BACKUP_HOME"/}" "$(human_bytes "$sz")" "$(date -r "$f" '+%Y-%m-%d %H:%M')"
    done
    printf '\n'
    ui_warn "$(t w_keep_off)"
    confirm "$(tf q_del_bk "${#del[@]}" "$(human_bytes "$total")")" n || { ui_info "Nothing was deleted."; return 0; }
    n=0
    for f in "${del[@]}"; do rm -f -- "$f" && n=$(( n + 1 )); done
    ui_ok "Deleted ${n} backup file(s), freed $(human_bytes "$total")."
}

clean_leftovers_flow() {
    local f sz total=0 n=0
    if (( ${#OPT_LEFT[@]} == 0 )); then ui_ok "No rollback copies or leftovers found."; return 0; fi
    ui_warn "$(t w_rollback)"
    printf '\n %s   %-56s %s%s\n' "$C_DIM" "ITEM" "SIZE" "$C_RESET"
    for f in "${OPT_LEFT[@]}"; do
        sz=$(path_bytes "$f"); total=$(( total + sz ))
        printf ' %s▌%s  %-56s %s\n' "$C_CYAN" "$C_RESET" "${f#"$BACKUP_HOME"/}" "$(human_bytes "$sz")"
    done
    printf '\n'
    confirm "$(tf q_del_left "${#OPT_LEFT[@]}" "$(human_bytes "$total")")" n || { ui_info "Nothing was deleted."; return 0; }
    for f in "${OPT_LEFT[@]}"; do rm -rf -- "$f" && n=$(( n + 1 )); done
    ui_ok "Deleted ${n} item(s), freed $(human_bytes "$total")."
}

clean_certs_flow() {
    local old_tot=$CERT_TOTAL
    (( old_tot > 0 )) || { ui_info "No certificates were found (Let's Encrypt or panel ACME)."; return 0; }
    menu_select_b "$(t q_which_certs)" 1 "$(t o_certs_safe)" "$(t o_certs_all)" || return 0
    if [[ $MENU_RESULT == 1 ]]; then cert_cleanup expired; else cert_cleanup unused; fi
}

do_optimize() {
    local sel=1
    while true; do
        show_header
        ui_section "$(t optimize_title)"
        spin_start "Scanning certificates, backups and leftovers..."
        optimize_scan
        spin_stop
        typed optimize_overview
        printf '\n'
        menu_select_b "$(t choose_action)" "$sel" \
            "$(tf opt_c_certs "$CERT_EXPIRED" "$CERT_UNUSED")" \
            "$(tf opt_c_backups "${#OPT_BK[@]}" "$(human_bytes "$OPT_BK_BYTES")")" \
            "$(tf opt_c_left "${#OPT_LEFT[@]}" "$(human_bytes "$OPT_LEFT_BYTES")")" \
            "$(t opt_c_servers)" \
            "$(t opt_c_stealth)" \
            "$(t opt_c_sysupd)" \
            "$(t opt_c_scan)" || return 0
        sel=$MENU_RESULT
        case $MENU_RESULT in
            1) clean_certs_flow; pause_key ;;
            2) clean_backups_flow; pause_key ;;
            3) clean_leftovers_flow; pause_key ;;
            4) do_servers ;;
            5) run_workflow do_stealth; pause_key ;;
            6) confirm_where "$(t w_sysupd)" && { run_workflow do_sysupdate; pause_key; } ;;
        esac
    done
}
# ── Servers: saved list (encoded .dat - never a password), checks, scoring, remote restore ─────────
readonly SRV_DIR='/etc/moc-networks'
readonly SRV_FILE="${SRV_DIR}/servers.dat" SRV_PREF="${SRV_DIR}/servers.pref"
SRV_NAME='' SRV_ADDR='' SRV_IP='' SRV_PORT=22 SRV_USER=root SRV_PASS=''
SSH_PRE=() SSH_OPTS=() SCP_OPTS=() INFRA_TITLE=''
SP_NAT=-1 SP_LOCAL_V4='' GH_OK=0 GH_TOTAL=0 GH_ROWS=()

srvdb() {   # srvdb list | upsert <name host port user status score location public_ip nat checked> | remove <host> <port>
python3 -I - "$SRV_FILE" "$@" <<'PYSRV'
import base64, json, os, sys, zlib
path, cmd, args = sys.argv[1], sys.argv[2], sys.argv[3:]
MAGIC = b"MOCDAT1\n"
FIELDS = ("name", "host", "port", "user", "status", "score", "location", "public_ip", "nat", "checked")
def load():
    try:
        raw = open(path, "rb").read()
        if not raw.startswith(MAGIC): return []
        data = json.loads(zlib.decompress(base64.b64decode(raw[len(MAGIC):])).decode("utf-8"))
        return data if isinstance(data, list) else []
    except Exception:
        return []
def save(items):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    blob = MAGIC + base64.b64encode(zlib.compress(json.dumps(items, ensure_ascii=False).encode("utf-8"), 9))
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f: f.write(blob)
    os.replace(tmp, path)
items = load()
if cmd == "list":
    for it in items: print("\t".join(str(it.get(k, "")).replace("\t", " ") for k in FIELDS))
elif cmd == "upsert":
    rec = dict(zip(FIELDS, args))
    for it in items:
        if it.get("host") == rec["host"] and str(it.get("port")) == rec["port"]:
            it.update({k: v for k, v in rec.items() if v != ""}); break
    else: items.append(rec)
    save(items)
elif cmd == "remove":
    save([it for it in items if not (it.get("host") == args[0] and str(it.get("port")) == args[1])])
PYSRV
}

srv_pref() { [[ -r $SRV_PREF ]] && head -n 1 "$SRV_PREF" | tr -d '[:space:]'; return 0; }
srv_set_pref() { install -d -m 700 "$SRV_DIR" && printf '%s\n' "$1" >"$SRV_PREF" && chmod 600 "$SRV_PREF"; }

# Asked once, at the first start: may this script remember the servers you work with?
ask_server_saving() {
    [[ -z $(srv_pref) ]] || return 0
    (( REMOTE_MODE )) && return 0
    [[ -t 0 ]] || return 0
    show_header
    ui_section "$(t srv_save_title)"
    ui_info "$(t srv_save_info)"
    if confirm "$(t srv_save_ask)" y; then srv_set_pref yes && ui_ok "$(t srv_save_yes)"
    else srv_set_pref no && ui_info "$(t srv_save_no)"; fi
    pause_key
}

srv_remember() {   # srv_remember <status> [score] [location]
    [[ $(srv_pref) == yes && -n $SRV_ADDR ]] || return 0
    install -d -m 700 "$SRV_DIR" 2>/dev/null
    srvdb upsert "${SRV_NAME:-$SRV_ADDR}" "$SRV_ADDR" "$SRV_PORT" "$SRV_USER" "$1" "${2:-}" "${3:-}" "${PUB_IP:-}" "${SP_NAT}" "$(date '+%Y-%m-%d %H:%M')" 2>/dev/null
    chmod 600 "$SRV_FILE" 2>/dev/null
    return 0
}

srv_table() {   # prints the saved servers; returns 1 when there are none
    local name host port user st score loc _pub _nat chk col n=0
    [[ -f $SRV_FILE ]] || return 1
    while IFS=$'\t' read -r name host port user st score loc _pub _nat chk; do
        [[ -n $host ]] || continue
        (( n == 0 )) && printf '\n %s   %-18s %-24s %-9s %-9s %s%s\n' "$C_DIM" "NAME" "ADDRESS : SSH PORT" "STATUS" "SCORE" "LOCATION · LAST CHECK" "$C_RESET"
        n=$(( n + 1 ))
        case $st in online) col=$C_GREEN ;; offline) col=$C_RED ;; *) col=$C_YELLOW ;; esac
        printf ' %s▌%s  %s%-18s%s %s%-24s%s %s%-9s%s %-9s %s%s%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "${name:0:18}" "$C_RESET" "$C_ACC" "${host}:${port}" "$C_RESET" "$col" "${st:-unknown}" "$C_RESET" "${score:+${score}/100}" "$C_DIM" "${loc:-?}${chk:+ · ${chk}}" "$C_RESET"
    done < <(srvdb list)
    (( n > 0 ))
}

# pick_server -> SRV_ADDR SRV_IP SRV_PORT SRV_USER SRV_NAME ; 0 = chosen, 1 = back / cancelled
pick_server() {
    local name host port user st score loc _pub _nat chk lbl
    local -a labels=() h=() po=() us=() nm=()
    if [[ -f $SRV_FILE ]]; then
        while IFS=$'\t' read -r name host port user st score loc _pub _nat chk; do
            [[ -n $host ]] || continue
            lbl=$'\x01'"${name:-$host}"$'\x02'"  (${host}:${port} · ${st:-unknown}${score:+ · score ${score}/100}${loc:+ · ${loc}})"
            labels+=("$lbl"); h+=("$host"); po+=("$port"); us+=("${user:-root}"); nm+=("${name:-$host}")
        done < <(srvdb list)
    fi
    if (( ${#labels[@]} )); then
        menu_select_b "$(t srv_which)" 1 "${labels[@]}" "$(t srv_new)" || return 1
        if (( MENU_RESULT <= ${#labels[@]} )); then
            SRV_ADDR=${h[MENU_RESULT-1]}; SRV_PORT=${po[MENU_RESULT-1]}; SRV_USER=${us[MENU_RESULT-1]}; SRV_NAME=${nm[MENU_RESULT-1]}
            resolve_destination "$SRV_ADDR" || return 1
            SRV_IP=$RESOLVED_IP
            return 0
        fi
    fi
    ui_info "$(t srv_back_hint)"
    while true; do
        prompt_input "$(t remote_addr)" 0 || return 1
        [[ $INPUT_VALUE == 0 ]] && return 1
        if resolve_destination "$INPUT_VALUE"; then SRV_ADDR=$INPUT_VALUE; SRV_IP=$RESOLVED_IP; break; fi
        ui_warn "$(t addr_retry)"
    done
    prompt_input "$(t remote_user)" 0 root || return 1; SRV_USER=$INPUT_VALUE
    [[ $SRV_USER == 0 ]] && return 1
    [[ $SRV_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { ui_err "Invalid SSH username."; return 1; }
    prompt_input "$(t remote_port)" 0 22 || return 1; SRV_PORT=$INPUT_VALUE
    [[ $SRV_PORT == 0 ]] && return 1
    valid_port "$SRV_PORT" || { ui_err "Invalid SSH port: $SRV_PORT"; return 1; }
    SRV_NAME=$SRV_ADDR
    return 0
}

SSH_DEST='' SSH_CTL=''
srv_ssh_setup() {   # builds the ssh/scp options; asks for the password only when sshpass is available (never stored)
    SSH_PRE=(); SRV_PASS=''
    SSH_CTL="/tmp/.moc-ssh-$$-%C"
    SSH_DEST="${SRV_USER}@${SRV_IP}"
    if command -v sshpass >/dev/null 2>&1; then
        prompt_input "SSH password for ${SSH_DEST}  (Enter = use your SSH key): " 1 "-" || return 1
        if [[ $INPUT_VALUE != "-" ]]; then SRV_PASS=$INPUT_VALUE; SSH_PRE=(sshpass -e); fi
    else
        ui_info "sshpass is not installed - OpenSSH asks for the password itself (or uses your SSH key). This script never stores it."
    fi
    SSH_OPTS=(-p "$SRV_PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ControlMaster=auto -o "ControlPath=${SSH_CTL}" -o ControlPersist=300)
    SCP_OPTS=(-P "$SRV_PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ControlMaster=auto -o "ControlPath=${SSH_CTL}" -o ControlPersist=300)
}

ssh_open() {   # authenticate ONCE (the password prompt happens here); every later ssh/scp call reuses this connection silently
    local rc=0
    ui_info "$(t ssh_auth)"
    SSHPASS=$SRV_PASS "${SSH_PRE[@]}" ssh "${SSH_OPTS[@]}" "$SSH_DEST" true || rc=$?
    if (( rc != 0 )); then ui_err "$(t ssh_fail)"; return 1; fi
    ui_ok "$(t ssh_ok)"
    return 0
}
ssh_close() { ssh -O exit "${SSH_OPTS[@]}" "$SSH_DEST" >/dev/null 2>&1 || true; }

tcp_open() { timeout "${3:-3}" bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }   # tcp_open <host> <port> [seconds]

# ── Server inspection: NAT, GitHub reachability, probe protocol ──────────────
GH_TARGETS=(
    "github.com|https://github.com/"
    "GitHub API|https://api.github.com/"
    "GitHub raw files|https://raw.githubusercontent.com/nx-panel/panel/main/install.sh"
    "release downloads|https://github.com/Nexora-VPN/nexora-migrate/releases/latest/download/SHA256SUMS"
    "3x-ui installer|https://raw.githubusercontent.com/mhsanaei/3x-ui/main/install.sh"
    "Xray releases|https://github.com/XTLS/Xray-core/releases/latest")

check_github() {   # fills GH_ROWS ("name|OK/FAIL|ms|http-code"), GH_OK, GH_TOTAL
    local i tmp name code secs ms st
    local -a pids=()
    GH_ROWS=() GH_OK=0 GH_TOTAL=${#GH_TARGETS[@]}
    command -v curl >/dev/null 2>&1 || { GH_TOTAL=0; return 0; }
    tmp=$(mktemp -d) || { GH_TOTAL=0; return 0; }
    for i in "${!GH_TARGETS[@]}"; do
        ( curl -sS -L -r 0-2047 -o /dev/null --connect-timeout 5 --max-time 10 -w '%{http_code} %{time_total}\n' "${GH_TARGETS[i]#*|}" >"${tmp}/${i}" 2>/dev/null || printf '000 0\n' >"${tmp}/${i}" ) &
        pids+=($!)
    done
    for i in "${pids[@]}"; do wait "$i" 2>/dev/null; done
    for i in "${!GH_TARGETS[@]}"; do
        name=${GH_TARGETS[i]%%|*}
        code=""; secs=0; { read -r code secs <"${tmp}/${i}" || true; } 2>/dev/null; [[ $code =~ ^[0-9]{3}$ ]] || { code=000; secs=0; }
        ms=$(awk -v t="${secs:-0}" 'BEGIN { printf "%d", t * 1000 }')
        # 2xx/3xx = fine; 404/405/416 = the host answered (only the path or the range is odd); 000/403/5xx = blocked or down
        if [[ $code =~ ^[23] || $code =~ ^(404|405|416)$ ]]; then st=OK; GH_OK=$(( GH_OK + 1 )); else st=FAIL; fi
        GH_ROWS+=("${name}|${st}|${ms}|${code}")
    done
    rm -rf -- "$tmp"
}

nat_detect() {   # SP_NAT: 1 = behind NAT, 0 = the public address is on the server, -1 = unknown
    SP_LOCAL_V4=$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4, a, "/"); print a[1]}' | paste -sd, - | sed 's/,/, /g')
    SP_NAT=-1
    [[ -n ${PUB_IP:-} && -n $SP_LOCAL_V4 ]] || return 0
    if [[ ",${SP_LOCAL_V4// /}," == *",${PUB_IP},"* ]]; then SP_NAT=0; else SP_NAT=1; fi
}

final_score() {
    local s
    s=$(compute_score)
    if (( GH_TOTAL > 0 && GH_OK == 0 )); then s=$(( s > 15 ? s - 15 : 0 ))
    elif (( GH_TOTAL > 0 && GH_OK < GH_TOTAL )); then s=$(( s > 5 ? s - 5 : 0 )); fi
    printf '%d' "$s"
}
score_tier() {
    local s=$1
    if   (( s >= 90 )); then printf 'Monster Node (Ideal)'
    elif (( s >= 70 )); then printf 'Optimal Server'
    elif (( s >= 40 )); then printf 'Standard Instance'
    else                     printf 'Entry-level'; fi
}

PROBE_VARS=(SP_HOST SP_KERNEL SP_ARCH SP_VIRT SP_UPTIME SP_L1 SP_L5 SP_L15 SP_CPU_MODEL SP_RAM_AVAIL SP_SWAP_MB SP_DISK_USED_GB SP_DISK_PCT
    SP_TZ SP_NTP SP_CC SP_QDISC SP_FW SP_SSH_PORT SP_P80 SP_P443 SP_LISTEN SP_IPV6 SP_REBOOT SP_F2B SP_NGINX SP_CERTBOT SP_DOCKER SP_RTT SP_CITY
    SP_ISP SP_ASN SP_PANELS SP_NAT SP_LOCAL_V4 CPU_CORES RAM_MB DISK_TOTAL_GB DISK_FREE_GB OS_NAME PUB_IP PUB_COUNTRY PUB_CC SPEED_MBPS GH_OK GH_TOTAL)

reset_specs() {
    local v
    for v in "${PROBE_VARS[@]}"; do printf -v "$v" '%s' ''; done
    CPU_CORES=1 RAM_MB=0 DISK_TOTAL_GB=0 DISK_FREE_GB=0 SP_L1=0 SP_L5=0 SP_L15=0 SP_RAM_AVAIL=0 SP_SWAP_MB=0 SP_DISK_USED_GB=0 SP_DISK_PCT=0
    SP_LISTEN=0 SP_REBOOT=0 SP_NAT=-1 GH_OK=0 GH_TOTAL=0 OS_NAME=Linux PUB_COUNTRY=Unavailable PUB_CC='--'
    GH_ROWS=()
}

probe_main() {   # --probe: print the inspection as KEY=VALUE lines (used over SSH by the server check)
    local v
    init_ui
    collect_specs
    printf 'PROBE_BEGIN\n'
    for v in "${PROBE_VARS[@]}"; do printf '%s=%s\n' "$v" "$(printf '%s' "${!v-}" | tr -d '\r\n\t')"; done
    for v in "${GH_ROWS[@]}"; do printf 'GH=%s\n' "$v"; done
    printf 'PROBE_END\n'
}

probe_parse() {   # reads probe_main's output on stdin
    local line k val on=0 ok v
    GH_ROWS=()
    while IFS= read -r line; do
        [[ $line == PROBE_BEGIN ]] && { on=1; continue; }
        [[ $line == PROBE_END ]] && break
        (( on )) || continue
        k=${line%%=*}; val=${line#*=}
        val=${val//[^[:print:]]/}
        if [[ $k == GH ]]; then GH_ROWS+=("$val"); continue; fi
        ok=0; for v in "${PROBE_VARS[@]}"; do [[ $v == "$k" ]] && { ok=1; break; }; done
        (( ok )) && printf -v "$k" '%s' "$val"
    done
    return 0
}

server_check_local() {
    local score tier
    spin_start "Inspecting this server: hardware, network, NAT, GitHub access, speed test (up to 40 s)..."
    collect_specs
    spin_stop
    score=$(final_score); tier=$(score_tier "$score")
    INFRA_TITLE="SERVER CHECK  -  THIS SERVER"
    typed_begin; infra_report "$score" "$tier"; typed_end
    INFRA_TITLE=''
    check_blacklists "${PUB_IP:-}"
}

network_only_check() {   # fallback when SSH is not possible: what can be seen from here
    local rtt p st open=0 json="" loc=""
    ui_section "SERVER CHECK  -  ${SRV_ADDR} (network view only)"
    rtt=$(ping -c 3 -W 2 "$SRV_IP" 2>/dev/null | awk -F/ '/^(rtt|round-trip)/ {printf "%d", $5}')
    ui_kv "ADDRESS" "${SRV_ADDR}  ->  ${SRV_IP}" "$C_WHITE"
    ui_kv "LATENCY" "$(or_else "$rtt" ' ms from this server' 'no ping answer (ICMP may be filtered)')" "$C_YELLOW"
    for p in "$SRV_PORT" 80 443; do
        if tcp_open "$SRV_IP" "$p" 3; then st="open"; open=$(( open + 1 )); else st="closed / filtered"; fi
        ui_kv "PORT ${p}" "$st" "$([[ $st == open ]] && echo "$C_GREEN" || echo "$C_DIM")"
    done
    json=$(curl -4 -fsS --connect-timeout 3 --max-time 7 "https://ipwho.is/${SRV_IP}" 2>/dev/null || true)
    if [[ -n $json ]]; then
        loc=$(python3 -I -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
c=d.get("connection") or {}
print("%s, %s  ·  %s" % (d.get("country",""), d.get("city",""), c.get("isp","")))' <<<"$json" 2>/dev/null)
        ui_kv "LOCATION / ISP" "$loc" "$C_YELLOW"
    fi
    check_blacklists "$SRV_IP"
    ui_info "A full score (CPU, RAM, disk, speed, NAT, GitHub access) needs an SSH login to the server."
    if tcp_open "$SRV_IP" "$SRV_PORT" 3; then srv_remember online "" "${loc%%  ·*}"; else srv_remember offline; fi
}

server_check_remote() {   # uses SRV_* + SSH_*; shows the same report as the local check
    local out='' rc=0 score tier
    reset_specs
    if [[ -f $SCRIPT_PATH ]] && command -v ssh >/dev/null 2>&1; then
        spin_start "$(t ssh_working_probe)"
        out=$(SSHPASS=$SRV_PASS "${SSH_PRE[@]}" ssh -T "${SSH_OPTS[@]}" "$SSH_DEST" 'bash -s -- --probe' <"$SCRIPT_PATH" 2>/dev/null) || rc=$?
        spin_stop
    else rc=1; fi
    if (( rc != 0 )) || [[ $out != *PROBE_BEGIN* ]]; then
        ui_warn "Could not log in over SSH (or run the inspection there) - showing what is visible from here instead."
        network_only_check
        return 0
    fi
    probe_parse <<<"$out"
    score=$(final_score); tier=$(score_tier "$score")
    INFRA_TITLE="SERVER CHECK  -  ${SRV_NAME:-$SRV_ADDR}"
    typed_begin; infra_report "$score" "$tier"; typed_end
    INFRA_TITLE=''
    check_blacklists "${PUB_IP:-$SRV_IP}"
    srv_remember online "$score" "${PUB_COUNTRY:-?}${SP_CITY:+, ${SP_CITY}}"
    return 0
}

server_remote_flow() {
    pick_server || return 0
    require_tools ssh || return 0
    srv_ssh_setup || return 0
    ssh_open || { network_only_check; SRV_PASS=''; return 0; }
    server_check_remote
    ssh_close; SRV_PASS=''
}

remove_server_flow() {
    local name host port user st score loc _pub _nat chk
    local -a labels=() h=() po=()
    [[ -f $SRV_FILE ]] || { ui_info "No saved servers."; return 0; }
    while IFS=$'\t' read -r name host port user st score loc _pub _nat chk; do
        [[ -n $host ]] || continue
        labels+=($'\x01'"${name:-$host}"$'\x02'"  (${host}:${port})"); h+=("$host"); po+=("$port")
    done < <(srvdb list)
    (( ${#labels[@]} )) || { ui_info "No saved servers."; return 0; }
    menu_select_b "Which saved server should be removed from the list?" 1 "${labels[@]}" || return 0
    confirm "Remove ${h[MENU_RESULT-1]}:${po[MENU_RESULT-1]} from the saved list? (The server itself is not touched.)" n || return 0
    srvdb remove "${h[MENU_RESULT-1]}" "${po[MENU_RESULT-1]}" && ui_ok "Removed."
}

do_servers() {
    local sel=1 pref lbl
    while true; do
        show_header
        ui_section "$(t srv_title)"
        ui_info "$(t srv_never)"
        srv_table || ui_info "$(t srv_none)"
        pref=$(srv_pref)
        if [[ $pref == yes ]]; then lbl="$(t srv_pref_on)"; else lbl="$(t srv_pref_off)"; fi
        printf '\n'
        menu_select_b "$(t choose_action)" "$sel" \
            "$(t srv_c_local)" \
            "$(t srv_c_remote)" \
            "$(t srv_c_remove)" \
            "$lbl" || return 0
        sel=$MENU_RESULT
        case $MENU_RESULT in
            1) run_workflow server_check_local; pause_key ;;
            2) run_workflow server_remote_flow; pause_key ;;
            3) remove_server_flow; pause_key ;;
            4) if [[ $pref == yes ]]; then
                   srv_set_pref no; ui_info "$(t srv_save_no)"
                   [[ -f $SRV_FILE ]] && confirm "Delete the already saved list file too?" n && { rm -f -- "$SRV_FILE"; ui_ok "Saved list deleted."; }
               else srv_set_pref yes; ui_ok "$(t srv_save_yes)"; fi
               pause_key ;;
        esac
    done
}

# ── Restore on a remote server ───────────────────────────────────────────────
# ship_to_remote <archive|""> <autostart: restore|"">  -> copies the files, then opens this script on the remote server
ship_to_remote() {
    local archive=${1:-} auto=${2:-} script_name='' src_host src_ip remote_cmd l1 l2
    local -a files=()
    require_tools ssh scp || return 1
    pick_server || return 1
    if [[ $SRV_USER != root ]]; then
        ui_err "The restore needs the root account on the new server (you entered '${SRV_USER}')."; return 1
    fi
    srv_ssh_setup || return 1
    ssh_open || { srv_remember offline; SRV_PASS=''; return 1; }
    [[ -n $archive ]] && files+=("$archive")
    if [[ -f $SCRIPT_PATH ]]; then
        files+=("$SCRIPT_PATH"); script_name=$(basename "$SCRIPT_PATH")
    else
        ui_warn "This script is not a regular file (piped / process substitution) - only the archive will be copied."
    fi
    if (( ${#files[@]} == 0 )); then ui_err "Nothing to copy."; return 1; fi
    if confirm "$(t srv_check_first)" y; then server_check_remote; fi
    spin_start "$(t transferring)"
    if ! SSHPASS=$SRV_PASS "${SSH_PRE[@]}" scp -q "${SCP_OPTS[@]}" -- "${files[@]}" "${SRV_USER}@${SRV_IP}:/root/"; then
        spin_stop
        ui_err "Transfer failed. Check IP, user, port, credentials and free disk space."
        srv_remember offline; ssh_close; SRV_PASS=''; return 1
    fi
    spin_stop
    ui_ok "$(t transfer_ok)"
    srv_remember online
    [[ -n $script_name ]] || { SRV_PASS=''; return 0; }
    printf -v l1 "$(t rw_l1)" "$(t w_restore)" "${SRV_NAME:-$SRV_ADDR} (${SRV_IP})"
    printf -v l2 "$(t rw_l2)" "$(host_label)"
    notice_box "$(t rw_title)" "$l1" "$l2"
    if confirm "$(t remote_launch)" y; then
        src_host=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown)
        pub_ip_quick; src_ip=$(ip_pair_plain "${PUB_QUICK:-${PUB_IP:-}}" "$(local_ip_first)"); : "${src_ip:=unavailable}"
        remote_cmd="XUI_EXECUTION_MODE=REMOTE XUI_UI_LANG=${UI_LANG} XUI_AUTOSTART=${auto} MOC_ICONS=${ICON_STYLE} XUI_SOURCE_HOST=$(printf '%q' "$src_host") XUI_SOURCE_IP=$(printf '%q' "$src_ip") bash /root/$(printf '%q' "$script_name")"
        ui_info "$(t remote_starting)"
        SSHPASS=$SRV_PASS "${SSH_PRE[@]}" ssh -tt "${SSH_OPTS[@]}" "$SSH_DEST" "$remote_cmd"
        printf '\033[0m\033[?25h\n'
        ui_ok "Back on the ORIGINAL server: $(host_label)"
    fi
    ssh_close
    SRV_PASS=''
}

remote_restore_flow() {
    select_backup_archive || return 0
    ship_to_remote "$SELECTED_ARCHIVE" restore
}

# ── Dry run for the "test the backup" mode: the same checks the real migration relies on ──────
# migration_selfcheck <source> <target> <backup-mode> <domains-file> <archive>
migration_selfcheck() {
    local pname=$1 tgt=$2 bmode=$3 dfile=$4 archive=$5 ok=0 warn=0 bad=0 score tier need_mb free_mb url code d n=0 hit=0 miss=0 pp owner
    local -a others=()
    ok_()   { ok=$(( ok + 1 ));     ui_ok "$*"; }
    warn_() { warn=$(( warn + 1 )); ui_warn "$*"; }
    bad_()  { bad=$(( bad + 1 ));   ui_err "$*"; }
    ui_section "$(t tst_title)"
    score=$(final_score); tier=$(score_tier "$score")
    printf ' %s▌%s  %s%-18s%s ' "$C_CYAN" "$C_RESET" "$C_DIM" "SERVER SCORE" "$C_RESET"
    progress_bar "$score"; printf '  %s / 100  ·  %s\n' "$score" "$tier"
    if (( score >= 40 )); then ok_ "This server scores ${score}/100 (${tier}) - enough for the migration and for running ${tgt}."
    else warn_ "This server scores only ${score}/100 (${tier}); a migration works but performance will be limited."; fi

    need_mb=$(( $(du -m "$archive" 2>/dev/null | cut -f1) * 4 + 200 )); free_mb=$(( ${DISK_FREE_GB:-0} * 1024 ))
    if (( free_mb >= need_mb )); then ok_ "Disk space: ${DISK_FREE_GB} GB free, about ${need_mb} MB needed."
    else bad_ "Disk space: ${DISK_FREE_GB} GB free but about ${need_mb} MB are needed for the unpacked backup and rollback copies."; fi

    if (( GH_TOTAL == 0 )); then warn_ "Download sources were not checked (curl is missing)."
    elif (( GH_OK == GH_TOTAL )); then ok_ "All ${GH_TOTAL} download sources (GitHub, installers, Xray releases) are reachable."
    elif (( GH_OK == 0 )); then bad_ "GitHub and the installers cannot be reached from this server - panel installers would fail. Use a proxy / mirror first."
    else warn_ "$(( GH_TOTAL - GH_OK )) of ${GH_TOTAL} download sources are unreachable (see the server report above)."; fi

    url=$(panel_installer_url "$tgt" 2>/dev/null)
    if [[ -n $url ]]; then
        code=$(curl -sS -L -r 0-512 -o /dev/null --connect-timeout 5 --max-time 10 -w '%{http_code}' "$url" 2>/dev/null || echo 000)
        if [[ $code =~ ^[23] ]]; then ok_ "$(panel_label "$tgt") installer is downloadable."; else bad_ "$(panel_label "$tgt") installer is not reachable (HTTP ${code})."; fi
    fi

    case $(panel_compat "$pname" "$tgt") in
        same|upgrade) ok_ "Compatibility: $(panel_label "$pname") -> $(panel_label "$tgt") is a direct database import." ;;
        downgrade)    warn_ "Compatibility: $(panel_label "$tgt") is an older line than $(panel_label "$pname"); the import works, newer-only settings are ignored." ;;
        *)            [[ $tgt == nx ]] && ok_ "Compatibility: NX Panel imports through its migration wizard." || warn_ "Compatibility: source type unknown." ;;
    esac

    pp=${BF_PPORT:-}
    if [[ $pp =~ ^[0-9]+$ && $tgt != nx ]]; then
        owner=$(port_owner "$pp")
        if [[ -z $owner || $owner == x-ui ]]; then ok_ "Panel port ${pp} is free (or already the panel's own)."; else warn_ "Panel port ${pp} is used by '${owner}' - the migration would pick another port."; fi
    fi
    for pp in 80 443; do
        owner=$(port_owner "$pp")
        [[ -n $owner && $owner != nginx ]] && warn_ "Port ${pp} is used by '${owner}' - Nginx / Let's Encrypt cannot use it until that stops."
    done

    mapfile -t others < <(installed_panels | grep -vx "$tgt")
    if (( ${#others[@]} )); then warn_ "Already installed here: $(printf '%s ' "${others[@]}")- it would be backed up and replaced after your confirmation."
    else ok_ "No other panel is installed on this server."; fi

    if [[ -s $dfile && -n ${PUB_IP:-} ]] && command -v getent >/dev/null 2>&1; then
        while IFS= read -r d; do
            [[ -n $d ]] || continue
            n=$(( n + 1 )); (( n > 12 )) && break
            dns_check_domain "$d" "$PUB_IP"
            case $DNS_STATE in MATCH|CDN) hit=$(( hit + 1 )) ;; *) miss=$(( miss + 1 )) ;; esac
        done < <(cut -f1 "$dfile" | sort -u)
        if (( hit + miss == 0 )); then :
        elif (( miss == 0 )); then ok_ "DNS: all ${hit} domain(s) already point to this server (${PUB_IP})."
        else warn_ "DNS: ${miss} of $(( hit + miss )) domain(s) do not point to this server (${PUB_IP}) yet - after a real migration it stays OUT OF SERVICE until you update them."; fi
    fi

    printf '\n'
    if (( bad > 0 )); then alert_box "TEST RESULT:  NOT READY" "${bad} blocking problem(s) and ${warn} note(s). Fix the red items before the real migration."
    elif (( warn > 0 )); then notice_box "TEST RESULT:  READY, WITH ${warn} NOTE(S)" "The migration can run. Read the yellow items; none of them blocks it."
    else ui_ok "TEST RESULT:  READY - every check passed (${ok}/${ok})."; fi
    ui_info "$(t test_nochange)"
    unset -f ok_ warn_ bad_
}

# ── VPN stealth check: how easy is it for an outside observer to tell this is a proxy? ────────
# (built-in probes: open ports, panel pages, active probing, open-proxy / SSTP tests, TLS and certificate consistency - explained in plain language)

stealth_tier() {   # stealth_tier <score>  -> STEALTH_TIER / STEALTH_COLOR / STEALTH_MEANING
    local s=$1
    if   (( s >= 85 )); then STEALTH_TIER="CLEAN";      STEALTH_COLOR=$C_GREEN;  STEALTH_MEANING="From the outside this server is hard to tell apart from an ordinary web host."
    elif (( s >= 70 )); then STEALTH_TIER="NOISY";      STEALTH_COLOR=$C_YELLOW; STEALTH_MEANING="A few things stand out. A casual scan will probably not flag it, a careful one might."
    elif (( s >= 50 )); then STEALTH_TIER="SUSPICIOUS"; STEALTH_COLOR=$C_YELLOW; STEALTH_MEANING="Several signs point to a proxy. A determined observer will notice it."
    else                     STEALTH_TIER="OBVIOUS";    STEALTH_COLOR=$C_RED;    STEALTH_MEANING="The server openly advertises that it is a proxy / panel. Fix the red items first."; fi
}

wrapped() {   # wrapped <indent> <color> <text>   (word wrap, never truncates)
    local ind=$1 color=$2 text=$3 w row
    local -a rows=()
    w=$(( UI_COLS - ind - 4 )); (( w < 30 )) && w=30
    if (( ${#text} > w )); then IFS=$'\x1f' read -ra rows < <(pywrap "$w" "$text"); else rows=("$text"); fi
    for row in "${rows[@]}"; do printf '%*s%s%s%s%s\n' "$ind" '' "$color" "$LRM" "$row" "$C_RESET"; done
}

stealth_render() {   # stealth_render <tsv-file> <target-label> <observer-label> <audit 0|1>
    local f=$1 label=$2 observer=$3 audit=${4:-1} type a b c d e g score=0 n=0 badge col vant tnet rd rtt area st
    local -A worst=() cnt=()
    local -a areas=("Panel exposure" "Open proxy / raw protocol" "Active probing" "Certificate" "TLS" "Web server look")
    (( audit )) && areas+=("Configuration" "Names")
    ui_section "VPN STEALTH CHECK  -  ${label}"
    vant=$(awk -F'\t' '$1 == "META" && $2 == "vantage" {print $3}' "$f"); tnet=$(awk -F'\t' '$1 == "META" && $2 == "target_net" {print $3}' "$f")
    rd=$(awk -F'\t' '$1 == "META" && $2 == "rdns" {print $3}' "$f"); rtt=$(awk -F'\t' '$1 == "META" && $2 == "rtt_ms" {print $3}' "$f")

    ui_card "HOW THIS TEST WAS DONE"
    ui_kv "OBSERVER (FROM)" "$observer" "$C_PURPLE"
    ui_kv "TARGET (TO)" "$label" "$C_ACC"
    if [[ -n $vant && $vant != '||' ]]; then IFS='|' read -r a b c <<<"$vant"; ui_kv "OBSERVER NETWORK" "${a:-?}${b:+ · ${b}}${c:+ · ${c}}" "$C_DIM"; fi
    if [[ -n $tnet && $tnet != '||' ]]; then IFS='|' read -r a b c <<<"$tnet"; ui_kv "TARGET NETWORK" "${a:-?}${b:+ · ${b}}${c:+ · AS${c#AS}}${rtt:+ · ${rtt} ms away}" "$C_DIM"; fi
    [[ -n $rd ]] && ui_kv "REVERSE DNS" "$rd" "$C_DIM"
    wrapped 3 "$C_NOTE" "A filtering system looks at a server from the OUTSIDE: it connects to its ports, speaks to them in odd ways and compares the answers with a normal website. This test does the same, from the observer above toward the target above - so you see what an outsider sees, not what the server thinks of itself."

    score=$(awk -F'\t' '$1 == "SCORE" {print $2}' "$f"); : "${score:=0}"
    stealth_tier "$score"
    printf '\n %s▌%s  %s%-18s%s ' "$C_CYAN" "$C_RESET" "$C_DIM" "STEALTH SCORE" "$C_RESET"
    progress_bar "$score"; printf '  %d / 100\n' "$score"
    ui_kv "VERDICT" "${STEALTH_TIER}" "$STEALTH_COLOR"
    wrapped 5 "$C_NOTE" "$STEALTH_MEANING"

    ui_card "WHAT AN OUTSIDE OBSERVER SEES  (ports that answered)"
    printf ' %s   %-7s %-22s %s%s\n' "$C_DIM" "PORT" "LOOKS LIKE" "DETAIL" "$C_RESET"
    while IFS=$'\t' read -r type a b c d e; do
        [[ $type == PORT ]] || continue
        n=$(( n + 1 ))
        col=$C_RESET; [[ $b == "OPEN PROXY" || $b == "SSTP VPN" ]] && col=$C_RED
        printf ' %s▌%s  %s%-7s%s %s%-22s%s %s%s%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$a" "$C_RESET" "$col" "$b" "$C_RESET" "$C_DIM" "${c:0:$(( UI_COLS - 40 ))}" "$C_RESET"
    done <"$f"
    (( n )) || ui_info "No common port answered - the server looks closed from the outside (or a firewall drops probes)."

    while IFS=$'\t' read -r type a b c d e g; do
        [[ $type == FIND ]] || continue
        cnt[$g]=$(( ${cnt[$g]:-0} + 1 ))
        case $a in HIGH) st=3 ;; MED) st=2 ;; LOW) st=1 ;; *) st=0 ;; esac
        (( st > ${worst[$g]:--1} )) && worst[$g]=$st
    done <"$f"
    ui_card "CHECKS BY AREA"
    for area in "${areas[@]}"; do
        st=${worst[$area]:--1}
        case $st in
            3) ui_err "${area}  -  serious problem" ;;
            2) ui_warn "${area}  -  needs attention" ;;
            1) ui_info "${area}  -  small note" ;;
            0) ui_ok "${area}  -  looks normal" ;;
            *) ui_ok "${area}  -  nothing unusual found" ;;
        esac
    done

    ui_card "WHAT GIVES THE SERVER AWAY, AND HOW TO FIX IT"
    n=0
    while IFS=$'\t' read -r type a b c d e g; do
        [[ $type == FIND ]] || continue
        n=$(( n + 1 ))
        case $a in
            HIGH) badge=" HIGH "; col=$C_RED ;;
            MED)  badge=" MEDIUM "; col=$C_YELLOW ;;
            LOW)  badge=" LOW "; col=$C_BLUE ;;
            *)    badge=" GOOD "; col=$C_GREEN ;;
        esac
        printf '\n %s%s%s%s  %s%s%s  %s[%s]%s\n' "$col" "$C_BOLD" "[${badge}]" "$C_RESET" "$C_BOLD" "$c" "$C_RESET" "$C_DIM" "${g:- }" "$C_RESET"
        wrapped 4 "$C_DIM" "$d"
        [[ -n ${e// /} ]] && wrapped 4 "$C_GREEN" "Fix: $e"
    done <"$f"
    (( n )) || ui_ok "Nothing obvious found."
    printf '\n'
    ui_card "HOW A FILTERING SYSTEM READS THIS  (Iran / Russia style)"
    wrapped 3 "$C_WHITE" "1. Known ports and panel pages: lists of IP:port pairs are built by scanning; a login page that names the panel, or a typical panel port, gets an address listed quickly."
    wrapped 3 "$C_WHITE" "2. Active probing: suspicious addresses receive odd requests; real websites answer with errors, proxy cores stay silent or reset. The 'Active probing' area above shows which of these this server would pass."
    wrapped 3 "$C_WHITE" "3. TLS and certificates: a certificate that does not match the name or IP, an expired one, or an old TLS version marks the server as 'not a normal site'."
    wrapped 3 "$C_WHITE" "4. Open or unwrapped protocols (SOCKS, HTTP proxy, SSTP, raw VMess/Shadowsocks) are recognised from their first bytes without any scanning."
    ui_card "WHAT THIS CHECK CANNOT SEE"
    wrapped 3 "$C_DIM" "Traffic volume and timing patterns, the reputation of your IP range, UDP protocols (WireGuard, Hysteria) and what filtering does INSIDE a country are not measured here. The score is a careful estimate, not a guarantee."
}

stealth_src() {   # prints the probe program (python) so it can run here or on a remote server
cat <<'PYSTEALTH'
import concurrent.futures as cf
import json, os, re, socket, sqlite3, ssl, sys, tempfile, time

host, mode = sys.argv[1], sys.argv[2]
SCAN = mode in ("self", "scan", "remote", "both")      # look at the target from here (network probes)
AUDIT = mode in ("self", "audit", "both")              # read the panel configuration of THIS machine
db = sys.argv[3] if len(sys.argv) > 3 else ""
extra_ports = [int(x) for x in (sys.argv[4] if len(sys.argv) > 4 else "").split(",") if x.isdigit()]
domains = [x for x in (sys.argv[5] if len(sys.argv) > 5 else "").split(",") if x]
merge_file = sys.argv[6] if len(sys.argv) > 6 else ""
import urllib.request

COMMON = [21, 22, 23, 25, 53, 80, 110, 143, 443, 465, 587, 853, 993, 995, 1080, 1194, 1723, 2052, 2053, 2082, 2083, 2086,
          2087, 2095, 2096, 3128, 3306, 3389, 4443, 5432, 5900, 6379, 7443, 8000, 8008, 8080, 8081, 8088, 8118, 8388,
          8443, 8444, 8880, 8888, 9000, 9090, 9443, 10000, 10808, 10809, 12345, 20000, 21000, 25000, 30000, 40000,
          50000, 54321, 62789]
PANEL_PORTS = {2053, 2052, 2082, 2083, 2086, 2087, 2095, 2096, 54321, 62789, 8880, 8888}
PANEL_MARK = ("x-ui", "3x-ui", "nx panel", "nx-panel", "sanaei", "alireza", "marzban", "hiddify", "s-ui", "sing-box",
              "v2ray", "xray", "clash")
NAME_MARK = {"vpn", "proxy", "v2ray", "xray", "xui", "panel", "sub", "sing", "singbox", "shadowsocks", "trojan", "vless",
             "vmess", "clash", "tunnel", "free", "bypass", "filter", "filterbreaker", "node", "reality", "hysteria"}
TRUSTED = ("let's encrypt", "digicert", "sectigo", "globalsign", "google trust", "amazon", "cloudflare", "zerossl", "microsoft",
           "godaddy", "entrust", "buypass", "r3", "r10", "r11", "e5", "e6", "e7", "e8")

rows, finds = [], []


def emit(*a):
    rows.append("\t".join((str(x).replace("\t", " ").replace("\n", " ").replace("\r", "") or " ") for x in a))


CATS = (("panel", "Panel exposure"), ("self-", "Certificate"), ("cert", "Certificate"), ("tlsonly", "Active probing"),
        ("active", "Active probing"), ("raw", "Open proxy / raw protocol"), ("proxy", "Open proxy / raw protocol"),
        ("socks", "Open proxy / raw protocol"), ("connect", "Open proxy / raw protocol"), ("sstp", "Open proxy / raw protocol"),
        ("cfg", "Configuration"), ("name", "Names"), ("rdns", "Names"), ("ver", "Web server look"), ("web", "Web server look"),
        ("no443", "Web server look"), ("many", "Web server look"), ("tls1", "TLS"), ("h2", "TLS"))


def find(sev, fid, title, detail, fix="", cat=""):
    if not cat:
        cat = next((c for p, c in CATS if fid.startswith(p)), "Other")
    finds.append((sev, fid, title, detail, fix, cat))


def dec_cert(der):
    try:
        pem = ssl.DER_cert_to_PEM_cert(der)
        with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as f:
            f.write(pem)
            name = f.name
        try:
            d = ssl._ssl._test_decode_cert(name)
        finally:
            os.unlink(name)
        flat = lambda t: {k: v for rdn in t for (k, v) in rdn}
        subj, iss = flat(d.get("subject", ())), flat(d.get("issuer", ()))
        san = [v for k, v in d.get("subjectAltName", ()) if k in ("DNS", "IP Address")]
        return {"cn": subj.get("commonName", ""), "issuer": iss.get("organizationName", "") or iss.get("commonName", ""),
                "issuer_cn": iss.get("commonName", ""), "self": subj == iss and bool(subj), "san": san, "end": d.get("notAfter", "")}
    except Exception:
        return None


def http_parse(raw):
    if not raw.startswith(b"HTTP/"):
        return None
    head, _, body = raw.partition(b"\r\n\r\n")
    lines = head.decode("latin1", "replace").split("\r\n")
    m = re.match(r"HTTP/\S+\s+(\d{3})", lines[0])
    hdr = {}
    for ln in lines[1:]:
        if ":" in ln:
            k, v = ln.split(":", 1)
            hdr[k.strip().lower()] = v.strip()
    text = body.decode("utf-8", "replace")
    t = re.search(r"<title[^>]*>(.*?)</title>", text, re.I | re.S)
    return {"status": int(m.group(1)) if m else 0, "server": hdr.get("server", ""), "location": hdr.get("location", ""),
            "title": (t.group(1).strip()[:60] if t else ""), "body": text[:6000].lower(), "len": len(body)}


def recv_all(s, limit=6000, wait=1.6):
    s.settimeout(wait)
    buf = b""
    try:
        while len(buf) < limit:
            d = s.recv(4096)
            if not d:
                break
            buf += d
    except Exception:
        pass
    return buf


REQ = ("GET / HTTP/1.1\r\nHost: %s\r\nUser-Agent: Mozilla/5.0 (X11; Linux x86_64)\r\nAccept: */*\r\nConnection: close\r\n\r\n" % host).encode()


def probe(port):
    r = {"port": port, "open": False, "kind": "closed", "detail": "", "http": None, "cert": None, "tls": "", "alpn": "",
         "banner": "", "garbage": ""}
    try:
        s = socket.create_connection((host, port), timeout=1.8)
    except Exception:
        return r
    r["open"] = True
    try:
        s.settimeout(0.5)
        try:
            b = s.recv(200)
        except Exception:
            b = b""
        if b:
            r["banner"] = b[:80].decode("latin1", "replace").strip()
            if b.startswith(b"SSH-"):
                r["kind"] = "ssh"; r["detail"] = r["banner"]
                return r
            if re.match(rb"^(220|\+OK|\* OK)", b):
                r["kind"] = "mail/ftp"; r["detail"] = r["banner"]
                return r
        s.settimeout(1.5)
        s.sendall(REQ)
        raw = b + recv_all(s)
        h = http_parse(raw)
        if h:
            r["kind"] = "http"; r["http"] = h
            return r
    except Exception:
        pass
    finally:
        try: s.close()
        except Exception: pass
    # TLS (no SNI, like a scanner that only knows the IP)
    try:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        try: ctx.set_alpn_protocols(["h2", "http/1.1"])
        except Exception: pass
        raw_s = socket.create_connection((host, port), timeout=2)
        t = ctx.wrap_socket(raw_s, server_hostname=None)
        r["tls"] = t.version() or ""
        r["alpn"] = t.selected_alpn_protocol() or ""
        r["cert"] = dec_cert(t.getpeercert(binary_form=True))
        r["kind"] = "tls"
        try:
            t.settimeout(1.8)
            t.sendall(REQ if r["alpn"] != "h2" else b"")
            raw = recv_all(t) if r["alpn"] != "h2" else b""
            h = http_parse(raw)
            if h:
                r["http"] = h; r["kind"] = "https"
            elif r["alpn"] == "h2":
                r["kind"] = "https"; r["detail"] = "HTTP/2"
        except Exception:
            pass
        t.close()
        return r
    except Exception:
        pass
    # not HTTP, not TLS: how does it react to random bytes?
    try:
        s = socket.create_connection((host, port), timeout=1.8)
        s.settimeout(1.5)
        s.sendall(os.urandom(48))
        try:
            d = s.recv(256)
            r["garbage"] = "closed" if d == b"" else "answers"
        except socket.timeout:
            r["garbage"] = "silent"
        except Exception:
            r["garbage"] = "reset"
        s.close()
    except Exception:
        r["garbage"] = "reset"
    r["kind"] = "raw"
    return r


ports = sorted(set(COMMON) | set(extra_ports)) if SCAN else []
with cf.ThreadPoolExecutor(max_workers=24) as ex:
    res = [x for x in ex.map(probe, ports) if x["open"]]


def react(port, payload, wait=1.3, sni=None, tls=False):
    """How does the port answer? reply / fin (closed politely) / rst / held (silent, waiting) / refused"""
    try:
        s = socket.create_connection((host, port), timeout=1.8)
    except Exception:
        return "refused"
    try:
        if tls:
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            s = ctx.wrap_socket(s, server_hostname=sni)
        s.settimeout(wait)
        if payload:
            s.sendall(payload)
        d = s.recv(512)
        return "fin" if d == b"" else "reply"
    except socket.timeout:
        return "held"
    except ssl.SSLError as e:
        return "alert" if "ALERT" in str(e).upper() or "alert" in str(e) else "rst"
    except Exception:
        return "rst"
    finally:
        try: s.close()
        except Exception: pass


def deep(r):
    p, k = r["port"], r["kind"]
    r["proxy"] = ""
    r["react"] = {}
    if k in ("raw", "http", "mail/ftp"):                     # open-proxy tests on plain ports
        try:
            s = socket.create_connection((host, p), timeout=1.5); s.settimeout(1.2)
            s.sendall(b"\x05\x01\x00")
            d = s.recv(8); s.close()
            if d[:2] == b"\x05\x00": r["proxy"] = "socks5"
        except Exception:
            pass
        if not r["proxy"]:
            try:
                s = socket.create_connection((host, p), timeout=1.5); s.settimeout(1.2)
                s.sendall(b"CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
                d = s.recv(64); s.close()
                if d.startswith(b"HTTP/1.") and b" 200" in d[:16]: r["proxy"] = "connect"
                elif d.startswith(b"HTTP/1.") and b" 407" in d[:16]: r["proxy"] = "connect-auth"
            except Exception:
                pass
    if k in ("tls", "https", "raw"):                         # how does it behave when spoken to wrongly?
        r["react"] = {
            "http": react(p, b"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
            "random": react(p, os.urandom(512)),
            "ff": react(p, b"\xff" * 128),
            "ssh": react(p, b"SSH-2.0-OpenSSH_9.6\r\n"),
        }
        if k in ("tls", "https"):
            r["react"]["badsni"] = react(p, b"", sni="invalid-name.example", tls=True, wait=1.0)
    if k in ("tls", "https") and p in (443, 8443, 4443, 9443):    # SSTP answers a special request inside TLS
        try:
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
            t = ctx.wrap_socket(socket.create_connection((host, p), timeout=2), server_hostname=None); t.settimeout(1.5)
            t.sendall(("SSTP_DUPLEX_POST /sra_{BA195980-CD49-458b-9E23-C84EE0ADCD75}/ HTTP/1.1\r\nHost: %s\r\n"
                       "Content-Length: 18446744073709551615\r\n\r\n" % host).encode())
            d = t.recv(64); t.close()
            if d.startswith(b"HTTP/1.1 200"): r["proxy"] = "sstp"
        except Exception:
            pass
    return r


with cf.ThreadPoolExecutor(max_workers=12) as ex:
    res = list(ex.map(deep, res))


def my_net():
    try:
        with urllib.request.urlopen("https://ipwho.is/", timeout=4) as f:
            d = json.load(f)
        c = d.get("connection") or {}
        return d.get("ip", ""), ", ".join(x for x in (d.get("city"), d.get("country_code")) if x), c.get("isp") or c.get("org") or ""
    except Exception:
        return "", "", ""


def target_net():
    try:
        with urllib.request.urlopen("https://ipwho.is/%s" % host, timeout=4) as f:
            d = json.load(f)
        c = d.get("connection") or {}
        return ", ".join(x for x in (d.get("city"), d.get("country_code")) if x), c.get("isp") or c.get("org") or "", str(c.get("asn") or "")
    except Exception:
        return "", "", ""


def cert_matches(name, san):
    name = name.lower()
    for x in san:
        x = x.lower()
        if x == name or (x.startswith("*.") and name.split(".", 1)[-1:] == [x[2:]] and "." in name):
            return True
    return False


if SCAN:
    emit("META", "target", host)
    emit("META", "probed", len(ports))
    vip, vplace, visp = my_net()
    emit("META", "vantage", "%s|%s|%s" % (vip, vplace, visp))
    tplace, tisp, tasn = target_net()
    emit("META", "target_net", "%s|%s|%s" % (tplace, tisp, tasn))
    try: emit("META", "rdns", socket.gethostbyaddr(host)[0])
    except Exception: emit("META", "rdns", "")
    rtts = []
    web_ports = [r["port"] for r in res]
    for _ in range(5 if web_ports else 0):
        t0 = time.time()
        try:
            c = socket.create_connection((host, web_ports[0]), timeout=2); c.close(); rtts.append((time.time() - t0) * 1000)
        except Exception:
            pass
    if rtts: emit("META", "rtt_ms", "%d" % sorted(rtts)[len(rtts) // 2])
seen_panel = set()
for r in res:
    p, k = r["port"], r["kind"]
    h, c = r["http"], r["cert"]
    if k == "ssh": svc, det = "SSH", r["detail"]
    elif k == "mail/ftp": svc, det = "mail / FTP", r["detail"]
    elif k in ("http", "https"):
        svc = "website (HTTPS)" if k == "https" else "website (plain HTTP)"
        det = ("HTTP %s" % h["status"] if h else (r["detail"] or "")) + ((" · " + h["title"]) if h and h["title"] else "")
        if h and h["server"]: det += " · server: " + h["server"]
    elif k == "tls": svc, det = "TLS service", "no web page answers"
    else: svc, det = "unknown service", "reaction to random bytes: " + (r["garbage"] or "?")
    if c:
        who = c["cn"] or (c["san"][0] if c["san"] else "?")
        det += " · cert: %s%s" % (who, " (self-signed)" if c["self"] else "")
    if r.get("proxy") in ("socks5", "connect"): svc, det = "OPEN PROXY", "answers as a %s proxy to anyone" % r["proxy"]
    elif r.get("proxy") == "sstp": svc, det = "SSTP VPN", "Microsoft SSTP answers on this port"
    emit("PORT", p, svc, det)

has443 = any(r["port"] == 443 for r in res)
for r in res:
    p, k, h, c = r["port"], r["kind"], r["http"], r["cert"]
    if h:
        blob = (h["title"] + " " + h["body"]).lower()
        if any(m in blob for m in PANEL_MARK) or (p in PANEL_PORTS and ("login" in blob or "password" in blob)):
            seen_panel.add(p)
            find("HIGH", "panel-%d" % p, "A management panel can be opened from the internet (port %d)" % p,
                 "Anyone who scans this address finds a login page that names the panel software. That identifies the server as a proxy panel immediately.",
                 "Put the panel behind Nginx on a private path, bind it to 127.0.0.1, or restrict the port to your own IP with the firewall.")
for r in res:
    p, k, h, c = r["port"], r["kind"], r["http"], r["cert"]
    if p in seen_panel: continue
    if p in PANEL_PORTS and k in ("http", "https", "tls"):
        find("MED", "panelport-%d" % p, "Port %d is a typical panel port and answers" % p,
             "Well-known panel ports are the first thing scanners try.", "Move the panel to a random high port, or close it to the public.")
    if c and c["self"] and k in ("https", "tls"):
        find("MED", "self-%d" % p, "Self-signed certificate on port %d" % p,
             "Ordinary websites use certificates from a public authority; a self-signed one on an IP is typical for a proxy core.",
             "Use a real domain with a Let's Encrypt certificate, or Reality with a believable camouflage site.")
    if k == "tls" and not (h or False):
        find("MED", "tlsonly-%d" % p, "TLS on port %d answers no web page" % p,
             "A real HTTPS site returns a page. A TLS port that stays silent after the handshake tells an active prober it is not a website.",
             "Give the port a fallback website (Nginx fallback, or Reality which forwards to a real site).")
    if k == "raw" and not r.get("proxy"):
        find("MED", "raw-%d" % p, "Port %d speaks an unrecognised raw protocol" % p,
             "It is neither HTTP nor TLS (reaction to random data: %s). Raw VMess / Shadowsocks / Trojan streams are what censorship systems fingerprint." % (r["garbage"] or "?"),
             "Wrap the protocol in TLS or Reality, or move it behind a CDN / web server.")
    if h and h["server"] and re.search(r"\d+\.\d+", h["server"]):
        find("LOW", "ver-%d" % p, "The web server announces its version on port %d (%s)" % (p, h["server"]),
             "Version banners help attackers pick exploits and make the stack easy to fingerprint.", "Set server_tokens off; in Nginx.")
for r in res:
    p, k, rc = r["port"], r["kind"], r.get("react") or {}
    if r.get("proxy") in ("socks5", "connect"):
        find("HIGH", "proxy-%d" % p, "Port %d is an OPEN %s proxy" % (p, "SOCKS5" if r["proxy"] == "socks5" else "HTTP"),
             "It accepts proxy requests from anyone on the internet. Scanners find these within hours, it is flagged as a proxy at once, and strangers can abuse it.",
             "Require a password / key, or close the port to the public (firewall).")
    elif r.get("proxy") == "connect-auth":
        find("MED", "proxy-%d" % p, "Port %d is an HTTP proxy asking for a password" % p,
             "Answering a proxy request with 'authentication required' tells a prober exactly what this is.", "Put it behind TLS or Reality, or restrict the port to your own IPs.")
    elif r.get("proxy") == "sstp":
        find("MED", "sstp-%d" % p, "A Microsoft SSTP VPN answers on port %d" % p,
             "SSTP replies to a special request that reveals the VPN. It is a known, easily blocked protocol.", "Use a TLS/Reality-based inbound instead.")
    if rc and not r.get("proxy"):
        quiet = [n for n in ("random", "ff", "ssh") if rc.get(n) == "held"]
        reset = [n for n in ("random", "ff", "ssh", "http") if rc.get(n) == "rst"]
        if k in ("tls", "https") and len(quiet) >= 2 and rc.get("http") in ("held", "rst", "fin"):
            find("MED", "active-silent-%d" % p, "Port %d goes silent when it receives malformed data" % p,
                 "A normal web server answers garbage with an error page or closes politely. This port just waits - the typical reaction of a proxy core. "
                 "Active probing (sending a few odd requests and watching the reaction) uses exactly this difference.",
                 "Add a fallback website for the port (Xray 'fallbacks' to Nginx), or use Reality, which answers like the real site it imitates.")
        elif k == "raw" and len(reset) >= 3:
            find("MED", "active-reset-%d" % p, "Port %d resets every request it does not understand" % p,
                 "Immediate resets for every unknown request are not how a web server behaves and make the port easy to recognise.",
                 "Wrap the protocol in TLS / Reality so unknown requests receive a normal web answer.")
        elif k in ("tls", "https") and rc.get("http") in ("reply", "fin") and not quiet:
            find("OK", "active-ok-%d" % p, "Port %d reacts to odd requests like a normal web server" % p,
                 "Malformed data gets an ordinary error or a polite close - nothing unusual for a prober to latch onto.")
    if k in ("tls", "https") and r.get("cert") and domains:
        san = r["cert"]["san"] + ([r["cert"]["cn"]] if r["cert"]["cn"] else [])
        # does the certificate shown without a name belong to one of the hosted domains?
        if not any(cert_matches(d, san) for d in domains) and not r["cert"]["self"] and p == 443:
            find("LOW", "cert-names", "The default certificate on port 443 is not for your domains",
                 "A visitor (or scanner) that connects by IP sees a certificate for '%s', not for your site. Mismatches between IP, name and certificate are a recognised proxy hint." % (r["cert"]["cn"] or "?"),
                 "Make the default server of Nginx / the Reality destination match what you want people to see, or serve your own domain by default.")
    if r.get("cert") and r["cert"].get("end"):
        try:
            left = (ssl.cert_time_to_seconds(r["cert"]["end"]) - time.time()) / 86400
            if left < 0:
                find("MED", "cert-exp-%d" % p, "The certificate on port %d has EXPIRED" % p, "Browsers and probers see an invalid certificate - a real site would not look like that.",
                     "Renew it (certbot renew) and check the auto-renew timer.")
            elif left < 7:
                find("LOW", "cert-soon-%d" % p, "The certificate on port %d expires in %d day(s)" % (p, left), "An expired certificate makes the server stand out.", "Run certbot renew.")
        except Exception:
            pass
    if p == 443 and k in ("tls", "https"):
        if r["tls"] and r["tls"] != "TLSv1.3":
            find("LOW", "tls12-443", "Port 443 does not offer TLS 1.3 (%s)" % r["tls"], "Almost every modern site speaks TLS 1.3; a TLS 1.2-only server looks old and unusual.", "Update the web server / enable TLS 1.3.")
        if r["alpn"] not in ("h2", "http/1.1"):
            find("LOW", "h2-443", "Port 443 does not negotiate HTTP/2", "Browsers always offer HTTP/2; modern sites answer with it.", "Enable http2 on the web server.")

if SCAN:
    rd = next((x.split("\t", 2)[2] for x in rows if x.startswith("META\trdns\t")), "")
    if rd:
        hit = sorted(set(re.split(r"[^a-z0-9]+", rd.lower())) & NAME_MARK)
        if hit:
            find("LOW", "rdns", "The reverse DNS name of this IP is '%s'" % rd, "Words such as %s in a reverse-DNS name are visible to anyone who looks the address up." % ", ".join(hit),
                 "Ask the provider to set a neutral PTR record (or remove it).")
others = [r for r in res if r["port"] not in (22, 80, 443)]
if len(others) > 6:
    find("LOW", "many", "%d unusual ports are open" % len(others), "Every extra open port is another thing to fingerprint.",
         "Close the ports you do not need (firewall).")
if res and not has443:
    find("LOW", "no443", "Nothing answers on port 443", "A server that looks like a normal website serves HTTPS on 443; proxy-only hosts without it stand out.",
         "Serve a real site on 443 (Nginx) and route the proxy through it.")
if has443:
    r443 = [r for r in res if r["port"] == 443][0]
    if r443["http"] and r443["http"]["status"] in (200, 301, 302, 303, 307, 308, 401, 403, 404):
        find("OK", "web443", "Port 443 looks like an ordinary website", "It answers with a normal HTTP response (status %s)." % r443["http"]["status"])
r80 = [r for r in res if r["port"] == 80]
if r80 and r80[0]["http"]:
    find("OK", "web80", "Port 80 answers like a normal web server", "Status %s%s." % (r80[0]["http"]["status"], (", redirects to " + r80[0]["http"]["location"][:50]) if r80[0]["http"]["location"] else ""))
for d in (domains if AUDIT else []):
    parts = set(re.split(r"[^a-z0-9]+", d.lower()))
    hit = sorted(parts & NAME_MARK)
    if hit:
        find("LOW", "name-" + d, "The host name '%s' gives the purpose away" % d,
             "Words such as %s are used by block lists and by anyone reading certificate-transparency logs." % ", ".join(hit),
             "Use a neutral name (for example a normal-looking blog or shop name).")

# configuration audit (this server only)
if AUDIT and db and os.path.isfile(db):
    try:
        con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
        cur = con.cursor()
        settings = dict(cur.execute("select key, value from settings").fetchall())
        base = settings.get("webBasePath", "/")
        wport = settings.get("webPort", "")
        cert = settings.get("webCertFile", "")
        if base in ("", "/"):
            find("MED", "cfg-base", "The panel uses the default web path '/'", "The default path means the login page sits at the root of the panel port - the first URL a scanner tries.",
                 "Set a long random web base path in the panel settings.")
        if wport and not cert:
            find("LOW", "cfg-http", "The panel is served over plain HTTP", "Login traffic is readable by anyone on the path and looks different from normal HTTPS.",
                 "Use HTTPS (Nginx + Let's Encrypt) in front of the panel.")
        raw_n = []
        for port, proto, ss in cur.execute("select port, protocol, stream_settings from inbounds where enable=1"):
            try: st = json.loads(ss or "{}")
            except Exception: st = {}
            sec = st.get("security", "none")
            if proto in ("vmess", "vless", "trojan", "shadowsocks") and sec == "none":
                raw_n.append((port, proto, st.get("network", "tcp")))
            if sec == "reality":
                rs = st.get("realitySettings", {})
                if not rs.get("serverNames"):
                    find("MED", "cfg-real-%s" % port, "Reality inbound on port %s has no camouflage name" % port, "Without a believable serverName the camouflage fails.",
                         "Set serverNames / dest to a large real website.")
        for port, proto, net in raw_n:
            find("MED", "cfg-raw-%s" % port, "Inbound %s (%s/%s) has no TLS or Reality" % (port, proto, net),
                 "The stream is not wrapped in TLS, so its first bytes can be recognised.", "Switch the inbound's security to Reality or TLS (behind a real domain).")
        con.close()
    except Exception as e:
        emit("META", "db_error", str(e)[:80])

if merge_file and os.path.isfile(merge_file):
    for ln in open(merge_file, encoding="utf-8", errors="replace").read().splitlines():
        parts = ln.split("\t")
        if parts[0] in ("PORT", "META") and len(parts) >= 3:
            rows.append(ln)
        elif parts[0] == "FIND" and len(parts) >= 6:
            parts += [""] * (8 - len(parts))
            finds.append(tuple(parts[1:7]))

pen = {"HIGH": 25, "MED": 12, "LOW": 4}
cap = {"HIGH": 50, "MED": 36, "LOW": 12}
tot = {"HIGH": 0, "MED": 0, "LOW": 0}
for sev, *_ in finds:
    if sev in tot: tot[sev] = min(cap[sev], tot[sev] + pen[sev])
score = max(0, 100 - sum(tot.values()))
order = {"HIGH": 0, "MED": 1, "LOW": 2, "OK": 3}
for f in sorted(finds, key=lambda x: order.get(x[0], 9)):
    emit("FIND", *f)
emit("SCORE", score)
print("\n".join(rows))
PYSTEALTH
}

stealth_py() {   # stealth_py <host> <self|scan|audit|remote> [db] [ports] [domains] [merge-file]  -> tab separated findings (runs here)
    python3 -I - "$@" < <(stealth_src)
}

stealth_scan() {   # stealth_scan <host> <mode> [db] [ports-csv] [domains-csv] [merge-file]
    local out
    out=$(mktemp) || return 1
    register_cleanup "$out"
    spin_start "Looking at ${1} the way an outside scanner would (about 20-40 seconds)..."
    stealth_py "$@" >"$out" 2>/dev/null
    spin_stop
    [[ -s $out ]] || { ui_err "The probe produced no result."; return 1; }
    STEALTH_OUT=$out
}

stealth_scan_via_ssh() {   # stealth_scan_via_ssh <target-ip> <ports-csv> <domains-csv>  - the REMOTE server probes the target
    local out rc=0 rq
    out=$(mktemp) || return 1
    register_cleanup "$out"
    printf -v rq '%q scan %q %q %q' "$1" "" "$2" "$3"
    if ! SSHPASS=$SRV_PASS "${SSH_PRE[@]}" ssh -T "${SSH_OPTS[@]}" "$SSH_DEST" 'command -v python3 >/dev/null 2>&1' 2>/dev/null; then
        ui_err "python3 is not installed on the remote server (apt-get install -y python3). It is needed to run the probe there."; return 1
    fi
    spin_start "The remote server is probing this server from the outside (about 20-40 seconds)..."
    SSHPASS=$SRV_PASS "${SSH_PRE[@]}" ssh -T "${SSH_OPTS[@]}" "$SSH_DEST" "python3 -I - ${rq}" < <(stealth_src) >"$out" 2>/dev/null || rc=$?
    spin_stop
    grep -q '^SCORE' "$out" 2>/dev/null || [[ -s $out ]] || { ui_err "The remote probe returned nothing (exit ${rc})."; return 1; }
    STEALTH_OUT=$out
}

do_stealth() {
    local where sel=1 ip='' db='' ports='' dom_csv='' dtmp label observer scanf
    ui_section "VPN STEALTH CHECK"
    wrapped 3 "$C_NOTE" "Finds out how easily an observer outside can recognise this server as a VPN / proxy, and explains every finding in plain words. Nothing is changed."
    ui_card "WHERE SHOULD THE TEST START FROM?"
    wrapped 3 "$C_NOTE" "A test is only meaningful from OUTSIDE. The best way is therefore to start it on ANOTHER server (one you can log in to over SSH) and aim it at THIS server: the other server plays the observer, this server is the target."
    menu_select_b "Where should the test start from?" "$sel" \
        "A remote server I log in to   ->  tests THIS server from outside  (recommended)" \
        "This server itself   ->  quick look at its own ports and panel settings (less realistic)" \
        "An address I type in   ->  tests THAT server from here" || return 0
    where=$MENU_RESULT
    require_tools python3 curl || return 0
    if (( where != 3 )); then
        pub_ip_quick; ip=${PUB_QUICK:-${PUB_IP:-}}
        if [[ -z $ip ]]; then
            prompt_input "Public IPv4 of this server (it could not be detected): " 0 || return 0
            ip=$INPUT_VALUE; is_ipv4 "$ip" || { ui_err "Invalid IPv4."; return 0; }
        fi
        [[ -f /etc/x-ui/x-ui.db ]] && db=/etc/x-ui/x-ui.db
        ports=$(ss -H -ltn 2>/dev/null | awk '{a = $4; n = split(a, x, ":"); if (a ~ /^(127\.|\[::1\])/) next; print x[n]}' | sort -un | paste -sd, -)
        if [[ -n $db ]]; then
            dtmp=$(mktemp) && register_cleanup "$dtmp" && collect_domains "$dtmp" "$db" /etc/nginx /etc/letsencrypt/live
            dom_csv=$(cut -f1 "$dtmp" 2>/dev/null | sort -u | paste -sd, -)
        fi
    fi
    case $where in
        1)
            require_tools ssh || return 0
            ui_info "Choose the server that will act as the observer."
            pick_server || return 0
            srv_ssh_setup || return 0
            ssh_open || { SRV_PASS=''; return 0; }
            if [[ $SRV_IP == "$ip" ]]; then ui_err "The observer and the target are the same address - choose a different server."; ssh_close; SRV_PASS=''; return 0; fi
            stealth_scan_via_ssh "$ip" "$ports" "$dom_csv" || { ssh_close; SRV_PASS=''; return 0; }
            scanf=$STEALTH_OUT
            stealth_scan "$ip" audit "$db" "$ports" "$dom_csv" "$scanf" || { ssh_close; SRV_PASS=''; return 0; }
            observer="${SRV_NAME:-$SRV_ADDR}$([[ ${SRV_NAME:-$SRV_ADDR} != "$SRV_IP" ]] && printf ' (%s)' "$SRV_IP") - a remote server, outside this server"
            label="THIS server (${ip})"
            ssh_close; srv_remember online "" ""; SRV_PASS=''
            typed_begin; stealth_render "$STEALTH_OUT" "$label" "$observer" "$([[ -n $db ]] && echo 1 || echo 0)"; typed_end ;;
        2)
            stealth_scan "$ip" self "$db" "$ports" "$dom_csv" || return 0
            observer="THIS server itself  (it looks at its own public address - a router/NAT may hide real-world filtering)"
            label="this server (${ip})"
            typed_begin; stealth_render "$STEALTH_OUT" "$label" "$observer" "$([[ -n $db ]] && echo 1 || echo 0)"; typed_end ;;
        3)
            pick_server || return 0
            ip=$SRV_IP; label="${SRV_NAME:-$SRV_ADDR} (${ip})"
            stealth_scan "$ip" remote "" "$SRV_PORT" "" || return 0
            observer="THIS server (${PUB_QUICK:-${PUB_IP:-local address}}) looking at another server from outside"
            typed_begin; stealth_render "$STEALTH_OUT" "$label" "$observer" 0; typed_end
            srv_remember online "" "" ;;
    esac
}

# ── Full system update (apt-get update / upgrade / dist-upgrade / autoremove / autoclean) ──────
SU_DIR='' SU_PM=''
su_clean() { tr -d '\r' | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' | tr -cd '[:print:]\n'; }

su_run() {   # su_run <n> <total> <label> <cmd...>  - runs in the background with a live "what is it doing now" line; logs to ${SU_DIR}/<n>.log
    local n=$1 total=$2 label=$3 log pid rc=0 start=$SECONDS last='' i=0 w
    local -a fr=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    shift 3
    log="${SU_DIR}/${n}.log"
    ui_step "$n" "$total" "$label"
    ( export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1 LC_ALL=C; "$@" ) >"$log" 2>&1 </dev/null &
    pid=$!
    w=$(( UI_COLS - 22 )); (( w < 20 )) && w=20
    if [[ -t 1 ]]; then
        while kill -0 "$pid" 2>/dev/null; do
            last=$(tail -n 1 "$log" 2>/dev/null | su_clean | tail -n 1)
            printf '\r\033[K %s%s%s  %s%ds%s  %s%s%s' "$C_BLUE" "${fr[i++ % 10]}" "$C_RESET" "$C_DIM" $(( SECONDS - start )) "$C_RESET" "$C_DIM" "${last:0:w}" "$C_RESET"
            sleep 0.2
        done
        printf '\r\033[K'
    fi
    wait "$pid" || rc=$?
    if (( rc == 0 )); then ui_ok "${label}  ($(( SECONDS - start ))s)"
    else ui_warn "${label} finished with errors (code ${rc}); details are in the log."; tail -n 6 "$log" | su_clean | sed 's/^/      /' >&2; fi
    return 0
}

su_num() {   # su_num <file> <regex-with-one-group>  -> sum of all matches
    grep -ohE "$2" "$1" 2>/dev/null | grep -oE '[0-9]+' | awk '{s += $1} END {print s + 0}'
}

do_sysupdate() {
    local up1 up2 new1 new2 rem held sec nplan nrem errs kern_run kern_new free0 free1 now log_all total=5 i
    local -a names=()
    ui_section "$(t sysupd_title)"
    if command -v apt-get >/dev/null 2>&1; then SU_PM=apt
    elif command -v dnf >/dev/null 2>&1; then SU_PM=dnf
    elif command -v yum >/dev/null 2>&1; then SU_PM=yum
    else ui_err "No supported package manager found (apt-get / dnf / yum)."; return 0; fi
    ui_kv "PACKAGE MANAGER" "$SU_PM"
    ui_kv "WHAT RUNS" "$([[ $SU_PM == apt ]] && echo 'apt-get update -> upgrade -> dist-upgrade -> autoremove -> autoclean' || echo "${SU_PM} makecache -> upgrade -> autoremove -> clean all")"
    ui_kv "SAFETY" "non-interactive; your edited config files are kept; services are NOT restarted automatically"
    if command -v fuser >/dev/null 2>&1 && [[ $SU_PM == apt ]] && fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
        ui_err "Another package manager is running right now (for example automatic updates). Try again in a few minutes."; return 0
    fi
    free0=$(df -BM --output=avail / 2>/dev/null | awk 'NR==2 {gsub(/M/, ""); print $1}'); : "${free0:=0}"
    if (( free0 < 1024 )); then ui_err "Only ${free0} MB free on / - at least 1 GB is needed for a safe update."; return 0; fi
    SU_DIR=$(mktemp -d) || { ui_err "Cannot create a work folder."; return 0; }
    register_cleanup "$SU_DIR"

    if [[ $SU_PM == apt ]]; then
        local -a AO=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o Dpkg::Use-Pty=0 -o DPkg::Lock::Timeout=120)
        su_run 1 $total "Refreshing the package lists" apt-get update "${AO[@]}"
        # what would change? (simulation only - nothing is installed yet)
        apt-get -s -o Dpkg::Use-Pty=0 dist-upgrade >"${SU_DIR}/sim.log" 2>&1 </dev/null || true
        nplan=$(grep -cE '^Inst ' "${SU_DIR}/sim.log" 2>/dev/null || true); : "${nplan:=0}"
        sec=$(grep -E '^Inst ' "${SU_DIR}/sim.log" 2>/dev/null | grep -ci 'security' || true); : "${sec:=0}"
        mapfile -t names < <(grep -E '^Inst ' "${SU_DIR}/sim.log" 2>/dev/null | awk '{print $2}' | head -n 12)
        printf '\n'
        ui_card "WHAT THE UPDATE WILL DO"
        ui_kv "PACKAGES" "${nplan} to install / upgrade   (${sec} of them security updates)"
        nrem=$(grep -cE '^Remv ' "${SU_DIR}/sim.log" 2>/dev/null || true); ui_kv "TO REMOVE" "${nrem:-0} package(s)"
        ui_kv "DOWNLOAD" "$(grep -oE 'Need to get [0-9.,]+ ?[kMG]?B' "${SU_DIR}/sim.log" 2>/dev/null | head -n 1 | sed 's/Need to get //' || true)"
        if (( ${#names[@]} )); then
            ui_kv "INCLUDES" "$(printf '%s, ' "${names[@]}" | sed 's/, $//')$( (( nplan > ${#names[@]} )) && printf '  (+%d more)' $(( nplan - ${#names[@]} )) )"
        fi
        if (( nplan == 0 )) && ! grep -qE '^Remv ' "${SU_DIR}/sim.log" 2>/dev/null; then
            ui_ok "Everything is already up to date - there is nothing to install."
        fi
    else
        su_run 1 $total "Refreshing the package metadata" "$SU_PM" -y makecache
        nplan=$( "$SU_PM" -q check-update 2>/dev/null </dev/null | grep -cE '^[A-Za-z0-9_.+-]+\.[A-Za-z0-9_]+ +[0-9]' || true ); : "${nplan:=0}"
        printf '\n'; ui_card "WHAT THE UPDATE WILL DO"; ui_kv "PACKAGES" "${nplan} to upgrade"
    fi
    notice_box "$(t sysupd_note_title)" "$(t sysupd_note1)" "$(t sysupd_note2)"
    confirm "$(t sysupd_ask)" y || { ui_info "Cancelled - nothing was installed."; return 0; }

    now=$SECONDS
    if [[ $SU_PM == apt ]]; then
        su_run 2 $total "Upgrading installed packages (apt-get upgrade)" apt-get upgrade "${AO[@]}"
        su_run 3 $total "Smart upgrade incl. new dependencies (apt-get dist-upgrade)" apt-get dist-upgrade "${AO[@]}"
        su_run 4 $total "Removing packages nobody needs (apt-get autoremove)" apt-get autoremove "${AO[@]}"
        su_run 5 $total "Clearing the package cache (apt-get autoclean)" apt-get autoclean "${AO[@]}"
        up1=$(su_num "${SU_DIR}/2.log" '[0-9]+ upgraded'); up2=$(su_num "${SU_DIR}/3.log" '[0-9]+ upgraded')
        new1=$(su_num "${SU_DIR}/2.log" '[0-9]+ newly installed'); new2=$(su_num "${SU_DIR}/3.log" '[0-9]+ newly installed')
        rem=$(( $(su_num "${SU_DIR}/2.log" '[0-9]+ to remove') + $(su_num "${SU_DIR}/3.log" '[0-9]+ to remove') + $(su_num "${SU_DIR}/4.log" '[0-9]+ to remove') ))
        held=$(grep -ohE '[0-9]+ not upgraded' "${SU_DIR}/3.log" 2>/dev/null | tail -n 1 | grep -oE '^[0-9]+' || true); : "${held:=0}"
    else
        su_run 2 $total "Upgrading installed packages" "$SU_PM" -y upgrade
        su_run 3 $total "Checking for leftovers" "$SU_PM" -y check
        su_run 4 $total "Removing packages nobody needs" "$SU_PM" -y autoremove
        su_run 5 $total "Clearing the package cache" "$SU_PM" -y clean all
        up1=$(grep -cE '^ *(Upgrading|Upgraded)' "${SU_DIR}/2.log" 2>/dev/null || true); up2=0; new1=0; new2=0; rem=0; held=0
    fi
    errs=$(cat "${SU_DIR}"/[2-5].log 2>/dev/null | grep -cE '^E: |dpkg: error|^Error|Failed' || true); : "${errs:=0}"
    free1=$(df -BM --output=avail / 2>/dev/null | awk 'NR==2 {gsub(/M/, ""); print $1}'); : "${free1:=0}"
    kern_run=$(uname -r)
    kern_new=$(ls /boot/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -V | tail -n 1)

    log_all="/var/log/moc-system-update-$(date +%Y%m%d-%H%M%S).log"
    for i in 1 2 3 4 5; do [[ -f ${SU_DIR}/${i}.log ]] && { printf '\n===== step %s =====\n' "$i"; su_clean <"${SU_DIR}/${i}.log"; }; done >"$log_all" 2>/dev/null && chmod 600 "$log_all" 2>/dev/null

    printf '\n'
    ui_card "RESULT"
    ui_kv "UPGRADED" "$(( up1 + up2 )) package(s)" "$C_GREEN"
    ui_kv "NEWLY INSTALLED" "$(( new1 + new2 )) (new dependencies)" "$C_WHITE"
    ui_kv "REMOVED" "${rem} unneeded package(s)" "$C_WHITE"
    ui_kv "HELD BACK" "${held} package(s)$( (( held > 0 )) && printf '  - need a manual decision' )" "$( (( held > 0 )) && echo "$C_YELLOW" || echo "$C_DIM")"
    ui_kv "DISK FREE" "${free0} MB -> ${free1} MB   ($(( free1 - free0 >= 0 ? free1 - free0 : free0 - free1 )) MB $( (( free1 >= free0 )) && echo freed || echo 'used by new packages' ))"
    ui_kv "TIME" "$(( SECONDS - now )) s"
    [[ -f $log_all ]] && ui_kv "FULL LOG" "$log_all" "$C_DIM"
    printf '\n'
    if (( errs > 0 )); then
        alert_box "UPDATE FINISHED WITH PROBLEMS" "${errs} error line(s) were found. Read ${log_all:-the log}, then run this update again."
    elif (( held > 0 )); then
        notice_box "UPDATE DONE - ${held} PACKAGE(S) HELD BACK" "They need a new dependency decision; run 'apt-get dist-upgrade' by hand to see why."
    else ui_ok "The system is fully up to date."; fi
    if [[ -f /var/run/reboot-required || ( -n $kern_new && $kern_new != "$kern_run" ) ]]; then
        notice_box "A REBOOT IS RECOMMENDED" "Running kernel: ${kern_run}   Newest installed: ${kern_new:-same}" \
            "Until you reboot, the new kernel / libraries are not active. Your panel and proxy come back by themselves after the reboot."
        if (( REMOTE_MODE )); then ui_warn "You are on a REMOTE session: a reboot closes it and you return to your original server."; fi
        if confirm "$(t sysupd_reboot)" n; then
            ui_info "Rebooting in 5 seconds..."; sleep 5; systemctl reboot || reboot
        fi
    fi
}

# ── Entry point ───────────────────────────────────────────────────────────────
usage() {
    cat <<EOF2
XUI-SPM - X-UI Smart Panel Manager v${SCRIPT_VERSION}
Supports NX Panel, 3x-ui, Alireza x-ui and classic x-ui.

Usage: sudo bash $(basename "$0") [--no-color] [--no-anim] [--fancy | --safe-icons] [--verify] [--check-update] [--self-update] [--help] [--version]

Run "Smart backup" on the OLD server and "Migrate / restore" on the NEW server (DNS + health verification and a final report run automatically).
  --verify        re-run only the DNS / health verification later
  --check-update  look for a newer version of this script
  --self-update   update this script from its GitHub address
  --no-anim       turn off the logo / menu animation and the typing effect
  --fancy         use emoji icons (default: plain characters that every console font has);  --safe-icons switches back
  --probe         print this server's hardware / network inspection as KEY=VALUE lines (used by the remote server check)
Environment: NO_COLOR=1 disables colors, MOC_NO_ANIM=1 disables animation, MOC_UPDATE_URL sets the update address.
EOF2
}

# Runs a workflow in a subshell: a die/exit inside it returns to the menu instead of leaving the program.
run_workflow() {
    ( trap cleanup EXIT; trap 'printf "\n"; exit 130' INT TERM; "$@"; pb_stop )
    pb_reset
    return 0
}

main_menu_loop() {
    local sel=1 first=1 found pl exit_lbl src_label l1
    local -a fl=()
    (( REMOTE_MODE )) && sel=2
    while true; do
        show_header
        mapfile -t fl < <(installed_panels)
        if (( ${#fl[@]} )); then pl=$(printf '%s, ' "${fl[@]}"); pl=${pl%, }; else pl=""; fi
        if (( REMOTE_MODE )); then
            src_label=${XUI_SOURCE_HOST:-unknown}
            printf -v exit_lbl "$(t opt_exit_remote)" "${src_label:0:30}"
        else exit_lbl=$(t opt_exit); fi
        if [[ -n $pl ]]; then printf -v found "$(t opt_panels)" $'\x01'"$pl"$'\x02'; else found=$(t opt_panels_none); fi
        MENU_HAS_BACK=$REMOTE_MODE menu_select "$(t main_title)" "$sel" "$(t opt_backup)" "$(t opt_restore)" "$(t opt_inspect)" "$found" \
            "$(t opt_optimize)" "$(t opt_selfupdate)" "$exit_lbl" || return 0
        sel=$MENU_RESULT
        first=0
        case $MENU_RESULT in
            1) confirm_where "$(t w_backup)" && { run_workflow do_backup; pause_key; } ;;
            2) confirm_where "$(t w_restore)" y && run_workflow do_restore ;;
            3) run_workflow do_inspect ;;
            4) do_panels ;;
            5) confirm_where "$(t w_optimize)" && run_workflow do_optimize ;;
            6) do_self_update 0; pause_key ;;
            7)
                if (( REMOTE_MODE )); then
                    printf -v l1 "$(t rl_body)" "${XUI_SOURCE_HOST:-unknown}"
                    notice_box "$(t rl_title)" "$l1"
                    confirm "$(t rl_ask)" y && return 0
                else
                    return 0
                fi ;;
        esac
    done
}

farewell() {   # clear the screen and say goodbye
    local l1 l2 pad
    [[ -t 1 ]] && printf '\033[H\033[2J\033[3J'
    if (( REMOTE_MODE )); then
        printf -v l1 "$(t bye_remote)" "${XUI_SOURCE_HOST:-the original server}"; l2=$(t bye_line)
    else l1=$(t bye_title); l2=$(t bye_line); fi
    printf '\n\n'
    printf ' %s%s%s\n' "${C_BOLD}${C_BLUE}" "$HDR_TITLE" "$C_RESET"
    printf '\n %s%s%s%s\n' "${C_BOLD}${C_GREEN}" "$I_OK" "  $l1" "$C_RESET"
    printf '   %s%s%s\n' "$C_WHITE" "$l2" "$C_RESET"
    pad=$(printf '%*s' $(( UI_COLS > 70 ? 66 : UI_COLS - 4 )) '')
    printf '\n %s%s%s\n\n' "$C_DIM" "${pad// /─}" "$C_RESET"
    printf ' %s%s  |  v%s%s\n\n' "$C_DIM" "$SIGNATURE" "$SCRIPT_VERSION" "$C_RESET"
}

save_icon_pref() {   # remember the chosen display style for the next start
    install -d -m 755 /etc/moc-networks 2>/dev/null && printf '%s\n' "$1" >/etc/moc-networks/icons.pref 2>/dev/null
    return 0
}

main() {
    local arg only_verify=0 only_update=0 check_update=0
    for arg in "$@"; do
        case $arg in
            -h|--help)      usage; exit 0 ;;
            -v|--version)   echo "$SCRIPT_VERSION"; exit 0 ;;
            --no-color)     NO_COLOR=1 ;;
            --no-anim)      MOC_NO_ANIM=1 ;;
            --probe)        probe_main; exit 0 ;;
            --fancy|--fancy-icons) save_icon_pref fancy ;;
            --safe-icons)   save_icon_pref safe ;;
            --verify)       only_verify=1 ;;
            --self-update)  only_update=1 ;;
            --check-update) only_update=1; check_update=1 ;;
            *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
        esac
    done
    [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Please run as root (sudo bash $(basename "$0"))." >&2; exit 1; }

    init_ui

    if (( only_verify )); then
        show_header
        do_verify
        exit 0
    fi
    if (( only_update )); then
        show_header
        do_self_update "$check_update"
        exit 0
    fi

    if [[ ${XUI_EXECUTION_MODE:-LOCAL} == REMOTE ]]; then
        REMOTE_MODE=1
        [[ ${XUI_UI_LANG:-EN} == FA ]] && UI_LANG="FA"
        set_lrm
        [[ ${XUI_AUTOSTART:-} == restore ]] && run_workflow do_restore
        main_menu_loop
        farewell
        return 0
    fi

    LRM=$'\xe2\x80\x8e'                 # the language menu mixes Latin and Persian: force left-to-right layout
    show_header
    menu_select "$(t lang_title)" 1 "English" "Farsi" "$(t exit)" || exit 1
    case $MENU_RESULT in
        2) UI_LANG="FA" ;;
        3) set_lrm; farewell; exit 0 ;;
    esac
    set_lrm
    ask_server_saving
    main_menu_loop
    farewell
}

if [[ ${BASH_SOURCE[0]:-$0} == "$0" ]]; then
    main "$@"
fi
