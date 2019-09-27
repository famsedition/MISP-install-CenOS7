#!/bin/bash

#######################################################################
#                    MISP CENTOS7 INSTALL SCRIPT                      #
#                                                                     #
# Revised from:                                                       #
# https://misp.github.io/MISP/INSTALL.rhel7/                          #
#                                                                     #
# > Must be run as root                                               #
# > run this file after misp-preparations.sh                          #
#######################################################################


MISPvars () {
  # MISP configuration variables
  PATH_TO_MISP='/var/www/MISP'

  # The web server user
  # RHEL/CentOS
  WWW_USER='apache'
  
  read -p " set new fqdn hostname [misp.local]: " FQDN
  hostnamectl set-hostname $FQDN

  if [ -z "$MISP_BASEURL" ]; then
    MISP_BASEURL='""'
  fi

  MISP_LIVE='1'

  # Database configuration
  DBHOST='localhost'
  DBNAME='misp'
  DBUSER_ADMIN='root'
  echo "Enter password for root db admin: "
  read -s DBPASSWORD_ADMIN
  DBUSER_MISP='misp'
  echo "Enter password for misp db user: "
  read -s DBPASSWORD_MISP
  
  # OpenSSL configuration
  OPENSSL_CN=$FQDN
  read -p "openssl - Enter Country Name (2 letter code) [SN]: "  OPENSSL_C
  read -p "openssl - Enter State or Province Name [Dakar]: "  OPENSSL_ST
  read -p "openssl - Enter Locality Name (eg, city) [Dakar]: "  OPENSSL_L
  read -p "openssl - Enter Organization Name [Supersonic Cloud]: "  OPENSSL_O
  read -p "openssl - Enter Organization Unit Name [SOC]: "  OPENSSL_OU
  read -p "openssl - Enter Email Address : "  OPENSSL_EMAILADDRESS

  # GPG configuration
  GPG_REAL_NAME='Autogenerated Key'
  # On a REAL install, please do not set a comment, see here for why: https://www.debian-administration.org/users/dkg/weblog/97
  GPG_COMMENT='WARNING: MISP AutoGenerated Key consider this Key VOID!'
  GPG_EMAIL_ADDRESS='admin@admin.test'
  # 3072 bits used as per suggestions here: https://riseup.net/en/security/message-security/openpgp/best-practices
  GPG_KEY_LENGTH='3072'
  GPG_PASSPHRASE="$(openssl rand -hex 32)"


  # php.ini configuration
  upload_max_filesize=50M
  post_max_size=50M
  max_execution_time=300
  memory_limit=2048M

  CAKE="$PATH_TO_MISP/app/Console/cake"

  SUDO_WWW="sudo -H -u ${WWW_USER} "

}
MISPvars

yumInstallCoreDeps () {
  # Install the dependencies:
  yum install gcc git zip rh-git218 \
                   httpd24 \
                   mod_ssl \
                   rh-redis32 \
                   rh-mariadb102 \
                   libxslt-devel zlib-devel ssdeep-devel -y

  # Enable and start redis
  systemctl enable --now rh-redis32-redis.service

  RUN_PHP="/usr/bin/scl enable rh-php72"
  PHP_INI="/etc/opt/rh/rh-php72/php.ini"
  # Install PHP 7.2 from SCL, see https://www.softwarecollections.org/en/scls/rhscl/rh-php72/
  yum install rh-php72 rh-php72-php-fpm rh-php72-php-devel \
                   rh-php72-php-mysqlnd \
                   rh-php72-php-mbstring \
                   rh-php72-php-xml \
                   rh-php72-php-bcmath \
                   rh-php72-php-opcache \
                   rh-php72-php-gd -y

  # Install Python 3.6 from SCL, see
  # https://www.softwarecollections.org/en/scls/rhscl/rh-python36/
  RUN_PYTHON='/usr/bin/scl enable rh-python36'
  yum install rh-python36 -y

  systemctl enable --now rh-php72-php-fpm.service
}
yumInstallCoreDeps

yum install haveged -y
systemctl enable --now haveged.service

installCoreRHEL () {
  # Download MISP using git in the /var/www/ directory.
  mkdir $PATH_TO_MISP
  chown $WWW_USER:$WWW_USER $PATH_TO_MISP
  cd /var/www
  $SUDO_WWW git clone https://github.com/MISP/MISP.git
  cd $PATH_TO_MISP
  ##$SUDO_WWW git checkout tags/$(git describe --tags `git rev-list --tags --max-count=1`)
  # if the last shortcut doesn't work, specify the latest version manually
  # example: git checkout tags/v2.4.XY
  # the message regarding a "detached HEAD state" is expected behaviour
  # (you only have to create a new branch, if you want to change stuff and do a pull request for example)

  # Fetch submodules
  $SUDO_WWW git submodule update --init --recursive
  # Make git ignore filesystem permission differences for submodules
  $SUDO_WWW git submodule foreach --recursive git config core.filemode false
  # Make git ignore filesystem permission differences
  $SUDO_WWW git config core.filemode false

  # Install packaged pears
  $RUN_PHP -- pear channel-update pear.php.net
  $RUN_PHP -- pear install ${PATH_TO_MISP}/INSTALL/dependencies/Console_CommandLine/package.xml
  $RUN_PHP -- pear install ${PATH_TO_MISP}/INSTALL/dependencies/Crypt_GPG/package.xml

  # Create a python3 virtualenv
  $SUDO_WWW $RUN_PYTHON -- virtualenv -p python3 $PATH_TO_MISP/venv
  mkdir /usr/share/httpd/.cache
  chown $WWW_USER:$WWW_USER /usr/share/httpd/.cache
  $SUDO_WWW $PATH_TO_MISP/venv/bin/pip install -U pip setuptools

  cd $PATH_TO_MISP/app/files/scripts
  $SUDO_WWW git clone https://github.com/CybOXProject/python-cybox.git
  $SUDO_WWW git clone https://github.com/STIXProject/python-stix.git
  #$SUDO_WWW git clone --branch master --single-branch https://github.com/lief-project/LIEF.git lief
  $SUDO_WWW git clone https://github.com/CybOXProject/mixbox.git

  cd $PATH_TO_MISP/app/files/scripts/python-cybox
  # If you umask is has been changed from the default, it is a good idea to reset it to 0022 before installing python modules
  UMASK=$(umask)
  umask 0022
  cd $PATH_TO_MISP/app/files/scripts/python-stix
  $SUDO_WWW $PATH_TO_MISP/venv/bin/pip install .

  # install mixbox to accommodate the new STIX dependencies:
  cd $PATH_TO_MISP/app/files/scripts/mixbox
  $SUDO_WWW $PATH_TO_MISP/venv/bin/pip install .

  # install STIX2.0 library to support STIX 2.0 export:
  cd $PATH_TO_MISP/cti-python-stix2
  $SUDO_WWW $PATH_TO_MISP/venv/bin/pip install .

  # install maec
  $SUDO_WWW $PATH_TO_MISP/venv/bin/pip install -U maec

  # install zmq
  $SUDO_WWW $PATH_TO_MISP/venv/bin/pip install -U zmq

  # install redis
  $SUDO_WWW $PATH_TO_MISP/venv/bin/pip install -U redis

  # install lief
  $SUDO_WWW $PATH_TO_MISP/venv/bin/pip install -U lief
  
  # install magic, pydeep
  $SUDO_WWW $PATH_TO_MISP/venv/bin/pip install -U python-magic git+https://github.com/kbandla/pydeep.git plyara

  # install PyMISP
  cd $PATH_TO_MISP/PyMISP
  $SUDO_WWW $PATH_TO_MISP/venv/bin/pip install -U .

  # Enable python3 for php-fpm
  echo 'source scl_source enable rh-python36' | tee -a /etc/opt/rh/rh-php72/sysconfig/php-fpm
  sed -i.org -e 's/^;\(clear_env = no\)/\1/' /etc/opt/rh/rh-php72/php-fpm.d/www.conf
  systemctl restart rh-php72-php-fpm.service

  umask $UMASK

  # Enable dependencies detection in the diagnostics page
  # This allows MISP to detect GnuPG, the Python modules' versions and to read the PHP settings.
  # The LD_LIBRARY_PATH setting is needed for rh-git218 to work, one might think to install httpd24 and not just httpd ...
  echo "env[PATH] = /opt/rh/rh-git218/root/usr/bin:/opt/rh/rh-redis32/root/usr/bin:/opt/rh/rh-python36/root/usr/bin:/opt/rh/rh-php72/root/usr/bin:/usr/local/bin:/usr/bin:/bin" |tee -a /etc/opt/rh/rh-php72/php-fpm.d/www.conf
  echo "env[LD_LIBRARY_PATH] = /opt/rh/httpd24/root/usr/lib64/" |tee -a /etc/opt/rh/rh-php72/php-fpm.d/www.conf
  systemctl restart rh-php72-php-fpm.service
}
installCoreRHEL


installCake_RHEL ()
{
  chown -R $WWW_USER:$WWW_USER $PATH_TO_MISP
  mkdir /usr/share/httpd/.composer
  chown $WWW_USER:$WWW_USER /usr/share/httpd/.composer
  cd $PATH_TO_MISP/app
  # Update composer.phar (optional)
  #$SUDO_WWW $RUN_PHP -- php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
  #$SUDO_WWW $RUN_PHP -- php -r "if (hash_file('SHA384', 'composer-setup.php') === '48e3236262b34d30969dca3c37281b3b4bbe3221bda826ac6a9a62d6444cdb0dcd0615698a5cbe587c3f0fe57a54d8f5') { echo 'Installer verified'; } else { echo 'Installer corrupt'; unlink('composer-setup.php'); } echo PHP_EOL;"
  #$SUDO_WWW $RUN_PHP "php composer-setup.php"
  #$SUDO_WWW $RUN_PHP -- php -r "unlink('composer-setup.php');"
  $SUDO_WWW $RUN_PHP "php composer.phar require kamisama/cake-resque:4.1.2"
  $SUDO_WWW $RUN_PHP "php composer.phar config vendor-dir Vendor"
  $SUDO_WWW $RUN_PHP "php composer.phar install"

  ## yum install php-redis -y
  scl enable rh-php72 'pecl channel-update pecl.php.net'
  scl enable rh-php72 'yes no|pecl install redis'
  echo "extension=redis.so" |tee /etc/opt/rh/rh-php72/php-fpm.d/redis.ini
  ln -s /etc/opt/rh/rh-php72/php-fpm.d/redis.ini /etc/opt/rh/rh-php72/php.d/99-redis.ini

  # Install gnupg extension
  yum install gpgme-devel -y
  scl enable rh-php72 'pecl install gnupg'
  echo "extension=gnupg.so" |tee /etc/opt/rh/rh-php72/php-fpm.d/gnupg.ini
  ln -s /etc/opt/rh/rh-php72/php-fpm.d/gnupg.ini /etc/opt/rh/rh-php72/php.d/99-gnupg.ini
  systemctl restart rh-php72-php-fpm.service

  # If you have not yet set a timezone in php.ini
  echo 'date.timezone = "Asia/Tokyo"' |tee /etc/opt/rh/rh-php72/php-fpm.d/timezone.ini
  ln -s ../php-fpm.d/timezone.ini /etc/opt/rh/rh-php72/php.d/99-timezone.ini

  # Recommended: Change some PHP settings in /etc/opt/rh/rh-php72/php.ini
  # max_execution_time = 300
  # memory_limit = 2048M
  # upload_max_filesize = 50M
  # post_max_size = 50M
  for key in upload_max_filesize post_max_size max_execution_time max_input_time memory_limit
  do
      sed -i "s/^\($key\).*/\1 = $(eval echo \${$key})/" $PHP_INI
  done
  systemctl restart rh-php72-php-fpm.service

  # To use the scheduler worker for scheduled tasks, do the following:
  cp -fa $PATH_TO_MISP/INSTALL/setup/config.php $PATH_TO_MISP/app/Plugin/CakeResque/Config/config.php
}
installCake_RHEL


# Main function to fix permissions to something sane
permissions_RHEL () {
  chown -R $WWW_USER:$WWW_USER $PATH_TO_MISP
  ## ? chown -R root:apache /var/www/MISP
  find $PATH_TO_MISP -type d -exec chmod g=rx {} \;
  chmod -R g+r,o= $PATH_TO_MISP
  ## **Note :** For updates through the web interface to work, apache must own the /var/www/MISP folder and its subfolders as shown above, which can lead to security issues. If you do not require updates through the web interface to work, you can use the following more restrictive permissions :
  chmod -R 750 $PATH_TO_MISP
  chmod -R g+xws $PATH_TO_MISP/app/tmp
  chmod -R g+ws $PATH_TO_MISP/app/files
  chmod -R g+ws $PATH_TO_MISP/app/files/scripts/tmp
  chmod -R g+rw $PATH_TO_MISP/venv
  chmod -R g+rw $PATH_TO_MISP/.git
  chown $WWW_USER:$WWW_USER $PATH_TO_MISP/app/files
  chown $WWW_USER:$WWW_USER $PATH_TO_MISP/app/files/terms
  chown $WWW_USER:$WWW_USER $PATH_TO_MISP/app/files/scripts/tmp
  chown $WWW_USER:$WWW_USER $PATH_TO_MISP/app/Plugin/CakeResque/tmp
  chown -R $WWW_USER:$WWW_USER $PATH_TO_MISP/app/Config
  chown -R $WWW_USER:$WWW_USER $PATH_TO_MISP/app/tmp
  chown -R $WWW_USER:$WWW_USER $PATH_TO_MISP/app/webroot/img/orgs
  chown -R $WWW_USER:$WWW_USER $PATH_TO_MISP/app/webroot/img/custom
}
permissions_RHEL


prepareDB_RHEL () {
  RUN_MYSQL="/usr/bin/scl enable rh-mariadb102"
  # Enable, start and secure your mysql database server
  systemctl enable --now rh-mariadb102-mariadb.service
  echo [mysqld] |tee /etc/opt/rh/rh-mariadb102/my.cnf.d/bind-address.cnf
  echo bind-address=127.0.0.1 |tee -a /etc/opt/rh/rh-mariadb102/my.cnf.d/bind-address.cnf
  systemctl restart rh-mariadb102-mariadb

  yum install expect -y

  expect -f - <<-EOF
    set timeout 10

    spawn scl enable rh-mariadb102 mysql_secure_installation
    expect "Enter current password for root (enter for none):"
    send -- "\r"
    expect "Set root password?"
    send -- "y\r"
    expect "New password:"
    send -- "${DBPASSWORD_ADMIN}\r"
    expect "Re-enter new password:"
    send -- "${DBPASSWORD_ADMIN}\r"
    expect "Remove anonymous users?"
    send -- "y\r"
    expect "Disallow root login remotely?"
    send -- "y\r"
    expect "Remove test database and access to it?"
    send -- "y\r"
    expect "Reload privilege tables now?"
    send -- "y\r"
    expect eof
EOF

  yum remove tcl expect -y

  systemctl restart rh-mariadb102-mariadb

  scl enable rh-mariadb102 "mysql -u $DBUSER_ADMIN -p$DBPASSWORD_ADMIN -e 'CREATE DATABASE $DBNAME;'"
  scl enable rh-mariadb102 "mysql -u $DBUSER_ADMIN -p$DBPASSWORD_ADMIN -e \"GRANT USAGE on *.* to $DBUSER_MISP@localhost IDENTIFIED by '$DBPASSWORD_MISP';\""
  scl enable rh-mariadb102 "mysql -u $DBUSER_ADMIN -p$DBPASSWORD_ADMIN -e \"GRANT ALL PRIVILEGES on $DBNAME.* to '$DBUSER_MISP'@'localhost';\""
  scl enable rh-mariadb102 "mysql -u $DBUSER_ADMIN -p$DBPASSWORD_ADMIN -e 'FLUSH PRIVILEGES;'"

  $SUDO_WWW cat $PATH_TO_MISP/INSTALL/MYSQL.sql | scl enable rh-mariadb102 "mysql -u $DBUSER_MISP -p$DBPASSWORD_MISP $DBNAME"
}
prepareDB_RHEL


apacheConfig_RHEL () {
  # Now configure your apache server with the DocumentRoot $PATH_TO_MISP/app/webroot/
  # A sample vhost can be found in $PATH_TO_MISP/INSTALL/apache.misp.centos7

  cp $PATH_TO_MISP/INSTALL/apache.misp.centos7.ssl /etc/httpd/conf.d/misp.ssl.conf
  #sed -i "s/SetHandler/\#SetHandler/g" /etc/httpd/conf.d/misp.ssl.conf
  rm /etc/httpd/conf.d/ssl.conf
  chmod 644 /etc/httpd/conf.d/misp.ssl.conf
  sed -i '/Listen 80/a Listen 443' /etc/httpd/conf/httpd.conf

  # If a valid SSL certificate is not already created for the server, create a self-signed certificate:
  echo "The Common Name used below will be: ${OPENSSL_CN}"
  # This will take a rather long time, be ready. (13min on a VM, 8GB Ram, 1 core)
  if [[ ! -e "/etc/pki/tls/certs/dhparam.pem" ]]; then
    openssl dhparam -out /etc/pki/tls/certs/dhparam.pem 4096
  fi
  openssl genrsa -des3 -passout pass:xxxx -out /tmp/misp.local.key 4096
  openssl rsa -passin pass:xxxx -in /tmp/misp.local.key -out /etc/pki/tls/private/misp.local.key
  rm /tmp/misp.local.key
  openssl req -new -subj "/C=${OPENSSL_C}/ST=${OPENSSL_ST}/L=${OPENSSL_L}/O=${OPENSSL_O}/OU=${OPENSSL_OU}/CN=${OPENSSL_CN}/emailAddress=${OPENSSL_EMAILADDRESS}" -key /etc/pki/tls/private/misp.local.key -out /etc/pki/tls/certs/misp.local.csr
  openssl x509 -req -days 365 -in /etc/pki/tls/certs/misp.local.csr -signkey /etc/pki/tls/private/misp.local.key -out /etc/pki/tls/certs/misp.local.crt
  ln -s /etc/pki/tls/certs/misp.local.csr /etc/pki/tls/certs/misp-chain.crt
  cat /etc/pki/tls/certs/dhparam.pem |tee -a /etc/pki/tls/certs/misp.local.crt 

  systemctl restart httpd.service

  # Since SELinux is enabled, we need to allow httpd to write to certain directories
  chcon -t httpd_sys_rw_content_t $PATH_TO_MISP/app/files
  chcon -t httpd_sys_rw_content_t $PATH_TO_MISP/app/files/terms
  chcon -t httpd_sys_rw_content_t $PATH_TO_MISP/app/files/scripts/tmp
  chcon -t httpd_sys_rw_content_t $PATH_TO_MISP/app/Plugin/CakeResque/tmp
  chcon -t httpd_sys_script_exec_t $PATH_TO_MISP/app/Console/cake
  chcon -t httpd_sys_script_exec_t $PATH_TO_MISP/app/Console/worker/start.sh
  chcon -t httpd_sys_script_exec_t $PATH_TO_MISP/app/files/scripts/mispzmq/mispzmq.py
  chcon -t httpd_sys_script_exec_t $PATH_TO_MISP/app/files/scripts/mispzmq/mispzmqtest.py
  #chcon -t httpd_sys_script_exec_t $PATH_TO_MISP/app/files/scripts/lief/build/api/python/lief.so
  chcon -t httpd_sys_rw_content_t /tmp
  chcon -R -t usr_t $PATH_TO_MISP/venv
  chcon -R -t httpd_sys_rw_content_t $PATH_TO_MISP/.git
  chcon -R -t httpd_sys_rw_content_t $PATH_TO_MISP/app/tmp
  chcon -R -t httpd_sys_rw_content_t $PATH_TO_MISP/app/Lib
  chcon -R -t httpd_sys_rw_content_t $PATH_TO_MISP/app/Config
  chcon -R -t httpd_sys_rw_content_t $PATH_TO_MISP/app/webroot/img/orgs
  chcon -R -t httpd_sys_rw_content_t $PATH_TO_MISP/app/webroot/img/custom
  chcon -R -t httpd_sys_rw_content_t $PATH_TO_MISP/app/files/scripts/mispzmq
}
apacheConfig_RHEL


firewall_RHEL () {
  # Allow httpd to connect to the redis server and php-fpm over tcp/ip
  setsebool -P httpd_can_network_connect on

  # Allow httpd to send emails from php
  setsebool -P httpd_can_sendmail on

  # Enable and start the httpd service
  systemctl enable --now httpd.service

  # Open a hole in the iptables firewall
  firewall-cmd --zone=public --add-port=80/tcp --permanent
  firewall-cmd --zone=public --add-port=443/tcp --permanent
  firewall-cmd --reload
}
firewall_RHEL


logRotation_RHEL () {
  # MISP saves the stdout and stderr of its workers in $PATH_TO_MISP/app/tmp/logs
  # To rotate these logs install the supplied logrotate script:

  cp $PATH_TO_MISP/INSTALL/misp.logrotate /etc/logrotate.d/misp
  chmod 0640 /etc/logrotate.d/misp

  # Now make logrotate work under SELinux as well
  # Allow logrotate to modify the log files
  semanage fcontext -a -t httpd_sys_rw_content_t "/var/www/MISP(/.*)?"
  semanage fcontext -a -t httpd_log_t "$PATH_TO_MISP/app/tmp/logs(/.*)?"
  chcon -R -t httpd_log_t $PATH_TO_MISP/app/tmp/logs
  chcon -R -t httpd_sys_rw_content_t $PATH_TO_MISP/app/tmp/logs
  # Impact of the following: ?!?!?!!?111
  ##restorecon -R /var/www/MISP/

  # Allow logrotate to read /var/www
  checkmodule -M -m -o /tmp/misplogrotate.mod $PATH_TO_MISP/INSTALL/misplogrotate.te
  semodule_package -o /tmp/misplogrotate.pp -m /tmp/misplogrotate.mod
  semodule -i /tmp/misplogrotate.pp
}
logRotation_RHEL

configMISP_RHEL () {
  # There are 4 sample configuration files in $PATH_TO_MISP/app/Config that need to be copied
  $SUDO_WWW cp -a $PATH_TO_MISP/app/Config/bootstrap.default.php $PATH_TO_MISP/app/Config/bootstrap.php
  $SUDO_WWW cp -a $PATH_TO_MISP/app/Config/database.default.php $PATH_TO_MISP/app/Config/database.php
  $SUDO_WWW cp -a $PATH_TO_MISP/app/Config/core.default.php $PATH_TO_MISP/app/Config/core.php
  $SUDO_WWW cp -a $PATH_TO_MISP/app/Config/config.default.php $PATH_TO_MISP/app/Config/config.php

  echo "<?php
  class DATABASE_CONFIG {
          public \$default = array(
                  'datasource' => 'Database/Mysql',
                  //'datasource' => 'Database/Postgres',
                  'persistent' => false,
                  'host' => '$DBHOST',
                  'login' => '$DBUSER_MISP',
                  'port' => 3306, // MySQL & MariaDB
                  //'port' => 5432, // PostgreSQL
                  'password' => '$DBPASSWORD_MISP',
                  'database' => '$DBNAME',
                  'prefix' => '',
                  'encoding' => 'utf8',
          );
  }" | $SUDO_WWW tee $PATH_TO_MISP/app/Config/database.php

  # Configure the fields in the newly created files:
  # config.php   : baseurl (example: 'baseurl' => 'http://misp',) - don't use "localhost" it causes issues when browsing externally
  # core.php   : Uncomment and set the timezone: `// date_default_timezone_set('UTC');`
  # database.php : login, port, password, database
  # DATABASE_CONFIG has to be filled
  # With the default values provided in section 6, this would look like:
  # class DATABASE_CONFIG {
  #   public $default = array(
  #       'datasource' => 'Database/Mysql',
  #       'persistent' => false,
  #       'host' => 'localhost',
  #       'login' => 'misp', // grant usage on *.* to misp@localhost
  #       'port' => 3306,
  #       'password' => 'XXXXdbpasswordhereXXXXX', // identified by 'XXXXdbpasswordhereXXXXX';
  #       'database' => 'misp', // create database misp;
  #       'prefix' => '',
  #       'encoding' => 'utf8',
  #   );
  #}

  # Important! Change the salt key in $PATH_TO_MISP/app/Config/config.php
  # The admin user account will be generated on the first login, make sure that the salt is changed before you create that user
  # If you forget to do this step, and you are still dealing with a fresh installation, just alter the salt,
  # delete the user from mysql and log in again using the default admin credentials (admin@admin.test / admin)

  # If you want to be able to change configuration parameters from the webinterface:
  chown $WWW_USER:$WWW_USER $PATH_TO_MISP/app/Config/config.php
  chcon -t httpd_sys_rw_content_t $PATH_TO_MISP/app/Config/config.php

  # Generate a GPG encryption key.
  cat >/tmp/gen-key-script <<EOF
      %echo Generating a default key
      Key-Type: default
      Key-Length: $GPG_KEY_LENGTH
      Subkey-Type: default
      Name-Real: $GPG_REAL_NAME
      Name-Comment: $GPG_COMMENT
      Name-Email: $GPG_EMAIL_ADDRESS
      Expire-Date: 0
      Passphrase: $GPG_PASSPHRASE
      # Do a commit here, so that we can later print "done"
      %commit
      %echo done
EOF

  gpg --homedir $PATH_TO_MISP/.gnupg --batch --gen-key /tmp/gen-key-script
  rm -f /tmp/gen-key-script
  chown -R $WWW_USER:$WWW_USER $PATH_TO_MISP/.gnupg
  chcon -R -t httpd_sys_rw_content_t $PATH_TO_MISP/.gnupg

  # And export the public key to the webroot
  gpg --homedir $PATH_TO_MISP/.gnupg --export --armor $GPG_EMAIL_ADDRESS |tee $PATH_TO_MISP/app/webroot/gpg.asc
  chown $WWW_USER:$WWW_USER $PATH_TO_MISP/app/webroot/gpg.asc

  echo "Admin (root) DB Password: $DBPASSWORD_ADMIN"
  echo "User  (misp) DB Password: $DBPASSWORD_MISP"
}
configMISP_RHEL

configWorkersRHEL () {
  echo "[Unit]
  Description=MISP background workers
  After=rh-mariadb102-mariadb.service rh-redis32-redis.service rh-php72-php-fpm.service

  [Service]
  Type=forking
  User=apache
  Group=apache
  ExecStart=/usr/bin/scl enable rh-php72 rh-redis32 rh-mariadb102 /var/www/MISP/app/Console/worker/start.sh
  Restart=always
  RestartSec=10

  [Install]
  WantedBy=multi-user.target" |tee /etc/systemd/system/misp-workers.service

  chmod +x /var/www/MISP/app/Console/worker/start.sh
  systemctl daemon-reload

  systemctl enable --now misp-workers.service
}
configWorkersRHEL


mispmodulesRHEL () {
  # some misp-modules dependencies
  yum install openjpeg-devel gcc-c++ poppler-cpp-devel pkgconfig python-devel redhat-rpm-config -y

  chmod 2777 /usr/local/src
  chown root:users /usr/local/src
  cd /usr/local/src/
  $SUDO_WWW git clone https://github.com/MISP/misp-modules.git
  cd misp-modules
  # pip install
  $SUDO_WWW $PATH_TO_MISP/venv/bin/pip install -U -I -r REQUIREMENTS
  $SUDO_WWW $PATH_TO_MISP/venv/bin/pip install -U .
  yum install rubygem-rouge rubygem-asciidoctor zbar-devel opencv-devel -y

  echo "[Unit]
  Description=MISP modules
  After=misp-workers.service

  [Service]
  Type=simple
  User=apache
  Group=apache
  WorkingDirectory=/usr/local/src/misp-modules
  Environment="PATH=/var/www/MISP/venv/bin"
  ExecStart=\"${PATH_TO_MISP}/venv/bin/misp-modules -l 127.0.0.1 -s\"
  Restart=always
  RestartSec=10

  [Install]
  WantedBy=multi-user.target" |tee /etc/systemd/system/misp-modules.service

  systemctl daemon-reload
  # Test misp-modules
  $SUDO_WWW $PATH_TO_MISP/venv/bin/misp-modules -l 127.0.0.1 -s &
  systemctl enable --now misp-modules

  # Enable Enrichment, set better timeouts
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Enrichment_services_enable" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Enrichment_hover_enable" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Enrichment_timeout" 300
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Enrichment_hover_timeout" 150
  # TODO:"Investigate why the next one fails"
  #$SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Enrichment_asn_history_enabled" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Enrichment_cve_enabled" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Enrichment_dns_enabled" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Enrichment_btc_steroids_enabled" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Enrichment_ipasn_enabled" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Enrichment_yara_syntax_validator_enabled" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Enrichment_yara_query_enabled" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Enrichment_pdf_enabled" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Enrichment_docx_enabled" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Enrichment_xlsx_enabled" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Enrichment_pptx_enabled" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Enrichment_ods_enabled" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Enrichment_odt_enabled" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Enrichment_services_url" "http://127.0.0.1"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Enrichment_services_port" 6666

  # Enable Import modules, set better timeout
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Import_services_enable" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Import_services_url" "http://127.0.0.1"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Import_services_port" 6666
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Import_timeout" 300
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Import_ocr_enabled" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Import_mispjson_enabled" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Import_openiocimport_enabled" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Import_threatanalyzer_import_enabled" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Import_csvimport_enabled" true

  # Enable Export modules, set better timeout
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Export_services_enable" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Export_services_url" "http://127.0.0.1"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Export_services_port" 6666
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Export_timeout" 300
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Export_pdfexport_enabled" true
}
mispmodulesRHEL



coreCAKE () {
  # IF you have logged in prior to running this, it will fail but the fail is NON-blocking
  $SUDO_WWW $RUN_PHP -- $CAKE userInit -q

  # This makes sure all Database upgrades are done, without logging in.
  $SUDO_WWW $RUN_PHP -- $CAKE Admin updateDatabase

  # The default install is Python >=3.6 in a virtualenv, setting accordingly
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.python_bin" "${PATH_TO_MISP}/venv/bin/python"

  # Set default role
  # TESTME: The following seem defunct, please test.
  # $SUDO_WWW $RUN_PHP -- $CAKE setDefaultRole 3

  # Tune global time outs
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Session.autoRegenerate" 0
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Session.timeout" 600
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Session.cookieTimeout" 3600

  # Change base url, either with this CLI command or in the UI
  $SUDO_WWW $RUN_PHP -- $CAKE Baseurl $MISP_BASEURL
  # example: 'baseurl' => 'https://<your.FQDN.here>',
  # alternatively, you can leave this field empty if you would like to use relative pathing in MISP
  # 'baseurl' => '',
  # The base url of the application (in the format https://www.mymispinstance.com) as visible externally/by other MISPs.
  # MISP will encode this URL in sharing groups when including itself. If this value is not set, the baseurl is used as a fallback.
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.external_baseurl" $MISP_BASEURL

  # Enable GnuPG
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "GnuPG.email" "$GPG_EMAIL_ADDRESS"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "GnuPG.homedir" "$PATH_TO_MISP/.gnupg"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "GnuPG.password" "$GPG_PASSPHRASE"
  # FIXME: what if we have not gpg binary but a gpg2 one?
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "GnuPG.binary" "$(which gpg)"

  # Enable installer org and tune some configurables
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.host_org_id" 1
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.email" "info@admin.test"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.disable_emailing" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.contact" "info@admin.test"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.disablerestalert" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.showCorrelationsOnIndex" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.default_event_tag_collection" 0

  # Provisional Cortex tunes
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Cortex_services_enable" false
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Cortex_services_url" "http://127.0.0.1"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Cortex_services_port" 9000
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Cortex_timeout" 120
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Cortex_authkey" ""
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Cortex_ssl_verify_peer" false
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Cortex_ssl_verify_host" false
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Cortex_ssl_allow_self_signed" true

  # Various plugin sightings settings
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Sightings_policy" 0
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Sightings_anonymise" false
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.Sightings_range" 365

  # Plugin CustomAuth tuneable
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.CustomAuth_disable_logout" false

  # RPZ Plugin settings
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.RPZ_policy" "DROP"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.RPZ_walled_garden" "127.0.0.1"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.RPZ_serial" "\$date00"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.RPZ_refresh" "2h"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.RPZ_retry" "30m"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.RPZ_expiry" "30d"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.RPZ_minimum_ttl" "1h"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.RPZ_ttl" "1w"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.RPZ_ns" "localhost."
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.RPZ_ns_alt" ""
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.RPZ_email" "root.localhost"

  # Force defaults to make MISP Server Settings less RED
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.language" "eng"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.proposals_block_attributes" false

  # Redis block
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.redis_host" "127.0.0.1"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.redis_port" 6379
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.redis_database" 13
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.redis_password" ""

  # Force defaults to make MISP Server Settings less YELLOW
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.ssdeep_correlation_threshold" 40
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.extended_alert_subject" false
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.default_event_threat_level" 4
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.newUserText" "Dear new MISP user,\\n\\nWe would hereby like to welcome you to the \$org MISP community.\\n\\n Use the credentials below to log into MISP at \$misp, where you will be prompted to manually change your password to something of your own choice.\\n\\nUsername: \$username\\nPassword: \$password\\n\\nIf you have any questions, don't hesitate to contact us at: \$contact.\\n\\nBest regards,\\nYour \$org MISP support team"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.passwordResetText" "Dear MISP user,\\n\\nA password reset has been triggered for your account. Use the below provided temporary password to log into MISP at \$misp, where you will be prompted to manually change your password to something of your own choice.\\n\\nUsername: \$username\\nYour temporary password: \$password\\n\\nIf you have any questions, don't hesitate to contact us at: \$contact.\\n\\nBest regards,\\nYour \$org MISP support team"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.enableEventBlacklisting" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.enableOrgBlacklisting" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.log_client_ip" false
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.log_auth" false
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.disableUserSelfManagement" false
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.block_event_alert" false
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.block_event_alert_tag" "no-alerts=\"true\""
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.block_old_event_alert" false
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.block_old_event_alert_age" ""
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.incoming_tags_disabled_by_default" false
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.maintenance_message" "Great things are happening! MISP is undergoing maintenance, but will return shortly. You can contact the administration at \$email."
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.footermidleft" "This is an initial install"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.footermidright" "Please configure and harden accordingly"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.welcome_text_top" "Initial Install, please configure"
  # TODO: Make sure $FLAVOUR is correct
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.welcome_text_bottom" "Welcome to MISP on $FLAVOUR, change this message in MISP Settings"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.attachments_dir" "$PATH_TO_MISP/app/files"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.download_attachments_on_load" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.title_text" "MISP"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.terms_download" false
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.showorgalternate" false
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "MISP.event_view_filter_fields" "id, uuid, value, comment, type, category, Tag.name"

  # Force defaults to make MISP Server Settings less GREEN
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Security.password_policy_length" 12
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Security.password_policy_complexity" '/^((?=.*\d)|(?=.*\W+))(?![\n])(?=.*[A-Z])(?=.*[a-z]).*$|.{16,}/'

  # Set MISP Live
  $SUDO_WWW $RUN_PHP -- $CAKE Live $MISP_LIVE
}
coreCAKE

updateGOWNT () {
  # AUTH_KEY Place holder in case we need to **curl** somehing in the future
  # 
  $SUDO_WWW $RUN_MYSQL -- mysql -u $DBUSER_MISP -p$DBPASSWORD_MISP misp -e "SELECT authkey FROM users;" | tail -1 > /tmp/auth.key
  AUTH_KEY=$(cat /tmp/auth.key)
  rm /tmp/auth.key

  debug "Updating Galaxies, ObjectTemplates, Warninglists, Noticelists and Templates"
  # Update the galaxies…
  # TODO: Fix updateGalaxies
  $SUDO_WWW $RUN_PHP -- $CAKE Admin updateGalaxies
  # Updating the taxonomies…
  $SUDO_WWW $RUN_PHP -- $CAKE Admin updateTaxonomies
  # Updating the warning lists…
  $SUDO_WWW $RUN_PHP -- $CAKE Admin updateWarningLists
  # Updating the notice lists…
  $SUDO_WWW $RUN_PHP -- $CAKE Admin updateNoticeLists
  # Updating the object templates…
  $SUDO_WWW $RUN_PHP -- $CAKE Admin updateObjectTemplates "1337"
}
updateGOWNT


# Main MISP Dashboard install function
mispDashboard () {
  yum install wget screen -y
  mkdir /var/www/misp-dashboard
  chown $WWW_USER:$WWW_USER /var/www/misp-dashboard
  $SUDO_WWW git clone https://github.com/MISP/misp-dashboard.git /var/www/misp-dashboard
  cd /var/www/misp-dashboard
  sed -i -E 's/apt/#apt/' install_dependencies.sh
  sed -i -E 's/rhel/centos/' install_dependencies.sh
  sed -i -E 's/virtualenv -p python3 DASHENV/\/usr\/bin\/scl enable rh-python36 \"virtualenv -p python3 DASHENV\"/' install_dependencies.sh
  /var/www/misp-dashboard/install_dependencies.sh
  sed -i "s/^host\ =\ localhost/host\ =\ 0.0.0.0/g" /var/www/misp-dashboard/config/config.cfg
  sed -i '/Listen 80/a Listen 0.0.0.0:8001' /etc/httpd/conf/httpd.conf
  yum install rh-python36-mod_wsgi -y
  cp /opt/rh/httpd24/root/usr/lib64/httpd/modules/mod_rh-python36-wsgi.so /etc/httpd/modules/
  cp /opt/rh/httpd24/root/etc/httpd/conf.modules.d/10-rh-python36-wsgi.conf /etc/httpd/conf.modules.d/

  echo "<VirtualHost *:8001>
      ServerAdmin admin@misp.local
      ServerName misp.local
      DocumentRoot /var/www/misp-dashboard

      WSGIDaemonProcess misp-dashboard \
         user=misp group=misp \
         python-home=/var/www/misp-dashboard/DASHENV \
         processes=1 \
         threads=15 \
         maximum-requests=5000 \
         listen-backlog=100 \
         queue-timeout=45 \
         socket-timeout=60 \
         connect-timeout=15 \
         request-timeout=60 \
         inactivity-timeout=0 \
         deadlock-timeout=60 \
         graceful-timeout=15 \
         eviction-timeout=0 \
         shutdown-timeout=5 \
         send-buffer-size=0 \
         receive-buffer-size=0 \
         header-buffer-size=0 \
         response-buffer-size=0 \
         server-metrics=Off
      WSGIScriptAlias / /var/www/misp-dashboard/misp-dashboard.wsgi
      <Directory /var/www/misp-dashboard>
          WSGIProcessGroup misp-dashboard
          WSGIApplicationGroup %{GLOBAL}
          Require all granted
      </Directory>
      LogLevel info
      ErrorLog /var/log/httpd/misp-dashboard.local_error.log
      CustomLog /var/log/httpd/misp-dashboard.local_access.log combined
      ServerSignature Off
  </VirtualHost>" | tee /etc/httpd/conf.d/misp-dashboard.conf

  semanage port -a -t http_port_t -p tcp 8001
  systemctl restart httpd.service

  # Add misp-dashboard to rc.local to start on boot.
  sed -i -e '$i \-u apache bash /var/www/misp-dashboard/start_all.sh > /tmp/misp-dashboard_rc.local.log\n' /etc/rc.local

  # Enable ZeroMQ for misp-dashboard
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.ZeroMQ_enable" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.ZeroMQ_event_notifications_enable" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.ZeroMQ_object_notifications_enable" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.ZeroMQ_object_reference_notifications_enable" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.ZeroMQ_attribute_notifications_enable" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.ZeroMQ_sighting_notifications_enable" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.ZeroMQ_user_notifications_enable" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.ZeroMQ_organisation_notifications_enable" true
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.ZeroMQ_port" 50000
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.ZeroMQ_redis_host" "localhost"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.ZeroMQ_redis_port" 6379
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.ZeroMQ_redis_database" 1
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.ZeroMQ_redis_namespace" "mispq"
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.ZeroMQ_include_attachments" false
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.ZeroMQ_tag_notifications_enable" false
  $SUDO_WWW $RUN_PHP -- $CAKE Admin setSetting "Plugin.ZeroMQ_audit_notifications_enable" false
}
mispDashboard

sudo -u apache $RUN_PHP "$CAKE Admin setSetting "MISP.python_bin" "${PATH_TO_MISP}/venv/bin/python""

echo "Installation completed"
echo "Now log in using the webinterface: https://misp/users/login"
echo "The default user/pass = admin@admin.test/admin"
echo "Set MISP up to your preference in Administration -> Server Settings"