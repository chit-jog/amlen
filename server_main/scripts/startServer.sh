#!/bin/bash
# Copyright (c) 2015-2021 Contributors to the Eclipse Foundation
# 
# See the NOTICE file(s) distributed with this work for additional
# information regarding copyright ownership.
# 
# This program and the accompanying materials are made available under the
# terms of the Eclipse Public License 2.0 which is available at
# http://www.eclipse.org/legal/epl-2.0
# 
# SPDX-License-Identifier: EPL-2.0
#

# Do not update this file --------------------------------------

_term() {
    trap - SIGTERM
    echo "SIGTERM in startServer"
    
    kill -TERM "$server" 2>/dev/null
    wait "$server" 2>/dev/null
    if [ $LOOP -eq 2 ]
    then
        LOOP=0
    fi
    ((LOOP++))
}

SVR_INSTALL_DIR=${IMA_SVR_INSTALL_PATH}
SVR_DATA_DIR=${IMA_SVR_DATA_PATH}

mkdir -p -m 770 ${SVR_DATA_DIR}/diag/logs
INITLOG=${SVR_DATA_DIR}/diag/logs/imaserver_start.log
export INITLOG

exec 200> /tmp/imaserver.lock
flock -e -n 200 2> /dev/null
if [ "$?" != "0" ]; then
    echo "imaserver process is already running." >&2
    exit 255
fi

echo "" >> ${INITLOG}
echo "-------------------------------------------------------------------"  >> ${INITLOG}
echo "START imaserver" >> ${INITLOG}
echo "Date: $(date) " >> ${INITLOG}
echo "User: `whoami` " >> ${INITLOG}

# Predefined configuration file location in the container
IMASERVERCFG=${SVR_DATA_DIR}/data/config/server.cfg

# Set PATH
PATH=${SVR_INSTALL_DIR}/bin:$PATH
export PATH

# Work out what we'll use as a temporary dir
# Useful advice: http://0pointer.net/blog/projects/tmp.html
# (NB: sockets can't be put on e.g. CephFS so we avoid using a dir under our data dir)
if [ -z "${IMASERVER_RUNTIME_DIR}" ]
then
    if [ -z "${XDG_RUNTIME_DIR}" ]
    then
        export IMASERVER_RUNTIME_DIR=/tmp/imaserver
    else
        export IMASERVER_RUNTIME_DIR=${XDG_RUNTIME_DIR}/imaserver
    fi
fi
mkdir -p -m 700  ${IMASERVER_RUNTIME_DIR}

# Initialize imaserver if systemd hasn't already done it
if [ "$SYSTEMD_STARTED_IMASERVER" != "1" ]
then
    ${SVR_INSTALL_DIR}/bin/initServer.sh
fi

if [ -f "/etc/os-release" ]; then
    . /etc/os-release
    OS="$ID"

    if [ "$OS" = "sles" ]; then
        # find perl library and set LD_LIBRARY_PATH
        # there could be a 64-bit and 32-bit perl installed ...
        perllibdir=$(dirname "$(find /usr/lib -name libperl.so | grep x86_64)")
        if [ -d "$perllibdir" ]; then
            export LD_LIBRARY_PATH=${perllibdir}:$LD_LIBRARY_PATH
        else
            echo "Could not find perl library."
        fi
    fi
fi

if [ "${CONTAINER_PASSWORD_CHECK}" = "true" ]; then
    echo "Doing password check" >> ${INITLOG}
    SECRET=`cat /secrets/admin/adminPassword`
    OLD=`cat ${SVR_DATA_DIR}/data/config/server_dynamic.json | grep -oP '(?<=\"AdminUserPassword\": \")[^\"]*'`
    ${SVR_INSTALL_DIR}/bin/imahasher -s -p $SECRET -e $OLD
    MATCH=$?
    if [ $MATCH == 0 ]; then
        echo "  Password check complete" >> ${INITLOG}
    elif [ $MATCH == 1 ]; then
        echo "  Password mismatch" >> ${INITLOG}
        NEWENCODING=`/usr/share/amlen-server/bin/imahasher -s -c $SECRET `
        CONFIRM=`cat ${SVR_DATA_DIR}/data/config/server_dynamic.json | grep -oP '(?<=\"AdminUserPassword\": \")[^\"]*'`
        if [ $CONFIRM != $NEWENCODING ]; then
            echo "  Updating password failed" >> ${INITLOG}
        else
            echo "  Password update successful" >> ${INITLOG}
        fi
    else
        echo "  Something went wrong running imahasher" >> ${INITLOG}
    fi
fi

# Start imaserver
echo "Start imaserver" >> ${INITLOG}

LOOP=1

while [ $LOOP -gt 0 ];
do
    # Start service
    ${SVR_INSTALL_DIR}/bin/imaserver -d ${IMASERVERCFG} &>> ${INITLOG} &
    server=$!
    trap _term SIGTERM
    wait "$server"
    if [ $LOOP -eq 0 ]
    then
        # Extract stack trace if previous run failed for any reason
        ${SVR_INSTALL_DIR}/bin/extractstackfromcore.sh
        echo "startServer terminated" $?
        exit 15
    fi

    if [ -f /tmp/.restart_inited ]
    then
        # Restart case
        rm -f /tmp/.restart_inited
        rm -f /tmp/imaserver.stop
        LOOP=1
        sleep 5
        # Extract stack trace if previous run failed for any reason
        ${SVR_INSTALL_DIR}/bin/extractstackfromcore.sh
    else
        # check if need to keep container running for debugging
        if [ -f /var/tmp/MessageSight.debug ]
        then
            # Extract stack trace if previous run failed for any reason
            ${SVR_INSTALL_DIR}/bin/extractstackfromcore.sh
            LOOP=1
            read -p "$*"
        else
            LOOP=0
        fi
    fi
done

# Extract stack trace if previous run failed for any reason
${SVR_INSTALL_DIR}/bin/extractstackfromcore.sh

