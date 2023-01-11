#!/bin/bash

# A script illustrating an IPFIX setup with a collector and an exported using
# pmacct.
# http://www.pmacct.net/

set -eEuxo pipefail

IP_COLLECTOR=fc00::1
IP_EXPORTER=fc00::2

this="$(printf %q "$(realpath "$0")")"

on_err() {
	read -p "Error occurred. Press Enter to continue..."
}

trap on_err ERR

setup() {
	# tmux related settings.
	tmux set pane-border-status top
	tmux set default-shell /bin/bash

	# Create veth pair.
	ip link add veth-co type veth peer veth-ex

	# Create netnses.
	ip netns add netns-co
	ip netns add netns-ex

	# Move veths.
	ip link set veth-co netns netns-co
	ip link set veth-ex netns netns-ex

	# Setup sides.
	ip netns exec netns-co "$0" setup_side co "$IP_COLLECTOR"
	ip netns exec netns-ex "$0" setup_side ex "$IP_EXPORTER"

	# Wait for NDP to determine uniqueness.
	ip netns exec netns-co "$0" wait_tentative
	ip netns exec netns-ex "$0" wait_tentative

	# Start collector and exporter.
	tmux select-pane -T "Collector"
	tmux split-window -v "ip netns exec netns-ex $this exporter"
	tmux select-pane -T "Exporter"
	tmux new-window "ip netns exec netns-co $this server $IP_COLLECTOR"
	tmux select-pane -T "HTTP-Server"
	tmux set pane-border-status top
	tmux split-window -h "ip netns exec netns-ex $this client [$IP_COLLECTOR]"
	tmux select-pane -T "HTTP-Client"
	tmux select-window -t 0
	tmux select-pane -t 0
	clear
	ip netns exec netns-co "$0" collector
	tmux kill-session
}

setup_side() {
	# Up interface.
	ip link set "veth-$1" up

	# Add ip address to interface.
	ip address add "$2/64" dev "veth-$1"
}

collector() {
	clear

	# Collect data via IPFIX from exporter and print.
	nfacctd -L "$IP_COLLECTOR" -l 2100 -P print -r 5 -c src_host,dst_host,dst_port,proto
}

exporter() {
	clear

	# Wait for collector to start up.
	sleep 1

	# Collect data and export via IPFIX to collector.
	pmacctd -f pmacctd.conf
}

server() {
	clear
	python -m http.server --bind "$1" 80
}

client() {
	# Generate some traffic.
	watch curl "http://$1"
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

	delete_netns co
	delete_netns ex
	delete_link veth-co
	delete_link veth-ex
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
