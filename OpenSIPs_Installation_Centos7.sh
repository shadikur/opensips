#!/bin/sh

#Script Name: Complete OpenSIPs installation including GUI management
#OS Requirement: CentOS 7 - Buster x64
#Note: Please use minimal OS to use this script, otherwise, there might be port/pid conflict.
#This is custom development project by Jasdeep Bansal & Mohammad Rahman


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

#Add dependencies
verbose "Add dependencies to prepare the environment"
sleep 3
yum groupinstall core base "Development Tools" -y
yum install wget curl git nano vim 

#SNMP
apt-get install -y snmpd
echo "rocommunity public" > /etc/snmp/snmpd.conf
service snmpd restart

#install monit
verbose "Install monitoring tools"
sleep 3
printf "%s\n" "deb http://ftp.de.debian.org/debian buster-backports main" | \
sudo tee /etc/apt/sources.list.d/buster-backports.list
sudo apt update
sudo apt install -t buster-backports monit
sudo systemctl start monit
sudo systemctl status monit

MonitPass=$(date +%s | sha256sum | base64 | head -c 32 ; echo)
warning "Changing monit password to $MonitPass"
sleep 2
cat <<EOF >> /etc/monit/monitrc
set httpd port 2812 and
#     use address localhost  # only accept connection from localhost (drop if you use M/Monit)
#     allow localhost        # allow localhost to connect to the server and
    allow admin:$MonitPass      # require user 'admin' with password 'monit'
EOF


#Install OpenSIPs
verbose "Adding OpenSIPs stable LTS repository"
curl https://apt.opensips.org/pubkey.gpg | apt-key add -
echo "deb https://apt.opensips.org buster 3.2-releases" >/etc/apt/sources.list.d/opensips.list
echo "deb https://apt.opensips.org buster cli-nightly" >/etc/apt/sources.list.d/opensips-cli.list
apt update

warning "Starting installation..."
sleep 3
apt install -y opensips* opensips-cli
systemctl start opensips

#Install OpenSIPs RTPProxy Engine
verbose "Installing OpenSIPs RTPProxy Engine"
sleep 2
useradd rtpproxy
cd /usr/src
git clone -b master https://github.com/sippy/rtpproxy.git
git -C rtpproxy submodule update --init --recursive
cd rtpproxy
./configure
make clean all
make install

warning "Adding OpenSIP RTPProxy as a service"
cat <<EOF > /lib/systemd/system/rtpproxy.service
[Unit]
Description=RTPProxy media server
After=network.target
Requires=network.target

[Service]
Type=simple
PIDFile=/var/run/rtpproxy/rtpproxy.pid
Environment='OPTIONS= -f -L 4096 -l 0.0.0.0 -m 10000 -M 20000 -d INFO:LOG_LOCAL5'

Restart=always
RestartSec=5

ExecStartPre=-/bin/mkdir /var/run/rtpproxy
ExecStartPre=-/bin/chown rtpproxy:rtpproxy /var/run/rtpproxy

ExecStart=/usr/local/bin/rtpproxy -p /var/run/rtpproxy/rtpproxy.pid -s udp:127.0.0.1:22222 \
 -u rtpproxy:rtpproxy -n udp:127.0.0.1:22223 $OPTIONS

ExecStop=/usr/bin/pkill -F /var/run/rtpproxy/rtpproxy.pid

ExecStopPost=-/bin/rm -R /var/run/rtpproxy

StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=rtpproxy
SyslogFacility=local5

TimeoutStartSec=10
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF

chmod +x /lib/systemd/system/rtpproxy.service 
systemctl enable rtpproxy.service
systemctl start rtpproxy.service

#MySQL Server & PHP Installation 
verbose "MySQL Server & PHP Installation"
sleep 3
cd /tmp
apt update -y && apt -y upgrade
apt install apache2 expect mariadb-server -y && apt-get install php php-mysql php-gd php-pear php-cli php-apcu libapache2-mod-php php-curl -y
systemctl start apache2

warning "Securing mysql sever..."
sleep 2

systemctl start mysql
DBPASS=$(date +%s | sha256sum | base64 | head -c 32 ; echo)
SECURE_MYSQL=$(expect -c "
set timeout 10
spawn mysql_secure_installation
expect \"Enter current password for root (enter for none):\"
send \"$MYSQL\r\"
expect \"Change the root password?\"
send \"y\r\"
expect \"New password:\"
send  \"$DBPASS\"
expect \"Re-enter new password:\"
send \"$DBPASS\"
expect \"Remove anonymous users?\"
send \"y\r\"
expect \"Disallow root login remotely?\"
send \"y\r\"
expect \"Remove test database and access to it?\"
send \"y\r\"
expect \"Reload privilege tables now?\"
send \"y\r\"
expect eof
")
systemctl restart mysql
echo "$SECURE_MYSQL"

error "MySQL ROOT Password set to $DBPASS"

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
