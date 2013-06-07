#!/usr/bin/env perl 

use strict;
use warnings;
use 5.010;
use AnyEvent;
use AnyEvent::IRC::Client;
use AnyEvent::HTTPD;
use Net::MyPeople::Bot;
use Data::Printer;

use JSON;
use YAML;
use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init($DEBUG); # you can see requests in Net::MyPeople::Bot.

start:

my $host = 'irc.freenode.net';
my $port = 8000;
my $nick = 'irc_myp';
my $ch = '#perl-kr';
my $APIKEY = $ENV{MYPEOPLE_APIKEY}; 
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

my $bot = Net::MyPeople::Bot->new({apikey=>$APIKEY});
my $irc = AnyEvent::IRC::Client->new;
my $httpd = AnyEvent::HTTPD->new (port => 8080);
$httpd->reg_cb (
	'/'=> sub{
		my ($httpd, $req) = @_;
		$req->respond( { content => ['text/html','hello'] });
	},
	'/callback' => sub {
		my ($httpd, $req) = @_;

		my $action = $req->parm('action');
		my $buddyId = $req->parm('buddyId');
		my $groupId = $req->parm('groupId');
		my $content = $req->parm('content');

		callback( $action, $buddyId, $groupId, $content );
	}
);

my %mp_users;
my %mp_groups;
my %mp_group_users;
if( -e $datapath ){
	my ($mpu, $mpg, $mpgu) = YAML::LoadFile($datapath);
	%mp_users = %{$mpu};
	%mp_groups= %{$mpg};
	%mp_group_users = %{$mpgu};
}


sub gethelptext{
	return "[freenode irc #perl-kr 중계봇]\nstart : 시작\nstop : 중지\nhelp : 도움말\nexit : 그룹대화 퇴장\nbot : 전체 중계봇 사용자목록\nirc : irc사용자목록";
}
sub broadcast{
	my $content = shift;
	my ($except_buddyId,$except_groupId) = @_;
	foreach my $buddyId (keys %mp_users){
		next if $except_buddyId && $except_buddyId eq $buddyId;
		my $user = $mp_users{$buddyId};
		if( $user->{on} ){
			$bot->send($buddyId,$content);
		}
	}
	foreach my $groupId (keys %mp_groups){
		next if $except_groupId && $except_groupId eq $groupId;
		my $group = $mp_groups{$groupId};
		if( $group->{on} ){
			$bot->groupSend($groupId, $content);
		}
	}
}

sub broadmembers{
	my %mem;

	foreach my $k (keys %mp_users){
		my $user = $mp_users{$k};
		if( $user->{on} ){
			push(@{$mem{personal}},$user->{name});
		}
	}
	my $num = 1;
	foreach my $k (keys %mp_groups){
		my $group = $mp_groups{$k};
		if( $group->{on} ){
			my @members = @{$bot->groupMembers($k)->{buddys}};
			$mem{"group_$num"} = [map{$_->{name};}@members];
		}		
	}
	p %mem;
	return %mem;
}

sub get_user{
	my $buddyId = shift;
	my $user = $mp_users{$buddyId};
	unless($user){
		my $res = $bot->buddy($buddyId);
		$user = $res->{buddys}->[0];
		$user->{on} = 1;
		$mp_users{$buddyId} = $user;
	}
	return $user;
}
sub get_group_user{
	my $buddyId = shift;
	my $user = $mp_group_users{$buddyId};
	unless($user){
		my $res = $bot->buddy($buddyId);
		$user = $res->{buddys}->[0];
		$mp_group_users{$buddyId} = $user;
	}
	return $user;
}
sub get_group{
	my $groupId = shift;
	my $buddyId = shift;
	my $user = get_group_user($buddyId);
	my $group = $mp_groups{$groupId};
	unless($group){
		$group = {on=>1,groupId=>$groupId};
		$mp_groups{$groupId} = $group;
	}
	return $group,$user;
}

sub process_command{
	my ($buddyId,$groupId,$user_group,$content) = @_;
	if( $content eq 'start' ){
		$user_group->{on} = 1;
		return 1;
	}
	if( $content eq 'stop' ){
		$user_group->{on} = 0;
		return 1;
	}
	if( $content eq 'help' ){
		if( $groupId ){
			$bot->groupSend($groupId,gethelptext());
		}
		else{
			$bot->send($buddyId,gethelptext());
		}
		return 1;
	}
	if( $content eq 'bot' ){
		my %members = broadmembers();
		my @msg;
		foreach my $k (keys %members){
			my @mem = @{$members{$k}};
			push( @msg, "$k member : ".join(',',@mem) );
		}

		foreach my $msg (@msg){
			if( $groupId ){
				$bot->groupSend($groupId,$msg);
			}
			else{
				$bot->send($buddyId,$msg);
			}
		}

		return 1;
	}

	if( $content eq 'irc' ){
		DEBUG 'irc command';
		$irc->send_srv('NAMES'=>$ch);
		push(@names_queue,[$buddyId,$groupId]);
		return 1;
	}

	if( $groupId && $content eq 'exit' ){
		$bot->groupExit($groupId);
		return 1;
	}
}

sub callback{
	my ($action, $buddyId, $groupId, $content ) = @_;
	p @_;

	if   ( $action eq 'addBuddy' ){ # when someone add this bot as a buddy.
		# $buddyId : buddyId who adds this bot to buddys.
		# $groupId : ""
		# $content : buddy info for buddyId 
		# [
		#    {"buddyId":"XXXXXXXXXXXXXXXXXXXX","isBot":"N","name":"XXXX","photoId":"myp_pub:XXXXXX"},
		# ]
	}
	elsif( $action eq 'sendFromMessage' ){ # when someone send a message to this bot.
		# $buddyId : buddyId who sends message
		# $groupId : ""
		# $content : text
		my $user = get_user($buddyId);
		my $was_cmd = process_command($buddyId, $groupId, $user, $content);

		if( !$was_cmd && $user->{on} ){
			my $username = $user->{name};
			my $msg = "[$username] $content";
			$irc->send_srv('PRIVMSG', $ch, $msg);
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
	}
	elsif( $action eq 'inviteToGroup' ){ # when someone in a group chat channel invites user to the channel.
		# $buddyId : buddyId who invites member
		# $groupId : group id where new member is invited
		# $content : 
		# [
		#    {"buddyId":"XXXXXXXXXXXXXXXXXXXX","isBot":"N","name":"XXXX","photoId":"myp_pub:XXXXXX"},
		#    {"buddyId":"XXXXXXXXXXXXXXXXXXXX","isBot":"Y","name":"XXXX","photoId":"myp_pub:XXXXXX"}
		# ]
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

		my ($group,$user) = get_group($groupId, $buddyId);
		my $was_cmd = process_command($buddyId, $groupId, $group, $content);

		if( !$was_cmd && $group->{on} ){
			my $username = $user->{name};
			my $msg = "[$username] $content";
			$irc->send_srv('PRIVMSG', $ch, $msg);
			broadcast($msg, $buddyId, $groupId);
		}
	}
}

$irc->reg_cb (connect => sub {
	my ($con, $err) = @_;
	if (defined $err) {
		DEBUG "connect error: $err";
		$cv->send;
		return;
	}
	#$irc->send_srv( JOIN => '#perl-kr' );
	$irc->send_srv( JOIN => $ch );
});
$irc->reg_cb (registered => sub { DEBUG "I'm in!"; });
$irc->reg_cb (disconnect => sub { DEBUG "I'm out!"; $cv->send });
$irc->reg_cb (join => sub { 
		my ($cl, $nick, $channel, $is_myself) = @_;
		if($is_myself){
			DEBUG "started";
			return;
		}
		else{
			broadcast("$nick 님이 입장하셨습니다.");
		}
		
});
$irc->reg_cb (privatemsg => sub { 
	my ($self, $nick, $ircmsg) = @_;
	DEBUG p $nick;
	DEBUG p $ircmsg;
});
$irc->reg_cb (publicmsg => sub { 
	my ($self, $ch, $ircmsg) = @_;
	my ($msgnick, $msg) = parse_msg($ircmsg);
	return if $msgnick eq $nick; # loop guard

	if( $msg =~ /^$nick.+help$/ ){
		$irc->send_srv('PRIVMSG', $ch, "$nick - A gateway between #perl-kr and mypeople-bot.");
		$irc->send_srv('PRIVMSG', $ch, "$nick bot : prints member list in $nick bot.");
		return;
	}
	if( $msg =~ /^$nick.+bot$/ ){
		my %members = broadmembers();
		foreach my $k (keys %members){
			my @mem = @{$members{$k}};
			$irc->send_srv('PRIVMSG', $ch, "MyPeople $k : ".join(',',@mem));
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
		my $msg = "IRC $ch : $names";
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

$irc->connect( $host, $port, {nick=>$nick});

my $res = $cv->recv; # EVENT LOOP

goto start unless $res;

$irc->disconnect;
YAML::DumpFile($datapath,\%mp_users,\%mp_groups,\%mp_group_users);
say "stopped";

