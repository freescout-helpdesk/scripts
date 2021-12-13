#!/bin/bash

# This will install everything required to run a basic FreeScout installation.
# This should be run on a clean Ubuntu server.

install_path='/var/www/html'
server_ip=`ip -o addr list | awk '{print $4}' | cut -d/ -f1 | grep -v '127.0.0.1' | grep -v '::1'`

printf "
########################################
## FreeScout Interactive Installation ##
########################################

Installation script will do the following:
- Install Nginx
- Install MySQL 5
- Install PHP 7.4
- Install the latest version of the FreeScout
- Configure HTTPS (if needed)
- Set up a cron task

Make sure you have a domain name pointed to one or multiple of your server IP addresses: 
$server_ip

You will be able to specify help desk domain name and choose installation directory.

Would you like to start installation? (Y/n) [n]:"
read confirm_start;
if [ $confirm_start != "Y" ]; then
    exit;
fi

#
# Domain
# 
printf "\nEnter help desk domain name (without 'www'): "
read domain_name;
if [ -z "$domain_name" ]; then
	echo "Domain name is required. Terminating installation"
    exit;
fi

mysql_pass=`date +%s | sha256sum | base64 | head -c 9 ; echo`

#
# Dependencies
#
echo "Installing dependencies..."
sudo apt update
export DEBIAN_FRONTEND=noninteractive

sudo apt remove apache2
sudo apt install git nginx mysql-server libmysqlclient-dev php7.4 php7.4-mysqli php7.4-fpm php7.4-mbstring php7.4-xml php7.4-imap php7.4-zip php7.4-gd php7.4-curl
# json extension may be already included in php7.4-fpm
sudo apt install php7.4-json

#
# MySQL
#
echo "Configuring MySQL..."
echo 'CREATE DATABASE `freescout` CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci;' | mysql -u root
echo 'REVOKE ALL PRIVILEGES, GRANT OPTION FROM `freescout`@`localhost`;' | mysql -u root
echo 'GRANT ALL PRIVILEGES ON `freescout`.* TO `freescout`@`localhost` IDENTIFIED BY "'"$mysql_pass"'";' | mysql -u root
# new syntax 
echo 'CREATE USER `freescout`@`localhost` IDENTIFIED BY "'"$mysql_pass"'";' | mysql -u root
echo 'GRANT ALL ON `freescout`.* TO `freescout`@`localhost`;' | mysql -u root
echo "You may see a MySQL privileges error above. Don't worry - the script executes two different commands for different DB versions and one of them always fails - just continue the installation."

#
# Application Setup
#
printf "\nWhere would you like to install FreeScout? [$install_path]:"
read confirm_path;
if [ ! -z "$confirm_path" ]; then
    install_path=`echo $confirm_path | sed 's:/*$::'`;
fi


if [ -f "$install_path" ]; then
	echo "$install_path is not a directory. Terminating installation"
	exit;
fi

if [ -d "$install_path" ]; then
    install_path_check=`sudo ls -1qA $install_path`

	if [ ! -z "$install_path_check" ]; then
		printf "All files in $install_path will be removed. Continue? (Y/n) [n]:"
		read confirm_clean;
		if [ $confirm_clean != "Y" ]; then
		    exit;
		fi
	    sudo rm -rf $install_path
	fi
fi

sudo mkdir -p $install_path
sudo chown www-data:www-data $install_path
sudo git clone https://github.com/freescout-helpdesk/freescout $install_path
sudo chown -R www-data:www-data $install_path
sudo find $install_path -type f -exec chmod 664 {} \;    
sudo find $install_path -type d -exec chmod 775 {} \;

if [ ! -f "$install_path/artisan" ]; then
	echo "Error occured installing FreeScout into $install_path. Terminating installation"
	exit;
fi
echo "Application installed"

#
# Nginx
#
echo "Configuring nginx..."
sudo echo 'server {
    listen 80;
    listen [::]:80;

    server_name '"$domain_name"';

    root '"$install_path"'/public;

    index index.php index.html index.htm;

    error_log '"$install_path"'/storage/logs/web-server.log;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }
    location ~ \.php$ {
		fastcgi_split_path_info ^(.+\.php)(/.+)$;
		fastcgi_pass unix:/run/php/php7.4-fpm.sock;
		fastcgi_index index.php;
		fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
		include fastcgi_params;
    }
    # Uncomment this location if you want to improve attachments downloading speed.
    # Also make sure to set APP_DOWNLOAD_ATTACHMENTS_VIA=nginx in the .env file.
    #location ^~ /storage/app/attachment/ {
    #    internal;
    #    alias '"$install_path"'/storage/app/attachment/;
    #}
    location ~* ^/storage/attachment/ {
        expires 1M;
        access_log off;
        try_files $uri $uri/ /index.php?$query_string;
    }
    location ~* ^/(?:css|js)/.*\.(?:css|js)$ {
        expires 2d;
        access_log off;
        add_header Cache-Control "public, must-revalidate";
    }
    location ~* ^/(?:css|fonts|img|installer|js|modules|[^\\\]+\..*)$ {
        expires 1M;
        access_log off;
        add_header Cache-Control "public";
    }
    location ~ /\. {
        deny  all;
    }
}' > /etc/nginx/sites-available/$domain_name

if [ -f "/etc/nginx/sites-enabled/default" ]; then
	sudo rm -f /etc/nginx/sites-enabled/default
fi

if [ -f "/etc/nginx/sites-enabled/$domain_name" ]; then
	sudo rm -f "/etc/nginx/sites-enabled/$domain_name" 
fi
sudo ln -s "/etc/nginx/sites-available/$domain_name" "/etc/nginx/sites-enabled/$domain_name"

nginx_test=`sudo nginx -t 2>&1; echo $?`
if [[ ! $nginx_test == *"test is successful"* ]]; then
	echo "Nginx configuration error. Terminating installation"
	sudo nginx -t
	exit;
fi

sudo service nginx reload

#
# HTTPS
# 
printf "\nWould you like to enable HTTPS? It is free and required for browser push notifications to work. (Y/n) [n]:"
read confirm_https;
if [ $confirm_https = "Y" ]; then

	printf "\nWhen asked to choose whether or not to redirect HTTP traffic to HTTPS, choose '2 - Redirect'.\nPress any key to continue..."
	read confirm_redirect;

	sudo apt-get install software-properties-common
	sudo add-apt-repository universe
	sudo add-apt-repository ppa:certbot/certbot
	sudo apt-get update
	sudo apt-get install certbot python-certbot-nginx
	sudo certbot --nginx --register-unsafely-without-email

	# Add certbot to root cron
	echo "Adding certbot renewal command to root's crontab..."
	sudo crontab -l > /tmp/rootcron;
	certbot_cron=`more /tmp/rootcron | grep certbot`
	if [ -z "$certbot_cron" ]; then
		sudo echo '0 12 * * * /usr/bin/certbot renew --quiet' >> /tmp/rootcron
		sudo crontab /tmp/rootcron
	fi
	if [ -f "/tmp/rootcron" ]; then
		sudo rm -f /tmp/rootcron
	fi
fi

#
# Cron
# 
echo "Configuring cron task for www-data..."
sudo crontab -u www-data -l > /tmp/wwwdatacron;
schedule_cron=`more /tmp/wwwdatacron | grep schedule`
if [ -z "$schedule_cron" ]; then
	sudo echo "* * * * * php $install_path/artisan schedule:run >> /dev/null 2>&1" >> /tmp/wwwdatacron
	sudo crontab -u www-data /tmp/wwwdatacron
fi
if [ -f "/tmp/wwwdatacron" ]; then
	sudo rm -f /tmp/wwwdatacron
fi

#
# Finish
#
protocol='http'
if [ $confirm_https = 'Y' ]; then
	protocol='https'
fi
echo ""
echo "To complete installation please open in your browser help desk URL and follow instructions.
You can skip setting up a cron task, as it has already been done for you.

URL: $protocol://$domain_name

Database Host: localhost
Database Port: 3306
Database Name: freescout
Database Username: freescout
Database Password: $mysql_pass
"
