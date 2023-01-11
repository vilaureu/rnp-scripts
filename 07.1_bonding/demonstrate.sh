#!/bin/bash

# This script illustrates how layer 2 interface bonding can be performed in
# Linux.

set -eEuxo pipefail

SIDES="left right"
MEMBERS="0 1"

declare -A IPS
IPS[left]="fd00::1"
IPS[right]="fd00::2"

this="$(printf %q "$0")"

on_err() {
	read -p "Error occurred. Press Enter to continue..."
}

trap on_err ERR

start_tmux() {
	tmux new-session "$this setup"

	# Cleanup.
	for side in $SIDES; do
		ip netns delete "$side" || echo "netns $side does not exist."
		ip link delete "bond-$side" || echo "interface bond-$side does not exist."
		for i in $MEMBERS; do
			ip link delete "veth-$side-$i" || echo "interface veth-$side-$i does not exist."
		done
	done
	modprobe -r bonding || echo "bonding module not loaded."
}

setup() {
	tmux set default-shell /bin/bash

	# miimon         ... Check if link is up every N milliseconds.
	# 802.3ad        ... IEEE 802.3ad Dynamic link aggregation.
	# lacp_rate=fast ... Check for LACP neighbor every second.
	modprobe bonding miimon=100 mode=802.3ad lacp_rate=fast

	# Create veth pairs.
	for i in $MEMBERS; do
		ip link add "veth-left-$i" type veth peer "veth-right-$i"
	done

	# Create netnses and move veths.
	for side in $SIDES; do
		ip netns add "$side"
		for i in $MEMBERS; do
			ip link set "veth-$side-$i" netns "$side"
		done
	done

	# Do per-side setup.
	for side in $SIDES; do
		ip netns exec "$side" "$0" setup_side "$side"
	done

	# Demonstration.
	tmux split-window -v "ip netns exec left $this dump bond-left"
	tmux select-pane -t 0
	tmux split-window -h "ip netns exec left $this down veth-left-0 veth-left-1"
	tmux select-pane -t 0
	ip netns exec right "$0" ping "${IPS[left]}"
}

setup_side() {
	# Create bond.
	ip link add dev "bond-$1" type bond

	# Link interfaces to bond.
	for i in $MEMBERS; do
		ip link set "veth-$1-$i" master "bond-$1"
	done

	# Up all interfaces.
	for i in $MEMBERS; do
		ip link set "veth-$1-$i" up
	done
	ip link set "bond-$1" up
	ip addr add "${IPS[$1]}/64" dev "bond-$1"
}

ping() {
	clear
	read -p "Press Enter to start pinging..."
	command ping "$1"
}

down() {
	clear

	# Show fault behavior of bond.
	read -p "Press Enter to take $1 down..."
	ip link set "$1" down
	read -p "Press Enter to also take $2 down..."
	ip link set "$2" down
	read -p "Press Enter to kill session..."
	tmux kill-session
}

dump() {
	clear
	tcpdump -i "$1"
}

if [[ $# -le 0 ]]; then
	start_tmux
elif [[ "$1" == "setup" ]]; then
	setup
elif [[ "$1" == "setup_side" ]]; then
	setup_side "$2"
elif [[ "$1" == "ping" ]]; then
	ping "$2"
elif [[ "$1" == "down" ]]; then
	down "$2" "$3"
elif [[ "$1" == "dump" ]]; then
	dump "$2"
fi
