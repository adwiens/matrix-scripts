#!/bin/bash
################################################################################################################################

# Bash script to create backups of:
#   - Reverse Proxy NGINX
#   - Synapse (Matrix communication server)
#   - Matrix-Registration (Token based registration of users at synapse server)
#   - PostgreSQL database
#   - Let's Encrypt shell client acme.sh with auto renewal of TLS certificats
#   - www & letsencrypt directories

################################################################################################################################
# Version 0.0.4
# Updated: 23.11.2021
################################################################################################################################

# Usage:
# 	- Interactive:                 ./backup.sh

################################################################################################################################

# 	- Passing parameters:          ./backup.sh       <BackupDirectory>    <UseCompression>    <maxNrOfBackups>    <BackupName>          
#                                                                           (optional)           (optional)        (optional)
#   - Example                      ./backup.sh    "/media/matrix_backup"    true|false               10           "Full_Backup"

################################################################################################################################

echo "###################################################################"
YELLOW=$(tput setaf 3)
GREEN=$(tput setaf 2)
RED=$(tput setaf 1)
NC=$(tput sgr0)

scriptDir=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)
cd "$scriptDir"

timestamp () {
    date +"%Y.%m.%d__%H:%M:%S.%3N"
}

time_echo() { cat <<< "$(timestamp)    $@" 1>&2; }

# Check for root
if [ "$(id -u)" != "0" ]; then
    time_echo "${RED}ERROR: This script has to be run as root!${NC}"
    exit 1
fi

# Declare backup directory, compression, max backups to store and name of backup by input arguments
backupMainDir=$1
useCompression=$2
maxNrOfBackups=$3
backupName=$4
if [ -z "$backupMainDir" ]; then
    # Interactive mode
    echo
    echo
    read -p "${YELLOW}Use default backup directory:  /media/matrix_backup  (y/n)? ${NC}"
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        backupMainDir="/media/matrix_backup"
    else
        echo
        echo
        read -p "Enter backup directory: " backupMainDir
    fi
    echo
    echo
    read -p "${YELLOW}Use GZIP to compress backup files (y/n)? ${NC}"
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        useCompression=true
    else
        useCompression=false
    fi
    echo
    echo
    read -p "${YELLOW}Enter the maximum number of backups to store (0 = keep all) ${NC}" maxNrOfBackups
    echo
fi

time_echo "${YELLOW}STARTING BACKUP...${NC}"
echo
echo

# Check if variables are empty -> set default values
if [ -z "$useCompression" ]; then
    time_echo "${YELLOW}Set default value for compression (useCompression=false)...${NC}"
    useCompression=false
    time_echo "${GREEN}Done${NC}"
    echo
fi    
if [ -z "$maxNrOfBackups" ]; then
    time_echo "${YELLOW}Set default value for max number of backups (maxNrOfBackups=0)...${NC}"
    maxNrOfBackups=0
    time_echo "${GREEN}Done${NC}"
    echo
fi
if [ -z "$backupName" ]; then
    # Set default value for backup name
    time_echo "${YELLOW}Set default value for backup name (backupName=Full_Backup)...${NC}"    
    backupName="Full_Backup"
    time_echo "${GREEN}Done${NC}"
    echo
fi

# Check if max Nr of backups is integer
if ! [[ "$maxNrOfBackups" =~ ^[0-9]+$ ]]; then
    time_echo "${RED}ERROR: The maximum number of backups must be an integer! (Your value: $maxNrOfBackups)${NC}"
    exit 1
fi

# remove slash at the end of path (e.g. /media/matrix_backup/   ->    /media/matrix_backup   )
backupMainDir=$(echo $backupMainDir | sed 's:/*$::')
currentDate=$(date +"%Y-%m-%d__%H-%M-%S")

# The actual directory of the current backup - this is a subdirectory of the main directory above with a timestamp
backupdir="${backupMainDir}/${currentDate}__${backupName}"

# Check if backup directory already exists
if [ ! -d "${backupdir}" ]; then
    mkdir -p "${backupdir}"
else
    time_echo "${RED}ERROR: The backup directory ${backupdir} already exists!${NC}"
    exit 1
fi

containerName[0]="matrix_synapse"
containerName[1]="matrix_registration"

directories[0]="/var/lib/docker/volumes/${containerName[0]}-data/_data"
directories[1]="/var/lib/docker/volumes/${containerName[1]}-data/_data"
directories[2]="/etc/letsencrypt"
directories[3]="/etc/nginx"
directories[4]="/var/www"
directories[5]="/home/letsencrypt/.acme.sh"

elementDirec="/var/lib/docker/volumes/matrix_element-data/_data"
elementConfig="config.json"
filePaths[0]="$elementDirec/$elementConfig"

fileNameBackup[0]="${containerName[0]}.tar"
fileNameBackup[1]="${containerName[1]}.tar"
fileNameBackup[2]="letsencrypt.tar"
fileNameBackup[3]="nginx.tar"
fileNameBackup[4]="www.tar"
fileNameBackup[5]="acme.tar"

dbBackupName="synapse-db.sql"
dbName="synapse_db"
dbUser="synapse_db_user"

# Add .gz extension if compression enabled
if [ "$useCompression" = true ] ; then
    for index in ${!fileNameBackup[*]}; do
        fileNameBackup[$index]+=".gz"
    done
    dbBackupName+=".gz"
fi

# Backup docker-compose and domains.txt
time_echo "${YELLOW}Creating backup: docker-compose.yaml + domains.txt...${NC}"
cp .env "${backupdir}/.env"
cp docker-compose.yaml "${backupdir}/docker-compose.yaml"
cp domains.txt "${backupdir}/domains.txt"
time_echo "${GREEN}Done${NC}"
echo

# Backup Element files
time_echo "${YELLOW}Creating backup: Element files...${NC}"
cp "${filePaths[0]}" "${backupdir}/${elementConfig}"
time_echo "${GREEN}Done${NC}"
echo

# Backup directories
for index in ${!directories[*]}; do
    time_echo "${YELLOW}Creating backup: ${directories[$index]}...${NC}"
    if [ "$useCompression" = true ]; then
        #tar -I pigz -cpf "${backupdir}/${fileNameBackup[$index]}" -C "${directories[$index]}" .
        tar -czf "${backupdir}/${fileNameBackup[$index]}" -C "${directories[$index]}" .
    else
        tar -cpf "${backupdir}/${fileNameBackup[$index]}" -C "${directories[$index]}" .
    fi
    time_echo "${GREEN}Done${NC}"
    echo
done

# Backup DB
time_echo "${YELLOW}Backup Matrix-Synapse database (PostgreSQL)...${NC}"
if [ "$useCompression" = true ]; then
    docker exec -t matrix_postgresql pg_dump "${dbName}" -h localhost -U "${dbUser}" | gzip > "${backupdir}/${dbBackupName}"
else
    docker exec -t matrix_postgresql pg_dump "${dbName}" -h localhost -U "${dbUser}" > "${backupdir}/${dbBackupName}"
fi
time_echo "${GREEN}Done${NC}"
echo

Delete_Backups () {
    # $1 = Type of backup (Full | Update)
    backupType=$1
    if [ ${maxNrOfBackups} != 0 ]; then
        nrOfBackups=$(ls -l ${backupMainDir} | grep -c ".*$backupType.*")
        if [ ${nrOfBackups} -gt ${maxNrOfBackups} ]; then
            time_echo "${YELLOW}Removing old $backupType backups...${NC}"
            ls -t ${backupMainDir} | grep ".*$backupType.*" | tail -$(( nrOfBackups - maxNrOfBackups )) | while read -r dirToRemove; do
                time_echo "${dirToRemove}"
                rm -r "${backupMainDir}/${dirToRemove:?}"
                time_echo "${GREEN}Done${NC}"
                echo
            done
        fi
    fi
}

Delete_Backups "Full"
Delete_Backups "Update"
echo
echo
time_echo "${GREEN}Backup was successful !${NC}"
echo
echo
time_echo "${YELLOW}Backup directory:${NC}   ${backupdir}"
echo
echo
