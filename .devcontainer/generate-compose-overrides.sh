#!/bin/sh
# ============================================================================
# Docker-outside-of-Docker (DooD) bind mount 路径修正脚本
# ============================================================================
# 问题：VS Code devcontainer 将宿主机项目路径（如 /home/user/MaiBot）挂载到
#       容器内的 ${containerWorkspaceFolder}。当 docker compose 在容器内执行时，
#       Docker Compose 将相对路径 ./ 解析为容器内路径，发送给宿主机 Docker 守护进程。
#       守护进程在宿主机上找不到同名路径，自动创建空目录，导致数据"消失"。
#
# 解决：从 /proc/1/mountinfo 提取宿主机真实项目路径，生成两个 compose 覆写文件：
#       1. docker-compose.dood-pathfix.yml — 仅修正路径，用于部署到稳定（生产）实例
#       2. docker-compose.devcontainer.yml — 路径修正 + 完整隔离，用于测试实例
#       配合 .devcontainer/maibot-deploy 脚本选择目标。
#
# 兼容性：devcontainer 始终运行 Linux，本脚本依赖 /proc/1/mountinfo（Linux 内核接口）。
#         Windows/macOS 宿主机的 Docker Desktop 会自动处理路径转换。
# ============================================================================

set -eu

WORKSPACE_FOLDER="${1:-/workspaces/MaiBot}"
PATHFIX_FILE="${WORKSPACE_FOLDER}/docker-compose.dood-pathfix.yml"
DEV_OVERRIDE_FILE="${WORKSPACE_FOLDER}/docker-compose.devcontainer.yml"

# 开发实例使用独立的配置和数据目录，避免与生产实例冲突
# 本地操作（cp/mkdir）使用容器内路径 WORKSPACE_FOLDER，docker compose 卷映射使用宿主机路径 HOST_ROOT
DEV_CONFIG_LOCAL="${WORKSPACE_FOLDER}/docker-config-dev"
DEV_DATA_LOCAL="${WORKSPACE_FOLDER}/data-dev"

# 若开发配置目录不存在，从生产配置模板复制一份
if [ ! -d "$DEV_CONFIG_LOCAL" ]; then
    echo "[devcontainer] 首次创建开发配置目录: ${DEV_CONFIG_LOCAL}"
    cp -a "${WORKSPACE_FOLDER}/docker-config" "$DEV_CONFIG_LOCAL"
fi

# 确保开发数据目录存在
mkdir -p "${DEV_DATA_LOCAL}/MaiMBot" "${DEV_DATA_LOCAL}/qq"

# 从 /proc/1/mountinfo 提取宿主机上对应 workspace 的真实路径
# mountinfo 格式: mount_id parent_id major:minor root mount_point options - fs_type source super_options
# 我们需要第5列(mount_point)匹配 workspace，取第4列(root)为宿主机路径
HOST_ROOT=$(awk -v ws="$WORKSPACE_FOLDER" '$5 == ws {print $4; exit}' /proc/1/mountinfo)

if [ -z "$HOST_ROOT" ]; then
    echo "[devcontainer] ⚠ 未能从 /proc/1/mountinfo 检测到 ${WORKSPACE_FOLDER} 的宿主机路径"
    echo "[devcontainer] docker compose 的 bind mount 可能指向错误位置，数据不会持久化"
    exit 0
fi

echo "[devcontainer] 检测到宿主机项目路径: ${HOST_ROOT}"

# ============================================================================
# 文件 1：docker-compose.dood-pathfix.yml — 仅修正 DooD 路径
# ============================================================================
cat > "$PATHFIX_FILE" << 'PATHFIX_EOF'
# 此文件由 .devcontainer/generate-compose-overrides.sh 自动生成
# 仅修正 Docker-outside-of-Docker 场景下的 bind mount 宿主机路径
# 不修改端口、容器名、数据目录，用于部署到稳定（生产）实例
# 请勿手动编辑，删除后将在下次容器创建时重新生成
services:
  core:
    volumes:
      - __HOST_ROOT__/docker-config/mmc:/MaiMBot/config
      - __HOST_ROOT__/data/MaiMBot:/MaiMBot/data
      - __HOST_ROOT__/data/MaiMBot/emoji:/data/emoji
      - __HOST_ROOT__/data/MaiMBot/plugins:/MaiMBot/plugins
      - __HOST_ROOT__/data/MaiMBot/logs:/MaiMBot/logs
      - __HOST_ROOT__/depends-data:/MaiMBot/depends-data
  napcat:
    volumes:
      - __HOST_ROOT__/docker-config/napcat:/app/napcat/config
      - __HOST_ROOT__/data/qq:/app/.config/QQ
      - __HOST_ROOT__/data/MaiMBot:/MaiMBot/data
  sqlite-web:
    volumes:
      - __HOST_ROOT__/data/MaiMBot:/data/MaiMBot
PATHFIX_EOF
# 替换占位符为实际宿主机路径
sed -i "s|__HOST_ROOT__|${HOST_ROOT}|g" "$PATHFIX_FILE"

echo "[devcontainer] ✓ 已生成 ${PATHFIX_FILE}（仅路径修正）"

# ============================================================================
# 文件 2：docker-compose.devcontainer.yml — 路径修正 + 测试实例完整隔离
# ============================================================================
cat > "$DEV_OVERRIDE_FILE" << 'DEV_EOF'
# 此文件由 .devcontainer/generate-compose-overrides.sh 自动生成
# 修复 DooD 路径 + 隔离端口/容器名/数据目录，使开发容器内以独立测试实例运行
# 通过 .devcontainer/maibot-deploy develop 使用；容器外 docker compose 不受影响
# 请勿手动编辑，删除后将在下次容器创建时重新生成
services:
  core:
    container_name: maim-bot-core-dev
    ports:
      - "18002:8001"
    volumes:
      - __HOST_ROOT__/docker-config-dev/mmc:/MaiMBot/config
      - __HOST_ROOT__/data-dev/MaiMBot:/MaiMBot/data
      - __HOST_ROOT__/data-dev/MaiMBot/emoji:/data/emoji
      - __HOST_ROOT__/data-dev/MaiMBot/plugins:/MaiMBot/plugins
      - __HOST_ROOT__/data-dev/MaiMBot/logs:/MaiMBot/logs
      - __HOST_ROOT__/depends-data:/MaiMBot/depends-data
  napcat:
    container_name: maim-bot-napcat-dev
    ports:
      - "16100:6099"
    volumes:
      - __HOST_ROOT__/docker-config-dev/napcat:/app/napcat/config
      - __HOST_ROOT__/data-dev/qq:/app/.config/QQ
      - __HOST_ROOT__/data-dev/MaiMBot:/MaiMBot/data
  sqlite-web:
    container_name: sqlite-web-dev
    ports:
      - "18121:8080"
    volumes:
      - __HOST_ROOT__/data-dev/MaiMBot:/data/MaiMBot
DEV_EOF
# 替换占位符为实际宿主机路径
sed -i "s|__HOST_ROOT__|${HOST_ROOT}|g" "$DEV_OVERRIDE_FILE"

echo "[devcontainer] ✓ 已生成 ${DEV_OVERRIDE_FILE}（测试实例完整隔离）"
