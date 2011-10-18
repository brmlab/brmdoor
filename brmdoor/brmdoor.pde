// get file cardids.h from the Council section in our wiki!

#define MUSIC 1

#include "NewSoftSerial.h"

// pins
const int magnetPin = 10;
const int soundPin = 9; /* piezo in series with 100R */
const int statusLed = 8;
const int statusBtn = 7;
const int videoLed = 6;
const int videoBtn = 5;
const int doorLock = 4;
const int rfidRx = 3;
const int rfidTx = 2;

int statusState = 0, statusStateOverride = 0;
int videoState = 0, videoStateOverride = 0;

// cardId is the same as you can see in CARD telnet message
struct ACLdata {
  byte cardId[7];
  char *nick;
} ACL[] = {
// the following include file contains lines like
// { {0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE}, "username" },
#include "cardids.h"
};

// comSerial for communication with the host
#define comSerial Serial

// rfidSerial for communication with the RFID reader
NewSoftSerial rfidSerial(rfidTx, rfidRx);

#if MUSIC

#include "pitches.h"

int melody_nak[] = { NOTE_G5, NOTE_G5, NOTE_G5, NOTE_DS5, NOTE_AS5, NOTE_G5, NOTE_DS5, NOTE_AS5, NOTE_G5};
int noteDurations_nak[] = { 330, 330, 330, 250, 120, 330, 250, 120, 500 };

int melody_ack[] = { NOTE_D6, NOTE_A6, NOTE_C7, NOTE_A6 };
int noteDurations_ack[] = { 120, 500, 120, 500 };

int melody_alarm[] = { NOTE_D6, NOTE_F6, NOTE_D6, NOTE_F6 };
int noteDurations_alarm[] = { 700, 700, 700, 700 };

void toneManual(int pin, int frequency, int duration)
{
  unsigned long period = 1000000/frequency;
  unsigned long length;
  boolean state = false;
  for (length = 0; length < (long) duration * 1000; length += period) {
    state = !state;
    digitalWrite(pin, state);
    /* The 50uS correspond to the time the rest of the loop body takes.
     * It seems about right, but has not been tuned precisely for
     * a 16MHz ATMega. */
    delayMicroseconds(period - 50);
    //comSerial.print(pin, DEC); comSerial.print(state, DEC); comSerial.write(" "); comSerial.print(period); comSerial.write(" "); comSerial.print(length); comSerial.write("\n");
  }
}

void playMelody(int *melody, int *noteDurations, int dcoef, int notes)
{
  int i;
  for (i = 0; i < notes; i++) {
    // comSerial.print(melody[i]); comSerial.write(" "); comSerial.print(noteDurations[i]); comSerial.write("\n");
    toneManual(soundPin, melody[i], noteDurations[i]);

    delay(noteDurations[i] * dcoef/10);
  }
}

void playMelodyAck()
{ playMelody(melody_ack, noteDurations_ack, 6, sizeof(melody_ack)/sizeof(melody_ack[0])); }
void playMelodyNak()
{ playMelody(melody_nak, noteDurations_nak, 6, sizeof(melody_nak)/sizeof(melody_nak[0])); }
void playMelodyAlarm()
{ playMelody(melody_alarm, noteDurations_alarm, 1, sizeof(melody_alarm)/sizeof(melody_alarm[0])); }


#else

void playMelodyAck()
{}
void playMelodyNak()
{}
void playMelodyAlarm()
{}

#endif

// opens door for "ms" milliseconds
void openDoorForTime(int ms)
{
  digitalWrite(doorLock, HIGH);
  playMelodyAck();
  delay(ms);
  digitalWrite(doorLock, LOW);
}

void readCard()
{
  byte RequestCardStatus[] = { 0xAA, 0x00, 0x03, 0x25, 0x26, 0x00, 0x00, 0xBB };
  byte NoCardResponse[] = { 0xAA, 0x00, 0x02, 0x01, 0x83, 0x80, 0xBB };
  byte buf[16];
  int i;

  // write query to serial
  for (i = 0; i < 8; i++)
    rfidSerial.print(RequestCardStatus[i]);
  // wait for the result, while reblinking
  delay(100);
  digitalWrite(statusLed, statusState);
  delay(150);

  // read input from serial into the buffer
  i = 0;
  while (rfidSerial.available() > 0) {
    if (i < sizeof(buf)) {
      buf[i] = rfidSerial.read();
    }
    ++i;
  }

  // no card is detected
  if (!memcmp(buf, NoCardResponse, 7)) {
    comSerial.write("NOCARD\n");
  }

  // card detected - message has form AA0006xxxxxxxxxxxxxxBB where xxx... is the card ID
  if (buf[0] == 0xAA && buf[1] == 0x00 && buf[2] == 0x06 && buf[10] == 0xBB) {
    bool known = false;
    // go through ACL
    for (int i = 0; i < sizeof(ACL)/sizeof(ACL[0]); ++i) {
      // if there is a match - print known card ...
      if (!memcmp(ACL[i].cardId, buf+3, 7)) {
        known = true;
        comSerial.write("CARD ");
        comSerial.write(ACL[i].nick);
        comSerial.write("\n");
        // ... and open door for 5s
        openDoorForTime(5000);
        break;
      }
    }
    // card was not found in the ACL
    if (!known) {
      comSerial.write("CARD UNKNOWN ");
      for (int i = 0; i < 7; ++i) {
        if (buf[i+3] <= 0xF) comSerial.write("0");
        comSerial.print(buf[i+3], HEX);
      }
      comSerial.write("\n");
      playMelodyNak();
    }
  } else {
    // make cycle interval 1s
    delay(750);
  }
}

void readSerial()
{
  if (comSerial.available()) {
    unsigned char cmd = comSerial.read();
    unsigned char data = comSerial.read();
    switch (cmd) {
      case 's': statusState = data - '0'; statusStateOverride = 1; break;
      case 'v': videoState = data - '0'; videoStateOverride = 1; break;
      case 'a': playMelodyAlarm(); /* data ignored */ break;
    }
  }
}

void setup()
{
  pinMode(magnetPin, INPUT);
  digitalWrite(magnetPin, HIGH);
  pinMode(doorLock, OUTPUT);
  pinMode(soundPin, OUTPUT);
  pinMode(statusLed, OUTPUT);
  pinMode(videoLed, OUTPUT);
  pinMode(statusBtn, INPUT);
  digitalWrite(statusBtn, HIGH);
  pinMode(videoBtn, INPUT);
  digitalWrite(videoBtn, HIGH);
  rfidSerial.begin(9600);
  comSerial.begin(9600);
}

void loop()
{
  /* Check buttons. */
  int statusStateNew = !digitalRead(statusBtn);
  int videoStateNew = !digitalRead(videoBtn);
  /* Cancel override if button is in same state as official state. */
  if (statusState == statusStateNew) statusStateOverride = 0;
  if (videoState == videoStateNew) videoStateOverride = 0;
  /* Update state based on buttons and override. */
  if (!statusStateOverride) statusState = statusStateNew;
  if (!videoStateOverride) videoState = videoStateNew;
  
  int doorOpen = digitalRead(magnetPin);

  digitalWrite(statusLed, !statusState); // will be turned back in readCard()
  digitalWrite(videoLed, videoState);
  comSerial.print(statusState, DEC); comSerial.write(" ");
  comSerial.print(videoState, DEC); comSerial.write(" ");
  comSerial.print(doorOpen, DEC); comSerial.write(" ");
  readCard();
  readSerial();
}
