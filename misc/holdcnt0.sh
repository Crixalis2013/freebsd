#!/bin/sh

#
# Copyright (c) 2013 EMC Corp.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#
# $FreeBSD$
#

# "panic: cluster_wbuild: page 0xc2eebc10 failed shared busing" seen.
# "panic: vdrop: holdcnt 0" seen.
# "panic: cleaned vnode isn't" seen.

# Test scenario suggestion by alc@

[ `id -u ` -ne 0 ] && echo "Must be root!" && exit 1

. ../default.cfg

here=`pwd`
cd /tmp
sed '1,/^EOF/d' < $here/$0 > holdcnt0.c
mycc -o holdcnt0 -Wall -Wextra -g holdcnt0.c || exit 1
rm -f holdcnt0.c
[ `uname -m` = "i386" ] && exit 0 # Not enough vm
cd $here

mount | grep $mntpoint | grep -q /dev/md && umount -f $mntpoint
mdconfig -l | grep -q md$mdstart &&  mdconfig -d -u $mdstart
mdconfig -a -t swap -s 5g -u $mdstart
bsdlabel -w md$mdstart auto
newfs md${mdstart}$part > /dev/null
mount /dev/md${mdstart}$part $mntpoint

(cd $mntpoint; /tmp/holdcnt0) &
sleep 5
while kill -0 $! 2> /dev/null; do
	(cd ../testcases/swap; ./swap -t 1m -i 1) > /dev/null 2>&1
done
wait

while mount | grep -q md${mdstart}$part; do
	umount $mntpoint || sleep 1
done
mdconfig -d -u $mdstart
rm -f /tmp/holdcnt0
exit 0
EOF
/*
   A test that causes the page daemon to generate cached pages
   within a bunch of files and has some consumer that is trying to
   allocate new pages to the same files.
*/

#include <sys/types.h>
#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define BUFSIZE (1024 * 1024)
#define FILES 200
#define RPARALLEL 8
#define WPARALLEL 2

static jmp_buf jbuf;
off_t maxsize;
int ps;
static char *buf;
volatile char val;

static void
hand(int i __unused) {  /* handler */
        longjmp(jbuf, 1);
}

void
cleanup(void)
{
	int i;
	char file[80];

	for (i = 0; i < FILES; i++) {
		snprintf(file, sizeof(file), "f%06d", i);
		unlink(file);
	}
}

void
init(void)
{
	char file[80];
	int fd, i;

	for (i = 0; i < FILES; i++) {
		snprintf(file, sizeof(file), "f%06d", i);
		if ((fd = open(file, O_RDWR | O_CREAT | O_TRUNC, 0644)) == -1)
			err(1, "open(%s)", file);
		if (write(fd, buf, BUFSIZE) != BUFSIZE)
			err(1, "write");
		close(fd);
	}

}

void
writer(void)
{
	int fd, i;
	char file[80];
	time_t start;
	struct stat statbuf;

	setproctitle("writer");
	start = time(NULL);
	while (time(NULL) - start < 600) {
		for (i = 0; i < FILES; i++) {
			snprintf(file, sizeof(file), "f%06d", i);
			if ((fd = open(file, O_RDWR | O_APPEND)) == -1) {
				if (errno != ENOENT)
					err(1, "open(%s) append", file);
				goto err;
			}
			if (fstat(fd, &statbuf) < 0)
				err(1, "fstat error");
			if (statbuf.st_size < maxsize) {
				if (write(fd, buf, ps) != ps) {
					warn("writer");
					goto err;
				}
			}
			close(fd);
		}
	}
err:
	cleanup();

	_exit(0);
}

void
reader(void)
{
	int fd, i, j, n;
	void *p;
	size_t len;
	char file[80];
	struct stat statbuf;

	setproctitle("reader");
	signal(SIGSEGV, hand);
	fd = 0;
	for (;;) {
		(void)setjmp(jbuf);
		for (i = 0; i < FILES; i++) {
			snprintf(file, sizeof(file), "f%06d", i);
			if (fd > 0)
				close(fd);
			if ((fd = open(file, O_RDWR)) == -1) {
				if (errno != ENOENT)
					warn("reader(%s)", file);
				_exit(0);
			}
			if (fstat(fd, &statbuf) < 0)
				err(1, "fstat error");
			if (statbuf.st_size >= maxsize) {
				if (ftruncate(fd, ps) == -1)
					err(1, "ftruncate");
				continue;
			}
			len = statbuf.st_size;
			if ((p = mmap(p, len, PROT_READ, MAP_SHARED, fd, 0)) == MAP_FAILED)
				err(1, "mmap()");
			close(fd);
			n = statbuf.st_size / ps;
			for (j = 0; j < n; j++) {
				val = *(char *)p;
				p = p + ps;
			}
#if 0
			if (munmap(p, len) == -1)
				perror("munmap");
#endif
		}
	}
	_exit(0);
}
int
main(void)
{
	int i;

	maxsize = 2LL * 1024 * 1024 * 1024 / FILES;
	buf = malloc(BUFSIZE);
	ps = getpagesize();

	init();
	for (i = 0; i < WPARALLEL; i++) {
		if (fork() == 0)
			writer();
	}
	for (i = 0; i < RPARALLEL; i++) {
		if (fork() == 0)
			reader();
	}

	for (i = 0; i < WPARALLEL; i++)
		wait(NULL);
	for (i = 0; i < RPARALLEL; i++)
		wait(NULL);

	free(buf);

	return (0);
}
