#!/bin/bash

set -euo pipefail

if [ -z "$MYSQL_HOST" ] ||  [ -z "$MYSQL_PORT" ] ||[ -z "$MYSQL_USER" ] || [ -z "$MYSQL_PASSWORD" ] || [ -z "$R2_ACCESS_KEY_ID" ] || [ -z "$R2_SECRET_ACCESS_KEY" ] || [ -z "$R2_BUCKET" ] || [ -z "$R2_S3_ENDPOINT" ]; then
    echo "Missing required environment variables."
    exit 1
fi

# Create MySQL config file with credentials
MYSQL_CNF=$(mktemp)
cat > "$MYSQL_CNF" << EOF
[client]
host=$MYSQL_HOST
port=$MYSQL_PORT
user=$MYSQL_USER
password=$MYSQL_PASSWORD
protocol=tcp
EOF

# Wait for MySQL to be ready
max_tries=30
counter=0
until mysqladmin --defaults-file="$MYSQL_CNF" ping 2>/dev/null; do
    counter=$((counter + 1))
    if [ $counter -gt $max_tries ]; then
        echo "Error: MySQL did not become ready in time"
        exit 1
    fi
    echo "Waiting for MySQL to be ready... ($counter/$max_tries)"
    sleep 2
done

# Liste toutes les DB, sauf system (mysql, information_schema, etc)
DBS=$(mysql --defaults-file="$MYSQL_CNF" -N -e "SHOW DATABASES;" | grep -Ev "^(mysql|sys|information_schema|performance_schema)$")

if [ -z "$DBS" ]; then
    echo "No user databases found."
    rm "$MYSQL_CNF"
    exit 1
fi

# Ensures rclone config directory exists
mkdir -p ~/.config/rclone

# Defines rclone.conf content
CONFIG_CONTENT=$(cat <<EOL
[remote]
type = s3
provider = Cloudflare
access_key_id = $R2_ACCESS_KEY_ID
secret_access_key = $R2_SECRET_ACCESS_KEY
endpoint = $R2_S3_ENDPOINT
acl = private
EOL
)

# Writes rclone.conf content
echo "$CONFIG_CONTENT" > ~/.config/rclone/rclone.conf

if [ ! -f ~/.config/rclone/rclone.conf ]; then
    echo "Error: Failed to create rclone.conf"
    rm "$MYSQL_CNF"
    exit 1
fi

# Creates bucket if it doesn't exist
rclone mkdir remote:$R2_BUCKET

# Loop sur chaque DB et backup
for DB in $DBS; do
    DUMP_FILE="db_${DB}_backup_$(date +%Y%m%d_%H%M%S).sql.gz"
    echo "Dumping $DB..."
    mysqldump --defaults-file="$MYSQL_CNF" --protocol=tcp "$DB" | gzip > "$DUMP_FILE"
    if [ $? -ne 0 ]; then
        echo "Dump failed for $DB"
        continue
    fi
    rclone copyto "$DUMP_FILE" remote:$R2_BUCKET/mysql-backup/"$DUMP_FILE"
    if [ $? -eq 0 ]; then
        echo "Backup $DB ok!"
        rm "$DUMP_FILE"
    else
        echo "Backup failed for $DB"
    fi
done

# Removes temporary config file
rm "$MYSQL_CNF"