#!/bin/bash

# clang-format 样式配置
# 假设项目根目录有 .clang-format 文件，clang-format 会自动加载
# 如果没有 .clang-format 文件，可以通过 --style 参数指定样式，例如：
# CLANG_FORMAT_STYLE="--style=LLVM"
CLANG_FORMAT_STYLE=""

# 要格式化的文件类型
FILE_TYPE='.*\.(h|hpp|hrp|c|cpp)$'
# 包含的目录（必须包含这些目录之一）
INCLUDE_KEY='^src/|^include/|^test/'
# 排除的目录或文件
EXCLUDE_KEY='^externals/'
FILE_LIST=''
CLANG_FORMAT="/usr/bin/clang-format"

FORMAT_MODE=$1

case $FORMAT_MODE in
all)
    # 格式化 Git 仓库中的所有源码文件
    # 必须包含 INCLUDE_KEY 且不包含 EXCLUDE_KEY
    FILE_LIST=$(git ls-tree -r --name-only HEAD | grep -E "$INCLUDE_KEY" | grep -Ev "$EXCLUDE_KEY" | grep -E "$FILE_TYPE")
    ;;
inc)
    # 格式化本地新增和修改的源码文件
    # 必须包含 INCLUDE_KEY 且不包含 EXCLUDE_KEY
    FILE_LIST=$(git status -s | awk '{print $2}' | grep -E "$INCLUDE_KEY" | grep -Ev "$EXCLUDE_KEY" | grep -E "$FILE_TYPE")
    ;;
*)
    # 格式化命令行传入的文件
    # 必须包含 INCLUDE_KEY 且不包含 EXCLUDE_KEY
    FILE_LIST=""
    for file in "$@"; do
        if echo "$file" | grep -E "$INCLUDE_KEY" >/dev/null && echo "$file" | grep -Ev "$EXCLUDE_KEY" >/dev/null && echo "$file" | grep -E "$FILE_TYPE" >/dev/null; then
            FILE_LIST="$FILE_LIST $file"
        fi
    done
    FORMAT_MODE='cmd'
    ;;
esac

echo "Start Formatting"
echo "Format Mode: $FORMAT_MODE"
formatted=0
unchanged=0
error=0
for f in $FILE_LIST
do
    if [ -e "$f" ]
    then
        # 使用 clang-format --dry-run 检查文件是否需要格式化
        $CLANG_FORMAT --dry-run --Werror $CLANG_FORMAT_STYLE "$f" >/dev/null 2>&1
        ret=$?

        if [ $ret -eq 0 ]; then
            # 文件无需格式化
            echo "Unchanged  $f"
            unchanged=$((unchanged + 1))
        else
            # 文件需要格式化，执行格式化操作
            $CLANG_FORMAT -i $CLANG_FORMAT_STYLE "$f"
            if [ $? -eq 0 ]; then
                echo "Formatted  $f"
                formatted=$((formatted + 1))
            else
                echo "Error      $f"
                error=$((error + 1))
            fi
        fi
    else
        echo "Error      $f (file not found)"
        error=$((error + 1))
    fi
done

echo "Formatted: $formatted, Unchanged: $unchanged, Error: $error"
echo "End Of Formatting"