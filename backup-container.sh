#!/bin/bash
# +------------------------------------------------+
# | Name    : DockerToBackupPC
# | Version : 0.1
# | Author  : Philippe Maladjian
# +------------------------------------------------+
# docker inspect --format='{{index .Config.Labels "backuppc.active"}}' NAME
# docker inspect --format='{{index .Config.Labels "backuppc.services"}} NAME
# docker inspect --format='{{index .Config.Labels "backuppc.volumes.path"}}' NAME

DEST=/export

usage() {
	echo "Usage"
        echo "./backup_container.sh -d ContainerName [-u DBUser] [-p DBPassword] [-n DBName][-c] [-r]"
        echo ""
	echo " -n : database name"
        echo " -d : name of the container to be saved"
        echo " -u : mysql username if you enable mysql backup"
        echo " -p : mysql password if you enable mysql backup"
        echo " -c : compress sql file if you enable mysql backup" 
	echo " -r : delete all files and directory in export dir. Use with post backup"
        echo ""

	echo "In your container you will have to add labels"
	echo "docker-compose.yml"
	echo "[...]"
	echo "labels:"
	echo "  # Activate backup"
	echo "  - backuppc.active=true"
	echo "  # Service to be saved. They must be separated by a comma."
	echo "  - backuppc.services=mysql,volume"
	echo "[...]"
	echo ""
	echo "  If there is only one service to save then it must end with a comma. Eg: backuppc.services=mysql,"
	echo ""
	echo " --- Notes ---"
	echo "  for mysqldump --> GRANT SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER ON 'DATABASE'.* TO 'USER'@'%';"
	echo "                    GRANT PROCESS ON *.* TO 'USER'@'%';"

	exit 1
}

out() { 
	IFS=${IFSOLD}
	exit ${1}
}

# Post command
delete_export() {
	rm -Rf ${DEST}/${IDC}/*
	if [ ${?} != "0" ]
	then
		exit 1
	else
		exit 0
	fi
}

while getopts ":d:h:n:u:p:cr" OPT
do
	case "${OPT}" in
		c) COMPRESS="true";;
		d) IDC=${OPTARG};;
		h) DBHOST=${OPTARG};;
		n) DBNAME=${OPTARG};;
		u) DBUSER=${OPTARG};;
		p) DBPASSWORD=${OPTARG};;
		r) delete_export;;
		:) usage;;
		\?) usage;;
		*) usage;;
	esac
done

if [ -z "${IDC}" ]
then
	out 1
else
	ACTIVE=`docker inspect --format='{{index .Config.Labels "backuppc.active"}}' ${IDC}`
	if [ "${ACTIVE}" = "true" ]
	then

		if [ ! -d ${DEST}/${IDC} ]
		then
			mkdir -p ${DEST}/${IDC}
			if [ ${?} != "0" ]
			then
				out 1
			fi
		fi

		SERVICES=`docker inspect --format='{{index .Config.Labels "backuppc.services"}}' ${IDC}`
		
		IFSOLD=${IFS}
		IFS=","
		readarray -d , -t strarrS <<< "${SERVICES}"
		for (( s=0; s < ${#strarrS[*]}; s++))
		do
			if [ "${strarrS[s]}" = "volume" ]
			then	
				VOLUMES=`docker inspect --format='{{index .Config.Labels "backuppc.volume.path"}}' ${IDC}`
				readarray -d , -t strarrV < <(printf '%s' "${VOLUMES}")
				for (( v=0; v < ${#strarrV[*]}; v++))
				do
					docker cp ${IDC}:${strarrV[v]} ${DEST}/${IDC}
					if [ ${?} != "0" ]
					then
						out 1
					fi
				done
			fi

			if [ "${strarrS[s]}" = "mysql" ]
			then
				if [ ! -z "${DBUSER}" ] || [ ! -z "${DBPASSWORD}" ] || [ ! -z ${DBNAME} ]]
				then
					mysqldump --user=${DBUSER} --password=${DBPASSWORD} --host=${DBHOST} ${DBNAME} > ${DEST}/${IDC}/sql_${DBNAME}.sql
					if [ ${?} != "0" ]
					then
						out 1
					else
						if [ ! -z "${COMPRESS}" ]
						then
							tar -czf ${DEST}/${IDC}/sql_${IDC}.tar.gz ${DEST}/${IDC}/sql_${DBNAME}.sql
							if [ ${?} != "0" ]
							then
								out 1
							else
								rm -f ${DEST}/${IDC}/sql_${DBNAME}.sql
							fi
						fi
					fi
				else
					out 1
				fi
			fi
		done
		out 0
	fi
fi

