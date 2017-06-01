#!/bin/bash
MSG_SUCCESS="Seznam brmkaret byl aktualizovan"

cat - > /tmp/cards.tmp

cf=/home/brmdoor/brmdoor/brmdoor-rpi/allowed.list

if [ `cat /tmp/cards.tmp | wc -l` -le 20 -o `cat /tmp/cards.tmp | wc -l` -ge 100 ]; then
  echo "Sanity check error: file length mismatch"
  exit 1
fi

if [ `diff /tmp/cards.tmp /root/brmdoor/allowed.list | wc -l` -ge 20 ]; then
  echo "Sanity check error: too many changes"
  exit 1
fi

CARDS_COUNT="$(wc -l /tmp/cards.tmp)"
MSG_SUCCESS="${MSG_SUCCESS} (${CARDS_COUNT} cards)"

cp /tmp/cards.tmp "$cf" && logger "${MSG_SUCCESS}" && echo "${HOSTNAME}: ${MSG_SUCCESS}"

