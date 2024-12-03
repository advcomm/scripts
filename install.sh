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



ssh-keygen -t ed25519 -C "dev1@hostingcontroller.com" -f 3ulogging -N ""
ssh-keygen -t ed25519 -C "dev1@hostingcontroller.com" -f 3uloggingDB -N ""
mkdir /srv/MnM
mkdir /srv/cnfg


mkdir /srv/replaylogs

mkdir /srv/3ulogging
mkdir /srv/3ulogging/prod
mkdir /srv/3ulogging/repo
mkdir /srv/3ulogging/conf
mkdir /srv/3ulogging/rbck
mkdir /srv/3ulogging/scripts
mkdir /srv/3ulogging/ssh


GIT_SSH_COMMAND="ssh -i /srv/3ulogging/ssh/3ulogging -o StrictHostKeyChecking=no" git clone git@github.com:3ugg/logging-prod.git
GIT_SSH_COMMAND="ssh -i /srv/3ulogging/ssh/3uloggingdb -o StrictHostKeyChecking=no" git clone git@github.com:3ugg/3uloggingdb.git


/srv/scripts/nginx_proxy_ip.sh 37.27.189.44 3ulogging 9502

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


/srv/scripts/update_fetch_pm2.sh /srv/geolocation/backup /srv/geolocation/repo/geolocation-prod /srv/geolocation/ssh/geolocation  geolocation 
/srv/scripts/nginx_proxy_ip.sh 37.27.189.44 geolocation 9504


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

/srv/scripts/update_fetch_pm2.sh /srv/3uengine/backup /srv/3uengine/repo/3uengine-prod /srv/3uengine/ssh/3uengine  3uengine 
/srv/scripts/nginx_ssl.sh 3u.gg 9501

# =================================================================================================================
#git fetch origin
#git reset --hard origin/main

# Fetch updates from the remote repository
echo "Fetching updates from remote..."
git fetch origin

# Check for changes
echo "Checking for changes..."
CHANGES=$(git diff --name-only "origin/$BRANCH")

if [[ -z "$CHANGES" ]]; then
    echo "No changes detected. Repository is up-to-date."
    exit 0
fi

echo "Changes detected:"
echo "$CHANGES"

# Back up the current repository folder
echo "Backing up current repository..."
zip -r "$BACKUP_FILE" . > /dev/null
if [[ $? -eq 0 ]]; then
    echo "Backup created successfully: $BACKUP_FILE"
else
    echo "Failed to create backup."
    exit 1
fi










# bashscript.sh
set +o history 
random_string=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32) >/dev/null2 >&1
mysql -e "ALTER USER 'app'@'localhost' IDENTIFIED BY '$random_string';"
nodejs /var/api/3u-engine/dist/index.js $random_string
set -o history

pm2 start bashscript.sh --name '3u' --interpreter bash



