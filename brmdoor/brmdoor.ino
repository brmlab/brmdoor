// get file cardids.h from the Council section in our wiki!

#define MUSIC 1

#include <SoftwareSerial.h>
#include <Adafruit_PN532.h>

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

// Pins where Adafruit PN532 shield is connected.
// Note that these are the analog pins used in digital mode - no other pins
// were available.
const int PN532_SCK   = A3;
const int PN532_MOSI  = A2;
const int PN532_SS    = A1;
const int PN532_MISO  = A0;

// Set to true if you want to have correct UID printed in hex after CARD
// message into UART (case when card is known).
bool printFullUID = false;

// Max retries to read card before timeout, 200 is around 1 second, 0xFF means
// wait forever (constitutes blocking read).
uint8_t pn532MaxRetries = 200;
bool pn532Working; //whether we have connected and working chip

int statusState = 0, statusStateOverride = 0;
int videoState = 0, videoStateOverride = 0;

/*!
 * The cardId is the same as you can see in CARD telnet message
 *
 * It's called broken, because we had broken reader that couldn't read 7-byte IDs.
 * I.e. the old reader could only use SELECT cascade 1, which begins with 0x88
 * cascading tag, thus we have only 3 bytes from 7-byte UIDs.
 *
 * So if we get a 7-byte ID, we must do "retarded search" for the 3-byte part.
 * If an ID in this struct contains 0x88 as third byte (index 2), it means it's
 * a card with 7 or 10 byte UID and begins with a cascading tag 0x88.
 * 
 * Currently the bytes seem to be:
 *
 * case of 4-byte UID:  0x00, 0x00, UID1, UID2, UID3, UID4, BCC
 * case of 7-byte UID:  0xFF, 0x00, 0x88, UID1, UID2, UID3, BCC
 * case of 10-byte UID: ??? I don't think I actually saw a real card with
 *                      10-byte UID, but it's in the NXP specs
 *
 */
typedef struct ACLdataBroken {
    byte cardId[7];
    char *nick;
} ACLRecordBroken;

/*! 
 * List of ACLs included from a static array, see ACLRecordBroken for details.
 */
ACLRecordBroken ACL[] = {
/* The following include file contains lines like
 * { {0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE}, "username" },
 */
#include "cardids.h"
};

// Let's hope aliasing won't break this.
// OMG why not some proper structures?
#define ACL_COUNT (sizeof(ACL)/sizeof(ACLRecordBroken))

// ISO14443 cascading tag
#define CASCADING_TAG 0x88

// comSerial for communication with the host
#define comSerial Serial

// PN532 chip instance
Adafruit_PN532 nfc(PN532_SCK, PN532_MISO, PN532_MOSI, PN532_SS);

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

/*!
 * Will search for given card UID in the borken ACL list with truncated UIDs.
 * 
 * @param uid UID of the card read
 * @param length length of the UID in bytes
 * @param acls list of ACLs in the old b0rken form
 * @param count of ACLs in the above array
 * @returns index into acls if found or -1 if not found
 */
int retardedACLSearch(const uint8_t *uid, uint8_t length, const struct ACLdataBroken *acls, int aclCount)
{
    int idx = -1;

    for(int i=0; i<aclCount; i++) {
        const ACLRecordBroken& acl = acls[i];

        // Look for ISO14443 cascading tag 0x88 in third byte of the UID.
        // If it's present, then the UID has been truncated - only 3 bytes
        // are correct. Otherwise we got correct 4 byte UID.
        if (acl.cardId[2] == CASCADING_TAG) { // truncated UID
            if (memcmp(acl.cardId+3, uid, 3) == 0) {
                idx = i;
                break;
            }
        } else { // full 4-byte UID
            if (memcmp(acl.cardId+2, uid, 4) == 0) {
                idx = i;
                break;
            }
        }
    }

    return idx;
}

/*! Writes given UID encoded in hex to the serial specified. */
void serialWriteUIDHex(const uint8_t *uid, uint8_t length)
{
    for (int i=0; i<length; i++) {
        comSerial.print(uid[i], HEX);
    }
}

/*! Returns true iff we could read a card's UID.
 * That card UID is then looked up in the ACL array and response is sent
 * via UART to controlling computer (Raspberry, etc).
 *
 * Opens door for 5 seconds if the UID matched something in ACL array.
 *
 * Note: PN532 can read multiple cards in its field, but this is not supported
 * here (not necessary). The reader will pick one if there's more of them.
 */
bool readCardPN532()
{
    uint8_t uid[10] = {0};
    uint8_t uidLength = 0;
    bool success;
    int aclIdx = -1;

    if (!pn532Working) {
        comSerial.write("NOCARD\n");
        return false;
    }

    // read from PN532, change according to cardids, write result to comSerial
    success = nfc.readPassiveTargetID(PN532_MIFARE_ISO14443A, &uid[0], &uidLength);

    if (!success) {
        // no card in reader field
        comSerial.write("NOCARD\n");
        return false;
    }

    // search for card UID in b0rken ACL database
    aclIdx = retardedACLSearch(uid, uidLength, ACL, ACL_COUNT);

    if (aclIdx < 0) {
        // unknown card ID
        comSerial.write("CARD UNKNOWN ");
        serialWriteUIDHex(uid, uidLength);
        comSerial.write("\n");
        delay(750);
        return false;
    }

    // OK we got some known card
    comSerial.write("CARD ");
    comSerial.write(ACL[aclIdx].nick);

    if (printFullUID) {
        comSerial.write(" ");
        serialWriteUIDHex(uid, uidLength);
    }

    comSerial.write("\n");

    openDoorForTime(5000);
    
    return true;
}

/*! Set status led according to status, delat a bit. */
void statusUpdate()
{
  delay(100);
  digitalWrite(statusLed, statusState);
  delay(150);
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
  comSerial.begin(9600);

  uint32_t versiondata = nfc.getFirmwareVersion();
  if (! versiondata) {
    comSerial.write("CARD READER BROKEN\n");
    pn532Working = false;
  } else {
    nfc.SAMConfig();
    nfc.setPassiveActivationRetries(pn532MaxRetries);
    pn532Working = true;
  }
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

  digitalWrite(statusLed, !statusState);
  digitalWrite(videoLed, videoState);

  comSerial.print(statusState, DEC); comSerial.write(" ");
  comSerial.print(videoState, DEC); comSerial.write(" ");
  comSerial.print(doorOpen, DEC); comSerial.write(" ");

  statusUpdate();

  readCardPN532();
  readSerial();
}

