#!/usr/bin/perl -w

use strict;
use Device::Modem;
use Device::Gsm::Pdu;
use POSIX qw(time strftime);
use DBI;
use vars qw(%opt);

# Ref http://stackoverflow.com/questions/1883318/how-can-i-add-time-information-to-stderr-output-in-perl
$SIG{__WARN__} = sub { warn sprintf("[%s] ", scalar localtime), @_ };
$SIG{__DIE__}  = sub { die  sprintf("[%s] ", scalar localtime), @_ };

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


my $maxdig = 14;    # maximum digits of phone number
my $maxchar = 160;  # maximum characters to send
my $validity = 'A7'; # (A7 for 1 day, A9 for 3 days)
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
my $lengthSSR = 53; # the maximum length of SMS-STATUS-REPORT is approximately 53


sub getOptions()
{
  use Getopt::Std;
  my $opt_string = 'sa:';
  getopts( "$opt_string", \%opt ) or usage();
  usage() if (!$opt{a});
}

sub usage()
{
  print STDERR << "EOF";

Usage: $0 [-s] -a decode_message
  -s  : save the result to sms.db

Example   : $0 -a 0006190C81803181097687718011128100827180217014008200

EOF
  exit;
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
    print "** Status Report **\n";
    print "PDU type   : $pdutype{$tpmti}\n";
    print "SMSC       : $smsc\n";
    print "From number: $tpoa\n";
    print "Time stamp : " . unpackTime($tpscts) . "\n";
    print "Message    : $sms\n";
    print "Data coding: $coding\n";
    print "\n";
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
    print "** Status Report **\n";
    print "Reference  : $msgref\n";
    print "PDU type   : $pdutype{$tpmti}\n";
    print "SMSC       : $smsc\n";
    print "From number: $tpra\n";
    print "Time stamp : " . unpackTime($tpscts) . "\n";
    print "Discharge  : " . unpackTime($tpdt) . "\n";
    print "Status     : $tpst ($smsstatus{$tpst})\n";
    print "\n";
    if ($opt{s}) {
      smsOutStat($msgref, $tpra, $tpst, unpackTime($tpdt));
    }
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
      print "** Status Report **\n";
      print "Reference  : $ref\n";
      print "PDU type   : $pdutype{$tpmti}\n";
      print "SMSC       : $smsc\n";
      print "Recipient  : $tpda\n";
      print "Message    : $sms\n";
      print "Validity   : $val $period\n";
      print "Data coding: $coding\n";
      print "\n";
    }
    if ($opt{s}) {
      smsOut($lastID,$ref,$tpda,$sms,$is_err,$now);
    }
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


$SMSDB  = '/var/log/sms.db';
$PREFIX = '+62';

$dbh = DBI->connect("dbi:SQLite:dbname=$SMSDB","","",{RaiseError => 1, AutoCommit => 0});

getOptions();

my $val = $opt{a};

#decodeSM(' ',0,$val);

$mdmAnswer = $val;
my @val; 

if ($mdmAnswer) {
  $mdmAnswer =~ s/[\r\n\s]+/ /g; 
  @val = split(/ /,$mdmAnswer);

  if ($val[0] =~ /^$regex/) { 
    print "$val[0] $val[1] $val[2]\n\n";
    decodeSM(' ',0,$val[2]);

  # predicting of SMS-STATUS-REPORT
  } elsif ($val[0] =~ /^$regex2/ and defined($val[1])) { 
    print "$val[0] $val[1]\n\n";
    decodeSM(' ',0,$val[1]);

  # predicting of SMS-DELIVER
  } elsif ($val[0] =~ /^$regex3/ and defined($val[1])) { 
    print "$val[0] $val[1]\n\n";
    decodeSM(' ',0,$val[1]);

  # predicting of SMS-STATUS-REPORT
  } elsif ($val[0] =~ /^000|^006|^002/)  {
    print $mdmAnswer; print "\n\n";

    if (length($val[0])<=$lengthSSR) {
      if ( $val[0] =~ /^00[26]/ ) {
        $val[0] = '0' . $val[0];
      }
    }
    decodeSM(' ',0,$val[0]); 

  # predicting of SMS-STATUS-REPORT or SMS-DELIVER
  } elsif ($val[0] =~ /^0[1-9]/)  {
    print $mdmAnswer; print "\n\n";

    if (length($val[0])<=$lengthSSR) {
      $val[0] = '00' . $val[0];
    }
    decodeSM(' ',0,$val[0]); 

  } elsif ($val[0] =~ /^[26]/)  {
    print $mdmAnswer; print "\n\n";

    if (length($val[0])<=$lengthSSR) {
      $val[0] = '000' . $val[0];
    }  else {
      $val[0] = '0' . $val[0];
    }
    decodeSM(' ',0,$val[0]);

  } elsif ($val[0] eq '') {
      if ($val[1] =~ /^$regex2/ and defined($val[2])) { 
        print "$val[1] $val[2]\n\n";
        decodeSM(' ',0,$val[2]);
      }
      if ($val[1] =~ /^$regex3/ and defined($val[2])) { 
        print "$val[1] $val[2]\n\n";
        decodeSM(' ',0,$val[2]);
      }

  } else {
    print "val0:$val[0]::val1:$val[1]::val2:$val[2]\n";
    # unknown response(s)
    print "$mdmAnswer\n\n";
    if ($opt{s}) {
     print "save to log\n";
     saveLog($mdmAnswer);
    }
  }
}
