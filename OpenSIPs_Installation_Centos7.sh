#!/bin/sh

#Script Name: Complete OpenSIPs installation including GUI management
#Description: This script will install OpenSIPs on a CentOS 7 server. This script will install all the necessary packages and will configure the server to run OpenSIPs Telephony Server. Once the script is executed, the server will be ready to run OpenSIPs Telephony Server and can be used as a SBC for Microsoft Teams.
#Author: Mohammad Rahman (Acknowledged by Jasdeep Bansal)
#OS Requirement: CentOS 7 - x86_64
#Note: Please use minimal OS to use this script, otherwise, there might be service/port/pid conflict.
#This is custom development project by Jasdeep Bansal & Mohammad Rahman for Microsoft Teams SBC.


#Color selection
verbose () {
	echo "${green}$1${normal}"
}
error () {
	echo "${red}$1${normal}"
	}
warning () {
	echo "${yellow}$1${normal}"
}

# check for color support
if test -t 1; then

    # see if it supports colors...
    ncolors=$(tput colors)

    if test -n "$ncolors" && test $ncolors -ge 8; then
        normal="$(tput sgr0)"
        red="$(tput setaf 1)"
        green="$(tput setaf 2)"
        yellow="$(tput setaf 3)"
    fi
fi


#Update to latest packages
verbose "Update installed packages"
sleep 3
yum update -y && yum upgrade -y
#Install epel-release and update
verbose "Install epel-release and update"
sleep 2
yum install epel-release -y && yum update -y


#Add dependencies
verbose "Add dependencies to prepare the environment"
sleep 3
yum groupinstall core base "Development Tools" -y
yum install wget curl git nano vim -y

#SNMP
verbose "Install SNMP"
sleep 3
yum install net-snmp-libs net-snmp-utils net-snmp-libs-devel net-snmp-devel -y
echo "rocommunity public" > /etc/snmp/snmpd.conf
systemctl enable snmpd.service
systemctl start snmpd.service

#install monit for checking system status
verbose "Install monitoring tools"
sleep 3
yum install monit -y
systemctl enable monit.service
systemctl start monit.service

#Monit Password Update
verbose "Update monit password"
sleep 2
MonitPass=$(date +%s | sha256sum | base64 | head -c 32 ; echo)
warning "Changing monit password to $MonitPass"
sleep 2
cat <<EOF >> /etc/monitrc
set httpd port 2812 and
#     use address localhost  # only accept connection from localhost (drop if you use M/Monit)
#     allow localhost        # allow localhost to connect to the server and
    allow admin:$MonitPass      # require user 'admin' with password 'monit'
EOF


#Install OpenSIPs & OpenSIPs-CLI
verbose "Install OpenSIPs & OpenSIPs-CLI"
sleep 3
warning "Starting installation..."
yum install https://yum.opensips.org/3.2/releases/el/7/x86_64/opensips-yum-releases-3.2-6.el7.noarch.rpm -y
yum install opensips opensips-cli -y
syytemctl enable opensips.service
systemctl start opensips.service

#Install OpenSIPs RTPProxy Engine
verbose "Installing OpenSIPs RTPProxy Engine"
sleep 3
yum install opensips-rtpproxy -y
systemctl enable opensips-rtpproxy.service
systemctl start opensips-rtpproxy.service


#MySQL Server & PHP Installation 
verbose "Installing MySQL Server & PHP"
sleep 3
#install PHP 7.3
yum install php73u php73u-mysqlnd php73u-xml php73u-json php73u-mbstring php73u-gd php73u-intl php73u-opcache php73u-devel php73u-pear php73u-pecl-apcu php73u-pecl-imagick php73u-pecl-memcached php73u-pecl-redis php73u-pecl-xdebug php73u-pecl-yaml php73u-pecl-zip php73u-pecl-geoip php73u-pecl-geoip-devel -y
#install MySQL Server
yum install mysql-server -y
systemctl enable mysqld.service
systemctl start mysqld.service

#Update MySQL password
verbose "Update MySQL password"
sleep 3
MySQLPass=$(date +%s | sha256sum | base64 | head -c 32 ; echo)
warning "Changing MySQL password to $MySQLPass"
sleep 2
mysqladmin -u root password $MySQLPass
mysql -u root -p$MySQLPass -e "UPDATE mysql.user SET Password=PASSWORD('$MySQLPass') WHERE User='root';"
mysql -u root -p$MySQLPass -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', 'localhost.localdomain');"
mysql -u root -p$MySQLPass -e "DELETE FROM mysql.user WHERE User='';"
mysql -u root -p$MySQLPass -e "FLUSH PRIVILEGES;"
mysql -u root -p$MySQLPass -e "CREATE USER 'opensips'@'localhost' IDENTIFIED BY '$MySQLPass';"
mysql -u root -p$MySQLPass -e "GRANT ALL PRIVILEGES ON *.* TO 'opensips'@'localhost' WITH GRANT OPTION;"
mysql -u root -p$MySQLPass -e "CREATE USER 'opensips'@'%' IDENTIFIED BY '$MySQLPass';"
mysql -u root -p$MySQLPass -e "GRANT ALL PRIVILEGES ON *.* TO 'opensips'@'%' WITH GRANT OPTION;"
mysql -u root -p$MySQLPass -e "FLUSH PRIVILEGES;"
mysql -u root -p$MySQLPass -e "CREATE DATABASE opensips DEFAULT CHARACTER SET utf8 COLLATE utf8_general_ci;"
mysql -u root -p$MySQLPass -e "GRANT ALL PRIVILEGES ON opensips.* TO 'opensips'@'localhost' IDENTIFIED BY '$MySQLPass';"
mysql -u root -p$MySQLPass -e "GRANT ALL PRIVILEGES ON opensips.* TO 'opensips'@'%' IDENTIFIED BY '$MySQLPass';"
mysql -u root -p$MySQLPass -e "FLUSH PRIVILEGES;"

warning "Securing mysql sever..."
sleep 2

error "MySQL ROOT Password set to $MySQLPass"

#Update PHP Settings
sleep 2
sed 's#post_max_size = .*#post_max_size = 80M#g' -i /etc/php/7.3/apache2/php.ini
sed 's#upload_max_filesize = .*#upload_max_filesize = 80M#g' -i /etc/php/7.3/apache2/php.ini
sed 's#;max_input_vars = .*#max_input_vars = 8000#g' -i /etc/php/7.3/apache2/php.ini


verbose "Cloning OpenSIPs GUI interface"
git -C /var/www/html/ clone https://github.com/OpenSIPS/opensips-cp.git
chown -R www-data:www-data /var/www/html/opensips-cp/
cd /var/www/html/opensips-cp/
cp config/tools/system/smonitor/opensips_stats_cron /etc/cron.d/
systemctl restart cron

#OpenSIPs CLI configuration
OpenSIPDBPass=$(date +%s | sha256sum | base64 | head -c 32 ; echo)
cat << EOF > /etc/opensips/opensips-cli.cfg
[default]
database_name=opensips
database_url=mysql://opensips:$OpenSIPDBPass@localhost
template_uri=mysql://opensips:$OpenSIPDBPass@localhost
database_admin_url=mysql://root:$DBPASS@localhost
database_modules=ALL
database_force_drop=true
EOF
opensips-cli -x database create
mysql -p$DBPASS -Dopensips < config/db_schema.mysql
sed -i "s/$config->db_pass = .*/$config->db_pass = \"$OpenSIPDBPass\";/g" /var/www/html/opensips-cp/config/db.inc.php
verbose "Installation has been completed"
ip=$(hostname -I | awk '{print $1}')
verbose "Please visit http://$ip/opensips-cp/web/ and start configuring your opensips"
warning "Default username: admin & password: opensips, Please change it immediately.\n\n"
verbose "Please keep this information in your record for further configuration"
verbose "MySQL ROOT Password: $DBPASS"
verbose	"OpenSIP DB Name: opensips, DB Username: opensips & DB Password: $OpenSIPDBPass"
verbose "Monit Username: admin and Password: $MonitPass\n\n"
error "If you face any issue on deployment or in configuration, please feel free to contact to jbansal@guidepoint.com or mrahman@guidepoint.com. Thank you.\n\n"