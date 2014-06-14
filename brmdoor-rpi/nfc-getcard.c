#include <stdint.h>
#include <stdio.h>

#include <nfc/nfc.h>
#include <nfc/nfc-types.h>

static nfc_device *pnd = NULL;
static nfc_context *context;

int main(int argc, const char *argv[]) {
	const uint8_t uiPollNr = 0x01;
	const uint8_t uiPeriod = 0x01;
	const nfc_modulation nmModulations[5] = {
		{ .nmt = NMT_ISO14443A, .nbr = NBR_106 },
		{ .nmt = NMT_ISO14443B, .nbr = NBR_106 },
		{ .nmt = NMT_FELICA, .nbr = NBR_212 },
		{ .nmt = NMT_FELICA, .nbr = NBR_424 },
		{ .nmt = NMT_JEWEL, .nbr = NBR_106 },
	};
	const size_t szModulations = 5;

	nfc_target nt;
	int res = 0;
	int i=0;

	nfc_init(&context);
	if (context == NULL) {
		printf("Unable to init libnfc (malloc)");
		return 1;
	}

	pnd = nfc_open(context, NULL);

	if (pnd == NULL) {
		printf("Unable to open NFC device.");
		nfc_exit(context);
		return 1;
	}

	if (nfc_initiator_init(pnd) < 0) {
		nfc_close(pnd);
		nfc_exit(context);
		return 1;
	}

	if ((res = nfc_initiator_poll_target(pnd, nmModulations, szModulations, uiPollNr, uiPeriod, &nt)) < 0) {
		nfc_close(pnd);
		nfc_exit(context);
		return 0;
	}

	if (res > 0) {
		if(nt.nm.nmt==NMT_ISO14443A) {
			nfc_iso14443a_info info=nt.nti.nai;
			for(i=0; i<info.szUidLen; i++) {
				printf("%0.2x", info.abtUid[i]);
			}
			printf("\n");
		}
	}

//	while (0 == nfc_initiator_target_is_present(pnd, NULL)) {
//	}

	nfc_close(pnd);
	nfc_exit(context);
	return 0;
}
