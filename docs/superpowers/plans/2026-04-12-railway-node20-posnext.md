# Railway Node 20 + POS Next Installation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix Node 20 installation order in the Railway Dockerfile, install POS Next app, and verify the site loads via HTTP.

**Architecture:** Four targeted file edits across the Railway deploy stack: reorder Node 20 install before `bench build` in the Dockerfile, switch supervisor socketio command to use `/usr/bin/node` (the symlinked Node 20 binary) instead of the fragile `${NODE_VERSION}` nvm path, add `pos_next` get-app in the builder stage and install/migrate/build in the setup script, and add a curl smoke test at the end of setup.

**Tech Stack:** Docker multi-stage build, Frappe bench (v15), ERPNext v15, POS Next (version-15 branch), nvm, Node 20, nginx, supervisord, bash.

---

### Task 1: Fix Node 20 install order in `railway/Dockerfile`

**Files:**
- Modify: `railway/Dockerfile`

**Context:**
Currently the production stage runs `bench build` (which compiles frontend assets) BEFORE installing Node 20. This means bench build uses the base image's default Node (likely 18). Node 20 must be installed first.

The builder stage also has a comment `### install your custom apps here` — this is where we add `bench get-app` for pos_next so the app code is baked into the image.

- [ ] **Step 1: Read the current Dockerfile to confirm line numbers**

Open `railway/Dockerfile`. Confirm that in stage 2 (production):
- The `RUN echo "-> Install nginx & supervisor"` block (contains `bench build`) appears around line 53–68
- The Node 20 `USER frappe` / `RUN bash -c "source ~/.nvm/nvm.sh..."` block appears around line 81–85
- The `USER root` symlink block appears around line 91–93

- [ ] **Step 2: Move Node 20 install to before `bench build`, and add pos_next get-app in builder**

Replace `railway/Dockerfile` with the corrected version:

```dockerfile
# ------------------------------------------
# - Stage: 01 - builder
# ------------------------------------------

FROM pipech/erpnext-docker-debian:version-15-latest AS builder

# These variable has been set from base image
# $systemUser, $benchFolderName
USER $systemUser
WORKDIR /home/$systemUser/$benchFolderName

RUN echo "-> Start builder" \
    ### remove unused sites, created by base image
    && rm -rf /home/$systemUser/$benchFolderName/sites/site1.local \
    ### [HOTFIX] Railway used IPv6 (Does not support IPv4),  https://docs.railway.com/guides/private-networking#caveats
    ### https://github.com/frappe/frappe/issues/33981
    && sed -i 's/socket\.AF_INET, socket\.SOCK_STREAM/socket.AF_INET6, socket.SOCK_STREAM/g' /home/frappe/bench/apps/frappe/frappe/utils/connections.py \
    ### install POS Next app
    && bench get-app https://github.com/BrainWise-DEV/pos_next.git --branch version-15 \
    && echo "-> Builder done!"


# ------------------------------------------
# - Stage: 02 - production
# ------------------------------------------

# Image version should also match with stage 01
# (Check pipech/erpnext-docker-debian Dockerfile)
# https://github.com/frappe/frappe_docker/blob/main/images/bench/Dockerfile
FROM frappe/bench:v5.22.9

# this env should match stage 01
# (Check pipech/erpnext-docker-debian Dockerfile)
ENV systemUser=frappe
ENV benchFolderName=bench

# Copied bench folder from build stage
COPY --from=builder --chown=$systemUser /home/$systemUser/$benchFolderName /home/$systemUser/$benchFolderName

# Copy template
COPY /railway/temp_nginx.conf /home/$systemUser/temp_nginx.conf
COPY /railway/temp_supervisor.conf /home/$systemUser/temp_supervisor.conf

USER root
WORKDIR /home/$systemUser/$benchFolderName

# [fix] "debconf: unable to initialize frontend: Dialog"
# https://github.com/moby/moby/issues/27988
ARG DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------
# Install Node 20 FIRST (before bench build so assets compile with Node 20)
# ---------------------------------------------------------
USER frappe
RUN bash -c "source ~/.nvm/nvm.sh \
    && nvm install 20 \
    && nvm alias default 20 \
    && nvm use 20 \
    && npm install -g yarn"

USER root
# Symlink Node 20 binaries globally so nginx/supervisor/scripts can call node/npm/yarn directly
RUN bash -c "ln -sf /home/frappe/.nvm/versions/node/v20.*/bin/node /usr/bin/node \
    && ln -sf /home/frappe/.nvm/versions/node/v20.*/bin/npm /usr/bin/npm \
    && ln -sf /home/frappe/.nvm/versions/node/v20.*/bin/yarn /usr/bin/yarn"
# ---------------------------------------------------------

RUN echo "-> Install nginx & supervisor" \
    # apt-get update
    && apt-get update \
    && apt-get install -y \
    # nginx for serving files
    nginx \
    # supervisor to run multiple server per container
    supervisor \
    && echo "-> Cleaning installation" \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && echo "-> Remove nginx default site" \
    && rm /etc/nginx/sites-enabled/default \
    && echo "-> Rebuilding bench (with Node 20)" \
    && su $systemUser -c "bash -c 'source ~/.nvm/nvm.sh && nvm use 20 && bench build'" \
    && su $systemUser -c "cp -r /home/$systemUser/$benchFolderName/sites /home/$systemUser/$benchFolderName/built_sites"

COPY --chown=$systemUser --chmod=0755 /railway/railway-setup.sh /home/$systemUser/$benchFolderName/railway-setup.sh
COPY --chown=$systemUser --chmod=0755 /railway/railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
COPY --chown=$systemUser --chmod=0755 /railway/railway-cmd.sh /usr/local/bin/railway-cmd.sh

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
CMD ["/usr/local/bin/railway-cmd.sh"]

EXPOSE 80
```

- [ ] **Step 3: Verify the edit looks correct**

Check that in the file:
1. `bench get-app https://github.com/BrainWise-DEV/pos_next.git --branch version-15` appears in stage 1
2. The `USER frappe` / nvm Node 20 install block appears BEFORE the `RUN echo "-> Install nginx & supervisor"` block
3. `bench build` is called with `source ~/.nvm/nvm.sh && nvm use 20 && bench build`
4. The duplicate Node 20 install block at the bottom (old position) is gone

---

### Task 2: Fix `temp_supervisor.conf` — use `/usr/bin/node` for socketio

**Files:**
- Modify: `railway/temp_supervisor.conf`

**Context:**
The current socketio command is:
```
command=${NVM_DIR}/versions/node/v${NODE_VERSION}/bin/node /home/frappe/bench/apps/frappe/socketio.js
```
`NODE_VERSION` is never exported into the environment at container start, so `envsubst` would produce a broken path. Since we now symlink `/usr/bin/node → Node 20`, we can use that directly and remove the fragile `${NODE_VERSION}` variable.

- [ ] **Step 1: Edit the socketio command in temp_supervisor.conf**

In `railway/temp_supervisor.conf`, find line:
```
command=${NVM_DIR}/versions/node/v${NODE_VERSION}/bin/node /home/frappe/bench/apps/frappe/socketio.js
```
Replace with:
```
command=/usr/bin/node /home/frappe/bench/apps/frappe/socketio.js
```

- [ ] **Step 2: Verify no other `${NODE_VERSION}` references remain**

Search `railway/temp_supervisor.conf` for `NODE_VERSION` — should return nothing.

---

### Task 3: Fix `railway-cmd.sh` — remove `$NODE_VERSION` from envsubst

**Files:**
- Modify: `railway/railway-cmd.sh`

**Context:**
Since `temp_supervisor.conf` no longer uses `${NODE_VERSION}`, we remove it from the `envsubst` call. Also change shebang to `#!/bin/bash` for consistency (supervisor, nvm, and other tooling expect bash).

- [ ] **Step 1: Update railway-cmd.sh**

Replace the entire contents of `railway/railway-cmd.sh`:

```bash
#!/bin/bash
set -e

echo "-> Clearing cache"
su frappe -c "bench execute frappe.cache_manager.clear_global_cache"

echo "-> Bursting env into config"
envsubst '$RFP_DOMAIN_NAME' < /home/$systemUser/temp_nginx.conf > /etc/nginx/conf.d/default.conf
envsubst '$PATH,$HOME,$NVM_DIR' < /home/$systemUser/temp_supervisor.conf > /home/$systemUser/supervisor.conf

echo "-> Starting nginx"
nginx

echo "-> Starting supervisor"
/usr/bin/supervisord -c /home/$systemUser/supervisor.conf
```

---

### Task 4: Update `railway-setup.sh` — install POS Next + smoke test

**Files:**
- Modify: `railway/railway-setup.sh`

**Context:**
After ERPNext site creation, the setup script must:
1. Install `pos_next` app to the site (app code is already in `apps/` from builder stage)
2. Run `bench migrate` to apply pos_next DB migrations
3. Run `bench build --app pos_next` with Node 20 to compile Vue 3/Vite frontend assets
4. Run a curl smoke test against `http://localhost` to confirm nginx + gunicorn are serving the site

The smoke test is valid here because by the time the user shells in and runs this script, `railway-cmd.sh` has already started nginx and supervisor (gunicorn is running).

- [ ] **Step 1: Update railway-setup.sh**

Replace the entire contents of `railway/railway-setup.sh`:

```bash
#!/bin/bash
set -e

# ---------------------------------------------------------
# FORCE NODE 20 ENVIRONMENT
# ---------------------------------------------------------
export NVM_DIR="/home/frappe/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm use 20
echo "-> Node version: $(node --version)"
# ---------------------------------------------------------

# -> Run entrypoint
# somehow when specify custom cmd in railway,
# it doesn't run entrypoint first, so we need to run it here.
sudo /usr/local/bin/railway-entrypoint.sh

echo "-> Create empty common site config"
echo "{}" > /home/frappe/bench/sites/common_site_config.json

echo "-> Create new site with ERPNext"
bench new-site ${RFP_DOMAIN_NAME} \
    --admin-password ${RFP_SITE_ADMIN_PASSWORD} \
    --no-mariadb-socket \
    --db-root-password ${RFP_DB_ROOT_PASSWORD} \
    --install-app erpnext
bench use ${RFP_DOMAIN_NAME}

echo "-> Enable scheduler"
bench enable-scheduler

echo "-> Install POS Next"
bench --site ${RFP_DOMAIN_NAME} install-app pos_next

echo "-> Run migrations"
bench --site ${RFP_DOMAIN_NAME} migrate

echo "-> Build POS Next frontend assets (Node $(node --version))"
bench build --app pos_next

echo "-> Smoke test: checking if site responds on port 80"
MAX_RETRIES=10
RETRY_DELAY=5
for i in $(seq 1 $MAX_RETRIES); do
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Host: ${RFP_DOMAIN_NAME}" \
        http://localhost/ 2>/dev/null || echo "000")
    echo "   Attempt $i/$MAX_RETRIES — HTTP $HTTP_STATUS"
    if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "302" ] || [ "$HTTP_STATUS" = "301" ]; then
        echo "-> Site is UP (HTTP $HTTP_STATUS)"
        break
    fi
    if [ "$i" = "$MAX_RETRIES" ]; then
        echo "WARNING: Site did not respond with 200/301/302 after $MAX_RETRIES attempts."
        echo "         Check nginx: nginx -t"
        echo "         Check supervisor: supervisorctl status"
        echo "         Check gunicorn log: cat /home/frappe/bench/logs/web.error.log"
    fi
    sleep $RETRY_DELAY
done

echo "-> Setup complete."
```

- [ ] **Step 2: Verify the script references**

Check that `${RFP_DOMAIN_NAME}`, `${RFP_SITE_ADMIN_PASSWORD}`, `${RFP_DB_ROOT_PASSWORD}` match the Railway environment variable names used in the rest of the project (compare with original `railway-setup.sh` — these are unchanged).

---

### Task 5: Verify all edits are consistent

- [ ] **Step 1: Check NODE_VERSION is gone from all files**

Run:
```bash
grep -r "NODE_VERSION" "railway/"
```
Expected: zero matches (we removed it from `temp_supervisor.conf` and `railway-cmd.sh`).

- [ ] **Step 2: Confirm pos_next appears in both Dockerfile and setup script**

```bash
grep -n "pos_next" "railway/Dockerfile" "railway/railway-setup.sh"
```
Expected:
- `railway/Dockerfile`: line in stage 1 with `bench get-app ... pos_next`
- `railway/railway-setup.sh`: lines for `install-app pos_next`, `migrate`, `build --app pos_next`

- [ ] **Step 3: Confirm Node 20 install is before bench build in Dockerfile**

```bash
grep -n "nvm install 20\|bench build" "railway/Dockerfile"
```
Expected: `nvm install 20` line number is **lower** (earlier) than `bench build` line number.

- [ ] **Step 4: Confirm /usr/bin/node symlink is still present**

```bash
grep -n "ln -sf.*node" "railway/Dockerfile"
```
Expected: symlink line pointing `/usr/bin/node` to `/home/frappe/.nvm/versions/node/v20.*/bin/node`.

---

### Task 6: Local Docker build smoke test (optional but strongly recommended)

**Context:** If Docker is available locally, build the image to catch any Dockerfile syntax errors before pushing to Railway.

- [ ] **Step 1: Build the image locally**

From the repo root:
```bash
docker build -f railway/Dockerfile -t erpnext-railway-test .
```
Expected: Build completes without error. Watch for Node version confirmation in the `bench build` output — it should show `v20.x.x`.

- [ ] **Step 2: Confirm node version inside built image**

```bash
docker run --rm erpnext-railway-test node --version
```
Expected output: `v20.x.x` (not v18).

- [ ] **Step 3: Clean up**

```bash
docker rmi erpnext-railway-test
```
