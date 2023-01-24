#!/bin/bash

# A script illustrating how to use an Open vSwitch bridge to connect network
# namespaces.
# https://www.openvswitch.org/

set -eEuxo pipefail

IP_V1=fc00:1::2
IP_V2=fc00:2::2
IP_V1_ROUTER=fc00:1::1
IP_V2_ROUTER=fc00:2::1

this="$(printf %q "$(realpath "$0")")"

on_err() {
	read -p "Error occurred. Press Enter to continue..."
}

trap on_err ERR

setup() {
	# tmux related settings.
	tmux set pane-border-status top
	tmux set default-shell /bin/bash

	# Start Open vSwitch.
	systemctl start ovs-vswitchd.service

	# Create bridge. We might need to wait a bit for Open vSwitch to start up.
	for attempt in {1..5}; do
		if [[ "$attempt" -lt 5 ]]; then
			ovs-vsctl add-br bri &>/dev/null && break || sleep 1
		else
			ovs-vsctl add-br bri
		fi
	done

	# Create veth pairs.
	ip link add veth-v1 type veth peer veth-v1-br
	ip link add veth-v2 type veth peer veth-v2-br
	ip link add veth-rt-v1 type veth peer veth-rt-v1-br
	ip link add veth-rt-v2 type veth peer veth-rt-v2-br

	# Create netnses.
	ip netns add netns-v1
	ip netns add netns-v2
	ip netns add netns-rt

	# Move veths.
	ip link set veth-v1 netns netns-v1
	ip link set veth-v2 netns netns-v2
	ip link set veth-rt-v1 netns netns-rt
	ip link set veth-rt-v2 netns netns-rt

	# Connect veths to bridge and set VLANs.
	for t in "veth-v1-br 1" "veth-v2-br 2" "veth-rt-v1-br 1" "veth-rt-v2-br 2"; do
		read if tag <<<"$t"
		ovs-vsctl add-port bri "$if"
		ovs-vsctl set port "$if" vlan_mode=native-untagged
		ovs-vsctl set port "$if" "tag=$tag"
		ip link set "$if" up
	done

	# Setup sides.
	ip netns exec netns-v1 "$0" setup_side veth-v1 "$IP_V1"
	ip netns exec netns-v2 "$0" setup_side veth-v2 "$IP_V2"
	ip netns exec netns-rt "$0" setup_side veth-rt-v1 "$IP_V1_ROUTER"
	ip netns exec netns-rt "$0" setup_side veth-rt-v2 "$IP_V2_ROUTER"

	# Wait for NDP to determine uniqueness.
	ip netns exec netns-v1 "$0" wait_tentative
	ip netns exec netns-v2 "$0" wait_tentative
	ip netns exec netns-rt "$0" wait_tentative

	# Add routes.
	ip netns exec netns-v1 ip route add "$IP_V2/64" via "$IP_V1_ROUTER"
	ip netns exec netns-v2 ip route add "$IP_V1/64" via "$IP_V2_ROUTER"

	# Ping and dump.
	tmux split-window -v "$this dump veth-rt-v1-br"
	tmux select-pane -T "tcpdump"
	tmux select-pane -t 0
	tmux select-pane -T "Ping VLAN 1 → VLAN 2"
	ip netns exec netns-v1 "$0" ping "$IP_V2"

	tmux kill-session
}

setup_side() {
	# Up interfaces.
	ip link set "$1" up

	# Allow forwarding.
	sysctl "net.ipv6.conf.all.forwarding=1"

	# Add ip address to interface.
	ip address add "$2/64" dev "$1"
}

ping() {
	clear
	command ping "$1"
}

dump() {
	clear
	tcpdump -ni "$1" ip6
}

wait_tentative() {
	set +x
	clear
	echo "Waiting for NDP ..."

	# Wait for NDP to determine uniqueness.
	while ip a | grep tentative >/dev/null; do true; done

	set -x
}

start_tmux() {
	tmux new-session "$this setup"

	delete_netns netns-v1
	delete_netns netns-v2
	delete_netns netns-rt
	ovs-vsctl del-br bri || echo "Bridge does not exist."
	delete_link veth-v1
	delete_link veth-v2
	delete_link veth-rt-v1
	delete_link veth-rt-v2
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
