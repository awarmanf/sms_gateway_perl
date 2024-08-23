#!/usr/bin/perl -w

#
# smsgateway.pl
#
# Execution:
#   smsgateway.pl -f modem.cfg > /var/log/smsgatewayerror.log 2>&1 &
#
# We need to reset the modem because if not to do this make the modem
# fail to get the status of sms delivery.
#

use strict;
use Device::Modem;
use Device::Gsm::Pdu;
use POSIX qw(time strftime);
use DBI;
use vars qw(%opt);

# Ref http://stackoverflow.com/questions/1883318/how-can-i-add-time-information-to-stderr-output-in-perl
$SIG{__WARN__} = sub { warn sprintf("[%s] Warning: ", scalar localtime), @_ };
$SIG{__DIE__}  = sub { die  sprintf("[%s] Die: ", scalar localtime), @_ };

$|=1;

#
# Statics
#

my %smsstatus = (
  # Short message transaction completed
  '00' => 'Short message received succesfully',
  '01' => 'Short message forwarded to the mobile phone, but unable to confirm delivery',
  '02' => 'Short message replaced by the service center',
  # Temporary error, Service center still trying to transfer SMS
  '20' => 'Congestion (SMSC still trying to transfer SMS)',
  '21' => 'SME busy (SMSC still trying to transfer SMS)',
  '22' => 'No response from SME (SMSC still trying to transfer SMS)',
  '23' => 'Service rejected (SMSC still trying to transfer SMS)',
  '24' => 'Quality of service not available (SMSC still trying to transfer SMS)',
  '25' => 'Error in SME (SMSC still trying to transfer SMS)',
  # Permanent error, Service center is not making any more transfer attempts
  '40' => 'Remote procedure error (SMSC no longer to transfer SMS)',
  '41' => 'Incompatible destination (SMSC no longer to transfer SMS)',
  '42' => 'Connection rejected by SME (SMSC no longer to transfer SMS)',
  '43' => 'Not obtainable (SMSC no longer to transfer SMS)',
  '44' => 'Quality of service not available (SMSC no longer to transfer SMS)',
  '45' => 'No interworking available (SMSC no longer to transfer SMS)',
  '46' => 'SM validity period expired (SMSC no longer to transfer SMS)',
  '47' => 'SM deleted by originating SME (SMSC no longer to transfer SMS)',
  '48' => 'SM deleted by service center administration (SMSC no longer to transfer SMS)',
  '49' => 'SM does not exist (SMSC no longer to transfer SMS)',
  # Temporary error, Service center is not making any more transfer attempts
  '60' => 'Congestion (SMSC no longer to transfer SMS)',
  '61' => 'SME busy (SMSC no longer to transfer SMS)',
  '62' => 'No response from SME (SMSC no longer to transfer SMS)',
  '63' => 'Service rejected (SMSC no longer to transfer SMS)',
  '64' => 'Quality of service not available (SMSC no longer to transfer SMS)',
  '65' => 'Error in SME (SMSC no longer to transfer SMS)',
);

my %pdutype = (
  '00' => 'SMS-DELIVER',
  '01' => 'SMS-SUBMIT',
  '10' => 'SMS-STATUS-REPORT',
  '11' => 'Reserved',
);


my $maxdig = 16;    # maximum digits of phone number
my $maxchar = 160;  # maximum characters to send
# using validity 2 days make some sms couldn't get delivery status at all
my $validity = 'A7'; # (A7 for 1 day, A8 for 2 days, A9 for 3 days)
my $smscum = 0;
my $is_cmgs = 'no';
my $dayinsecond = 86400; # 1 day
my $regex = "CDS:|DS:|S:|CMT:|MT:|T:|:"; # regex for modem response
my $regex2 = "2[1-6]|[56]"; # regex for predicting of SMS-STATUS-REPORT
my $regex3 = "[,]?[0-9]"; # regex for predicting of SMS-DELIVER

my ($SERIAL, $BAUD, $TIMEOUT, $LTIMEOUT, $ELAPSED, $CHECKTIME, $SMSTORESET, $DIR, $LOG, $PID, $PREFIX, $SMSDB);
my ($modem, $atcmd);
my ($dbh,$lastID);
my $mdmAnswer;
my ($resettime, $start, $elapse, $elapsed);
my $lengthSSR = 54; # the maximum length of SMS-STATUS-REPORT approximately is 54

#
# Subs
#

# Command line options processing
sub getOptions()
{
  use Getopt::Std;
  my $opt_string = 'hf:';
  getopts( "$opt_string", \%opt ) or usage();
  usage() if (!$opt{f});
  usage() if $opt{h};
}

# AT Command
sub ATSend {
  my ($atcmd) = @_;
  $modem->atsend("$atcmd");
  return $modem->answer();
}

# Message about this program and how to use it
sub usage()
{
  print STDERR << "EOF";

Usage: $0 [-h] -f file
  -h	  : this (help) message
  -f file : configuration file

Example   : $0 -f modem.cfg

EOF
  exit;
}


# Read config
sub readConfig()
{
  if ( open (IN, $opt{f})) {
    while (<IN>)
    {
      $SERIAL = $1 if (/^modem[\s]*=[\s]*(.*)/i);
      $BAUD  = $1 if (/^baud[\s]*=[\s]*(.*)/i);
      $TIMEOUT  = $1 if (/^timeout[\s]*=[\s]*(.*)/i);
      $LTIMEOUT  = $1 if (/^longtimeout[\s]*=[\s]*(.*)/i);
      $ELAPSED  = $1 if (/^elapsed[\s]*=[\s]*(.*)/i);
      $CHECKTIME  = $1 if (/^checktime[\s]*=[\s]*(.*)/i);
      $SMSTORESET = $1 if (/^smstoreset[\s]*=[\s]*(.*)/i);
      $DIR = $1 if (/^directory[\s]*=[\s]*(.*)/i);
      $LOG = $1 if (/^log[\s]*=[\s]*(.*)/i);
      $PID = $1 if (/^pid[\s]*=[\s]*(.*)/i);
      $PREFIX = $1 if (/^prefix[\s]*=[\s]*(.*)/i);
      $SMSDB = $1 if (/^database[\s]*=[\s]*(.*)/i);
    }
    close (IN);
  } else {
    print "Can not open file $opt{f} for reading: $!\n";
    exit 1;
  }
}

sub reloadConfig()
{
  if ( open (IN, $opt{f})) {
    while (<IN>)
    {
      $TIMEOUT  = $1 if (/^timeout[\s]*=[\s]*(.*)/i);
      $LTIMEOUT  = $1 if (/^longtimeout[\s]*=[\s]*(.*)/i);
      $ELAPSED  = $1 if (/^elapsed[\s]*=[\s]*(.*)/i);
      $CHECKTIME  = $1 if (/^checktime[\s]*=[\s]*(.*)/i);
      $SMSTORESET = $1 if (/^smstoreset[\s]*=[\s]*(.*)/i);
    }
    close FLOG;
    open (FLOG,">>$LOG") || die "Can not open $LOG: $!";
    print FLOG "Reload modem configuration.\n";
    close (IN);
  } else {
    print FLOG "Can not open file $opt{f} for reading: $!\n";
    close FLOG;
    unlink $PID;
    exit 1;
  }
}

sub connectModem()
{
  $modem = new Device::Modem( port => $SERIAL);

  if( $modem->connect( baudrate => $BAUD ) ) {
      print FLOG "\nModem is connected!\n\n";
  } else {
      print FLOG "\nSorry, no connection with serial port!\n";
      close FLOG;
      unlink $PID;
      exit 1;
  }
}

sub initModem()
{
  $atcmd = "ATQ0 V1 E0 &C1 &D2 +FCLASS=0\n";
  print FLOG $atcmd . ATSend($atcmd) . "\n\n" ;
  sleep 1;

  $atcmd = "AT+IFC=2,2\n";
  print FLOG $atcmd . ATSend($atcmd) . "\n\n" ;

  $atcmd = "AT+CPIN?\n";
  print FLOG $atcmd . ATSend($atcmd) . "\n\n" ;

  $atcmd = "AT+CSQ\n";
  print FLOG $atcmd . ATSend($atcmd) . "\n\n" ;

  $atcmd = "AT+CREG?\n";
  print FLOG $atcmd . ATSend($atcmd) . "\n\n" ;

  $atcmd = "AT+CSMS=1\n";
  print FLOG $atcmd . ATSend($atcmd) . "\n\n" ;

  $atcmd = "AT+CNMI=1,2,0,1,0;+CMEE=1\n";
  print FLOG $atcmd . ATSend($atcmd) . "\n\n" ;

  $atcmd = "AT+CPMS=\"SM\"\n";
  print FLOG $atcmd . ATSend($atcmd) . "\n\n" ;

  $atcmd = "AT+CPMS?\n";
  print FLOG $atcmd . ATSend($atcmd) . "\n\n" ;

  $atcmd = "AT+CMGF=0\n";
  print FLOG $atcmd . ATSend($atcmd) . "\n\n" ;

  $atcmd = "AT+CSMP=1,167,0,0\n";
  print FLOG $atcmd . ATSend($atcmd) . "\n\n" ;
}

sub unpackTime {
  my ($hex) = @_;
  my $packed = pack('h14',$hex);
  my ($year,$month,$date,$hour,$minute,$second,$zone)=unpack('H2' x 7,$packed);
  $year+=2000;$zone=($zone*15)/60;
  #return "$year-$month-$date $hour:$minute:$second GMT+$zone";
  return "$year-$month-$date $hour:$minute:$second";
}

sub unpackAddress {
  my ($hex, $ofs) = @_;
  $ofs += 2;
  my $adrslenhex = substr ($hex, $ofs, 2);
  my $adrslen = sprintf("%d",hex($adrslenhex));
  # check if odd or even
  if ( ($adrslen % 2) > 0 )
  { $adrslen++; }
  $ofs += 2;
  my $adrstype = substr ($hex, $ofs, 2);
  $ofs += 2;
  my $addresspdu = $adrslenhex . $adrstype . substr ($hex, $ofs, $adrslen);
  my $address = Device::Gsm::Pdu::decode_address($addresspdu);
  # change the number in international format
  if ($adrstype eq '81' )
  {
    $address = substr ($address,1);
    $address = $PREFIX . $address;
  } 
  return ($address, $adrslen+$ofs);  
}

sub decodePDU {
  my ($hex,$dcs) = @_;
  # Data coding. If Bit 2=1, then it is 8 bit data, else 7 bit text.
  # Ref "SMS Application"
  if ($dcs eq "04")
  {
    # 8 bit data coding in the user data
    return ("The decoding is not available.","Alphabet 8bit");
  } elsif ($dcs eq "08") {
    # 16 bit data coding in the user data
    return ("The decoding is not available.","UCS2(16)bit");
  } else {
    # Default alphabet (7 bit data coding in the user data)
    return (Device::Gsm::Pdu::pdu_to_latin1($hex),"SMS Default Alphabet");
  }
}

sub validity {
  my ($tpvp) = @_;
  my $val;
  if ($tpvp <= 143)
  {
    # minutes
    $val = ($tpvp + 1) * 5;
    return ($val,"minutes");
  } elsif ( ($tpvp >= 144) && ($tpvp<=167))
  {
    # minutes
    $val = 12*60 + ( ($tpvp-143) * 30);
    return ($val,"minutes");
  } elsif ( ($tpvp >= 168) && ($tpvp<=196))
  {
    # day(s)
    $val = ($tpvp - 166) * 1;
    return ($val,"day(s)");
  } else {
    # $tpvp>=197 && $tpvp <=255
    # week(s)
    $val = ($tpvp - 192) * 1;
    return ($val,"week(s)");
  }
}

# save sms out before get +CMGS from modem
sub getID {
  my ($dest,$text) = @_;
  my $now = POSIX::strftime ("%Y-%m-%d %H:%M:%S", localtime);
  $text =~ s/'/''/gm;
  eval {
    $dbh->do("INSERT INTO smsout (destination,text,datetime) 
              VALUES ('$dest','$text','$now')");
    $dbh->commit( );
    return $dbh->last_insert_id("", "", "smsout", "no");
  }
}

sub smsOut {
  my ($id,$ref, $dest, $text, $is_err, $tpscts) = @_;
  $text =~ s/'/''/gm;
  eval {
    $dbh->do("UPDATE smsout 
             SET reference=$ref,destination='$dest',text='$text',
                 error='$is_err',tpscts='$tpscts' 
             WHERE no=$id");
    # when using commit AutoCommit set to 0
    $dbh->commit( );
  }
}

sub smsOutStat {
  # modification of sms.out if got a sms status report
  # it depends on ref and dest number and status which is null
  my ($ref, $dest, $status, $tpdt) = @_;
  eval {
    $dbh->do("UPDATE smsout 
              SET status='$status',tpdt='$tpdt' 
              WHERE reference=$ref AND destination='$dest' and status is null");
    $dbh->commit( );
  }
}

sub smsIn {
  my ($from,$text,$tpscts) = @_;
  # if sender using name it seldom contains null character (\x00) which can't insert to table
  $from =~ s/\x00//g;
  $text =~ s/'/''/gm;
  eval {
    $dbh->do("INSERT INTO smsin (sender, text, tpscts) 
              VALUES ('$from','$text','$tpscts')");
    # when using commit AutoCommit set to 0
    $dbh->commit( );
  }
}

sub decodeSM {
  my ($is_err,$ref,$data) = @_;
  my $ofs = 0;

  my $smsc = substr ( $data, $ofs, 2);
  my ($tprp,$tpudhi,$tpsri,$tpsrq,$tpsrr,$tprd,$reserved1,$reserved2,$tpmms,$tpmti);
  my ($tpudl,$tpud,$tppid);
  my ($pduh,$binstr);
  my ($val,$len,$temp,$coding,$msgref);
  my ($tpdcs,$tpda,$now,$sms,$period);
  my ($tpst,$tpdt,$tpvp,$tpvpf,$tpmr);
  my ($tpoa,$tpscts,$tpra);

  $ofs += 2;
  if ($smsc ne "00" ) {
    # eg. 07912618485400F9 then it contains the length of smsc
    $len = sprintf("%d",hex($smsc));
    $smsc = $smsc . substr ( $data, $ofs, $len*2);
    $ofs += $len*2;
    $smsc = Device::Gsm::Pdu::decode_address($smsc);
  }
  $pduh = substr ($data, $ofs, 2);
  # extract pdu header
  $binstr = unpack('B8',chr(hex($pduh)));
  # get tpmti only
  ($temp,$tpmti)=unpack("A6 A2" ,$binstr);
  if ($tpmti eq "00" )
  {
    # SMS-DELIVER
    ($tprp,$tpudhi,$tpsri,$reserved1,$reserved2,$tpmms)=unpack("A1 A1 A1 A1 A1 A1" ,$temp);
    ($tpoa, $ofs) = unpackAddress($data, $ofs);
    $tppid = substr ($data, $ofs, 2);
    $ofs += 2;
    $tpdcs = substr ($data, $ofs, 2);
    $ofs += 2;
    $tpscts = substr ($data, $ofs, 14);
    $ofs += 14;
    $tpudl = substr ($data, $ofs, 2);
    $ofs += 2;
    $tpud  = substr ($data, $ofs);
    ($sms,$coding) = decodePDU($tpud,$tpdcs);
    print FLOG "** Status Report **\n";
    print FLOG "PDU type   : $pdutype{$tpmti}\n";
    print FLOG "SMSC       : $smsc\n";
    print FLOG "From number: $tpoa\n";
    print FLOG "Time stamp : " . unpackTime($tpscts) . "\n";
    print FLOG "Message    : $sms\n";
    print FLOG "Data coding: $coding\n";
    print FLOG "\n";
    smsIn($tpoa,$sms,unpackTime($tpscts));
  } elsif ($tpmti eq "10" )
  {
    # SMS-STATUS REPORT
    ($reserved1,$tpsrq,$reserved2,$tpmms)=unpack("A2 A1 A2 A1" ,$temp);
    $ofs += 2;
    $tpmr = substr ($data, $ofs, 2);
    $msgref = sprintf("%d",hex($tpmr));
    ($tpra, $ofs) = unpackAddress($data, $ofs);
    $tpscts = substr ($data, $ofs, 14);
    $ofs += 14;
    $tpdt = substr ($data, $ofs, 14);
    $ofs += 14;
    $tpst = substr ($data, $ofs, 2);
    print FLOG "** Status Report **\n";
    print FLOG "Reference  : $msgref\n";
    print FLOG "PDU type   : $pdutype{$tpmti}\n";
    print FLOG "SMSC       : $smsc\n";
    print FLOG "From number: $tpra\n";
    print FLOG "Time stamp : " . unpackTime($tpscts) . "\n";
    print FLOG "Discharge  : " . unpackTime($tpdt) . "\n";
    print FLOG "Status     : $tpst ($smsstatus{$tpst})\n";
    print FLOG "\n";
    smsOutStat($msgref, $tpra, $tpst, unpackTime($tpdt));
  } else {
    # SMS-SUBMIT
    ($tprp,$tpudhi,$tpsrr,$tpvpf,$tprd)=unpack("A1 A1 A1 A2 A1" ,$temp);
    $ofs += 2;
    $tpmr = substr ($data, $ofs, 2);
    ($tpda, $ofs) = unpackAddress($data, $ofs);
    $tppid = substr ($data, $ofs, 2);
    $ofs += 2;
    $tpdcs = substr ($data, $ofs, 2);
    $ofs += 2;
    # check if vp is set
    $tpvpf = sprintf ("%d", hex($tpvpf));
    ($val,$period) = ("Not present","");
    if ($tpvpf > 0) {
      $tpvp = substr ($data, $ofs, 2);
      $ofs += 2;
      ($val,$period) = validity(hex($tpvp));
    }
    $tpudl = substr ($data, $ofs, 2);
    $ofs += 2;
    $tpud = substr ($data, $ofs);
    ($sms,$coding) = decodePDU($tpud,$tpdcs);
    $now = POSIX::strftime ("%Y-%m-%d %H:%M:%S", localtime);
    # if not get any +CMS ERROR
    if ($is_err eq " " ) {
      print FLOG "** Status Report **\n";
      print FLOG "Reference  : $ref\n";
      print FLOG "PDU type   : $pdutype{$tpmti}\n";
      print FLOG "SMSC       : $smsc\n";
      print FLOG "Recipient  : $tpda\n";
      print FLOG "Message    : $sms\n";
      print FLOG "Validity   : $val $period\n";
      print FLOG "Data coding: $coding\n";
      print FLOG "\n";
    }
    smsOut($lastID,$ref,$tpda,$sms,$is_err,$now);
  }
}

sub saveLog {
  # save unknown modem response
  my ($text) = @_;
  my $now = POSIX::strftime ("%Y-%m-%d %H:%M:%S", localtime);
  eval {
    $dbh->do("INSERT INTO log (text, datetime) 
              VALUES ('$text','$now')");
    $dbh->commit( );
  }
}

sub closeApp() {
  print FLOG "\nResetting modem done.\n";
  print FLOG "Finishing at " . POSIX::strftime ("%a, %d-%m-%Y %T %Z", localtime) . ".\n";
  close FLOG;
  $modem->reset();
  $dbh->disconnect();
  unlink $PID;
  exit;
}

sub resetModem {
  my ($string) = @_;
  print FLOG "\n$string\n";
  $modem->reset();
  sleep 3;
  connectModem();
  initModem();
  $resettime = POSIX::time();
}

sub getResponse {
  my ($pdu) = @_;
  my $mdmAnswer = $modem->answer();
  my (@val,$val);

  if ($mdmAnswer) {
    $mdmAnswer =~ s/[\r\n\s]+/ /g; 
    @val = split(/ /,$mdmAnswer);
    if ($val[0] =~ /CMGS/) {
      print FLOG "$val[0] $val[1]\n\n";
      # reference in $val[1] is decimal value
      decodeSM(' ',$val[1],$pdu);
      $is_cmgs = 'yes';
    } elsif ($val[0] =~ /CMS/) { # find error like +CMS ERROR: nnn
      print FLOG "$val[0] $val[1] $val[2]\n\n";
      decodeSM("$val[0] $val[1] $val[2]",0,$pdu);
      # sometime CMS followed by CDS
      # +CMS ERROR: 304 +CDS: 25 0006240C81802532143479510191012064825101910120158200
      # 0    1      2   3     4  5
      if ( grep(/^\+CDS:$/,@val) ) {
        print FLOG "$val[3] $val[4] $val[5]\n\n";
        decodeSM(' ',0,$val[5]);
        $atcmd = "AT+CNMA\n";
        print FLOG $atcmd . ATSend($atcmd) . "\n\n";
      }
      $is_cmgs = 'yes';
    } elsif ($val[0] =~ /^$regex/) { 
      print FLOG "$val[0] $val[1] $val[2]\n\n";
      decodeSM(' ',0,$val[2]);
      $atcmd = "AT+CNMA\n";
      print FLOG $atcmd . ATSend($atcmd) . "\n\n";

    # predicting of SMS-STATUS-REPORT
    } elsif ($val[0] =~ /^$regex2/ and defined($val[1])) { 
      print FLOG "$val[0] $val[1]\n\n";
      decodeSM(' ',0,$val[1]);
      $atcmd = "AT+CNMA\n";
      print FLOG $atcmd . ATSend($atcmd) . "\n\n";

    # predicting of SMS-DELIVER
    } elsif ($val[0] =~ /^$regex3/ and defined($val[1])) {
      print FLOG "$val[0] $val[1]\n\n";
      decodeSM(' ',0,$val[1]);
      $atcmd = "AT+CNMA\n";
      print FLOG $atcmd . ATSend($atcmd) . "\n\n";

    # predicting of SMS-STATUS-REPORT
    } elsif ($val[0] =~ /^000|^006|^002/)  {
      print FLOG $mdmAnswer; print FLOG "\n\n";

      if (length($val[0])<=$lengthSSR) {
        if ( $val[0] =~ /^00[26]/ ) {
          $val[0] = '0' . $val[0];
        }
      }
      decodeSM(' ',0,$val[0]); 
      $atcmd = "AT+CNMA\n";
      print FLOG $atcmd . ATSend($atcmd) . "\n\n" ;

    # predicting of SMS-STATUS-REPORT or SMS-DELIVER
    } elsif ($val[0] =~ /^0[1-9]/)  {
      print FLOG $mdmAnswer; print FLOG "\n\n";

      if (length($val[0])<=$lengthSSR) {
        $val[0] = '00' . $val[0];
      }
      decodeSM(' ',0,$val[0]); 
      $atcmd = "AT+CNMA\n";
      print FLOG $atcmd . ATSend($atcmd) . "\n\n" ;

    } elsif ($val[0] =~ /^[26]/)  {
      print FLOG $mdmAnswer; print FLOG "\n\n";
      if (length($val[0])<=$lengthSSR) {
        $val[0] = '000' . $val[0];
      } else {
        $val[0] = '0' . $val[0];
      }
      decodeSM(' ',0,$val[0]);
      $atcmd = "AT+CNMA\n";
      print FLOG $atcmd . ATSend($atcmd) . "\n\n";

    # there's a space before modem response
    } elsif ($val[0] eq '') {
        if ($val[1] =~ /^$regex2/ and defined($val[2])) {
          print FLOG "$val[1] $val[2]\n\n";
          decodeSM(' ',0,$val[2]);
          $atcmd = "AT+CNMA\n";
          print FLOG $atcmd . ATSend($atcmd) . "\n\n";
        }
        if ($val[1] =~ /^$regex3/ and defined($val[2])) {
          print FLOG "$val[1] $val[2]\n\n";
          decodeSM(' ',0,$val[2]);
          $atcmd = "AT+CNMA\n";
          print FLOG $atcmd . ATSend($atcmd) . "\n\n";
        }

    # log unparseable response(s) such as RING, etc
    } else {
      print FLOG $mdmAnswer; print FLOG "\n\n";
      saveLog($mdmAnswer);
    }
  }
}


#
# Main
#

getOptions();
readConfig();

# check if another smsgateway.pl is already running
if (-e $PID)
{
  print "\nsmsgateway already running\n";
  exit 1;
}

open (FLOG,">>$LOG") || die "Can not open $LOG: $!";
FLOG->autoflush(1);
print FLOG "\nSmsgateway starting at ".POSIX::strftime("%a, %d-%m-%Y %T %Z", localtime).".\n";

connectModem();
initModem();

open (OUT,">$PID") || die "Can not open $PID: $!";
print OUT $$;
close OUT;

$SIG{'INT'} =  'closeApp';
$SIG{'KILL'} = 'closeApp';
$SIG{'TERM'} = 'closeApp';
$SIG{'HUP'} = 'reloadConfig';

my $OCTS1 = '003100';
my $OCTS2 = '0000'.$validity;

$dbh = DBI->connect("dbi:SQLite:dbname=$SMSDB","","",
  {RaiseError => 1, AutoCommit => 0});

$resettime = POSIX::time(); # epoch
$elapsed = 0;

my (@hpSMS,@files,$file);
my ($dest,$encdest,$text,$enctext,$pdu,$length,$response);
while (1) {
  # check file text sms to sent every elapsed time
  if ( ($elapsed % $ELAPSED == 0) ) {
    mkdir $DIR if (! -e $DIR);
    @files = <$DIR/*>;
    foreach (@files) {
      $file = $_;
      open IN,"<$file" || die "Can not open $file: $!\n";
      @hpSMS = ();
      while (<IN>) { 
        chomp;
        push (@hpSMS, $_);
      } # while
      close IN;
      # remove file
      unlink $file;

      # sent sms
      foreach $_ (@hpSMS) { 
        if ( $_ =~ /([\+\d]+)[\s]+(.*)/) {
          $dest = $1;
          $text = $2;
          $dest =~ /.{1,$maxdig}/;
          $dest = $&;
          $text =~ /.{1,$maxchar}/;
          $text = $&;
          print FLOG "To: $dest\nSMS: $text\n\n";
          $encdest = Device::Gsm::Pdu::encode_address($dest);
          $enctext = Device::Gsm::Pdu::encode_text7($text);
          $pdu = "$OCTS1"."$encdest"."$OCTS2"."$enctext";
          $length = length ($pdu)/2 - 1;
          $atcmd = "AT+CMGS=$length\n";
          $response = ATSend($atcmd);
          print FLOG $atcmd . $response;
          $atcmd = "$pdu\cZ";
          $lastID = getID($dest,$text);
          $is_cmgs = 'no';
          $modem->atsend("$atcmd"); # we must wait for response from modem like CMGS if success
          print FLOG $atcmd . "\n\n" ;

          $start = POSIX::time(); # epoch
          $smscum++;
          if ( $smscum >= $SMSTORESET )
          {
            # waiting for modem answer after sent final sms
            while ( (POSIX::time()-$start) < $LTIMEOUT) {
              getResponse($pdu);
            }
            # reset modem
            resetModem("Resetting modem at " . POSIX::strftime ("%a, %d-%m-%Y %T %Z", localtime) . " after $smscum sms.");
            $smscum = 0;
          } else {
            do {
              while ( (POSIX::time()-$start) < $TIMEOUT) {
                getResponse($pdu);
              }
              $start = POSIX::time(); # epoch
            } until ($is_cmgs eq 'yes');
          }
        } # if
      } # foreach sent sms
    } # foreach @files
  } # if elapsed
  # modem is in waiting mode, check for modem response
  getResponse($pdu);

  $elapsed = POSIX::time() - $resettime;
  # check modem every some minutes
  if ( ($elapsed % $CHECKTIME == 0) ) {
    $atcmd = "AT+CPMS?\n";
    print FLOG $atcmd . ATSend($atcmd) . "\n\n" ;
  }
  if ( ($elapsed >= $dayinsecond) )
  {
    # reset modem
    resetModem ("Resetting modem at " . POSIX::strftime ("%a, %d-%m-%Y %T %Z", localtime) . " after " . $elapsed/60 . " minutes");
  } # if
} # while
