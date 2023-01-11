#!/bin/bash

# This script demonstrates how two machines can communicate via the WireGuard
# (https://www.wireguard.com/) VPN tool.

set -eEuxo pipefail

PUBLIC_IP_LEFT=10.0.0.1
PUBLIC_IP_RIGHT=10.0.0.2
PRIVATE_IP_LEFT=192.168.0.1
PRIVATE_IP_RIGHT=192.168.0.2
PORT=51820

this="$(printf %q "$(realpath "$0")")"

on_err() {
	read -p "Error occurred. Press Enter to continue..."
}

trap on_err ERR

setup() {
	# tmux related settings.
	tmux set pane-border-status top
	tmux set default-shell /bin/bash

	# Create bridge and up.
	ip link add bri type bridge
	ip link set bri up

	# Create veth pairs.
	ip link add veth-left type veth peer veth-left-br
	ip link add veth-right type veth peer veth-right-br

	# Add veths to bridge.
	ip link set veth-left-br master bri
	ip link set veth-right-br master bri

	# Create netnses.
	ip netns add left
	ip netns add right

	# Move veths.
	ip link set veth-left netns left
	ip link set veth-right netns right

	# Up interfaces.
	ip link set veth-left-br up
	ip link set veth-right-br up

	# Setup sides.
	ip netns exec left "$0" setup_side left "$PUBLIC_IP_LEFT"
	ip netns exec right "$0" setup_side right "$PUBLIC_IP_RIGHT"

	ip netns exec left "$0" setup_wireguard left right "$PRIVATE_IP_LEFT" "$PUBLIC_IP_RIGHT" \
		"$PRIVATE_IP_RIGHT"
	ip netns exec right "$0" setup_wireguard right left "$PRIVATE_IP_RIGHT" "$PUBLIC_IP_LEFT" \
		"$PRIVATE_IP_LEFT"

	tmux select-pane -T "ping left->right"
	clear
	ip netns exec left ping "$PRIVATE_IP_RIGHT"
}

setup_side() {
	# Up interface.
	ip link set "veth-$1" up

	# Add ip address to interface.
	ip address add "$2/24" dev "veth-$1"

	# Generate WireGuard keys.
	wg genkey | (umask 0077 && tee "$1.key") | wg pubkey >"$1.pub"
}

setup_wireguard() {
	# Create WireGuard interface.
	ip link add dev wg0 type wireguard

	# Add IP address.
	ip address add "$3/24" dev wg0

	# Setup WireGuard interface.
	wg set wg0 listen-port "$PORT" private-key "$1.key"
	wg set wg0 peer "$(cat "$2.pub")" endpoint "$4:$PORT" allowed-ips "$5/32"
	ip link set wg0 up
}

start_tmux() {
	tmpdir="$(mktemp -d)"
	cd "$tmpdir"

	tmux new-session "$this setup"

	# Cleanup.
	delete_netns left
	delete_netns right
	delete_link veth-left
	delete_link veth-right
	delete_link veth-left-br
	delete_link veth-right-br
	delete_link bri

	cd -
	rm "$tmpdir/left.key" || echo "no left.key file"
	rm "$tmpdir/left.pub" || echo "no left.pub file"
	rm "$tmpdir/right.key" || echo "no right.key file"
	rm "$tmpdir/right.pub" || echo "no right.pub file"
	rmdir "$tmpdir" || echo "no temporary directory"
}

delete_netns() {
	ip netns delete "$1" || echo "netns $1 does not exist."
}

delete_link() {
	ip link delete "$1" || echo "link $1 does not exist."
}

if [[ $# -le 0 ]]; then
	start_tmux
elif [[ "$(type -t $1)" == function ]]; then
	"$1" "${@:2}"
else
	exit 1
fi
