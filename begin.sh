#!/bin/bash
# 定义screen会话名称
SCREEN_NAME="dst"

# 检查是否已存在同名会话，避免冲突
if screen -list | grep -q "$SCREEN_NAME"; then
    echo "错误：screen会话 '$SCREEN_NAME' 已存在。请先结束它或使用其他名称。"
    exit 1
fi

# 创建detached模式的screen会话[1,3](@ref)
screen -dmS "$SCREEN_NAME"
echo "已创建screen会话：$SCREEN_NAME"

# 向screen会话发送命令：执行start.sh脚本[1,4](@ref)
# 使用stuff命令输入指令，并通过换行符（\n）执行
screen -x -S "$SCREEN_NAME" -p 0 -X stuff "./start.sh"
screen -x -S "$SCREEN_NAME" -p 0 -X stuff $'\n'
echo "已在会话中启动 ./start.sh"

# 提示用户如何查看或连接该会话
echo "Screen会话已在后台运行。查看命令：screen -r $SCREEN_NAME"
