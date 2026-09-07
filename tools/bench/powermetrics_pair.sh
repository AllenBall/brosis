#!/bin/bash
# brosis M0 / E7：成对资源测量脚本模板（记录器开 / 关跑同一任务）
#
# 对应《实施计划》2.4 验收口径「资源」行与附录 A 的 E7：
#   同一任务成对运行（记录器开 / 关），接电与电池各一次；
#   记录全进程 CPU、WindowServer、内存、磁盘增长、能耗。
#
# 现状（2026-09-06）：M1 的记录器还不存在，所以本脚本只是**模板**。
# --dry-run 可以完整走通流程（不需要 sudo，不采 powermetrics），用来验证参数、
# 目录、采样循环、CSV 列和汇总逻辑；真正出数据要等记录器可执行文件就位。
#
# ===== 需要 sudo =====
# powermetrics 必须以 root 运行（`powermetrics: must be invoked as the superuser`）。
# 正式测量请用：
#     sudo ./powermetrics_pair.sh --task ... --minutes 30 ...
# 或先 `sudo -v` 拿到票据再运行。--dry-run 不需要 sudo。
# 这一步会弹系统的密码提示，需要**用户本人**操作，不能由脚本代劳。

set -euo pipefail

usage() {
  cat <<'USAGE'
用法：
  powermetrics_pair.sh --task <命令> [选项]

必填：
  --task <命令>            两个臂里都要跑的同一个任务（shell 命令串）。
                           想只测空载就用 --task 'sleep $((MINUTES*60))'。

可选：
  --minutes <N>            每个臂跑多少分钟（默认 30；--dry-run 下换算成秒）
  --interval <秒>          采样间隔（默认 5）
  --label <名字>           这轮的名字，进目录名（默认 pair）
  --power-source <plugged|battery>
                           只作为标签记录，脚本不切换电源（默认 plugged）
  --recorder-start <命令>  B 臂开始前拉起记录器（默认空 = 没有记录器）
  --recorder-stop <命令>   B 臂结束后停掉记录器（默认空）
  --data-dir <目录>        记录器的数据目录，用来算磁盘增长
                           （默认 ~/Library/Application Support/brosis）
  --watch <正则>           ps 采样要单独盯住的进程名正则
                           （默认 'WindowServer|brosis|Xcode|python3'）
  --out <目录>             输出根目录（默认 ~/Library/Caches/brosis-build/power）
  --dry-run                不采 powermetrics、不需要 sudo，每个臂只跑
                           <minutes> 秒；用来验证脚本流程
  -h, --help               显示本帮助

输出（<out>/<label>-<时间戳>/）：
  power_A.csv / power_B.csv    powermetrics 解析后的时序（ts,arm,metric,value,unit）
  power_A.log / power_B.log    powermetrics 原始输出，保留以便复核解析
  ps_A.csv    / ps_B.csv       ps 时序（ts,arm,pid,pcpu,pmem,rss_kb,command）
  disk.csv                     两个臂的数据目录字节数（前 / 后 / 增量）
  battery.csv                  两个臂前后的 pmset -g batt 快照
  summary.csv                  A/B 配对汇总与差值（这份是要写进报告的）
  meta.txt                     参数、机器信息、是否 dry-run
USAGE
}

MINUTES=30
INTERVAL=5
LABEL="pair"
POWER_SOURCE="plugged"
TASK=""
REC_START=""
REC_STOP=""
DATA_DIR="$HOME/Library/Application Support/brosis"
WATCH_RE='WindowServer|brosis|Xcode|python3'
OUT_ROOT="$HOME/Library/Caches/brosis-build/power"
DRY_RUN=0
PM_PREFIX=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) TASK="$2"; shift 2 ;;
    --minutes) MINUTES="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --power-source) POWER_SOURCE="$2"; shift 2 ;;
    --recorder-start) REC_START="$2"; shift 2 ;;
    --recorder-stop) REC_STOP="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    --watch) WATCH_RE="$2"; shift 2 ;;
    --out) OUT_ROOT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$TASK" ]]; then
  echo "错误：--task 必填。只想测空载就传 --task 'sleep 1800'。" >&2
  usage
  exit 2
fi

# --- 前置检查 -------------------------------------------------------------- #
if [[ $DRY_RUN -eq 0 ]]; then
  if [[ "$(id -u)" != "0" ]] && ! sudo -n true 2>/dev/null; then
    cat >&2 <<'ERR'
错误：powermetrics 需要 root。

  请用 `sudo ./powermetrics_pair.sh ...` 重跑，或先执行 `sudo -v` 拿到 sudo 票据。
  这一步会弹密码提示，必须由你本人输入，脚本不会也不能代劳。
  只想验证脚本流程、不出真实能耗数据，请加 --dry-run。
ERR
    exit 3
  fi
  command -v powermetrics >/dev/null || { echo "错误：找不到 powermetrics" >&2; exit 3; }
  # 有 sudo 票据但本身不是 root 时，powermetrics 也必须用 sudo 拉起，否则它会直接拒绝运行
  if [[ "$(id -u)" != "0" ]]; then
    PM_PREFIX="sudo -n"
  else
    PM_PREFIX=""
  fi
fi

if [[ -z "$REC_START" ]]; then
  echo "提示：--recorder-start 为空。B 臂不会真的开记录器，" >&2
  echo "      A/B 两臂做的是同一件事，差值只反映测量噪声——现在（M1 之前）就是这样。" >&2
fi

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$OUT_ROOT/$LABEL-$TS"
mkdir -p "$OUT"

if [[ $DRY_RUN -eq 1 ]]; then
  DURATION=$MINUTES          # dry-run：分钟当秒用，几十秒就能走完全流程
  DUR_UNIT="秒（--dry-run 把分钟当秒）"
else
  DURATION=$((MINUTES * 60))
  DUR_UNIT="秒"
fi
NSAMPLES=$(( DURATION / INTERVAL ))
[[ $NSAMPLES -lt 1 ]] && NSAMPLES=1

{
  echo "label=$LABEL"
  echo "timestamp=$TS"
  echo "dry_run=$DRY_RUN"
  echo "power_source=$POWER_SOURCE"
  echo "minutes=$MINUTES"
  echo "duration_s=$DURATION ($DUR_UNIT)"
  echo "interval_s=$INTERVAL"
  echo "samples_per_arm=$NSAMPLES"
  echo "task=$TASK"
  echo "recorder_start=${REC_START:-<空>}"
  echo "recorder_stop=${REC_STOP:-<空>}"
  echo "data_dir=$DATA_DIR"
  echo "watch_regex=$WATCH_RE"
  echo "host=$(hostname)"
  echo "os=$(sw_vers -productName) $(sw_vers -productVersion) $(sw_vers -buildVersion)"
  echo "cpu=$(sysctl -n machdep.cpu.brand_string)"
  echo "mem_bytes=$(sysctl -n hw.memsize)"
  echo "thermal=$(pmset -g therm 2>/dev/null | tr '\n' ';' || echo 'n/a')"
} > "$OUT/meta.txt"

echo "ts,arm,pid,pcpu,pmem,rss_kb,command" > "$OUT/ps_A.csv"
echo "ts,arm,pid,pcpu,pmem,rss_kb,command" > "$OUT/ps_B.csv"
echo "arm,phase,bytes" > "$OUT/disk.csv"
echo "arm,phase,pmset_batt" > "$OUT/battery.csv"

dir_bytes() {
  if [[ -d "$1" ]]; then
    /usr/bin/du -sk "$1" 2>/dev/null | awk '{print $1 * 1024}'
  else
    echo 0
  fi
}

# ps 采样循环：全进程 CPU 汇总一行（pid=-1），外加 --watch 命中的进程各一行
ps_sampler() {
  local arm="$1" out="$2" n="$3"
  local i=0
  while [[ $i -lt $n ]]; do
    local now
    now="$(date +%s)"
    ps -Ao pid,pcpu,pmem,rss,comm | awk -v ts="$now" -v arm="$arm" -v re="$WATCH_RE" '
      NR == 1 { next }
      {
        cpu += $2; mem += $3; rss += $4
        cmd = ""
        for (j = 5; j <= NF; j++) cmd = cmd (j > 5 ? " " : "") $j
        if (cmd ~ re) {
          gsub(/,/, ";", cmd)
          printf "%s,%s,%s,%s,%s,%s,%s\n", ts, arm, $1, $2, $3, $4, cmd
        }
      }
      END { printf "%s,%s,-1,%.2f,%.2f,%d,__ALL_PROCESSES__\n", ts, arm, cpu, mem, rss }
    ' >> "$out"
    i=$((i + 1))
    sleep "$INTERVAL"
  done
}

# powermetrics 解析：原始文本 -> ts,arm,metric,value,unit
parse_power() {
  local arm="$1" log="$2" csv="$3"
  echo "ts,arm,metric,value,unit" > "$csv"
  [[ -s "$log" ]] || return 0
  awk -v arm="$arm" '
    /^\*\*\* Sampled system activity/ { n++ }
    /Combined Power \(CPU \+ GPU \+ ANE\):/ { print n "," arm ",combined_power," $(NF-1) ",mW" }
    /^CPU Power:/                          { print n "," arm ",cpu_power,"      $(NF-1) ",mW" }
    /^GPU Power:/                          { print n "," arm ",gpu_power,"      $(NF-1) ",mW" }
    /^ANE Power:/                          { print n "," arm ",ane_power,"      $(NF-1) ",mW" }
    /^DRAM Power:/                         { print n "," arm ",dram_power,"     $(NF-1) ",mW" }
  ' "$log" >> "$csv"
}

run_arm() {
  local arm="$1" recorder_on="$2"
  local log="$OUT/power_${arm}.log"
  local pscsv="$OUT/ps_${arm}.csv"

  echo ">>> 臂 $arm（记录器 $( [[ $recorder_on -eq 1 ]] && echo 开 || echo 关 )）开始，"\
       "持续 ${DURATION} ${DUR_UNIT}"

  if [[ $recorder_on -eq 1 && -n "$REC_START" ]]; then
    echo "    拉起记录器：$REC_START"
    eval "$REC_START"
    sleep 5      # 让记录器稳定下来再开始采样
  fi

  echo "$arm,before,$(dir_bytes "$DATA_DIR")" >> "$OUT/disk.csv"
  echo "$arm,before,\"$(pmset -g batt | tr '\n' ' ' | tr ',' ';')\"" >> "$OUT/battery.csv"

  local pm_pid=""
  if [[ $DRY_RUN -eq 0 ]]; then
    # shellcheck disable=SC2086
    $PM_PREFIX powermetrics --samplers cpu_power,gpu_power,thermal \
                 --show-process-energy \
                 -i $((INTERVAL * 1000)) -n "$NSAMPLES" > "$log" 2>&1 &
    pm_pid=$!
  else
    {
      echo "# --dry-run：没有采 powermetrics。正式测量会执行："
      echo "# sudo powermetrics --samplers cpu_power,gpu_power,thermal --show-process-energy \\"
      echo "#      -i $((INTERVAL * 1000)) -n $NSAMPLES"
    } > "$log"
  fi

  ps_sampler "$arm" "$pscsv" "$NSAMPLES" &
  local ps_pid=$!

  local t0 t1
  t0="$(date +%s)"
  set +e
  eval "$TASK"
  local task_rc=$?
  set -e
  t1="$(date +%s)"
  echo "    任务退出码 $task_rc，用时 $((t1 - t0)) 秒"

  wait "$ps_pid" 2>/dev/null || true
  if [[ -n "$pm_pid" ]]; then
    wait "$pm_pid" 2>/dev/null || true
  fi
  parse_power "$arm" "$log" "$OUT/power_${arm}.csv"

  if [[ $recorder_on -eq 1 && -n "$REC_STOP" ]]; then
    echo "    停掉记录器：$REC_STOP"
    eval "$REC_STOP"
  fi

  echo "$arm,after,$(dir_bytes "$DATA_DIR")" >> "$OUT/disk.csv"
  echo "$arm,after,\"$(pmset -g batt | tr '\n' ' ' | tr ',' ';')\"" >> "$OUT/battery.csv"
  echo "    臂 $arm 结束，任务退出码 $task_rc"
}

# --- 跑两个臂 -------------------------------------------------------------- #
run_arm A 0     # 记录器关
sleep 10        # 让机器回到基线再跑第二个臂
run_arm B 1     # 记录器开

# --- 汇总 ------------------------------------------------------------------ #
{
  echo "metric,unit,arm_A,arm_B,delta_B_minus_A,note"

  for m in combined_power cpu_power gpu_power dram_power; do
    a=$(awk -F, -v m="$m" '$3==m {s+=$4; n++} END {if (n) printf "%.1f", s/n; else print "NA"}' "$OUT/power_A.csv")
    b=$(awk -F, -v m="$m" '$3==m {s+=$4; n++} END {if (n) printf "%.1f", s/n; else print "NA"}' "$OUT/power_B.csv")
    d=$(awk -v a="$a" -v b="$b" 'BEGIN {if (a=="NA"||b=="NA") print "NA"; else printf "%.1f", b-a}')
    echo "${m}_mean,mW,$a,$b,$d,powermetrics 采样均值"
  done

  for m in cpu pmem rss; do
    case $m in
      cpu)  col=4; unit="%";  note="全进程 %CPU 之和的采样均值" ;;
      pmem) col=5; unit="%";  note="全进程 %MEM 之和的采样均值" ;;
      rss)  col=6; unit="KB"; note="全进程 RSS 之和的采样均值" ;;
    esac
    a=$(awk -F, -v c="$col" '$3=="-1" {s+=$c; n++} END {if (n) printf "%.1f", s/n; else print "NA"}' "$OUT/ps_A.csv")
    b=$(awk -F, -v c="$col" '$3=="-1" {s+=$c; n++} END {if (n) printf "%.1f", s/n; else print "NA"}' "$OUT/ps_B.csv")
    d=$(awk -v a="$a" -v b="$b" 'BEGIN {if (a=="NA"||b=="NA") print "NA"; else printf "%.1f", b-a}')
    echo "all_process_${m}_mean,$unit,$a,$b,$d,$note"
  done

  for who in WindowServer; do
    a=$(awk -F, -v w="$who" '$7 ~ w {s+=$4; n++} END {if (n) printf "%.2f", s/n; else print "NA"}' "$OUT/ps_A.csv")
    b=$(awk -F, -v w="$who" '$7 ~ w {s+=$4; n++} END {if (n) printf "%.2f", s/n; else print "NA"}' "$OUT/ps_B.csv")
    d=$(awk -v a="$a" -v b="$b" 'BEGIN {if (a=="NA"||b=="NA") print "NA"; else printf "%.2f", b-a}')
    echo "${who}_cpu_mean,%,$a,$b,$d,ps 采样均值"
  done

  da=$(awk -F, '$1=="A"&&$2=="after"{x=$3} $1=="A"&&$2=="before"{y=$3} END {print x-y}' "$OUT/disk.csv")
  db=$(awk -F, '$1=="B"&&$2=="after"{x=$3} $1=="B"&&$2=="before"{y=$3} END {print x-y}' "$OUT/disk.csv")
  echo "data_dir_growth,B,$da,$db,$((db - da)),$DATA_DIR 的 du -sk 差值"
  echo "duration,s,$DURATION,$DURATION,0,每个臂的目标时长"
  echo "samples_per_arm,count,$NSAMPLES,$NSAMPLES,0,采样点数"
  echo "power_source,-,$POWER_SOURCE,$POWER_SOURCE,-,标签，脚本不切换电源"
  echo "dry_run,-,$DRY_RUN,$DRY_RUN,-,1 = 没有真实能耗数据"
} > "$OUT/summary.csv"

echo
echo "完成。输出目录：$OUT"
echo
column -s, -t "$OUT/summary.csv" 2>/dev/null || cat "$OUT/summary.csv"
if [[ $DRY_RUN -eq 1 ]]; then
  echo
  echo "注意：这是 --dry-run，power_*.csv 只有表头，没有真实能耗数据。"
  echo "      正式测量：sudo $0 --task '<真实任务>' --minutes 30 --label plugged \\"
  echo "                   --recorder-start '<拉起记录器>' --recorder-stop '<停掉记录器>'"
fi
