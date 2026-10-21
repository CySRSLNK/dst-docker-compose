#!/bin/bash

# 定义 screen 会话的名称，应与 begin 脚本中一致
SCREEN_NAME="dst"

# 检查指定的 screen 会话是否存在
if screen -list | grep -q "$SCREEN_NAME"; then
    # 会话存在，则结束它
    screen -S "$SCREEN_NAME" -X quit
    echo "Screen 会话 '$SCREEN_NAME' 已结束。"
else
    echo "错误：未找到名为 '$SCREEN_NAME' 的 screen 会话。"
    exit 1
fi
