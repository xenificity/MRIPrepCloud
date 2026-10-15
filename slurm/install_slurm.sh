#!/bin/bash
# Install munge + Slurm 24.11.7 (built from source) on every node of the cluster. Run once on the head node (vm0)
# after /mydata (NFS) is mounted everywhere. Ubuntu 20.04's packaged Slurm (19.05) has no GPU sharding (gres/shard
# needs Slurm >= 22.05), which this work depends on.
# Usage: slurm/install_slurm.sh [node ...]        (default: vm0 vm1 vm2 vm3; vm0 = head node)
set -e
NODES=${*:-vm0 vm1 vm2 vm3}
VER=24.11.7; B=/mydata/slurm-build; SRC=$B/slurm-$VER; ROOT=$B/slurm-root
HEAD=$(set -- $NODES; echo "$1")

# 1. munge on every node, one shared key (generated on the head node)
for v in $NODES; do ssh "$v" 'sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq munge libmunge2 libmunge-dev build-essential libpam0g-dev libhwloc-dev libnuma-dev libjson-c-dev libyaml-dev libreadline-dev >/dev/null'; done
ssh "$HEAD" 'sudo cp /etc/munge/munge.key /mydata/munge.key && sudo chmod 644 /mydata/munge.key'
for v in $NODES; do ssh "$v" 'sudo install -m 400 -o munge -g munge /mydata/munge.key /etc/munge/munge.key && sudo systemctl enable --now munge && sudo systemctl restart munge'; done
sudo rm -f /mydata/munge.key

# 2. build once, into the shared directory
mkdir -p "$B" && cd "$B"
[ -d "$SRC" ] || { curl -sLO "https://download.schedmd.com/slurm/slurm-$VER.tar.bz2"; tar xjf "slurm-$VER.tar.bz2"; }
cd "$SRC"
[ -f config.status ] || ./configure --prefix=/usr/local --sysconfdir=/etc/slurm --with-munge --enable-pam >configure.log
make -j"$(nproc)" >make.log && make install DESTDIR="$ROOT" >install.log

# 3. install the staged tree on every node; slurmctld only on the head node
for v in $NODES; do
  echo "== $v"
  ssh "$v" "sudo bash -s $([ "$v" = "$HEAD" ] && echo head)" <<'EOF'
set -e
systemctl stop slurmd slurmctld 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq slurm-wlm slurmd slurmctld slurm-client slurm-wlm-basic-plugins slurmdbd >/dev/null 2>&1 || true
getent passwd slurm >/dev/null || useradd -r -u 64030 -s /usr/sbin/nologin slurm   # same uid on all nodes
cp -a /mydata/slurm-build/slurm-root/. / && ldconfig
install -d -m 755 /etc/slurm /var/spool/slurmd /var/log/slurm
install -d -m 700 -o slurm -g slurm /var/spool/slurmctld
cp /mydata/slurm-build/slurm-24.11.7/etc/slurmd.service /etc/systemd/system/
[ "$1" = head ] && cp /mydata/slurm-build/slurm-24.11.7/etc/slurmctld.service /etc/systemd/system/
systemctl daemon-reload
[ "$1" = head ] && systemctl enable slurmctld || systemctl enable slurmd
/usr/local/sbin/slurmd -V
EOF
done
echo "Slurm $VER installed. Next: slurm/deploy_shards.sh 2 2   (writes slurm.conf/gres.conf and starts the daemons)"
