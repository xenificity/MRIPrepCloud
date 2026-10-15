#!/bin/bash
# Deploy slurm.conf + gres.conf with the given shard counts to all nodes and (re)start Slurm 24.11.
# Usage: deploy_shards.sh <shards per T4> <shards per RTX 6000>
set -e
T4=${1:-2}; RTX=${2:-2}
D=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
sed -e "s/SHARDS_NODE2/$T4/" -e "s/SHARDS_NODE3/$((2*RTX))/" "$D/slurm.conf" > "$TMP/slurm.conf"
sed -e "s/SHARDS_T4/$T4/" "$D/gres.conf.node2" > "$TMP/gres.node2"
sed -e "s/SHARDS_RTX/$RTX/" "$D/gres.conf.node3" > "$TMP/gres.node3"
for v in vm0 vm1 vm2 vm3; do
  scp -q "$TMP/slurm.conf" $v:/tmp/slurm.conf.new
  ssh $v 'sudo install -m 644 /tmp/slurm.conf.new /etc/slurm/slurm.conf'
done
scp -q "$TMP/gres.node2" vm1:/tmp/gres.conf.new; ssh vm1 'sudo install -m 644 /tmp/gres.conf.new /etc/slurm/gres.conf'
scp -q "$TMP/gres.node3" vm2:/tmp/gres.conf.new; ssh vm2 'sudo install -m 644 /tmp/gres.conf.new /etc/slurm/gres.conf'
ssh vm0 'sudo systemctl restart slurmctld'
sleep 2
for v in vm1 vm2 vm3; do ssh $v 'sudo systemctl restart slurmd'; done
sleep 3
sinfo -N -o "%N %T %c %G %P"
rm -rf "$TMP"
