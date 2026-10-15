#!/bin/bash
# MRIPrepCloud: run DeepPrep on the Slurm cluster with GPU sharding, critical-path priorities and the elastic spill cap.
# Usage:  scripts/run_deepprep.sh <bids_dir> <output_dir> [bold_task_type]      (default task type: rest)
# Detach it from your terminal so it survives a dropped SSH session:
#   setsid nohup scripts/run_deepprep.sh /mydata/data/chess_data/bids /mydata/output/chess_data/run1 > run1.log 2>&1 < /dev/null &
set -u
BIDS_DIR=${1:?bids_dir}; OUTPUT_DIR=${2:?output_dir}; TASK=${3:-rest}
DEEP_PREP_HOME=${DEEP_PREP_HOME:-/mydata/DeepPrep}
SINGULARITY_IMG=${SINGULARITY_IMG:-/mydata/deepprep_25.1.0.sif}
FS_LICENSE=${FS_LICENSE:-/mydata/freesurfer_key/license.txt}
HERE=$(cd "$(dirname "$0")/.." && pwd)
CONFIG=${CONFIG:-$HERE/config/deepprep.slurm.config}
export TF_FORCE_GPU_ALLOW_GROWTH=true   # passed into the container (singularity.envWhitelist): two tasks can share one GPU
RUN=$OUTPUT_DIR/mriprepcloud; mkdir -p "$RUN"
log() { echo "$(date +%F_%T) $*" | tee -a "$RUN/status.log"; }

log "START bids=$BIDS_DIR out=$OUTPUT_DIR config=$CONFIG"
# DeepPrep's launcher; --device '$CUDA_VISIBLE_DEVICES' is expanded inside each Slurm job to the GPU Slurm assigned to it
( cd /mydata && "$DEEP_PREP_HOME/deepprep/deepprep.sh" "$BIDS_DIR" "$OUTPUT_DIR" participant \
    --bold_task_type "$TASK" --device '$CUDA_VISIBLE_DEVICES' --fs_license_file "$FS_LICENSE" --debug --executor cluster \
    --container "$SINGULARITY_IMG" --config_file "$CONFIG" --deepprep_home "$DEEP_PREP_HOME" ) > "$RUN/launch.log" 2>&1 &
PIPE=$!
sleep 20
DEEP_PREP_HOME=$DEEP_PREP_HOME LOG=$RUN/spill_controller.log "$HERE/scripts/spill_controller.sh" > /dev/null 2>&1 &
CTL=$!
# light-weight cluster monitor: queue + GPU state every 15 s
( while kill -0 $PIPE 2>/dev/null; do
    { echo "### $(date +%T)"; squeue -h -o "%.6i %.10P %.45j %.2t %.6M %.3C %N %b"
      for v in vm1 vm2 vm3; do
        ssh -o ConnectTimeout=5 "$v" "echo -n \"$v load=\$(cut -d' ' -f1 /proc/loadavg) \"; nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader,nounits 2>/dev/null | tr '\n' ';'; echo"
      done; } >> "$RUN/monitor.log" 2>&1
    sleep 15
  done ) &
wait $PIPE; rc=$?
wait $CTL 2>/dev/null
summary=$(grep -oE "succeededCount=[0-9]+; failedCount=[0-9]+" "$OUTPUT_DIR/WorkDir/nextflow/.nextflow.log" 2>/dev/null | tail -1)
log "END rc=$rc $summary"
python3 "$HERE/scripts/summarize_run.py" "$OUTPUT_DIR" 2>&1 | tee -a "$RUN/status.log"
