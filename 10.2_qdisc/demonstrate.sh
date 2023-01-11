#!/bin/bash

# This script demonstrates how to shape network traffic using Linux queuing
# disciplines.

set -eEuxo pipefail

IP_ROUTER_IN=fc00::1
IP_MAIL=fc00::2
IP_GIT=fc00::3
IP_WEB=fc00::4
IP_ROUTER_EX=fc00:1::1
IP_CLIENT=fc00:1::2

this="$(printf %q "$(realpath "$0")")"

on_err() {
	read -p "Error occurred. Press Enter to continue..."
}

trap on_err ERR

setup() {
	# tmux related settings.
	tmux set pane-border-status top
	tmux set default-shell /bin/bash

	# Create veth pairs.
	ip link add veth-in-rt type veth peer veth-in-sv
	ip link add veth-ex-rt type veth peer veth-ex-cl

	# Create netnses.
	ip netns add netns-rt
	ip netns add netns-sv
	ip netns add netns-cl

	# Move veths.
	ip link set veth-in-rt netns netns-rt
	ip link set veth-ex-rt netns netns-rt
	ip link set veth-in-sv netns netns-sv
	ip link set veth-ex-cl netns netns-cl

	# Setup sides.
	ip netns exec netns-rt "$0" setup_side in-rt "$IP_ROUTER_IN"
	ip netns exec netns-rt "$0" setup_side ex-rt "$IP_ROUTER_EX"
	ip netns exec netns-sv "$0" setup_side in-sv "$IP_MAIL" "$IP_GIT" "$IP_WEB"
	ip netns exec netns-cl "$0" setup_side ex-cl "$IP_CLIENT"

	# Wait for NDP to determine uniqueness.
	ip netns exec netns-rt "$0" wait_tentative
	ip netns exec netns-sv "$0" wait_tentative
	ip netns exec netns-cl "$0" wait_tentative

	# Add routes.
	ip netns exec netns-sv ip route add "$IP_CLIENT/64" via "$IP_ROUTER_IN"
	ip netns exec netns-cl ip route add "$IP_MAIL/64" via "$IP_ROUTER_EX"

	# Configure router.
	ip netns exec netns-rt "$0" configure_router

	# Setup iperf servers.
	tmux new-window "ip netns exec netns-sv $this iperf_server $IP_MAIL"
	tmux select-pane -T "Iperf Mail Server"
	tmux split-window -h "ip netns exec netns-sv $this iperf_server $IP_GIT"
	tmux select-pane -T "Iperf Git Server"
	tmux split-window -v "ip netns exec netns-sv $this iperf_server $IP_WEB"
	tmux select-pane -T "Iperf Web Server"
	tmux set pane-border-status top

	# Test network performance.
	tmux select-window -t 0
	tmux split-window -h "ip netns exec netns-cl $this iperf_client $IP_GIT"
	tmux select-pane -T "Iperf Git Client"
	tmux select-pane -t 0
	tmux select-pane -T "Iperf Mail Client"
	ip netns exec netns-cl "$0" iperf_client "$IP_MAIL"

	tmux kill-pane -t 1
	tmux split-window -h "ip netns exec netns-cl $this iperf_client $IP_WEB"
	tmux select-pane -T "Iperf Other Client"
	tmux select-pane -t 0
	tmux select-pane -T "Iperf Git Client"
	ip netns exec netns-cl "$0" iperf_client "$IP_GIT"

	tmux kill-pane -t 1
	tmux split-window -h "ip netns exec netns-cl $this iperf_client $IP_WEB -R"
	tmux select-pane -T "Iperf Web Download"
	tmux select-pane -t 0
	tmux select-pane -T "Iperf Mail Download"
	ip netns exec netns-cl "$0" iperf_client "$IP_MAIL" -R

	tmux kill-session
}

setup_side() {
	# Up interfaces.
	ip link set lo up
	ip link set "veth-$1" up

	# Allow forwarding.
	sysctl "net.ipv6.conf.all.forwarding=1"

	# Add ip address to interface.
	for ip in "${@:2}"; do
		ip address add "$ip/64" dev "veth-$1"
	done
}

configure_router() {
	# Add classless qdisc to internal interface to create bottleneck.
	tc qdisc add dev veth-in-rt root handle 2: tbf rate 60mbit burst 1mb latency 20ms

	# Add classful qdisc to internal interface.
	tc qdisc add dev veth-in-rt parent 2: handle 1: prio bands 3

	# Configure internal interface filters.
	# Higher priority (value) filters overrule lower priority ones.
	tc filter add dev veth-in-rt parent 1: prio 10 protocol ipv6 \
		u32 match ip6 dst "$IP_MAIL" classid 1:1
	tc filter add dev veth-in-rt parent 1: prio 5 protocol ipv6 \
		u32 match ip6 dst "$IP_GIT" classid 1:2
	tc filter add dev veth-in-rt parent 1: prio 0 protocol ipv6 \
		matchall classid 1:3

	# Add classful qdisc to external interface.
	tc qdisc add dev veth-ex-rt root handle 1: htb

	# Add classes to qdisc with rate limit.
	tc class add dev veth-ex-rt parent 1: classid 1:1 htb rate 1mbit
	tc class add dev veth-ex-rt parent 1: classid 1:2 htb rate 1gbit ceil 1tbit

	# Configure external interface filters.
	tc filter add dev veth-ex-rt parent 1: prio 10 protocol ipv6 \
		u32 match ip6 src "$IP_WEB" classid 1:1
	tc filter add dev veth-ex-rt parent 1: prio 0 protocol ipv6 \
		matchall classid 1:2
}

iperf_server() {
	clear
	iperf3 -sV -B "$1"
}

iperf_client() {
	clear
	# Limit iperf to 40 Mbit/s.
	iperf3 -c "$1" -b 40M "${@:2}"
	read -p "Press Enter to continue..."
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

	delete_netns rt
	delete_netns sv
	delete_netns cl
	delete_link veth-in-rt
	delete_link veth-ex-rt
	delete_link veth-in-sv
	delete_link veth-ex-cl
}

delete_netns() {
	ip netns delete "netns-$1" || echo "netns netns-$1 does not exist."
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
