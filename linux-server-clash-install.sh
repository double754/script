#!/bin/bash
set -e

# 目录设置
https_proxy=
all_proxy=
http_proxy=
MROOT="$HOME/.mihomo"
BIN="$MROOT/mihomo"
CONF="$MROOT/config.yaml"
RUN_SCRIPT="$MROOT/run.sh"

# 下载源 https://github.com/MetaCubeX/mihomo/releases/download/v1.19.11/mihomo-linux-amd64-go120-v1.19.11.gz
MIHOMO_URL="https://gh-proxy.com/github.com/MetaCubeX/mihomo/releases/download/v1.19.11/mihomo-linux-amd64-go120-v1.19.11.gz"
GEOX_BASE="https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release"

# 创建目录
mkdir -p "$MROOT"
echo "⬇️ 下载 Mihomo..."
wget -O "$MROOT/mihomo.gz" "$MIHOMO_URL"
gzip -d "$MROOT/mihomo.gz"
chmod +x "$BIN"
echo "🌐 下载 geox 数据..."
wget -O "$MROOT/geosite.dat" "$GEOX_BASE/geosite.dat"
wget -O "$MROOT/geoip.dat" "$GEOX_BASE/geoip.dat"
wget -O "$MROOT/country.mmdb" "$GEOX_BASE/country.mmdb"
wget -O "$MROOT/asn.mmdb" "$GEOX_BASE/GeoLite2-ASN.mmdb"

# 提示配置文件处理
echo "📁 Mihomo 安装完成，工作目录：$MROOT"
read -p "📥 是否从远程 URL 导入 config.yaml？(y/n): " choice
if [[ "$choice" == "y" ]]; then
    read -p "🔗 请输入 config.yaml 的下载链接: " config_url
    wget -O "$CONF" "$config_url"
    echo "✅ 已保存配置文件到 $CONF"
else
    echo "⚠️ 请将 config.yaml 手动放置到：$CONF"
fi
# 创建启动脚本
cat > "$RUN_SCRIPT" <<EOF
#!/bin/bash
DIR=\$(cd \$(dirname \$0) && pwd)
\$DIR/mihomo -d \$DIR
EOF
chmod +x "$RUN_SCRIPT"
echo ""
echo "✅ 安装完毕"
echo "👉 请将你的配置文件命名为 config.yaml 放入 $MROOT"
echo "🚀 启动：运行 $RUN_SCRIPT"
