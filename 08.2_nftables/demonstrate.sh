#!/bin/bash

# Example script for using nftables to configure Linux firewalls.

set -eEuxo pipefail

# Firewall IP to outside.
IP_FW_WAN=10.0.0.1
# Firewall IP to inside.
IP_FW_LAN=192.168.2.1
# Attacker IP on the outside.
IP_ATTACKER=10.0.0.22
# User IP inside the LAN.
IP_USER=192.168.2.33
LAN=192.168.2.0/24
WAN=10.0.0.0/24
# Prefix for logging packets.
PREFIX="nft-demo___"

this="$(printf %q "$0")"

on_err() {
	read -p "Error occurred. Press Enter to continue..."
}

trap on_err ERR

setup() {
	# tmux related settings.
	tmux set pane-border-status top
	tmux set default-shell /bin/bash

	echo 1 >/proc/sys/net/netfilter/nf_log_all_netns

	# Create veth pairs.
	ip link add veth-fw-wan type veth peer veth-attacker
	ip link add veth-fw-lan type veth peer veth-user

	# Create netnses.
	ip netns add fw
	ip netns add attacker
	ip netns add user

	# Move veths.
	ip link set veth-fw-wan netns fw
	ip link set veth-fw-lan netns fw
	ip link set veth-attacker netns attacker
	ip link set veth-user netns user

	# Up interfaces.
	ip netns exec fw ip link set veth-fw-wan up
	ip netns exec fw ip link set veth-fw-lan up
	ip netns exec attacker ip link set veth-attacker up
	ip netns exec user ip link set veth-user up

	# Add IP addresses.
	ip netns exec fw ip address add "$IP_FW_WAN/24" dev veth-fw-wan
	ip netns exec fw ip address add "$IP_FW_LAN/24" dev veth-fw-lan
	ip netns exec attacker ip address add "$IP_ATTACKER/24" dev veth-attacker
	ip netns exec user ip address add "$IP_USER/24" dev veth-user

	# Add routes.
	ip netns exec attacker ip route add "$LAN" via "$IP_FW_WAN"
	ip netns exec user ip route add "$WAN" via "$IP_FW_LAN"

	present
}

present() {
	# Present tasks.
	tmux select-pane -T "configure firewall"

	## 1.
	tmux split-window -v "ip netns exec fw $this dump veth-fw-wan"
	tmux select-pane -T "dump veth-fw-wan"
	tmux select-pane -t 0
	tmux split-window -h "ip netns exec attacker $this ping $IP_FW_WAN"
	tmux select-pane -T "ping attacker->firewall"
	tmux select-pane -t 0

	ip netns exec fw "$0" nft_drop_icmp

	tmux kill-pane -t 2
	tmux kill-pane -t 1

	# 2.
	tmux split-window -v "ip netns exec fw $this dump veth-fw-wan"
	tmux select-pane -T "dump veth-fw-wan"
	tmux select-pane -t 0
	tmux split-window -h "ip netns exec attacker $this ping $IP_FW_WAN"
	tmux select-pane -T "ping attacker->firewall"
	tmux select-pane -t 0

	ip netns exec fw "$0" nft_established

	tmux kill-pane -t 2
	tmux kill-pane -t 1

	# 3.
	tmux split-window -v "ip netns exec fw $this dump veth-fw-wan"
	tmux select-pane -T "dump veth-fw-wan"
	tmux split-window -h "ip netns exec fw $this http 22"
	tmux select-pane -T "HTTP server on firewall @ port 22"
	tmux select-pane -t 0
	tmux split-window -h "ip netns exec attacker $this curl http://$IP_FW_WAN:22"
	tmux select-pane -T "curl attacker->firewall on port 22"
	tmux select-pane -t 0

	ip netns exec fw "$0" nft_ssh

	tmux kill-pane -t 3
	tmux kill-pane -t 2
	tmux kill-pane -t 1

	# 4.
	tmux split-window -v "ip netns exec user $this dump veth-user"
	tmux select-pane -T "dump veth-user"
	tmux select-pane -t 0
	tmux split-window -h "ip netns exec attacker $this ping $IP_USER"
	tmux select-pane -T "ping attacker-firewall->user"
	tmux select-pane -t 0

	ip netns exec fw "$0" nft_forward

	tmux kill-pane -t 2
	tmux kill-pane -t 1

	# 5.
	tmux split-window -v "ip netns exec fw $this dump veth-fw-lan"
	tmux select-pane -T "dump veth-fw-lan"
	tmux split-window -h "ip netns exec fw $this journalctl $(printf %q "$PREFIX")"
	tmux select-pane -T "system log"
	tmux select-pane -t 0
	tmux split-window -h "ip netns exec fw $this ping $IP_USER"
	tmux select-pane -T "ping firewall->user"
	tmux select-pane -t 0

	ip netns exec fw "$0" nft_log

	tmux kill-pane -t 3
	tmux kill-pane -t 2
	tmux kill-pane -t 1

	tmux kill-session
}

nft_drop_icmp() {
	clear
	nft create table filter
	nft create chain filter input \{ type filter hook input priority 0 \; \}

	read -p "Press Enter to drop all ICMP packets..."

	# Drop ICMP packets.
	nft insert rule filter input ip protocol icmp drop

	read -p "Press enter to continue..."

	nft delete table filter
}

nft_established() {
	clear
	nft create table filter

	read -p "Press Enter to drop all new connections..."

	# Drop packets by default.
	nft create chain filter input \{ type filter hook input priority 0 \; policy drop \; \}
	# Accept packets from established and related connections.
	nft insert rule filter input ct state established,related accept

	read -p "Press enter to start pinging the attacker..."

	command ping -c 4 "$IP_ATTACKER"

	read -p "Press enter to continue..."

	nft delete table filter
}

nft_ssh() {
	clear
	nft create table filter
	nft create chain filter input \{ type filter hook input priority 0 \; policy drop \; \}

	read -p "Press Enter to allow packets on SSH port..."

	# Accept packets on SSH port.
	nft insert rule filter input tcp dport 22 accept

	read -p "Press enter to continue..."

	nft delete table filter
}

nft_forward() {
	clear
	nft create table filter
	# Use forward hook.
	nft create chain filter forward \{ type filter hook forward priority 0 \; policy drop \; \}

	read -p "Press Enter to allow forwarding..."

	# Allow forwarding to LAN.
	nft insert rule filter forward ip daddr "$LAN" accept

	read -p "Press enter to continue..."

	nft delete table filter
}

nft_log() {
	clear
	nft create table filter
	nft create chain filter output \{ type filter hook output priority 0 \; \}

	read -p "Press Enter to start logging..."

	# Log outgoing ICMP packets.
	nft insert rule filter output ip protocol icmp log prefix "$PREFIX" level warn

	read -p "Press enter to continue..."

	nft delete table filter
}

ping() {
	clear
	command ping "$1"
}

http() {
	clear

	# Start HTTP server.
	python -m http.server "$1"
}

curl() {
	# Connect to HTTP server.
	LC_NUMERIC= watch -n 1 curl --connect-timeout 1 --silent --show-error "$1"
}

journalctl() {
	clear
	command journalctl -kf --since now --grep "$1"
}

dump() {
	clear
	tcpdump -ni "$1" ip
}

start_tmux() {
	tmux new-session "$this setup"

	# Cleanup.
	delete_netns fw
	delete_netns attacker
	delete_netns user
	delete_link veth-fw-wan
	delete_link veth-fw-lan
	delete_link veth-attacker
	delete_link veth-user
	echo 0 >/proc/sys/net/netfilter/nf_log_all_netns || echo "could not disable nf_log_all_netns"
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
