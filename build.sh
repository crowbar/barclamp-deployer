#!/bin/bash
#
# Copyright 2011-2013, Dell
# Copyright 2013-2014, SUSE LINUX Products GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

[[ $BC_CACHE ]] || export BC_CACHE="$HOME/.crowbar-build-cache/barclamps/deployer"
[[ $CROWBAR_DIR ]] || export CROWBAR_DIR="$HOME/crowbar"
[[ $BC_DIR ]] || export BC_DIR="$HOME/crowbar/barclamps/deployer"

echo "Using: BC_CACHE = $BC_CACHE"
echo "Using: CROWBAR_DIR = $CROWBAR_DIR"
echo "Using: BC_DIR = $BC_DIR"

bc_needs_build() {
    true
}

bc_build() {
    mkdir -p "$BC_CACHE/files/wsman"
    mkdir -p "$BC_CACHE/gems"

    cd "$BC_DIR/updates/wsman"
    gem build wsman.gemspec

    mv "$BC_DIR"/updates/wsman/wsman*.gem "$BC_CACHE/gems"
}
