#!/bin/bash
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
