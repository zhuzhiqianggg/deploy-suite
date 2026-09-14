#!/bin/bash
# 磁盘健康监控脚本，支持Prometheus格式输出
# 该脚本保留为独立脚本，主入口脚本可自动复制并托管为 systemd 服务

set -e

CONFIG_FILE="/etc/disk_monitor.conf"
EXPORTER_PORT="9101"
SCRAPE_INTERVAL="3600"
PUSHGATEWAY_URL="http://121.36.241.152:9091"
PUSH_JOB_NAME="disk_health"
PUSH_INSTANCE_NAME=""

METRICS=(
    "health_status"
    "temperature_celsius"
    "power_on_hours"
    "reallocated_sectors"
    "reported_uncorrectable_errors"
    "command_timeout"
    "current_pending_sector"
    "offline_uncorrectable"
    "wear_leveling_count"
    "media_wearout_indicator"
    "percentage_used"
    "available_spare"
    "available_spare_threshold"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

check_dependencies() {
    if ! command -v smartctl &> /dev/null; then
        echo "错误: smartctl 未安装"
        echo "请安装 smartmontools"
        exit 1
    fi
}

get_disk_devices() {
    local devices=()
    for device in $(ls /dev/sd? 2>/dev/null) $(ls /dev/nvme?n? 2>/dev/null) $(ls /dev/mmcblk? 2>/dev/null); do
        if [[ -e "$device" ]]; then
            devices+=("$device")
        fi
    done
    if [ ${#devices[@]} -eq 0 ]; then
        devices=($(smartctl --scan | awk '{print $1}'))
    fi
    echo "${devices[@]}"
}

check_smart_supported() {
    local device=$1
    local smart_output
    smart_output=$(smartctl -i "$device" 2>/dev/null || true)
    if echo "$smart_output" | grep -qi "SMART support is.*Available"; then
        echo 1
    elif echo "$smart_output" | grep -qi "NVMe Version"; then
        echo 1
    else
        echo 0
    fi
}

detect_disk_type() {
    local device=$1
    local dev_name=$(basename "$device")
    if [[ $device == /dev/nvme* ]]; then
        echo "nvme"
        return
    fi
    local smart_output=$(smartctl -i "$device" 2>/dev/null || true)
    local vendor=$(echo "$smart_output" | grep -i "Vendor" | head -1 | cut -d: -f2 | xargs)
    local model=$(echo "$smart_output" | grep -iE "Device Model|Model Number" | head -1 | cut -d: -f2 | xargs)
    local rotation=$(echo "$smart_output" | grep -i "Rotation Rate" | head -1 | cut -d: -f2 | xargs)
    local transport=$(echo "$smart_output" | grep -i "Transport protocol" | head -1 | cut -d: -f2 | xargs)
    if echo "$vendor" | grep -qi "VMware"; then
        echo "vmware"
        return
    fi
    if echo "$vendor" | grep -qi "QEMU\|KVM\|virtio"; then
        echo "kvm"
        return
    fi
    if echo "$vendor" | grep -qi "Virtual"; then
        echo "virtual"
        return
    fi
    local rota_file="/sys/block/${dev_name}/queue/rotational"
    if [ -f "$rota_file" ]; then
        local rota=$(cat "$rota_file" 2>/dev/null || echo "1")
        if [ "$rota" = "0" ]; then
            echo "ssd"
            return
        else
            echo "hdd"
            return
        fi
    fi
    if echo "$rotation" | grep -qi "Solid State\|SSD\|Not Rotating"; then
        echo "ssd"
        return
    fi
    if echo "$transport" | grep -qi "sas\|fc"; then
        echo "sas"
        return
    fi
    echo "sata"
}

get_disk_info() {
    local device=$1
    local model=""
    local serial=""
    local size=""
    local disk_type=""
    local smart_output=$(smartctl -i "$device" 2>/dev/null || true)
    disk_type=$(detect_disk_type "$device")
    model=$(echo "$smart_output" | grep -E "Model Number|Device Model|Product" | head -1 | cut -d: -f2 | xargs)
    if echo "$model" | grep -qi "LOGICAL_VOLUME\|Virtual\|VMware\|QEMU"; then
        return
    fi
    serial=$(echo "$smart_output" | grep "Serial Number" | cut -d: -f2 | xargs)
    local size_line=$(echo "$smart_output" | grep -E "User Capacity|Total NVM Capacity" | head -1)
    if [[ -n "$size_line" ]]; then
        local size_bytes=$(echo "$size_line" | grep -oP '\d[\d,]+ bytes' | head -1 | grep -oP '\d[\d,]+' | tr -d ',')
        if [[ -n "$size_bytes" ]] && [ "$size_bytes" -gt 0 ] 2>/dev/null; then
            size="$((size_bytes / 1073741824))GB"
        else
            size=$(echo "$size_line" | cut -d[ -f2 | cut -d] -f1 | xargs)
        fi
    fi
    if [[ -z "$size" ]]; then
        local dev_name=$(basename "$device")
        local size_bytes=$(blockdev --getsize64 "/dev/${dev_name}" 2>/dev/null || echo "0")
        if [ "$size_bytes" -gt 0 ] 2>/dev/null; then
            size="$((size_bytes / 1073741824))GB"
        else
            size="Unknown"
        fi
    fi
    if [[ -z "$model" ]]; then
        model="Unknown"
    fi
    if [[ -z "$serial" ]]; then
        serial="Unknown"
    fi
    echo "${disk_type}|${model}|${serial}|${size}"
}

get_smart_value() {
    local device=$1
    local metric=$2
    local value=""
    case "$metric" in
        "current_pending_sector")
            value=$(smartctl -A "$device" 2>/dev/null | grep -i "Current_Pending_Sector" | awk '{print $NF}')
            ;;
        "reported_uncorrectable_errors")
            value=$(smartctl -A "$device" 2>/dev/null | grep -i "Reported_Uncorrect" | awk '{print $NF}')
            ;;
        "offline_uncorrectable")
            value=$(smartctl -A "$device" 2>/dev/null | grep -i "Offline_Uncorrectable" | awk '{print $NF}')
            ;;
    esac
    if [[ -z "$value" || ! "$value" =~ ^[0-9]+$ ]]; then
        value=0
    fi
    echo "$value"
}

get_disk_health() {
    local device=$1
    local health_status=0
    local output
    output=$(smartctl -H "$device" 2>/dev/null || true)
    if echo "$output" | grep -q "PASSED"; then
        health_status=1
    elif echo "$output" | grep -q "FAILED"; then
        health_status=0
    elif echo "$output" | grep -q "OK"; then
        health_status=1
    else
        health_status=2
    fi
    echo "$health_status"
}

get_disk_temperature() {
    local device=$1
    local temperature=0
    if [[ $device == /dev/nvme* ]]; then
        local temp_line=$(smartctl -A "$device" 2>/dev/null | grep -E '^Temperature:')
        if [[ -n "$temp_line" ]]; then
            temperature=$(echo "$temp_line" | sed 's/.*Temperature: *//' | awk '{print $1}')
        fi
    else
        local temp_output=$(smartctl -A "$device" 2>/dev/null | grep "Temperature_Celsius" | awk '{print $10}')
        if [[ -z "$temp_output" || ! "$temp_output" =~ ^[0-9]+$ ]]; then
            temp_output=$(smartctl -A "$device" 2>/dev/null | grep -E "Airflow_Temperature" | awk '{print $10}')
        fi
        if [[ -n "$temp_output" && "$temp_output" =~ ^[0-9]+$ ]]; then
            temperature=$temp_output
        fi
    fi
    if [[ -z "$temperature" || ! "$temperature" =~ ^[0-9]+$ ]]; then
        temperature=0
    fi
    echo "$temperature"
}

get_power_on_hours() {
    local device=$1
    local hours=0
    if [[ $device == /dev/nvme* ]]; then
        local line=$(smartctl -A "$device" 2>/dev/null | grep -E '^Power On Hours:')
        if [[ -n "$line" ]]; then
            hours=$(echo "$line" | sed 's/.*Power On Hours: *//' | awk '{print $1}' | tr -d ',')
        fi
    else
        hours=$(smartctl -A "$device" 2>/dev/null | grep "Power_On_Hours" | awk '{print $10}')
    fi
    if [[ -z "$hours" || ! "$hours" =~ ^[0-9]+$ ]]; then
        hours=0
    fi
    echo "$hours"
}

get_reallocated_sectors() {
    local device=$1
    local sectors=0
    if [[ $device == /dev/nvme* ]]; then
        local line=$(smartctl -A "$device" 2>/dev/null | grep -E '^Media and Data Integrity Errors:')
        if [[ -n "$line" ]]; then
            sectors=$(echo "$line" | sed 's/.*Media and Data Integrity Errors: *//' | awk '{print $1}' | tr -d ',')
        fi
    else
        sectors=$(smartctl -A "$device" 2>/dev/null | grep "Reallocated_Sector_Ct" | awk '{print $10}')
    fi
    if [[ -z "$sectors" || ! "$sectors" =~ ^[0-9]+$ ]]; then
        sectors=0
    fi
    echo "$sectors"
}

get_ssd_life_info() {
    local device=$1
    local info_type=$2
    local value=0
    if [[ $device == /dev/nvme* ]]; then
        case $info_type in
            "percentage_used")
                value=$(smartctl -A "$device" 2>/dev/null | grep 'Percentage Used:' | sed 's/.*Percentage Used: *//' | awk '{print $1}' | tr -d '%,' )
                if [[ -z "$value" ]]; then value=-1; fi
                ;;
            "available_spare")
                value=$(smartctl -A "$device" 2>/dev/null | grep 'Available Spare:' | sed 's/.*Available Spare: *//' | awk '{print $1}' | tr -d '%,' )
                ;;
            "available_spare_threshold")
                value=$(smartctl -A "$device" 2>/dev/null | grep 'Available Spare Threshold:' | sed 's/.*Available Spare Threshold: *//' | awk '{print $1}' | tr -d '%,' )
                ;;
            "data_units_written")
                local raw=$(smartctl -A "$device" 2>/dev/null | grep 'Data Units Written:' | sed 's/.*Data Units Written: *//')
                value=$(echo "$raw" | awk '{print $1}' | tr -d ',')
                ;;
        esac
    else
        local smart_output=$(smartctl -A "$device" 2>/dev/null)
        case $info_type in
            "wear_leveling_count")
                local wl_line=$(echo "$smart_output" | grep -i "^ *[0-9]\+ *Wear_Leveling_Count")
                if [[ -n "$wl_line" ]]; then
                    local wl_raw=$(echo "$wl_line" | awk '{print $10}')
                    local wl_value=$(echo "$wl_line" | awk '{print $4}')
                    wl_value=$(echo "$wl_value" | sed 's/^0*//')
                    if [[ -n "$wl_value" && "$wl_value" =~ ^[0-9]+$ ]]; then
                        value=$wl_value
                    elif [[ -n "$wl_raw" && "$wl_raw" =~ ^[0-9]+$ ]]; then
                        value=$wl_raw
                    fi
                fi
                ;;
            "media_wearout_indicator")
                local mwi_line=$(echo "$smart_output" | grep -i "^ *[0-9]\+ *Media_Wearout_Indicator")
                if [[ -n "$mwi_line" ]]; then
                    value=$(echo "$mwi_line" | awk '{print $4}' | sed 's/^0*//' | tr -d '%')
                fi
                ;;
            "percentage_used")
                local pl_used=$(echo "$smart_output" | grep -i "^ *[0-9]\+ *Percent_Lifetime_Used" | awk '{print $4}' | sed 's/^0*//' | tr -d '%')
                if [[ -z "$pl_used" ]]; then
                    pl_used=$(echo "$smart_output" | grep -i "^ *[0-9]\+ *Percentage_Used" | awk '{print $4}' | sed 's/^0*//' | tr -d '%')
                fi
                if [[ -z "$pl_used" ]]; then
                    local wl_line=$(echo "$smart_output" | grep -i "^ *[0-9]\+ *Wear_Leveling_Count")
                    if [[ -n "$wl_line" ]]; then
                        local wl_value=$(echo "$wl_line" | awk '{print $4}' | sed 's/^0*//')
                        if [[ -n "$wl_value" && "$wl_value" =~ ^[0-9]+$ && "$wl_value" -le 100 ]]; then
                            pl_used=$((100 - wl_value))
                        fi
                    fi
                fi
                if [[ -z "$pl_used" ]]; then
                    local mwi_line=$(echo "$smart_output" | grep -i "^ *[0-9]\+ *Media_Wearout_Indicator")
                    if [[ -n "$mwi_line" ]]; then
                        local mwi_value=$(echo "$mwi_line" | awk '{print $4}' | sed 's/^0*//' | tr -d '%')
                        if [[ -n "$mwi_value" && "$mwi_value" =~ ^[0-9]+$ && "$mwi_value" -le 100 ]]; then
                            pl_used=$((100 - mwi_value))
                        fi
                    fi
                fi
                value=${pl_used:-0}
                ;;
            "total_lbas_written")
                value=$(echo "$smart_output" | grep -i "Total_LBAs_Written" | awk '{print $10}')
                if [[ -z "$value" || ! "$value" =~ ^[0-9]+$ ]]; then
                    value=0
                fi
                ;;
        esac
    fi
    if [[ -z "$value" || ! "$value" =~ ^[0-9]+$ ]]; then
        value=0
    fi
    echo "$value"
}

generate_prometheus_headers() {
    cat <<'EOF'
# HELP smart_health_status 磁盘健康状态 (0=失败, 1=正常, 2=未知)
# TYPE smart_health_status gauge
# HELP smart_temperature_celsius 磁盘温度(摄氏度)
# TYPE smart_temperature_celsius gauge
# HELP smart_power_on_hours 磁盘通电时间(小时)
# TYPE smart_power_on_hours gauge
# HELP smart_reallocated_sectors 重映射扇区数量
# TYPE smart_reallocated_sectors gauge
# HELP smart_percentage_used SSD已使用寿命百分比
# TYPE smart_percentage_used gauge
# HELP smart_current_pending_sector 待处理扇区数
# TYPE smart_current_pending_sector gauge
# HELP smart_reported_uncorrectable_errors 不可纠正错误数
# TYPE smart_reported_uncorrectable_errors gauge
# HELP smart_offline_uncorrectable 离线坏扇区数
# TYPE smart_offline_uncorrectable gauge
EOF
}

generate_prometheus_metric_values() {
    local device=$1
    local device_basename=$(basename "$device")
    local disk_info=$(get_disk_info "$device")
    IFS='|' read -r disk_type model serial size <<< "$disk_info"
    if [[ -z "$model" || "$model" == "Unknown" ]] || echo "$model" | grep -qi "LOGICAL_VOLUME\|Virtual\|VMware\|QEMU"; then
        return
    fi
    local hostname_val=$(hostname)
    local model_label=$(echo "$model" | tr -s ' ' '_' | tr -cd '[:alnum:]_.-')
    local serial_label=$(echo "$serial" | tr -cd '[:alnum:]')
    local labels="device=\"$device_basename\",hostname=\"$hostname_val\",model=\"$model_label\",serial=\"$serial_label\",type=\"$disk_type\""
    local smart_supported=$(check_smart_supported "$device")
    echo "smart_smart_available{$labels} $smart_supported"
    if [[ $smart_supported -eq 1 ]]; then
        local health_status=$(get_disk_health "$device")
        local temperature=$(get_disk_temperature "$device")
        local power_on_hours=$(get_power_on_hours "$device")
        local reallocated_sectors=$(get_reallocated_sectors "$device")
        local percentage_used=$(get_ssd_life_info "$device" "percentage_used")
        local current_pending=$(get_smart_value "$device" "current_pending_sector")
        local reported_uncorrectable=$(get_smart_value "$device" "reported_uncorrectable_errors")
        local offline_uncorrectable=$(get_smart_value "$device" "offline_uncorrectable")
    else
        local health_status=1
        local temperature=-1
        local power_on_hours=-1
        local reallocated_sectors=-1
        local percentage_used=-1
        local current_pending=0
        local reported_uncorrectable=0
        local offline_uncorrectable=0
    fi
    echo "smart_health_status{$labels} $health_status"
    echo "smart_temperature_celsius{$labels} $temperature"
    echo "smart_power_on_hours{$labels} $power_on_hours"
    echo "smart_reallocated_sectors{$labels} $reallocated_sectors"
    echo "smart_percentage_used{$labels} $percentage_used"
    echo "smart_current_pending_sector{$labels} $current_pending"
    echo "smart_reported_uncorrectable_errors{$labels} $reported_uncorrectable"
    echo "smart_offline_uncorrectable{$labels} $offline_uncorrectable"
}

push_to_gateway() {
    local metrics_file="$1"
    local instance="${PUSH_INSTANCE_NAME:-$(hostname)}"
    if [ ! -s "$metrics_file" ]; then
        echo "警告: 指标文件为空，跳过推送"
        return 1
    fi
    local url="${PUSHGATEWAY_URL}/metrics/job/${PUSH_JOB_NAME}/instance/${instance}"
    local response
    response=$(curl -s -w "\n%{http_code}" --data-binary "@${metrics_file}" "$url" 2>&1)
    local http_code=$(echo "$response" | tail -n1)
    if [ "$http_code" = "200" ] || [ "$http_code" = "202" ]; then
        return 0
    fi
    return 1
}

show_help() {
    cat <<EOF
磁盘健康监控脚本

用法: $0 [选项]

选项:
  -c, --console     控制台模式
  -o, --once        单次输出Prometheus格式
  -g, --pushgateway 推送到PushGateway
  --port PORT       设置端口（默认: 9101）
  --interval SEC    设置采集间隔（默认: 3600秒）
  -h, --help        显示帮助
EOF
}

main() {
    check_dependencies
    local mode="once"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --console|-c)
                mode="console"
                ;;
            --once|-o)
                mode="once"
                ;;
            --pushgateway|--push|-g)
                mode="pushgateway"
                ;;
            --port)
                EXPORTER_PORT="$2"
                shift
                ;;
            --interval)
                SCRAPE_INTERVAL="$2"
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                echo "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
        shift
    done

    case "$mode" in
        console)
            for device in $(get_disk_devices); do
                if [ -e "$device" ]; then
                    device_basename=$(basename "$device")
                    disk_info=$(get_disk_info "$device")
                    IFS='|' read -r disk_type model serial size <<< "$disk_info"
                    health_status=$(get_disk_health "$device")
                    temperature=$(get_disk_temperature "$device")
                    power_on_hours=$(get_power_on_hours "$device")
                    reallocated_sectors=$(get_reallocated_sectors "$device")
                    echo "设备: $device_basename"
                    echo "型号: $model"
                    echo "状态: $health_status"
                    echo "温度: $temperature"
                    echo "通电时间: $power_on_hours"
                    echo "重映射扇区: $reallocated_sectors"
                    echo "----"
                fi
            done
            ;;
        once)
            generate_prometheus_headers
            for device in $(get_disk_devices); do
                if [ -e "$device" ]; then
                    generate_prometheus_metric_values "$device"
                fi
            done
            ;;
        pushgateway)
            while true; do
                local metrics_file="/tmp/disk_metrics_$$.prom"
                {
                    generate_prometheus_headers
                    for device in $(get_disk_devices); do
                        if [ -e "$device" ]; then
                            generate_prometheus_metric_values "$device"
                        fi
                    done
                } > "$metrics_file"
                if push_to_gateway "$metrics_file"; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') 推送成功"
                else
                    echo "$(date '+%Y-%m-%d %H:%M:%S') 推送失败"
                fi
                rm -f "$metrics_file"
                sleep "$SCRAPE_INTERVAL"
            done
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
