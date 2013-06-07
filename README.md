mypeople-irc-gateway
====================

mypeople-irc-gateway

1. Install Dependencies.

    cat cpandeps | cpanm

2. Edit the configuration in the source file.
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

4. Set MyPeopleBot Callback URL to http://YOUR_HOST:$HTTP_PORT/callback and API Request IP to YOUR_IP in Daum MyPeople-Bot page.

