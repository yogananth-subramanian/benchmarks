#!/bin/bash
#
echo "running test"

IP=$1
ITERATIONS=$2
KAFKA_CONFIG=$(realpath $3)
TRIAL=0

WORKING_DIR=${PWD}
CURRENT_DIR="$(dirname "$(realpath "$0")")"
pushd "${CURRENT_DIR}" > /dev/null
SCRIPT_REPO=${PWD}
pushd ".." > /dev/null
#SCRIPT_REPO=${PWD}
pushd ".." > /dev/null

RESULTS_DIR_PATH=result


cleanup() {
  #grep -q work /tmp/nohup.out
  [ -f $TEMP1 ] && rm -rf $TEMP1
  [ -f $TEMP2 ] && rm -rf $TEMP2
  #grep -q work /tmp/nohup.out
}
trap cleanup EXIT
for iter in $(seq 2 `cat ${KAFKA_CONFIG}|wc -l`); do 
  TEMP1=`mktemp --suffix=.csv`
  TEMP2=`mktemp --suffix=.json`
  echo $TEMP1
  echo $TEMP2
  cat ${KAFKA_CONFIG}|head -n1 > $TEMP1
  cat ${KAFKA_CONFIG}|tail -n +${iter}|head -n 1 >> $TEMP1
  cat $TEMP1 |head -n2|jc --csv|jq .[0]|tee $TEMP2
  ${SCRIPT_REPO}/kafka-run.sh ${IP} ${ITERATIONS} $TEMP2

  RES_DIR=`ls -td -- ./result/*/ | head -n1 `
  echo $RES_DIR
  TRIAL=$((iter-2))
  if [[ -f "${RES_DIR}/output.csv" ]]; then
  ## Copy the output.csv into current directory
    for i in ${RES_DIR}/*workload-Kafka.json;do
      j=`basename $i`
      cp ${RES_DIR}/$j ./result/${TRIAL}'-'${j}
    done
    cp -r ${RES_DIR}/output.csv ${WORKING_DIR}/
    sed -i 's/[[:blank:]]//g' ${WORKING_DIR}/output.csv
    if [[ ${iter} == 2 ]]; then
      cp ${WORKING_DIR}/output.csv ${WORKING_DIR}/experiment-output.csv
    else
      tail -n+2 ${WORKING_DIR}/output.csv >> ${WORKING_DIR}/experiment-output.csv
    fi
    rm -rf ${WORKING_DIR}/output.csv
  fi
  cleanup
done
