#!/bin/bash
# Assropic 验证脚本入口。
cd "$(dirname "$0")" || exit 1
exec ./verify.sh
