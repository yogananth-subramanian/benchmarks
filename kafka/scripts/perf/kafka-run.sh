#!/bin/bash
CURRENT_DIR="$(dirname "$(realpath "$0")")"
pushd "${CURRENT_DIR}" > /dev/null
SCRIPT_REPO=${PWD}
pushd ".." > /dev/null
#SCRIPT_REPO=${PWD}
pushd ".." > /dev/null

RESULTS_DIR_PATH=result
RESULTS_DIR_ROOT=${RESULTS_DIR_PATH}/kafka-$(date +%Y%m%d%H%M)
rm -rf ${RESULTS_DIR_PATH}/kafka-*
mkdir -p ${RESULTS_DIR_ROOT}

client_ip=$1
TOTAL_ITR=$2
KAFKA_CONFIG=$3
HPO_CONFIG=$4
KEY=~/.ssh/kafka_cloud
SSH_OPTION=" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "
SSH_USER="ec2-user"
SET_TUNED=false

if [[ $# == 4 ]];then
  declare -A tunables 
  for ((i=0; i<$(cat $HPO_CONFIG |jq '. | length'); i++ ))
   do
    echo $i
    echo `cat $HPO_CONFIG |jq -r .[$i].tunable_name`
    echo `cat $HPO_CONFIG |jq -r .[$i].tunable_value`
    tunables[`cat $HPO_CONFIG |jq -r .[$i].tunable_name`]=`cat $HPO_CONFIG |jq -r .[$i].tunable_value`
  done
  echo ${tunables[@]}
fi

declare -A kafka
for i in $(cat $KAFKA_CONFIG |jq -r '.|keys[]')
 do
  echo $i
  echo `cat $KAFKA_CONFIG |jq  '.["'$i'"]'`
  #echo `cat $HPO_CONFIG |jq -r .[$i].tunable_value`
  kafka[$i]=`cat $KAFKA_CONFIG |jq  '.["'${i}'"]'|sed -e 's/"//g'`
  #export $i=${kafka[$i]}
done
echo ${kafka[@]}
echo ${kafka["messageSize"]}

LATENCY_LOGS=(aggregatedPublishLatencyAvg aggregatedPublishLatency95pct aggregatedPublishLatency99pct aggregatedPublishLatency999pct aggregatedPublishLatency9999pct aggregatedEndToEndLatencyAvg  aggregatedEndToEndLatency95pct   aggregatedEndToEndLatency99pct aggregatedEndToEndLatency999pct aggregatedEndToEndLatency9999pct)

WORKLOAD=(topics partitionsPerTopic messageSize subscriptionsPerTopic producersPerTopic consumerPerSubscription producerRate consumerBacklogSizeGB testDurationMinutes)

declare -A producerConfig=(["acks"]=acks ["linger_ms"]=linger.ms ["batch_size"]=batch.size)

declare -A consumerConfig=(["fetch_min_bytes"]=fetch.min.bytes ["max_partition_fetch_bytes"]=max.partition.fetch.bytes ["fetch_max_bytes"]=fetch.max.bytes)


function set_tuned() {
 for i in ${!tunables[@]}
  do
   export $i=${tunables[$i]}
   echo ${!i}
 done
}

declare -A kafka_default=(["topics"]=1 ["partitionsPerTopic"]=9 ["messageSize"]=1024 ["subscriptionsPerTopic"]=1 ["producersPerTopic"]=9 ["consumerPerSubscription"]=9  ["consumerBacklogSizeGB"]=0 ["testDurationMinutes"]=2 ["batch_size"]=200000 ["fetch_min_bytes"]=100000 ["throughput"]=1048576 ["producerRate"]=1048576  ["acks"]=all ["linger_ms"]=100 ["max_partition_fetch_bytes"]=10485760 ["fetch_max_bytes"]=52428800)

if [[ $# == 4 ]];then
  set_tuned
fi

if [[ -z ${4:-} ]]; then
  DEPLOY_LOGS=(${!kafka[@]})
else
  DEPLOY_LOGS=(${!kafka_default[@]})
fi

for i in ${DEPLOY_LOGS[@]}
 do
  if [ "${i}" = "producerRate" ]; then
   [[ -z "${!i}" ]] && export producerRate=`expr ${kafka["throughput"]:-${kafka_default["throughput"]}} / ${kafka["messageSize"]:-${kafka_default["messageSize"]}}`
  elif [ "${i}" = "consumerPerSubscription" ]; then
   [[ -z "${!i}" ]] && export consumerPerSubscription=${kafka["partitionsPerTopic"]:-${kafka_default["partitionsPerTopic"]}}
  elif [ "${i}" = "partitionsPerTopic" ]; then
   [[ -z "${!i}" ]] && export partitionsPerTopic=${kafka["consumerPerSubscription"]:-${kafka_default["consumerPerSubscription"]}}
  else
   [[ -z "${!i}" ]] && export $i=${kafka[$i]:-${kafka_default[$i]}}
  fi
  echo $i
  echo ${!i}
done

runtime=$(($testDurationMinutes*60+180))

function write_to_csv() {
  csvout=''
  name=$1[@]
  csv_file=$2
  values=$3
  array_var=("${!name}")
  for metric in "${array_var[@]}"
  do
    dem=', '
    if $values
    then
      csvout=$csvout$dem${!metric}
    else
      csvout=$csvout$dem${metric}
      if [ $TOTAL_ITR -gt 1 ] && [ 'LATENCY_LOGS' == $1 ]
      then
        csvout=${csvout}${dem}ci_${metric}
      fi
    fi
  done
  echo $csvout >> ${RESULTS_DIR_ROOT}/$csv_file
}

write_to_csv LATENCY_LOGS Metrics-wrk.log false
write_to_csv DEPLOY_LOGS deploy-config.log false
write_to_csv DEPLOY_LOGS deploy-config.log true
ERROR=false

[[ -z "${dirty_bytes}" ]] && [[ ! -z "${dirty_background_bytes}" ]] && export dirty_bytes=1073741824
[[ ! -z "${mem_max}"  ]] && [[  -z "${tcp_def}"  ]] && export tcp_mem="\"4096 `expr ${mem_max} / 8` ${mem_max}\""
[[ ! -z "${mem_max}"  ]] && [[ ! -z "${tcp_def}"  ]] && export tcp_mem="\"4096 ${tcp_def} ${mem_max}\""
envsubst < ${CURRENT_DIR}/../../templates/kafka.yaml > /tmp/kafka.yaml
sed -i '/=[[:space:]]*$/d' /tmp/kafka.yaml
for i in $(echo -e  `cat /tmp/kafka.yaml |jc --yaml -r|jq '.[].spec|.profile|.[].data'`|sed -e 's/"//g'|jc --ini|jq '.[]|length'|tail -n+2);do if [[ $i >=1 ]] ;then SET_TUNED=true;fi;done
echo ${SET_TUNED}
${SET_TUNED} && oc create -f /tmp/kafka.yaml

for (( run=0 ; run<"${TOTAL_ITR}" ;run++))
do
  if [ -f /tmp/nhup ]
  then
    rm -f /tmp/nohup
  fi
  mkdir -p ${RESULTS_DIR_ROOT}/ITR-${run}
  head -c ${messageSize} /dev/urandom > /tmp/payload.data
  ssh -i ${KEY} ${SSH_OPTION} ${SSH_USER}@${client_ip} ' [[ -f /tmp/workload-Kafka.json ]] && sudo rm -rf /tmp/workload-Kafka.json'
  scp -i ${KEY} ${SSH_OPTION} /tmp/payload.data  ${SSH_USER}@${client_ip}:/tmp/payload.data
  for i in ${WORKLOAD[@]} ;do
    ssh -i ${KEY} ${SSH_OPTION} ${SSH_USER}@${client_ip} sed -i -e "s/$i:.*/$i:\ ${!i}/" /opt/benchmark/workloads/workload.yaml
  done
  ssh -i ${KEY} ${SSH_OPTION} ${SSH_USER}@${client_ip} "sudo sed -i 's/.*payloadFile:.*/payloadFile: \/tmp\/payload.data/' /opt/benchmark/workloads/workload.yaml"
  [[  `ssh -i ${KEY} ${SSH_OPTION} ${SSH_USER}@${client_ip} grep  warmupDurationMinutes /opt/benchmark/workloads/workload.yaml` ]] && ssh -i ${KEY} ${SSH_OPTION} ${SSH_USER}@${client_ip} "sudo sed -i 's/warmupDurationMinutes:.*/warmupDurationMinutes: 2/g' /opt/benchmark/workloads/workload.yaml"
  for i in producerConfig consumerConfig ;do
    declare -n p=${i}
    for j in ${!p[@]}; do
      [[ -z "${!j}" ]] && export $j=${kafka_default[$j]}
      echo "${!j}"
      if  [[ "default" == "${!j}" ]];then
        echo "default" 
        echo  ${p[$j]}
        [[  `ssh -i ${KEY} ${SSH_OPTION} ${SSH_USER}@${client_ip} grep  ${p[$j]} /opt/benchmark/driver-kafka/kafka.yaml` ]] && ssh -i ${KEY} ${SSH_OPTION} ${SSH_USER}@${client_ip} sed -i  -e "/${p[$j]}=.*/d" /opt/benchmark/driver-kafka/kafka.yaml
      else
        if [[ `ssh -i ${KEY} ${SSH_OPTION} ${SSH_USER}@${client_ip} grep  ${p[$j]} /opt/benchmark/driver-kafka/kafka.yaml` ]]; then
          echo "substituing"
          ssh -i ${KEY} ${SSH_OPTION} ${SSH_USER}@${client_ip} sed -i -e "s/${p[$j]}=.*/${p[$j]}=${!j}/" /opt/benchmark/driver-kafka/kafka.yaml
        else
          echo "appending"
          ssh -i ${KEY} ${SSH_OPTION} ${SSH_USER}@${client_ip} sed -i -e "/$i/a${p[$j]}=${!j}" /opt/benchmark/driver-kafka/kafka.yaml
          ssh -i ${KEY} ${SSH_OPTION} ${SSH_USER}@${client_ip} sed -i -e "s/${p[$j]}=${!j}/\ \ ${p[$j]}=${!j}/" /opt/benchmark/driver-kafka/kafka.yaml
        fi
      fi
    done
  #echo ${!{i}[@]}
  done
  timeout -k $runtime  $runtime nohup ssh -i ${KEY} ${SSH_OPTION} ${SSH_USER}@${client_ip} 'cd /opt/benchmark; sudo bin/benchmark -wf workers.yaml  --drivers driver-kafka/kafka.yaml  workloads/workload.yaml  -o /tmp/workload-Kafka.json' > /tmp/nohup  &
  wait $!
  grep "initialize-driver -- code: 500" /tmp/nohup
  if [ $? == 0 ]
  then
    rm -f /tmp/nohup
    sleep 60
    echo "Re-running benchmark"
    timeout -k $runtime $runtime  nohup ssh -i ${KEY} ${SSH_OPTION} ${SSH_USER}@${client_ip} 'cd /opt/benchmark; sudo bin/benchmark -wf workers.yaml  --drivers driver-kafka/kafka.yaml  workloads/workload.yaml  -o /tmp/workload-Kafka.json'  >/tmp/nohup  &
    wait $!
  fi
  grep "ERROR" /tmp/nohup
  if [ $? == 0 ]
  then
    ERROR=true
    ssh -i ${KEY} ${SSH_OPTION} ${SSH_USER}@${client_ip} "sudo pkill -9 java"
    break
  else
    ssh -i ${KEY} ${SSH_OPTION} ${SSH_USER}@${client_ip} ' [[ -f /tmp/workload-Kafka.json ]] ' || ERROR=true
    if ! $ERROR; then
      ssh -i ${KEY} ${SSH_OPTION} ${SSH_USER}@${client_ip} date --utc -Is >> ${RESULTS_DIR_ROOT}/endtime.log
      scp -i ${KEY} ${SSH_OPTION} ${SSH_USER}@${client_ip}:/tmp/workload-Kafka.json ${RESULTS_DIR_ROOT}/ITR-${run}
      cp ${RESULTS_DIR_ROOT}/ITR-${run}/workload-Kafka.json ${RESULTS_DIR_ROOT}/${run}-workload-Kafka.json
    fi
  fi
  tail /tmp/nohup
  #rm -f /tmp/nohup
  #cp /tmp/workload-Kafka.json ${RESULTS_DIR_ROOT}/ITR-${run}
  sleep 60
done
${SET_TUNED} && oc delete -f /tmp/kafka.yaml

if $ERROR
then
  csvout=''
  for i in ${LATENCY_LOGS[@]}
  do
    d=', '
    csvout=$csvout$d'999999999'
  done
  echo $csvout >> ${RESULTS_DIR_ROOT}/Metrics-wrk.log
else
  ${SCRIPT_REPO}/parsemetrics.sh ${RESULTS_DIR_ROOT} ${TOTAL_ITR} ${SCRIPT_REPO}
fi

#${SCRIPT_REPO}/parsemetrics.sh ${RESULTS_DIR_ROOT}
readarray -t arr_time < ${RESULTS_DIR_ROOT}/endtime.log
endtime=()
for i in $(seq 1 $((${#arr_time[*]})));do endtime+=("endtime_${i}_iter");done
write_to_csv endtime time.log false
write_to_csv arr_time time.log false

paste  ${RESULTS_DIR_ROOT}/Metrics-wrk.log ${RESULTS_DIR_ROOT}/deploy-config.log ${RESULTS_DIR_ROOT}/time.log > ${RESULTS_DIR_ROOT}/output.csv

cat ${RESULTS_DIR_ROOT}/output.csv




