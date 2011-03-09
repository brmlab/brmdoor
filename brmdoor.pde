// get file cardids.h from the Council section in our wiki!

#define MUSIC 1

// if you are running Arduino0018 or older, comment the SPI.h include
#include <SPI.h>
#include <Ethernet.h>

// pins
const int doorLock = 5;
const int soundPin = 9;
const int statusLed = 8;
const int statusBtn = 7;
const int videoLed = 6;
const int videoBtn = 3;

int statusState = 0;
int videoState = 0;

// cardId is the same as you can see in CARD telnet message
struct ACLdata {
  byte cardId[7];
  char *nick;
} ACL[] = {
// the following include file contains lines like
// { {0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE}, "username" },
#include "cardids.h"
};

// run telnet server
Server server(23);

#if MUSIC

#include "pitches.h"

int melody_nak[] = { NOTE_G5, NOTE_G5, NOTE_G5, NOTE_DS5, NOTE_AS5, NOTE_G5, NOTE_DS5, NOTE_AS5, NOTE_G5};
int noteDurations_nak[] = { 330, 330, 330, 250, 120, 330, 250, 120, 500 };

int melody_ack[] = { NOTE_D6, NOTE_A6, NOTE_C7, NOTE_A6 };
int noteDurations_ack[] = { 120, 500, 120, 500 };

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
    //server.print(pin, DEC); server.print(state, DEC); server.write(" "); server.print(period); server.write(" "); server.print(length); server.write("\n");
  }
}

void playMelody(int *melody, int *noteDurations, int notes)
{
  int i;
  for (i = 0; i < notes; i++) {
    // server.print(melody[i]); server.write(" "); server.print(noteDurations[i]); server.write("\n");
    toneManual(soundPin, melody[i], noteDurations[i]);

    delay(noteDurations[i] * 6/10);
  }
}

void playMelodyAck()
{ playMelody(melody_ack, noteDurations_ack, sizeof(melody_ack)/sizeof(melody_ack[0])); }
void playMelodyNak()
{ playMelody(melody_nak, noteDurations_nak, sizeof(melody_nak)/sizeof(melody_nak[0])); }

#else

void playMelodyAck()
{}
void playMelodyNak()
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

  // write query to serial
  Serial.write(RequestCardStatus, 8);
  // wait for the result, while reblinking
  delay(100);
  digitalWrite(statusLed, statusState);
  delay(150);

  // read input from serial into the buffer
  int i = 0;
  while (Serial.available() > 0) {
    if (i < sizeof(buf)) {
      buf[i] = Serial.read();
    }
    ++i;
  }

  // no card is detected
  if (!memcmp(buf, NoCardResponse, 7)) {
    server.write("NOCARD\n");
  }

  // card detected - message has form AA0006xxxxxxxxxxxxxxBB where xxx... is the card ID
  if (buf[0] == 0xAA && buf[1] == 0x00 && buf[2] == 0x06 && buf[10] == 0xBB) {
    bool known = false;
    // go through ACL
    for (int i = 0; i < sizeof(ACL)/sizeof(ACL[0]); ++i) {
      // if there is a match - print known card ...
      if (!memcmp(ACL[i].cardId, buf+3, 7)) {
        known = true;
        server.write("CARD ");
        server.write(ACL[i].nick);
        server.write("\n");
        // ... and open door for 5s
        openDoorForTime(5000);
        break;
      }
    }
    // card was not found in the ACL
    if (!known) {
      server.write("CARD UNKNOWN ");
      for (int i = 0; i < 7; ++i) {
        if (buf[i+3] < 0xF) server.write("0");
        server.print(buf[i+3], HEX);
      }
      server.write("\n");
      playMelodyNak();
    }
  }
  // make cycle interval 1s
  delay(750);
}

void setup()
{
  // constants for ethernet shield
  byte mac[] = { 0xDE, 0xAD, 0xBE, 0xEF, 0xFE, 0xED };
  byte ip[] = { 192, 168, 1, 3 };
  byte gateway[] = { 192, 168, 1, 1 };
  byte subnet[] = { 255, 255, 255, 0 };

  pinMode(doorLock, OUTPUT);
  pinMode(soundPin, OUTPUT);
  pinMode(statusLed, OUTPUT);
  pinMode(videoLed, OUTPUT);
  pinMode(statusBtn, INPUT);
  digitalWrite(statusBtn, HIGH);
  pinMode(videoBtn, INPUT);
  digitalWrite(videoBtn, HIGH);
  Serial.begin(9600);
  Ethernet.begin(mac, ip, gateway, subnet);
  server.begin();
}

void loop()
{
  statusState = !digitalRead(statusBtn);
  videoState = !digitalRead(videoBtn);
  digitalWrite(statusLed, !statusState); // will be turned back in readCard()
  digitalWrite(videoLed, videoState);
  server.print(statusState, DEC); server.write(" ");
  server.print(videoState, DEC); server.write(" ");
  readCard();
}
