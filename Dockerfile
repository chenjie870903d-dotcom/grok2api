# 构建阶段：安装依赖并编译
FROM python:3.13-alpine AS builder

# 基础环境变量配置
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TZ=Asia/Shanghai \
    UV_PROJECT_ENVIRONMENT=/opt/venv \
    # 明确 uv 缓存路径，便于清理
    UV_CACHE_DIR=/tmp/uv-cache

# 确保 venv 和 uv 的 bin 目录在 PATH 最前
ENV PATH="$UV_PROJECT_ENVIRONMENT/bin:$PATH"

# 安装构建依赖 + 时区配置（确保时区生效）
RUN set -eux; \
    apk add --no-cache \
        tzdata \
        ca-certificates \
        build-base \
        linux-headers \
        libffi-dev \
        openssl-dev \
        curl-dev \
        cargo \
        rust; \
    # 强制设置时区，避免容器时区异常
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime; \
    echo "Asia/Shanghai" > /etc/timezone; \
    # 升级 pip 避免安装 uv 时兼容问题
    pip install --no-cache-dir --upgrade pip; \
    # 安装 uv（避免依赖 ghcr.io，保留 pip 方式）
    pip install --no-cache-dir uv; \
    # 创建缓存目录（避免 uv 运行时报错）
    mkdir -p $UV_CACHE_DIR; \
    # 清理临时文件
    rm -rf /root/.cache/pip

WORKDIR /app

# 复制依赖文件（利用 Docker 层缓存，依赖不变则不重新构建）
COPY pyproject.toml uv.lock ./

# 安装项目依赖 + 深度清理无用文件
RUN set -eux; \
    # 同步依赖（冻结版本、不装开发依赖、不安装项目本身）
    uv sync --frozen --no-dev --no-install-project; \
    # 清理 pycache、编译缓存
    find /opt/venv -type d -name "__pycache__" -exec rm -rf {} +; \
    find /opt/venv -type f -name "*.pyc" -delete; \
    # 清理测试相关目录
    find /opt/venv -type d -name "tests" -o -name "test" -o -name "testing" | xargs rm -rf; \
    # 剥离二进制文件符号表（减小体积，alpine 兼容）
    find /opt/venv -type f -name "*.so" -exec strip --strip-unneeded {} + || true; \
    # 彻底清理 uv 缓存和 pip 缓存
    rm -rf $UV_CACHE_DIR /root/.cache/uv /root/.cache/pip; \
    # 清理构建依赖的临时文件
    apk del build-base linux-headers cargo rust; \
    rm -rf /var/cache/apk/*

# 运行阶段：仅保留运行时依赖和代码
FROM python:3.13-alpine

# 基础环境变量
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TZ=Asia/Shanghai \
    VIRTUAL_ENV=/opt/venv \
    SERVER_HOST=0.0.0.0 \
    SERVER_PORT=8000 \
    SERVER_WORKERS=1

ENV PATH="$VIRTUAL_ENV/bin:$PATH"

# 安装运行时依赖 + 时区配置
RUN set -eux; \
    apk add --no-cache \
        tzdata \
        ca-certificates \
        libffi \
        openssl \
        libgcc \
        libstdc++ \
        libcurl; \
    # 强制设置时区
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime; \
    echo "Asia/Shanghai" > /etc/timezone; \
    # 创建非 root 用户（提升安全性，避免 root 运行）
    addgroup -g 1001 -S appgroup; \
    adduser -S appuser -u 1001 -G appgroup -h /app -s /sbin/nologin; \
    # 清理 apk 缓存
    rm -rf /var/cache/apk/*

WORKDIR /app

# 从构建阶段复制 venv（仅保留运行时依赖）
COPY --from=builder /opt/venv /opt/venv

# 复制项目代码（按变更频率排序，利用缓存）
COPY config.defaults.toml ./
COPY main.py ./
COPY app ./app
COPY _public ./_public
COPY scripts ./scripts

# 创建数据/日志目录 + 权限配置（非 root 用户可写）
RUN set -eux; \
    mkdir -p /app/data /app/logs; \
    chmod +x /app/scripts/entrypoint.sh; \
    # 目录权限交给非 root 用户
    chown -R appuser:appgroup /app; \
    chmod -R 755 /app/data /app/logs

# 切换到非 root 用户运行（核心安全优化）
USER appuser

# 暴露端口
EXPOSE 8000

# Entrypoint 和 CMD 规范写法（避免 sh -c 嵌套，提升稳定性）
ENTRYPOINT ["/app/scripts/entrypoint.sh"]
CMD ["granian", "--interface", "asgi", "--host", "${SERVER_HOST}", "--port", "${SERVER_PORT}", "--workers", "${SERVER_WORKERS}", "main:app"]
