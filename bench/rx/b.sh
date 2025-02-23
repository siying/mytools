#!/usr/bin/env bash # Copyright (c) Facebook, Inc. and its affiliates. All Rights Reserved.
# REQUIRE: db_bench binary exists in the current directory

# Exit Codes
EXIT_INVALID_ARGS=1
EXIT_NOT_COMPACTION_TEST=2
EXIT_UNKNOWN_JOB=3

# Size Constants
K=1024
M=$((1024 * K))
G=$((1024 * M))
T=$((1024 * G))

function display_usage() {
  echo "useage: benchmark.sh [--help] <test>"
  echo ""
  echo "These are the available benchmark tests:"
  echo -e "\tbulkload"
  echo -e "\tfillseq_disable_wal\t\tSequentially fill the database with no WAL"
  echo -e "\tfillseq_enable_wal\t\tSequentially fill the database with WAL"
  echo -e "\toverwrite"
  echo -e "\tupdaterandom"
  echo -e "\treadrandom"
  echo -e "\tmergerandom"
  echo -e "\tfilluniquerandom"
  echo -e "\tmultireadrandom"
  echo -e "\tfwdrange"
  echo -e "\trevrange"
  echo -e "\treadwhilewriting"
  echo -e "\treadwhilemerging"
  echo -e "\tfwdrangewhilewriting"
  echo -e "\trevrangewhilewriting"
  echo -e "\tfwdrangewhilemerging"
  echo -e "\trevrangewhilemerging"
  echo -e "\trandomtransaction"
  echo -e "\tuniversal_compaction"
  echo -e "\tdebug"
  echo ""
  echo "Enviroment Variables:"
  echo -e "\tJOB_ID\t\tAn identifier for the benchmark job, will appear in the results"
  echo -e "\tDB_DIR\t\t\t\tPath to write the database data directory"
  echo -e "\tWAL_DIR\t\t\t\tPath to write the database WAL directory"
  echo -e "\tOUTPUT_DIR\t\t\tPath to write the benchmark results to (default: /tmp)"
  echo -e "\tNUM_KEYS\t\t\tThe number of keys to use in the benchmark"
  echo -e "\tKEY_SIZE\t\t\tThe size of the keys to use in the benchmark (default: 20 bytes)"
  echo -e "\tVALUE_SIZE\t\t\tThe size of the values to use in the benchmark (default: 400 bytes)"
  echo -e "\tBLOCK_SIZE\t\t\tThe size of the database blocks in the benchmark (default: 8 KB)"
  echo -e "\tDB_BENCH_NO_SYNC\t\tDisable fsync on the WAL"
  echo -e "\tNUM_THREADS\t\t\tThe number of threads to use (default: 64)"
  echo -e "\tMB_WRITE_PER_SEC"
  echo -e "\tNUM_NEXTS_PER_SEEK\t\t(default: 10)"
  echo -e "\tCACHE_SIZE\t\t\t(default: 16GB)"
  echo -e "\tCOMPRESSION_MAX_DICT_BYTES"
  echo -e "\tCOMPRESSION_TYPE\t\t(default: zstd)"
  echo -e "\tBOTTOMMOST_COMPRESSION\t\t(default: none)"
  echo -e "\tDURATION\t\t\tNumber of seconds for which the test runs"
  echo -e "\tWRITES\t\t\tNumber of writes for which the test runs"
  echo -e "\tWRITE_BUFFER_SIZE_MB\t\tThe size of the write buffer in MB (default: 128)"
  echo -e "\tTARGET_FILE_SIZE_BASE_MB\t\tThe value for target_file_size_base in MB (default: 128)"
  echo -e "\tMAX_BYTES_FOR_LEVEL_BASE_MB\t\tThe value for max_bytes_for_level_base in MB (default: 128)"
  echo -e "\tMAX_BACKGROUND_JOBS\t\t\tThe value for max_background_jobs (default: 16)"
  echo -e "\tCACHE_INDEX_AND_FILTER_BLOCKS\t\tThe value for cache_index_and_filter_blocks (default: 0)"
  echo -e "\tUSE_O_DIRECT\t\tUse O_DIRECT for user reads and compaction"
  echo -e "\tSOFT_PENDING_COMPACTION_BYTES_LIMIT_IN_GB\tThe value for soft_pending_compaction_bytes_limit in GB"
  echo -e "\tHARD_PENDING_COMPACTION_BYTES_LIMIT_IN_GB\tThe value for hard_pending_compaction_bytes_limit in GB"
  echo -e "\tSTATS_INTERVAL_SECONDS\tValue for stats_interval_seconds"
  echo -e "\tSUBCOMPACTIONS\t\tValue for subcompactions"
  echo -e "\tLEVEL0_FILE_NUM_COMPACTION_TRIGGER\tValue for level0_file_num_compaction_trigger"
  echo -e "\tLEVEL0_SLOWDOWN_WRITES_TRIGGER\tValue for level0_slowdown_writes_trigger"
  echo -e "\tLEVEL0_STOP_WRITES_TRIGGER\tValue for level0_stop_writes_trigger"
  echo -e "\tUNIVERSAL\t\tUse universal compaction when set to anything, otherwise use leveled"
  echo -e "\tUNIVERSAL_MIN_MERGE_WIDTH\tValue of min_merge_width option for universal"
  echo -e "\tUNIVERSAL_MAX_MERGE_WIDTH\tValue of min_merge_width option for universal"
  echo -e "\tUNIVERSAL_SIZE_RATIO\tValue of size_ratio option for universal"
  echo -e "\tUNIVERSAL_MAX_SIZE_AMP\tmax_size_amplification_percent for universal"
  echo -e "\tUNIVERSAL_ALLOW_TRIVIAL_MOVE\tSet allow_trivial_move to true for universal, default is false"
}

if [ $# -lt 1 ]; then
  display_usage
  exit $EXIT_INVALID_ARGS
fi
bench_cmd=$1
shift
bench_args=$*

if [[ "$bench_cmd" == "--help" ]]; then
  display_usage
  exit
fi

job_id=${JOB_ID}

# Make it easier to run only the compaction test. Getting valid data requires
# a number of iterations and having an ability to run the test separately from
# rest of the benchmarks helps.
if [ "$COMPACTION_TEST" == "1" -a "$bench_cmd" != "universal_compaction" ]; then
  echo "Skipping $1 because it's not a compaction test."
  exit $EXIT_NOT_COMPACTION_TEST
fi

if [ -z $DB_DIR ]; then
  echo "DB_DIR is not defined"
  exit $EXIT_INVALID_ARGS
fi

if [ -z $WAL_DIR ]; then
  echo "WAL_DIR is not defined"
  exit $EXIT_INVALID_ARGS
fi

output_dir=${OUTPUT_DIR:-/tmp}
if [ ! -d $output_dir ]; then
  mkdir -p $output_dir
fi

report="$output_dir/report.tsv"
schedule="$output_dir/schedule.txt"

# all multithreaded tests run with sync=1 unless
# $DB_BENCH_NO_SYNC is defined
syncval="1"
if [ ! -z $DB_BENCH_NO_SYNC ]; then
  echo "Turning sync off for all multithreaded tests"
  syncval="0";
fi

num_threads=${NUM_THREADS:-64}
mb_written_per_sec=${MB_WRITE_PER_SEC:-0}
# Only for tests that do range scans
num_nexts_per_seek=${NUM_NEXTS_PER_SEEK:-10}
cache_size=${CACHE_SIZE:-$((17179869184))}
compression_max_dict_bytes=${COMPRESSION_MAX_DICT_BYTES:-0}
compression_type=${COMPRESSION_TYPE:-zstd}
min_level_to_compress=${MIN_LEVEL_TO_COMPRESS:-"-1"}
duration=${DURATION:-0}
writes=${WRITES:-0}

num_keys=${NUM_KEYS:-8000000000}
key_size=${KEY_SIZE:-20}
value_size=${VALUE_SIZE:-400}
block_size=${BLOCK_SIZE:-8192}
write_buffer_mb=${WRITE_BUFFER_SIZE_MB:-128}
target_file_mb=${TARGET_FILE_SIZE_BASE_MB:-128}
l1_mb=${MAX_BYTES_FOR_LEVEL_BASE_MB:-1024}
max_background_jobs=${MAX_BACKGROUND_JOBS:-16}
stats_interval_seconds=${STATS_INTERVAL_SECONDS:-60}
subcompactions=${SUBCOMPACTIONS:-1}

cache_index_and_filter=${CACHE_INDEX_AND_FILTER_BLOCKS:-0}
if [[ $cache_index_and_filter -eq 0 ]]; then
  cache_meta_flags=""
elif [[ $cache_index_and_filter -eq 1 ]]; then
  cache_meta_flags="\
  --cache_index_and_filter_blocks=$cache_index_and_filter \
  --cache_high_pri_pool_ratio=0.5"
else
  echo CACHE_INDEX_AND_FILTER_BLOCKS was $CACHE_INDEX_AND_FILTER_BLOCKS but most be 0 or 1
  exit $EXIT_INVALID_ARGS
fi

soft_pending_arg=""
if [ ! -z $SOFT_PENDING_COMPACTION_BYTES_LIMIT_IN_GB ]; then
  soft_pending_bytes=$( echo $SOFT_PENDING_COMPACTION_BYTES_LIMIT_IN_GB | \
    awk '{ printf "%s", $1 * 1024 * 1024 * 1024 }' )
  soft_pending_arg="--soft_pending_compaction_bytes_limit=$soft_pending_bytes"
fi

hard_pending_arg=""
if [ ! -z $HARD_PENDING_COMPACTION_BYTES_LIMIT_IN_GB ]; then
  hard_pending_bytes=$( echo $HARD_PENDING_COMPACTION_BYTES_LIMIT_IN_GB | \
    awk '{ printf "%s", $1 * 1024 * 1024 * 1024 }' )
  hard_pending_arg="--hard_pending_compaction_bytes_limit=$hard_pending_bytes"
fi

o_direct_flags=""
if [ ! -z $USE_O_DIRECT ]; then
  # TODO: deal with flags only supported in new versions, like prepopulate_block_cache
  #o_direct_flags="--use_direct_reads --use_direct_io_for_flush_and_compaction --prepopulate_block_cache=1"
  o_direct_flags="--use_direct_reads --use_direct_io_for_flush_and_compaction"
fi

univ_min_merge_width=${UNIVERSAL_MIN_MERGE_WIDTH:-2}
univ_max_merge_width=${UNIVERSAL_MAX_MERGE_WIDTH:-8}
univ_size_ratio=${UNIVERSAL_SIZE_RATIO:-1}
univ_max_size_amp=${UNIVERSAL_MAX_SIZE_AMP:-200}

if [ ! -z $UNIVERSAL_ALLOW_TRIVIAL_MOVE ]; then
  univ_allow_trivial_move=1
else
  univ_allow_trivial_move=0
fi

const_params_base="
  --db=$DB_DIR \
  --wal_dir=$WAL_DIR \
  \
  --num=$num_keys \
  --num_levels=8 \
  --key_size=$key_size \
  --value_size=$value_size \
  --block_size=$block_size \
  --cache_size=$cache_size \
  --cache_numshardbits=6 \
  --compression_max_dict_bytes=$compression_max_dict_bytes \
  --compression_ratio=0.5 \
  --compression_type=$compression_type \
  --min_level_to_compress=$min_level_to_compress \
  --bytes_per_sync=$((8 * M)) \
  $cache_meta_flags \
  $o_direct_flags \
  --benchmark_write_rate_limit=$(( 1024 * 1024 * $mb_written_per_sec )) \
  \
  --write_buffer_size=$(( $write_buffer_mb * M)) \
  --target_file_size_base=$(( $target_file_mb * M)) \
  --max_bytes_for_level_base=$(( $l1_mb * M)) \
  \
  --verify_checksum=1 \
  --delete_obsolete_files_period_micros=$((60 * M)) \
  --max_bytes_for_level_multiplier=8 \
  \
  --statistics=0 \
  --stats_per_interval=1 \
  --stats_interval_seconds=$stats_interval_seconds \
  --histogram=1 \
  \
  --memtablerep=skip_list \
  --bloom_bits=10 \
  --open_files=-1 \
  --subcompactions=$subcompactions \
  \
  $bench_args"

level_const_params="
  $const_params_base \
  --compaction_style=0 \
  --level_compaction_dynamic_level_bytes=true \
  --pin_l0_filter_and_index_blocks_in_cache=1 \
  $soft_pending_arg \
  $hard_pending_arg \
"

# TODO:
#   pin_l0_filter_and..., is this OK?
univ_const_params="
  $const_params_base \
  --compaction_style=1 \
  --pin_l0_filter_and_index_blocks_in_cache=1 \
  --universal_min_merge_width=$univ_min_merge_width \
  --universal_max_merge_width=$univ_max_merge_width \
  --universal_size_ratio=$univ_size_ratio \
  --universal_max_size_amplification_percent=$univ_max_size_amp \
  --universal_allow_trivial_move=$univ_allow_trivial_move \
"

if [ -z $UNIVERSAL ]; then
const_params="$level_const_params"
l0_file_num_compaction_trigger=${LEVEL0_FILE_NUM_COMPACTION_TRIGGER:-4}
l0_slowdown_writes_trigger=${LEVEL0_SLOWDOWN_WRITES_TRIGGER:-20}
l0_stop_writes_trigger=${LEVEL0_STOP_WRITES_TRIGGER:-30}
else
const_params="$univ_const_params"
l0_file_num_compaction_trigger=${LEVEL0_FILE_NUM_COMPACTION_TRIGGER:-8}
l0_slowdown_writes_trigger=${LEVEL0_SLOWDOWN_WRITES_TRIGGER:-20}
l0_stop_writes_trigger=${LEVEL0_STOP_WRITES_TRIGGER:-30}
fi

l0_config="
  --level0_file_num_compaction_trigger=$l0_file_num_compaction_trigger \
  --level0_slowdown_writes_trigger=$l0_slowdown_writes_trigger \
  --level0_stop_writes_trigger=$l0_stop_writes_trigger"

# You probably don't want to set both --writes and --duration
if [ $duration -gt 0 ]; then
  const_params="$const_params --duration=$duration"
fi
if [ $writes -gt 0 ]; then
  const_params="$const_params --writes=$writes"
fi

params_w="$l0_config \
          --max_background_jobs=$max_background_jobs \
          --max_write_buffer_number=8 \
          $compact_bytes_limit \
          $const_params"

params_bulkload="--max_background_jobs=$max_background_jobs \
                 --max_write_buffer_number=8 \
                 --allow_concurrent_memtable_write=false \
                 --level0_file_num_compaction_trigger=$((10 * M)) \
                 --level0_slowdown_writes_trigger=$((10 * M)) \
                 --level0_stop_writes_trigger=$((10 * M)) \
                 $const_params "

params_fillseq="--allow_concurrent_memtable_write=false \
                $params_w "

#
# Tune values for level and universal compaction.
# For universal compaction, these level0_* options mean total sorted of runs in
# LSM. In level-based compaction, it means number of L0 files.
#
params_level_compact="$const_params \
                --max_background_flushes=4 \
                --max_write_buffer_number=4 \
                --level0_file_num_compaction_trigger=4 \
                --level0_slowdown_writes_trigger=16 \
                --level0_stop_writes_trigger=20"

params_univ_compact="$const_params \
                --max_background_flushes=4 \
                --max_write_buffer_number=4 \
                --level0_file_num_compaction_trigger=8 \
                --level0_slowdown_writes_trigger=16 \
                --level0_stop_writes_trigger=20"

function get_time_cmd() {
  output=$1
  echo "/usr/bin/time -f '%e %U %S' -o $output"
}

function month_to_num() {
    local date_str=$1
    date_str="${date_str/Jan/01}"
    date_str="${date_str/Feb/02}"
    date_str="${date_str/Mar/03}"
    date_str="${date_str/Apr/04}"
    date_str="${date_str/May/05}"
    date_str="${date_str/Jun/06}"
    date_str="${date_str/Jul/07}"
    date_str="${date_str/Aug/08}"
    date_str="${date_str/Sep/09}"
    date_str="${date_str/Oct/10}"
    date_str="${date_str/Nov/11}"
    date_str="${date_str/Dec/12}"
    echo $date_str
}

function start_stats {
  output=$1
  iostat -y -mx 1  >& $output.io &
  vmstat 1 >& $output.vm &
}

function stop_stats {
  output=$1
  killall iostat
  killall vmstat
  sleep 1
  gzip $output.io
  gzip $output.vm
}

function summarize_result {
  test_out=$1
  test_name=$2
  bench_name=$3

  # Note that this function assumes that the benchmark executes long enough so
  # that "Compaction Stats" is written to stdout at least once. If it won't
  # happen then empty output from grep when searching for "Sum" will cause
  # syntax errors.
  version=$( grep ^RocksDB: $test_out | awk '{ print $3 }' )
  date=$( grep ^Date: $test_out | awk '{ print $6 "-" $3 "-" $4 "T" $5 }' )
  my_date=$( month_to_num $date )
  uptime=$( grep ^Uptime\(secs $test_out | tail -1 | awk '{ printf "%.0f", $2 }' )
  stall_pct=$( grep "^Cumulative stall" $test_out| tail -1  | awk '{  print $5 }' )
  nstall=$( grep ^Stalls\(count\):  $test_out | tail -1 | awk '{ print $2 + $4 + $6 + $8 + $10 + $14 + $18 + $20 }' )
  ops_sec=$( grep ^${bench_name} $test_out | awk '{ print $5 }' )
  mb_sec=$( grep ^${bench_name} $test_out | awk '{ print $7 }' )

  flush_wgb=$( grep "^Flush(GB)" $test_out | tail -1 | awk '{ print $3 }' | tr ',' ' ' | awk '{ print $1 }' )
  sum_wgb=$( grep "^Cumulative compaction" $test_out | tail -1 | awk '{ printf "%.1f", $3 }' )
  cmb_ps=$( grep "^Cumulative compaction" $test_out | tail -1 | awk '{ print $6 }' )
  if [[ "$sum_wgb" == "" || "$flush_wgb" == "" || "$flush_wgb" == "0.000" ]]; then
    wamp=""
  else
    wamp=$( echo "$sum_wgb / $flush_wgb" | bc -l | awk '{ printf "%.1f", $1 }' )
  fi
  c_secs=$( grep "^Cumulative compaction" $test_out | tail -1 | awk '{ print $15 }' )

  sum_size=$( grep "^ Sum" $test_out | tail -1 | awk '{ printf "%.0f%s", $3, $4 }' )
  usecs_op=$( grep ^${bench_name} $test_out | awk '{ printf "%.1f", $3 }' )
  p50=$( grep "^Percentiles:" $test_out | tail -1 | awk '{ printf "%.1f", $3 }' )
  p99=$( grep "^Percentiles:" $test_out | tail -1 | awk '{ printf "%.0f", $7 }' )
  p999=$( grep "^Percentiles:" $test_out | tail -1 | awk '{ printf "%.0f", $9 }' )
  p9999=$( grep "^Percentiles:" $test_out | tail -1 | awk '{ printf "%.0f", $11 }' )
  pmax=$( grep "^Min: " $test_out | grep Median: | grep Max: | awk '{ printf "%.0f", $6 }' )

  time_out=$test_out.time
  u_cpu=$( awk '{ printf "%.1f", $2 / 1000.0 }' $time_out )
  s_cpu=$( awk '{ printf "%.1f", $3 / 1000.0  }' $time_out )

  # if the report TSV (Tab Separate Values) file does not yet exist, create it and write the header row to it
  if [ ! -f "$report" ]; then
    echo -e "# ops_sec - operations per second" >> $report
    echo -e "# mb_sec - ops_sec * size-of-operation-in-MB" >> $report
    echo -e "# db_size - database size" >> $report
    echo -e "# c_wgb - GB written by compaction" >> $report
    echo -e "# w_amp - Write-amplification as (bytes written by compaction / bytes written by memtable flush)" >> $report
    echo -e "# c_mbps - Average write rate for compaction" >> $report
    echo -e "# c_secs - Wall clock seconds doing compaction" >> $report
    echo -e "# usec_op - Microseconds per operation" >> $report
    echo -e "# p50, p99, p99.9, p99.99 - 50th, 99th, 99.9th, 99.99th percentile response time in usecs" >> $report
    echo -e "# pmax - max response time in usecs" >> $report
    echo -e "# uptime - RocksDB uptime in seconds" >> $report
    echo -e "# stall% - Percentage of time writes are stalled" >> $report
    echo -e "# Nstall - Number of stalls" >> $report
    echo -e "# u_cpu - #seconds/1000 of user CPU" >> $report
    echo -e "# s_cpu - #seconds/1000 of system CPU" >> $report
    echo -e "# test - Name of test" >> $report
    echo -e "# date - Date/time of test" >> $report
    echo -e "# version - RocksDB version" >> $report
    echo -e "# job_id - User-provided job ID" >> $report
    echo -e "ops_sec\tmb_sec\tdb_size\tc_wgb\tw_amp\tc_mbps\tc_secs\tusec_op\tp50\tp99\tp99.9\tp99.99\tpmax\tuptime\tstall%\tNstall\tu_cpu\ts_cpu\ttest\tdate\tversion\tjob_id" \
      >> $report
  fi

  echo -e "$ops_sec\t$mb_sec\t$sum_size\t$sum_wgb\t$wamp\t$cmb_ps\t$c_secs\t$usecs_op\t$p50\t$p99\t$p999\t$p9999\t$pmax\t$uptime\t$stall_pct\t$nstall\t$u_cpu\t$s_cpu\t$test_name\t$my_date\t$version\t$job_id" \
    >> $report
}

function run_bulkload {
  # This runs with a vector memtable and the WAL disabled to load faster. It is still crash safe and the
  # client can discover where to restart a load after a crash. I think this is a good way to load.
  echo "Bulk loading $num_keys random keys"
  log_file_name=$output_dir/benchmark_bulkload_fillrandom.log
  time_cmd=$( get_time_cmd $log_file_name.time )
  cmd="$time_cmd ./db_bench --benchmarks=fillrandom \
       --use_existing_db=0 \
       --disable_auto_compactions=1 \
       --sync=0 \
       $params_bulkload \
       --threads=1 \
       --memtablerep=vector \
       --allow_concurrent_memtable_write=false \
       --disable_wal=1 \
       --seed=$( date +%s ) \
       2>&1 | tee -a $log_file_name"
  if [[ "$job_id" != "" ]]; then
    echo "Job ID: ${job_id}" > $log_file_name
    echo $cmd | tee -a $log_file_name
  else
    echo $cmd | tee $log_file_name
  fi
  eval $cmd
  summarize_result $log_file_name bulkload fillrandom

  echo "Compacting..."
  log_file_name=$output_dir/benchmark_bulkload_compact.log
  time_cmd=$( get_time_cmd $log_file_name.time )
  cmd="$time_cmd ./db_bench --benchmarks=compact \
       --use_existing_db=1 \
       --disable_auto_compactions=1 \
       --sync=0 \
       $params_w \
       --threads=1 \
       2>&1 | tee -a $log_file_name"
  if [[ "$job_id" != "" ]]; then
    echo "Job ID: ${job_id}" > $log_file_name
    echo $cmd | tee -a $log_file_name
  else
    echo $cmd | tee $log_file_name
  fi
  eval $cmd
}

#
# Parameter description:
#
# $1 - 1 if I/O statistics should be collected.
# $2 - compaction type to use (level=0, universal=1).
# $3 - number of subcompactions.
# $4 - number of maximum background compactions.
#
function run_manual_compaction_worker {
  # This runs with a vector memtable and the WAL disabled to load faster.
  # It is still crash safe and the client can discover where to restart a
  # load after a crash. I think this is a good way to load.
  echo "Bulk loading $num_keys random keys for manual compaction."

  log_file_name=$output_dir/benchmark_man_compact_fillrandom_$3.log

  if [ "$2" == "1" ]; then
    extra_params=$params_univ_compact
  else
    extra_params=$params_level_compact
  fi

  # Make sure that fillrandom uses the same compaction options as compact.
  time_cmd=$( get_time_cmd $log_file_name.time )
  cmd="$time_cmd ./db_bench --benchmarks=fillrandom \
       --use_existing_db=0 \
       --disable_auto_compactions=0 \
       --sync=0 \
       $extra_params \
       --threads=$num_threads \
       --compaction_measure_io_stats=$1 \
       --compaction_style=$2 \
       --subcompactions=$3 \
       --memtablerep=vector \
       --allow_concurrent_memtable_write=false \
       --disable_wal=1 \
       --max_background_compactions=$4 \
       --seed=$( date +%s ) \
       2>&1 | tee -a $log_file_name"

  if [[ "$job_id" != "" ]]; then
    echo "Job ID: ${job_id}" > $log_file_name
    echo $cmd | tee -a $log_file_name
  else
    echo $cmd | tee $log_file_name
  fi
  eval $cmd

  summarize_result $log_file_namefillrandom_output_file man_compact_fillrandom_$3 fillrandom

  echo "Compacting with $3 subcompactions specified ..."

  log_file_name=$output_dir/benchmark_man_compact_$3.log

  # This is the part we're really interested in. Given that compact benchmark
  # doesn't output regular statistics then we'll just use the time command to
  # measure how long this step takes.
  cmd="{ \
       time ./db_bench --benchmarks=compact \
       --use_existing_db=1 \
       --disable_auto_compactions=0 \
       --sync=0 \
       $extra_params \
       --threads=$num_threads \
       --compaction_measure_io_stats=$1 \
       --compaction_style=$2 \
       --subcompactions=$3 \
       --max_background_compactions=$4 \
       ;}
       2>&1 | tee -a $log_file_name"

  if [[ "$job_id" != "" ]]; then
    echo "Job ID: ${job_id}" > $log_file_name
    echo $cmd | tee -a $log_file_name
  else
    echo $cmd | tee $log_file_name
  fi
  eval $cmd

  # Can't use summarize_result here. One way to analyze the results is to run
  # "grep real" on the resulting log files.
}

function run_univ_compaction {
  # Always ask for I/O statistics to be measured.
  io_stats=1

  # Values: kCompactionStyleLevel = 0x0, kCompactionStyleUniversal = 0x1.
  compaction_style=1

  # Define a set of benchmarks.
  subcompactions=(1 2 4 8 16)
  max_background_compactions=(16 16 8 4 2)

  i=0
  total=${#subcompactions[@]}

  # Execute a set of benchmarks to cover variety of scenarios.
  while [ "$i" -lt "$total" ]
  do
    run_manual_compaction_worker $io_stats $compaction_style ${subcompactions[$i]} \
      ${max_background_compactions[$i]}
    ((i++))
  done
}

function run_fillseq {
  # This runs with a vector memtable. WAL can be either disabled or enabled
  # depending on the input parameter (1 for disabled, 0 for enabled). The main
  # benefit behind disabling WAL is to make loading faster. It is still crash
  # safe and the client can discover where to restart a load after a crash. I
  # think this is a good way to load.

  # Make sure that we'll have unique names for all the files so that data won't
  # be overwritten.
  if [ $1 == 1 ]; then
    log_file_name="${output_dir}/benchmark_fillseq.wal_disabled.v${value_size}.log"
    test_name=fillseq.wal_disabled.v${value_size}
  else
    log_file_name="${output_dir}/benchmark_fillseq.wal_enabled.v${value_size}.log"
    test_name=fillseq.wal_enabled.v${value_size}
  fi

  # For Leveled compaction hardwire this to 0 so that data that is trivial-moved
  # to larger levels (3, 4, etc) will be compressed.
  if [ -z $UNIVERSAL ]; then
    ml2c=0
  else
    ml2c=$min_level_to_compress
  fi

  echo "Loading $num_keys keys sequentially"
  time_cmd=$( get_time_cmd $log_file_name.time )
  cmd="$time_cmd ./db_bench --benchmarks=fillseq \
       --use_existing_db=0 \
       --sync=0 \
       $params_fillseq \
       --min_level_to_compress=$ml2c \
       --threads=1 \
       --memtablerep=vector \
       --allow_concurrent_memtable_write=false \
       --disable_wal=$1 \
       --seed=$( date +%s ) \
       2>&1 | tee -a $log_file_name"
  if [[ "$job_id" != "" ]]; then
    echo "Job ID: ${job_id}" > $log_file_name
    echo $cmd | tee -a $log_file_name
  else
    echo $cmd | tee $log_file_name
  fi
  start_stats $log_file_name.stats
  eval $cmd
  stop_stats $log_file_name.stats

  # The constant "fillseq" which we pass to db_bench is the benchmark name.
  summarize_result $log_file_name $test_name fillseq
}

function run_lsm {
  # This flushes the memtable and L0 to get the LSM tree into a deterministic
  # state for read-only tests that will follow.
  echo "Flush memtable, wait, compact L0, wait"
  job=$1

  if [ $job = flush_mt_l0 ]; then
    benchmarks=levelstats,flush,waitforcompaction,compact0,waitforcompaction,memstats,levelstats
  elif [ $job = waitforcompaction ]; then
    benchmarks=levelstats,waitforcompaction,memstats,levelstats
  else
    echo Job unknown: $job
    exit $EXIT_NOT_COMPACTION_TEST
  fi

  log_file_name=$output_dir/benchmark_${job}.log
  time_cmd=$( get_time_cmd $log_file_name.time )
  cmd="$time_cmd ./db_bench --benchmarks=$benchmarks \
       --use_existing_db=1 \
       --sync=0 \
       $params_w \
       --threads=1 \
       --seed=$( date +%s ) \
       2>&1 | tee -a $log_file_name"
  if [[ "$job_id" != "" ]]; then
    echo "Job ID: ${job_id}" > $log_file_name
    echo $cmd | tee -a $log_file_name
  else
    echo $cmd | tee $log_file_name
  fi
  start_stats $log_file_name.stats
  # waitforcompaction can hang with universal (compaction_style=1)
  # see bug https://github.com/facebook/rocksdb/issues/9275
  eval $cmd
  stop_stats $log_file_name.stats
  # Don't summarize, the log doesn't have the output needed for it
}

function run_change {
  output_name=$1
  grep_name=$2
  benchmarks=$3
  echo "Do $num_keys random $output_name"
  log_file_name="$output_dir/benchmark_${output_name}.t${num_threads}.s${syncval}.log"
  time_cmd=$( get_time_cmd $log_file_name.time )
  cmd="$time_cmd ./db_bench --benchmarks=$benchmarks \
       --use_existing_db=1 \
       --sync=$syncval \
       $params_w \
       --threads=$num_threads \
       --merge_operator=\"put\" \
       --seed=$( date +%s ) \
       2>&1 | tee -a $log_file_name"
  if [[ "$job_id" != "" ]]; then
    echo "Job ID: ${job_id}" > $log_file_name
    echo $cmd | tee -a $log_file_name
  else
    echo $cmd | tee $log_file_name
  fi
  start_stats $log_file_name.stats
  eval $cmd
  stop_stats $log_file_name.stats
  summarize_result $log_file_name ${output_name}.t${num_threads}.s${syncval} $grep_name
}

function run_filluniquerandom {
  echo "Loading $num_keys unique keys randomly"
  log_file_name=$output_dir/benchmark_filluniquerandom.log
  time_cmd=$( get_time_cmd $log_file_name.time )
  cmd="$time_cmd ./db_bench --benchmarks=filluniquerandom \
       --use_existing_db=0 \
       --sync=0 \
       $params_w \
       --threads=1 \
       --seed=$( date +%s ) \
       2>&1 | tee -a $log_file_name"
  if [[ "$job_id" != "" ]]; then
    echo "Job ID: ${job_id}" > $log_file_name
    echo $cmd | tee -a $log_file_name
  else
    echo $cmd | tee $log_file_name
  fi
  start_stats $log_file_name.stats
  eval $cmd
  stop_stats $log_file_name.stats
  summarize_result $log_file_name filluniquerandom filluniquerandom
}

function run_readrandom {
  echo "Reading $num_keys random keys"
  log_file_name="${output_dir}/benchmark_readrandom.t${num_threads}.log"
  time_cmd=$( get_time_cmd $log_file_name.time )
  cmd="$time_cmd ./db_bench --benchmarks=readrandom \
       --use_existing_db=1 \
       $params_w \
       --threads=$num_threads \
       --seed=$( date +%s ) \
       2>&1 | tee -a $log_file_name"
  if [[ "$job_id" != "" ]]; then
    echo "Job ID: ${job_id}" > $log_file_name
    echo $cmd | tee -a $log_file_name
  else
    echo $cmd | tee $log_file_name
  fi
  start_stats $log_file_name.stats
  eval $cmd
  stop_stats $log_file_name.stats
  summarize_result $log_file_name readrandom.t${num_threads} readrandom
}

function run_multireadrandom {
  echo "Multi-Reading $num_keys random keys"
  log_file_name="${output_dir}/benchmark_multireadrandom.t${num_threads}.log"
  time_cmd=$( get_time_cmd $log_file_name.time )
  cmd="$time_cmd ./db_bench --benchmarks=multireadrandom \
       --use_existing_db=1 \
       --threads=$num_threads \
       --batch_size=10 \
       $params_w \
       --seed=$( date +%s ) \
       2>&1 | tee -a $log_file_name"
  if [[ "$job_id" != "" ]]; then
    echo "Job ID: ${job_id}" > $log_file_name
    echo $cmd | tee -a $log_file_name
  else
    echo $cmd | tee $log_file_name
  fi
  start_stats $log_file_name.stats
  eval $cmd
  stop_stats $log_file_name.stats
  summarize_result $log_file_name multireadrandom.t${num_threads} multireadrandom
}

function run_readwhile {
  operation=$1
  echo "Reading $num_keys random keys while $operation"
  log_file_name="${output_dir}/benchmark_readwhile${operation}.t${num_threads}.log"
  time_cmd=$( get_time_cmd $log_file_name.time )
  cmd="$time_cmd ./db_bench --benchmarks=readwhile${operation} \
       --use_existing_db=1 \
       --sync=$syncval \
       $params_w \
       --threads=$num_threads \
       --merge_operator=\"put\" \
       --seed=$( date +%s ) \
       2>&1 | tee -a $log_file_name"
  if [[ "$job_id" != "" ]]; then
    echo "Job ID: ${job_id}" > $log_file_name
    echo $cmd | tee -a $log_file_name
  else
    echo $cmd | tee $log_file_name
  fi
  start_stats $log_file_name.stats
  eval $cmd
  stop_stats $log_file_name.stats
  summarize_result $log_file_name readwhile${operation}.t${num_threads} readwhile${operation}
}

function run_rangewhile {
  operation=$1
  full_name=$2
  reverse_arg=$3
  log_file_name="${output_dir}/benchmark_${full_name}.t${num_threads}.log"
  time_cmd=$( get_time_cmd $log_file_name.time )
  echo "Range scan $num_keys random keys while ${operation} for reverse_iter=${reverse_arg}"
  cmd="$time_cmd ./db_bench --benchmarks=seekrandomwhile${operation} \
       --use_existing_db=1 \
       --sync=$syncval \
       $params_w \
       --threads=$num_threads \
       --merge_operator=\"put\" \
       --seek_nexts=$num_nexts_per_seek \
       --reverse_iterator=$reverse_arg \
       --seed=$( date +%s ) \
       2>&1 | tee -a $log_file_name"
  echo $cmd | tee $log_file_name
  start_stats $log_file_name.stats
  eval $cmd
  stop_stats $log_file_name.stats
  summarize_result $log_file_name ${full_name}.t${num_threads} seekrandomwhile${operation}
}

function run_range {
  full_name=$1
  reverse_arg=$2
  log_file_name="${output_dir}/benchmark_${full_name}.t${num_threads}.log"
  time_cmd=$( get_time_cmd $log_file_name.time )
  echo "Range scan $num_keys random keys for reverse_iter=${reverse_arg}"
  cmd="$time_cmd ./db_bench --benchmarks=seekrandom \
       --use_existing_db=1 \
       $params_w \
       --threads=$num_threads \
       --seek_nexts=$num_nexts_per_seek \
       --reverse_iterator=$reverse_arg \
       --seed=$( date +%s ) \
       2>&1 | tee -a $log_file_name"
  if [[ "$job_id" != "" ]]; then
    echo "Job ID: ${job_id}" > $log_file_name
    echo $cmd | tee -a $log_file_name
  else
    echo $cmd | tee $log_file_name
  fi
  start_stats $log_file_name.stats
  eval $cmd
  stop_stats $log_file_name.stats
  summarize_result $log_file_name ${full_name}.t${num_threads} seekrandom
}

function run_randomtransaction {
  echo "..."
  log_file_name=$output_dir/benchmark_randomtransaction.log
  time_cmd=$( get_time_cmd $log_file_name.time )
  cmd="$time_cmd ./db_bench $params_r --benchmarks=randomtransaction \
       --num=$num_keys \
       --transaction_db \
       --threads=5 \
       --transaction_sets=5 \
       2>&1 | tee $log_file_name"
  if [[ "$job_id" != "" ]]; then
    echo "Job ID: ${job_id}" > $log_file_name
    echo $cmd | tee -a $log_file_name
  else
    echo $cmd | tee $log_file_name
  fi
  start_stats $log_file_name.stats
  eval $cmd
  stop_stats $log_file_name.stats
}

function now() {
  echo `date +"%s"`
}


echo "===== Benchmark ====="

# Run!!!
IFS=',' read -a jobs <<< $bench_cmd
# shellcheck disable=SC2068
for job in ${jobs[@]}; do

  if [ $job != debug ]; then
    echo "Starting $job (ID: $job_id) at `date`" | tee -a $schedule
  fi

  start=$(now)
  if [ $job = bulkload ]; then
    run_bulkload
  elif [ $job = flush_mt_l0 ]; then
    run_lsm flush_mt_l0
  elif [ $job = waitforcompaction ]; then
    run_lsm waitforcompaction
  elif [ $job = fillseq_disable_wal ]; then
    run_fillseq 1
  elif [ $job = fillseq_enable_wal ]; then
    run_fillseq 0
  elif [ $job = overwrite ]; then
    run_change overwrite overwrite overwrite
  elif [ $job = overwritesome ]; then
    # This uses a different name for overwrite results so it can be run twice in one benchmark run.
    run_change overwritesome overwrite overwrite
  elif [ $job = overwriteandwait ]; then
    run_change overwriteandwait overwrite overwrite,waitforcompaction
  elif [ $job = updaterandom ]; then
    run_change updaterandom updaterandom updaterandom
  elif [ $job = mergerandom ]; then
    run_change mergerandom mergerandom mergerandom
  elif [ $job = filluniquerandom ]; then
    run_filluniquerandom
  elif [ $job = readrandom ]; then
    run_readrandom
  elif [ $job = multireadrandom ]; then
    run_multireadrandom
  elif [ $job = fwdrange ]; then
    run_range $job false
  elif [ $job = revrange ]; then
    run_range $job true
  elif [ $job = readwhilewriting ]; then
    run_readwhile writing
  elif [ $job = readwhilemerging ]; then
    run_readwhile merging
  elif [ $job = fwdrangewhilewriting ]; then
    run_rangewhile writing $job false
  elif [ $job = revrangewhilewriting ]; then
    run_rangewhile writing $job true
  elif [ $job = fwdrangewhilemerging ]; then
    run_rangewhile merging $job false
  elif [ $job = revrangewhilemerging ]; then
    run_rangewhile merging $job true
  elif [ $job = randomtransaction ]; then
    run_randomtransaction
  elif [ $job = universal_compaction ]; then
    run_univ_compaction
  elif [ $job = debug ]; then
    num_keys=1000; # debug
    echo "Setting num_keys to $num_keys"
  else
    echo "unknown job $job"
    exit $EXIT_UNKNOWN_JOB
  fi
  end=$(now)

  if [ $job != debug ]; then
    echo "Completed $job (ID: $job_id) in $((end-start)) seconds" | tee -a $schedule
  fi

  echo -e "ops_sec\tmb_sec\tdb_size\tc_wgb\tw_amp\tc_mbps\tc_secs\tusec_op\tp50\tp99\tp99.9\tp99.99\tpmax\tuptime\tstall%\tNstall\tu_cpu\ts_cpu\ttest\tdate\tversion\tjob_id"
  tail -1 $report

done
