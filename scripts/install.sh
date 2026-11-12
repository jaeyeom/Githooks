#!/usr/bin/env bash
set -euo pipefail

function die() {
    echo -e "! ERROR:" "$@" >&2
    exit 1
}

function check_tool() {
    if ! command -v "$1" &>/dev/null; then
        echo "!! Required tool '$1' is not installed."
        exit 1
    fi
}

function check_bash() {
    if ! declare -n _DUMMY &>/dev/null; then
        die "You need bash at least 4.3 to run this script."
    fi
}

function get_platform_os() {
    local -n _platform_os="$1"

    if [[ $OSTYPE == "linux"* ]]; then
        _platform_os="linux"
    elif [[ $OSTYPE == "darwin"* ]]; then
        _platform_os="darwin"
    elif [[ $OSTYPE == "freebsd"* ]]; then
        _platform_os="freebsd"
    else
        # Resort to `uname` for windows stuff.
        local name
        name=$(uname -a)
        case "$name" in
        CYGWIN*) _platform_os="windows" ;;
        MINGW*) _platform_os="windows" ;;
        *Msys) _platform_os="windows" ;;
        *) die "Platform: '$name' not supported." ;;
        esac
    fi

    return 0
}

function get_platform_arch() {
    local -n _arch="$1"

    _arch=""
    if uname -m | grep -q "x86_64" &>/dev/null; then
        _arch="amd64"
        return 0
    elif uname -m | grep -q -E "aarch64|arm64" &>/dev/null; then
        _arch="arm64"
        return 0
    elif uname -a | grep -q -E "aarch64|arm64" &>/dev/null; then
        _arch="arm64"
    else
        die "Architecture: '$(uname -m)' not supported."
    fi
}

check_bash
check_tool "git"
check_tool "go"
check_tool "uname"

org=jaeyeom
repo=githooks

unInstall="false"
installerArgs=()
versionTag=""

# Compare a and b as version strings. Rules:
# $1-a $2-op $3-b
# R1: a and b : dot-separated sequence of items. Items are numeric. The last item can optionally end with letters, i.e., 2.5 or 2.5a.
# R2: Zeros are automatically inserted to compare the same number of items, i.e., 1.0 < 1.0.1 means 1.0.0 < 1.0.1 => yes.
# R3: op can be '=' '==' '!=' '<' '<=' '>' '>=' (lexicographic).
# R4: Unrestricted number of digits of any item, i.e., 3.0003 > 3.0000004.
# R5: Unrestricted number of items.
function version_compare() {
    local a=$1 op=$2 b=$3 al=${1##*.} bl=${3##*.}
    while [[ $al =~ ^[[:digit:]] ]]; do al=${al:1}; done
    while [[ $bl =~ ^[[:digit:]] ]]; do bl=${bl:1}; done
    local ai=${a%"$al"} bi=${b%"$bl"}

    local ap=${ai//[[:digit:]]/} bp=${bi//[[:digit:]]/}
    ap=${ap//./.0} bp=${bp//./.0}

    local w=1 fmt=$a.$b x IFS=.
    for x in $fmt; do [ ${#x} -gt "$w" ] && w=${#x}; done
    fmt=${*//[^.]/}
    fmt=${fmt//./%${w}s}
    # shellcheck disable=SC2086,SC2059
    printf -v a "$fmt" $ai$bp
    printf -v a "%s-%${w}s" "$a" "$al"
    # shellcheck disable=SC2086,SC2059
    printf -v b "$fmt" $bi$ap
    printf -v b "%s-%${w}s" "$b" "$bl"

    # shellcheck disable=SC1072
    case $op in
    '<=' | '>=') test "$a" "${op:0:1}" "$b" || [ "$a" = "$b" ] ;;
    *) test "$a" "$op" "$b" ;;
    esac
}

function print_help() {
    echo -e "Usage: install.sh [options...] [-- <installer-args>...]\n\n" \
        "Options:\n" \
        "  --version <version> : Git tag or branch to clone and build.\n" \
        "                        Default: the repository's default branch.\n" \
        "  --uninstall         : Uninstall Githooks. Builds the uninstaller from the same checkout.\n" \
        "all other arguments are forwarded to the installer."
}

function parse_args() {
    local to_installer=false
    local prev=""

    for p in "$@"; do
        if [ "$to_installer" = "true" ]; then
            installerArgs+=("$p")
        elif [ "$p" = "--help" ] || [ "$p" = "-h" ]; then
            print_help
            exit 0
        elif [ "$p" = "--version" ]; then
            true
        elif [ "$p" = "--uninstall" ]; then
            unInstall="true"
        elif [ "$prev" = "--version" ]; then
            if [ "${p#-}" != "$p" ]; then
                echo "! '--version' requires a version argument, got '$p'." >&2
                return 1
            fi
            versionTag="v$p"

        elif [ "$p" = "--" ]; then
            to_installer="true"
        else
            echo "! Unknown argument '$p'." >&2
            echo "  Use '--' to separate install.sh options from installer arguments:" >&2
            echo "    curl -sL <url>/install.sh | bash -s -- -- \"$p\"" >&2
            return 1
        fi

        prev="$p"
    done

    if [ "$prev" = "--version" ] && [ "$versionTag" = "" ]; then
        echo "! '--version' requires a version argument." >&2
        return 1
    fi
}

function check_old_version_v2() {
    if ! version_compare "${versionTag##v}" ">=" "2.3.4"; then
        echo "!! Can only bootstrap version tags >= 'v2.3.4' with this script. Got tag '$versionTag'."
        exit 1
    fi

    local versionTag="$1"
    local installedVersion
    installedVersion=$(git hooks --version 2>/dev/null | sed -E 's/.* ([0-9]+\..*)/\1/') || true

    if [ -n "$installedVersion" ] &&
        version_compare "$installedVersion" "<=" "3.0.0" &&
        version_compare "${versionTag##v}" ">=" "3.0.0"; then
        echo "!! You use an old Githooks version < 3 and want to install a version > 3.0.0." >&2
        echo "!! Please uninstall the version before reinstalling the major new one." >&2
        exit 1
    fi

    if [ -n "$(git config githooks.usecorehookspath)" ] &&
        version_compare "${versionTag##v}" ">=" "3.0.0"; then
        echo "!! You seem to use an old Githooks version < 3 and want to install a version > 3.0.0." >&2
        echo "!! Please uninstall the version before reinstalling the major new one." >&2
        exit 1
    fi
}

tempDir="$(mktemp -d)"
function clean_up() {
    rm -rf "$tempDir" &>/dev/null || true
}
trap clean_up EXIT

parse_args "$@"

# No GitHub release is required. The v2→v3 guard still needs a version
# when --version was not given; the checkout itself stays on the default branch.
checkoutRef="$versionTag"
if [ -z "$versionTag" ]; then
    versionTag="v3.0.6"
fi

check_old_version_v2 "$versionTag"

os=""
get_platform_os os

cloneURL="https://github.com/${org}/${repo}.git"
srcDir="$tempDir/src"
echo "Cloning '$cloneURL'..."
if [ -n "$checkoutRef" ]; then
    git clone --template= -c core.hooksPath=.git/hooks --branch "$checkoutRef" "$cloneURL" "$srcDir"
else
    git clone --template= -c core.hooksPath=.git/hooks "$cloneURL" "$srcDir"
fi

commit="$(git -C "$srcDir" rev-parse HEAD)"
if [ -n "$checkoutRef" ]; then
    export GH_BUILD_VERSION="${checkoutRef#v}"
else
    export GH_BUILD_VERSION="3.0.6"
fi
# The installer resets its clone to this ref. Use the commit, because this
# fork does not publish version tags.
export GH_BUILD_TAG="$commit"

cliExe="githooks-cli"
if [ "$os" = "windows" ]; then
    cliExe="${cliExe}.exe"
fi

binDir="$tempDir/githooks"
mkdir -p "$binDir"

echo "Building '$cliExe' at '$commit'..."
(
    cd "$srcDir/githooks"
    go mod vendor
    go generate -mod=vendor ./...
    CGO_ENABLED=0 go build -mod=vendor -o "$binDir/$cliExe" ./apps/cli
)

if [ "$unInstall" = "true" ]; then
    "$binDir/$cliExe" uninstaller "${installerArgs[@]}"
else
    "$binDir/$cliExe" installer \
        --build-from-source \
        --clone-url "$cloneURL" \
        "${installerArgs[@]}"
fi
