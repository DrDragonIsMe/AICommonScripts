#!/bin/bash
set -euo pipefail

BACKUP_DIR="$HOME/.sys_mirrors_backup_$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"

echo "============================================================="
echo "          Ubuntu 开发环境一键配置（含Java全栈）"
echo "          支持：setup 安装 ｜ rollback 回滚"
echo "============================================================="

# ------------------------------
# 回滚模式
# ------------------------------
if [ "$1" = "rollback" ]; then
  echo -e "\n[回滚] 恢复所有配置到原始状态..."

  # APT
  if [ -f "$BACKUP_DIR/sources.list" ]; then
    sudo cp -f "$BACKUP_DIR/sources.list" /etc/apt/sources.list
    echo "✅ APT 源已回滚"
  fi

  # pip
  if [ -f "$BACKUP_DIR/pip.conf.bak" ]; then
    mkdir -p ~/.pip
    cp -f "$BACKUP_DIR/pip.conf.bak" ~/.pip/pip.conf 2>/dev/null
    echo "✅ pip 源已回滚"
  fi

  # conda
  if [ -f "$BACKUP_DIR/condarc.bak" ]; then
    cp -f "$BACKUP_DIR/condarc.bak" ~/.condarc 2>/dev/null
    echo "✅ conda 源已回滚"
  fi

  # docker
  if [ -f "$BACKUP_DIR/daemon.json.bak" ]; then
    sudo cp -f "$BACKUP_DIR/daemon.json.bak" /etc/docker/daemon.json 2>/dev/null
    sudo systemctl daemon-reload
    sudo systemctl restart docker
    echo "✅ Docker 镜像已回滚"
  fi

  # maven
  if [ -d "$BACKUP_DIR/maven" ]; then
    mkdir -p ~/.m2
    cp -f "$BACKUP_DIR/maven/settings.xml" ~/.m2/settings.xml 2>/dev/null
    echo "✅ Maven 镜像已回滚"
  fi

  # gradle
  if [ -d "$BACKUP_DIR/gradle" ]; then
    mkdir -p ~/.gradle
    cp -f "$BACKUP_DIR/gradle/init.gradle" ~/.gradle/init.gradle 2>/dev/null
    echo "✅ Gradle 镜像已回滚"
  fi

  # npm
  npm config delete registry 2>/dev/null || true
  echo "✅ NPM 镜像已重置"

  echo -e "\n🎉 全部回滚完成！"
  exit 0
fi

if [ "$1" != "setup" ]; then
  echo "用法："
  echo "  $0 setup       安装开发环境 + 配置全国内镜像"
  echo "  $0 rollback    一键回滚所有配置"
  exit 1
fi

# ==============================
# 1. APT 清华源
# ==============================
echo -e "\n[1/10] 备份并更换 APT 为清华源..."
ARCH=$(dpkg --print-architecture)
if [ "$ARCH" = "arm64" ]; then
  UBUNTU_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports"
else
  UBUNTU_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/ubuntu"
fi

[ -f /etc/apt/sources.list ] && sudo cp /etc/apt/sources.list "$BACKUP_DIR/sources.list"

sudo tee /etc/apt/sources.list >/dev/null <<EOF
deb ${UBUNTU_MIRROR}/ noble main restricted universe multiverse
deb ${UBUNTU_MIRROR}/ noble-updates main restricted universe multiverse
deb ${UBUNTU_MIRROR}/ noble-backports main restricted universe multiverse
deb ${UBUNTU_MIRROR}/ noble-security main restricted universe multiverse
EOF

sudo apt update -y
sudo apt upgrade -y

# ==============================
# 2. 基础工具
# ==============================
echo -e "\n[2/10] 安装基础开发工具..."
sudo apt install -y \
  git curl wget vim zsh tmux htop iotop iftop \
  build-essential libssl-dev libffi-dev python3-dev \
  python3-pip python3-venv net-tools lsof jq \
  ca-certificates gnupg lsb-release unzip zip

# ==============================
# 3. pip 清华源
# ==============================
echo -e "\n[3/10] 配置 pip 清华源..."
mkdir -p ~/.pip
[ -f ~/.pip/pip.conf ] && cp ~/.pip/pip.conf "$BACKUP_DIR/pip.conf.bak"

tee ~/.pip/pip.conf >/dev/null <<EOF
[global]
index-url = https://pypi.tuna.tsinghua.edu.cn/simple
trusted-host = pypi.tuna.tsinghua.edu.cn
EOF

# ==============================
# 4. Docker + 国内镜像
# ==============================
echo -e "\n[4/10] 安装 Docker 并配置国内镜像..."
# Backup and remove any pre-existing Docker APT sources to avoid conflicts
for f in /etc/apt/sources.list.d/docker*.list; do
  [ -f "$f" ] && sudo cp "$f" "$BACKUP_DIR/$(basename "$f").bak" && sudo rm -f "$f"
done

curl -fsSL https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/docker.gpg

echo \
  "deb [arch=${ARCH} signed-by=/etc/apt/trusted.gpg.d/docker.gpg] https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt update -y
sudo apt install -y docker-ce docker-ce-cli containerd.io

[ -f /etc/docker/daemon.json ] && sudo cp /etc/docker/daemon.json "$BACKUP_DIR/daemon.json.bak"
sudo tee /etc/docker/daemon.json >/dev/null <<EOF
{
  "registry-mirrors": [
    "https://docker.mirrors.ustc.edu.cn",
    "https://hub-mirror.c.163.com",
    "https://mirror.baidubce.com"
  ]
}
EOF

sudo systemctl daemon-reload
sudo systemctl restart docker
sudo usermod -aG docker "$USER"

# ==============================
# 5. Docker Compose
# ==============================
echo -e "\n[5/10] 安装 Docker Compose..."
sudo apt install -y docker-compose-plugin

# ==============================
# 6. Conda 清华源
# ==============================
echo -e "\n[6/10] 配置 Conda 清华源..."
[ -f ~/.condarc ] && cp ~/.condarc "$BACKUP_DIR/condarc.bak"

tee ~/.condarc >/dev/null <<EOF
channels:
  - defaults
show_channel_urls: true
default_channels:
  - https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main
  - https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/r
  - https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/msys2
custom_channels:
  conda-forge: https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud
  pytorch: https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud
  nvidia: https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud
EOF

# ==============================
# 7. Node.js + npm 淘宝源
# ==============================
echo -e "\n[7/10] 安装 Node.js v22 + 配置 npm 镜像..."
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs
npm config set registry https://registry.npmmirror.com

# ==============================
# 8. Java 17 + Maven
# ==============================
echo -e "\n[8/10] 安装 OpenJDK 17 + Maven..."
sudo apt install -y openjdk-17-jdk maven

# Maven 阿里云镜像
echo -e "\n配置 Maven 阿里云镜像..."
mkdir -p ~/.m2
mkdir -p "$BACKUP_DIR/maven"
[ -f ~/.m2/settings.xml ] && cp ~/.m2/settings.xml "$BACKUP_DIR/maven/settings.xml"

tee ~/.m2/settings.xml >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 http://maven.apache.org/xsd/settings-1.0.0.xsd">
  <mirrors>
    <mirror>
      <id>aliyunmaven</id>
      <mirrorOf>central</mirrorOf>
      <url>https://maven.aliyun.com/repository/public</url>
    </mirror>
  </mirrors>
</settings>
EOF

# ==============================
# 9. Gradle 阿里云镜像
# ==============================
echo -e "\n[9/10] 配置 Gradle 阿里云镜像..."
mkdir -p ~/.gradle
mkdir -p "$BACKUP_DIR/gradle"
[ -f ~/.gradle/init.gradle ] && cp ~/.gradle/init.gradle "$BACKUP_DIR/gradle/init.gradle"

tee ~/.gradle/init.gradle >/dev/null <<EOF
allprojects {
    repositories {
        maven { url 'https://maven.aliyun.com/repository/public/' }
        maven { url 'https://maven.aliyun.com/repository/google/' }
        maven { url 'https://maven.aliyun.com/repository/gradle-plugin/' }
        mavenCentral()
    }
    buildscript {
        repositories {
            maven { url 'https://maven.aliyun.com/repository/public/' }
            maven { url 'https://maven.aliyun.com/repository/google/' }
            maven { url 'https://maven.aliyun.com/repository/gradle-plugin/' }
            mavenCentral()
        }
    }
}
EOF

# ==============================
# 10. Oh My Zsh
# ==============================
echo -e "\n[10/10] 安装 Oh My Zsh..."
REMOTE=https://gitee.com/mirrors/oh-my-zsh.git sh -c "$(curl -fsSL https://gitee.com/mirrors/oh-my-zsh/raw/master/tools/install.sh)" "" --unattended || true

# ==============================
# 完成
# ==============================
echo -e "\n============================================================="
echo "🎉 开发环境安装完成！"
echo "备份目录：$BACKUP_DIR"
echo "回滚命令： ./setup-dev-env.sh rollback"
echo ""
echo "已安装：Java17, Maven, Gradle, Docker, Node22, Python3, Git, Zsh..."
echo "已加速：APT/PIP/Docker/Maven/Gradle/NPM/Conda"
echo ""
echo "请重新登录使 Docker 权限生效："
echo "    su - \$USER"
echo "============================================================="
