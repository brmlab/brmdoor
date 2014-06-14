#!/bin/bash

GPIO_LOCK=24
GPIO_LED=22
GPIO_BEEP=23

GPIO_SWITCH=18
GPIO_MAGSWITCH=17


NFC_BINARY=/root/brmdoor/nfc-getcard
ALLOWED_LIST=/root/brmdoor/allowed.list

IRSSIFIFO=/home/brmdoor/.irssi/remote-control
IRCCHANS=("#brmlab" "#brmbiolab" "#brmstatus")
IRSSITOPICS=/home/brmdoor/.irssi/topics/


# WARNING - OPEN/DOOR are stored as GPIO values. Since we have pullups and switches that grounds these pins, values are inverted (ie. 1 means "CLOSED")
OPEN=1
DOOR=1
UNLOCKED=0

LOCK_TIMEOUT=3s

IGNORE_ALARM_SET=10

IGNORE_ALARM=0


export LD_LIBRARY_PATH=/usr/local/lib


clean_gpio() {
	for i in $GPIO_LOCK $GPIO_LED $GPIO_BEEP $GPIO_SWITCH $GPIO_MAGSWITCH; do
		echo in > /sys/class/gpio/gpio${i}/direction
		echo $i > /sys/class/gpio/unexport
	done
}


beep_invalid() {
	for i in `seq 1 5`; do
		echo 1 > /sys/class/gpio/gpio${GPIO_BEEP}/value
		sleep 0.05s
		echo 0 > /sys/class/gpio/gpio${GPIO_BEEP}/value
		sleep 0.05s
	done
}

beep_alarm() {
	for i in `seq 1 5`; do
		echo 1 > /sys/class/gpio/gpio${GPIO_BEEP}/value
		sleep 0.5s
		echo 0 > /sys/class/gpio/gpio${GPIO_BEEP}/value
		sleep 0.5s
	done
}

irc_message() {
	if [ ! -p "$IRSSIFIFO" ]; then
		echo "irssi fifo '$IRSSIFIFO' does not exist!"
		return
	fi
	for chan in ${IRCCHANS[*]}; do
		echo "MSG $chan $1" > "$IRSSIFIFO"
	done
}

irc_status() {
	if [ ! -p "$IRSSIFIFO" ]; then
		echo "irssi fifo '$IRSSIFIFO' does not exist!"
		return
	fi
	echo "TINFO" > "$IRSSIFIFO"
	for chan in ${IRCCHANS[*]}; do
		T=`cat "${IRSSITOPICS}/${chan}"`
		NT=`echo "$T"|sed "s/BRMBIOLAB OPEN\|BRMBIOLAB CLOSED/BRMBIOLAB $1/"`
		if [ "$NT" = "$T" ]; then
			continue;
		fi
		echo "TOPIC $chan $NT" > "$IRSSIFIFO"
	done

}

log_message() {
	echo "`date "+%Y-%m-%d %T"` $1" >> ~/brmdoor.log
}

trap clean_gpio EXIT


for i in $GPIO_LOCK $GPIO_LED $GPIO_BEEP $GPIO_SWITCH $GPIO_MAGSWITCH; do
	echo $i > /sys/class/gpio/export
done

for i in $GPIO_LOCK $GPIO_LED $GPIO_BEEP; do
	echo "out" > /sys/class/gpio/gpio${i}/direction
done

for i in $GPIO_SWITCH $GPIO_MAGSWITCH; do
	echo "in" > /sys/class/gpio/gpio${i}/direction
done


LOOP=0

while true; do
	CARD=`$NFC_BINARY`
	if [ $? -ne 0 ]; then
		
		log_message "NFC_FAILURE"
		logger -p user.error "[biodoor] NFC failure"
		irc_message "[biodoor] NFC error! Might be out of order!"
		sleep 15s
	fi

	if [ $IGNORE_ALARM -gt 0 ]; then
		let IGNORE_ALARM=$IGNORE_ALARM-1
	fi
	
	if [ -n "$CARD" ]; then # we have a card
		NAME=`grep -i "^[0-9a-zA-Z_-]* ${CARD}$" "$ALLOWED_LIST"| cut -d ' ' -f 1`
		if [ -z "$NAME" ]; then
			log_message "UNKNOWN_CARD $CARD"
			logger "[biodoor] unauthorized access denied for card $CARD"
			irc_message "[biodoor] unauthorized request denied!"
			beep_invalid
		else
			log_message "DOOR_UNLOCKED $NAME $CARD"
			logger "[biodoor] unlocked by $NAME $CARD"
			irc_message "[biodoor] door unlocked"
			echo 1 > /sys/class/gpio/gpio${GPIO_LOCK}/value
			echo 1 > /sys/class/gpio/gpio${GPIO_BEEP}/value

			sleep $LOCK_TIMEOUT
			echo 0 > /sys/class/gpio/gpio${GPIO_LOCK}/value
			echo 0 > /sys/class/gpio/gpio${GPIO_BEEP}/value
			IGNORE_ALARM=$IGNORE_ALARM_SET
		fi
	fi

	# check open/closed status
	CURRENT_OPEN=`cat /sys/class/gpio/gpio${GPIO_SWITCH}/value`
	if [ $CURRENT_OPEN -eq 1 -a $OPEN -eq 0 ]; then
		log_message "STATUS_CLOSED"
		irc_message "BRMBIOLAB is now *CLOSED*"
		irc_status "CLOSED"
		IGNORE_ALARM=$IGNORE_ALARM_SET
	fi
	if [ $CURRENT_OPEN -eq 0 -a $OPEN -eq 1 ]; then
		log_message "STATUS_OPEN"
		irc_message "BRMBIOLAB is now *OPEN*"
		irc_status "OPEN"

	fi

	CURRENT_DOOR=`cat /sys/class/gpio/gpio${GPIO_MAGSWITCH}/value`

	OPEN=$CURRENT_OPEN

	if [ $CURRENT_DOOR -eq 1 ] && [ $DOOR -eq 0 ] && [ $OPEN -eq 1 ] && [ $IGNORE_ALARM -eq 0 ]; then # doplnit timeout
		log_message "DOOR_ALARM"
		irc_message "[biodoor] alarm (door opened without unlock)!!!"

		beep_alarm &
	fi

	DOOR=$CURRENT_DOOR


	# just the led blinking stuff	
	if [ $LOOP -le 1 ]; then
		if [ $OPEN -eq 1 ]; then
			echo 0 > /sys/class/gpio/gpio${GPIO_LED}/value
		else
			echo 1 > /sys/class/gpio/gpio${GPIO_LED}/value
		fi
	fi

	if [ $LOOP -gt 5 ]; then
		LOOP=0
		if [ $OPEN -eq 1 ]; then
			echo 1 > /sys/class/gpio/gpio${GPIO_LED}/value
		else
			echo 0 > /sys/class/gpio/gpio${GPIO_LED}/value
		fi
	fi

	let LOOP=$LOOP+1
done
