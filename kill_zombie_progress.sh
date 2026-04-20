#!/bin/bash
echo "查找僵尸进程..."
zombies=$(ps -eo pid,ppid,stat,cmd | awk '$3 ~ /Z/ {print $1, $2}')

if [ -z "$zombies" ]; then
    echo "没有发现僵尸进程"
    exit 0
fi

echo "发现僵尸进程："
echo "$zombies"

echo "尝试向父进程发送 SIGCHLD..."
echo "$zombies" | while read -r pid ppid; do
    echo "僵尸 PID: $pid, 父进程 PPID: $ppid"
    kill -s SIGCHLD "$ppid" 2>/dev/null
done

sleep 2

# 检查是否还有残留
remaining=$(ps -eo pid,stat | awk '$2 ~ /Z/ {print $1}')
if [ -n "$remaining" ]; then
    echo "仍有残留，强制终止父进程："
    echo "$zombies" | awk '{print $2}' | sort -u | while read -r ppid; do
        echo "终止父进程 PPID: $ppid"
        kill -15 "$ppid" 2>/dev/null
    done
fi

