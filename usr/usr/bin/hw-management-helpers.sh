#!/bin/bash
########################################################################
# Copyright (c) 2021, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
# 3. Neither the names of the copyright holders nor the names of its
#    contributors may be used to endorse or promote products derived from
#    this software without specific prior written permission.
#
# Alternatively, this software may be distributed under the terms of the
# GNU General Public License ("GPL") version 2 as published by the Free
# Software Foundation.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
#

hw_management_path=/var/run/hw-management
environment_path=$hw_management_path/environment
alarm_path=$hw_management_path/alarm
eeprom_path=$hw_management_path/eeprom
led_path=$hw_management_path/led
system_path=$hw_management_path/system
sfp_path=$hw_management_path/sfp
watchdog_path=$hw_management_path/watchdog
config_path=$hw_management_path/config
events_path=$hw_management_path/events
thermal_path=$hw_management_path/thermal
jtag_path=$hw_management_path/jtag
power_path=$hw_management_path/power
fw_path=$hw_management_path/firmware
udev_ready=$hw_management_path/.udev_ready
LOCKFILE="/var/run/hw-management-chassis.lock"
board_type_file=/sys/devices/virtual/dmi/id/board_name
sku_file=/sys/devices/virtual/dmi/id/product_sku
system_ver_file=/sys/devices/virtual/dmi/id/product_version
devtree_file=$config_path/devtree
i2c_bus_def_off_eeprom_cpu_file=$config_path/i2c_bus_def_off_eeprom_cpu
i2c_comex_mon_bus_default_file=$config_path/i2c_comex_mon_bus_default
l1_switch_health_events=("intrusion" "pwm_pg" "thermal1_pdb" "thermal2_pdb")
ui_tree_sku=`cat $sku_file`
ui_tree_archive="/etc/hw-management-sensors/ui_tree_$ui_tree_sku.tar.gz"

# Thermal type constants
thermal_type_t1=1
thermal_type_t2=2
thermal_type_t3=3
thermal_type_t4=4
thermal_type_t4=4
thermal_type_t5=5
thermal_type_t6=6
thermal_type_t7=7
thermal_type_t8=8
thermal_type_t9=9
thermal_type_t10=10
thermal_type_t11=11
thermal_type_t12=12
thermal_type_t13=13
thermal_type_t14=14
thermal_type_def=0
thermal_type_full=100

base_cpu_bus_offset=10
max_tachos=14
i2c_asic_bus_default=2
i2c_asic2_bus_default=3
i2c_bus_max=26
lc_i2c_bus_min=34
lc_i2c_bus_max=43
i2c_bus_offset=0
cpu_type=

# CPU Family + CPU Model should idintify exact CPU architecture
# IVB - Ivy-Bridge
# RNG - Atom Rangeley
# BDW - Broadwell-DE
# CFL - Coffee Lake
# DNV - Denverton
# BF3 - BlueField-3
IVB_CPU=0x63A
RNG_CPU=0x64D
BDW_CPU=0x656
CFL_CPU=0x69E
DNV_CPU=0x65F
BF3_CPU=0xD42

log_err()
{
    logger -t hw-management -p daemon.err "$@"
}

log_info()
{
    logger -t hw-management -p daemon.info "$@"
}

check_cpu_type()
{
	if [ ! -f $config_path/cpu_type ]; then
		# ARM CPU provide "CPU part" field, x86 does not. Check for ARM first.
		cpu_pn=$(grep -m1 "CPU part" /proc/cpuinfo | awk '{print $4}')
		cpu_pn=`echo $cpu_pn | cut -c 3- | tr a-z A-Z`
		cpu_pn=0x$cpu_pn
		if [ "$cpu_pn" == "$BF3_CPU" ]; then
			cpu_type=$cpu_pn
			echo $cpu_type > $config_path/cpu_type
			return 0
		fi

		family_num=$(grep -m1 "cpu family" /proc/cpuinfo | awk '{print $4}')
		model_num=$(grep -m1 model /proc/cpuinfo | awk '{print $3}')
		cpu_type=$(printf "0x%X%X" "$family_num" "$model_num")
		echo $cpu_type > $config_path/cpu_type
	else
		cpu_type=$(cat $config_path/cpu_type)
	fi
}

find_i2c_bus()
{
    # Find physical bus number of Mellanox I2C controller. The default
    # number is 1, but it could be assigned to others id numbers on
    # systems with different CPU types.
    if [ -f $config_path/i2c_bus_offset ]; then
        i2c_bus_offset=$(< $config_path/i2c_bus_offset)
        return
    fi
    for ((i=1; i<i2c_bus_max; i++)); do
        folder=/sys/bus/i2c/devices/i2c-$i
        if [ -d $folder ]; then
            name=$(cut $folder/name -d' ' -f 1)
            if [ "$name" == "i2c-mlxcpld" ]; then
                i2c_bus_offset=$((i-1))
		case $sku in
		HI151|HI156)
			i2c_bus_offset=$((i2c_bus_offset-1))
			;;
		default)
			;;
		esac

                echo $i2c_bus_offset > $config_path/i2c_bus_offset
                return
            fi
        fi
    done

    log_err "I2C infrastructure is not created"
    exit 0
}

lock_service_state_change()
{
    exec {LOCKFD}>${LOCKFILE}
    /usr/bin/flock -x ${LOCKFD}
    trap "/usr/bin/flock -u ${LOCKFD}" EXIT SIGINT SIGQUIT SIGTERM
}

unlock_service_state_change()
{
    /usr/bin/flock -u ${LOCKFD}
}

check_labels_enabled()
{
    if [ "$ui_tree_sku" = "HI130" ] && [ ! -e "$ui_tree_archive" ]; then
        return 0
    else
        return 1
    fi
}

# Check if file exists and create soft link
# $1 - file path
# $2 - link path
# return none
check_n_link()
{
    if [ -f "$1" ];
    then
        ln -sf "$1" "$2"
        if  check_labels_enabled; then
            hw-management-labels-maker.sh "$2" "link" > /dev/null 2>&1 &
        fi
    fi
}

# Check if link exists and unlink it
# $1 - link path
# return none
check_n_unlink()
{
    if [ -L "$1" ];
    then
        unlink "$1"
        if check_labels_enabled; then
	    hw-management-labels-maker.sh "$1" "unlink" > /dev/null 2>&1 &
        fi
    fi
}

# Check if file not exists and create it
# $1 - file path
# $2 - default value
# return none
check_n_init()
{
	if [ ! -f $1 ]; then
		echo $2 > $1
	fi
}

# Read int val from file, inc it by val and save back
# value can negative
# $1 - counter file name
# $2 - value to add (can be < 0)
change_file_counter()
{
	file_name=$1
	val=$2
	[ -f "$file_name" ] && counter=$(< $file_name)
	counter=$((counter+val))
	if [ $counter -lt 0 ]; then
		counter=0
	fi
	echo $counter > $file_name
}

connect_device()
{
	find_i2c_bus
	if [ -f /sys/bus/i2c/devices/i2c-"$3"/new_device ]; then
		addr=$(echo "$2" | tail -c +3)
		bus=$(($3+i2c_bus_offset))
		if [ ! -d /sys/bus/i2c/devices/$bus-00"$addr" ] &&
		   [ ! -d /sys/bus/i2c/devices/$bus-000"$addr" ]; then
			echo "$1" "$2" > /sys/bus/i2c/devices/i2c-$bus/new_device
			return $?
		fi
	fi

	return 0
}

disconnect_device()
{
	find_i2c_bus
	if [ -f /sys/bus/i2c/devices/i2c-"$2"/delete_device ]; then
		addr=$(echo "$1" | tail -c +3)
		bus=$(($2+i2c_bus_offset))
		if [ -d /sys/bus/i2c/devices/$bus-00"$addr" ] ||
		   [ -d /sys/bus/i2c/devices/$bus-000"$addr" ]; then
			echo "$1" > /sys/bus/i2c/devices/i2c-$bus/delete_device
			return $?
		fi
	fi

	return 0
}

# Common retry helper function.
# Input:
# - $1 - user function to execute.
# - $2 - retry timeout delay window.
# - $3 - retry counter.
# - $4 - user log to be produced if user function failed (optional).
# Output:
# - return code (0 - success; 1 - failure).
# Example:
# retry_helper find_regio_sysfs_path_helper 0.5 10 "mlxreg_io is not loaded"
function retry_helper()
{
	local user_func="$1"
	local retry_to="$2"
	local retry_cnt="$3"
	local user_log="$4"

	for ((i=0; i<${retry_cnt}; i+=1)); do
		$user_func
		if [ $? -eq 0 ]; then
			return 0
		fi
		sleep "$retry_to"
	done

	if [ ! -z "$$user_log" ]; then
		log_err "$user_log"
	fi

	return 1
}

# Set PSU fan speed
# Input:
# - $1 - psu name
# - $2 - psu speed
# Output:
# - none
psu_set_fan_speed()
{
	local addr=$(< $config_path/"$1"_i2c_addr)
	local bus=$(< $config_path/"$1"_i2c_bus)
	local fan_config_command=$(< $config_path/fan_config_command)
	local fan_speed_units=$(< $config_path/fan_speed_units)
	local fan_command=$(< $config_path/fan_command)
	local speed=$2

	# Set fan speed units (percentage or RPM)
	i2cset -f -y "$bus" "$addr" "$fan_config_command" "$fan_speed_units" bp

	# Set fan speed
	i2cset -f -y "$bus" "$addr" "$fan_command" "${speed}" wp
}
