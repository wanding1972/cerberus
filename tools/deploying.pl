#!/usr/bin/perl
use strict;
use warnings;
use Expect;
use Socket;
use DBI;
use File::Spec;
use MIME::Base64;
my $path_curf = File::Spec->rel2abs(__FILE__);
my ($vol, $path, $file) = File::Spec->splitpath($path_curf);
require "$path/deploy/min_funcs.pl";
require "$path/fileLoad.pl";

#deploy.pl node ip user pass port rootPass proxy
if(scalar @ARGV<2){
	print "Usage: deploying.pl prog|unprog|check sitecode [ip] [noforce]\n";
	exit 0;
}
my $action = $ARGV[0];

my $PROMPT = '[\#\$\>\%\]]\s*$';
my $regPass = "[Pp]assword:|��:|����";
my $sess;
our %hostInfos = (
 #	'NOD010-192.168.0.3' => ['view','s7!','root',22,'direct']
);

our %hostProxy = ( 
 #       node=>ip
);
my %hostDirect = ();
my %hostIndirect = ();
loadHost();
my %installed = loadInstalledHost();

my $count = 0;
foreach my $key (keys %hostProxy){
	if(defined $ARGV[3] && $ARGV[3] eq 'noforce'){
		next if(exists $installed{$key});
	}
	my $key1= "$key-$hostProxy{$key}";
	$hostDirect{$key1} = $hostInfos{$key1};	
}
foreach my $key (keys %hostInfos){
	next if(exists $hostDirect{$key});
	if(defined $ARGV[3] && $ARGV[3] eq 'noforce'){
		next if(exists $installed{$key});
	}
	my($node,$ip) = split /-/,$key;
	my $isDirect = $hostInfos{$key}->[4];
	if($isDirect eq 'direct'){
		$hostDirect{$key} = $hostInfos{$key};	
	}else{
		next if(! exists $hostProxy{$node});
        	$hostIndirect{$key} = $hostInfos{$key};
	}
	$count++;
}
info("host number: $count");
makePack();

if($action eq 'check'){
	doMulti(\%hostDirect,1);
	doMulti(\%hostIndirect,0);
}elsif($action eq 'unprog'){
	doMulti(\%hostIndirect,0);
	doMulti(\%hostDirect,1);
}elsif($action eq 'prog'){
	doMulti(\%hostDirect,1);
	doMulti(\%hostIndirect,0);
}

`rm $path/deploy/min_agent.tar`;

# parallel deploy
sub doMulti{
        my($hostsRef,$direct)=@_;
        my %hosts = %$hostsRef;
        my $MAXPROC=10;                 
        my $procNum = 0;              
        my @pids = ();

        foreach my $key (keys %hosts){
                my $host = $hosts{$key};
                my ($node,$ip) = split/-/,$key;
                my $pid = fork();
                if($pid == 0){          
                        doWork($node,$ip,$direct);
                        exit 0;
                }else{         
                        $procNum++;
                        push(@pids,$pid);
                }
                if($procNum >= $MAXPROC ){
                        foreach my $pid (@pids){
                             waitpid($pid,0);
                        }
                        $procNum = 0;
                        @pids = ();
                }
        }
        foreach my $pid (@pids){
                   waitpid($pid,0);
        }
}


#return value:
#0,  can not connect ssh Port
#1,  connected
#2   loginUser,

sub doWork{
        my ($node,$ip,$connected) = @_;
        my $ret = 0;
	my $user = $hostInfos{"$node-$ip"}->[0];
	my $pass = $hostInfos{"$node-$ip"}->[1];
	my $rootPass = $hostInfos{"$node-$ip"}->[2];
	my $port = $hostInfos{"$node-$ip"}->[3];
	my $start = time();
	if($connected == 0){   # indirect 
		if(exists $hostProxy{$node}){
			$ret = deployIndirect($node,$ip,$port,$user,$pass,$rootPass);
		}
	}else{                 
		$ret = deployDirect($node,$ip);
	}
	my $ela = (time()-$start).' seconds';
	my $stat;
	if($ret==0){
        	$stat='disconnect';
	}elsif($ret==1){
		$stat='connected';
	}elsif($ret==2){
		$stat='userlogin';
	}elsif($ret==3){
		$stat='rootlogin';
	}elsif($ret==4){
		$stat='installed';
	}elsif($ret==5){
		$stat='checked';
	}
	$pass = decode_base64($pass);
	#updateDeploy($stat,$node,$ip);
	print "($stat,$node,$ip) \n";
        return $ret;
}


sub deployDirect{
	my ($node,$ip) = @_;
	my $retDeploy = 0;
	my $user = $hostInfos{"$node-$ip"}->[0];
	my $pass = $hostInfos{"$node-$ip"}->[1];
	my $rootPass = $hostInfos{"$node-$ip"}->[2];
	my $port = $hostInfos{"$node-$ip"}->[3];
	my $cmd = "";
	if(exists $hostProxy{$node} && $ip eq $hostProxy{$node} && $action ne 'prog'){
		# deploy the program on the proxy when check or unprog
		$cmd = "$path/deploy/min_deploy.pl prog $ip $user '$pass' $node '$rootPass' PROXY";
		execCMD($cmd);
	}
	if(exists $hostProxy{$node}){
		$cmd = "$path/deploy/min_deploy.pl $action $ip:$port $user '$pass' $node '$rootPass' PROXY";
	}else{
		$cmd = "$path/deploy/min_deploy.pl $action $ip:$port $user '$pass' $node '$rootPass' DIRECT";
	}
	info($cmd);
	my @lines = execCMD($cmd);    
	foreach my $line (@lines){
		if($line =~ /return value=(\d)/){
			$retDeploy = $1;
			last;
		}
	}
	return $retDeploy;
}

sub deployIndirect{
        my ($node,$host,$port,$user,$passwd,$rootPass) = @_;
        my ($sess,$sessTmp,$ret);
	my $retVal = 0;
        debug("deployIndirect: $node $host,$port,$user,$passwd,$rootPass");
	my $ipProxy = $hostProxy{$node};
        my $userProxy = $hostInfos{"$node-$ipProxy"}->[0];
        my $passProxy = $hostInfos{"$node-$ipProxy"}->[1];
	$passProxy = decode_base64($passProxy);
        my $portProxy = $hostInfos{"$node-$ipProxy"}->[3];
	#Login
	($ret,$sess) = login('ssh',$userProxy,$passProxy,$ipProxy,$portProxy);
	if($ret == 0){
		return 0;
	}
	my $cmd = "/tmp/min_deploy.pl $action $host:$port $user '$passwd' $node '$rootPass'";
	$sess->send("$cmd\r"); 
	info("$ipProxy: $cmd");
       	$sess->expect(30,'-re','return value.+$');
	my $out = $sess->match();
       	logout($sess);
	if($out =~ /return value=(\d)/){
		$retVal = $1;
	}else{
		$retVal = 0;
	}
        return $retVal;
}

sub loadInstalledHost{
	my %hash = ();
	if(open(FILE,"$path/../data/host.status")){
		my @lines = <FILE>;
		foreach my $line (@lines){
			chomp($line);
			my (@tokens) = split /,/,$line;
			my ($node,$ip,$installed,$version) = ($tokens[0],$tokens[1],$tokens[2],$tokens[3]);
			if($installed eq 'ONLINE' && $version == 32){
				$hash{"$node-$ip"} = 1;
			}
		}
		close(FILE);
	}
	return %hash;
}

sub makePack{
	chdir("$path/..");
	`tar cvf min_agent.tar agent`;
	`mv min_agent.tar $path/deploy/`;
}