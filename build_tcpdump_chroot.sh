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

SOURCES=(libpcap-1.2.1.tar.gz tcpdump-4.2.1.tar.gz)

cd /tmp
for s in ${SOURCES[@]}; do
    cp ${BC_CACHE}/files/"$s" .
    tar xzf "$s"
    cd "${s%.tar.gz}"
    case $s in
	libpcap*)
	    ./configure
	    make
	    libpcap=${s%.tar.gz}
	    ;;
	tcpdump*)
	    LDFLAGS=-static ./configure "--with-libpcap=../$libpcap"
	    LDFLAGS=-static make
	    strip tcpdump
	    tcpdump=${s%.tar.gz}
	    ;;
    esac
    cd ..
done
[[ -x $tcpdump/tcpdump ]] || exit 1
cp "$tcpdump/tcpdump" /mnt/files
