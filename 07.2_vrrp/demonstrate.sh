#!/bin/bash

# Demonstration of the VRRP protocol using keepalived
# https://www.keepalived.org/.

set -eEuxo pipefail

SIDES="master backup"

declare -A IPS
IPS[master]="192.168.0.11"
IPS[backup]="192.168.0.12"

this="$(printf %q "$0")"

on_err() {
	read -p "Error occurred. Press Enter to continue..."
}

trap on_err ERR

delete_link() {
	ip link delete "$1" || echo "link $1 does not exist."
}

start_tmux() {
	tmux new-session "$this setup"

	# Cleanup.
	for side in $SIDES; do
		ip netns delete "$side" || echo "netns $side does not exist."
		delete_link "veth-$side"
		delete_link "veth-$side-br"
	done
	delete_link bri
	rm -rf /run/keepalived/**/*.pid
}

setup() {
	tmux set default-shell /bin/bash

	# Create bridge and set up.
	ip link add bri type bridge
	ip link set bri up

	# Create netnes, veth pairs, and add them to the bridge and their netnses.
	for side in $SIDES; do
		ip netns add "$side"
		ip link add "veth-$side" type veth peer "veth-$side-br"
		ip link set "veth-$side-br" master bri
		ip link set "veth-$side-br" up
		ip link set "veth-$side" netns "$side"
	done

	# Up interfaces in netnses.
	for side in $SIDES; do
		ip netns exec "$side" "$0" setup_side "$side"
	done

	# Demonstration.
	tmux new-window "ip netns exec master $this ipa"
	tmux split-window -v "$this dump bri"
	tmux select-pane -t 0
	tmux split-window -h -p 60 "ip netns exec backup $this ipa"
	tmux split-window -h -p 33 "$this down veth-master-br"

	sleep 1
	tmux new-window "$this keepalived master"
	tmux split-window -h "$this keepalived backup"
	tmux select-window -t 1
}

setup_side() {
	ip link set "veth-$1" up
	ip addr add "${IPS[$1]}/24" dev "veth-$1"
}

ipa() {
	watch ip addr
}

keepalived() {
	clear
	if [[ "$1" == master ]]; then
		sleep 2
	fi
	command keepalived -f "$1.cfg" --vrrp --dont-fork --log-console
}

down() {
	clear

	# Take a router down.
	read -p "Press Enter to take $1 down..."
	ip link set "$1" down
	read -p "Press Enter to kill session..."
	tmux kill-session
}

dump() {
	clear
	tcpdump -n -i "$1" not ip6
}

if [[ $# -le 0 ]]; then
	start_tmux
elif [[ "$(type -t $1)" == function ]]; then
	"$1" "${@:2}"
else
	exit 1
fi
