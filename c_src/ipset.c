//
// setuid program to call /bin/ip as user program
//
// usage
//
// ipset down <canx>
// ipset up   <canx>
// ipset set  <canx> [key value]*
//

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>

const char* bin_ip = "/bin/ip";

void printv(char* argv[])
{
    int i = 0;

    fprintf(stderr, "ipset: ");
    while(argv[i] != NULL) {
	fprintf(stderr, "%s ", argv[i++]);
    }
    fprintf(stderr, "\r\n");
}

int main(int argc, char* argv[])
{
    if ((argc == 3) && (strcmp(argv[1],"up") == 0)) {
	char* argw[7];
	argw[0] = (char*) bin_ip;
	argw[1] = "link";
	argw[2] = "set";
	argw[3] = "dev";
	argw[4] = argv[2];
	argw[5] = "up";
	argw[6] = NULL;
	// printv(argw);
	execv(bin_ip, argw);
    }
    else if ((argc == 3) && (strcmp(argv[1],"down") == 0)) {
	char* argw[7];
	argw[0] = (char*) bin_ip;
	argw[1] = "link";
	argw[2] = "set";
	argw[3] = "dev";
	argw[4] =  argv[2];
	argw[5] = "down";
	argw[6] = NULL;
	// printv(argw);
	execv(bin_ip, argw);
    }
    else if ((argc > 3) && (strcmp(argv[1], "set") == 0)) {
	char* argw[5+(argc-3)+1];
	int i, j;
	// printv(argv);
	// fprintf(stderr, "argc=%d, |argw|=%d\r\n", argc, 8+(argc-3)+1);
	argw[0] = (char*) bin_ip;
	argw[1] = "link";
	argw[2] = "set";
	argw[3] = "dev";
	argw[4] = argv[2];
	j = 5;
	for (i = 3; i < argc; i++)
	    argw[j++] = (char*) argv[i];
	argw[j] = NULL;
	// printv(argw);
	execv(bin_ip, argw);
    }
    else {
	fprintf(stderr, "ipset: usage ipset up <canx> | down <canx> | "
		"set <canx> [key value]*\n");
	exit(1);
    }
    exit(0);
}
