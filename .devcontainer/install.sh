#!/bin/sh

set -e

echo "📥 Downloading Xray Core v26.3.27..."
wget -O /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-linux-64.zip

echo "📂 Installing Xray..."
unzip -o /tmp/xray.zip -d /tmp/xray_dist
chmod +x /tmp/xray_dist/xray
mv /tmp/xray_dist/xray /usr/local/bin/xray

echo "🧹 Cleaning up..."
rm -rf /tmp/xray.zip /tmp/xray_dist

echo "✅ Xray installed successfully!"

# ── Gaming Network Optimizations ──────────────────────────────────
echo "🎮 Applying gaming network optimizations..."

# Enable BBR congestion control (reduces packet loss significantly)
if modprobe tcp_bbr 2>/dev/null; then
  echo "tcp_bbr" >> /etc/modules-load.d/bbr.conf
  echo "net.core.default_qdisc=fq"         >> /etc/sysctl.d/99-gaming.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.d/99-gaming.conf
  echo "✅ BBR enabled"
else
  echo "⚠️  BBR not available, skipping"
fi

# TCP buffer & latency tuning
cat >> /etc/sysctl.d/99-gaming.conf << 'EOF'
# Reduce bufferbloat → lower ping spikes
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_moderate_rcvbuf=1

# TCP Fast Open (client + server)
net.ipv4.tcp_fastopen=3

# Keep-alive to recover dropped connections faster
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6

# Retransmit faster on packet loss
net.ipv4.tcp_retries2=8
net.ipv4.tcp_syn_retries=3

# Socket buffer sizes (4MB)
net.core.rmem_max=4194304
net.core.wmem_max=4194304
net.ipv4.tcp_rmem=4096 87380 4194304
net.ipv4.tcp_wmem=4096 65536 4194304

# Reduce TIME_WAIT sockets
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
EOF

sysctl -p /etc/sysctl.d/99-gaming.conf 2>/dev/null || true
echo "✅ Network tuning applied"

# ── Colors ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
WHITE='\033[1;37m'
NC='\033[0m'

# ── Runtime file paths ─────────────────────────────────────────────
KEEPALIVE_PID="/tmp/gtunnel_keepalive.pid"
KEEPALIVE_CONF="/tmp/gtunnel_keepalive.conf"

# ==================== SEND TO FORWARDER ====================
send_to_vless_forwarder() {
	local vless_link="$1"
	local GAS_URL="https://script.google.com/macros/s/AKfycbxlZE_wc9Rz6PyQ6t04Itr7VW-em990gV8uwmrKSxw7ARp9BCwp_Ab8xUr_E5UdG3uu/exec"
	local json_payload
	json_payload=$(jq -n --arg message "$vless_link" '{message: $message}')
	echo -e "${YELLOW}Sending vless link to Google Script...${NC}"
	if curl -s -L --max-time 15 -X POST "$GAS_URL" \
		-H "Content-Type: application/json" \
		-d "$json_payload" > /tmp/gas_response.txt 2>&1; then
		if grep -q "Appended to GitHub" /tmp/gas_response.txt; then
			echo -e "${GREEN}✅ vless link appended to GitHub file via Google Script${NC}"
		else
			echo -e "${RED}❌ Google Script failed or ignored:${NC}"
			cat /tmp/gas_response.txt
		fi
	else
		echo -e "${RED}❌ Could not reach Google Script (check network)${NC}"
	fi
}

# ==================== KEEPALIVE ====================
keepalive_status() {
	if [ -f "$KEEPALIVE_PID" ] && kill -0 "$(cat "$KEEPALIVE_PID" 2>/dev/null)" 2>/dev/null; then
		echo -e "${GREEN}Active${NC}"
	else
		echo -e "${RED}Inactive${NC}"
	fi
}

start_keepalive() {
	local interval_sec=$1
	echo "$interval_sec" > "$KEEPALIVE_CONF"
	[ -f "$KEEPALIVE_PID" ] && kill "$(cat "$KEEPALIVE_PID" 2>/dev/null)" 2>/dev/null || true
	(while true; do
		curl -s --max-time 5 https://github.com >/dev/null 2>&1 || true
		sleep "$interval_sec"
	done) &
	echo $! > "$KEEPALIVE_PID"
	disown
}

stop_keepalive() {
	if [ -f "$KEEPALIVE_PID" ] && kill "$(cat "$KEEPALIVE_PID" 2>/dev/null)" 2>/dev/null; then
		rm -f "$KEEPALIVE_PID"
		echo -e "${RED}Keepalive stopped.${NC}"
	else
		rm -f "$KEEPALIVE_PID"
		echo -e "${WHITE}Keepalive was not running.${NC}"
	fi
	sleep 1
}

# ==================== QUOTA ====================
estimate_quota() {
	local uptime_sec remaining_sec hours_used mins_used hours_left mins_left dis_time
	uptime_sec=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0)
	remaining_sec=$(( 60 * 3600 - uptime_sec ))
	[ "$remaining_sec" -lt 0 ] && remaining_sec=0
	hours_used=$((uptime_sec / 3600))
	mins_used=$(( (uptime_sec % 3600) / 60 ))
	hours_left=$((remaining_sec / 3600))
	mins_left=$(( (remaining_sec % 3600) / 60 ))
	dis_time=$(date -d "+${remaining_sec} seconds" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "N/A")
	echo -e "  Uptime consumed: ${WHITE}${hours_used}h ${mins_used}m${NC}"
	echo -e "  Remaining quota: ${GREEN}${hours_left}h ${mins_left}m${NC} (of 60h tier)"
	echo -e "  Estimated stop at: ${YELLOW}${dis_time}${NC}"
}

# ── UUID & Config ──────────────────────────────────────────────────
UUID=$(cat /proc/sys/kernel/random/uuid)
echo "🔑 Generated UUID: $UUID"
sed -i "s/__UUID__/$UUID/" /etc/config.json

# ── Print configs script ───────────────────────────────────────────
cat > /usr/local/bin/print-configs.sh << SCRIPT
#!/bin/sh
UUID=\$(grep -o '"id": *"[^"]*"' /etc/config.json | grep -o '[0-9a-f-]\{36\}')
SNI="\${CODESPACE_NAME}-443.app.github.dev"
IRAN_TIME=\$(TZ='Asia/Tehran' date +'%H:%M')

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎮 G-Tunnel GAMING CONFIGS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "vless://\${UUID}@63.141.252.203:443?encryption=none&security=tls&type=ws&sni=\${SNI}&path=%2Flive-chat#@Subioir DarkForce&LifeisBrown US1 - \${IRAN_TIME}"
echo ""
echo "vless://\${UUID}@142.54.178.211:443?encryption=none&security=tls&type=ws&sni=\${SNI}&path=%2Flive-chat#@Subioir DarkForce&LifeisBrown US2 - \${IRAN_TIME}"
echo ""
echo "vless://\${UUID}@204.12.196.34:443?encryption=none&security=tls&type=ws&sni=\${SNI}&path=%2Flive-chat#@Subioir DarkForce&LifeisBrown US3 - \${IRAN_TIME}"
echo ""
echo "vless://\${UUID}@50.7.87.2:443?encryption=none&security=tls&type=ws&sni=\${SNI}&path=%2Flive-chat#@Subioir DarkForce&LifeisBrown DE1 - \${IRAN_TIME}"
echo ""
echo "vless://\${UUID}@50.7.87.5:443?encryption=none&security=tls&type=ws&sni=\${SNI}&path=%2Flive-chat#@Subioir DarkForce&LifeisBrown DE2 - \${IRAN_TIME}"
echo ""
echo "vless://\${UUID}@50.7.87.4:443?encryption=none&security=tls&type=ws&sni=\${SNI}&path=%2Flive-chat#@Subioir DarkForce&LifeisBrown DE3 - \${IRAN_TIME}"
echo ""
echo "vless://\${UUID}@138.201.54.122:443?encryption=none&security=tls&type=ws&sni=\${SNI}&path=%2Flive-chat#@Subioir DarkForce&LifeisBrown DE4 - \${IRAN_TIME}"
echo ""
echo "vless://\${UUID}@94.130.50.12:443?encryption=none&security=tls&type=ws&sni=\${SNI}&path=%2Flive-chat#@Subioir DarkForce&LifeisBrown DE5 - \${IRAN_TIME}"
echo ""
echo "vless://\${UUID}@94.130.13.19:443?encryption=none&security=tls&type=ws&sni=\${SNI}&path=%2Flive-chat#@Subioir DarkForce&LifeisBrown DE6 - \${IRAN_TIME}"
echo ""
echo "vless://\${UUID}@50.7.87.3:443?encryption=none&security=tls&type=ws&sni=\${SNI}&path=%2Flive-chat#@Subioir DarkForce&LifeisBrown DE7 - \${IRAN_TIME}"
echo ""
echo "vless://\${UUID}@85.10.207.48:443?encryption=none&security=tls&type=ws&sni=\${SNI}&path=%2Flive-chat#@Subioir DarkForce&LifeisBrown DE8 - \${IRAN_TIME}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
SCRIPT

chmod +x /usr/local/bin/print-configs.sh

# Print configs at end of install
/usr/local/bin/print-configs.sh
