#! /bin/bash

function check_if_master() {
    master_pnn=$(ctdb recmaster)
    current_pnn=$(ctdb pnn)
    if [ $master_pnn -eq $current_pnn ]; then
        echo true
    else
        echo false
    fi
}

function get_lock_name() {
    lock_info=$(grep rados $CTDB_CONFIG_FILE | awk '{print $5}')
    lockname=${lock_info:0:-1}
    echo $lockname
}

function get_all_banned_count() {
    all_banned_info=$(sed -n 1p $STATUS_FILE)
    all_banned_count=${all_banned_info#*:}
    echo $all_banned_count
}

function get_lock_del_interval() {
    last_time=$(get_lock_del_last_time)
    current_time=$(date +%s)
    interval=$(expr $current_time - $last_time)
    echo $interval
}

function get_ctdb_restart_interval() {
    last_time=$(get_ctdb_restart_last_time)
    if [ -z "$last_time" ]; then
        interval=$(expr $RESTART_CTDB_INTERVAL_MAX + 1)
    else
        current_time=$(date +%s)
        interval=$(expr $current_time - $last_time)
    fi
    echo $interval
}

function get_lock_del_last_time() {
    last_time_info=$(sed -n 2p $STATUS_FILE)
    last_time=${last_time_info#*:}
    echo $last_time
}

function get_ctdb_restart_last_time() {
    last_time_info=$(sed -n 3p $STATUS_FILE)
    last_time=${last_time_info#*:}
    echo $last_time
}

function update_count() {
    update_type=$1
    if [ $update_type = "new" ];then
        count=$(get_all_banned_count)
        new_count=$(expr $count + 1) 
    elif [ $update_type = "reset" ];then
        new_count=0
    fi
    count_info="all banned count:"$new_count
    sed -i 1s/.*/"$count_info"/ $STATUS_FILE
    echo $(date)" Ctdb all banned count: "$new_count >> $MONITOR_LOG
}

function update_last_del_time() {
    update_type=$1
    current_time=$(date +%s)
    if [ $update_type = "new" ];then
        time_info="lock last delete time:"$current_time
    	echo $(date)" Lock last delete time update: "$current_time >> $MONITOR_LOG
    elif [ $update_type = "reset" ];then
        time_info="lock last delete time:"
    	echo $(date)" Lock last delete time reset" >> $MONITOR_LOG
    fi
    sed -i 2s/.*/"$time_info"/ $STATUS_FILE
}

function update_last_ctdb_restart_time() {
    current_time=$(date +%s)
    time_info="ctdb last restart time:"$current_time
    echo $(date)" Ctdb last restart time update: "$current_time >> $MONITOR_LOG
    sed -i 3s/.*/"$time_info"/ $STATUS_FILE
}

function delete_lock_object() {
    lockname=$(get_lock_name)
    echo $(date)" Delete lock object: "$lockname >> $MONITOR_LOG
    rados -p rbd rm $lockname 
    update_count reset
    update_last_del_time new
    save_nodes_ip
}

function generate_status_file() {
    echo "all banned count:0" > $STATUS_FILE
    echo "lock last delete time:" >> $STATUS_FILE
    echo "ctdb last restart time:" >> $STATUS_FILE
}

function save_nodes_ip() {
    nodes=$(ctdb listnodes)
    for node in $nodes; do
        echo "$node" > $node
        rados -p rbd put $node $node
        echo $(date)" Save ip in rados: "$node >> $MONITOR_LOG
        rm -f $node
    done
}

function check_status_file() {
    if [ ! -f "$STATUS_FILE" ]; then
        generate_status_file
    fi
    line1=$(sed -n 1p $STATUS_FILE)
    line2=$(sed -n 2p $STATUS_FILE)
    line3=$(sed -n 3p $STATUS_FILE)
    if [ -z "$line1" -o -z "$line2" -o -z "$line3" ]; then
        generate_status_file
    fi
}

function monitor_master() {
    check_status_file
    ctdb_status=$(ctdb status 2>&1)

    if [ "$ctdb_status" = "$ALL_BANNED" ]; then
        update_count new
        count=$(get_all_banned_count)
        if [ $count -ge $COUNT_MAX ]; then
            if [ -z $(get_lock_del_last_time) ]; then
                delete_lock_object
            else
                if [ $(get_lock_del_interval) -ge $DEL_LOCK_INTERVAL_MAX ]; then
                    delete_lock_object
                fi
            fi
        fi
    else
        if [ $(get_all_banned_count) -ne 0 ]; then
            update_count reset
        fi
    fi
}

function monitor_nodes_ip_in_rados() {
    ips=$(get_current_node_ips)
    for ipinfo in $ips; do
        ip=${ipinfo%/*}
        if $(timeout 10 rados -p rbd ls | grep "$ip" -qw); then
            if [ $(get_ctdb_restart_interval) -ge $RESTART_CTDB_INTERVAL_MAX ]; then 
                systemctl restart ctdb
                echo $(date)" Ctdb restart by delete ip in rados" >> $MONITOR_LOG
                rados -p rbd rm $ip
                echo $(date)" Delete ip in rados: "$ip >> $MONITOR_LOG
                update_last_ctdb_restart_time
            fi
        fi
    done
}

function get_current_node_ips() {
    ips=$(/usr/sbin/ip addr | grep "inet " | awk '{print $2}')
    echo $ips
}

function monitor_get_lock_timeout() {
    count=$(ps -ef | grep rados_helper | wc -l)
    if [ $count -ge $RADOS_HELPER_PROCESS_MAX ]; then
        echo $(date)" Rados_helper process redundant, count is "$count >> $MONITOR_LOG
        if [ $(get_ctdb_restart_interval) -ge $RESTART_CTDB_INTERVAL_MAX ]; then 
            systemctl restart ctdb
            echo $(date)" Ctdb restart by redundant rados_helper process" >> $MONITOR_LOG
            update_last_ctdb_restart_time
        fi
    fi
}

CTDB_CONFIG_FILE=/etc/sysconfig/ctdb
STATUS_FILE=/etc/ctdb/status.log
MONITOR_LOG=/var/log/monitor_ctdb.log
ALL_BANNED="Warning: All nodes are banned."
COUNT_MAX=5
DEL_LOCK_INTERVAL_MAX=300
RADOS_HELPER_PROCESS_MAX=6
RESTART_CTDB_INTERVAL_MAX=120

if $(grep rados $CTDB_CONFIG_FILE -q); then
    if $(check_if_master); then
	monitor_master
    fi
    monitor_nodes_ip_in_rados
    monitor_get_lock_timeout
fi
