#!/usr/bin/env perl 

use strict;
use warnings;
use utf8;
use AnyEvent;
use AnyEvent::IRC::Client;
use AnyEvent::HTTPD;
use Net::MyPeople::Bot;
use Data::Printer;
use JSON;
use YAML;
use Encode;
use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init($DEBUG); # you can see requests in Net::MyPeople::Bot.

### CONFIGURATIONS FOR YOU ###
my $IRC_HOST = 'irc.freenode.net';
my $IRC_PORT = 8000;
my $IRC_NICK = 'MYPEOPLE_BOT';
my $IRC_CHANNEL = '#perl-kr';
my $MYPEOPLE_APIKEY = '';
my $HTTP_PORT = 8080; # for MyPeople-Bot
### CONFIGURATIONS END ###

$MYPEOPLE_APIKEY = $ENV{MYPEOPLE_APIKEY} unless $MYPEOPLE_APIKEY; # by env
unless($MYPEOPLE_APIKEY){
	ERROR "\$MYPEOPLE_APIKEY is not set.";
	exit;
}
my $datapath = 'data.yaml';
my $cv = AE::cv;
my $sig = AE::signal INT => sub{$cv->send(1);};


sub parse_msg {
    my ($irc_msg) = @_;
    my ($nickname) = $irc_msg->{prefix} =~ m/^([^!]+)/;
    my $message = $irc_msg->{params}[1];
    return ($nickname, $message);
}

my @names_queue;

my $bot = Net::MyPeople::Bot->new({apikey=>$MYPEOPLE_APIKEY});
my $irc = AnyEvent::IRC::Client->new;
my $httpd = AnyEvent::HTTPD->new (port => $HTTP_PORT );
$httpd->reg_cb (
	'/callback' => sub {
		my ($httpd, $req) = @_;

		my $action = $req->parm('action');
		my $buddyId = $req->parm('buddyId');
		my $groupId = $req->parm('groupId');
		my $content = $req->parm('content');

		$req->respond( { content => ['text/html','ok'] });
		callback( $action, $buddyId, $groupId, $content );
	}
);

my %mp_users;
my %mp_groups;
my %mp_nickmap;

if( -e $datapath ){
	my ($mpu, $mpg, $nickmap) = YAML::LoadFile($datapath);
	%mp_users = %{$mpu} if( $mpu );
	%mp_groups= %{$mpg} if( $mpg );
	%mp_nickmap = %{$nickmap} if($nickmap);
}


sub broadcast{
	my $content = shift;
	my ($except_buddyId,$except_groupId) = @_;
	foreach my $buddyId (keys %mp_users){
		next if $except_buddyId && $except_buddyId eq $buddyId;
		my $user = $mp_users{$buddyId};
		if( $user->{on} ){
			my $res = $bot->send($buddyId,$content);
			if( $res->{code} eq '404' ){
				delete $mp_users{$buddyId};
			}
		}
	}
	foreach my $groupId (keys %mp_groups){
		next if $except_groupId && $except_groupId eq $groupId;
		my $group = $mp_groups{$groupId};
		if( $group->{on} ){
			my $res = $bot->groupSend($groupId, $content);
			if( $res->{code} eq '901' ){
				delete $mp_groups{$groupId};
			}
		}
	}
}

sub broadmembers{
	my %mem;

	foreach my $k (keys %mp_users){
		my $m = $mp_users{$k};
		if( $m->{on} ){
			my $name = $m->{name};
			my $mapped_nick = $mp_nickmap{$m->{buddyId}};
			push(@{$mem{'Personal'}}, $mapped_nick?$mapped_nick:$name);
		}
	}
	my $num = 1;
	foreach my $k (keys %mp_groups){
		my $group = $mp_groups{$k};
		my $group_name = $group->{name};
		if( $group->{on} ){
			$group_name = 'GROUP#'.$num++ unless $group_name ;
			my @members = @{$bot->groupMembers($k)->{buddys}};
			my @names;
			foreach my $m (@members){
				my $name = $m->{name};
				my $mapped_nick = $mp_nickmap{$m->{buddyId}};
				$mp_nickmap{$m->{buddyId}} = $m->{name} unless $mapped_nick; # update nick

				push(@names, $mapped_nick?$mapped_nick:$name);
			}
			$mem{$group_name} = \@names;
		}
	}
	return %mem;
}

sub get_user{
	my $buddyId = shift;
	my $user = $mp_users{$buddyId};
	if(!$user && !$user->{buddyId}){
		my $res = $bot->buddy($buddyId);
		$user = $res->{buddys}->[0];
		$user->{on} = 1;
		$mp_users{$buddyId} = $user;
	}
	return $user;
}

sub get_group_usernick{
	my $buddyId = shift;
	my $nick = $mp_nickmap{$buddyId};
	if(!$nick){
		my $res = $bot->buddy($buddyId);
		my $user = $res->{buddys}->[0];
		$nick = $mp_nickmap{$buddyId} = $user->{name};
	}
	return $nick;
}

sub get_group{
	my $groupId = shift;
	my $buddyId = shift;
	my $usernick = get_group_usernick($buddyId);
	my $group = $mp_groups{$groupId};
	unless($group){
		$group = {on=>1,groupId=>$groupId};
		$mp_groups{$groupId} = $group;
	}
	return $group,$usernick;
}

sub gethelptext{
	my ($buddyId,$groupId,$user_group,$content) = @_;

    my $content_lc = lc($content);

	if( $content_lc eq 'start' ){
		$user_group->{on} = 1;
		return 1;
	}
	if( $content_lc eq 'stop' ){
		$user_group->{on} = 0;
		return 1;
	}
	if( $content_lc eq 'help' ){

	    my $help = "[freenode irc #perl-kr 중계봇]\nstart : 시작\nstop : 중지\nhelp : 도움말\nexit : 그룹대화 퇴장\nwho : irc/마이피플 사용자목록\nnick 닉네임 : 중계용 닉네임설정\ngroupname 그룹이름 : 중계용 그룹이름 설정";
		if( $groupId ){
			$bot->groupSend($groupId,$help);
		}
		else{
			$bot->send($buddyId,$help);
		}
		return 1;
	}
	if( $content_lc eq 'who' ){
		my %members = broadmembers();
		my @msg;
        my $out = "[Mypeople]";
		foreach my $k (keys %members){
			my @mem = @{$members{$k}};
			$out .= "$k : ".join(',',@mem)."\n" ;
		}

        if( $groupId ){
            $bot->groupSend($groupId,$out);
        }
        else{
            $bot->send($buddyId,$out);
        }

        # query IRC names
		$irc->send_srv('NAMES'=>$IRC_CHANNEL);
		push(@names_queue,[$buddyId,$groupId]);

		return 1;
	}

	if( $content =~ /^groupname/i ){

		if( $groupId && $content =~ /^groupname (.+)/i ){
			$mp_groups{$groupId}->{name} = $1;
		}
		return 1;
	}

	if( $content =~ /^nick/i ){

		if( $buddyId && $content =~ /^nick (.+)/i ){
			$mp_nickmap{$buddyId} = $1;
		}
		return 1;
	}


	if( $groupId && $content_lc eq 'exit' ){
		$bot->groupExit($groupId);
		delete $mp_groups{$groupId};
		return 1;
	}
}

sub irc_send{
	my $msg = shift;
	Encode::_utf8_off($msg) if Encode::is_utf8($msg);
	$irc->send_srv('PRIVMSG', $IRC_CHANNEL, $msg);
}

sub callback{
	my ($action, $buddyId, $groupId, $content ) = @_;
	DEBUG 'callback dump:'. p @_;
	$content = Encode::decode('utf8',$content);

	if   ( $action eq 'addBuddy' ){ # when someone add this bot as a buddy.
		# $buddyId : buddyId who adds this bot to buddys.
		# $groupId : ""
		# $content : buddy info for buddyId 
		# [
		#    {"buddyId":"XXXXXXXXXXXXXXXXXXXX","isBot":"N","name":"XXXX","photoId":"myp_pub:XXXXXX"},
		# ]
		my $user = get_user($buddyId);
	}
	elsif( $action eq 'sendFromMessage' ){ # when someone send a message to this bot.
		# $buddyId : buddyId who sends message
		# $groupId : ""
		# $content : text
		my $user = get_user($buddyId);
		my $was_cmd = process_command($buddyId, $groupId, $user, $content);

		if( !$was_cmd && $user->{on} ){
			my $username = $user->{name};
			my $mapped_nick = $mp_nickmap{$buddyId};
			my $nick = $mapped_nick?$mapped_nick:$username;
			my $msg = "[$nick] $content";
			irc_send($msg);
			broadcast($msg, $buddyId);
		}
	}
	elsif( $action eq 'createGroup' ){ # when this bot invited to a group chat channel.
		# $buddyId : buddyId who creates
		# $groupId : new group id
		# $content : members
		# [
		#    {"buddyId":"XXXXXXXXXXXXXXXXXXXX","isBot":"N","name":"XXXX","photoId":"myp_pub:XXXXXX"},
		#    {"buddyId":"XXXXXXXXXXXXXXXXXXXX","isBot":"N","name":"XXXX","photoId":"myp_pub:XXXXXX"},
		#    {"buddyId":"XXXXXXXXXXXXXXXXXXXX","isBot":"Y","name":"XXXX","photoId":"myp_pub:XXXXXX"}
		# ]
		my ($group,$usernick) = get_group($groupId, $buddyId);
	}
	elsif( $action eq 'inviteToGroup' ){ # when someone in a group chat channel invites user to the channel.
		# $buddyId : buddyId who invites member
		# $groupId : group id where new member is invited
		# $content : 
		# [
		#    {"buddyId":"XXXXXXXXXXXXXXXXXXXX","isBot":"N","name":"XXXX","photoId":"myp_pub:XXXXXX"},
		#    {"buddyId":"XXXXXXXXXXXXXXXXXXXX","isBot":"Y","name":"XXXX","photoId":"myp_pub:XXXXXX"}
		# ]
		my ($group,$usernick) = get_group($groupId, $buddyId);
	}
	elsif( $action eq 'exitFromGroup' ){ # when someone in a group chat channel leaves.
		# $buddyId : buddyId who exits
		# $groupId : group id where member exits
		# $content : ""

		my $buddy = $bot->buddy($buddyId); # hashref
		my $buddy_name = $buddy->{buddys}->[0]->{name};
		my $res = $bot->sendGroup($groupId, "I'll miss $buddy_name ...");

	}
	elsif( $action eq 'sendFromGroup'){ # when received from group chat channel
		# $buddyId : buddyId who sends message
		# $groupId : group id where message is sent
		# $content : text

		my ($group,$usernick) = get_group($groupId, $buddyId);
		my $was_cmd = process_command($buddyId, $groupId, $group, $content);

		if( !$was_cmd && $group->{on} ){
			my $groupname = $group->{name};
			my $msg = "[$usernick] $content";
			irc_send($msg);
			broadcast($msg, $buddyId, $groupId);
		}
	}
}

$irc->reg_cb (connect => sub {
	my ($con, $err) = @_;
	if (defined $err) {
		ERROR "connect error: $err";
		$cv->send;
		return;
	}
	$irc->send_srv( JOIN => $IRC_CHANNEL );
});
$irc->reg_cb (registered => sub { INFO "Connected!"; });
$irc->reg_cb (disconnect => sub { INFO "Disconnected!"; $cv->send });
$irc->reg_cb (join => sub { 
		my ($cl, $nick, $channel, $is_myself) = @_;
		if($is_myself){
			INFO "started!";
			return;
		}
		else{
			broadcast("$nick 님이 입장하셨습니다.");
		}
		
});
$irc->reg_cb (publicmsg => sub { 
	my ($self, $ch, $ircmsg) = @_;
	my ($msgnick, $msg) = parse_msg($ircmsg);
	return if $msgnick eq $IRC_NICK; # loop guard

	if( $msg =~ /^$IRC_NICK.+help$/i ){
		irc_send("$IRC_NICK - A gateway between #perl-kr and mypeople-bot.");
		irc_send("    $IRC_NICK who - prints member list in $IRC_NICK bot.");
		return;
	}

	if( $msg =~ /^$IRC_NICK.+who$/i ){
		my %members = broadmembers();
		my $printed = 0;
		foreach my $k (keys %members){
            irc_send("[MyPeople]") unless $printed;
			my @mem = @{$members{$k}};
			irc_send("$k : ".join(',',@mem));
			$printed = 1;
		}
		unless($printed){
			irc_send("Nobody is on MyPeople.");
		}
		return;
	}

	broadcast("{$msgnick} $msg");
} 
);
$irc->reg_cb(
	part => sub {
		my ($cl, $nick, $channel, $is_myself, $msg) = @_;
		unless($is_myself){
			broadcast("$nick 님이 채널을 떠났습니다.");
		}
	}
);
$irc->reg_cb(
	quit => sub {
		my ($cl, $nick, $msg) = @_;
		broadcast("$nick 님이 접속을 종료하였습니다.");
	}
);
$irc->reg_cb(
	irc_353	=> sub {
		my ($cl, $ircmsg) = @_;
		my ($_nick,$sep,$_ch,$names) = @{$ircmsg->{params}};
		my $msg = "[IRC $IRC_CHANNEL]\n$names";
		while( my $from = shift(@names_queue) )
		{
			if( $from->[1] ){
				$bot->groupSend($from->[1],$msg);
			}
			else{
				$bot->send($from->[0],$msg);
			}
		}
	}
);

start:

$irc->connect( $IRC_HOST, $IRC_PORT, {nick=>$IRC_NICK});

my $res = $cv->recv; # EVENT LOOP
$irc->disconnect;
YAML::DumpFile($datapath,\%mp_users,\%mp_groups,\%mp_nickmap);

unless ($res){ # restart
	INFO "restart";
	goto start;
}

INFO "stopped";

