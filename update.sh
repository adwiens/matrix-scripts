#!/bin/bash
################################################################################################################################

# Bash script to update following docker container:
#   - Synapse (Matrix communication server)
#   - Matrix-Registration (token based registration of users at synapse server)
#   - PostgreSQL database
#   - Element (web-based Matrix client)
#   - Synapse-Admin (GUI Matrix administration)

# Update source:     https://raw.githubusercontent.com/adwiens/matrix-scripts/main/.env

################################################################################################################################
# Version 0.0.2
# Updated: 23.11.2021
################################################################################################################################

echo "###################################################################"
YELLOW=$(tput setaf 3)
GREEN=$(tput setaf 2)
RED=$(tput setaf 1)
NC=$(tput sgr0)

scriptDir=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)
cd "$scriptDir"
dockerComposePath="/usr/local/bin/docker-compose"

timestamp () {
    date +"%Y.%m.%d__%H:%M:%S.%3N"
}

time_echo() { cat <<< "$(timestamp)    $@" 1>&2; }

time_echo "${YELLOW}STARTING UPDATE...${NC}"
echo
echo

# Check for root
if [ "$(id -u)" != "0" ]; then
    time_echo "${RED}ERROR: This script has to be run as root!${NC}"
    exit 1
fi

# Check if new container tags are available
time_echo "${YELLOW}Check if new container tags are available...${NC}"
newEnvFile=$(curl -s -L https://raw.githubusercontent.com/adwiens/matrix-scripts/main/.env)
oldEnvFile=$(cat ".env")
if [ "$oldEnvFile" = "$newEnvFile" ]; then
    time_echo "No updates found!"
    exit 1
else
    time_echo "New updates are available!"
fi
time_echo "${GREEN}Done${NC}"
echo

# Backup directory
currentDate=$(date +"%Y-%m-%d__%H-%M-%S")
backupMainDir="/media/matrix_backup"
backupdir="${backupMainDir}/${currentDate}_Update_Backup"

# Check if backup directory already exists
if [ ! -d "${backupdir}" ]; then
    mkdir -p "${backupdir}"
else
    time_echo "${RED}ERROR: The backup directory   ${backupdir}   already exists!${NC}"
    exit 1
fi

serviceName="postgresql"
containerName="matrix_$serviceName"

dbBackupName="synapse-db.sql"
dbName="synapse_db"
dbUser="synapse_db_user"

# Backup old .env file
cp .env "${backupdir}/.env"

# Overwrite .env file with new tags
echo "$newEnvFile" >| .env

# Pull new images
time_echo "${YELLOW}Pulling new docker images...${NC}"
# docker-compose pull
$dockerComposePath pull
time_echo "${GREEN}Done${NC}"
echo

# Backup DB
time_echo "${YELLOW}Backup Matrix-Synapse database (PostgreSQL)...${NC}"
docker exec -t ${containerName} pg_dump "${dbName}" -h localhost -U "${dbUser}" > "${backupdir}/${dbBackupName}"
time_echo "${GREEN}Done${NC}"
echo

# Delete PostgreSQL container and volume
time_echo "${YELLOW}Delete PostgreSQL container and volume...${NC}"
docker container rm -f ${containerName}
docker volume rm ${containerName}-data
time_echo "${GREEN}Done${NC}"
echo

# Setup PostgreSQL container and volume
time_echo "${YELLOW}Creating and starting PostgreSQL container and volume...${NC}"
# docker-compose up -d ${serviceName}
$dockerComposePath up -d ${serviceName}
# sometimes pg_isready is true but restore fails because connection is not ready
#until docker exec -it ${containerName} pg_isready -U "${dbUser}"; do
#until docker exec -it ${containerName} psql -U "${dbUser}" "${dbName}" -c "\q"; do
until docker exec ${containerName} psql -U "${dbUser}" "${dbName}" -c "\q"; do
    time_echo "${RED}Ignore error. PostgreSQL is starting...wait 1 second${NC}"
    sleep 1
done
time_echo "${GREEN}PostgreSQL is ready...${NC}"
time_echo "${GREEN}Done${NC}"
echo

# Restore database from backup
time_echo "${YELLOW}Restoring database from backup...${NC}"
#until docker exec -i ${containerName} psql -U ${dbUser} ${dbName} < "${backupdir}/${dbBackupName}"; do
until docker exec ${containerName} psql -U ${dbUser} ${dbName} < "${backupdir}/${dbBackupName}"; do
    time_echo "${RED}Retry restoring database...wait 1 second${NC}"
    sleep 1
done
time_echo "${GREEN}Done${NC}"
echo

# Start all containers
time_echo "${YELLOW}Starting Synapse + Element + Registration + Admin container...${NC}"
time_echo "${RED}This will take some time. Please wait...${NC}"
# docker-compose up -d
$dockerComposePath up -d
time_echo "${GREEN}Done${NC}"
echo

# Delete unused container images
time_echo "${YELLOW}Deleting unused container images...${NC}"
docker image prune -a -f
time_echo "${GREEN}Done${NC}"
echo
echo
docker ps
echo
echo
time_echo "${GREEN}Update was successful !${NC}"
echo
echo
