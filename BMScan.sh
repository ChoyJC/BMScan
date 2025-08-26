#!/bin/bash
source logger.sh

# 使用说明: ./BMScan.sh [目录路径] [关键词文件] [输出文件(可选)]

# 全局变量
HAS_TEXTUTIL=0

# 检查依赖工具
function check_dependencies() {
    # mac环境下使用默认安装的textutil来把doc文件转为txt进行检测
    # linux环境下没有默认安装textutil 对于doc文件提示用户自行检查
    if command -v textutil &> /dev/null; then
        HAS_TEXTUTIL=1
        $(logger "LOG" "检测到textutil依赖")
    else
        $(logger "ERROR" "未检测到textutil依赖")
        $(logger "ERROR" "  MacOS: brew install textutil")
    fi

    # 检测unzip 用于解压Office文档来检测其中文本
    if command -v unzip &> /dev/null; then
        $(logger "LOG" "检测到unzip依赖")
    else
        $(logger "ERROR" "未检测到unzip依赖")
        $(logger "ERROR" "  MacOS: brew install unzip")
        $(logger "ERROR" "  Ubuntu/Debian: sudo apt install unzip")
        $(logger "ERROR" "  CentOS/RHEL: sudo yum install unzip")
        exit 1
    fi
    
    # 检测pdftotext 用于处理pdf文件
    if command -v pdftotext &> /dev/null; then
        $(logger "LOG" "检测到pdftotext依赖")
    else
        $(logger "ERROR" "需要pdftotext工具处理PDF文件")
        $(logger "ERROR" "  macOS: brew install poppler")
        $(logger "ERROR" "  Ubuntu/Debian: sudo apt install poppler-utils")
        $(logger "ERROR" "  CentOS/RHEL: sudo yum install poppler-utils")
        exit 1
    fi
}

# 搜索XML内容 (用于Office文档)
function check_xml_content() {
    local file="$1"
    shift
    local keywords=("$@")
    local tmp_dir=$(mktemp -d)
    local matches=()
    
    # 解压Office文档
    if unzip -qq "$file" -d "$tmp_dir"; then
        # 搜索所有XML文件
        while IFS= read -r -d $'\0' xml_file; do
            for keyword in "${keywords[@]}"; do
                # 在XML文件中搜索关键词（忽略标签）
                if grep -q -i -F -- "$keyword" "$xml_file"; then
                    matches+=("$keyword")
                fi
            done
        done < <(find "$tmp_dir" -type f -name "*.xml" -print0)
    fi
    
    # 清理临时文件
    rm -rf "$tmp_dir"
    
    # 返回匹配的关键词
    if [ ${#matches[@]} -gt 0 ]; then
        printf "%s\n" "${matches[@]}"
        return 0
    else 
        return 1
    fi
}

# 提取关键词列表
function read_keywords() {
    local keyword_file="$1"
    if [ ! -f "$keyword_file" ]; then
        $(logger "ERROR" "关键词文件不存在: $keyword_file")
        exit 1
    fi
    
    # 过滤空行和注释
    grep -v '^#\|^\s*$' "$keyword_file" | while IFS= read -r keyword; do
        printf "%s\n" "$keyword"
    done
}

# 处理压缩文件
function process_archive() {
    local file="$1"
    shift
    local keywords=("$@")
    local matches=()
    
    # 创建临时目录
    local tmp_dir=$(mktemp -d)
    local found_matches=0
    local result=""

    # 根据文件类型解压
    case "$file" in
        *.zip)
            unzip -qq "$file" -d "$tmp_dir" 2>/dev/null
            ;;
        *.tar)
            tar -xf "$file" -C "$tmp_dir" 2>/dev/null
            ;;
        *.tar.gz|*.tgz)
            tar -xzf "$file" -C "$tmp_dir" 2>/dev/null
            ;;
        *.tar.bz2)
            tar -xjf "$file" -C "$tmp_dir" 2>/dev/null
            ;;
        # *.7z)
            # if command -v 7z &> /dev/null; then
            #     7z x "$file" -o"$tmp_dir" >/dev/null 2>&1
            # else
            #     $(logger "WARN" "未安装7z，跳过: $file")
            #     rm -rf "$tmp_dir"
            #     return 1
            # fi
            # ;;
        *)
            $(logger "WARN" "不支持的压缩格式: $file")
            rm -rf "$tmp_dir"
            return 1
            ;;
    esac
    
    # 检查是否解压成功
    if [ ! -d "$tmp_dir" ] || [ -z "$(ls -A "$tmp_dir")" ]; then
        rm -rf "$tmp_dir"
        return 1
    fi
    
    # 处理解压后的文件
    while IFS= read -r -d $'\0' inner_file; do

        # 跳过__MACOSX目录
        if [[ "$inner_file" == *"__MACOSX"* ]]; then
            continue  
        fi

        # 处理压缩包内的文件
        # 文件名匹配
        inner_filename_matches=()
        for keyword in "${keywords[@]}"; do
            if [[ "${inner_file##*/}" =~ $keyword ]]; then
                inner_filename_matches+=("$keyword")
            fi
        done
        
        # 文件内容匹配
        inner_content_matches=()
        # 跳过压缩包内的压缩文件
        if [[ ! "$inner_file" =~ \.(zip|tar|gz|bz2|7z)$ ]]; then
            if content_results=$(check_content "$inner_file" "${keywords[@]}"); then
                while IFS= read -r match; do
                    inner_content_matches+=("$match")
                done <<< "$content_results"
            fi
        fi

        # 输出匹配结果
        if [ ${#inner_filename_matches[@]} -gt 0 ] || [ ${#inner_content_matches[@]} -gt 0 ]; then
            # 获取相对路径
            local rel_path="${inner_file#$tmp_dir/}"
            result+="  └─ 文件: $rel_path\n"
            if [ ${#inner_filename_matches[@]} -gt 0 ]; then
                result+="    ├─ 文件名匹配: ${inner_filename_matches[*]}\n"
            fi
            if [ ${#inner_content_matches[@]} -gt 0 ]; then
                result+="    └─ 内容匹配: ${inner_content_matches[*]}\n"
            fi
            found_matches=1
        fi

    done < <(find "$tmp_dir" -type f -print0)
    
    # 清理临时目录
    rm -rf "$tmp_dir"
    
    # 返回结果
    if [ "$found_matches" -eq 1 ]; then
        printf "%b" "$result"
        return 0
    else
        return 1
    fi
}

# 检查文件内容
function check_content() {
    local file="$1"
    local keywords=("${@:2}")
    local matches=()
    
    if [[ "$file" == *"__MACOSX"* ]]; then
        continue  
    fi

    # 检查是否为压缩文件
    if [[ "$file" =~ \.(zip|tar|gz|bz2|7z)$ ]]; then
        if archive_results=$(process_archive "$file" "${keywords[@]}"); then
            matches+=("$archive_results")
        fi
    else
        # 常规文件处理
        case "$file" in
            *.txt|*.xml|*.csv)
                # 文本文件
                # csv文件在win和mac下编码不同 这里只检查mac下的utf-8格式编码
                for keyword in "${keywords[@]}"; do
                    if grep -q -i -F -- "$keyword" "$file"; then
                        matches+=("$keyword")
                    fi
                done
                ;;
            *.docx|*.pptx|*.xlsx)
                # Office文档处理
                if content_results=$(check_xml_content "$file" "${keywords[@]}"); then
                    # 兼容macOS的数组填充
                    while IFS= read -r match; do
                        matches+=("$match")
                    done <<< "$content_results"
                fi
                ;;
            *.doc)
                # 旧版Office文档处理
                if [ "$HAS_TEXTUTIL" -eq 1 ]; then
                    local temp_txt=$(mktemp)
                    textutil -convert txt -output "$temp_txt" "$file" >/dev/null 2>&1
                    for keyword in "${keywords[@]}"; do
                        if grep -q -i -F -- "$keyword" "$temp_txt"; then
                            matches+=("$keyword")
                        fi
                    done
                    rm -f "$temp_txt"
                else
                    echo "[.doc|.ppt|.xls文件需人工检查]" 
                    return 0
                fi
                ;;
            *.ppt|*.xls)
                    echo "[.doc|.ppt|.xls文件需人工检查]" 
                    return 0
                ;;
            *.pages|*.numbers|*.key)
                # Mac iWork文件处理
                ;;
            *.pdf)
                # PDF转文本搜索
                local temp_txt=$(mktemp)
                pdftotext -q "$file" "$temp_txt"
                for keyword in "${keywords[@]}"; do
                    if grep -q -i -F -- "$keyword" "$temp_txt"; then
                        matches+=("$keyword")
                    fi
                done
                rm -f "$temp_txt"
                ;;
            *.wps|*.et|*.dps)
            # WPS文件压缩方式未知，没什么人用，暂不支持
                ;;
        esac
    fi
    
    # 返回匹配的关键词
    if [ ${#matches[@]} -gt 0 ]; then
        printf "%s\n" "${matches[@]}"
        return 0
    else
        return 1
    fi
}

# 主函数
function scan_files() {
    local target_dir="$1"
    local keyword_file="$2"
    local output_file="${3:-}"
    local number=1
    
    # 设置输出目标
    if [ -n "$output_file" ]; then
        exec 3>"$output_file"
    else
        exec 3>&1
    fi
    
    # 读取关键词到数组
    $(logger "LOG" "读取关键词文件：$keyword_file")
    keywords=()
    while IFS= read -r keyword; do
        keywords+=("$keyword")
    done < <(read_keywords "$keyword_file")
    
    if [ ${#keywords[@]} -eq 0 ]; then
        $(logger "ERROR" "未找到有效关键词")
        return 1
    fi
    
    # 构建find命令
    $(logger "LOG" "当前检查文件类型： *.txt|*.csv|*.docx|*.xlsx|*.pptx|*.pdf|")
    find "$target_dir" -type f \( \
        -iname "*.txt" -o \
        -iname "*.csv" -o \
        -iname "*.docx" -o \
        -iname "*.xlsx" -o \
        -iname "*.pptx" -o \
        -iname "*.ppt" -o \
        -iname "*.xls" -o \
        -iname "*.doc" -o \
        -iname "*.pdf" -o \
        -iname "*.zip" -o \
        -iname "*.tar" -o \
        -iname "*.tar.gz" -o \
        -iname "*.tgz" -o \
        -iname "*.tar.bz2" -o \
        -iname "*.7z" \
    \) -print0 | while IFS= read -r -d $'\0' file; do

        # 跳过__MACOSX目录
        if [[ "$file" == *"__MACOSX"* ]]; then
            continue  
        fi
        
        # 检查文件名
        $(logger "LOG" "检查文件: $file")
        filename_matches=()
        for keyword in "${keywords[@]}"; do
            if [[ "${file##*/}" =~ $keyword ]]; then
                filename_matches+=("$keyword")
            fi
        done
        
        # 检查文件内容
        content_matches=()
        if content_results=$(check_content "$file" "${keywords[@]}"); then
            while IFS= read -r match; do
                content_matches+=("$match")
            done <<< "$content_results"
        fi
        
        # 输出结果
        if ([ ${#filename_matches[@]} -gt 0 ] || [ ${#content_matches[@]} -gt 0 ]); then
            echo "$number 文件: $file" >&3
            if [ ${#filename_matches[@]} -gt 0 ]; then
                echo "  ├─ 文件名匹配: ${filename_matches[*]}" >&3
            fi
            if [ ${#content_matches[@]} -gt 0 ]; then
                # 检查是否为压缩文件结果
                if [[ "$file" =~ \.(zip|tar|gz|tgz|bz2)$ ]]; then
                    echo "  └─ 压缩包内容匹配:" >&3
                    for line in "${content_matches[@]}"; do
                        echo "      $line" >&3
                    done
                else
                    echo "  └─ 内容匹配: ${content_matches[*]}" >&3
                fi
            fi
            echo "---" >&3
            let number++
        fi
    done
    $(logger "LOG" "检查完成，结果保存至 $output_file")
}


# 主执行流程
if [ $# -lt 2 ]; then
    echo "version 1.0.0"
    echo "Usage: $0 [目录路径] [关键词文件] [输出文件(可选)]"
    echo "Example: $0 scan_directory keyword.txt export.txt"
    exit 1
fi

target_directory="$1"
keyword_file="$2"
output_file="${3:-}"

check_dependencies
scan_files "$target_directory" "$keyword_file" "$output_file"