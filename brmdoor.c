/*
 * Copyright (c) 2010 Pavol Rusnak <stick@gk2.sk>
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <arpa/inet.h>
#include <unistd.h>

#define IRCSERVER "213.92.8.4" // irc.freenode.net
#define IRCPORT   6667
#define IRCNICK   "brmdoor"
#define IRCIDENT  "brmdoor"
#define IRCHOST   "brmlab.cz"
#define IRCCHAN   "#kvak"
#define IRCNAME   "brmlab door"

#define IRCJOINCMD "USER " IRCIDENT " " IRCHOST " " IRCNICK " :" IRCNAME "\r\nNICK " IRCNICK "\r\nJOIN " IRCCHAN "\r\n"

#define BUFSIZE 1024
char buf[BUFSIZE];

void do_irc(int o)
{
    struct sockaddr_in sa;
    int res;
    int fd = socket(PF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (-1 == fd)
        return;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons(IRCPORT);
    res = inet_pton(AF_INET, IRCSERVER, &sa.sin_addr);
    if (0 >= res) {
        close(fd);
        return;
    }
    if (-1 == connect(fd, (struct sockaddr *)&sa, sizeof(sa))) {
        close(fd);
        return;
    }


/*

  $topic = '';
  while (!feof($fp)) {
    $line = fgets($fp,256);
    $data = explode(' ', $line, 5);
    if ($data[1] == '366') break;
    if ($data[1] == '332') {
      $topic = $data[4];
     break;
    }
  }

  if (!$topic) {
    $topic = $open ? 'BRMLAB OPEN' : 'BRMLAB CLOSED';
  } else {
    $topic = explode('|', $topic, 2);
    @ $topic = ($open ? 'BRMLAB OPEN' : 'BRMLAB CLOSED') . ' | ' . trim($topic[1]);
  }

  fwrite($fp, "TOPIC $chan :$topic\r\n");
  while (!feof($fp)) {
    $line = fgets($fp,256);
    $data = explode(' ', $line, 3);
    if ($data[1] == 'TOPIC') break;
  }


*/

    shutdown(fd, SHUT_RDWR);
    close(fd);
}

int main(int argc, char **argv)
{
    if (argc < 2 || (argv[1][0] & 0xFE) != 0x30 ) // first arg is not 0 or 1
    {
        printf("\nUsage: brmdoor [0|1]\n\n");
        return 1;
    }

    switch (argv[1][0]) {
        case '0':
            do_irc(0);
            break;
        case '1':
            do_irc(1);
            break;
    }

    return 0;
}
