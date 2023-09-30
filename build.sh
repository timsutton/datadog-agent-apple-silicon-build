#!/bin/bash

set -eu -o pipefail
set -x

DD_VERSION=7.47.1
# override this as you wish: find these definitions in release.json
RELEASE_VERSION=release-a7

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
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

    # Apply everything in /patches
    for patch_file in "${script_dir}/patches/"*.patch; do
        git apply "${patch_file}"
    done

    # ..then apply any patches specific to this version
    for patch_file in "${script_dir}/patches/${DD_VERSION}/"*.patch; do
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
    if [ "$(uname -m)" != "arm64" ] || [ "$(uname)" != "Darwin" ]; then
        echo "This script must be run on macOS on Apple Silicon."
        exit 1
    fi

    # Brew env
    if brew ls | grep gettext >/dev/null; then
        # scrub gettext's libs from the brew environment, due to:
        # https://github.com/DataDog/datadog-agent-macos-build/blob/aa2bd128f333c2bf7400f32d00088917573130ba/.github/workflows/test.yaml#L52-L57
        echo "Found a 'gettext' in 'brew ls'. This is known to cause issues in"
        echo "the build. Uninstalling it now, we'll put it back at the end!"
        brew rm --ignore-dependencies gettext
        brew_gettext_removed=1
    fi

    if ! command -v cmake >/dev/null; then
        echo "No cmake found. You can install it with brew: 'brew install cmake'"
        exit 1
    fi

    # Python env (naively checks for what we know homebrew installs)
    # It's important to use 3.8:
    # https://github.com/DataDog/datadog-agent/blame/main/docs/dev/agent_dev_env.md#L15-L18
    if ! command -v python3.8 >/dev/null; then
        echo "This script requires you have an available Python 3.8 in your PATH, but one couldn't"
        echo "be found. Exiting early."
        exit 1
    fi
}

function env_setup_python() {
    # python
    python_exe="$(command -v python3.8)"
    rm -rf venv
    # We have to create the build virtualenv using virtualenv and not `python -m venv` due
    # to issues resolving Python initialization when building embedded Pythons:
    # https://bugs.python.org/issue22213
    $python_exe -m pip install 'virtualenv==20.24.3'
    virtualenv venv
    source venv/bin/activate
    # Include some fixes from https://github.com/DataDog/datadog-agent-buildimages/pull/419
    python3 -m pip install distro==1.4.0 wheel==0.40.0
    python3 -m pip install --no-build-isolation "cython<3.0.0" PyYAML==5.4.1
    python3 -m pip install -r requirements.txt --disable-pip-version-check
    python3 -m pip uninstall -y cython
}

function env_setup_go() {
    # go
    command -v gimme >/dev/null || brew install gimme
    go_version=$(cat .go-version)
    eval "$(gimme "${go_version}")"
    inv check-go-version

    # We should only need this for dev/testing reasons, not packaged builds
    # invoke install-tools
}

function env_setup_build_dirs() {
    sudo rm -rf /opt/datadog-agent ./vendor ./vendor-new /var/cache/omnibus/src/* ./omnibus/Gemfile.lock

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
    if command -v rvm >/dev/null; then
        if rvm list | grep '2.7'; then
            rvm use 2.7
            echo "Selected Ruby $(which ruby) using rvm"
            return
        fi
    fi

    if command -v chruby >/dev/null; then
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

    # ffi-yajl has issues building on M1 and newer Xcodes, so override the build
    # settings for this in Bundler. This is fixed on later releases, but
    # https://github.com/chef/ffi-yajl/issues/115
    bundle config build.ffi-yajl --with-ldflags="-Wl,-undefined,dynamic_lookup"
}

function run_build() {
    # https://github.com/DataDog/datadog-agent/blob/main/docs/dev/agent_build.md
    # https://github.com/DataDog/datadog-agent/blob/main/docs/dev/agent_dev_env.md
    # https://github.com/DataDog/datadog-agent/blob/main/docs/dev/agent_omnibus.md

    # including --log-level=debug so we get full configure/make output
    invoke \
        --echo \
        agent.omnibus-build \
        --skip-sign \
        --python-runtimes "3" \
        --major-version "7" \
        --release-version "${RELEASE_VERSION}" \
        --log-level=debug

    # building just the agent + python works fine
    # invoke agent.build \
    #     --build-include=python
}

env_setup_build_dirs
env_setup_ruby

sanity_checks

fix_git
setup_dd_agent_repo

env_setup_python
env_setup_go

run_build
