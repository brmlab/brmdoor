#!/usr/bin/python
#
# Copyright (c) 2010 Pavol Rusnak <stick@gk2.sk>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#

import sys
from ircbot import SingleServerIRCBot

class BrmDoorBot(SingleServerIRCBot):
    def __init__(self, channel, nickname, server, port=6667):
        SingleServerIRCBot.__init__(self, [(server, port)], nickname, nickname)
        self.channel = channel

    def on_nicknameinuse(self, c, e):
        c.nick(c.get_nickname() + "_")

    def on_welcome(self, c, e):
        c.join(self.channel)

    def on_topic(self, c, e):
         print e.eventtype()
         print e.source()
         print e.target()
         print e.arguments()

    def on_join(self, c, e):
         print e.eventtype()
         print e.source()
         print e.target()
         print e.arguments()
#         c.privmsg(self.channel, 'hello')
         self.disconnect()
         self.die()

def change_state(state):
    bot = BrmDoorBot("#kvak", "brmdoor", "irc.freenode.net")
    bot.start()

# DEBUG INTERFACE

if len(sys.argv) != 2:
    print "\nUsage: brmdoor [0|1]\n\n"
    sys.exit(1)

if sys.argv[1] == '0':
    change_state(False)

if sys.argv[1] == '1':
    change_state(True)
