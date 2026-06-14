#!/usr/bin/env bash
# power-cost.sh — Electronic Clam 자체 자원 비용 측정 (proposal §7).
#
# 비-sudo 근사: ps 샘플링으로 앱+helper의 평균/최대 CPU%와 RSS를 잰다.
# 진짜 에너지(전력 임팩트)는 sudo가 필요하다:
#   sudo powermetrics --samplers tasks --show-process-energy -i 1000 -n 60 \
#     | grep -iE "ElectronicClam|eclam"
#
# 사용법: ./scripts/power-cost.sh [지속초=60]
set -euo pipefail

DUR="${1:-60}"
INT=2
APP_PID="$(pgrep -f 'ElectronicClam.app/Contents/MacOS/ElectronicClam$' | head -1 || true)"
HELPER_PID="$(pgrep -x ElectronicClamHelper | head -1 || true)"

if [[ -z "$APP_PID" ]]; then
    echo "ERROR: ElectronicClam.app 프로세스를 찾지 못함 — 앱을 먼저 실행하세요." >&2
    exit 1
fi
echo "==> 측정 대상: app=$APP_PID helper=${HELPER_PID:-없음(권한대기?)} / ${DUR}s, ${INT}s 간격"

samples=0
app_cpu_sum=0; app_cpu_max=0; app_rss_max=0
helper_cpu_sum=0; helper_cpu_max=0; helper_rss_max=0

end=$(( $(date +%s) + DUR ))
while [[ $(date +%s) -lt $end ]]; do
    if out=$(ps -o %cpu=,rss= -p "$APP_PID" 2>/dev/null); then
        cpu=$(echo "$out" | awk '{print $1}'); rss=$(echo "$out" | awk '{print $2}')
        app_cpu_sum=$(echo "$app_cpu_sum + $cpu" | bc)
        (( $(echo "$cpu > $app_cpu_max" | bc) )) && app_cpu_max=$cpu
        [[ $rss -gt $app_rss_max ]] && app_rss_max=$rss
    fi
    if [[ -n "$HELPER_PID" ]] && out=$(ps -o %cpu=,rss= -p "$HELPER_PID" 2>/dev/null); then
        cpu=$(echo "$out" | awk '{print $1}'); rss=$(echo "$out" | awk '{print $2}')
        helper_cpu_sum=$(echo "$helper_cpu_sum + $cpu" | bc)
        (( $(echo "$cpu > $helper_cpu_max" | bc) )) && helper_cpu_max=$cpu
        [[ $rss -gt $helper_rss_max ]] && helper_rss_max=$rss
    fi
    samples=$((samples + 1))
    sleep "$INT"
done

avg() { echo "scale=2; $1 / $samples" | bc; }
mb()  { echo "scale=1; $1 / 1024" | bc; }

echo "==> 샘플 $samples 개 (${INT}s 간격)"
echo "    app    : avg $(avg "$app_cpu_sum")% CPU · max ${app_cpu_max}% · RSS $(mb $app_rss_max) MB"
if [[ -n "$HELPER_PID" ]]; then
    echo "    helper : avg $(avg "$helper_cpu_sum")% CPU · max ${helper_cpu_max}% · RSS $(mb $helper_rss_max) MB"
fi
echo "==> POWER-COST DONE"
