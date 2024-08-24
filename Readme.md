# SMS Gateway

The SMS Gateway is a console application running on background (init.d service) created with Perl.

## Requirement

Packages installation in Debian / Ubuntu.

```
apt-get install libdbi-perl libdbd-sqlite3-perl sqlite3 build-essential
```

Download the CPAN modules

* [Device-SerialPort-1.04.tar.gz](https://cpan.metacpan.org/authors/id/C/CO/COOK/Device-SerialPort-1.04.tar.gz)
* [Device-Modem-1.57.tar.gz](https://cpan.metacpan.org/authors/id/C/CO/COSIMO/Device-Modem-1.57.tar.gz)
* [Device-Gsm-1.61.tar.gz](https://cpan.metacpan.org/authors/id/C/CO/COSIMO/Device-Gsm-1.61.tar.gz)

Installation for CPAN module

```
tar zxf module_name.tar.gz
cd module_name
perl Makefile.PL
make
make test
make install
```

## How to use

Edit file `/usr/local/sbin/modem.cfg`

```
modem   = /dev/ttyUSB0
baud    = 115200
# timeout to wait for modem response after sending sms
timeout = 30
# longtimeout to wait for modem response after sending some sms
longtimeout = 300
# elapsed time for checking sms file(s) to sent
elapsed = 10
# check the modem every some seconds
checktime = 900
# reset modem after sending some sms
smstoreset = 30
# directory to search sms file(s) 
directory = /var/tmp/sms
# log file
log = /var/log/smsgateway.log
# pid file
pid = /var/run/smsgateway.pid
# international prefix number for indonesia
prefix = +62
# database sqlite
database = /var/log/sms.db
```

Create directory

```
mkdir /var/tmp/sms
```

Make executable

```
chmod 755 /etc/init.d/smsgateway
chmod 755 /usr/local/sbin/smsgateway.pl
chmod 755 /usr/local/sbin/decodeSM.pl
```

Running the service

```
/etc/init.d/smsgateway start
```

## Test sending sms

```
$ /etc/init.d/smsgateway test 
Recipient : 085236006000
Text      : Testing
Sending SMS ...
```

## Execution

After execution the content of `/var/log/smsgateway.log` :

```
Smsgateway starting at Fri, 07-11-2014 16:23:23 WIT.

Modem is connected!

ATQ0 V1 E0 &C1 &D2 +FCLASS=0
OK

AT+IFC=2,2
OK

AT+CPIN?
+CPIN: READY

AT+CSQ
+CSQ: 24,5

OK

AT+CREG?
+CREG: 0,1

OK

AT+CSMS=1
+CSMS: 1,1,1

OK

AT+CNMI=1,2,0,1,0;+CMEE=1
OK

AT+CPMS="SM"
+CPMS: 0,10,0,10

OK

AT+CPMS?
+CPMS: "SM",0,10,"SM",0,10

OK

AT+CMGF=0
OK

AT+CSMP=1,167,0,0
OK
```

The content of `/var/log/smsgateway.log` after sms is delivered.

```
To: 085236006000
SMS: Testing

AT+CMGS=21
> 0031000C818025630066970000A707D4F29C9E769F01

+CMGS: 54

** Status Report **
Reference  : 54
PDU type   : SMS-SUBMIT
SMSC       : 00
Recipient  : +6285236006000
Message    : Testing@
Validity   : 1440 minutes
Data coding: SMS Default Alphabet

+CDS: 25 0006360C81802563006697411170617285824111706182708200

** Status Report **
Reference  : 54
PDU type   : SMS-STATUS-REPORT
SMSC       : 00
From number: +6285236006000
Time stamp : 2014-11-07 16:27:58
Discharge  : 2014-11-07 16:28:07
Status     : 00 (Short message received succesfully)

AT+CNMA
OK
```

## How to create SMS Bulk

Create a file `contacts2sms.csv`, column 1 is contact number and column 2 is the message.

```
085236000001;Good Morning !
085236000002;How are you?
085236000003;Can you come tomorrow?
085236000004;Please, answer me
085236000005;Today is great!
```

Execute code below to create a sms bulk which saved at `/var/tmp/sms`

```bash
grep -v '^#' contacts2sms.csv | while read INFO
do
  CONTACT=`echo $INFO | cut -f1 -d';'`
  MESG=`echo $INFO | cut -f2 -d';'`
  echo $CONTACT $MESG
done > /var/tmp/sms/sms.bulk 
```

## Limitation

* Only support 160 characters to sent.
* Default alphabet is 7 bit data coding.

## Reference

[SMS Gateway dengan Perl](https://awarmanf.wordpress.com/2016/08/18/sms-gateway-dengan-perl/)

