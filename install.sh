#!/bin/bash
################################################################################################################################

# Bash script to install and configure:
#   - Reverse Proxy NGINX
#   - Docker.io + Docker-Compose
#   - Let's Encrypt shell client acme.sh with auto renewal of TLS certificats
#   - Firewall
#   - Crontabs to backup whole setup and database every day and update docker container

#   Docker container
#   - Synapse (Matrix communication server)
#   - Matrix-Registration (token based registration of users at synapse server)
#   - PostgreSQL database
#   - Element (web-based Matrix client)
#   - Synapse-Admin (GUI Matrix administration)

################################################################################################################################
# Version 0.0.9
# Updated: 23.11.2021
################################################################################################################################

YELLOW=$(tput setaf 3)
GREEN=$(tput setaf 2)
RED=$(tput setaf 1)
NC=$(tput sgr0)

scriptDir=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)

Check_For_Root () {
    if [ "$(id -u)" != "0" ]; then
        echo "${RED}ERROR: This script has to be run as root!${NC}"
        exit 1
    fi
}

Check_OS_And_CPU () {
    if [ $(uname -m) != "x86_64" ] || [[ $(. /etc/os-release && echo ${VERSION}) != *"Focal Fossa"* ]]; then
        echo "${RED}This installation script is only compatible with Ubuntu 20.04 LTS (Focal Fossa) and x86-64bit CPUs!${NC}"
        exit 1
    fi
}

Enter_Domain_Names () {
    echo
    echo
    read -p "${YELLOW}Enter your ${RED}Matrix domain${YELLOW} (e.g. matrix.domain.com): ${NC}" domain[0]
    echo
    read -p "${YELLOW}Enter your ${RED}Element domain${YELLOW} (e.g. element.domain.com): ${NC}" domain[1]
    echo
    read -p "${YELLOW}Enter your ${RED}Synapse-Admin domain${YELLOW} (e.g. synapseadmin.domain.com): ${NC}" domain[2]
    echo
    echo
    # Check if domain array contains duplicates
    uniqueNum=$(printf '%s\n' "${domain[@]}"|awk '!($0 in seen){seen[$0];c++} END {print c}')
    if (( uniqueNum != ${#domain[@]} )); then
        echo "${RED}ERROR: Every domain needs a unique name! 
You had entered the same domain name minimum twice!${NC}"
        exit 1
    fi
    # Save domain names in file (relevant for full restore on new machine)
    printf "%s\n" "${domain[@]}" > domains.txt
}

Check_IPs () {
    echo "Check IPs of this server and domains..."
    wanIP=$(curl -s http://whatismyip.akamai.com/)
    if [ -z "$wanIP" ]; then
        # Fallback if akamai is not responding
        wanIP=$(curl -s http://ipconfig.io/)
    fi
    for index in ${!domain[*]}; do
        dnsIP=$(getent hosts ${domain[$index]} | awk '{ print $1 }')
        if [ $wanIP = $dnsIP ]; then
            echo "${GREEN}SUCCESS: ${domain[$index]} points to this server ($wanIP)${NC}"
        else
            echo "${RED}ERROR: The IP $dnsIP of ${domain[$index]} NOT points to this server ($wanIP)!
Check your DNS records and remove proxies like Cloudflare in front of the server!${NC}"
            echo
            exit 1
        fi
        echo
    done
}

Set_Timezone () {
    echo "${YELLOW}Set timezone to Europe/Berlin...${NC}"
    timedatectl set-timezone Europe/Berlin
    echo "${GREEN}Done${NC}"
    echo
}

Update_System_Packages () {
    echo "${YELLOW}Update system packages...${NC}"
    apt update && apt upgrade -V -y && apt dist-upgrade && apt autoremove -y
    echo "${GREEN}Done${NC}"
    echo
}

Install_Prerequisite_Packages () {
    echo "${YELLOW}Install prerequisite packages...${NC}"
    apt install apt-transport-https ca-certificates curl software-properties-common pwgen cron nano openssl -y
    wget https://github.com/mikefarah/yq/releases/download/v4.13.4/yq_linux_amd64 -O /usr/bin/yq && chmod +x /usr/bin/yq
    echo "${GREEN}Done${NC}"
    echo
}

Make_Scripts_Executable () {
    echo "${YELLOW}Make several scripts executable...${NC}"
    chmod +x backup.sh restore.sh update.sh
    echo "${GREEN}Done${NC}"
    echo
}

Install_NGINX () {
    echo "${YELLOW}Install NGINX packet sources...${NC}"
    apt-get update && apt-get install -y gnupg2
    wget -O - http://nginx.org/keys/nginx_signing.key | apt-key add -
    echo "# Nginx (Mainline)
    deb [arch=amd64] http://nginx.org/packages/mainline/ubuntu/ focal nginx
    deb-src [arch=amd64] http://nginx.org/packages/mainline/ubuntu/ focal nginx" > /etc/apt/sources.list.d/nginx.list
    apt update && apt install nginx
    echo "${GREEN}Done${NC}"
    echo
}

Edit_NGINX_Config () {
    echo "${YELLOW}Edit NGINX-Config...${NC}"
    newString="user  www-data;"
    nginxConfig="/etc/nginx/nginx.conf"
    if grep -q "$newString" "$nginxConfig"; then
        echo "${GREEN}No modificatition of $nginxConfig needed!${NC}"
        return
    fi
    oldString="user  nginx;"
    sed -i "s/$oldString/$newString/" $nginxConfig
    # -------
    httpSection="http {"
    newHttpSection="${httpSection}\n    server_tokens  off;"
    search=$httpSection
    sed -i "s/$search/$newHttpSection/" $nginxConfig
    # Disable default.conf
    mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf_disabled
    echo "${GREEN}Done${NC}"
    echo
}

Check_Nginx_Config() {
    echo "${YELLOW}Check NGINX configuration...${NC}"
    nginx -t
    service nginx restart
    service nginx status
    echo "${GREEN}Done${NC}"
    echo
}

Create_HTTP_Gateway () {
    echo "${YELLOW}Edit HTTP-Gateway (Port 80 listener)...${NC}"
    #ip4=$(ip -o route get to 8.8.8.8 | sed -n 's/.*src \([0-9.]\+\).*/\1/p')
    httpGateway="/etc/nginx/conf.d/httpGateway.conf"
    if [ -f "$httpGateway" ] && grep -q "${domain[0]}" "$httpGateway"; then
        # httpsGateway exists and domain name is listed
        echo "${GREEN}No modificatition of $httpGateway needed!${NC}"
        return
    fi
    cp -R nginx_http.conf "$httpGateway"
    # Edit HTTP-Gateway
    oldString="server_name "
    newString="$oldString${domain[0]}\n                ${domain[1]}\n                ${domain[2]}"
    sed -i "s/$oldString/$newString/" $httpGateway
    echo "${GREEN}Done${NC}"
    echo
}

Add_LetsEncrypt_User () {
    echo "${YELLOW}Adding Lets Encrypt user...${NC}"
    userName="letsencrypt"
    if id $userName &>/dev/null; then
        echo "${RED}User $userName exists!${NC}"
    else
        adduser $userName --disabled-password --gecos ""
        usermod -a -G www-data $userName
        echo "$userName ALL=NOPASSWD: /bin/systemctl reload nginx.service" | sudo EDITOR='tee -a' visudo
    fi
    echo "${GREEN}Done${NC}"
    echo
}

Install_ACME_Script () {
    # Switching to letsencrypt user to install ACME
    sudo -i -u letsencrypt bash << EOF
    echo "${YELLOW}Switching to letsencrypt user...${NC}"
    echo
    echo "${YELLOW}Downloading ACME shell script...${NC}"
    /usr/bin/curl https://get.acme.sh | sh
    echo "${GREEN}Done${NC}"
EOF
    echo
    echo "${YELLOW}Switching to root user...${NC}"
    echo
    # IMPORTANT: Logout and re-login to letsencrypt user -> only then works acme.sh
    sudo -i -u letsencrypt bash << EOF
    echo "${YELLOW}Setting default CA to Lets Encrypt...${NCn}"
    sh ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    echo "${GREEN}Done${NC}"
    echo
EOF
    echo
    echo "${YELLOW}Switching to root user...${NC}"
    echo
}

Create_TLS_Certificate_Directories () {
    for index in ${!domain[*]}; do
        echo "${YELLOW}Create directories and set permissions for RSA and ECC: ${domain[$index]}...${NC}"
        mkdir -p /etc/letsencrypt/"${domain[$index]}"/rsa
        mkdir -p /etc/letsencrypt/"${domain[$index]}"/ecc
        chown -R www-data:www-data /etc/letsencrypt/"${domain[$index]}"
        chmod -R 775 /etc/letsencrypt/"${domain[$index]}"
        echo "${GREEN}Done${NC}"
        echo
    done
}

Create_Well_Known_Directory () {
    # Create .well-known directory for ACME challenge
    service nginx reload
    mkdir -p /var/www/letsencrypt/.well-known/acme-challenge
    chown -R www-data:www-data /var/www/letsencrypt
    chmod -R 775 /var/www/letsencrypt
    echo "Directory is reachable for Let's Encrypt...Check passed" > /var/www/letsencrypt/.well-known/acme-challenge/test.txt
}

Check_If_Letsencrypt_Can_Access_Webserver () {
    for index in ${!domain[*]}; do
        echo "${YELLOW}Check if Lets-Encrypt can access: ${domain[$index]}...${NC}"
        url=http://"${domain[$index]}"/.well-known/acme-challenge/test.txt
        statusCode=$(curl --write-out '%{http_code}' --silent --output /dev/null $url)
        if [[ "$statusCode" -ne 200 ]]; then
            echo "${RED}ERROR:    ${domain[$index]}    is NOT reachable! 
Check your firewall, iptables, port forwarding settings and DNS records.
Make sure, that no proxy like Cloudflare is in front.${NC}"
            exit 1
        else
            echo "${GREEN}SUCCESS:    ${domain[$index]}    is reachable${NC}"
        fi
        echo
    done
}

Get_RSA_ECC_Certificates () {
    # Change to lets-encrypt user to get RSA and ECC certificates with ACME script
    # For testing use --staging without --force in acme command
    for index in ${!domain[*]}; do
        sudo -i -u letsencrypt bash << EOF
        echo
        echo "${YELLOW}Create RSA certificate for: ${domain[$index]}...${NC}"
        echo
        sh ~/.acme.sh/acme.sh --force --issue -d "${domain[$index]}" --server letsencrypt --keylength 4096 -w /var/www/letsencrypt --key-file /etc/letsencrypt/"${domain[$index]}"/rsa/key.pem --ca-file /etc/letsencrypt/"${domain[$index]}"/rsa/ca.pem --cert-file /etc/letsencrypt/"${domain[$index]}"/rsa/cert.pem --fullchain-file /etc/letsencrypt/"${domain[$index]}"/rsa/fullchain.pem --reloadcmd "sudo /bin/systemctl reload nginx.service"
        echo "${GREEN}Done${NC}"
        echo

        echo "${YELLOW}Create ECC certificate for: ${domain[$index]}...${NC}"
        echo
        sh ~/.acme.sh/acme.sh --force --issue -d "${domain[$index]}" --server letsencrypt --keylength ec-384 -w /var/www/letsencrypt --key-file /etc/letsencrypt/"${domain[$index]}"/ecc/key.pem --ca-file /etc/letsencrypt/"${domain[$index]}"/ecc/ca.pem --cert-file /etc/letsencrypt/"${domain[$index]}"/ecc/cert.pem --fullchain-file /etc/letsencrypt/"${domain[$index]}"/ecc/fullchain.pem --reloadcmd "sudo /bin/systemctl reload nginx.service"
        echo "${GREEN}Done${NC}"
        echo
EOF
    done
    # Change back to root user
}

Create_Diffie_Hellman_Parameter () {
    echo
    echo
    read -p "${YELLOW}Enter key size in bits for Diffie-Hellman-Parameter (weak CPU = 2048 | strong CPU = 4096 | skip this step = 0): ${NC}" dhKeySize
    echo
    mkdir -p /etc/nginx/dhparams
    if [ $dhKeySize = 0 ]; then
        echo "Skipped creation of DH-Parameter. You can create DH on stronger machine and copy dhparams.pem to /etc/nginx/dhparams/..."
    else
        openssl dhparam -out /etc/nginx/dhparams/dhparams.pem $dhKeySize
    fi
    echo
}

Create_NGINX_Snippets_Headers () {
    echo "${YELLOW}Create NGINX snippets and headers configurations...${NC}"
    mkdir -p /etc/nginx/snippets
    cp -R nginx_ssl.conf /etc/nginx/snippets/ssl.conf
    cp -R nginx_headers.conf /etc/nginx/snippets/headers.conf
    echo "${GREEN}Done${NC}"
    echo
}

Create_HTTPS_Configurations () {
    # Nginx Https configuration for Synapse / Element / Synapse-Admin
    nginxTemplate[0]="nginx_https_synapse.conf"
    nginxTemplate[1]="nginx_https_element.conf"
    nginxTemplate[2]="nginx_https_admin.conf"
    echo
    echo "Federation allows users from separate Matrix servers (e.g. tu-dresden.de  |  th-owl.de) to communicate with each other"
    echo
    read -p "${YELLOW}Enable Matrix federation (y/n)? ${NC}" -n 1 -r
    enableFederation=false
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        enableFederation=true
    fi
    echo
    echo
    for index in ${!domain[*]}; do
        echo "Create NGINX HTTPS configuration for:  ${domain[$index]}..."
        nginxConfig="/etc/nginx/conf.d/${domain[$index]}.conf"
        cp -R ${nginxTemplate[$index]} "$nginxConfig"
        sed -i "s/DOMAIN.COM/${domain[$index]}/" $nginxConfig
        # Redirect matrix.domain.com to element.domain.com (only in matrix https config)
        sed -i "s/ELEMENT.COM/${domain[1]}/" $nginxConfig
        if [ $enableFederation=true ]; then
            # Enable federation
            sed -i "s/## //" $nginxConfig
        else
            # Disable federation
            sed -i "s/## /# /" $nginxConfig
        fi
        echo "${GREEN}Done${NC}"
        echo
    done
}

Enable_And_Configure_Firewall () {
    # Enable and configure UFW firewall
    echo
    read -p "${YELLOW}Setup internal UFW firewall for HTTP, HTTPS and SSH (y/n)? ${NC}" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo
        echo "${RED}ATTENTION: You can not access this server anymore if you enter the wrong SSH port!!!${NC}"
        read -p "${YELLOW}Enter your SSH port: ${NC}" sshPort
        echo
        apt update && apt install ufw
        ufw default deny
        ufw allow $sshPort
        ufw allow 80
        ufw allow 443
        ufw --force enable
        ufw status
        echo "${GREEN}Done${NC}"
        echo
    fi
}

Install_DockerIO () {
    # https://stackoverflow.com/questions/45023363/what-is-docker-io-in-relation-to-docker-ce-and-docker-ee
    #
    # docker-ce does it the Golang way: All dependencies are pulled into the source tree before the build and the whole thing forms one single package afterwards. 
    # So you always update docker with all its dependencies at once.
    #curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
    #add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu focal stable"
    #apt update
    #apt-cache policy docker-ce
    #apt install docker-ce -y
    # ---------------------------------------------------------------------------------------------------------------------------------------------------------------------
    # docker.io does it the Debian (or Ubuntu) way: Each external dependency is a separate package that can and will be updated independently.
    echo
    echo "${YELLOW}Installing Docker.io...${NC}"
    apt-get install docker.io -y
    docker --version
    echo "${GREEN}Done${NC}"
    echo
}

Install_Docker_Compose () {
    echo "${YELLOW}Installing Docker-Compose...${NC}"
    curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    docker-compose --version
    cp -R docker-compose_template.yaml docker-compose.yaml
    echo "${GREEN}Done${NC}"
    echo
}

Optimize_PostgreSQL () {
    echo
    echo
    read -p "${YELLOW}[FOR EXPERIENCED ONLY] Optimize PostgreSQL database settings (y/n)? " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        totalRam=$(awk '/MemTotal/ { printf "%.3f \n", $2/1024/1024 }' /proc/meminfo)
        numCpu=$(grep -c ^processor /proc/cpuinfo)
        echo
        echo
        echo "${RED}If you need need help open this website:    pgtune.leopard.in.ua"
        echo
        echo "Use the system informations below and paste it on the website
-----------------------------------------------------------------
    DB Version:              |   ${GREEN}14${RED}
    OS Type:                 |   ${GREEN}$(uname -s)${RED}
    DB Type:                 |   ${GREEN}Mixed type of application${RED}
    Total Memory (RAM):      |   ${GREEN}$totalRam GB${RED}
    Number of CPUs:          |   ${GREEN}$numCpu${RED}
    Number of Connections:   |   ${GREEN}optional${RED}
    Data Storage:            |   ${GREEN}SSD${RED}
-----------------------------------------------------------------"
        echo
        echo
        read -p "${YELLOW}Press any key to continue...${NC}" -n 1 -r
        echo
        echo "${RED}Enter the values${NC}"
        echo
        read -p "${YELLOW}max_connections: ${NC}" max_connections
        echo
        read -p "${YELLOW}shared_buffers (unit needed -> 1GB): ${NC}" shared_buffers
        echo
        read -p "${YELLOW}effective_cache_size (unit needed -> 3GB): ${NC}" effective_cache_size
        echo
        read -p "${YELLOW}maintenance_work_mem (unit needed -> 256MB): ${NC}" maintenance_work_mem
        echo
        read -p "${YELLOW}checkpoint_completion_target: ${NC}" checkpoint_completion_target
        echo
        read -p "${YELLOW}wal_buffers (unit needed -> 16MB): ${NC}" wal_buffers
        echo
        read -p "${YELLOW}default_statistics_target: ${NC}" default_statistics_target
        echo
        read -p "${YELLOW}random_page_cost: ${NC}" random_page_cost
        echo
        read -p "${YELLOW}effective_io_concurrency: ${NC}" effective_io_concurrency
        echo
        read -p "${YELLOW}work_mem (unit needed -> 2621kB): ${NC}" work_mem
        echo
        read -p "${YELLOW}min_wal_size (unit needed -> 1GB): ${NC}" min_wal_size
        echo
        read -p "${YELLOW}max_wal_size (unit needed -> 4GB): ${NC}" max_wal_size
        echo
        # uncomment first section of yaml
        sed -i "s/# //" docker-compose.yaml
        sed -i "s/max_connections_value/$max_connections/" docker-compose.yaml
        sed -i "s/shared_buffers_value/$shared_buffers/" docker-compose.yaml
        sed -i "s/effective_cache_size_value/$effective_cache_size/" docker-compose.yaml
        sed -i "s/maintenance_work_mem_value/$maintenance_work_mem/" docker-compose.yaml
        sed -i "s/checkpoint_completion_target_value/$checkpoint_completion_target/" docker-compose.yaml
        sed -i "s/wal_buffers_value/$wal_buffers/" docker-compose.yaml
        sed -i "s/default_statistics_target_value/$default_statistics_target/" docker-compose.yaml
        sed -i "s/random_page_cost_value/$random_page_cost/" docker-compose.yaml
        sed -i "s/effective_io_concurrency_value/$effective_io_concurrency/" docker-compose.yaml
        sed -i "s/work_mem_value/$work_mem/" docker-compose.yaml
        sed -i "s/min_wal_size_value/$min_wal_size/" docker-compose.yaml
        sed -i "s/max_wal_size_value/$max_wal_size/" docker-compose.yaml
        if [ $numCpu -gt 1 ]; then
            read -p "${YELLOW}max_worker_processes: ${NC}" max_worker_processes
            echo
            read -p "${YELLOW}max_parallel_workers_per_gather: ${NC}" max_parallel_workers_per_gather
            echo
            read -p "${YELLOW}max_parallel_workers: ${NC}" max_parallel_workers
            echo
            read -p "${YELLOW}max_parallel_maintenance_workers: ${NC}" max_parallel_maintenance_workers
            echo
            # uncomment second section of yaml if number of CPUs > 1
            sed -i "s/##//" docker-compose.yaml
            sed -i "s/max_worker_processes_value/$max_worker_processes/" docker-compose.yaml
            sed -i "s/max_parallel_workers_per_gather_value/$max_parallel_workers_per_gather/" docker-compose.yaml
            sed -i "s/max_parallel_workers_value/$max_parallel_workers/" docker-compose.yaml
            sed -i "s/max_parallel_maintenance_workers_value/$max_parallel_maintenance_workers/" docker-compose.yaml
        fi
        echo "${GREEN}Done${NC}"
    fi
    echo
    echo
}

Modify_Docker_Compose_Configuration () {
    echo "${YELLOW}Modify docker-compose.yaml...${NC}"
    postgresPW=$(pwgen -s 64 1)
    sed -i "s/MATRIX.DOMAIN.COM/${domain[0]}/" docker-compose.yaml
    sed -i "s/POSTGRES_PW/$postgresPW/" docker-compose.yaml
    echo "${GREEN}Done${NC}"
    echo
}

Pull_Images_And_Create_Container () {
    echo "${YELLOW}Pull docker images and create container...${NC}"
    docker-compose up --no-start
    echo "${GREEN}Done${NC}"
    echo
}

Generate_Synapse_Configuration () {
    echo "${YELLOW}Generate Synapse configuration and signing keys...${NC}"
    docker-compose run --rm synapse generate
    echo "${GREEN}Done${NC}"
    echo
}

Modify_Synapse_Configuration () {
    echo "${YELLOW}Modify Synapse configuration...${NC}"
    # Get keys/secrets of generated homeserver.yaml
    synapseYaml="/var/lib/docker/volumes/matrix_synapse-data/_data/homeserver.yaml"
    regSharedSec=$(yq e ".registration_shared_secret" $synapseYaml)
    macSecKey=$(yq e ".macaroon_secret_key" $synapseYaml)
    formSec=$(yq e ".form_secret" $synapseYaml)
    # old method with grep and awk
    # regSharedSec=$(grep "registration_shared_secret: " $synapseYaml | awk '{ print $2 }')
    # macSecKey=$(grep "macaroon_secret_key: " $synapseYaml | awk '{ print $2 }')
    # formSec=$(grep "form_secret: " $synapseYaml | awk '{ print $2 }')
    # ---
    # Overwrite default yaml with template
    cp -R synapse_template.yaml $synapseYaml
    # Replace placeholders with user specific values
    sed -i "s/MATRIX.DOMAIN.COM/${domain[0]}/" $synapseYaml
    sed -i "s/POSTGRES_PW/$postgresPW/" $synapseYaml
    # sed has problems when secret contains "&"  -> sed inserts the pattern
    # sed -i "s/My_Registration_Shared_Secret/$regSharedSec/" $synapseYaml
    # ---
    # perl has problems when secret contains "@". -> perl deletes chars
    # perl -pi -e "s/My_Registration_Shared_Secret/$regSharedSec/" $synapseYaml
    # ---
    # yq has problems to preserving the format and deletes some comment sections -> exhausting to read for humans!
    # yq -i e ".registration_shared_secret |= \"${regSharedSec}\"" $synapseYaml
    # ---
    # best solution with substring replacement and nested loop 
    # (adapted from: https://stackoverflow.com/questions/525592/find-and-replace-inside-a-text-file-from-a-bash-command)
    declare -a old=("My_Registration_Shared_Secret" "My_Macaroon_Secret_Key" "My_Form_Secret")
    # add quotes (\") to the keys/secrets
    declare -a new=(\"$regSharedSec\" \"$macSecKey\" \"$formSec\")
    # save default IFS (Internal Field Separator)
    oldIFS=$IFS
    for index in ${!old[*]}; do
        # set new IFS to keep whitespace during read command (indentation for comments etc)
        IFS=""
        # read every single line
        while read a; do
            # replace "old" with "new" string in line "a" and write result in temporary file "synapseYaml.t"
            echo ${a//${old[$index]}/${new[$index]}}
        done < $synapseYaml > $synapseYaml.t
        # finally overwrite original "synapseYaml" with temporary "synapseYaml.t"
        mv $synapseYaml{.t,}
    done
    IFS=$oldIFS
    echo "${GREEN}Done${NC}"
    echo
}

Modify_Matrix_Registration_Configuration () {
    echo "${YELLOW}Modify Matrix-Registration configuration...${NC}"
    registrationYaml="/var/lib/docker/volumes/matrix_registration-data/_data/config.yaml"
    # Overwrite default yaml with template
    cp -R registration_template.yaml $registrationYaml
    # Replace placeholders with user specific values
    sed -i "s/MATRIX.DOMAIN.COM/${domain[0]}/" $registrationYaml
    sed -i "s/ELEMENT.DOMAIN.COM/${domain[1]}/" $registrationYaml
    # sed has problems when secret contains "&"  -> sed inserts the pattern
    # sed -i "s/My_Registration_Shared_Secret/$regSharedSec/" $registrationYaml
    # ---
    # yq don't preserve the format if many comments are used. Here are only 2 commments -> no problem
    yq -i e ".registration_shared_secret |= \"${regSharedSec}\"" $registrationYaml
    adminApiSec=$(pwgen -s 64 1)
    # sed -i "s/My_Admin_Api_Shared_Secret/$adminApiSec/" $registrationYaml
    yq -i e ".admin_api_shared_secret |= \"${adminApiSec}\"" $registrationYaml
    echo "${GREEN}Done${NC}"
    echo
}

Modify_Element_Configuration () {
    echo "${YELLOW}Modify Element configuration...${NC}"
    elementJson="/var/lib/docker/volumes/matrix_element-data/_data/config.json"
    # Overwrite default json with template
    cp -R element_template.json $elementJson
    # Replace placeholders with user specific values
    sed -i "s/MATRIX.DOMAIN.COM/${domain[0]}/" $elementJson
    echo "${GREEN}Done${NC}"
    echo
}

Start_Container () {
    echo "${YELLOW}Start docker container: Synapse + PostgreSQL + Registration + Admin + Element...${NC}"
    docker-compose up -d
    echo "${GREEN}Done${NC}"
    echo
}

Create_Synapse_User () {
    echo
    echo
    echo "${RED}In the next step you have to create an admin user for matrix. Below you see hints to create this account.
-------------------------------------------------------------------------------------------------------------------
New user localpart [root]:   |   ${GREEN}YOUR_USERNAME${RED}                  |   Press Enter
Password:                    |   ${GREEN}YOUR_PASSWORD (pw is hidden)${RED}   |   Press Enter
Confirm Password:            |   ${GREEN}YOUR_PASSWORD (pw is hidden)${RED}   |   Press Enter
Make admin [no]:             |   ${GREEN}yes${RED}                            |   Press Enter"
    echo
    echo
    read -p "${YELLOW}Press any key to continue...${NC}" -n 1 -r
    echo
    echo
    echo
    docker exec -it matrix_synapse register_new_matrix_user http://localhost:8008 -c /data/homeserver.yaml
    echo
}

Check_Container_Status () {
    echo "${YELLOW}Checking docker container status...${NC}"
    containerName[0]="matrix_synapse"
    containerName[1]="matrix_element"
    containerName[2]="matrix_registration"
    containerName[3]="matrix_synapse-admin"
    containerName[4]="matrix_postgresql"
    for i in ${!containerName[*]}; do
        if [ "$( docker container inspect -f '{{.State.Status}}' ${containerName[$i]} )" == "running" ]; then
            echo "${GREEN}CONTAINER RUNNING:   ${containerName[$i]}${NC}"
        else
            echo "${RED}CONTAINER NOT RUNNING:   ${containerName[$i]}${NC}"
        fi
    done
    echo
}

Check_Services_Are_Reachable () {
    echo "${YELLOW}Checking if services are reachable...${NC}"
    url[0]="${domain[0]}/_matrix/federation/v1/version"    # matrix_synapse
    url[1]="${domain[1]}"                                  # matrix_element
    url[2]="${domain[0]}/register"                         # matrix_registration
    url[3]="${domain[2]}"                                  # matrix_synapse-admin
    for i in ${!url[*]}; do
        statusCode=$(curl --write-out '%{http_code}' --silent --output /dev/null https://${url[$i]})
        if [[ "$statusCode" -ne 200 ]]; then
            echo "${RED}ERROR:   ${url[$i]}              is NOT reachable! Check configuration of this container:   ${containerName[$i]}${NC}"
            #exit 1
        else
            echo "${GREEN}SERVICE REACHABLE:   ${containerName[$i]}${NC}"
        fi
    done
    echo
    echo
    docker ps
    echo
    echo
    echo
}

Add_Crontab () {
    # $1 = Comment to cronjob (# in front NOT necessary!)
    # $2 = "0 1 * * *"
    # $3 = "/bin/bash -c \"$ScriptDir/myScript.sh\""

    ## This function make a duplicate check before adding a new cronjob
    cronComment=$1
    cronTime=$2
    cronCmd=$3
    nl=$'\n'
    cronLine="${nl}# $cronComment${nl}$cronTime $cronCmd"
    if [[ $(crontab -l | egrep -v "^(#|$)" | grep -q "$cronCmd"; echo $?) == 1 ]]; then
        set -f
        (crontab -l ; echo "$cronLine") | crontab -
        set +f
    fi
}

Add_Backup_And_Update_Cronjob () {
    Add_Crontab "Avoid this error in crontab log: \"tput: No value for \$TERM and no -T specified\"" "TERM=xterm"
    echo "${YELLOW}Adding backup cronjob...${NC}"
    Add_Crontab "Matrix backup (synapse-database, letsencrypt-certificates, nginx, acme, docker-volumes)" "0 2 * * *" "/bin/bash \"$scriptDir/backup.sh\" \"/media/matrix_backup\" true 10 >> \"$scriptDir/backup.log\" 2>&1"
    echo "${GREEN}Done${NC}"
    echo
    echo "${YELLOW}Adding update cronjob...${NC}"
    Add_Crontab "Matrix update (synapse, matrix-registration, element, synapse-admin, postgresql, )" "0 3 * * *" "/bin/bash \"$scriptDir/update.sh\" >> \"$scriptDir/update.log\" 2>&1"
    echo "${GREEN}Done${NC}"
    echo
}

Show_Credentials () {
    # Check if variables are empty -> in case of restoring from backup
    if [ -z "$adminApiSec" ]; then
        registrationYaml="/var/lib/docker/volumes/matrix_registration-data/_data/config.yaml"
        adminApiSec=$(yq e ".admin_api_shared_secret" $registrationYaml)
        domain[0]=$(yq e ".server_name" $registrationYaml)
    fi
    echo
    echo
    echo
    echo
    echo "${RED}IMPORTANT
-------------------------------------------------------------------------------------------------------------------
API Shared Secret:            ${GREEN}${adminApiSec}${RED}
Matrix Homeserver URL:        ${GREEN}${domain[0]}${RED}

Copy the credentials from above!"
    echo
    echo
    read -p "${YELLOW}Press any key to finish installation...${NC}" -n 1 -r
    echo
    echo
    echo
}



# --------------------------------------------------------------------------------------------------------------------------------------

installArgument=$1
if [ -z "$installArgument" ]; then
    # Manual installation without restore

    # Pre-Checks and setup system
    Check_For_Root
    Check_OS_And_CPU
    Enter_Domain_Names
    Set_Timezone
    Update_System_Packages
    Install_Prerequisite_Packages
    Make_Scripts_Executable
    Check_IPs

    # NGINX
    Install_NGINX
    Edit_NGINX_Config
    Create_HTTP_Gateway
    Check_Nginx_Config

    # Let's Encrypt Client acme.sh
    Add_LetsEncrypt_User
    Install_ACME_Script
    Create_TLS_Certificate_Directories
    Create_Well_Known_Directory
    Check_If_Letsencrypt_Can_Access_Webserver
    Get_RSA_ECC_Certificates

    # NGINX
    Create_Diffie_Hellman_Parameter
    Create_NGINX_Snippets_Headers
    Create_HTTPS_Configurations
    Check_Nginx_Config

    # Container-Management
    Install_DockerIO
    Install_Docker_Compose

    # Initialize docker-compose
    Optimize_PostgreSQL
    Modify_Docker_Compose_Configuration
    Pull_Images_And_Create_Container
    
    Generate_Synapse_Configuration

    # Modify configurations
    Modify_Synapse_Configuration
    Modify_Matrix_Registration_Configuration
    Modify_Element_Configuration

    Start_Container

    # Make backup
    /bin/bash backup.sh "/media/matrix_backup" true 0 "Init_Backup"

    Create_Synapse_User

    # Final checks
    Check_Container_Status
    Check_Services_Are_Reachable

    Add_Backup_And_Update_Cronjob

    # Security
    Enable_And_Configure_Firewall
    # Fail2ban, automatic updates, SSH configs, ssh hardening https://www.sshaudit.com/

    Show_Credentials


elif [ $installArgument = "autoinstall" ]; then
    # Automatic installation with restore from backup

    # Read domain names
    readarray -t domain < domains.txt
    # Pre-Checks and setup system
    Check_For_Root
    Check_OS_And_CPU

    Set_Timezone
    Update_System_Packages
    Install_Prerequisite_Packages
    Make_Scripts_Executable
    Check_IPs

    # NGINX
    Install_NGINX

    # Let's Encrypt + ACME
    Add_LetsEncrypt_User
    Install_ACME_Script

    # Container-Management
    Install_DockerIO
    Install_Docker_Compose

    # Initialize docker-compose
    Pull_Images_And_Create_Container

    # Now switch back to restore.sh -> delete all directories and restore from backup


elif [ $installArgument = "finalize" ]; then
    # Finalize automatic installation with restore from backup
    
    # Read domain names
    readarray -t domain < domains.txt
    Check_For_Root

    Check_Nginx_Config
    Check_If_Letsencrypt_Can_Access_Webserver

    # Final checks
    Check_Container_Status
    Check_Services_Are_Reachable

    Add_Backup_And_Update_Cronjob

    # Security
    Enable_And_Configure_Firewall
    # Fail2ban, automatic updates, SSH configs, ssh hardening https://www.sshaudit.com/

    Show_Credentials
fi
