#!/bin/bash
################################################################################################################################

# Bash script to restore backups of:
#   - Reverse Proxy NGINX
#   - Synapse (Matrix communication server)
#   - Matrix-Registration (token based registration of users at synapse server)
#   - PostgreSQL database
#   - Let's Encrypt shell client acme.sh with auto renewal of TLS certificats
#   - www & letsencrypt directories

################################################################################################################################
# Version 0.0.6
# Updated: 08.03.2021
################################################################################################################################

YELLOW=$(tput setaf 3)
GREEN=$(tput setaf 2)
RED=$(tput setaf 1)
NC=$(tput sgr0)

# Function for error messages
errorecho() { cat <<< "$@" 1>&2; }

# Check for root
if [ "$(id -u)" != "0" ]; then
    errorecho "${RED}ERROR: This script has to be run as root!${NC}"
    exit 1
fi

echo
echo "${RED}"
COLUMNS=12
PS3="${YELLOW}
Please enter your choice: "
options[0]="Rollback to previous container releases and keep current database"
options[1]="Rollback to previous container releases and restore old database"
options[2]="Restore only old database"
options[3]="You are on a new machine and want to restore everything"
options[4]="Quit"
select opt in "${options[@]}"
do
    case $opt in
        "${options[0]}")
            searchPattern=".*Update.*\|.*Init.*"
            break
            ;;
        "${options[1]}")
            searchPattern=".*Update.*\|.*Init.*"
            break
            ;;
        "${options[2]}")
            searchPattern=".*"
            break
            ;;
        "${options[3]}")
            searchPattern=".*Full.*\|.*Init.*"
            break
            ;;
        "${options[4]}")
            echo "${NC}"
            exit 1
            ;;
        *)
            echo
            echo "${RED}Invalid option $REPLY${YELLOW}"
            echo 
            echo
            ;;
    esac
done
echo
selectedNr=$REPLY

serviceName="postgresql"

dbBackupName="synapse-db.sql"
dbName="synapse_db"
dbUser="synapse_db_user"

containerName[0]="matrix_synapse"
containerName[1]="matrix_registration"
containerName[3]="matrix_$serviceName"

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

# Use default or special backup directory
backupMainDir="/media/matrix_backup"
echo
echo
read -p "${YELLOW}Search for backups in default backup directory:  $backupMainDir  (y/n)? ${NC}"
echo
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo
    read -p "${YELLOW}Enter backup directory: ${NC}" backupMainDir
    backupMainDir=$(echo $backupMainDir | sed 's:/*$::')
    echo
    echo
fi

# List all backups in directory
ls "${backupMainDir}" | grep "${searchPattern}"
echo
echo
read -p "${YELLOW}Enter backup from above (e.g. 2021-10-14__23-45-45_Full_Backup) : ${NC}" restore
echo

# Check if backup directory exists
currentRestoreDir="${backupMainDir}/${restore}"
if [ ! -d "${currentRestoreDir}" ]; then
	errorecho "${RED}ERROR: Backup directory not found:    ${currentRestoreDir}${NC}"
    exit 1
fi

# Check if backup directory contains .env file
if [ ! -f "${currentRestoreDir}/.env" ]; then
	errorecho "${RED}ERROR: No backup files in directory:    ${currentRestoreDir}${NC}"
    exit 1
fi

Make_Scripts_Executable () {
    echo "${YELLOW}Make several scripts executable...${NC}"
    chmod +x install.sh backup.sh update.sh
    echo "${GREEN}Done${NC}"
    echo
}

Restore_Docker_Compose_File () {
    echo "${YELLOW}Restoring docker-compose.yaml file...${NC}"
    cp "${currentRestoreDir}/docker-compose.yaml" "docker-compose.yaml"
    echo "${GREEN}Done${NC}"
    echo
}

Restore_Env_File () {
    echo "${YELLOW}Restoring .env file...${NC}"
    cp "${currentRestoreDir}/.env" ".env"
    echo "${GREEN}Done${NC}"
    echo
}

Restore_Domains_File () {
    echo "${YELLOW}Restoring domains.txt file...${NC}"
    cp "${currentRestoreDir}/domains.txt" "domains.txt"
    echo "${GREEN}Done${NC}"
    echo
}

Pull_Images () {
    echo "${YELLOW}Pulling new docker images...${NC}"
    docker-compose pull
    echo "${GREEN}Done${NC}"
    echo
}

Backup_DB () {
    echo "${YELLOW}Backup Matrix-Synapse database (PostgreSQL)...${NC}"
    docker exec -t ${containerName[3]} pg_dump "${dbName}" -h localhost -U "${dbUser}" > "${dbBackupName}"
    echo "${GREEN}Done${NC}"
    echo
}

Delete_PostgreSQL_Container_And_Volume () {
    echo "${YELLOW}Deleting PostgreSQL container and volume...${NC}"
    docker container rm -f ${containerName[3]}
    docker volume rm ${containerName[3]}-data
    echo "${GREEN}Done${NC}"
    echo
}

Setup_PostgreSQL_Container_And_Volume() {
    echo "${YELLOW}Creating and starting PostgreSQL container and volume...${NC}"
    docker-compose up -d ${serviceName}
    # sometimes pg_isready is "true" but restore fails because connection is not ready
    #until docker exec -it ${containerName} pg_isready -U "${dbUser}"; do
    until docker exec -it ${containerName[3]} psql -U "${dbUser}" "${dbName}" -c "\q"; do
        echo "${RED}Ignore error. PostgreSQL is starting...wait 1 second${NC}"
        sleep 1
    done
    echo "${GREEN}PostgreSQL is ready...${NC}"
    echo "${GREEN}Done${NC}"
    echo
}

Restore_Database () {
    echo "${YELLOW}Restoring database from backup...${NC}"
    if [ "$filesCompressed" = true ]; then
        until gunzip -c "${dbBackupName}" | docker exec -i ${containerName[3]} psql -U ${dbUser} ${dbName}; do
            echo "${RED}Retry restoring database...wait 1 second${NC}"
            sleep 1
        done
    else
        until docker exec -i ${containerName[3]} psql -U ${dbUser} ${dbName} < "${dbBackupName}"; do
            echo "${RED}Retry restoring database...wait 1 second${NC}"
            sleep 1
        done
    fi
    echo "${GREEN}Done${NC}"
    echo
}

Delete_Directory () {
    # $1 = directory to delete
    directory=$1
    echo "${YELLOW}DELETING directory:${NC} $directory..."
    # rm -r "$directory"
    echo "${GREEN}Done${NC}"
    echo
}

Restore_Directory() {
    # $1 = directory to restore
    # $2 = filename of tar(.gz) without path
    directory=$1
    archiveName=$2
    echo "${YELLOW}RESTORING backup from:${NC} $archiveName..."
    mkdir -p "$directory"
    if [ "$filesCompressed" = true ]; then
        tar -I pigz -xmpf "${currentRestoreDir}/$archiveName" -C "$directory"
    else
        tar -xmpf "${currentRestoreDir}/$archiveName" -C "$directory"
    fi
    echo "${GREEN}Done${NC}"
    echo
}

Delete_Old_Directories_And_Restore() {
    for index in ${!directories[*]}; do
        Delete_Directory ${directories[$index]}
        Restore_Directory ${directories[$index]} ${fileNameBackup[$index]}
    done
}

Restore_Element_Files () {
    echo "${YELLOW}Restore Element files...${NC}"
    cp "${currentRestoreDir}/${elementConfig}" "${filePaths[0]}"
    echo "${GREEN}Done${NC}"
    echo
}

Restart_All_Containers () {
    echo "${YELLOW}Restarting Synapse + Element + Registration + Admin container...${NC}"
    echo "${RED}This will take some time. Please wait...${NC}"
    docker-compose restart
    echo "${GREEN}Done${NC}"
    echo
    echo
    docker ps
    echo
    echo
}

Start_All_Containers () {
    echo "${YELLOW}Starting Synapse + Element + Registration + Admin container...${NC}"
    echo "${RED}This will take some time. Please wait...${NC}"
    docker-compose up -d
    echo "${GREEN}Done${NC}"
    echo
    echo
    docker ps
    echo
    echo
}

Check_If_Backup_Compressed () {
    echo "${YELLOW}Checking if backup is compressed...${NC}"
    dbBackupName="$currentRestoreDir/$dbBackupName"
    if [ ! -f "${dbBackupName}" ]; then
        filesCompressed=true
        echo "${YELLOW}Backup is compressed!${NC}"
        # Add .gz extension
        for index in ${!fileNameBackup[*]}; do
            fileNameBackup[$index]+=".gz"
        done
        dbBackupName+=".gz"
    else
        echo "${YELLOW}Backup is not compressed!${NC}"
    fi
    echo "${GREEN}Done${NC}"
    echo
}

Check_Return_Code () {
    # $1 = Return code
    # $2 = Name of bash script
    retCode=$1
    if [ $retCode -eq 0 ]; then
        echo "${GREEN}$2 was successful${NC}"
    else
        echo "${RED}$2 failed! Review error messages above.${NC}"
        exit 1
    fi
    echo
}

RestoreSuccessful () {
    echo
    echo
    echo "${GREEN}Restoring from:    ${YELLOW}$restore${GREEN}    was successful${NC}"
    echo
    echo
    echo
    echo
}



# ------------------------------------------------------------------------------------------------------------------

if [ $selectedNr = 1 ]; then
    # Rollback to previous container releases and keep current database
    Restore_Env_File
    Pull_Images
    Backup_DB
    Delete_PostgreSQL_Container_And_Volume
    Setup_PostgreSQL_Container_And_Volume
    Restore_Database
    Start_All_Containers
    rm $dbBackupName
    RestoreSuccessful
elif [ $selectedNr = 2 ]; then
    # Rollback to previous container releases and restore old database
    Restore_Env_File
    Pull_Images
    Delete_PostgreSQL_Container_And_Volume
    Setup_PostgreSQL_Container_And_Volume
    Check_If_Backup_Compressed
    Restore_Database
    Start_All_Containers
    RestoreSuccessful
elif [ $selectedNr = 3 ]; then
    # Restore only old database
    Delete_PostgreSQL_Container_And_Volume
    Setup_PostgreSQL_Container_And_Volume
    Check_If_Backup_Compressed
    Restore_Database
    Restart_All_Containers
    RestoreSuccessful
elif [ $selectedNr = 4 ]; then
    # You are on a new machine and want to restore everything
    Make_Scripts_Executable
    Restore_Docker_Compose_File
    Restore_Env_File
    Restore_Domains_File
    # Install software like nginx, docker, etc
    echo "${YELLOW}Executing install.sh (autoinstall)...${NC}"
    /bin/bash install.sh "autoinstall"
    Check_Return_Code $? "Auto install"
    # at this point images and volumes are created
    # but containers are not running!

    # Restore directories and volumes (except PSQL)
    Check_If_Backup_Compressed
    Delete_Old_Directories_And_Restore

    # Restore PostGreSQL database
    Setup_PostgreSQL_Container_And_Volume
    Restore_Database

    Restore_Element_Files
    Start_All_Containers

    # Restart nginx and make final checks
    echo "${YELLOW}Executing install.sh (finalize)...${NC}"
    /bin/bash install.sh "finalize"
    Check_Return_Code $? "Finalize installation"
    RestoreSuccessful
fi

