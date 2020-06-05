#!/bin/sh

if [ $(id -u) -ne 0 ]; then
    exec sudo -E "$0" "$@"
fi

base=$(dirname $0)

ip addr add 10.0.1.1/32 dev lo
ip addr add 10.0.1.2/32 dev lo

nft -f $base/priv/lb.nft
nft list table ip raw


# nft -nn monitor trace
