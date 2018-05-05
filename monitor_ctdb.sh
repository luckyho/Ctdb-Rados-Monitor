#! /bin/bash

function check_if_master() {
    MASTER_PNN=$(ctdb recmaster)
    CURRENT_PNN=$(ctdb pnn)
    if [ $MASTER_PNN -eq $CURRENT_PNN ]; then
        echo true
    else
        echo false
    fi
}

function get_lock_name() {
    LOCK_INFO=$(grep rados $CTDB_CONFIG_FILE | awk '{print $5}')
    LOCK_NAME=${LOCK_INFO:0:-1}
    echo $LOCK_NAME
}

function monitor_lock() {
    STATUS_FILE=/etc/ctdb/status.txt
    CTDB_STATUS=$(ctdb status 2>&1)
    ALL_BANNED="Warning: All nodes are banned."

    if [ ! -f "$STATUS_FILE" ]; then
        echo "$CTDB_STATUS" > $STATUS_FILE
    else
        if [ "$CTDB_STATUS" = "$ALL_BANNED" ]; then
            LAST_CTDB_STATUS=$(cat $STATUS_FILE)
            if [ "$LAST_CTDB_STATUS" = "$ALL_BANNED" ]; then
                LOCKNAME=$(get_lock_name)
                echo $(date)" Ctdb all nodes banned: Second time" >> /var/log/monitor_ctdb.log
                echo $(date)" Remove ctdb rados lock: "$LOCKNAME >> /var/log/monitor_ctdb.log
                rados -p rbd rm $LOCKNAME 
                echo -n "" > $STATUS_FILE
            else
                echo $(date)" Ctdb all nodes banned: First time" >> /var/log/monitor_ctdb.log
                echo "$ALL_BANNED" > $STATUS_FILE
            fi
        else
            echo -n "" > $STATUS_FILE
        fi
    fi
}

CTDB_CONFIG_FILE=/etc/sysconfig/ctdb
if $(grep rados $CTDB_CONFIG_FILE -q); then
    if $(check_if_master); then
        monitor_lock
    fi
fi
