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
chmod 755 /usr/local/sbin/smsgateway.pl
chmod 755 /usr/local/sbin/decodeSM.pl
```

Running the service

```
/etc/init.d/smsgateway start
```

## Test sending sms

```
# /etc/init.d/smsgateway test 
Recipient : 085236006000
Text      : Testing
Sending SMS ...
```

## Reference

[SMS Gateway dengan Perl](https://awarmanf.wordpress.com/2016/08/18/sms-gateway-dengan-perl/)


