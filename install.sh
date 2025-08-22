sudo apt update
sudo apt install mysql-server -y #TODO: Latest Version to do 8.x
sudo apt upgrade -y
sudo systemctl start mysql.service

sudo apt install nginx -y
sudo ufw allow 22
sudo ufw allow 'Nginx HTTP'
sudo ufw allow 'Nginx HTTPS'
sudo ufw enable -y
sudo systemctl restart nginx
sudo systemctl start nginx

# For learning purpose.
sudo systemctl reload nginx
sudo systemctl enable nginx


#sudo ufw allow 443
# sudo apt install nginx
# sudo ufw app list
# sudo ufw allow 'Nginx HTTP' 


# mysql -e "DELETE FROM mysql.user WHERE User='';"
# mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
# mysql -e "DROP DATABASE IF EXISTS test;"
# mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
# mysql -e "FLUSH PRIVILEGES;"



sudo apt-get install -y curl
curl -fsSL https://deb.nodesource.com/setup_23.x -o nodesource_setup.sh
sudo -E bash nodesource_setup.sh
sudo apt-get install -y nodejs
node -v

#sudo pm2 completion install
sudo npm install pm2@latest -g && pm2 update

#Generate key for ssh from github..
echo '-----BEGIN OPENSSH PRIVATE KEY-----' >/root/.ssh/id_ed25519
echo 'b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW'>>/root/.ssh/id_ed25519
echo 'QyNTUxOQAAACDS7qKN8l1GPNnaFnAVsoV8OTv0hlQfbf5FIMQ0g+AlRAAAAJCc+SWHnPkl'>>/root/.ssh/id_ed25519
echo 'hwAAAAtzc2gtZWQyNTUxOQAAACDS7qKN8l1GPNnaFnAVsoV8OTv0hlQfbf5FIMQ0g+AlRA'>>/root/.ssh/id_ed25519
echo 'AAAEA5VzyDH7Gm1mLPJlCIhRcd5N04/lqPZ5EjscTuWGxn5tLuoo3yXUY82doWcBWyhXw5'>>/root/.ssh/id_ed25519
echo 'O/SGVB9t/kUgxDSD4CVEAAAADXJvb3RAM3UtaGVsLTE='>>/root/.ssh/id_ed25519
echo '-----END OPENSSH PRIVATE KEY-----'>>/root/.ssh/id_ed25519
chmod 600 /root/.ssh/id_ed25519

eval "$(ssh-agent -s)"

ssh-add /srv/3ulogging/ssh/3uLoggingDB

#================================= common scripts===============================
#Install mysql community server..
nano mysql.sh
chmod +x mysql.sh
./mysql.sh 

# Install Nginx
nano mysql.sh
chmod +x mysql.sh
./install_nginx.sh

# Node installation..
nano mysql.sh
chmod +x mysql.sh
./install_node_pm2.sh

mkdir /srv/scripts
#create general scripts..

nano mysql_user.sh
chmod +x mysql_user.sh

nano update_db.sh
chmod +x update_db.sh

nano update_fetch_pm2.sh
chmod +x update_fetch_pm2.sh

nano nginx_proxy_ip.sh
chmod +x nginx_proxy_ip.sh

nano startapp.sh
chmod +x startapp.sh

nano update_static.sh
chmod +x update_static.sh

nano generate-cert.sh
chmod +x generate-cert.sh

nano nginx_ssl_websocket.sh
chmod +x nginx_ssl_websocket.sh




#================================== mnmagent =======================================
npm i mnm-pm -g





sudo nano /etc/systemd/system/MnM.service

[Unit]
Description='MnM Agent'
After=network.target

[Service]
ExecStart=/usr/bin/node /srv/mnm/app.js
WorkingDirectory=/var/www/MnM/
Restart=always
User=root
Group=nogroup
Environment=NODE_ENV=production
# Log file
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=MnM

[Install]
WantedBy=multi-user.target


#================================== apps =======================================
mkdir /srv/MnM
mkdir /srv/cnfg
mkdir /srv/replaylogs


# ========================================== mnmserver ==========================================
mkdir /srv/mnmserver
mkdir /srv/mnmserver/prod
mkdir /srv/mnmserver/repo
mkdir /srv/mnmserver/conf
mkdir /srv/mnmserver/rbck
mkdir /srv/mnmserver/scripts
mkdir /srv/mnmserver/ssh

ssh-keygen -t ed25519 -C "dev1@hostingcontroller.com" -f /srv/mnmserver/ssh/mnmserver -N ""
cd /srv/mnmserver/repo
GIT_SSH_COMMAND="ssh -i /srv/mnmserver/ssh/mnmserver -o StrictHostKeyChecking=no" git clone git@github.com:MnMsys/mnmserver-prod.git

/srv/scripts/update_fetch_pm2.sh /srv/mnmserver/backup /srv/mnmserver/repo/mnmserver-prod /srv/mnmserver/ssh/mnmserver mnmserver
/srv/scripts/nginx_ssl_websocket.sh mnms.io mnmserver 9512

# ========================================== 3ulogging ==========================================
mkdir /srv/3ulogging
mkdir /srv/3ulogging/prod
mkdir /srv/3ulogging/repo
mkdir /srv/3ulogging/conf
mkdir /srv/3ulogging/rbck
mkdir /srv/3ulogging/scripts
mkdir /srv/3ulogging/ssh


ssh-keygen -t ed25519 -C "dev1@hostingcontroller.com" -f /srv/3ulogging/ssh/3ulogging -N ""
ssh-keygen -t ed25519 -C "dev1@hostingcontroller.com" -f /srv/3ulogging/ssh/3uloggingdb -N ""

cd /srv/3ulogging/repo
GIT_SSH_COMMAND="ssh -i /srv/3ulogging/ssh/3uloggingdb -o StrictHostKeyChecking=no" git clone git@github.com:3ugg/3uloggingdb.git
cd /srv/scripts
/srv/scripts/mysql_user.sh 3ulogging
/srv/scripts/update_db.sh  /srv/3ulogging/backup/mysql /srv/3ulogging/repo/3uloggingdb   /srv/3ulogging/ssh/3uloggingdb 3ulogging

cd /srv/3ulogging/repo
GIT_SSH_COMMAND="ssh -i /srv/3ulogging/ssh/3ulogging -o StrictHostKeyChecking=no" git clone git@github.com:3ugg/logging-prod.git

/srv/scripts/update_fetch_pm2.sh /srv/3ulogging/backup /srv/3ulogging/repo/logging-prod /srv/3ulogging/ssh/3ulogging 3ulogging
/srv/scripts/nginx_proxy_ip.sh 167.235.25.26 3ulogging 9502

# ========================================= geolocation ===========================================
mkdir /srv/geolocation
mkdir /srv/geolocation/prod
mkdir /srv/geolocation/repo
mkdir /srv/geolocation/conf
mkdir /srv/geolocation/rbck
mkdir /srv/geolocation/scripts
mkdir /srv/geolocation/ssh

ssh-keygen -t ed25519 -C "dev1@hostingcontroller.com" -f /srv/geolocation/ssh/geolocation -N ""
ssh-keygen -t ed25519 -C "dev1@hostingcontroller.com" -f /srv/geolocation/ssh/geolocationdb -N ""
cd /srv/geolocation/repo
GIT_SSH_COMMAND="ssh -i /srv/geolocation/ssh/geolocationdb -o StrictHostKeyChecking=no" git clone git@github.com:advcomm/geolocationdb.git


cd /srv/scripts
nano mysql_user.sh
chmod +x mysql_user.sh
/srv/scripts/mysql_user.sh geolocation
nano update_db.sh
chmod +x update_db.sh
/srv/scripts/update_db.sh  /srv/geolocation/backup/mysql /srv/geolocation/repo/geolocationdb   /srv/geolocation/ssh/geolocationdb geolocation

cd /srv/geolocation/scripts 
nano import_ipcountry.sh
chmod +x import_ipcountry.sh
/srv/geolocation/scripts/import_ipcountry.sh "U0n6gjf3pM7FDZyyS7vGCqsTcV1ju93okU3ho7q4uoymGWEW3UFjQ7zHF8sfjdXi"  


cd /srv/geolocation/repo
GIT_SSH_COMMAND="ssh -i /srv/geolocation/ssh/geolocation -o StrictHostKeyChecking=no" git clone git@github.com:advcomm/geolocation-prod.git

cd /srv/geolocation/scripts
nano startapp.sh
chmod +x startapp.sh


/srv/scripts/update_fetch_pm2.sh /srv/geolocation/backup /srv/geolocation/repo/geolocation-prod /srv/geolocation/ssh/geolocation geolocation
/srv/scripts/nginx_proxy_ip.sh 37.27.189.44 geolocation 9504

# ========================================= 3uadmin ===========================================
mkdir /srv/3uadmin
mkdir /srv/3uadmin/prod
mkdir /srv/3uadmin/repo
mkdir /srv/3uadmin/conf
mkdir /srv/3uadmin/rbck
mkdir /srv/3uadmin/scripts
mkdir /srv/3uadmin/ssh

ssh-keygen -t ed25519 -C "dev1@hostingcontroller.com" -f /srv/3uadmin/ssh/3uadmin -N ""
ssh-keygen -t ed25519 -C "dev1@hostingcontroller.com" -f /srv/3uadmin/ssh/3uadmindb -N ""

cd /srv/3uadmin/scripts
nano mysql_admin_user.sh
chmod +x mysql_admin_user.sh
/srv/3uadmin/scripts/mysql_admin_user.sh


cd /srv/3uadmin/repo
GIT_SSH_COMMAND="ssh -i /srv/3uadmin/ssh/3uadmindb -o StrictHostKeyChecking=no" git clone git@github.com:3ugg/3uadmindb.git

/srv/scripts/update_db.sh  /srv/3uadmin/backup/mysql /srv/3uadmin/repo/3uadmindb   /srv/3uadmin/ssh/3uadmindb 3uadmin


cd /srv/3uadmin/repo
GIT_SSH_COMMAND="ssh -i /srv/3uadmin/ssh/3uadmin -o StrictHostKeyChecking=no" git clone git@github.com:3ugg/3uadmin-prod.git

cd /srv/3uadmin/conf
nano serverapi.env

/srv/scripts/update_fetch_pm2.sh /srv/3uadmin/backup /srv/3uadmin/repo/3uadmin-prod /srv/3uadmin/ssh/3uadmin 3uadmin




# ========================================= 3uauth ===========================================
mkdir /srv/3uauth
mkdir /srv/3uauth/prod
mkdir /srv/3uauth/repo
mkdir /srv/3uauth/conf
mkdir /srv/3uauth/rbck
mkdir /srv/3uauth/scripts
mkdir /srv/3uauth/ssh

ssh-keygen -t ed25519 -C "dev1@hostingcontroller.com" -f /srv/3uauth/ssh/3uauth -N ""
cd /srv/3uauth/repo
GIT_SSH_COMMAND="ssh -i /srv/3uauth/ssh/3uauth -o StrictHostKeyChecking=no" git clone git@github.com:3ugg/3uauth-prod.git

/srv/scripts/update_fetch_pm2.sh /srv/3uauth/backup /srv/3uauth/repo/3uauth-prod /srv/3uauth/ssh/3uauth 3uauth
/srv/scripts/nginx_ssl.sh auth.3u.gg 3uauth 9506
# ========================================= 3uengine ===========================================
mkdir /srv/3uengine
mkdir /srv/3uengine/prod
mkdir /srv/3uengine/repo
mkdir /srv/3uengine/conf
mkdir /srv/3uengine/rbck
mkdir /srv/3uengine/scripts
mkdir /srv/3uengine/ssh

ssh-keygen -t ed25519 -C "dev1@hostingcontroller.com" -f /srv/3uengine/ssh/3uengine -N ""
/srv/scripts/mysql_user.sh 3uengine

cd /srv/3uengine/repo
GIT_SSH_COMMAND="ssh -i /srv/3uengine/ssh/3uengine -o StrictHostKeyChecking=no" git clone git@github.com:3ugg/3uengine-prod.git

/srv/scripts/update_fetch_pm2.sh /srv/3uengine/backup /srv/3uengine/repo/3uengine-prod /srv/3uengine/ssh/3uengine 3uengine
/srv/scripts/nginx_ssl.sh 3u.gg 3uengine 9501
/home/scripts/nginx_ssl.sh auth.xdoc.app xdocAuth 3333
# ========================================= 3uadmingui ===========================================
mkdir /srv/3uadmingui
mkdir /srv/3uadmingui/prod
mkdir /srv/3uadmingui/repo
mkdir /srv/3uadmingui/conf
mkdir /srv/3uadmingui/rbck
mkdir /srv/3uadmingui/scripts
mkdir /srv/3uadmingui/ssh

ssh-keygen -t ed25519 -C "dev1@hostingcontroller.com" -f /srv/3uadmingui/ssh/3uadmingui -N ""
/srv/scripts/mysql_user.sh 3uadmingui

cd /srv/3uadmingui/repo
GIT_SSH_COMMAND="ssh -i /srv/3uadmingui/ssh/3uadmingui -o StrictHostKeyChecking=no" git clone git@github.com:3ugg/3uadmingui-prod.git

#/srv/scripts/deploy_angular_nginx.sh my-app myapp.example.com /var/www/my-app/dist /etc/letsencrypt/live/example.com

/srv/scripts/update_static.sh /srv/3uadmingui/backup /srv/3uadmingui/repo/3uadmingui-prod /srv/3uadmingui/ssh/3uadmingui 

/srv/scripts/nginx_web.sh admin.3u.gg /srv/3uadmingui/prod/dist /etc/letsencrypt/live/3u.gg
# =================================================================================================================






# ========================================= xdoc ===========================================
mkdir /srv/xdoc
mkdir /srv/xdoc/prod
mkdir /srv/xdoc/repo
mkdir /srv/xdoc/conf
mkdir /srv/xdoc/rbck
mkdir /srv/xdoc/scripts
mkdir /srv/xdoc/ssh

ssh-keygen -t ed25519 -C "dev1@hostingcontroller.com" -f /srv/xdoc/ssh/xdoc -N ""
ssh-keygen -t ed25519 -C "dev1@hostingcontroller.com" -f /srv/xdoc/ssh/xdocdb -N ""

cd /srv/xdoc/repo
GIT_SSH_COMMAND="ssh -i /srv/xdoc/ssh/xdoc -o StrictHostKeyChecking=no" git clone git@github.com:xdocapp/api-prod.git
/srv/scripts/nginx_ssl.sh api.xdoc.app xdoc 3000


* * * * * /bin/bash /srv/scripts/update_fetch_pm2.sh /srv/xdoc/backup /srv/xdoc/repo/api-prod /srv/xdoc/ssh/xdoc xdoc >> /tmp/update_xdoc.log 2>&1
cd /srv/xdoc/repo
GIT_SSH_COMMAND="ssh -i /srv/xdoc/ssh/xdocdb -o StrictHostKeyChecking=no" git clone git@github.com:xdocapp/db.git


* * * * * /bin/bash  /srv/scripts/update_db.sh  /srv/xdoc/backup/mysql /srv/xdoc/repo/db   /srv/xdoc/ssh/xdocdb xdoc >> /tmp/cronjob.log 2>&1


# ========================================= xdocgui ===========================================
mkdir /srv/xdocgui
mkdir /srv/xdocgui/prod
mkdir /srv/xdocgui/repo
mkdir /srv/xdocgui/conf
mkdir /srv/xdocgui/rbck
mkdir /srv/xdocgui/scripts
mkdir /srv/xdocgui/ssh

ssh-keygen -t ed25519 -C "dev1@hostingcontroller.com" -f /srv/xdocgui/ssh/xdocgui -N ""
/srv/scripts/mysql_user.sh xdocgui

cd /srv/xdocgui/repo
GIT_SSH_COMMAND="ssh -i /srv/xdocgui/ssh/xdocgui -o StrictHostKeyChecking=no" git clone git@github.com:xdocapp/web.git

#/srv/scripts/deploy_angular_nginx.sh my-app myapp.example.com /var/www/my-app/dist /etc/letsencrypt/live/example.com

* * * * * /bin/bash /srv/scripts/update_static.sh /srv/xdocgui/backup /srv/xdocgui/repo/web /srv/xdocgui/ssh/xdocgui >> /tmp/update_xdocgui.log 2>&1

 /srv/scripts/update_static_prod.sh /srv/xdocgui/backup /srv/xdocgui/repo/web 

/srv/scripts/nginx_web.sh s.xdoc.app /srv/xdocgui/prod/web /etc/letsencrypt/live/xdoc.app
# =================================================================================================================





# ========================================= uids ===========================================
mkdir /srv/uids
mkdir /srv/uids/prod
mkdir /srv/uids/repo
mkdir /srv/uids/conf
mkdir /srv/uids/rbck
mkdir /srv/uids/scripts
mkdir /srv/uids/ssh

ssh-keygen -t ed25519 -C "dev1@hostingcontroller.com" -f /srv/uids/ssh/uids -N ""

cd /srv/uids/repo
GIT_SSH_COMMAND="ssh -i /srv/uids/ssh/uids -o StrictHostKeyChecking=no" git clone git@github.com:uids-io/api-prod.git

* * * * * /bin/bash /srv/uids/scripts/update_fetch_pm2.sh /srv/uids/backup /srv/uids/repo/api-prod /srv/uids/ssh/uids uids >> /tmp/AuthApi.log 2>&1
/srv/scripts/nginx_ssl.sh api.uids.app uids 3333

* * * * * /bin/bash  /srv/scripts/update_db.sh  /srv/uids/backup/mysql /srv/uids/repo/db   /srv/uids/ssh/uidsdb uids >> /tmp/cronjob.log 2>&1


=======================================================================

mkdir /srv/cannons.dev
mkdir /srv/cannons.dev/prod
mkdir /srv/cannons.dev/repo
mkdir /srv/cannons.dev/conf
mkdir /srv/cannons.dev/rbck
mkdir /srv/cannons.dev/scripts
mkdir /srv/cannons.dev/ssh

ssh-keygen -t ed25519 -C "dev1@hostingcontroller.com" -f /srv/cannons.dev/ssh/static -N ""

cd /srv/cannons.dev/repo
GIT_SSH_COMMAND="ssh -i  /srv/cannons.dev/ssh/static -o StrictHostKeyChecking=no" git clone git@github.com:canonicalapp/www.git

# ========================================= xdoc(xdoc-db-1) ===========================================
mkdir /srv/xdoc
mkdir /srv/xdoc/prod
mkdir /srv/xdoc/repo
mkdir /srv/xdoc/conf
mkdir /srv/xdoc/rbck
mkdir /srv/xdoc/scripts
mkdir /srv/xdoc/ssh

# - if new server...
ssh-keygen -t ed25519 -C "dev1@hostingcontroller.com" -f /srv/xdoc/ssh/xdoc_db -N ""
#otherwise use existing key

sudo chmod 600 /srv/xdoc/ssh/xdoc_db

#other block ends

cd /srv/xdoc/repo
GIT_SSH_COMMAND="ssh -i /srv/xdoc/ssh/xdoc_db -o StrictHostKeyChecking=no" git clone git@github.com:xdocapp/db.git
* * * * * /bin/bash /srv/scripts/pg_deploy_with_update.sh /srv/xdoc/backup/pg /srv/xdoc/repo/db /srv/xdoc/ssh/xdoc_db xdoc xdoc 10001 >> /tmp/cronjob.log 2>&1


sudo /srv/scripts/gen_sscertificate.sh 95.216.189.60

#mtddlookup container... (should be on first server)
### podman rm -f mtdd-lookup-service 

podman run -d --name mtdd-lookup-service \
  --label io.containers.autoupdate=local \
  -p 50054:50054 \
  -e GRPC_PORT=50054 \
  -e 'DB_CONFIG={"type":"postgres","host":"/var/run/postgresql","user":"xdoc","database":"xdoc"}' \
  -e BACKEND_SERVERS=95.216.189.60 \
  -v pg-run-volume:/var/run/postgresql \
  docker.io/syednhashmi/mtddlookup:latest

sudo /srv/scripts/nginx_grpc_proxy_container.sh 95.216.189.60 mtddlookup 50054



#mtdd container...
### podman rm -f mtdd-service

podman run -d --name mtdd-service \
  --label io.containers.autoupdate=local \
  -p 50051:50051 \
  -e 'DB_CONFIG={"type":"postgres","host":"/var/run/postgresql","user":"xdoc","database":"xdoc"}' \
  -e USER_UID=10001 \
  -e USER_NAME=xdoc \
  -v pg-run-volume:/var/run/postgresql \
  docker.io/syednhashmi/mtdd:latest

##sudo /srv/scripts/nginx_grpc_proxy_container.sh 95.216.189.60 mtdd 50051
sudo /srv/scripts/nginx_grpc_proxy_container.sh 95.216.189.60 DB.DBService 50051
#-----------------------xdoc Gateway server-----------------------------------#

# install NGINX...
mkdir /srv/scripts
nano /srv/scripts/install_nginx_podman.sh #place the content from the mentioned file...
chmod +x /srv/scripts/install_nginx_podman.sh
/srv/scripts/install_nginx_podman.sh

mkdir /uploads


### podman rm -f xdoc-api
podman pull docker.io/chishtiaq422/xdoc-api:latest
podman run -d \
  --name xdoc-api \
  -e NODE_ENV=production \
  -e 'DB_CONFIG={}' \
  -e 'BACKEND_SERVERS=95.216.189.60' \
-e 'LOOKUP_SERVER=95.216.189.60' \
  -p 3000:3000 \
  -v pg-run-volume:/var/run/postgresql \
  -v /uploads:/app/uploads \
  docker.io/chishtiaq422/xdoc-api


  mkdir ~/.aws
  nano ~/.aws/credentials
  /srv/scripts/gen_cert_aws.sh api.xdoc.app dev1@hostingcontroller.com
sudo ./add_reverse_proxy.sh api.xdoc.app 3000

# ========================================= xdoc-spa ===========================================
# install NGINX...
mkdir /srv/scripts
nano /srv/scripts/install_nginx_podman.sh #place the content from the mentioned file...

chmod +x /srv/scripts/install_nginx_podman.sh
/srv/scripts/install_nginx_podman.sh

nano  /srv/scripts/gen_cert_aws.sh
chmod +x /srv/scripts/gen_cert_aws.sh


podman pull docker.io/syednhashmi/xdoc-web:latest
podman run -d --name xdoc-web --label io.containers.autoupdate=local -v /var/www/html-podman/xdoc-web:/var/www/html-podman/xdoc-web docker.io/syednhashmi/xdoc-web:latest

  mkdir ~/.aws
  nano ~/.aws/credentials
/srv/scripts/gen_cert_aws.sh web.xdoc.app dev1@hostingcontroller.com
nano /srv/scripts/deploy_static_nginx_podman.sh
chmod +x /srv/scripts/deploy_static_nginx_podman.sh

/srv/scripts/deploy_static_nginx_podman.sh web.xdoc.app xdoc-web
# =================================================================================================================

#--------------------------------xdoc-static-----------------------------------
# install NGINX...
mkdir /srv/scripts
nano /srv/scripts/install_nginx_podman.sh #place the content from the mentioned file...
chmod +x /srv/scripts/install_nginx_podman.sh
/srv/scripts/install_nginx_podman.sh

nano /srv/scripts/add_reverse_proxy.sh
chmod +x /srv/scripts/add_reverse_proxy.sh

nano  /srv/scripts/gen_cert_aws.sh
chmod +x /srv/scripts/gen_cert_aws.sh

### podman rm -f xdoc-static
podman run -d \
  --name xdoc-static \
  --label io.containers.autoupdate=local \
  -e NODE_ENV=production \
  -p 3000:3000 \
   docker.io/syednhashmi/xdoc-static


  mkdir ~/.aws
  nano ~/.aws/credentials
  /srv/scripts/gen_cert_aws.sh t.xdoc.app dev1@hostingcontroller.com
sudo /srv/scripts/add_reverse_proxy.sh t.xdoc.app 3000

#======================Installers=========================
mkdir ~/.aws
  nano ~/.aws/credentials
  /srv/scripts/gen_cert_aws.sh installers.xdoc.app dev1@hostingcontroller.com


mkdir -p /srv/xdoc/installers/{windows,macos,linux,android}
nano /srv/scripts/deploy_installer_nginx_podman.sh
chmod +x /srv/scripts/deploy_installer_nginx_podman.sh

 
/srv/scripts/deploy_installer_nginx_podman.sh installers.xdoc.app /srv/xdoc/installers


#whenever wants to update the installer ftp to server  place file and then run this
sudo cp -r /srv/xdoc/installers/* /var/www/html-podman/installers/ && sudo podman exec nginx-server nginx -s reload