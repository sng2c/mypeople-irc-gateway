mypeople-irc-gateway
====================

mypeople-irc-gateway

1. Install Dependencies.

    cat cpandeps | cpanm

2. Edit the source.

* $IRC_HOST
* $IRC_PORT
* $IRC_NICK
* $IRC_CHANNEL

* $MYPEOPLE_APIKEY : If you not set, the script fill it from system environment values.
* $HTTP_PORT

3. And execute below in shell.

    perl mypeople-irc-gateway.pl

	or

    MYPEOPLE_APIKEY=XXXXXXXXXXX perl mypeople-irc-gateway.pl
