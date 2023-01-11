#!/bin/bash

# This script demonstrates how to interact with a local SNMP daemon.
# It uses the Net-SNMP tools (http://www.net-snmp.org/).

snmpd -f -C -c snmpd.conf &
snmpwalk -v 2c -c rnp localhost:10161
wait
