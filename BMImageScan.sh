#!/bin/bash
source logger.sh

# 使用 Tesseract OCR 检查图片关键词（支持压缩文件和文档中的图片）
# 使用说明: ./BMImageScan.sh [目录路径] [关键词文件] [输出文件(可选)]

# 全局变量
TESSERACT_LANGS="chi_sim+eng"  # 简体中文 + 英文

# 检查依赖工具
function check_dependencies() {
    # 需要tesseract-ocr进行识别
    if command -v tesseract &> /dev/null; then
        $(logger "LOG" "检测到tesseract依赖，启用检查工具")
        # 检查中文语言包是否安装
        if ! tesseract --list-langs | grep -q chi_sim; then
            $(logger "WARN" "未检测到中文语言包，识别精度可能受影响")
            $(logger "WARN" "  macOS: brew install tesseract-lang")
            $(logger "WARN" "  Ubuntu/Debian: sudo apt install tesseract-ocr-chi-sim")
        fi
    else
        $(logger "ERROR" "需要tesseract")
        $(logger "ERROR" "  macOS: brew install tesseract tesseract-lang")
        $(logger "ERROR" "  Ubuntu/Debian: sudo apt install tesseract-ocr tesseract-ocr-chi-sim")
        exit 1
    fi

    # 检测unzip用于解压Office文档和压缩文件
    if command -v unzip &> /dev/null; then
        $(logger "LOG" "检测到unzip依赖")
    else
        $(logger "ERROR" "需要unzip工具处理压缩文件")
        $(logger "ERROR" "  macOS: brew install unzip")
        $(logger "ERROR" "  Ubuntu/Debian: sudo apt install unzip")
        exit 1
    fi
    
    # 检测tar用于解压tar文件
    if command -v tar &> /dev/null; then
        $(logger "LOG" "检测到tar依赖")
    else
        $(logger "WARN" "未检测到tar命令，部分压缩格式可能无法处理")
    fi
    
    # 检测pdfimages用于提取PDF中的图片
    if command -v pdfimages &> /dev/null; then
        $(logger "LOG" "检测到pdfimages依赖")
    else
        $(logger "ERROR" "需要pdfimages工具处理PDF文件")
        $(logger "ERROR" "  macOS: brew install poppler")
        $(logger "ERROR" "  Ubuntu/Debian: sudo apt install poppler-utils")
        exit 1
    fi
}

# 提取关键词列表
function read_keywords() {
    local keyword_file="$1"
    if [ ! -f "$keyword_file" ]; then
        echo "[$(date "+%Y-%m-%d %H:%M:%S")]ERROR: 关键词文件不存在: $keyword_file" >&2
        exit 1
    fi
    
    # 过滤空行和注释
    grep -v '^#\|^\s*$' "$keyword_file" | while IFS= read -r keyword; do
        printf "%s\n" "$keyword"
    done
}

# OCR识别图片中的文字
function ocr_image() {
    local image_file="$1"
    shift
    local keywords=("$@")
    local matches=()
    
    # 创建临时文本文件
    local temp_txt=$(mktemp)
    
    # 使用Tesseract识别图片中的文字
    tesseract "$image_file" "$temp_txt" -l "$TESSERACT_LANGS" >/dev/null 2>&1
    
    # 检查识别出的文本
    if [ -f "${temp_txt}.txt" ]; then
        for keyword in "${keywords[@]}"; do
            # 在识别出的文本中搜索关键词
            if grep -q -i -F -- "$keyword" "${temp_txt}.txt" 2>/dev/null; then
                matches+=("$keyword")
            fi
        done
        # 删除产生的临时文件
        rm -f "${temp_txt}.txt"
    fi
    
    rm -f "$temp_txt"
    
    # 返回匹配的关键词
    if [ ${#matches[@]} -gt 0 ]; then
        printf "%s\n" "${matches[@]}"
        return 0
    else
        return 1
    fi
}

# 从Office文档中提取图片并检查
function check_office_images() {
    local file="$1"
    shift
    local keywords=("$@")
    local matches=()
    local tmp_dir=$(mktemp -d)
    
    # 解压Office文档
    if unzip -qq "$file" -d "$tmp_dir" 2>/dev/null; then
        # 根据文档类型确定图片位置
        local media_dir=""
        case "$file" in
            *.docx) media_dir="word/media" ;;
            *.pptx) media_dir="ppt/media" ;;
            *.xlsx) media_dir="xl/media" ;;
        esac
        
        # 查找图片文件
        if [ -d "$tmp_dir/$media_dir" ]; then
            while IFS= read -r -d $'\0' image_file; do
                # 检查图片内容
                if image_results=$(ocr_image "$image_file" "${keywords[@]}"); then
                    while IFS= read -r match; do
                        matches+=("$match")
                    done <<< "$image_results"
                fi
            done < <(find "$tmp_dir/$media_dir" -type f \( \
                -iname "*.jpg" -o \
                -iname "*.jpeg" -o \
                -iname "*.png" \
            \) -print0)
        fi
    fi
    
    # 清理临时目录
    rm -rf "$tmp_dir"
    
    # 返回匹配结果
    if [ ${#matches[@]} -gt 0 ]; then
        printf "%s\n" "${matches[@]}"
        return 0
    else
        return 1
    fi
}

# 从PDF中提取图片并检查
function check_pdf_images() {
    local file="$1"
    shift
    local keywords=("$@")
    local matches=()
    local tmp_dir=$(mktemp -d)
    local prefix="pdfimage"
    
    # 提取PDF中的图片
    pdfimages -png "$file" "$tmp_dir/$prefix" >/dev/null 2>&1
    
    # 检查提取的图片
    while IFS= read -r -d $'\0' image_file; do
        # 检查图片内容
        if image_results=$(ocr_image "$image_file" "${keywords[@]}"); then
            while IFS= read -r match; do
                matches+=("$match")
            done <<< "$image_results"
        fi
    done < <(find "$tmp_dir" -type f -name "${prefix}*.png" -print0)
    
    # 清理临时目录
    rm -rf "$tmp_dir"
    
    # 返回匹配结果
    if [ ${#matches[@]} -gt 0 ]; then
        printf "%s\n" "${matches[@]}"
        return 0
    else
        return 1
    fi
}

# 处理压缩文件中的内容
function process_archive() {
    local file="$1"
    shift
    local keywords=("$@")
    local matches=()
    local tmp_dir=$(mktemp -d)
    
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
        *)
            $(logger "WARN" "不支持的压缩格式: $file")
            rm -rf "$tmp_dir"
            return 1
            ;;
    esac
    
    # 检查解压是否成功
    if [ ! -d "$tmp_dir" ] || [ -z "$(ls -A "$tmp_dir")" ]; then
        rm -rf "$tmp_dir"
        return 1
    fi
    
    # 遍历解压后的文件
    while IFS= read -r -d $'\0' inner_file; do

        # 跳过__MACOSX目录
        if [[ "$inner_file" == *"__MACOSX"* ]]; then
            continue  
        fi
        
        # 跳过嵌套压缩包
        if [[ "$inner_file" =~ \.(zip|tar|gz|bz2|7z)$ ]]; then
            $(logger "LOG" "跳过嵌套压缩包: $inner_file")
            continue
        fi
        
        # 处理图片文件
        if [[ "$inner_file" =~ \.(jpg|jpeg|png|bmp|tiff|gif|webp)$ ]]; then
            if image_results=$(ocr_image "$inner_file" "${keywords[@]}"); then
                # 获取相对路径
                local rel_path="${inner_file#$tmp_dir/}"
                while IFS= read -r match; do
                    matches+=("$rel_path: $match")
                done <<< "$image_results"
            fi
        # 处理Office文档
        elif [[ "$inner_file" =~ \.(docx|xlsx|pptx)$ ]]; then
            if office_results=$(check_office_images "$inner_file" "${keywords[@]}"); then
                # 获取相对路径
                local rel_path="${inner_file#$tmp_dir/}"
                while IFS= read -r match; do
                    matches+=("$rel_path: $match")
                done <<< "$office_results"
            fi
        # 处理PDF文档
        elif [[ "$inner_file" =~ \.pdf$ ]]; then
            if pdf_results=$(check_pdf_images "$inner_file" "${keywords[@]}"); then
                # 获取相对路径
                local rel_path="${inner_file#$tmp_dir/}"
                while IFS= read -r match; do
                    matches+=("$rel_path: $match")
                done <<< "$pdf_results"
            fi
        fi
    done < <(find "$tmp_dir" -type f -print0)
    
    # 清理临时目录
    rm -rf "$tmp_dir"
    
    # 返回匹配结果
    if [ ${#matches[@]} -gt 0 ]; then
        printf "%s\n" "${matches[@]}"
        return 0
    else
        return 1
    fi
}

# 检查文件内容
function check_image_content() {
    local file="$1"
    shift
    local keywords=("$@")
    local matches=()
    
    case $file in
        *.jpg|*.png|*.jpeg)
            # 直接处理图片文件
            if image_results=$(ocr_image "$file" "${keywords[@]}"); then
                while IFS= read -r match; do
                    matches+=("$match")
                done <<< "$image_results"
            fi
            ;;
            
        *.pdf)
            # 处理PDF文件中的图片
            if pdf_results=$(check_pdf_images "$file" "${keywords[@]}"); then
                while IFS= read -r match; do
                    matches+=("$match")
                done <<< "$pdf_results"
            fi
            ;;
            
        *.docx|*.xlsx|*.pptx)
            # 处理Office文档中的图片
            if office_results=$(check_office_images "$file" "${keywords[@]}"); then
                while IFS= read -r match; do
                    matches+=("$match")
                done <<< "$office_results"
            fi
            ;;
            
        *.zip|*.tar|*.tar.gz|*.tgz|*.tar.bz2)
            # 处理压缩文件
            if archive_results=$(process_archive "$file" "${keywords[@]}"); then
                while IFS= read -r match; do
                    matches+=("$match")
                done <<< "$archive_results"
            fi
            ;;
    esac
    
    # 返回匹配的关键词
    if [ ${#matches[@]} -gt 0 ]; then
        printf "%s\n" "${matches[@]}"
        return 0
    else
        return 1
    fi
}

# 主扫描函数
function scan_images() {
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
    
    # 获取关键词文件的绝对路径用于比较
    abs_keyword_file=$(realpath "$keyword_file" 2>/dev/null || echo "$(cd "$(dirname "$keyword_file")"; pwd)/$(basename "$keyword_file")")
    
    # 支持的文件格式（增加压缩文件）
    find "$target_dir" -type f \( \
        -iname "*.jpg" -o \
        -iname "*.jpeg" -o \
        -iname "*.png" -o \
        -iname "*.bmp" -o \
        -iname "*.tiff" -o \
        -iname "*.tif" -o \
        -iname "*.gif" -o \
        -iname "*.pdf" -o \
        -iname "*.webp" -o \
        -iname "*.docx" -o \
        -iname "*.xlsx" -o \
        -iname "*.pptx" -o \
        -iname "*.zip" -o \
        -iname "*.tar" -o \
        -iname "*.tar.gz" -o \
        -iname "*.tgz" -o \
        -iname "*.tar.bz2" \
    \) -print0 | while IFS= read -r -d $'\0' file; do
        
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
        if content_results=$(check_image_content "$file" "${keywords[@]}"); then
            while IFS= read -r match; do
                content_matches+=("$match")
            done <<< "$content_results"
        fi
        
        # 输出结果
        if [ ${#filename_matches[@]} -gt 0 ] || [ ${#content_matches[@]} -gt 0 ]; then
            echo "$number 文件: $file" >&3
            if [ ${#filename_matches[@]} -gt 0 ]; then
                echo "  ├─ 文件名匹配: ${filename_matches[*]}" >&3
            fi
            if [ ${#content_matches[@]} -gt 0 ]; then
                # 检查是否为压缩文件结果
                if [[ "$file" =~ \.(zip|tar|gz|tgz|bz2)$ ]]; then
                    echo "  └─ 压缩包内容匹配:" >&3
                    for match in "${content_matches[@]}"; do
                        echo "      $match" >&3
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
scan_images "$target_directory" "$keyword_file" "$output_file"