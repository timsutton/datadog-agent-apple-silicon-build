#!/bin/bash

set -eu -o pipefail


DD_VERSION=7.46.0
# override this as you wish: find these definitions in release.json
RELEASE_VERSION=release-a7

script_dir=$(cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)
brew_gettext_removed=

trap cleanup EXIT

function cleanup() {
    if [ -n "${brew_gettext_removed}" ]; then
        echo "Re-installing the homebrew gettext we'd removed"
        HOMEBREW_NO_INSTALL_UPGRADE=1 \
        HOMEBREW_NO_ENV_HINTS=1 \
        HOMEBREW_NO_INSTALL_CLEANUP=1 \
        brew install gettext
    fi
}

function setup_dd_agent_repo() {
    if [ ! -d datadog-agent ]; then
        git clone https://github.com/DataDog/datadog-agent
    fi

    cd datadog-agent
    git fetch
    git reset --hard "${DD_VERSION}"

    # Apply patches (can we just apply all files in the patches dir instead?)
    for patch_file in "${script_dir}/patches/"*.patch; do
        git apply "${patch_file}"
    done
}

function fix_git() {
    # git: if we had a homebrew-installed git already installed, we just broke it by uninstalling
    #      gettext as required in the earlier step. So, we set up a shim /bin dir at the front of
    #      PATh which points back to /usr/bin/git
    path_shim="$(mktemp -d)"
    mkdir "${path_shim}/bin"
    ln -sf /usr/bin/git "${path_shim}/bin/git"
    export PATH="${path_shim}/bin:${PATH}"
}

function sanity_checks() {
    # Brew env
    if brew ls | grep gettext >/dev/null; then
        # TODO: improve this text
        echo "Found a 'gettext' in 'brew ls'. This is known to cause"
        echo "issues in the build. uninstalling, we'll put it back at the end!"
        brew rm --ignore-dependencies gettext
        brew_gettext_removed=1
    fi

    if ! command -v cmake >/dev/null; then
        echo "No cmake found. You can install it with brew: 'brew install cmake'"
        exit 1
    fi

    # Python env
    if ! command -v python3.9 >/dev/null; then
        echo "This script requires you have an available Python 3.9 in your PATH, but one couldn't"
        echo "be found. Exiting early."
        exit 1
    fi
}

function env_setup_python() {
    # python
    python_exe="$(command -v python3.9)"
    if [ ! -d venv ]; then
        mkdir venv
        "${python_exe}" -m venv venv
    fi
    source venv/bin/activate
    pip install -r requirements.txt --disable-pip-version-check
}

function env_setup_go() {
    # go
    command -v gimme > /dev/null || brew install gimme
    go_version=$(cat .go-version)
    eval "$(gimme "${go_version}")"
    inv check-go-version

    # We should only need this for dev/testing reasons, not packaged builds
    # invoke install-tools
}

function env_setup_build_dirs() {
    # required directories
    for builddir in /var/cache/omnibus /opt/datadog-agent; do
        if [ ! -d "${builddir}" ]; then
            echo "Missing required dir: ${builddir}. Will need to create this and chown it to "
            echo "${USER} using sudo, which may now prompt for sudo credentials."
            sudo mkdir -p "${builddir}"
            sudo chown "$(whoami)" "${builddir}"
        fi
    done
}

function env_setup_ruby() {
    # Attempt to discover RVM or chruby and select a Ruby 2.7 if available
    if command -v rvm > /dev/null; then
        if rvm list | grep '2.7'; then
            rvm use 2.7
            echo "Selected Ruby $(which ruby) using rvm"
            return
        fi
    fi

    if command -v chruby > /dev/null; then
        if chruby | grep '2.7'; then
            chruby 2.7
            echo "Selected Ruby $(which ruby) using chruby"
            return
        fi
    fi

    if [[ "$(command -v ruby)" = "/usr/bin/ruby" ]]; then
        echo "Exiting early because you've got a system Ruby selected. First select a 2.7.x ruby using"
        echo "a ruby version manager and retry."
        exit 1
    fi

    # Old omnibus fork doesn't yet support Ruby 3.0+
    if ! ruby --version | grep -E -q '^ruby 2\.7.*$' >/dev/null; then
        echo "A ruby version other than 2.7 was detected. Switch first to a 2.7 Ruby version and retry."
        exit 1
    fi
}

function run_build() {
    # https://github.com/DataDog/datadog-agent/blob/main/docs/dev/agent_build.md
    # https://github.com/DataDog/datadog-agent/blob/main/docs/dev/agent_dev_env.md

    # including --log-level=debug so we get full configure/make output
    invoke \
        --echo \
        agent.omnibus-build \
        --skip-sign \
        --python-runtimes "3" \
        --major-version "7" \
        --release-version "${RELEASE_VERSION}"
        # --log-level=debug
}

env_setup_build_dirs
env_setup_ruby

sanity_checks

fix_git
setup_dd_agent_repo

env_setup_python
env_setup_go

run_build
