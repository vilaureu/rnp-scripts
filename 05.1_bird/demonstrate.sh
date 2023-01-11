#!/bin/bash

# This script demonstrates how two BIRD (https://bird.network.cz/) instances
# exchange IP routes via OSPF.

set -eEuxo pipefail

this="$(printf %q "$0")"

on_err() {
	read -p "Error occured. Press Enter to continue..."
}

trap on_err ERR

start_tmux() {
	tmux new-session "$this setup"

	# Cleanup code.
	ip netns delete left || echo "netns left does not exits."
	ip netns delete right || echo "netns right does not exits."
	rm -f left/bird.ctl
	rm -f right/bird.ctl
}

setup() {
	# Create veth pair.
	ip link add veth_left type veth peer veth_right

	# Create network namespaces.
	ip netns add left
	ip netns add right

	# Move interfaces to namespaces.
	ip link set veth_left netns left
	ip link set veth_right netns right

	# Setup interfaces.
	ip netns exec left ip link set veth_left up
	ip netns exec right ip link set veth_right up

	# Start demonstration.
	tmux split-window -v "ip netns exec left $this dump"
	tmux select-pane -t 0
	tmux split-window -h -p 80 "$this monitor"
	tmux split-window -h -p 13 "ip netns exec right $this right"
	tmux select-pane -t 1
	ip netns exec left "$0" left
}

left() {
	clear
	ip link set lo up

	# Add IP addresses.
	ip addr add 192.186.0.1/24 dev lo
	ip addr add 10.0.0.1/24 dev veth_left

	# Start bird.
	cd left
	bird -dl
}

right() {
	clear

	# Add IP address.
	ip addr add 10.0.0.2/24 dev veth_right

	# Start bird.
	cd right
	bird -dl
}

dump() {
	clear
	tcpdump -i veth_left ip proto 89 # OSPF
}

monitor() {
	clear
	sleep 1
	ip netns exec left ip a

	# Demonstrate how routes are propagated.
	ip netns exec right ip route
	read -p "Press Enter to show routes... (You should wait for OSPF to propagate routes.)"
	ip netns exec right ip route
	read -p "Press Enter to exit..."
	tmux kill-session
}

if [[ $# -le 0 ]]; then
	start_tmux
elif [[ "$1" == "setup" ]]; then
	setup
elif [[ "$1" == "left" ]]; then
	left
elif [[ "$1" == "right" ]]; then
	right
elif [[ "$1" == "dump" ]]; then
	dump
elif [[ "$1" == "monitor" ]]; then
	monitor
fi
