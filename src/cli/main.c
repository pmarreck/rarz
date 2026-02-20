#include <stdio.h>
#include "rarz.h"

int main(void) {
	printf("rarz - clean-room RAR archive toolkit\n");
	printf("ABI version: %u\n", rarz_abi_version());
	return 0;
}
