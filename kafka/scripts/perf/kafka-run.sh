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

client_ip=
TOTAL_ITR=$1
HPO_CONFIG=$2
KAFKA_CONFIG=$3

declare -A tunables 
for ((i=0; i<$(cat $HPO_CONFIG |jq '. | length'); i++ ))
 do
  echo $i
  echo `cat $HPO_CONFIG |jq -r .[$i].tunable_name`
  echo `cat $HPO_CONFIG |jq -r .[$i].tunable_value`
  tunables[`cat $HPO_CONFIG |jq -r .[$i].tunable_name`]=`cat $HPO_CONFIG |jq -r .[$i].tunable_value`
done
echo ${tunables[@]}

declare -A kafka
for i in $(cat $KAFKA_CONFIG |jq -r '.|keys[]')
 do
  echo $i
  echo `cat $KAFKA_CONFIG |jq  '.["'$i'"]'`
  #echo `cat $HPO_CONFIG |jq -r .[$i].tunable_value`
  kafka[$i]=`cat $KAFKA_CONFIG |jq  '.["'$i'"]'`
  #export $i=${kafka[$i]}
done
echo ${kafka[@]}
echo ${kafka["messageSize"]}

#DEPLOY_LOGS=(topics partitionsPerTopic messageSize subscriptionsPerTopic producersPerTopic consumerPerSubscription producerRate consumerBacklogSizeGB testDurationMinutes)
LATENCY_LOGS=(aggregatedPublishLatencyAvg aggregatedPublishLatency95pct aggregatedPublishLatency99pct aggregatedPublishLatency999pct aggregatedPublishLatency9999pct aggregatedEndToEndLatencyAvg  aggregatedEndToEndLatency95pct   aggregatedEndToEndLatency99pct aggregatedEndToEndLatency999pct aggregatedEndToEndLatency9999pct)
#echo ", topics ,  , IMAGE_NAME , CONTAINER_NAME" > ${RESULTS_DIR_ROOT}/deploy-config.log



function set_tuned() {
 for i in ${!tunables[@]}
  do
   export $i=${tunables[$i]}
   echo ${!i}
 done

 [[ -z "${dirty_bytes}" ]] && export dirty_bytes=1073741824
 [[ ! -z "${mem_max}" ]] && export tcp_def=`expr ${mem_max} / 8`
 envsubst < ${CURRENT_DIR}/../../templates/kafka.yaml > /tmp/kafka.yaml
}

declare -A kafka_default=(["topics"]=1 ["partitionsPerTopic"]=9 ["messageSize"]=1024 ["subscriptionsPerTopic"]=1 ["producersPerTopic"]=9 ["consumerPerSubscription"]=9 ["producerRate"]=10240 ["consumerBacklogSizeGB"]=0 ["testDurationMinutes"]=15 ["linger_ms"]=200 ["batch_size"]=200000 ["fetch_min_bytes"]=100000 ["throughput"]=5242880)

set_tuned

DEPLOY_LOGS=(${!kafka_default[@]})
for i in ${!kafka_default[@]}
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
  if $values
  then
    echo $csvout >> ${RESULTS_DIR_ROOT}/$csv_file
  else
    echo $csvout > ${RESULTS_DIR_ROOT}/$csv_file
  fi
}

write_to_csv LATENCY_LOGS Metrics-wrk.log false
write_to_csv DEPLOY_LOGS deploy-config.log false
write_to_csv DEPLOY_LOGS deploy-config.log true
ERROR=false
for (( run=0 ; run<"${TOTAL_ITR}" ;run++))
do
  if [ -f /tmp/nhup ]
  then
    rm -f /tmp/nohup
  fi
  mkdir -p ${RESULTS_DIR_ROOT}/ITR-${run}
  head -c ${messageSize} /dev/urandom > /tmp/payload.data
  oc create -f /tmp/kafka.yaml
  scp -i ~/.ssh/kafka_cloud /tmp/payload.data  ec2-user@${client_ip}:/tmp/payload.data
  ssh -i ~/.ssh/kafka_cloud ec2-user@${client_ip} "sudo sed -i 's/.*payloadFile:.*/payloadFile: \/tmp\/payload.data/' /opt/benchmark/workloads/workload.yaml"
  ssh -i ~/.ssh/kafka_cloud ec2-user@${client_ip} "sudo sed -i 's/producerRate:.*/producerRate: ${producerRate}/' /opt/benchmark/workloads/workload.yaml"
  ssh -i ~/.ssh/kafka_cloud ec2-user@${client_ip} "sudo sed -i 's/messageSize:.*/messageSize: ${messageSize}/' /opt/benchmark/workloads/workload.yaml"
  ssh -i ~/.ssh/kafka_cloud ec2-user@${client_ip} "sudo sed -i 's/producersPerTopic:.*/producersPerTopic: ${producersPerTopic}/' /opt/benchmark/workloads/workload.yaml"
  ssh -i ~/.ssh/kafka_cloud ec2-user@${client_ip} "sudo sed -i 's/consumerPerSubscription:.*/consumerPerSubscription: ${consumerPerSubscription}/' /opt/benchmark/workloads/workload.yaml"
  ssh -i ~/.ssh/kafka_cloud ec2-user@${client_ip} "sudo sed -i 's/partitionsPerTopic:.*/partitionsPerTopic: ${partitionsPerTopic}/' /opt/benchmark/workloads/workload.yaml"
  ssh -i ~/.ssh/kafka_cloud ec2-user@${client_ip} "sudo sed -i 's/testDurationMinutes:.*/testDurationMinutes: ${testDurationMinutes}/' /opt/benchmark/workloads/workload.yaml"
  ssh -i ~/.ssh/kafka_cloud ec2-user@${client_ip} "sudo sed -i 's/batch.size=.*/batch.size=${batch_size}/' /opt/benchmark/driver-kafka/kafka.yaml"
  ssh -i ~/.ssh/kafka_cloud ec2-user@${client_ip} "sudo sed -i 's/linger.ms=.*/linger.ms=${linger_ms}/' /opt/benchmark/driver-kafka/kafka.yaml"
  ssh -i ~/.ssh/kafka_cloud ec2-user@${client_ip} "sudo sed -i 's/fetch.min.bytes=.*/fetch.min.bytes=${fetch_min_bytes}/' /opt/benchmark/driver-kafka/kafka.yaml"
  timeout -k $runtime  $runtime nohup ssh -i /root/.ssh/kafka_cloud ec2-user@${client_ip} 'cd /opt/benchmark; sudo bin/benchmark -wf workers.yaml  --drivers driver-kafka/kafka.yaml  workloads/workload.yaml  -o /tmp/workload-Kafka.json' > /tmp/nohup  &
  wait $!
  grep "initialize-driver -- code: 500" /tmp/nohup
  if [ $? == 0 ]
  then
    rm -f /tmp/nohup
    sleep 60
    echo "Re-running benchmark"
    timeout -k $runtime $runtime  nohup ssh -i /root/.ssh/kafka_cloud ec2-user@${client_ip} 'cd /opt/benchmark; sudo bin/benchmark -wf workers.yaml  --drivers driver-kafka/kafka.yaml  workloads/workload.yaml  -o /tmp/workload-Kafka.json'  >/tmp/nohup  &
    wait $!
  fi
  grep "ERROR" /tmp/nohup
  if [ $? == 0 ]
  then
    ERROR=true
    ssh -i ~/.ssh/kafka_cloud ec2-user@${client_ip} "sudo pkill -9 java"
    break
  else
    scp -i ~/.ssh/kafka_cloud ec2-user@${client_ip}:/tmp/workload-Kafka.json ${RESULTS_DIR_ROOT}/ITR-${run}
  fi
  rm -f /tmp/nohup
  #cp /tmp/workload-Kafka.json ${RESULTS_DIR_ROOT}/ITR-${run}
  oc delete -f /tmp/kafka.yaml
  sleep 60
done

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

paste  ${RESULTS_DIR_ROOT}/Metrics-wrk.log ${RESULTS_DIR_ROOT}/deploy-config.log > ${RESULTS_DIR_ROOT}/output.csv

cat ${RESULTS_DIR_ROOT}/output.csv




