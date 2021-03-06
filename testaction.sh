#! /bin/bash

usage() {
    echo ""
    echo "Usage: sudo -E bash add-storage-account.sh <storage-account-name> <storage-account-key> [-p]" ;
	echo "If -p option is specified, then storage account key will be stored in plain text. Otherwise, it will be encrypted."
    echo "This script does NOT require Ambari username and password";
    exit 132;
}

#validate user input
if [ -z "$1" ]
    then
        usage
        echo "Storage account name must be provided."
        exit 137
fi

if [ -z "$2" ]
    then
        usage
        echo "Storage account key must be provided."
        exit 138
fi

if [ "$3" == "-p" ]
	then
		DISABLEENCRYPTION=true
		echo "Key encryption is disabled."
	else
		DISABLEENCRYPTION=false
		echo "Key encryption is enabled"
fi

STORAGEACCOUNTNAME=$1
if [[ $1 == *blob.core.windows.net* ]]; then
    echo "Extracting storage account name from $1"
    STORAGEACCOUNTNAME=$(echo $1 | cut -d'.' -f 1)
fi
echo STORAGE ACCOUNT IS: $STORAGEACCOUNTNAME

STORAGEACCOUNTKEY=$2

#for idempotency, check if storage account is already present.
CORESITECONTENT=$(cat /etc/hadoop/conf/core-site.xml)
if [[ $CORESITECONTENT =~ $STORAGEACCOUNTNAME.blob.core.windows.net ]]; then
    echo "Storage account already added to cluster. Exiting!!!"
    exit 0
fi

#validate storage account credentials
echo "Validate storage account creds:"
CREDS_VALIDATION=$(echo -e "from azure.storage.blob import BlobService\nvalid=True\ntry:\n\tblob_service = BlobService(account_name='$STORAGEACCOUNTNAME', account_key='$STORAGEACCOUNTKEY')\n\tblob_service.get_blob_service_properties()\nexcept Exception as e:\n\tvalid=False\nprint valid"| sudo python)
if [[ $CREDS_VALIDATION == "False" ]]; then
    echo "Invalid Credentials provided for storage account"
    exit 139
else
    echo "Successfully validated storage account credentials."
fi

AMBARICONFIGS_PY=/var/lib/ambari-server/resources/scripts/configs.py
PORT=8080

ACTIVEAMBARIHOST=headnodehost

#Import helper module
wget -O /tmp/HDInsightUtilities-v01.sh -q https://hdiconfigactions.blob.core.windows.net/linuxconfigactionmodulev01/HDInsightUtilities-v01.sh && source /tmp/HDInsightUtilities-v01.sh && rm -f /tmp/HDInsightUtilities-v01.sh

checkHostNameAndSetClusterName() {
	PRIMARYHEADNODE=`get_primary_headnode`
    
	#Check if values retrieved are empty, if yes, exit with error
	if [[ -z $PRIMARYHEADNODE ]]; then
	echo "Could not determine primary headnode."
	exit 139
	fi

	fullHostName=$(hostname -f)
    echo "fullHostName=$fullHostName. Lower case: ${fullHostName,,}"
    echo "primary headnode=$PRIMARYHEADNODE. Lower case: ${PRIMARYHEADNODE,,}"
    if [ "${fullHostName,,}" != "${PRIMARYHEADNODE,,}" ]; then
        echo "$fullHostName is not primary headnode. This script has to be run on $PRIMARYHEADNODE."
        exit 0
    fi
    CLUSTERNAME=$(sed -n -e 's/.*\.\(.*\)-ssh.*/\1/p' <<< $fullHostName)
    if [ -z "$CLUSTERNAME" ]; then
        CLUSTERNAME=$(echo -e "import hdinsight_common.ClusterManifestParser as ClusterManifestParser\nprint ClusterManifestParser.parse_local_manifest().deployment.cluster_name" | python)
        if [ $? -ne 0 ]; then
            echo "[ERROR] Cannot determine cluster name. Exiting!"
            exit 133
        fi
    fi
    echo "Cluster Name=$CLUSTERNAME"
}


checkHostNameAndSetClusterName

if [ "$DISABLEENCRYPTION" == true ]; then
	echo "Encryption is disabled. No changes will be made to storage account key."
	KEYPROVIDER=SimpleKeyProvider
else
	#Encrypt storage account key
	KEYPROVIDER=ShellDecryptionKeyProvider
	echo "Encrypting storage account key"

	echo "Getting encryption cert"
	for cert in `sudo ls /var/lib/waagent/*.crt`
	do
		SUBJECT=`sudo openssl x509 -in $cert -noout -subject`
		if [[ $SUBJECT == *"cluster-$CLUSTERNAME-"* ]]; then
				CERT=$cert
				break
		fi
        # the new cert subject name should be EC-{HDIDeploymentID}.{valid domain}
		if [[ $SUBJECT == *"EC-"* ]]; then
				CERT=$cert
				break
		fi        
	done

	if [ -z "$CERT" ];then
		echo "Could not locate cert for encryption"
		exit 142
	fi

	echo $2 | sudo openssl cms -encrypt -outform PEM -out storagekey.txt $CERT
	if (( $? )); then
		echo "Could not encrypt storage account key"
		exit 140
	fi

	STORAGEACCOUNTKEY=$(echo -e "import re\n\nfile = open('storagekey.txt', 'r')\nfor line in file.read().splitlines():\n\tif '-----BEGIN CMS-----' in line or '-----END CMS-----' in line:\n\t\tcontinue\n\telse:\n\t\tprint line\nfile.close()" | sudo python)
	STORAGEACCOUNTKEY=$(echo $STORAGEACCOUNTKEY | tr -d ' ')
	if [ -z "$STORAGEACCOUNTKEY" ];
	then
		echo "Storage account key could not be stripped off header values form encrypted key"
		exit 141
	fi
	rm storagekey.txt
fi 


validateUsernameAndPassword() {
    #coreSiteContent=$(bash $AMBARICONFIGS_PY --user=$USERID --password=$PASSWD --action=get --port=$ACTIVEAMBARIHOST --cluster=$CLUSTERNAME --config-type=core-site)
    coreSiteContent=$($AMBARICONFIGS_PY --user=$USERID --password=$PASSWD --action=get --port=$PORT --host=$ACTIVEAMBARIHOST --cluster=$CLUSTERNAME --config-type=core-site)
	
    if [[ $coreSiteContent == *"[ERROR]"* && $coreSiteContent == *"Bad credentials"* ]]; then
        echo "[ERROR] Username and password are invalid. Exiting!"
        exit 134
    fi
}

updateAmbariConfigs() {
    updateResult=$($AMBARICONFIGS_PY --user=$USERID --password=$PASSWD --action=set --port=$PORT --host=$ACTIVEAMBARIHOST --cluster=$CLUSTERNAME --config-type=core-site -k "fs.azure.account.key.$STORAGEACCOUNTNAME.blob.core.windows.net" -v "$STORAGEACCOUNTKEY")
    
    if [[ $updateResult != *"Tag:version"* ]] && [[ $updateResult == *"[ERROR]"* ]]; then
        echo "[ERROR] Failed to update core-site. Exiting!"
        echo $updateResult
        exit 135
    fi
    echo "Added property: 'fs.azure.account.key.$STORAGEACCOUNTNAME.blob.core.windows.net' with storage account key"

    updateResult=$($AMBARICONFIGS_PY --user=$USERID --password=$PASSWD --action=set --port=$PORT --host=$ACTIVEAMBARIHOST --cluster=$CLUSTERNAME --config-type=core-site -k "fs.azure.account.keyprovider.$STORAGEACCOUNTNAME.blob.core.windows.net" -v "org.apache.hadoop.fs.azure.$KEYPROVIDER")
	if [[ $updateResult != *"Tag:version"* ]] && [[ $updateResult == *"[ERROR]"* ]]; then
		echo "[ERROR] Failed to update core-site. Exiting!"
		echo $updateResult
		exit 135
	fi
	echo "Added property: 'fs.azure.account.keyprovider.$STORAGEACCOUNTNAME.blob.core.windows.net':org.apache.hadoop.fs.azure.$KEYPROVIDER "
}

stopServiceViaRest() {
    if [ -z "$1" ]; then
        echo "Need service name to stop service"
        exit 136
    fi
    SERVICENAME=$1
    echo "Stopping $SERVICENAME"
    curl -u $USERID:$PASSWD -i -H 'X-Requested-By: ambari' -X PUT -d '{"RequestInfo": {"context" :"Stop Service for adding storage account"}, "Body": {"ServiceInfo": {"state": "INSTALLED"}}}' http://$ACTIVEAMBARIHOST:$PORT/api/v1/clusters/$CLUSTERNAME/services/$SERVICENAME
}

startServiceViaRest() {
    if [ -z "$1" ]; then
        echo "Need service name to start service"
        exit 136
    fi
    sleep 2
    SERVICENAME=$1
    echo "Starting $SERVICENAME"
    startResult=$(curl -u $USERID:$PASSWD -i -H 'X-Requested-By: ambari' -X PUT -d '{"RequestInfo": {"context" :"Start Service after adding storage account"}, "Body": {"ServiceInfo": {"state": "STARTED"}}}' http://$ACTIVEAMBARIHOST:$PORT/api/v1/clusters/$CLUSTERNAME/services/$SERVICENAME)
    if [[ $startResult == *"500 Server Error"* || $startResult == *"internal system exception occurred"* ]]; then
        sleep 60
        echo "Retry starting $SERVICENAME"
        startResult=$(curl -u $USERID:$PASSWD -i -H 'X-Requested-By: ambari' -X PUT -d '{"RequestInfo": {"context" :"Start Service after adding storage account"}, "Body": {"ServiceInfo": {"state": "STARTED"}}}' http://$ACTIVEAMBARIHOST:$PORT/api/v1/clusters/$CLUSTERNAME/services/$SERVICENAME)
    fi
    echo $startResult
}

##############################
if [ "$(id -u)" != "0" ]; then
    echo "[ERROR] The script has to be run as root."
    usage
fi

USERID=$(echo -e "import hdinsight_common.Constants as Constants\nprint Constants.AMBARI_WATCHDOG_USERNAME" | python)

echo "USERID=$USERID"

PASSWD=$(echo -e "import hdinsight_common.ClusterManifestParser as ClusterManifestParser\nimport hdinsight_common.Constants as Constants\nimport base64\nbase64pwd = ClusterManifestParser.parse_local_manifest().ambari_users.usersmap[Constants.AMBARI_WATCHDOG_USERNAME].password\nprint base64.b64decode(base64pwd)" | python)

validateUsernameAndPassword

echo "***************************UPDATING AMBARI CONFIG**************************"
updateAmbariConfigs
echo "***************************UPDATED AMBARI CONFIG**************************"

function restart_stale_services() {
    sudo python << EOF
from hdinsight_common.AmbariHelper import AmbariHelper
ambari_helper = AmbariHelper()
ambari_helper.restart_all_stale_services()
EOF
}

#before issuing a restart command, wait for 30 seconds
sleep 30

restart_stale_services