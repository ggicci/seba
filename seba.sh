#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

if [[ "${IMAGE_NAME:-notset}" == "notset" ]]; then echo "Missing IMAGE_NAME" 1>&2; exit 1; fi

COLOR_BLACK='0'
COLOR_RED='1'
COLOR_GREEN='2'
COLOR_YELLOW='3'
COLOR_BLUE='4'
COLOR_MAGENTA='5'
COLOR_CYAN='6'
COLOR_WHITE='7'

COLOR_CODE='\033['
COLOR_NC='0'
COLOR_FG='3'
COLOR_BG='4'
COLOR_FG_HI='9'
COLOR_BG_HI='10'
COLOR_BOLD='1'
COLOR_UNDERLINE='4'
COLOR_BLINK='5'

util::is_gnu_command() { [[ -n "$("$1" --version 2>/dev/null | grep "GNU")" ]]; }

GNU_GREP="grep"
if ! util::is_gnu_command "grep"; then
    GNU_GREP="ggrep"
fi

util::printf_style() {
    printf "${COLOR_CODE}$1m"
    shift 1
    printf "${@}"
    printf "${COLOR_CODE}${COLOR_NC}m"
}
util::printf_yellow() { util::printf_style "${COLOR_FG}${COLOR_YELLOW}" "$@"; }
util::printf_red()    { util::printf_style "${COLOR_FG}${COLOR_RED}" "$@"; }
util::printf_green()  { util::printf_style "${COLOR_FG}${COLOR_GREEN}" "$@"; }

git::ensure_git() {
    if ! git rev-parse --git-dir &>/dev/null; then
        >&2 util::printf_red "ERROR: not a git repository\n"
        exit 1
    fi
}
git::get_commit() { git rev-parse --short HEAD; }
git::get_dirty() { test -n "`git status --porcelain`" && echo "+CHANGES" || true; }
git::get_description() { git describe --tags --always; }
docker::get_label() { echo "$(docker image inspect -f "{{ .Config.Labels.$1 }}" ${IMAGE_NAME}:latest 2>/dev/null)"; }
docker::image_exists() { [[ "$(docker images -q "$1" 2>/dev/null)" != "" ]]; }

env::setup() {
    git::ensure_git
    COMMIT="$(git::get_commit)$(git::get_dirty)"
    VERSION="$(git::get_description)"
    SHIP_VERSION="$(docker::get_label "version")"
    IMAGE_TAR=""
    IMAGE_TAR_GZ=""

    if [[ "${SHIP_VERSION}" != "" ]]; then
        IMAGE_TAR="${IMAGE_NAME//\//_}.${SHIP_VERSION}.tar"
    fi
    if [[ "${SHIP_VERSION}" != "" ]]; then
        IMAGE_TAR_GZ="${IMAGE_TAR}.gz"
    fi
}

# Show repository status
command::status() {
    env::setup

    util::printf_yellow "\nCommit: "
    printf "${COMMIT}"
    util::printf_yellow "  Version: "
    printf "${VERSION}"
    util::printf_yellow "  Ship: "
    printf "${SHIP_VERSION:-none}\n\n"
}

# Build docker image
command::build() {
    command::status

    if docker::image_exists "${IMAGE_NAME}:${VERSION}"; then
        >&2 util::printf_red "ERROR: image ${IMAGE_NAME}:${VERSION} already exists, skip\n"
        echo
        docker images "${IMAGE_NAME}"
        echo
        exit 1
    fi

    # TODO: support a given Dockerfile

    docker build \
        --tag "${IMAGE_NAME}:${VERSION}" \
        --tag "${IMAGE_NAME}:latest" \
        --build-arg COMMIT=${COMMIT} \
        --build-arg VERSION=${VERSION} \
        .

    util::printf_green "build successfully!\n"
}

# Save docker image to local filesystem and archive it to a .tar.gz file
command::save() {
    command::status

    if [[ "${SHIP_VERSION}" == "" ]]; then
        >&2 util::printf_red "ERROR: no version to save or ship, run build command first\n"
        exit 1
    fi

    if [[ -e "${IMAGE_TAR_GZ}" ]]; then
        util::printf_yellow "WARNING: image archive file \"${IMAGE_TAR_GZ}\" already exists\n"
        return
    fi

    docker save "${IMAGE_NAME}:${SHIP_VERSION}" > "${IMAGE_TAR}"
    tar zcf "${IMAGE_TAR_GZ}" "${IMAGE_TAR}"
    rm "${IMAGE_TAR}"
    util::printf_green "image saved successfully!"
    printf " [ ${IMAGE_TAR_GZ} ]\n"
}

# Save docker image and ship the archived file to remote servers
#
# Usage:
#   seba ship -t/--to <dest1 [dest2 [dest3 [...]]]> [-e/--extra <file1 [file2 [file3 [...]]]>]
#
# dest:
#   <user>@<host>[(<port>)]:[<path>]
#   adm_a@aaa.com:
#   adm_b@bbb.com:/home/adm_b/
#   adm_c@ccc.com(22221):/home/adm_c/somewhere.tar.gz
#   adm_d@ddd.com(222):
command::ship() {
    local extra=()
    local dests=()
    local current_opt=""

    while :; do
        case ${1:-notset} in
            -e|--extra)
                current_opt="extra"
                ;;
            -t|--to)
                current_opt="to"
                ;;
            notset)
                break
                ;;
            *)
                case ${current_opt} in
                    extra)
                        extra+=("$1")
                        ;;
                    to)
                        dests+=("$1")
                        ;;
                esac
                ;;
        esac
        shift
    done

    if [[ ${#dests[@]} -eq 0 ]]; then
        >&2 util::printf_red 'ERROR: "-t/--to" required\n'
        exit 1
    fi

    # Archive image to local file
    command::save

    for dest in "${dests[@]}"; do
        echo "${IMAGE_TAR_GZ} --> ${dest}"
        local host="${dest%%:*}"
        local path="${dest##*:}"

        local scp_opts=""
        if [[ "${host}" = *"("*")" ]]; then
            # with port
            local port="${host##*\(}"
            port="${port%%\)*}"
            host="${host%%\(*}"
            if [[ "${port}" != "" ]]; then
                scp_opts="${scp_opts} -P ${port}"
            fi
        fi
        # NB: do not quote ${scp_opts}, otherwise it will be treated as a file
        scp ${scp_opts} "${IMAGE_TAR_GZ}" "${extra[@]}" "${host}:${path}"
    done

    util::printf_green "ship successfully!\n"
}

# Load archived docker image file to docker images
command::install() {
    local repogz=$(ls -t ${IMAGE_NAME//\//_}.*.tar.gz 2>/dev/null | head -n 1)
    if [[ "${repogz}" == "" ]]; then
        echo "no image to deploy, run ship command first"
        exit 1
    fi

    local ext="${repogz##*.}"
    local repotar="${repogz%.*}"

    if [[ ! -e "${repotar}" ]]; then
        echo "extract: ${repogz}"
        tar zxf "${repogz}"
    fi

    local image="$(tar xfO "${repotar}" manifest.json | ${GNU_GREP} -Po '"RepoTags":\[.*?\]' | cut -d'"' -f 4)"
    printf "load image: "
    util::printf_yellow "${image}\n"

    if docker::image_exists "${image}"; then
        echo "WARNING: image ${image} already loaded, skip"
    else
        echo "start loading image from ${repotar}"
        docker load < "${repotar}"
    fi

    local image_latest="${image%:*}:latest"
    echo "tag latest"
    docker tag "${image}" "${image_latest}"
    echo; docker images ${IMAGE_NAME}
    util::printf_green "\ninstall successfully!\n"
}

# Get value of seba environment variables
command::env() {
    env::setup
    echo "${!1}"
}

usage() {
    echo "
Usage: seba [command]

command:
    status      show status
    build       build docker image
    save        save docker image and archive
    ship        ship docker images
    install     install docker images
    env         get value of seba variables

available seba variables:
    COMMIT, VERSION, SHIP_VERSION, IMAGE_NAME, IMAGE_TAR, IMAGE_TAR_GZ

" 1>&2; exit 1;
}

main() {
    local command="${1:-notset}"

    if [[ "${command}" == "notset" ]]; then
        usage
    fi

    shift

    case "${command}" in
        status|build|save|ship|install|env)
            "command::${command}" "$@"
            ;;
        *)
            usage
    esac
}

main "$@"

