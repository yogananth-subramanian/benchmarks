#!/bin/bash
set -x
CURRENT_DIR="$(dirname "$(realpath "$0")")"
source ${CURRENT_DIR}/../utils/common.sh


function parseResults() {
	TOTAL_RUNS=1
	#TOTAL_ITR=1

	for (( run=0 ; run<"${TOTAL_ITR}" ;run++))
	do
	    for metric in "${LATENCY_LOGS[@]}"
		do
			RESULTS_DIR_P=${RESULTS_DIR}/ITR-${run}
			RESULT_LOG=${RESULTS_DIR_P}/workload-Kafka.json
			eval ${metric}=`cat ${RESULT_LOG} |jq --arg keyvar "$metric" '.[$keyvar]' `
			echo ${!metric} >> ${RESULTS_DIR}/${metric}-measure-temp.log
		done

		#echo "${run} , ${CPU_REQ} , ${MEM_REQ} , ${CPU_LIM} , ${MEM_LIM} , ${thrp_sum} , ${responsetime} , ${wer_sum} , ${max_responsetime} , ${stddev_responsetime}" >> ${RESULTS_DIR_J}/Latency-raw.log
		#echo "${run}${csvout}" >> ${RESULTS_DIR}/Metrics-wrk.log
	done
	for  metric in "${LATENCY_LOGS[@]}"
	do
		val=$(echo `calcAvg ${RESULTS_DIR}/${metric}-measure-temp.log | cut -d "=" -f2`)
		eval ${metric}=${val}
		if [ $TOTAL_ITR -gt 1 ]
		then
			metric_ci=`php ${SCRIPT_REPO}/ci.php ${RESULTS_DIR}/${metric}-measure-temp.log`
			eval ci_${metric}=${metric_ci}
		fi

	done
	csvout=''
	for metric in "${LATENCY_LOGS[@]}"
	do
		dem=', '
		if [ $TOTAL_ITR -gt 1 ]
		then		
			eval temp_ci=ci_${metric}
			csvout=${csvout}${dem}${!metric}${dem}${!temp_ci}
		else
			csvout=${csvout}${dem}${!metric}
		fi
	done
	echo "${run}${csvout}"
	echo "${csvout}" >> ${RESULTS_DIR}/Metrics-wrk.log

}

#RESULTS_DIR=result
RESULTS_DIR=$1
TOTAL_ITR=$2
SCRIPT_REPO=$3
RESULTS_DIR_P=result/ITR-0
LATENCY_LOGS=(aggregatedPublishLatencyAvg aggregatedPublishLatency99pct aggregatedPublishLatency999pct aggregatedPublishLatency9999pct aggregatedEndToEndLatencyAvg aggregatedEndToEndLatency99pct aggregatedEndToEndLatency999pct aggregatedEndToEndLatency9999pct)
parseResults  
