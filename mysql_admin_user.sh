APP_NAME="3uadmin"
mysql -e "CREATE DATABASE IF NOT EXISTS ${APP_NAME};"
mysql -e "CREATE DATABASE IF NOT EXISTS 3uengine;"
mysql -e "DROP USER IF EXISTS ${APP_NAME}_def@localhost;"
mysql -e "DROP USER IF EXISTS ${APP_NAME}@localhost;"
mysql -e "CREATE USER ${APP_NAME}_def@localhost IDENTIFIED WITH caching_sha2_password BY '$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 41)';"
mysql -e "REVOKE ALL PRIVILEGES ON *.* FROM ${APP_NAME}_def@localhost;"
mysql -e "GRANT ALL PRIVILEGES ON ${APP_NAME}.* TO ${APP_NAME}_def@localhost;"
mysql -e "GRANT ALL PRIVILEGES ON 3uengine.* TO ${APP_NAME}_def@localhost;"
mysql -e "CREATE USER ${APP_NAME}@localhost IDENTIFIED WITH caching_sha2_password BY '$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 41)';"
mysql -e "REVOKE ALL PRIVILEGES ON *.* FROM ${APP_NAME}@localhost;"
mysql -e "GRANT EXECUTE on ${APP_NAME}.* TO ${APP_NAME}@localhost;"
mysql -e "FLUSH PRIVILEGES;"