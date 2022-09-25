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
topics=1
testDurationMinutes=2
subscriptionsPerTopic=1
consumerBacklogSizeGB=0
TOTAL_ITR=$1
messageSize=$2
echo $messageSize
producersPerTopic=$3
consumerPerSubscription=$4
partitionsPerTopic=$5
linger_ms=$6
batch_size=$7
fetch_min_bytes=$8

producerRate=`expr 5242880 / ${messageSize}`
echo $producerRate

runtime=$(($testDurationMinutes*60+180))


DEPLOY_LOGS=(topics partitionsPerTopic messageSize subscriptionsPerTopic producersPerTopic consumerPerSubscription producerRate consumerBacklogSizeGB testDurationMinutes)
LATENCY_LOGS=(aggregatedPublishLatencyAvg aggregatedPublishLatency99pct aggregatedPublishLatency999pct aggregatedPublishLatency9999pct aggregatedEndToEndLatencyAvg aggregatedEndToEndLatency99pct aggregatedEndToEndLatency999pct aggregatedEndToEndLatency9999pct)
echo ", topics ,  , IMAGE_NAME , CONTAINER_NAME" > ${RESULTS_DIR_ROOT}/deploy-config.log

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
  timeout -k $runtime  $runtime nohup ssh -i /root/.ssh/kafka_cloud ec2-user@${client_ip} 'cd /opt/benchmark; sudo bin/benchmark -wf workers.yaml  --drivers driver-kafka/kafka.yaml  workloads/workload.yaml  -o /tmp/workload-Kafka.json' > /tmp/nohup 2>&1 &
  wait $!
  grep "initialize-driver -- code: 500" /tmp/nohup
  if [ $? == 0 ]
  then
    rm -f /tmp/nohup
    sleep 60
    echo "Re-running benchmark"
    timeout -k $runtime $runtime  nohup ssh -i /root/.ssh/kafka_cloud ec2-user@${client_ip} 'cd /opt/benchmark; sudo bin/benchmark -wf workers.yaml  --drivers driver-kafka/kafka.yaml  workloads/workload.yaml  -o /tmp/workload-Kafka.json'  >/tmp/nohup 2>&1 &
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
  sleep 120
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




