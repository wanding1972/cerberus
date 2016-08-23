my $LOGLEVEL = 2;
my $TIMEOUT = 50;
my $TCP_TIMEOUT=10;
my $PROMPT = '[\#\$\>\%\]]\s*$';
my $regPass = "[Pp]assword:";
sub debug{
        my ($msg) = @_;
        my $curTime = localtime(time);
        if($LOGLEVEL<2 &&$LOGLEVEL>0){
                print $curTime.' DEBUG: '.$msg."\n";
        }
}
sub error{
        my ($msg) = @_;
        my $curTime = localtime(time);
        if($LOGLEVEL<4 &&$LOGLEVEL>0){
                print $curTime.' ERROR: '.$msg."\n";
        }
}
sub info{
        my ($msg) = @_;
        my $curTime = localtime(time);
        if($LOGLEVEL<3 &&$LOGLEVEL>0){
                print $curTime.' INFO: '.$msg."\n";
        }
}
sub execCMD{
        my ($cmd) = @_;
        debug($cmd);
        `$cmd`;
}

sub testTCPPort{
        my ($ip,$port) = @_;
        if(!defined $port ||$port eq '' ){ $port=22;}
        my $flag = 0;
        my ($dest,$sock,$con);
        debug("testtcp port $ip $port");
        $dest = sockaddr_in($port, inet_aton($ip));
        $sock = socket(SOCK,PF_INET,SOCK_STREAM,6);
        if(!$sock){ return 0;}
        eval{
                local $SIG{ALRM} = sub { die "timeout"; };
                alarm $TCP_TIMEOUT;
                $con = connect(SOCK,$dest);
                alarm 0;
        };
        if($con){              
                close SOCK;
                return 1;    
        }else{
                return 0;
        }
}

sub login{
        my ($type,$user,$passwd,$ip,$port) = @_;
                if(!defined $port || $port eq ''){
                           $port = 22; 
                }
        my $sess=new Expect;
        if($type eq 'ssh'){
                my $command = "ssh -o 'StrictHostKeyChecking no' -o ConnectTimeout=$TIMEOUT  -l $user -p $port $ip";
                debug($command);
                $sess = Expect->spawn( $command );
                        if(! $sess){
                                error("Couldn't spawn ssh,$!");
                        }
        }else{
                        $sess = Expect->spawn( "telnet $ip");
                        if(! $sess){
                                 error("Couldn't spawn telnet,$!");
                        }
                        $sess->expect($TIMEOUT,"-re","username");
                        $sess->send("$user\r");
        }
        verbose($sess,0);
        $sess->expect($TIMEOUT, [
                                qr/$regPass/i,
                                sub {
                                        $sess->send("$passwd\r");
					debug($sess->match());
					debug("send $passwd");
                                                exp_continue;
                                                                        }
                        ],
                        -re => $PROMPT
         );
        my $match=$sess->match();
        if($match !~ /[\#\$\>\%\]]/) {
                debug("failed Login ... ... ");
                return (0,$sess);
        }else{
                debug("suceed Login ... ... ");
                return (1,$sess);
        }
}

sub su{
        my ($sess,$rootPass) = @_;
        my $msg;
        $sess->send("LANG=C \r");
        $sess->send("su - \r");
        my $ret=$sess->expect($TIMEOUT,'-re',$regPass);
        if(! defined $ret) {
                $msg="su failed";
                error($msg);
                return (0,$msg);
        }
        $sess->send("$rootPass\r");
        debug("rootpass: ".$rootPass);
        $ret=$sess->expect($TIMEOUT,'-re',$PROMPT);
        my $match = $sess->match();
        if((defined $ret)&&($match =~ /#/)) {
                debug("su success... ... ");
                return (1,$sess);
        }else{
                $msg="su failed match= $match";
                error($msg);
                return (0,$msg);
        }
}

sub logout{
        my($sess) = @_;
        $sess->send(" exit\r");
        $ret=$sess->expect($TIMEOUT,'-re',$PROMPT);
        $sess->hard_close();
        debug("logout ... ... ");
}

sub rcopy{
       my($ip,$port,$user,$passwd,$src,$dst) = @_;
       my $cmd = "scp -p -o 'StrictHostKeyChecking no' -o ConnectTimeout=10 -P $port $src $user\@$ip:$dst";
       debug($cmd);
       my $scp=new Expect;
       if( ! $scp->spawn($cmd)){
             error("Cannot spawn : $!");
             return 0;
        }
        $scp->expect(20,
                        [
                                qr/$regPass/i,
                                sub {
                                                $scp->send("$passwd\r");
                                                exp_continue;
                                                                        }
                        ],
                        -re => $PROMPT
       );
        my $msg=$scp->before();
        if($msg !~ /100%/si) {
                return 0;
        }
        $scp->soft_close();
        return 1;
}

sub verbose{
        my ($sess,$flag) = @_;
        $sess->log_stdout($flag);
        $sess->raw_pty($flag);
        $sess->exp_internal( $flag );
        $sess->debug($flag);
}

sub regCron{
        my ($program) = @_;
        my $file="/tmp/crontab.cur";
        my @entrys = `crontab -l`;

        open(FILE,">$file")||die "can't open $file";
        foreach my $entry (@entrys){
                if($entry !~ /$program/){
                         print FILE $entry;
                }
        }
        print FILE "* * * * * $program >/dev/null 2>&1\n";
        close(FILE);
        `crontab $file`;
        `rm /tmp/crontab.cur`;
}

sub unregCron{
        my ($program) = @_;
        my $file="/tmp/crontab.cur";
        my @entrys = `crontab -l`;

        open(FILE,">$file")||die "can't open $file";
        foreach my $entry (@entrys){
                if($entry !~ /$program/){
                         print FILE $entry;
                }else{
                        print '-----';
                }

        }
        close(FILE);
        `crontab $file`;
        `rm /tmp/crontab.cur`;
}

sub getSrcIP{
=pod;
        my %hash = (
                'hp' => "oracle   - pts/0        Jun  8 11:27   .    12492  192.168.6.5",
                'aix' => "root        pts/0       Jun  8 11:22     (192.168.6.5)",
                'sun' => "oracle     pts/1        Jun  7 17:59    (192.168.6.5)",
                'linux' => "root     pts/137      Jun  7 15:13 (192.168.6.5)"
        );
=cut;
        my $fromIP;
        my $out = `env|grep SSH_CLIENT`;
    	chomp($out);
        if($out eq ''){
                my $os = `uname -s`;
        	chomp($os);
        	$os = lc($os);
        	my $out = `LC_ALL=C;export LC_ALL;who am i`;
        	if($os eq 'hp-ux'){
               		 $out = `LC_ALL=C;export LC_ALL;who -T`;
        	}
        	chomp($out);
        	my @tokens = split /[ \t()]+/,$out;
        	$fromIP = $tokens[5];
        	if($os eq 'hp-ux'){
                	$fromIP = $tokens[8];
        	}
        }else{
            	my @tokens = split /[ =]+/,$out;
                $fromIP = $tokens[1];
		$fromIP =~ s/::ffff://g;
        }
    return $fromIP;
}

sub lsps{
       my %ps = (
                        'aix' => 'ps -ef 2>/dev/null',
                        'hp-ux' => 'ps -efx',
                        'linux' => 'ps -auxww 2>/dev/null',
                        'sunos' => '/usr/ucb/ps -auxww'
                );
                my $os = lc(`uname -s`);
                chomp($os);

        my $cmd = $ps{$os};
        my @pslist = `$cmd`;
        return @pslist;
}

sub dupProcess{
        my ($processName) = @_;
        my @pslist = lsps();
        my $count = 0;
        foreach my $line (@pslist){
                if($line =~ /$processName/){
                        $count++;
                }
        }
        if($count>1){
                print "$processName is running\n";
                exit(-1);
        }
}

sub loginUser{
        my %cmdWho = (
                        'SunOS' => '/usr/ucb/whoami',
                        'other' => 'whoami'
        );
        my $os = lc(`uname -s`);
        chomp($os);

        my $loginUser = '';
        if($os eq 'sunos'){
                        $loginUser = `$cmdWho{$os}`;
        }else{
                        $loginUser = `$cmdWho{'other'}`;
        }
        return chomp($loginUser);
}

sub killAll{
        my ($prog) = @_;
    my @lines = lsps();
    foreach my $line (@lines){
                if($line =~ /$prog/){
                        $line=~s/^\s*|\s*$//g;
                        my @tokens = split / +/,$line;
                        $cmd = "kill -9 $tokens[1]";
                        `$cmd`;
                }
    }
}


1;
