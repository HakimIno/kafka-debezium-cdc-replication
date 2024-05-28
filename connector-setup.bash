#!/bin/bash

export DEBEZIUM_VERSION=2.3
export DC_FILE=docker-compose.dev.yml

# Create the database and grant privileges
docker compose -f ${DC_FILE} exec -e MYSQL_PWD=debezium mysql \
    mysql -uroot -e "create database inventory;grant all privileges on inventory.* to 'mysqluser'@'%';"

# Check if the previous command succeeded
if [ $? -ne 0 ]; then
  echo "Failed to create database or grant privileges."
  exit 1
fi

# Create the Debezium source connector
curl -i -X POST http://localhost:8083/connectors/ \
  -H "Accept:application/json" \
  -H "Content-Type:application/json" \
  -d '{
    "name": "employees-connector-from-mysql",
    "config": {
        "connector.class": "io.debezium.connector.mysql.MySqlConnector",
        "tasks.max": "1",
        "database.hostname": "mysql-main",
        "database.port": "3306",
        "database.user": "root",
        "database.password": "debezium",
        "database.server.id": "184054",
        "database.include.list": "inventory",
        "schema.history.internal.kafka.bootstrap.servers": "kafka:9092",
        "schema.history.internal.kafka.topic": "schema-changes.inventory",
        "database.history.kafka.bootstrap.servers": "kafka:9092",
        "database.history.kafka.topic": "dbhistory.inventory",
        "database.server.name": "mysql",
        "topic.prefix": "from_mysql",
        "include.schema.changes": "true",
        "heartbeat.interval.ms": "3000",
        "autoReconnect": "true",
        "transforms": "route",
        "transforms.route.type": "org.apache.kafka.connect.transforms.RegexRouter",
        "transforms.route.regex": "([^.]+)\\.([^.]+)\\.([^.]+)",
        "transforms.route.replacement": "from_mysql_$3"
    }
}'

# Check if the previous command succeeded
if [ $? -ne 0 ]; then
  echo "Failed to create Debezium source connector."
  exit 1
fi

# Get the list of topics
topics=$(docker compose -f ${DC_FILE} exec kafka /kafka/bin/kafka-topics.sh --bootstrap-server kafka:9092 --list)

# Loop through topics and create sink connectors
for topic in $topics; do
    if [[ $topic == from_mysql_* ]]; then
        connector_name="jdbc-sink-to-mysql-${topic#from_mysql_}"
        curl -i -X POST http://localhost:8083/connectors/ \
            -H "Accept:application/json" \
            -H "Content-Type:application/json" \
            -d '{
                "name": "'"$connector_name"'",
                "config": {
                    "heartbeat.interval.ms": "3000",
                    "autoReconnect": "true",
                    "connector.class": "io.debezium.connector.jdbc.JdbcSinkConnector",
                    "tasks.max": "1",
                    "topics": "'"$topic"'",
                    "connection.url": "jdbc:mysql://mysql:3306/inventory",
                    "connection.username": "mysqluser",
                    "connection.password": "mysqlpw",
                    "auto.create": "true",
                    "insert.mode": "upsert",
                    "delete.enabled": "true",
                    "primary.key.mode": "record_key",
                    "schema.evolution": "basic",
                    "database.time_zone": "UTC",
                    "auto.evolve": "true",
                    "value.converter.schemas.enable": "true",
                    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
                    "pk.mode": "kafka"
                }
            }'

        # Check if the previous command succeeded
        if [ $? -ne 0 ]; then
            echo "Failed to create JDBC sink connector for topic $topic."
            exit 1
        fi
    fi
done

# List all connectors
curl --location 'http://localhost:8083/connectors' | jq '.'

# Optional: Check the status of specific connectors
# curl --location 'http://localhost:8083/connectors/employees-connector-from-mysql/status' | jq '.'
# curl --location 'http://localhost:8083/connectors/jdbc-sink-to-mysql-customers/status' | jq '.'
# curl --location 'http://localhost:8083/connectors/jdbc-sink-to-mysql-employees/status' | jq '.'
# curl --location 'http://localhost:8083/connectors/jdbc-sink-to-mysql-salaries/status' | jq '.'

# Optional: Delete connectors
# curl --request DELETE 'http://localhost:8083/connectors/employees-connector-from-mysql'      
# curl --request DELETE 'http://localhost:8083/connectors/jdbc-sink-to-mysql-employees'
