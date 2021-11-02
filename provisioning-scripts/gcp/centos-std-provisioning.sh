# Copyright (c) 2021 Teradici Corporation
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

#!/bin/bash

######################
# Required Variables #
######################
# REQUIRED: You must fill in this value before running the script
PCOIP_REGISTRATION_CODE=""

######################
# Optional Variables #
######################
# NOTE: Fill both USERNAME and TEMP_PASSWORD to create login credential, 
# otherwise please SSH into workstation to add user and set password.
# Please change password upon first login.
USERNAME=""
TEMP_PASSWORD=""
# You can use the default value set here or change it
AUTO_SHUTDOWN_IDLE_TIMER=240
CPU_POLLING_INTERVAL=15
ENABLE_AUTO_SHUTDOWN="true"
TERADICI_DOWNLOAD_TOKEN="yj39yHtgj68Uv2Qf"


LOG_FILE="/var/log/teradici/provisioning.log"

TERADICI_REPO_SETUP_SCRIPT_URL="https://dl.teradici.com/$TERADICI_DOWNLOAD_TOKEN/pcoip-agent/cfg/setup/bash.rpm.sh"

log() {
    local message="$1"
    echo "[$(date)] $message"
}

retry() {
    local retries=0
    local max_retries=3
    until [[ $retries -ge $max_retries ]]
    do  
    # Break if command succeeds, or log then retry if command fails.
        $@ && break || {

            log "--> Failed to run command. $@"
            log "--> Retries left... $(( $max_retries - $retries ))"
            ((retries++))
            sleep 10;
        }
    done

    if [[ $retries -eq $max_retries ]]
    then
        return 1
    fi
}

check_required_vars() {
    set +x
    if [[ -z "$PCOIP_REGISTRATION_CODE" ]]; then
        log "--> ERROR: Missing PCoIP Registration Code."
        missing_vars="true"
    fi

    set -x

    if [[ "$missing_vars" = "true" ]]; then
        log "--> Exiting..."
        exit 1
    fi
}

exit_and_restart() {
    log "--> Rebooting..."
    (sleep 1; reboot -p) &
    exit
}

install_pcoip_agent() {
    log "--> Getting Teradici PCoIP agent repo..."
    curl --retry 3 --retry-delay 5 -u "token:$TERADICI_DOWNLOAD_TOKEN" -1sLf $TERADICI_REPO_SETUP_SCRIPT_URL | bash
    if [ $? -ne 0 ]; then
        log "--> ERROR: Failed to install PCoIP agent repo."
        exit 1
    fi
    log "--> PCoIP agent repo installed successfully."

    log "--> Installing USB dependencies..."
    retry "yum install -y usb-vhci"
    if [ $? -ne 0 ]; then
        log "--> Warning: Failed to install usb-vhci."
    fi
    log "--> usb-vhci successfully installed."

    log "--> Installing PCoIP standard agent..."
    retry yum -y install pcoip-agent-standard
    if [ $? -ne 0 ]; then
        log "--> ERROR: Failed to install PCoIP agent."
        exit 1
    fi
    log "--> PCoIP agent installed successfully."

    log "--> Registering PCoIP agent license..."
    n=0
    set +x
    while true; do
        /usr/sbin/pcoip-register-host --registration-code="$PCOIP_REGISTRATION_CODE" && break
        n=$[$n+1]

        if [ $n -ge 10 ]; then
            log "--> ERROR: Failed to register PCoIP agent after $n tries."
            exit 1
        fi

        log "--> ERROR: Failed to register PCoIP agent. Retrying in 10s..."
        sleep 10
    done
    set -x
    log "--> PCoIP agent registered successfully."
}

install_idle_shutdown() {
    log "--> Installing idle shutdown..."
    mkdir /tmp/idleShutdown

    retry wget "https://raw.githubusercontent.com/teradici/deploy/master/remote-workstations/new-agent-vm/Install-Idle-Shutdown.sh" -O /tmp/idleShutdown/Install-Idle-Shutdown-raw.sh

    awk '{ sub("\r$", ""); print }' /tmp/idleShutdown/Install-Idle-Shutdown-raw.sh > /tmp/idleShutdown/Install-Idle-Shutdown.sh && chmod +x /tmp/idleShutdown/Install-Idle-Shutdown.sh

    log "--> Setting auto shutdown idle timer to $AUTO_SHUTDOWN_IDLE_TIMER minutes..."
    INSTALL_OPTS="--idle-timer $AUTO_SHUTDOWN_IDLE_TIMER"
    if [[ "$ENABLE_AUTO_SHUTDOWN" = "false" ]]; then
        INSTALL_OPTS="$INSTALL_OPTS --disabled"
    fi

    retry /tmp/idleShutdown/Install-Idle-Shutdown.sh $INSTALL_OPTS

    exitCode=$?
    if [[ $exitCode -ne 0 ]]; then
        log "--> ERROR: Failed to install idle shutdown."
        exit 1
    fi

    if [[ $CPU_POLLING_INTERVAL -ne 15 ]]; then
        log "--> Setting CPU polling interval to $CPU_POLLING_INTERVAL minutes..."
        sed -i "s/OnUnitActiveSec=15min/OnUnitActiveSec=$${CPU_POLLING_INTERVAL}min/g" /etc/systemd/system/CAMIdleShutdown.timer.d/CAMIdleShutdown.conf
        systemctl daemon-reload
    fi
}

if (rpm -q pcoip-agent-standard); then
    exit
fi

if [[ ! -f "$LOG_FILE" ]]
then
    mkdir -p "$(dirname $LOG_FILE)"
    touch "$LOG_FILE"
    chmod +644 "$LOG_FILE"
fi

log "$(date)"

# Print all executed commands to the terminal
set -x

# Redirect stdout and stderr to the log file
exec &>>$LOG_FILE

# Add a user and give the user a password so a user can start 
# a PCoIP session without having to first create password via SSH
# if USERNAME and TEMP_PASSWORD were provided
set +x
if [[ "$TEMP_PASSWORD" && "$USERNAME" ]]
then
    useradd $USERNAME
    echo $USERNAME:$TEMP_PASSWORD | chpasswd
    log "--> User and TEMP_PASSWORD has been set."
else
    log "--> USERNAME or TEMP_PASSWORD not provided. Skip creating user..."
fi
set -x

check_required_vars

yum -y update

yum install -y wget

# Install GNOME and set it as the desktop
log "--> Installing Linux GUI..."
yum -y groupinstall "GNOME Desktop" "Graphical Administration Tools"
# yum -y groupinstall "Server with GUI"

log "--> Setting default to graphical target..."
systemctl set-default graphical.target

if (rpm -q pcoip-agent-standard)
then
    log "--> pcoip-agent-standard is already installed."
else
    install_pcoip_agent
fi

install_idle_shutdown

log "--> Installation is complete!"

exit_and_restart
