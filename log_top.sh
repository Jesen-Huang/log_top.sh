#!/bin/bash

# log_top.sh
#
# Logs top output.

#Format of the file is, minus "-----" and leading "# ", is:
#
#-----
# %START:<ID>:<date +%Y-%m-%d_%H:%M:%S>
#
# <top output>
# %END:<ID>:<date +%Y-%m-%d_%H:%M:%S>
#-----
# top output includes a blank line at the end of its output.

set -eu

PIDFILE=/var/run/log_top.pid
DEFAULT_LOG=log_top.log

# LOG=$1
#
# Starts the logger (log()) and forks it as a subshell.
#
# LOG=$1, unset value log_top.log
start_logging()
{
  LOG="${1:-${DEFAULT_LOG}}"

  if [[ -f "$PIDFILE" ]]; then
    echo "Logger running.  Please stop it first via \`$0 stop'"
    return 1
  fi

  ID=`tac "$LOG" | grep -m 1 "^%END:[0-9]\+:.*" | sed -e 's/^%END://' -e 's/:.*$//'`
  ID="$((ID+1))"
  echo "ID of current run: $ID"

  log &
  pid=$!
  echo "PID of logger: $pid"
  echo "$pid" > $PIDFILE

  return 0
}

# Do the logging until clean_stop is executed at some point.  Meant to be
# forked.  This will grab the latest ID and increment it by one.
log()
{
  trap "clean_stop" SIGINT SIGTERM
  clean_stop()
  {
    keep_running=""
  }
  keep_running="yes" # Keep running in middle of a test.
  while [ "$keep_running" ]; do
    date=`date +%Y-%m-%d_%H:%M:%S`
    echo -e "%START:$ID:$date\n" >> $LOG
    top -bn 1 -c >> $LOG
    echo -e "%END:$ID:$date\n" >> $LOG
    sleep 1
  done

  exit 0
}

stop_logging()
{
  if [ ! -f "$PIDFILE" ]; then
    echo "log_top doesn't seem to be running." >&2
    return 1
  fi

  kill -15 `cat $PIDFILE` 2>/dev/null || ret=$?

  rm "$PIDFILE"

  if [ "${ret-0}" -ne "0" ]; then
    echo "Process was not killed.  Maybe it didn't exist?" >&2
    echo "\`$0 start\` should properly work now."
  fi

  return "${ret-0}"
}

# -d DATE
# -i ID
# FLAG=$1, format `date +%Y-%m-%d_%H:%M:%S`
# SPEC=$2
# FILE=$3
read_log()
{
  FLAG="$1"
  SPEC="$2"
  FILE="${3:-${DEFAULT_LOG}}"

  if [ "$FLAG" == "-d" ]; then
    DATE="$SPEC"
    REGEX="/^%START:[0-9]+:${DATE}.*$/,/^%END:[0-9]+:${DATE}.*$/"
  elif [ "$FLAG" == "-i" ]; then
    ID="$SPEC"
    REGEX="/^%START:${SPEC}:.*$/,/^%END:${SPEC}:.*$/"
  fi

  awk "${REGEX}" "$FILE"
}

query_log()
{
  FILE="${1-${DEFAULT_LOG}}"

  echo "Possible IDs from $FILE:"
  cat "$FILE" | awk -F: '/^%START:[0-9]+:/ {print $2}' | uniq | tr '\n'
}


# ID=$1
# FILE=${2-log_top.log}
query_num()
{
  if [ ! "${1-}" ]; then
    echo "Usage: $0 query-num id [file]"
  fi
  ID="$1"
  FILE="${2-${DEFAULT_LOG}}"
  read_log -i $ID | grep '^%START:' | wc -l
}

# Get date block from input.
block_date()
{
  sed -n -e '1s/^%START:[0-9]\+://p' | tr -d '\n'
}

# Get memory block from input.
block_mem()
{
  sed -n '3p' |
    sed -e 's/Mem: /,/' \
      -e 's/ used, /,/' \
      -e 's/ free, /,/' \
      -e 's/ shrd, /,/' \
      -e 's/ buff, /,/' \
      -e 's/ cached//'  \
      -e 's/K//g' | tr -d '\n'
}

# Get cpu block from input.
block_cpu()
{
  sed -n '4p' |
    sed -e 's/CPU: */,/' \
      -e 's/ usr */,/'   \
      -e 's/ sys */,/'   \
      -e 's/ nic */,/'   \
      -e 's/ idle */,/'  \
      -e 's/ io */,/'    \
      -e 's/ irq */,/'   \
      -e 's/ sirq//'     \
      -e 's/%//g' | tr -d '\n'
}

# Get loadavg block from input.
block_loadavg()
{
  sed -n '5p' | sed -e 's/Load average: /,/' -e 's: \|/:,:g' | tr -d '\n'
}

# Deletes first block of input.
block_delete_first()
{
  sed '1d' | sed -n '/^%START:/,$p'
}

block_selected_app()
{
  if [ "${1-}" ]; then
    AWK_STRING="$1"
  else
    AWK_STRING='1,$p'
  fi

  sed -n -e '/ *PID/,$p' -e '/^%END/q' | tac | sed -n '3,$p' | tac | awk "$AWK_STRING" | awk  '{print $9, $8, $6}'  | sed -e 's/^/,/' -e 's/ /,/g' | tr -d '\n'
}

# CSV file:
#
# date,mem.used,mem.free,mem.shrd,mem.buff,mem.cached,cpu.usr,cpu.sys,cpu.nic,cpu.idle,io,irq,sirq,load.avg.1min,load.avg.5min,load.avg.15min,running_threads,total_threads,last_running_pid
#
# Turn a file delimited with proper blocks into a CSV file.
block_csv()
{
  input=`cat`
  AWK_ARG="${1-}"

  while [ "$input" ]; do
    echo -n "$input" | block_date
    echo -n "$input" | block_mem
    echo -n "$input" | block_cpu
    echo -n "$input" | block_loadavg
    [ "$AWK_ARG" ] && echo -n "$input" | block_selected_app "$AWK_ARG"
    echo
    input=`echo "$input" | block_delete_first`
  done
}

do_csv()
{
  if [ ! "${1-}" ]; then
    echo "Usage: $0 csv id [awk_string]"
    exit 1
  fi

  ID="$1"
  AWK_STRING="${2-}"
  FILE="${3-}"

  echo -n "date,mem.used,mem.free,mem.shrd,mem.buff,mem.cached,cpu.usr,cpu.sys,cpu.nic,cpu.idle,io,irq,sirq,load.avg.1min,load.avg.5min,load.avg.15min,running_threads,total_threads,last_running_pid"

  if [ "$AWK_STRING" ]; then
    echo -n ",app,cpu.app,mem.app"
  fi
  echo

  read_log -i "$ID" "$FILE" | block_csv "$AWK_STRING"
}

# Gets usage.
#
# Generates usage documentation from self  Begin a line with #HELPQU for
# quickhelp (such as a syntax error) or #HELP for full help ($0 -h).
usage()
{
  QUICKHELPSTR="^ *#HELPQU "
  FULLHELPSTR="^ *#HELP\(QU\)\? "
  if [ "${1-}" == "-v" ]; then
    HELPSTR="$FULLHELPSTR"
  elif [ "${1-}" ]; then
    echo "Bad argument to usage().  Report this bug." >&2
    HELPSTR="$QUICKHELPSTR"
  else
    HELPSTR="$QUICKHELPSTR"
  fi

  echo -e "`grep \"$HELPSTR\" "$0" | sed \"s/$HELPSTR//\"`"
}

#BEG MAIN
if [ "${1-}" == "-h" ]; then
  #HELPQU -h
  #HELPQU   Extended help.\n
  usage -v
elif [ "${1-}" == "start" ]; then
  #HELP start [file]
  #HELP   Start logging to file.\n
  shift
  start_logging "${1-}"
elif [ "${1-}" == "read" ]; then
  #HELP read [file]
  #HELP   Read a specific date form file.\n
  shift
  read_log "$@"
elif [ "${1-}" == "stop" ]; then
  #HELP stop
  #HELP   Stop logging.
  stop_logging
elif [ "${1-}" == "query" ]; then
  #HELP query [file]
  #HELP   Get IDs from a file\n
  shift
  query_log "$@"
elif [ "${1-}" == "query-num" ]; then
  #HELP query-num num file
  #HELP   Get number of blocks from an ID from a file.\n
  shift
  query_num "$@"
elif [ "${1-}" == "csv" ]; then
  #HELP csv
  #HELP   Convert log to CSV.\n
  shift
  do_csv "$@"
else
  usage
  exit 1
fi
#END MAIN

exit 0

trap "usage true" EXIT

#DOC Default faile is "log_top.log".\n
