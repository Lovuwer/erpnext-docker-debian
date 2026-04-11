#!/bin/bash
set -e

# ---------------------------------------------------------
# FORCE NODE 20 ENVIRONMENT FOR POS AWESOME
# ---------------------------------------------------------
export NVM_DIR="/home/frappe/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm use 20
# ---------------------------------------------------------

# -> Run entrypoint
# somehow when specify custom cmd in railway,
# it doesn't run entrypoint first, so we need to run it here.
sudo /usr/local/bin/railway-entrypoint.sh

echo "-> Create empty common site config"
echo "{}" > /home/frappe/bench/sites/common_site_config.json

echo "-> Create new site with ERPNext"
bench new-site ${RFP_DOMAIN_NAME} --admin-password ${RFP_SITE_ADMIN_PASSWORD} --no-mariadb-socket --db-root-password ${RFP_DB_ROOT_PASSWORD} --install-app erpnext
bench use ${RFP_DOMAIN_NAME}

echo "-> Enable scheduler"
bench enable-scheduler
