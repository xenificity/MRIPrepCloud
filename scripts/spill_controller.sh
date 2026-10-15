#!/bin/bash
# MRIPrepCloud per-node elastic spill cap. Runs while deepprep.sh is alive. For each GPU node n in {Node2, Node3}:
#   cap_n = 16 - cores held by running GPU jobs on n - reserve_n
#   reserve_n = RESERVE (cores for the next GPU task) if GPU tasks are pending AND node n has a free shard/GPU, else 0
# so CPU tasks (partitions cpu-spill2/cpu-spill3) use every core the GPU tasks are not using, while a GPU task
# that could start on a free shard always finds cores. Shards: Node2 = 2 (1 GPU), Node3 = 4 (2 GPUs); an exclusive
# --gres=gpu:1 job consumes one GPU = 2 shards.
RESERVE=${RESERVE:-4}; MIN=${MIN:-2}; LOG=${LOG:-$HOME/spill_controller.log}; DEEP_PREP_HOME=${DEEP_PREP_HOME:-/mydata/DeepPrep}
declare -A SHARDS=([Node2]=2 [Node3]=4) PART=([Node2]=cpu-spill2 [Node3]=cpu-spill3) cur
echo "$(date +%F_%T) start per-node controller RESERVE=$RESERVE" >> "$LOG"
while pgrep -f "^/bin/bash $DEEP_PREP_HOME/deepprep/deepprep.sh" >/dev/null; do
  pend=$(squeue -h -p gpu-node -t PD 2>/dev/null | wc -l)
  running=$(squeue -h -p gpu-node -t R -o "%N %C %b" 2>/dev/null)
  for n in Node2 Node3; do
    cores=$(echo "$running" | awk -v n=$n '$1==n{c+=$2} END{print c+0}')
    used=$(echo "$running" | awk -v n=$n '$1==n{ if ($3 ~ /gres\/gpu/) s+=2; else s+=1 } END{print s+0}')
    free=$(( ${SHARDS[$n]} - used ))
    res=0; [ "$pend" -gt 0 ] && [ "$free" -gt 0 ] && res=$RESERVE
    want=$(( 16 - cores - res )); [ "$want" -lt "$MIN" ] && want=$MIN; [ "$want" -gt 16 ] && want=16
    cur[$n]=$(scontrol show partition ${PART[$n]} 2>/dev/null | grep -oE "MaxCPUsPerNode=[0-9]+" | cut -d= -f2)
    if [ "$want" != "${cur[$n]}" ]; then
      sudo scontrol update PartitionName=${PART[$n]} MaxCPUsPerNode=$want && cur[$n]=$want
      echo "$(date +%F_%T) $n gpu_pending=$pend gpu_cores=$cores free_shards=$free cap=$want" >> "$LOG"
    fi
  done
  sleep 5
done
sudo scontrol update PartitionName=cpu-spill2 MaxCPUsPerNode=12; sudo scontrol update PartitionName=cpu-spill3 MaxCPUsPerNode=12
echo "$(date +%F_%T) end (caps restored to 12)" >> "$LOG"
