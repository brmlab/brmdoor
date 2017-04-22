#!/bin/bash
WD=$(dirname $(readlink -f $0))
if [ -e $WD/brmdoor.conf ]; then
	echo "Loading config file $WD/brmdoor.conf..."
	. $WD/brmdoor.conf
else
	echo "ERROR: Config file not found. Please create brmdoor.conf in the same directory as brmdoor-rpi.sh."
	exit 1
fi

# WARNING - OPEN/DOOR are stored as GPIO values. Since we have pullups and switches that grounds these pins, values are inverted (ie. 1 means "CLOSED")
OPEN=1
DOOR=1
UNLOCKED=0

LOCK_TIMEOUT=3s

IGNORE_ALARM_SET=50

IGNORE_ALARM=0

export LD_LIBRARY_PATH=/usr/local/lib

clean_gpio() {
	for i in $GPIO_LOCK $GPIO_LED $GPIO_BEEP $GPIO_SWITCH $GPIO_MAGSWITCH; do
		echo in > /sys/class/gpio/gpio${i}/direction
		echo $i > /sys/class/gpio/unexport
	done
}


beep_invalid() {
	for i in `seq 1 2`; do
		echo 1 > /sys/class/gpio/gpio${GPIO_BEEP}/value
		sleep 0.05s
		echo 0 > /sys/class/gpio/gpio${GPIO_BEEP}/value
		sleep 0.05s
	done
}

beep_unlocked() {
	for i in `seq 1 3`; do
		echo 1 > /sys/class/gpio/gpio${GPIO_BEEP}/value
		sleep 0.05s
		echo 0 > /sys/class/gpio/gpio${GPIO_BEEP}/value
		sleep 0.05s
	done
}


beep_alarm() {
	for i in `seq 1 10`; do
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
	sleep 5s
	for chan in ${IRCCHANS[*]}; do
		echo "chan: $chan"
		T=`cat "${IRSSITOPICS}/${chan}"`
		NT=`echo "$T"|sed "s/$ROOM OPEN\|$ROOM CLOSED/$ROOM $1/"`
		echo "t: $T"
		echo "nt: $NT"
		echo "sed: s/$ROOM OPEN\|$ROOM CLOSED/$ROOM $1/"
		if [ "$NT" = "$T" ]; then
			continue;
		fi
		echo "TOPIC $chan $NT" > "$IRSSIFIFO"
	done

}

log_message() {
	echo "`date "+%Y-%m-%d %T"` $1" >> ~/brmdoor.log
}

updateSpaceApi() {
	local open=$1
	local changestamp=$2
	if [ -z $SPACEAPI_DST ] || [ ! -f $SPACEAPI_TPL ]; then
		return
	fi

	cat "$SPACEAPI_TPL"| sed "s/##OPEN##/$open/g;s/##LASTCHANGE##/$changestamp/g" > $SPACEAPI_DST
}

trap clean_gpio EXIT


for i in $GPIO_LOCK $GPIO_LED $GPIO_BEEP $GPIO_SWITCH $GPIO_MAGSWITCH; do
	echo $i > /sys/class/gpio/export
done

sleep 1 # do not remove unless running as root... few ms after exporting the GPIO the file is owned by root:root

for i in $GPIO_LOCK $GPIO_LED $GPIO_BEEP; do
	echo "out" > /sys/class/gpio/gpio${i}/direction
done

for i in $GPIO_SWITCH $GPIO_MAGSWITCH; do
	echo "in" > /sys/class/gpio/gpio${i}/direction
done


LOOP=0

NFC_FAILED=1

CURRENT_OPEN=`cat /sys/class/gpio/gpio${GPIO_SWITCH}/value`
LASTCHANGE=`date +%s`

if [ $CURRENT_OPEN -eq 1 ]; then
	irc_status "CLOSED" &
	updateSpaceApi false $LASTCHANGE
else
	irc_status "OPEN" &
	updateSpaceApi true $LASTCHANGE
fi

while true; do
	CARD=`$NFC_BINARY`
	RET=$?
	if [ $RET -ne 0 ] && [ $NFC_FAILED -eq 1 ] ; then
		NFC_FAILED=0
		log_message "NFC_FAILURE"
		logger -p user.error "[$IDENTITY] NFC failure"
#		irc_message "[$IDENTITY] NFC error! Might be out of order!"
		sleep 1s
		continue
	elif [ $RET -eq 0 ] && [ $NFC_FAILED -eq 0 ]; then
		NFC_FAILED=1
	        log_message "NFC_BACK"
                logger -p user.error "[$IDENTITY] NFC back"
#                irc_message "[$IDENTITY] NFC communication is back!"
	fi

	if [ $IGNORE_ALARM -gt 0 ]; then
		let IGNORE_ALARM=$IGNORE_ALARM-1
	fi
	
	if [ -n "$CARD" ]; then # we have a card
		NAME=`grep -i "^[0-9a-zA-Z_-]* ${CARD}$" "$ALLOWED_LIST"| cut -d ' ' -f 1`
		if [ -z "$NAME" ]; then
			log_message "UNKNOWN_CARD $CARD" &
			logger "[$IDENTITY] unauthorized access denied for card $CARD" &
			irc_message "[$IDENTITY] unauthorized access denied" &
			beep_invalid
		else
			log_message "DOOR_UNLOCKED $NAME $CARD" &
			logger "[$IDENTITY] unlocked by $NAME $CARD" &
			irc_message "[$IDENTITY] door unlocked" &
			echo 1 > /sys/class/gpio/gpio${GPIO_LOCK}/value
			beep_unlocked &
			sleep $LOCK_TIMEOUT
			echo 0 > /sys/class/gpio/gpio${GPIO_LOCK}/value
			IGNORE_ALARM=$IGNORE_ALARM_SET
		fi
	fi

	# check open/closed status
	CURRENT_OPEN=`cat /sys/class/gpio/gpio${GPIO_SWITCH}/value`
	if [ $CURRENT_OPEN -eq 1 -a $OPEN -eq 0 ]; then
		log_message "STATUS_CLOSED" &
		irc_message "[${STATUS}] update: CLOSED" &
		irc_status "CLOSED" &
		LASTCHANGE=`date +%s`
		updateSpaceApi false $LASTCHANGE
		IGNORE_ALARM=$IGNORE_ALARM_SET
		if [ -n $IMAGE_DST ]; then
			cp $IMAGE_CLOSED $IMAGE_DST
		fi
	fi
	if [ $CURRENT_OPEN -eq 0 -a $OPEN -eq 1 ]; then
		log_message "STATUS_OPEN" &
		irc_message "[${STATUS}] update: OPEN" &
		irc_status "OPEN" &
		LASTCHANGE=`date +%s`
		updateSpaceApi true $LASTCHANGE
		if [ -n $IMAGE_DST ]; then
			cp $IMAGE_OPEN $IMAGE_DST
		fi
	fi

	CURRENT_DOOR=`cat /sys/class/gpio/gpio${GPIO_MAGSWITCH}/value`

	OPEN=$CURRENT_OPEN

	if [ $CURRENT_DOOR -eq 1 ] && [ $DOOR -eq 0 ] && [ $OPEN -eq 1 ] && [ $IGNORE_ALARM -eq 0 ]; then
		log_message "DOOR_ALARM" &
		irc_message "[$IDENTITY] alarm! (status closed, door opened, not unlocked)" &
		beep_alarm
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

	if [ $LOOP -gt 10 ]; then
		LOOP=0
		if [ $OPEN -eq 1 ]; then
			echo 1 > /sys/class/gpio/gpio${GPIO_LED}/value
		else
			echo 0 > /sys/class/gpio/gpio${GPIO_LED}/value
		fi
	fi

	let LOOP=$LOOP+1
	sleep 1
done
